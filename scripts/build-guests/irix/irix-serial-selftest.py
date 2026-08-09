#!/usr/bin/env python3
"""irix-serial-selftest.py — run the REAL irixser/2 agent and the REAL client
against each other over a pair of ptys, with a relay in the middle that can
corrupt the wire on demand.

    scripts/build-guests/irix/irix-serial-selftest.py [-v] [NAME ...]

Why this exists: the acceptance evidence for the IRIX exec channel used to be
prose in a commit message, so a re-bake (agent change, an SCC fix, a new base
golden) had to re-derive the whole verification by hand on a tile whose cold
boot is 4.5 minutes. Everything except the emulated UART and IRIX's own perl is
exercised here in a couple of seconds, on any box with perl.

WHAT IT CANNOT COVER: the guest's perl is 5.004 and the wire is MAME's SCC.
Syntax that a modern perl accepts and 5.004 does not, and the SCC's byte
dropping itself, still need a booted clone (scripts/build-guests/irix/irix-serial-rig.sh).
What it DOES cover is every protocol decision — framing, checksums in both
directions, replay, NAK/resend, abort, truncation, byte-exactness — including
the four corruption cases that a wire test can only produce by luck.
"""

import contextlib
import os
import pty
import random
import re
import subprocess
import sys
import termios
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_GA = os.path.join(HERE, "..", "..", "streamhost", "guest-agents", "irix")
# Overridable so an OLD pair can be pointed at the same suite — which is how the
# corruption cases were shown to fail on irixser/1 and pass on /2.
AGENT = os.environ.get("IRIX_SELFTEST_AGENT", os.path.join(_GA, "irixagent.pl"))
CLIENT = os.environ.get("IRIX_SELFTEST_CLIENT", os.path.join(_GA, "irixexec.py"))
VERBOSE = False


def set_raw(fd):
    a = termios.tcgetattr(fd)
    a[0] = termios.IGNBRK
    a[1] = 0
    a[3] = 0
    a[6][termios.VMIN] = 1
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)


class Wire:
    """Two ptys joined by a line-oriented relay. The hooks see one whole
    protocol line at a time and may return it changed, which is how a dropped
    byte or a flipped digit is produced on demand instead of waited for."""

    def __init__(self, g2h=None, h2g=None):
        self.g2h = g2h or (lambda line: line)
        self.h2g = h2g or (lambda line: line)
        self.mA, self.sA = pty.openpty()  # agent end
        self.mB, self.sB = pty.openpty()  # client end
        self.agent_dev = os.ttyname(self.sA)
        self.client_dev = os.ttyname(self.sB)
        for fd in (self.mA, self.sA, self.mB, self.sB):
            set_raw(fd)
        # The slave fds are deliberately kept open for the life of the rig: with
        # no slave holder a master read fails EIO the instant the agent or the
        # client is between opens, and the relay thread would die for good.
        self.alive = True
        self.threads = [
            threading.Thread(target=self._pump, args=(self.mA, self.mB, self.g2h, "g2h"), daemon=True),
            threading.Thread(target=self._pump, args=(self.mB, self.mA, self.h2g, "h2g"), daemon=True),
        ]
        for t in self.threads:
            t.start()

    def _pump(self, src, dst, hook, tag):
        buf = b""
        while self.alive:
            try:
                data = os.read(src, 4096)
            except OSError:
                return
            if not data:
                return
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                out = hook(line)
                if VERBOSE:
                    mark = "" if out == line else "  <-- MANGLED"
                    sys.stderr.write(f"  {tag} {out!r}{mark}\n")
                try:
                    os.write(dst, out + b"\n")
                except OSError:
                    return

    def close(self):
        self.alive = False
        for fd in (self.mA, self.mB, self.sA, self.sB):
            with contextlib.suppress(OSError):
                os.close(fd)


class Rig:
    def __init__(self, tmpdir, g2h=None, h2g=None):
        self.tmp = tmpdir
        os.makedirs(tmpdir, exist_ok=True)
        self.wire = Wire(g2h, h2g)
        env = dict(os.environ)
        env["IRIXAGENT_DEV"] = self.wire.agent_dev
        env["IRIXAGENT_LOGDIR"] = tmpdir
        env["IRIXAGENT_CHUNK"] = os.environ.get("SELFTEST_CHUNK", "64")
        self.log = open(os.path.join(tmpdir, "agent.log"), "wb")  # noqa: SIM115 — closed in stop()
        self.agent = subprocess.Popen(["perl", AGENT], env=env, stdout=self.log, stderr=self.log)
        time.sleep(0.4)

    def exec(self, cmd, *extra, timeout=20):
        env = dict(os.environ)
        env["IRIX_SERIAL_PTS"] = self.wire.client_dev
        argv = [sys.executable, CLIENT, self.tmp, cmd, "--timeout", str(timeout), *extra]
        return subprocess.run(argv, env=env, capture_output=True, timeout=timeout + 90)

    def stop(self):
        self.agent.terminate()
        try:
            self.agent.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.agent.kill()
        self.log.close()
        self.wire.close()


# ---- corruption hooks -------------------------------------------------------
def once(pattern, mangle):
    """Apply `mangle` to the FIRST line matching `pattern`, then get out of the
    way — a hook that keeps corrupting would test an unrecoverable wire, and the
    point is that the protocol recovers."""
    state = {"done": False}

    def hook(line):
        if state["done"] or not re.search(pattern, line):
            return line
        state["done"] = True
        return mangle(line)

    return hook


def flip_payload(line):
    """Change one byte of the payload, leaving the framing intact — the case the
    checksum was added for."""
    parts = line.split(b" ", 3)
    if len(parts) < 4 or not parts[3]:
        return line
    body = bytearray(parts[3])
    body[0] = body[0] ^ 0x01
    return b" ".join(parts[:3] + [bytes(body)])


def eat_id_digit(line):
    """Delete a digit from the id. In irixser/1 the id was outside the checksum,
    so this was invisible and surfaced as a timeout."""
    parts = line.split(b" ", 1)
    return parts[0][:-1] + b" " + parts[1]


def eat_cmd_byte(line):
    """Drop a byte from the command text of a RUN. In irixser/1 the request
    direction had no checksum at all, so the guest ran the mutated command and
    reported success."""
    i = line.rfind(b" ")
    return line[: i + 2] + line[i + 3 :]


# ---- tests ------------------------------------------------------------------
CASES = []


def case(fn):
    CASES.append(fn)
    return fn


def need(cond, what):
    if not cond:
        raise AssertionError(what)


@case
def basics(tmp):
    """exit codes, stdout, stderr, multi-line, empty output, signals"""
    r = Rig(tmp)
    try:
        p = r.exec("echo hello")
        need(p.returncode == 0 and p.stdout == b"hello\n", f"echo: rc={p.returncode} out={p.stdout!r}")
        p = r.exec("exit 42")
        need(p.returncode == 42, f"exit 42 -> {p.returncode}")
        p = r.exec("echo out; echo err 1>&2")
        need(b"out" in p.stdout and b"err" in p.stdout, f"stderr not merged: {p.stdout!r}")
        p = r.exec("printf 'a\\nb\\nc\\n'")
        need(p.stdout == b"a\nb\nc\n", f"multiline: {p.stdout!r}")
        p = r.exec("true")
        need(p.returncode == 0 and p.stdout == b"", f"empty output: {p.stdout!r}")
        p = r.exec("kill -9 $$")
        need(p.returncode == 137, f"SIGKILL -> {p.returncode} (want 137)")
    finally:
        r.stop()


@case
def byte_exact(tmp):
    """every byte 0x00..0xff survives the round trip unchanged"""
    r = Rig(tmp)
    try:
        p = r.exec(
            "perl -e 'binmode(STDOUT); print map { chr($_) } 0..255'",
            "--outmax",
            "4096",
        )
        want = bytes(range(256))
        need(p.stdout == want, f"byte round trip: {len(p.stdout)} bytes, first diff at {_firstdiff(p.stdout, want)}")
        # High bytes are where irixser/1 lost: latin-1 in, UTF-8 out.
        p = r.exec("perl -e 'print chr(255) x 300'", "--outmax", "4096")
        need(p.stdout == b"\xff" * 300, f"0xff x300 came back as {len(p.stdout)} bytes")
    finally:
        r.stop()


def _firstdiff(a, b):
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return i
    return "length"


@case
def reply_payload_corrupted(tmp):
    """a mangled O line must yield the FULL output, not a truncated one

    irixser/1's replay went out under the ORIGINAL id, so the client could not
    tell replayed lines from the tail of the original still in flight: it
    appended that tail, hit the original X and exited 0 with partial output."""
    cmd = "for i in 1 2 3 4 5 6 7 8; do echo line-$i-%s; done" % ("x" * 60)
    want = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True).stdout
    r = Rig(tmp, g2h=once(rb" O ", flip_payload))
    try:
        p = r.exec(cmd, "--outmax", "8192")
        need(p.returncode == 0, f"rc={p.returncode} stderr={p.stderr!r}")
        need(p.stdout == want, f"got {len(p.stdout)} bytes, want {len(want)}")
    finally:
        r.stop()


@case
def reply_id_corrupted(tmp):
    """a mangled id on the terminal X line must replay, not time out

    In irixser/1 the id sat outside the checksum, so this was dropped silently
    and the client waited out its whole deadline (exit 124) on a command that
    had in fact completed."""
    r = Rig(tmp, g2h=once(rb"^\d+ X ", eat_id_digit))
    try:
        t0 = time.monotonic()
        p = r.exec("echo done; exit 3", timeout=15)
        need(p.returncode == 3, f"rc={p.returncode} (want 3) stderr={p.stderr!r}")
        need(p.stdout == b"done\n", f"stdout={p.stdout!r}")
        need(time.monotonic() - t0 < 15, "took %.1fs — that is the timeout path" % (time.monotonic() - t0))
    finally:
        r.stop()


@case
def reply_verb_corrupted(tmp):
    """a mangled verb byte is inside the checksum too"""
    r = Rig(tmp, g2h=once(rb"^\d+ X ", lambda ln: ln.replace(b" X ", b" Z ", 1)))
    try:
        p = r.exec("echo ok; exit 7", timeout=15)
        need(p.returncode == 7, f"rc={p.returncode} (want 7) stderr={p.stderr!r}")
        need(p.stdout == b"ok\n", f"stdout={p.stdout!r}")
    finally:
        r.stop()


@case
def request_corrupted(tmp):
    """a dropped byte in the RUN must NOT run a different command

    irixser/1 checksummed replies only: the guest ran the mutated command and
    the client reported exit 0 with the mutated output."""
    marker = "A" * 40 + "-marker"
    r = Rig(tmp, h2g=once(rb" RUN ", eat_cmd_byte))
    try:
        p = r.exec(f"echo {marker}", timeout=20)
        need(p.returncode == 0, f"rc={p.returncode} stderr={p.stderr!r}")
        need(p.stdout == (marker + "\n").encode(), f"ran a MUTATED command: {p.stdout!r}")
    finally:
        r.stop()


@case
def request_run_not_duplicated(tmp):
    """the NAK/resend path must not run a non-idempotent command twice

    The agent NAKs a line it cannot verify; the client re-sends the identical
    line. If a NAK were ever raised by garbage that merely PRECEDED an accepted
    RUN, the resend would be a second execution — so a RUN is idempotent in its
    id, and this proves it with a command that counts its own invocations."""
    counter = os.path.join(tmp, "runs")
    cmd = f"echo x >> {counter}; wc -l < {counter}"
    # Corrupt the FIRST reply the agent sends for the run (its O line), which
    # makes the client re-fetch; then corrupt a later request so it also NAKs.
    r = Rig(tmp, h2g=once(rb" RUN ", lambda ln: ln[:-1]))
    try:
        p = r.exec(cmd, timeout=20)
        need(p.returncode == 0, f"rc={p.returncode} stderr={p.stderr!r}")
        need(p.stdout.strip() == b"1", f"the command ran {p.stdout.strip()} times, want 1")
    finally:
        r.stop()


@case
def truncation(tmp):
    """the output cap is exact and the remainder stays in the guest"""
    r = Rig(tmp)
    try:
        p = r.exec("perl -e 'print \"z\" x 5000'", "--outmax", "1000")
        need(p.stdout == b"z" * 1000, f"capped output is {len(p.stdout)} bytes")
        need(b"4000 more bytes" in p.stderr, f"no truncation note: {p.stderr!r}")
    finally:
        r.stop()


@case
def abort_frees_the_line(tmp):
    """a timed-out big reply must not block the NEXT client

    irixser/1's agent did not look at the line again until the whole capped
    output had been paced out, so the ABORT was read minutes late and the next
    client's PING died behind the backlog."""
    os.environ["SELFTEST_CHUNK"] = "1"  # a slow wire, so the abort lands mid-reply
    # A reply that is still ARRIVING normally keeps the client alive past
    # --timeout (a big reply on a 140 B/s wire must not be killed by the
    # command's own budget). Shrink that grace so this case can produce a host
    # timeout in the middle of a transfer, which is the state under test.
    os.environ["IRIXEXEC_TRANSFER_GRACE"] = "0.05"
    r = Rig(tmp)
    try:
        p = r.exec("perl -e 'print \"y\" x 20000'", "--outmax", "20000", timeout=2)
        need(p.returncode == 124, f"rc={p.returncode} (want 124)")
        t0 = time.monotonic()
        p = r.exec("echo after", timeout=25)
        dt = time.monotonic() - t0
        need(p.returncode == 0 and p.stdout == b"after\n", f"next command: rc={p.returncode} out={p.stdout!r}")
        need(dt < 20, f"the next command took {dt:.1f}s — the line was still draining")
    finally:
        os.environ.pop("SELFTEST_CHUNK", None)
        os.environ.pop("IRIXEXEC_TRANSFER_GRACE", None)
        r.stop()


@case
def detach(tmp):
    """--detach returns at once and the command keeps running"""
    r = Rig(tmp)
    marker = os.path.join(tmp, "detach.marker")
    try:
        t0 = time.monotonic()
        p = r.exec(f"sleep 3; echo done > {marker}", "--detach", timeout=20)
        need(p.returncode == 0, f"rc={p.returncode} stderr={p.stderr!r}")
        need(time.monotonic() - t0 < 10, "detach took %.1fs" % (time.monotonic() - t0))
        need(not os.path.exists(marker), "the command was not detached")
        time.sleep(5)
        need(os.path.exists(marker), "the detached command never ran")
    finally:
        r.stop()


@case
def single_instance(tmp):
    """a second agent on the same line declines to start"""
    r = Rig(tmp)
    try:
        env = dict(os.environ)
        env["IRIXAGENT_DEV"] = r.wire.agent_dev
        env["IRIXAGENT_LOGDIR"] = tmp
        second = subprocess.Popen(["perl", AGENT], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.0)
        p = r.exec("echo still-readable", timeout=20)
        second.kill()
        second.wait()
        need(p.stdout == b"still-readable\n", f"two agents interleaved: {p.stdout!r}")
    finally:
        r.stop()


@case
def ping_reports_source_checksum(tmp):
    """--ping --agent-src detects an agent that is not the repo's"""
    r = Rig(tmp)
    try:
        env = dict(os.environ)
        env["IRIX_SERIAL_PTS"] = r.wire.client_dev
        p = subprocess.run(
            [sys.executable, CLIENT, tmp, "--ping", "--agent-src", AGENT], env=env, capture_output=True, timeout=60
        )
        need(p.returncode == 0, f"ping vs the real source: rc={p.returncode} {p.stdout!r} {p.stderr!r}")
        need(b"irixser/2" in p.stdout, f"banner: {p.stdout!r}")
        other = os.path.join(tmp, "not-the-agent.pl")
        with open(other, "wb") as f:
            f.write(b"# a different file\n")
        p = subprocess.run(
            [sys.executable, CLIENT, tmp, "--ping", "--agent-src", other], env=env, capture_output=True, timeout=60
        )
        need(p.returncode == 126, f"drift not reported: rc={p.returncode} {p.stderr!r}")
    finally:
        r.stop()


def main():
    global VERBOSE
    args = [a for a in sys.argv[1:] if a != "-v"]
    VERBOSE = "-v" in sys.argv[1:]
    if subprocess.run(["perl", "-e", "1"], capture_output=True).returncode != 0:
        sys.stderr.write("irix-serial-selftest: no perl\n")
        return 2
    root = f"/tmp/irixser-selftest-{random.randrange(10**6)}"
    chosen = [c for c in CASES if not args or c.__name__ in args]
    if not chosen:
        sys.stderr.write("no such case; have: {}\n".format(" ".join(c.__name__ for c in CASES)))
        return 2
    failed = []
    for c in chosen:
        t0 = time.monotonic()
        try:
            c(os.path.join(root, c.__name__))
            print(f"PASS  {c.__name__:<28} {time.monotonic() - t0:5.1f}s  {(c.__doc__ or chr(10)).splitlines()[0]}")
        except Exception as exc:  # noqa: BLE001 — a failing case must not stop the suite
            failed.append(c.__name__)
            print(f"FAIL  {c.__name__:<28} {time.monotonic() - t0:5.1f}s  {exc}")
    print(f"{len(chosen) - len(failed)}/{len(chosen)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
