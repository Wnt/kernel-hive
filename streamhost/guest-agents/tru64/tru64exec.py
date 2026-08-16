#!/usr/bin/env python3
"""tru64exec — captured command exec over the Tru64 guest's second serial line,
for `labctl exec tru64`.

This station has NO network device (see docs/guests/tru64.md), so the exec
channel is the emulated com2 that es40 already carries: the guest runs a getty
on /dev/tty01, and the tile's pumps.py lends that line to one client at a time
over the unix socket serial-exec.sock in the station dir. That indirection is
what makes the channel survive relaunches — the TCP serial port is held by
pumps.py from boot (es40 blocks until both ports have a client), and clients
address the station DIRECTORY, never a port.

It logs in (passwordless root), silences the tty so the console's own noise and
the shell's echo cannot be mistaken for output, wraps the command between
unique sentinels with a trailing `echo $?`, and prints what the command printed,
exiting with the guest's status — the labctl-exec contract.

    tru64exec.py <station-dir> "<cmd>" [--timeout SECS]

A command is run in a FRESH login each call: sequential calls cannot inherit a
half-typed line from a previous one, and a wedged call cannot poison the next.
"""

import os
import re
import signal
import socket
import sys
import time
import uuid

PROMPT = re.compile(rb"[#$] ?$")
LOGIN = re.compile(rb"(?i)login:[^\n]*$")
PASSWORD = re.compile(rb"(?i)password:[^\n]*$")


def thaw(station_dir):
    """SIGCONT this station's emulator if streamhost's idle auto-pause has it
    frozen. A paused guest answers nothing, and the pauser can re-freeze it
    mid-command (grace has long expired when nobody is watching), so this is
    called before each phase rather than once at the start. Same mechanism and
    same guard as labctl's ensure_running: the pid comes from the pidfile the
    daemon itself uses, and it is only signalled while its cmdline still looks
    like this station's emulator."""
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


class Session:
    def __init__(self, path, timeout):
        self.deadline = time.time() + timeout
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(5)
        self.s.connect(path)
        self.buf = bytearray()

    def send(self, line):
        self.s.sendall(line.encode("latin1") + b"\r")
        time.sleep(0.2)

    def read_until(self, pattern, timeout=None):
        """Read until `pattern` matches the tail of the stream, or time out."""
        end = time.time() + (timeout if timeout is not None else 20)
        end = min(end, self.deadline)
        rx = re.compile(pattern) if isinstance(pattern, (bytes, str)) else pattern
        while time.time() < end:
            if rx.search(bytes(self.buf)):
                return True
            self.s.settimeout(0.5)
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            if not d:
                break
            self.buf.extend(d)
        return bool(rx.search(bytes(self.buf)))

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def run_once(station_dir, cmd, timeout, tag):
    """One login + one command.

    Returns (rc, stdout, raw). rc None means the EXCHANGE failed — no sentinels
    came back, i.e. the line was corrupted or the guest never answered — which
    is the one case worth retrying on a fresh login."""
    begin, end = f"BX{tag}", f"EX{tag}"

    try:
        se = Session(f"{station_dir}/serial-exec.sock", timeout)
    except OSError as e:
        sys.stderr.write(
            f"tru64exec: cannot reach {station_dir}/serial-exec.sock ({e}).\n"
            "The station must be running (pumps.py owns the line and serves this socket).\n"
        )
        return 125, "", ""

    # Converge on a FRESH login prompt. The line is shared and persistent: a
    # previous call that timed out (or a guest frozen mid-exchange) can leave
    # the getty halfway through a login, and a client that assumes a clean line
    # then matches the wrong prompt and reports nonsense. So drive whatever
    # state we find back to "login:" — answer a stray Password:, log out of a
    # live shell — before touching the command.
    logged_in = False
    for _ in range(6):
        thaw(station_dir)
        se.buf.clear()
        se.send("")
        se.read_until(rb"(?i)login:|password:|[#$] ?$", 8)
        tail = bytes(se.buf)[-200:]
        if PASSWORD.search(tail):
            se.send("")  # empty password -> "Login incorrect" -> fresh login:
            continue
        if LOGIN.search(tail):
            se.send("root")
            if se.read_until(rb"(?i)password:", 6):
                se.send("")
            if se.read_until(rb"[#$] ?$", 30):
                logged_in = True
                break
            continue
        if PROMPT.search(tail):
            logged_in = True
            break
    if not logged_in:
        sys.stderr.write(
            "tru64exec: could not reach a shell on the serial console.\n"
            "The guest may be frozen (idle auto-pause) or the getty on tty01 is gone.\n"
        )
        se.close()
        return 125, "", ""

    # root's login shell here is /bin/sh — Tru64's LEGACY Bourne shell, where
    # `$(...)` is not command substitution but a syntax error, so a caller's
    # ordinary-looking command comes back with the substitution untouched. ksh
    # has it, and is what every other station's exec effectively gives you, so
    # pin ksh and fall back to sh if this guest somehow lacks it. `exec`
    # replaces the login shell, so `exit` below still logs the session out.
    se.send("exec /bin/ksh")
    if not se.read_until(rb"[#$] ?$", 10):
        se.send("exec /bin/sh")
        se.read_until(rb"[#$] ?$", 10)
    # stty: no echo (the shell would otherwise repeat the wrapped line back and
    # the first sentinel would match the ECHO, not the run). Empty prompt so a
    # prompt string can never land inside captured output.
    se.send("stty -echo; PS1=; export PS1")
    # SYNCHRONISE, do not sleep. This guest is emulated and its console is a
    # 9600-baud-shaped pipe: a fixed pause sometimes ended while the previous
    # line was still being echoed, and the next line interleaved with it
    # ("stt# y -echo") — a corrupted command line that produces no sentinel at
    # all. Waiting for a marker the shell can only print once it is idle and
    # echo is really off removes the race instead of widening the window.
    sync = f"SY{tag}"
    se.send(f"echo {sync}")
    se.read_until(sync.encode(), 20)
    se.buf.clear()

    # The command runs in a SUBSHELL: a bare `exit 3` (or a command that ends
    # with one) would otherwise kill the login before the closing sentinel is
    # echoed, and the call would report "sentinels not found" instead of the
    # status the operator asked for.
    end_re = re.compile(end.encode() + rb"(\d+)")
    se.send(f"echo {begin}; ( {cmd} ); echo {end}$?")
    if not se.read_until(end_re, timeout):
        # A long command can outlive the idle pauser's patience: thaw and give
        # the tail of the output a second chance before declaring failure.
        thaw(station_dir)
        se.read_until(end_re, min(30.0, timeout))

    text = bytes(se.buf).replace(b"\r", b"").decode("latin1", "replace")
    try:
        se.send("exit")
    except OSError:
        pass
    se.close()

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
        sys.stderr.write('usage: tru64exec.py <station-dir> "<cmd>" [--timeout SECS]\n')
        return 2
    station_dir, cmd = argv[0], " ".join(argv[1:])

    # One retry, on a FRESH login. A serial console shared with a getty has
    # states this client did not create — a half-finished login from a call
    # that timed out, a guest frozen mid-line — and the cheap, honest recovery
    # is to start the exchange over rather than to guess what the line means.
    raw = ""
    for attempt in range(2):
        rc, out, raw = run_once(station_dir, cmd, timeout, uuid.uuid4().hex[:12].upper())
        if rc is not None:
            if out:
                sys.stdout.write(out + "\n")
            return rc
        if attempt == 0:
            time.sleep(1.0)
    sys.stderr.write("tru64exec: no sentinels after two attempts; raw serial:\n")
    sys.stderr.write(raw)
    return 125


if __name__ == "__main__":
    sys.exit(main())
