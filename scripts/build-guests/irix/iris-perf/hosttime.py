#!/usr/bin/env python3
"""hosttime.py — HOST wall-clock of a fixed IRIX workload over the kiosk's SCC
telnet channel (runs INSIDE the kiosk, next to iexec.py). Guest-reported seconds
are not trusted on Iris: its IRIX clock was seen standing still through a
CPU-bound loop, so /bin/time under-reports. This stamps host time when the
START and END marker lines come back on the serial line."""

import re
import sys
import time

sys.path.insert(0, "/root")
import iexec

LOOP = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
# unwedge: whatever the last client left (csh, a stuck sh, a running awk), get
# back to the getty's login prompt before iexec's login dance.
pre = iexec.Term(timeout=60)
pre.s.sendall(b"\x03")
time.sleep(0.5)
for _ in range(6):
    pre.pump()
    if re.search(r"login:\s*$", pre.buf):
        break
    pre.send("exit")
    time.sleep(1.2)
pre.pump()
print("PRE:", repr(pre.buf[-120:]))
pre.s.close()
time.sleep(6)
_orig = iexec.Term._ensure_sh


def _ensure_sh(self):
    # root's .login runs tset and asks "TERM = (vt100)"; answer it with a bare
    # Enter before the shell probe, or the probe becomes the terminal type.
    for _ in range(10):
        time.sleep(0.8)
        self.pump()
        if "TERM =" in self.buf[-80:]:
            self.send("")
            time.sleep(1.0)
            self.pump()
            break
    return _orig(self)


iexec.Term._ensure_sh = _ensure_sh
t = iexec.Term(timeout=600)
try:
    t.login()
except RuntimeError as e:
    print("LOGIN-FAIL:", e)
    print("BUF:", repr(t.buf[-700:]))
    sys.exit(1)
cmd = f"echo HT_S; awk 'BEGIN{{s=0;for(i=0;i<{LOOP};i++)s+=(i*i)%7;print s}}'; echo HT_E"
t0 = time.time()
t.run("true")
noop = round(time.time() - t0, 2)
t.buf = ""
t.send(cmd)
ts = te = None
t0 = time.time()
while time.time() - t0 < 240:
    t.pump()
    if ts is None and re.search(r"HT_S\r?\n", t.buf):
        ts = time.time()
    if ts is not None and re.search(r"\r?\nHT_E\r?\n", t.buf):
        te = time.time()
        break
    time.sleep(0.01)
host_s = None if te is None else round(te - ts, 2)
print(f"loop={LOOP} host_s={host_s} noop_run_s={noop}")
if te is None:
    print("BUF:", repr(t.buf[-500:]))
t.send("exit")
time.sleep(0.5)
t.send("exit")
