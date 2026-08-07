#!/usr/bin/env python3
"""irixexec.py — host side of the IRIX tile's serial exec channel.

`labctl exec irix "<cmd>"` runs this. It talks irixser/2 (see irixagent.pl) to
the agent inside the guest over MAME's `-ioc2:rs232a pty` line, prints the
command's captured stdout+stderr BYTE FOR BYTE, and exits with the command's OWN
exit code.

    irixexec.py <tile-dir> "<cmd>" [--timeout S] [--outmax N]
                                   [--detach] [--fast] [--pts PATH]
    irixexec.py <tile-dir> --ping [--agent-src PATH]

Exit status
    0..255  the guest command's exit code
    124     timed out (the host aborted it; the guest killed the process group)
    125     could not talk to the agent (no pty, no PING answer, bad framing)
    126     --ping: the guest's agent is NOT the --agent-src file
    128+N   the guest command was killed by signal N

WHY A pty AND NOT A SOCKET.  MAME's `socket.` bitbanger closes its listener
after the first accept and never re-accepts (verified 2026-08-03), so a one-shot
client would work exactly once per MAME run. The `pty` endpoint has no accept
semantics at all: MAME holds /dev/ptmx open for its whole life and the host
opens the slave as often as it likes. The slave's NAME is never printed by MAME
(dipty.cpp only stores it), so it is scraped out of the emulator's fd table.

SINGLE CONSUMER.  Two clients on one serial line would interleave bytes, so
every run takes an exclusive flock on <tile-dir>/serial.lock and waits its turn.

BYTES, NOT TEXT.  The wire is latin-1 (it is an escaped 7-bit protocol), but
what the guest produced is bytes and is written to stdout as bytes. Decoding
output to str and letting print() re-encode it turned every byte >= 0x80 into
two, which is invisible until somebody cksums a file through this channel.
"""

import argparse
import errno
import fcntl
import os
import random
import select
import sys
import termios
import time

PROTO = "irixser/2"
E_CHANNEL = 125
E_TIMEOUT = 124
E_DRIFT = 126

_UNESC = {"n": "\n", "r": "\r", "\\": "\\"}

# A reply that is still arriving keeps the client alive past --timeout: the cap
# bounds RAW guest bytes, escaping can quadruple them, and this wire does ~140
# B/s. --timeout bounds the COMMAND; this bounds silence.
TRANSFER_GRACE = float(os.environ.get("IRIXEXEC_TRANSFER_GRACE", "60"))


def esc(s):
    out = []
    for ch in s:
        b = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif 0x20 <= b <= 0x7E:
            out.append(ch)
        else:
            out.append("\\x%02x" % b)
    return "".join(out)


def unesc(s):
    """Inverse of esc(), returning BYTES. Raises ValueError on a malformed
    escape rather than silently handing back a corrupted payload."""
    out = bytearray()
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        i += 1
        if ch != "\\":
            out.append(ord(ch) & 0xFF)
            continue
        if i >= n:
            raise ValueError("truncated escape")
        e = s[i]
        i += 1
        if e in _UNESC:
            out.append(ord(_UNESC[e]))
        elif e == "x":
            if i + 2 > n:
                raise ValueError("truncated hex escape")
            out.append(int(s[i : i + 2], 16))
            i += 2
        else:
            raise ValueError("unknown escape \\%s" % e)
    return bytes(out)


def sum16(text):
    return sum(text.encode("latin-1")) & 0xFFFF


def frame(ident, verb, payload=""):
    """One protocol line. The checksum covers the framing — id and verb — as
    well as the payload: in irixser/1 they sat outside it, so a mangled id on
    the terminal X line was invisible to the checksum and surfaced as a bogus
    timeout instead of the replay the protocol has for exactly that case."""
    body = "%s %s %s" % (ident, verb, payload)
    return "%s %s %04x %s" % (ident, verb, sum16(body), payload)


def parse(line):
    """(id, verb, payload) for a checksum-clean reply line, or None."""
    parts = line.split(" ", 3)
    if len(parts) < 3:
        return None
    ident, verb, field = parts[0], parts[1], parts[2]
    payload = parts[3] if len(parts) > 3 else ""
    try:
        want = int(field, 16)
    except ValueError:
        return None
    if sum16("%s %s %s" % (ident, verb, payload)) != want:
        return None
    return ident, verb, payload


def is_mame(pid):
    """Is this pid actually the tile's emulator? mame.pid can outlive the
    process it names, and writing protocol lines into whatever inherited that
    pid's pty is not a mistake worth being able to make."""
    try:
        if "mame" in os.path.basename(os.readlink("/proc/%d/exe" % pid)).lower():
            return True
    except OSError:
        pass
    # The tile runs MAME through the bundled glibc's ld.so, so argv[0] is the
    # loader and the emulator's name is further along the command line.
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            argv = f.read().lower()
        return b"mame" in argv or b"indy_4610" in argv
    except OSError:
        return False


def find_pts(tile_dir):
    """The host end of ioc2:rs232a, in preference order: an explicit override,
    MAME's own fd table (authoritative), then the file the launcher wrote at
    boot (a convenience that goes stale the moment MAME is relaunched)."""
    env = os.environ.get("IRIX_SERIAL_PTS")
    if env:
        return env
    pid = None
    try:
        with open(os.path.join(tile_dir, "mame.pid")) as f:
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
    try:
        with open(os.path.join(tile_dir, "serial.pts")) as f:
            path = f.read().strip()
        if path:
            return path
    except OSError:
        pass
    return None


class Line:
    """The serial line: raw termios, line-buffered reads, whole-line writes."""

    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
        self._set_raw()
        self.buf = b""
        # IRIXEXEC_TRACE=<file> records every byte in both directions. On a wire
        # this exotic, "what did the guest ACTUALLY send" is the first question
        # of every investigation, and reconstructing it afterwards is hopeless.
        self.trace = open(os.environ["IRIXEXEC_TRACE"], "ab") if os.environ.get("IRIXEXEC_TRACE") else None

    def _log(self, direction, data):
        if self.trace:
            self.trace.write(b"%s %r\n" % (direction, data))
            self.trace.flush()

    def _set_raw(self):
        a = termios.tcgetattr(self.fd)
        # iflag: no CR/NL rewriting, no ^S/^Q flow control (a literal 0x13 in a
        # command's output would otherwise stop the line for ever), no 8th-bit
        # stripping. oflag: no post-processing. lflag: no echo, no canonical
        # mode, no signal generation.
        a[0] = termios.IGNBRK
        a[1] = 0
        a[3] = 0
        a[6][termios.VMIN] = 0
        a[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, a)

    def drain(self, quiet=0.3, limit=2.0):
        """Discard whatever a previous client left on the wire."""
        end = time.monotonic() + limit
        last = time.monotonic()
        while time.monotonic() < end and time.monotonic() - last < quiet:
            r, _, _ = select.select([self.fd], [], [], 0.1)
            if r:
                junk = os.read(self.fd, 4096)
                if junk:
                    self._log(b"drain", junk)
                    last = time.monotonic()
        self.buf = b""

    def send(self, line):
        data = (line + "\n").encode("latin-1")
        self._log(b"tx", data)
        off = 0
        while off < len(data):
            try:
                off += os.write(self.fd, data[off:])
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EINTR):
                    continue
                raise

    def readline(self, deadline):
        """One decoded line, or None when the deadline passes."""
        while True:
            i = self.buf.find(b"\n")
            if i >= 0:
                line = self.buf[:i]
                self.buf = self.buf[i + 1 :]
                # rstrip("\r\n") and NOT .strip(): a payload may legitimately
                # begin or end with spaces (any 512-byte chunk boundary can land
                # in the middle of an indent), and stripping them silently
                # corrupted output that was otherwise byte-exact.
                return line.decode("latin-1").rstrip("\r\n")
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            r, _, _ = select.select([self.fd], [], [], min(left, 0.5))
            if r:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError as exc:
                    if exc.errno in (errno.EAGAIN, errno.EINTR):
                        continue
                    raise
                if chunk:
                    self._log(b"rx", chunk)
                    self.buf += chunk

    def close(self):
        os.close(self.fd)


def die(msg, code=E_CHANNEL):
    sys.stderr.write("irixexec: %s\n" % msg)
    sys.exit(code)


def sync(line, ident, timeout=20.0):
    """Put the line in a known state: drain, then PING with a fresh id and read
    until that id answers. Returns the agent's banner payload, or None.
    Anything with another id is a leftover from a client that died mid-reply."""
    line.drain()
    for _ in range(2):
        line.send(frame(ident, "PING"))
        deadline = time.monotonic() + timeout
        while True:
            got = line.readline(deadline)
            if got is None:
                break
            rec = parse(got)
            if rec and rec[0] == str(ident) and rec[1] == "P":
                return rec[2]
        ident += 1
    return None


def agent_srcsum(path):
    """The same additive 16-bit checksum the agent computes over its own source
    at startup, so `--ping --agent-src` answers "is the baked agent the file in
    the repo" without mounting the golden."""
    with open(path, "rb") as f:
        return "%04x" % (sum(f.read()) & 0xFFFF)


def run(line, args):
    ident = random.randrange(1000000, 2**31)
    banner = sync(line, ident)
    if banner is None:
        die("agent did not answer PING")
    ident += 1

    opts = "t=%d,o=%d,p=%s,d=%d" % (
        int(args.timeout) + 10 if args.timeout else 0,
        args.outmax,
        "fast" if args.fast else "idle",
        1 if args.detach else 0,
    )
    pending = frame(ident, "RUN", "%s %s" % (opts, esc(args.cmd)))
    line.send(pending)

    cur = ident  # the id the agent is answering under (a replay changes it)
    out = []
    status = None
    truncated = None
    sum_retries = 3
    nak_retries = 2
    started = False  # have we seen any valid line for this reply yet?
    replay_id = ident + 1000
    abort_id = ident + 2000
    cmd_deadline = time.monotonic() + args.timeout
    deadline = cmd_deadline

    def corrupted(what):
        """Never repair a line locally and never re-run the command: ask the
        agent to replay the whole reply it still remembers, under a NEW id so
        the replay cannot be confused with the tail of the original still on
        the wire."""
        nonlocal cur, out, truncated, sum_retries, replay_id, deadline, started, pending
        if sum_retries <= 0:
            die("checksum mismatch and no retries left: %r" % what)
        sum_retries -= 1
        out, truncated, started = [], None, False
        replay_id += 1
        cur = replay_id
        pending = frame(replay_id, "RESULT", str(ident))
        line.send(pending)
        deadline = time.monotonic() + args.timeout

    while status is None:
        got = line.readline(deadline)
        if got is None:
            # Host-side timeout. Tell the agent to stop before letting go of the
            # line, or the tail of this command would land on the next client.
            # The agent reads ABORT between output chunks, so this is answered
            # even mid-transmission.
            line.send(frame(abort_id, "ABORT", str(cur)))
            end = time.monotonic() + 30
            while True:
                tail = line.readline(end)
                if tail is None:
                    break
                rec = parse(tail)
                if rec and rec[1] == "X":
                    break
            sys.stderr.write("irixexec: timed out after %.0fs (output below is PARTIAL)\n" % args.timeout)
            sys.stdout.buffer.write(b"".join(out))
            sys.stdout.buffer.flush()
            return E_TIMEOUT
        rec = parse(got)
        if rec is None:
            corrupted(got)
            continue
        rid, verb, body = rec
        if verb == "N" and not started and (rid == str(cur) or rid == "0"):
            # The agent did NOT run it. Re-send the identical line: a RUN is
            # idempotent in its id, so even if the NAK was raised by leftover
            # garbage that preceded an accepted RUN, the agent replays rather
            # than running the command twice.
            if nak_retries <= 0:
                die("the agent rejected the request: %s" % body)
            nak_retries -= 1
            line.send(pending)
            continue
        if rid != str(cur):
            continue  # a reply to somebody else's request, or a stale line
        started = True
        # Anything still arriving means the transfer is alive; a big reply on a
        # ~140 B/s wire must not be killed by the COMMAND's timeout.
        deadline = max(deadline, time.monotonic() + TRANSFER_GRACE)
        try:
            if verb == "O":
                out.append(unesc(body))
            elif verb == "T":
                bits = body.split(" ", 1)
                truncated = (int(bits[0]), unesc(bits[1]).decode("latin-1") if len(bits) > 1 else "")
            elif verb == "X":
                status = int(body)
            elif verb == "E":
                sys.stderr.write("irixexec: agent error: %s\n" % unesc(body).decode("latin-1"))
                return E_CHANNEL
        except ValueError:
            # Checksum-clean but not parseable — so the AGENT built it that way
            # (a garbled render, see irixagent.pl). Same recovery as a bad
            # checksum: replay, never re-run.
            corrupted(got)

    sys.stdout.buffer.write(b"".join(out))
    sys.stdout.buffer.flush()
    if truncated:
        sys.stderr.write("irixexec: output capped, %d more bytes in guest %s\n" % truncated)
    if status == 257:
        sys.stderr.write("irixexec: the guest timed the command out\n")
        return E_TIMEOUT
    if status == 258:
        sys.stderr.write("irixexec: aborted\n")
        return E_TIMEOUT
    if status > 255:
        sys.stderr.write("irixexec: killed by signal %d\n" % (status - 256))
        return 128 + (status - 256)
    return status


def ping(line, args):
    banner = sync(line, random.randrange(1000000, 2**31))
    if banner is None:
        die("agent did not answer PING")
    print(banner)
    if not args.agent_src:
        return 0
    want = agent_srcsum(args.agent_src)
    got = banner.split()[-1] if banner.split() else ""
    if got != want:
        sys.stderr.write(
            "irixexec: AGENT DRIFT — guest srcsum %s, %s is %s\n" % (got, args.agent_src, want)
        )
        return E_DRIFT
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("tile_dir")
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--outmax", type=int, default=4096)
    ap.add_argument("--detach", action="store_true")
    ap.add_argument("--fast", action="store_true")
    ap.add_argument("--pts")
    ap.add_argument("--ping", action="store_true", help="banner + agent source checksum")
    ap.add_argument("--agent-src", help="with --ping: fail 126 unless the guest runs THIS file")
    args = ap.parse_args()
    if not args.ping and args.cmd is None:
        ap.error("a command is required (or --ping)")

    pts = args.pts or find_pts(args.tile_dir)
    if not pts or not os.path.exists(pts):
        die("no serial line for %s (is MAME running?)" % args.tile_dir)

    lockpath = os.path.join(args.tile_dir, "serial.lock")
    try:
        lock = open(lockpath, "w")
    except OSError as exc:
        die("cannot open %s: %s" % (lockpath, exc))
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
    except OSError as exc:
        die("cannot lock the serial line: %s" % exc)

    try:
        line = Line(pts)
    except OSError as exc:
        die("cannot open %s: %s" % (pts, exc))
    try:
        return ping(line, args) if args.ping else run(line, args)
    finally:
        line.close()


if __name__ == "__main__":
    sys.exit(main())
