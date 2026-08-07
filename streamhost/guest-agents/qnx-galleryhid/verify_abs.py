#!/usr/bin/env python3
# Absolute-tracking verification for the QNX gallery-hid abs-filter OUTPUT path.
# Injects Elo abs touches (the proven devi `abs` filter vehicle) and screenshots
# the Photon framebuffer between commands so we can see the cursor track.
import socket, json, subprocess, sys, time, os

DIR = "/data/vms/soltest/qnx-ghid-spike-3112"
CTRL = DIR + "/ctrl.sock"
QMP  = DIR + "/qmp.sock"

def ctrl(*args):
    c = socket.socket(socket.AF_UNIX); c.connect(CTRL)
    c.sendall(" ".join(str(a) for a in args).encode()); c.close()

def _qmp_conn():
    s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(QMP)
    f = s.makefile("rwb", buffering=0); f.readline()
    f.write(b'{"execute":"qmp_capabilities"}\n')
    while b"return" not in f.readline(): pass
    return s, f

def shot(name):
    s, f = _qmp_conn()
    ppm = "/tmp/_v.ppm"
    f.write(json.dumps({"execute":"screendump","arguments":{"filename":ppm}}).encode()+b"\n")
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: break
    s.close()
    out = DIR + "/V_" + name + ".png"
    with open(out, "wb") as o:
        subprocess.run(["pnmtopng", ppm], stdout=o, stderr=subprocess.DEVNULL, check=False)
    print("shot", out, os.path.getsize(out))

def move(x, y, status=3, reps=3):
    # status 3 = stream/move (position the cursor without a committed click)
    for _ in range(reps):
        ctrl("T", status, x, y); time.sleep(0.08)

def tap(x, y):
    ctrl("T", 1, x, y); time.sleep(0.15)   # down
    ctrl("T", 4, x, y); time.sleep(0.15)   # up

def drag(x0, y0, x1, y1, steps=8):
    ctrl("T", 1, x0, y0); time.sleep(0.15)              # down at start
    for i in range(1, steps+1):
        x = x0 + (x1 - x0) * i // steps
        y = y0 + (y1 - y0) * i // steps
        ctrl("T", 3, x, y); time.sleep(0.10)            # stream
    ctrl("T", 4, x1, y1); time.sleep(0.15)              # up at end

if __name__ == "__main__":
    op = sys.argv[1]
    if op == "move":
        move(int(sys.argv[2]), int(sys.argv[3]),
             status=int(sys.argv[4]) if len(sys.argv) > 4 else 3)
        shot(sys.argv[5] if len(sys.argv) > 5 else "move")
    elif op == "tap":
        tap(int(sys.argv[2]), int(sys.argv[3])); shot(sys.argv[4])
    elif op == "drag":
        drag(int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
        shot(sys.argv[6])
    elif op == "shot":
        shot(sys.argv[2])
