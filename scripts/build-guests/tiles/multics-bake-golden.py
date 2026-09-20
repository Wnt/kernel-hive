#!/usr/bin/env python3
"""Bake the Multics golden root.dsk: boot, change Repair's password, shut down clean.

Run on labhost. Output: $MULTICS_BAKE_DIR/root.dsk, which becomes
assets/multics/media/root.dsk — the immutable RPV every launch reflink-copies.

WHY THIS EXISTS: the released MR12.8 QuickStart FORCES a password change on the
first `Repair` login. A visitor must never be shown that, so the change is made
once, here, and the disk is then shut down cleanly.

FOUR THINGS THIS SCRIPT KNOWS THAT COST A RUN EACH (all measured 2026-09-20):

 1. `dps8 ... < fifo` never boots — it prints as far as the FNP listen line and
    sleeps forever. /dev/null boots, and a pty boots. The bake needs a pty
    because the console is what performs the shutdown.

 2. system_control DROPS request text that arrives in the same write as the
    attention ESC. The handshake is ESC -> wait for a NEW `M-> ` -> settle ->
    send. It also sometimes just releases the console without running anything
    (`M-> CONSOLE: RELEASED`), so the request is not sent, it is sent AND
    VERIFIED by its echo, and retried when the echo does not appear.

 3. `shut` does not shut down. It answers "shutdown: 5 users still on. Do you
    want to shut down?" and waits — those five are the standard SysDaemons the
    answering service logs in at every boot, so this is the normal path, not an
    anomaly. Unanswered, the console prints `CONSOLE: TIMEOUT` and gives up.

 4. `die` is NOT a system_control request. After `shutdown complete` the console
    belongs to BCE, which takes typed lines with no attention key. Sending `die`
    through the ESC handshake produces `system_control: Unknown request "die"`.

The FNP conversation is driven by SILENCE, not by sleeps: every step waits for
the line to stop talking before sending the next thing. A first attempt used
fixed `time.sleep(2)` steps, and on a loaded box (the answering service took
85 s instead of the measured 52 s) the whole exchange slid one step out of
phase and typed the new password at the login prompt.
"""

import contextlib
import os
import pathlib
import pty
import select
import shutil
import signal
import socket
import subprocess
import sys
import time

DPS8 = os.environ.get("MULTICS_DPS8", "/data/assets-staging/multics/dps8m-r3.1.0/dps8")
QS = os.environ.get("MULTICS_QUICKSTART", "/data/assets-staging/multics/QuickStart_MR12.8")
S = os.environ.get("MULTICS_BAKE_DIR", "/data/vms/sandbox/multics-live/bake")
FNP_PORT = int(os.environ.get("MULTICS_FNP_PORT", "6180"))
NEWPW = os.environ.get("MULTICS_REPAIR_PW", "multics")
# On success the baked RPV is installed as the station's immutable asset, mode
# 0444, so the launcher can bind it read-only. Set to "" to leave it in $S.
INSTALL_TO = os.environ.get("MULTICS_INSTALL_TO", "/data/vms/streamhost/assets/multics/media/root.dsk")


def reap():
    """Kill any stray simulator by /proc/<pid>/exe — never a cmdline grep
    (AGENTS.md rule 5: a cmdline match reaps your own shell)."""
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == os.getpid():
            continue
        try:
            e = os.readlink(f"/proc/{d}/exe")
        except OSError:
            continue
        if e.removesuffix(" (deleted)") == DPS8:
            print(f"reaping stray dps8 pid {d}", flush=True)
            with contextlib.suppress(OSError):
                os.kill(int(d), signal.SIGKILL)


reap()
shutil.rmtree(S, ignore_errors=True)
os.makedirs(S)
subprocess.run(["cp", "--reflink=auto", f"{QS}/root.dsk", f"{S}/root.dsk"], check=True)
for f in ("MR12.8_boot.ini", "12.8MULTICS.tap"):
    shutil.copy(f"{QS}/{f}", f"{S}/{f}")
pathlib.Path(f"{S}/serial.txt").write_text("sn: 0\n")

mfd, sfd = pty.openpty()
p = subprocess.Popen([DPS8, "MR12.8_boot.ini"], cwd=S, stdin=sfd, stdout=sfd, stderr=sfd, preexec_fn=os.setsid)
os.close(sfd)
log = bytearray()
# noqa: SIM115 — this handle lives for the whole run (pump() appends to it
# from every wait) and is closed at the end; a context manager would have to
# wrap the entire script body.
logf = open(f"{S}/dps8.log", "wb", buffering=0)  # noqa: SIM115
T0 = time.time()


def stamp():
    return f"+{time.time() - T0:6.1f}s"


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([mfd], [], [], 0.2)
        if mfd in r:
            try:
                b = os.read(mfd, 65536)
            except OSError:
                return
            if not b:
                return
            log.extend(b)
            logf.write(b)


def die(msg):
    print(f"BAKE FAILED: {msg}", flush=True)
    print("=== last 4000 bytes of console ===", flush=True)
    print(log[-4000:].decode("utf8", "replace"), flush=True)
    with contextlib.suppress(OSError):
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    sys.exit(1)


def wait_for(text, timeout, label):
    t0 = time.time()
    while time.time() - t0 < timeout:
        pump(0.5)
        if text.encode() in log:
            print(f"{label}: {stamp()} ({time.time() - t0:.1f}s waiting)", flush=True)
            return True
        if p.poll() is not None:
            die(f"{label}: dps8 EXITED rc={p.returncode}")
    return False


def con(s):
    os.write(mfd, s.encode())


def console_quiet(quiet=2.0, timeout=120):
    """Return once the operator console has said nothing for `quiet` seconds."""
    t0 = time.time()
    last = len(log)
    stable = time.time()
    while time.time() - t0 < timeout:
        pump(0.3)
        if len(log) != last:
            last = len(log)
            stable = time.time()
        elif time.time() - stable >= quiet:
            return
    return


LAST_REQ_MARK = 0


def req(cmd, tries=4):
    """Run a system_control request at the operator console.

    ESC -> wait for a NEW `M-> ` -> settle -> send -> VERIFY THE ECHO. The
    verification is the part that matters: the console sometimes takes the ESC,
    prints its prompt and then releases without running anything
    (`M-> CONSOLE: RELEASED`), and a request that was silently dropped looks
    exactly like one that ran.
    """
    global LAST_REQ_MARK
    for attempt in range(1, tries + 1):
        mark = len(log)
        LAST_REQ_MARK = mark
        con("\033")
        t0 = time.time()
        while time.time() - t0 < 30:
            pump(0.3)
            if b"M-> " in log[mark:]:
                break
        else:
            print(f"req({cmd!r}) attempt {attempt}: no M-> prompt", flush=True)
            continue
        pump(2.0)
        con(cmd + "\r")
        t0 = time.time()
        while time.time() - t0 < 20:
            pump(0.3)
            if cmd.encode() in log[mark:]:
                print(f"req({cmd!r}): echoed {stamp()} (attempt {attempt})", flush=True)
                return True
        print(f"req({cmd!r}) attempt {attempt}: no echo — console dropped it, retrying", flush=True)
        pump(3.0)
    die(f"req({cmd!r}): console never accepted the request after {tries} attempts")


def answer(pattern, reply, timeout=180, label=None, mark=None):
    """Answer a question the console has ALREADY prompted for.

    Unlike req(), the ESC must NOT be sent: Multics has printed `M-> ` itself
    and is waiting, so an ESC would be taken as the answer's first character.
    The console abandons an unanswered question, so this has to land in time.
    """
    # MEASURED: Multics prints the question in the SAME breath as the echo of
    # the request, so by the time req() has confirmed the echo the question is
    # already in the log. Searching from "now" therefore never finds it and the
    # console times out. Default to the mark req() started from.
    label = label or pattern
    if mark is None:
        mark = LAST_REQ_MARK
    t0 = time.time()
    while time.time() - t0 < timeout:
        pump(0.3)
        if pattern.encode() in log[mark:]:
            pump(1.0)
            con(reply + "\r")
            pump(1.0)
            print(f"answer({label!r}): sent {reply!r} {stamp()}", flush=True)
            return True
        if p.poll() is not None:
            die(f"answer({label!r}): dps8 exited rc={p.returncode}")
    return False


# ---------------------------------------------------------------- boot -------
if not wait_for("as_init_", 600, "answering-service"):
    die("answering service never came up")
# The SysDaemons log in and chatter for ~20 s after as_init_. Wait for the
# console to go quiet rather than guessing how long that takes.
console_quiet(quiet=4.0, timeout=180)
print(f"console quiet {stamp()}", flush=True)


# ------------------------------------------------ the FNP visitor line -------
class Line:
    """The visitor's FNP telnet line, driven by silence rather than sleeps."""

    def __init__(self, port):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.all = ""

    def settle(self, quiet=2.0, timeout=120):
        """Read until the line has been silent for `quiet` seconds; return the
        text that arrived in this step."""
        got = b""
        self.s.settimeout(0.5)
        last = time.time()
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                b = self.s.recv(8192)
                if not b:
                    break
                # Multics pads with NUL after CR, and the FNP opens with a
                # telnet option block; neither is content.
                got += b.replace(b"\x00", b"")
                last = time.time()
            except socket.timeout:
                if got and time.time() - last >= quiet:
                    break
            except OSError:
                break
        text = got.decode("utf8", "replace")
        self.all += text
        return text

    def send(self, s):
        self.s.sendall(s.encode())


ln = Line(FNP_PORT)
step = ln.settle()  # telnet options + the HSLA Port prompt
print(f"fnp connect {stamp()}: {step[-120:]!r}", flush=True)
ln.send("\r\n")
step = ln.settle()  # Attached to line d.h000 + login banner
print(f"fnp attach {stamp()}: {step[-160:]!r}", flush=True)
if "Attached to line" not in ln.all and "Channel d.h000" not in ln.all:
    die("the FNP never attached the visitor line")

ln.send("login Repair -cpw\r")
print(f"login prompt: {ln.settle()[-160:]!r}", flush=True)
ln.send("repair\r")
print(f"current pw:   {ln.settle()[-160:]!r}", flush=True)
ln.send(NEWPW + "\r")
print(f"new pw:       {ln.settle()[-160:]!r}", flush=True)
ln.send(NEWPW + "\r")
print(f"confirm pw:   {ln.settle(quiet=3.0)[-400:]!r}", flush=True)

if "Password changed" not in ln.all:
    print("=== full FNP transcript ===", flush=True)
    print(ln.all, flush=True)
    die("Repair's password was not changed — the exhibit would show a visitor the forced-change prompt")
print(f"PASSWORD CHANGED {stamp()}", flush=True)

ln.send("logout\r")
print(f"logout: {ln.settle()[-200:]!r}", flush=True)
with contextlib.suppress(OSError):
    ln.s.close()
console_quiet(quiet=4.0, timeout=120)


# ------------------------------------------------------- clean shutdown ------
# The console abandons an unanswered question quickly (`CONSOLE: TIMEOUT`), and
# a dropped ESC costs an attempt, so the whole request+confirm+complete cycle is
# retried as a unit rather than each step alone.
done = False
for attempt in range(1, 4):
    req("shut")
    if not answer("Do you want to shut down?", "yes", timeout=120, label="shutdown-confirm"):
        print(f"shutdown attempt {attempt}: no confirmation prompt", flush=True)
    if wait_for("shutdown complete", 420, "shutdown"):
        done = True
        break
    print(f"shutdown attempt {attempt}: no `shutdown complete`, retrying", flush=True)
    console_quiet(quiet=3.0, timeout=60)
if not done:
    die("`shutdown complete` never printed — the RPV is NOT safe to ship")

# THE DISK IS CONSISTENT FROM HERE. `shutdown complete` is Multics' own
# statement that every page has been flushed to the RPV. `die` only halts the
# CPU afterwards, so a simulator that refuses to die is cosmetic.
pump(8)
t0 = time.time()
while time.time() - t0 < 180:
    pump(0.5)
    if b"bce (" in log[-3000:]:
        break
con("die\r")
pump(5)
con("yes\r")
t0 = time.time()
while p.poll() is None and time.time() - t0 < 90:
    pump(1)
rc = p.poll()
print(f"dps8 rc: {rc} {stamp()}", flush=True)
if rc is None:
    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    print(
        "dps8 did not exit on die; SIGKILLed AFTER shutdown complete "
        "(the RPV was already flushed — see the gate above)",
        flush=True,
    )
logf.close()
print("=== console tail ===", flush=True)
print(log[-2000:].decode("utf8", "replace"), flush=True)
if INSTALL_TO:
    os.makedirs(os.path.dirname(INSTALL_TO), exist_ok=True)
    tmp = INSTALL_TO + ".new"
    subprocess.run(["cp", "--reflink=auto", f"{S}/root.dsk", tmp], check=True)
    os.chmod(tmp, 0o444)
    os.replace(tmp, INSTALL_TO)
    print(f"installed {INSTALL_TO} ({os.path.getsize(INSTALL_TO)} bytes, mode 0444)", flush=True)
print(f"=== BAKE OK: shutdown complete; {S}/root.dsk is the asset ===", flush=True)
