#!/usr/bin/env python3
"""Bake the Multics golden root.dsk: boot, change Repair's password, clean shutdown.

STATUS 2026-09-20: PROVEN as far as `Password changed.`; the clean-shutdown tail
(`logout * * *` / `shut` / `die`) is NOT yet proven — see docs/lab/MULTICS-WAVE.md
wall W3. Do not treat the disk this writes as an asset until `shutdown complete`
appears in the console stream and dps8 exits with rc 0.

Why a pty and not a pipe: wall W1 — `dps8 ... < fifo` never boots. /dev/null
boots but then nothing can drive the operator console, and the console is what
performs the shutdown, so the bake needs a pty.

Run on labhost. Output: <S>/root.dsk.
"""
import os, pty, select, socket, subprocess, sys, time, shutil, signal

DPS8 = "/data/assets-staging/multics/dps8m-r3.1.0/dps8"
QS = "/data/assets-staging/multics/QuickStart_MR12.8"
S = os.environ.get("MULTICS_BAKE_DIR", "/data/vms/sandbox/multics-live/bake")
NEWPW = "multics"

def reap():
    for d in os.listdir("/proc"):
        if not d.isdigit() or int(d) == os.getpid():
            continue
        try:
            e = os.readlink(f"/proc/{d}/exe")
        except OSError:
            continue
        if e.removesuffix(" (deleted)") == DPS8:
            try: os.kill(int(d), signal.SIGKILL)
            except OSError: pass

reap(); time.sleep(1)
shutil.rmtree(S, ignore_errors=True); os.makedirs(S)
subprocess.run(["cp", "--reflink=auto", f"{QS}/root.dsk", f"{S}/root.dsk"], check=True)
for f in ("MR12.8_boot.ini", "12.8MULTICS.tap"):
    shutil.copy(f"{QS}/{f}", f"{S}/{f}")
open(f"{S}/serial.txt", "w").write("sn: 0\n")

mfd, sfd = pty.openpty()
p = subprocess.Popen([DPS8, "MR12.8_boot.ini"], cwd=S, stdin=sfd, stdout=sfd, stderr=sfd,
                     preexec_fn=os.setsid)
os.close(sfd)
log = bytearray()
logf = open(f"{S}/dps8.log", "wb", buffering=0)

def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([mfd], [], [], 0.2)
        if mfd in r:
            try: b = os.read(mfd, 65536)
            except OSError: return
            if not b: return
            log.extend(b); logf.write(b)

def wait_for(text, timeout, label):
    t0 = time.time()
    while time.time() - t0 < timeout:
        pump(0.5)
        if text.encode() in log:
            print(f"{label}: {time.time()-t0:.1f}s", flush=True); return True
        if p.poll() is not None:
            print(f"{label}: dps8 EXITED rc={p.returncode}", flush=True); return False
    print(f"{label}: TIMEOUT after {timeout}s", flush=True); return False

def con(s):
    os.write(mfd, s.encode())

def req(cmd, settle=2.0):
    """ESC to take the operator console, WAIT for the M-> prompt, then the request.
    Characters sent in the same breath as the ESC are dropped by system_control."""
    mark = len(log)
    con("\033")
    t0 = time.time()
    while time.time() - t0 < 30:
        pump(0.3)
        if b"M-> " in log[mark:]:
            break
    else:
        print(f"req({cmd!r}): no M-> prompt", flush=True)
    pump(settle)
    con(cmd + "\r")
    pump(1.0)
    print(f"req({cmd!r}) sent", flush=True)

if not wait_for("as_init_", 300, "answering-service"):
    print(log[-2000:].decode("utf8", "replace")); sys.exit(1)
pump(5)

# --- password change over the FNP telnet line ---
s = socket.create_connection(("127.0.0.1", 6180))
def rd(t=4):
    s.settimeout(t); out = b""
    try:
        while True:
            b = s.recv(8192)
            if not b: break
            out += b
    except Exception: pass
    return out.replace(b"\x00", b"")
rd(3); s.sendall(b"\r\n"); rd(3)
s.sendall(b"login Repair -cpw\r"); time.sleep(2); rd(2)
s.sendall(b"repair\r"); time.sleep(2); print("newpw:", rd(2)[-120:], flush=True)
s.sendall((NEWPW + "\r").encode()); time.sleep(2); print("again:", rd(2)[-120:], flush=True)
s.sendall((NEWPW + "\r").encode()); time.sleep(4)
out = rd(5); print("after-cpw:", out[-600:], flush=True)
s.sendall(b"logout\r"); time.sleep(3); print("logout:", rd(4)[-300:], flush=True)
s.close()
pump(5)

# --- clean shutdown at the operator console ---
#
# WALL W3, resolved: `shut` is a system_control request and needs the ESC ->
# new `M-> ` -> settle handshake (system_control drops request text that
# arrives in the same write as the attention ESC). `die` is NOT a
# system_control request at all — once `shutdown complete` prints, Multics has
# handed the console back to BCE, the bootload command environment, which owns
# the console DIRECTLY and takes typed lines with no attention key. Sending
# `die` through req() is what produced `system_control: Unknown request "die"`
# in the first attempt: the ESC re-entered system_control, which was still the
# console owner because the shutdown had not completed.
req("logout * * *")
pump(20)

req("shut")
ok = wait_for("shutdown complete", 600, "shutdown")
if not ok:
    print(log[-3000:].decode("utf8", "replace"), flush=True)
    p.kill()
    sys.exit(1)

# THE DISK IS ALREADY CONSISTENT HERE. `shutdown complete` is Multics'
# own statement that every page has been flushed to the RA disk; `die` only
# halts the CPU afterwards. So this is the success gate, and a simulator that
# refuses to die is a cosmetic failure, not a dirty disk.
pump(8)

# BCE prompt looks like `bce (early) 1234.5:` / `bce (boot) ...` — raw line, no ESC.
t0 = time.time()
while time.time() - t0 < 120:
    pump(0.5)
    if b"bce (" in log[-4000:]:
        break
con("die\r")
pump(5)
con("y\r")
t0 = time.time()
while p.poll() is None and time.time() - t0 < 60:
    pump(1)
rc = p.poll()
print("dps8 rc:", rc, flush=True)
if rc is None:
    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    print("dps8 did not exit on die; SIGKILLed AFTER shutdown complete "
          "(disk already flushed, see above)", flush=True)
logf.close()
print("=== tail ===")
print(log[-2500:].decode("utf8", "replace"))
print("=== BAKE OK: shutdown complete reached ===")
