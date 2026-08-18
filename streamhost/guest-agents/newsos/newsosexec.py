#!/usr/bin/env python3
"""newsosexec.py — host side of the NEWS-OS tile's serial exec channel.

`labctl exec newsos "<cmd>"` runs this. NEWS-OS 4.1R has no host-reachable
network device on this station, so exec rides the emulated serial line MAME
already carries: the guest runs a getty on /dev/tty00, and MAME exposes that
line as a host pty (`-serial0 pty`). This client logs in (passwordless root),
silences the tty, wraps the command between unique sentinels with a trailing
`echo $?`, prints what the command printed byte-for-byte, and exits with the
guest's own status — the labctl-exec contract.

    newsosexec.py <station-dir> "<cmd>" [--timeout SECS]

TRANSPORT is irix's, not tru64's — no pump.  MAME holds /dev/ptmx open for its
whole life and the host opens the slave as often as it likes, so the client
opens the pty DIRECTLY (scraped out of MAME's fd table, which is authoritative
across relaunches — the slave name is never printed) under an exclusive flock
on <station-dir>/serial.lock so two runs cannot interleave on one line. There
is no port and no second process to hold it.

PROTOCOL is tru64's — a getty login driven back to a known state, then a
sentinel-framed command in a FRESH login each call so a wedged call cannot
poison the next.  Two NEWS-specific twists (see docs/guests/newsos.md):
  * root's login shell is /bin/csh and NEWS has NO ksh, so the session does
    `exec /bin/sh` (tru64's ksh path would strand a csh here).
  * /bin/sh starts with a threadbare PATH, so it is set explicitly or `id`,
    `uname`, etc. are simply "not found".
"""

import fcntl
import os
import re
import select
import signal
import sys
import termios
import time
import uuid

PROMPT = re.compile(rb"[#$%] ?$")
LOGIN = re.compile(rb"(?i)login:[^\n]*$")
PASSWORD = re.compile(rb"(?i)password:[^\n]*$")

# The PATH /bin/sh is given after `exec /bin/sh` — NEWS-OS's default is too thin
# to find id/uname/hostname, which live in /usr/ucb and /usr/bin here.
GUEST_PATH = "/bin:/usr/bin:/usr/ucb:/etc:/usr/etc"

E_CHANNEL = 125


def is_mame(pid):
    """Is this pid actually the tile's emulator? mame.pid can outlive the
    process it names, and writing into whatever inherited that pid's pty is not
    a mistake worth being able to make."""
    try:
        if "mame" in os.path.basename(os.readlink("/proc/%d/exe" % pid)).lower():
            return True
    except OSError:
        pass
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            argv = f.read().lower()
        return b"mame" in argv or b"nws3260" in argv
    except OSError:
        return False


def find_pts(station_dir):
    """The host end of MAME's -serial0 pty, in preference order: an explicit
    override, then MAME's own fd table (authoritative)."""
    env = os.environ.get("NEWSOS_SERIAL_PTS")
    if env:
        return env
    pid = None
    try:
        with open(os.path.join(station_dir, "mame.pid")) as f:
            pid = int(f.read().strip())
    except (OSError, ValueError):
        pid = None
    if pid and os.path.isdir("/proc/%d" % pid) and is_mame(pid):
        for fd in sorted(os.listdir("/proc/%d/fd" % pid), key=int):
            try:
                if os.readlink("/proc/%d/fd/%s" % (pid, fd)) != "/dev/ptmx":
                    continue
                with open("/proc/%d/fdinfo/%s" % (pid, fd)) as f:
                    for line in f:
                        if line.startswith("tty-index:"):
                            return "/dev/pts/%s" % line.split()[1]
            except OSError:
                continue
    return None


def thaw(station_dir):
    """SIGCONT this station's emulator if streamhost's idle auto-pause has it
    frozen. A paused guest answers nothing, and the pauser can re-freeze it
    mid-command, so this is called before each phase. The pid comes from the
    pidfile the daemon itself uses and is only signalled while its cmdline still
    looks like this station's emulator (same guard as labctl's ensure_running)."""
    env = {}
    try:
        with open(f"{station_dir}/station.env") as fh:
            for ln in fh:
                if "=" in ln and not ln.startswith("#"):
                    k, v = ln.split("=", 1)
                    env[k.strip()] = v.split("#", 1)[0].strip()
        pidfile = env.get("SH_IDLE_PAUSE_PIDFILE")
        match = env.get("SH_IDLE_PAUSE_PROC_MATCH", "")
        if not pidfile:
            return
        pid = int(open(pidfile).read().strip())
        state = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[0]
        if state not in ("T", "t"):
            return
        cmdline = open(f"/proc/{pid}/cmdline", "rb").read().decode("latin1")
        if match and match not in cmdline:
            return
        os.kill(pid, signal.SIGCONT)
        time.sleep(0.5)
    except (OSError, ValueError, IndexError):
        pass


class Pty:
    """The serial line as a raw byte stream: whole-line writes, tail-matched
    reads. termios raw so nothing rewrites CR/NL, strips the 8th bit, or acts on
    a literal ^S in output (which would stop the line for ever)."""

    def __init__(self, path, deadline):
        self.deadline = deadline
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        self._set_raw()
        self.buf = bytearray()

    def _set_raw(self):
        a = termios.tcgetattr(self.fd)
        a[0] = termios.IGNBRK  # iflag: no CR/NL xlate, no ^S/^Q, no istrip
        a[1] = 0  # oflag: no post-processing
        a[3] = 0  # lflag: no echo, no canon, no signals
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)

    def send(self, line):
        data = (line + "\r").encode("latin1")
        off = 0
        while off < len(data):
            try:
                off += os.write(self.fd, data[off:])
            except OSError:
                break
        time.sleep(0.2)

    def read_until(self, pattern, timeout=None):
        """Read until `pattern` matches the tail of the stream, or time out."""
        end = time.time() + (timeout if timeout is not None else 20)
        end = min(end, self.deadline)
        rx = re.compile(pattern) if isinstance(pattern, (bytes, str)) else pattern
        while time.time() < end:
            if rx.search(bytes(self.buf)):
                return True
            r, _, _ = select.select([self.fd], [], [], 0.5)
            if not r:
                continue
            try:
                d = os.read(self.fd, 4096)
            except OSError:
                break
            if not d:
                break
            self.buf.extend(d)
        return bool(rx.search(bytes(self.buf)))

    def clear(self):
        self.buf.clear()

    def close(self):
        try:
            os.close(self.fd)
        except OSError:
            pass


def open_session(station_dir, pts, timeout, tag):
    """Connect to the pty, converge on a login, and hand back a Pty at a silent
    /bin/sh prompt — or None. Drives whatever state the shared getty is in back
    to a known login before touching the command."""
    deadline = time.time() + timeout
    try:
        se = Pty(pts, deadline)
    except OSError as e:
        sys.stderr.write(f"newsosexec: cannot open {pts} ({e}).\n")
        return None

    logged_in = False
    probe = f"PB{tag}"
    for _ in range(6):
        thaw(station_dir)
        se.clear()
        se.send("")
        se.read_until(rb"(?i)login:|password:|[#$%] ?$", 8)
        tail = bytes(se.buf)[-200:]
        if not tail.strip():
            # Silent line: nothing listening, or a previous session left a live
            # shell with `stty -echo` and empty PS1 that answers a bare newline
            # with nothing. Ask a question only a shell can answer.
            se.clear()
            se.send(f"echo {probe}")
            if se.read_until(probe.encode(), 8):
                logged_in = True
                break
            continue
        if PASSWORD.search(tail):
            se.send("")  # empty password -> Login incorrect -> fresh login:
            continue
        if LOGIN.search(tail):
            se.send("root")
            if se.read_until(rb"(?i)password:", 6):
                se.send("")  # root is passwordless on this install
            if se.read_until(rb"[#$%] ?$", 30):
                logged_in = True
                break
            continue
        if PROMPT.search(tail):
            logged_in = True
            break
    if not logged_in:
        sys.stderr.write(
            "newsosexec: could not reach a shell on the serial console.\n"
            "The guest may be frozen (idle auto-pause) or the getty on tty00 is gone.\n"
        )
        se.close()
        return None

    # root's login shell is /bin/csh and NEWS has no ksh; the sentinel protocol
    # needs a Bourne shell, so `exec /bin/sh` (replacing the login shell, so the
    # closing `exit` still logs out). Then a real PATH — /bin/sh's default lacks
    # id/uname/hostname here.
    se.send("exec /bin/sh")
    se.read_until(rb"[#$%] ?$", 10)
    se.send(f"PATH={GUEST_PATH}; export PATH")
    # No echo (else the wrapped line echoes and the first sentinel matches the
    # ECHO, not the run); empty prompt so a PS1 can never land inside output.
    se.send("stty -echo; PS1=; export PS1")
    # Synchronise, do not sleep: wait for a marker the shell can only print once
    # it is idle and echo is really off, so the next line can't interleave with
    # a still-echoing one on this ~9600-baud-shaped pipe.
    sync = f"SY{tag}"
    se.send(f"echo {sync}")
    se.read_until(sync.encode(), 20)
    se.clear()
    return se


def run_command(se, station_dir, cmd, timeout, tag):
    """Run one command in an open session. Returns (rc, stdout, raw); rc None
    means no sentinels came back — the exchange failed, not the command."""
    begin, end = f"BX{tag}", f"EX{tag}"
    se.clear()
    end_re = re.compile(end.encode() + rb"(\d+)")
    # The command runs in a SUBSHELL so a bare `exit N` inside it cannot kill the
    # login before the closing sentinel is echoed.
    se.send(f"echo {begin}; ( {cmd} ); echo {end}$?")
    if not se.read_until(end_re, timeout):
        thaw(station_dir)  # a long command can outlive the idle pauser's patience
        se.read_until(end_re, min(30.0, timeout))

    text = bytes(se.buf).replace(b"\r", b"").decode("latin1", "replace")
    m = re.search(re.escape(begin) + r"\n(.*?)" + re.escape(end) + r"(\d+)", text, re.S)
    if not m:
        return None, "", text
    body, rc = m.group(1), int(m.group(2))
    lines = [ln for ln in body.split("\n") if begin not in ln and end not in ln]
    return rc, "\n".join(lines).strip("\n"), text


def main():
    argv = sys.argv[1:]
    timeout = 90.0
    if "--timeout" in argv:
        i = argv.index("--timeout")
        timeout = float(argv[i + 1])
        del argv[i : i + 2]
    if len(argv) < 2:
        sys.stderr.write('usage: newsosexec.py <station-dir> "<cmd>" [--timeout SECS]\n')
        return 2
    station_dir, cmd = argv[0], " ".join(argv[1:])

    pts = find_pts(station_dir)
    if not pts or not os.path.exists(pts):
        sys.stderr.write("newsosexec: no serial pty for %s (is MAME running?)\n" % station_dir)
        return E_CHANNEL

    # Single consumer: two shells interleaved on one console produce garbage that
    # looks like guest corruption. Wait our turn on the station's serial.lock.
    lockpath = os.path.join(station_dir, "serial.lock")
    try:
        lock = open(lockpath, "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
    except OSError as exc:
        sys.stderr.write("newsosexec: cannot lock the serial line: %s\n" % exc)
        return E_CHANNEL

    # One retry, on a FRESH login: a shared getty has states this client did not
    # create (a half-finished login from a timed-out call), and the honest
    # recovery is to start the exchange over.
    raw = ""
    for attempt in range(2):
        tag = uuid.uuid4().hex[:12].upper()
        se = open_session(station_dir, pts, timeout, tag)
        if se is None:
            return E_CHANNEL
        rc, out, raw = run_command(se, station_dir, cmd, timeout, tag)
        try:
            se.send("exit")
        except OSError:
            pass
        se.close()
        if rc is not None:
            if out:
                sys.stdout.write(out + "\n")
            return rc
        if attempt == 0:
            time.sleep(1.0)
    sys.stderr.write("newsosexec: no sentinels after two attempts; raw serial:\n")
    sys.stderr.write(raw)
    return E_CHANNEL


if __name__ == "__main__":
    sys.exit(main())
