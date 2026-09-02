#!/usr/bin/env python3
"""pcgeos-ramabs-derive.py -- derive and write-test KH_RAMABS_ADDR for the pcgeos golden.

RE-RUN AFTER EVERY RE-BAKE of the pcgeos golden (docs/lab/BEOS-ABSOLUTE-POINTER.md
says why: `loadvm golden` restores RAM verbatim, so the address the kh-ramabs
device writes is bound to that checkpoint). Runs ON THE BOX against a sandbox rig
that mirrors streamhost/stations/pcgeos/qemu-streamhost.sh: same device set, own
paths, a `launch.sh` in RIG that honours $EXTRA and passes `-loadvm golden -S`
when the tag exists.

    python3 pcgeos-ramabs-derive.py derive RIG          # 5 positions: screendump + pmemsave 1 MB, bias search
    python3 pcgeos-ramabs-derive.py test RIG ADDR...    # one QEMU start per candidate; the device's own
                                                        # connect-time probe is the write test; then a MOVEA sweep

`derive` expects RIG/qmp.sock (guest running, golden restored) and RIG/s1.ppm: a
screendump of the fixture with the pointer parked at the right edge. Locating is
a diff against that reference rather than cursor-locate.py, because GEOS repaints
nothing but the taskbar clock (masked, y >= 575) and the parked sprite still
leaves 3 px at x=799 (masked too). Motion is 1:1 only below GEOS's acceleration
threshold: 2-unit steps 8 ms apart (20-unit packets move ~1.4 px per unit).

Exactly ONE candidate must verify. If more do, stop and escalate.
"""

import json
import os
import socket
import subprocess
import sys
import time

import numpy as np
from PIL import Image


class Q:
    def __init__(self, rig):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(os.path.join(rig, "qmp.sock"))
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, ex, **a):
        self.f.write(json.dumps({"execute": ex, "arguments": a}) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "event" not in r:
                return r

    def rel(self, dx, dy, step=2):
        while dx or dy:
            sx = max(-step, min(step, dx))
            sy = max(-step, min(step, dy))
            dx -= sx
            dy -= sy
            self.cmd(
                "input-send-event",
                events=[
                    {"type": "rel", "data": {"axis": "x", "value": sx}},
                    {"type": "rel", "data": {"axis": "y", "value": sy}},
                ],
            )
            time.sleep(0.008)

    def shot(self, p):
        self.cmd("screendump", filename=p, format="ppm")

    def dump(self, p):
        self.cmd("pmemsave", val=0, size=0x100000, filename=p)


def locator(rig):
    ref = np.asarray(Image.open(os.path.join(rig, "s1.ppm")).convert("RGB")).astype(int)

    def locate(p):
        a = np.asarray(Image.open(p).convert("RGB")).astype(int)
        d = np.abs(a - ref).sum(2) > 0
        d[575:, :] = False
        d[446:456, 795:] = False
        ys, xs = np.nonzero(d)
        return (int(xs.min()), int(ys.min())) if len(xs) else None

    return locate


def derive(rig):
    q = Q(rig)
    locate = locator(rig)
    moves = [(-200, -150), (300, 100), (100, 200), (-250, 50), (-100, -250)]
    loc = []
    for i, (dx, dy) in enumerate(moves):
        q.rel(dx, dy)
        time.sleep(0.5)
        q.shot(f"{rig}/d{i}.ppm")
        q.dump(f"{rig}/m{i}.bin")
        pos = locate(f"{rig}/d{i}.ppm")
        print(i, (dx, dy), pos)
        if pos is None:
            sys.exit("pointer not located; is s1.ppm a parked-pointer reference of THIS golden?")
        loc.append(pos)
    dumps = [np.fromfile(f"{rig}/m{i}.bin", dtype="<i2") for i in range(len(moves))]
    n = len(dumps[0])
    ok = np.ones(n - 1, bool)
    bx = dumps[0][0 : n - 1].astype(int) - loc[0][0]
    by = dumps[0][1:n].astype(int) - loc[0][1]
    for d, (lx, ly) in zip(dumps[1:], loc[1:]):
        ok &= (d[0 : n - 1].astype(int) - lx == bx) & (d[1:n].astype(int) - ly == by)
    ok &= (np.abs(bx) < 64) & (np.abs(by) < 64)
    for idx in np.nonzero(ok)[0]:
        vals = [(int(d[idx]), int(d[idx + 1])) for d in dumps]
        print(f"CAND addr=0x{idx * 2:06x} layout=point16le bias=({bx[idx]},{by[idx]}) vals={vals}")


def test(rig, cands):
    locate = locator(rig)
    for addr in cands:
        ptr = os.path.join(rig, "ptr.sock")
        if os.path.exists(ptr):
            os.remove(ptr)
        extra = (
            f"-chardev socket,id=ptr0,path={ptr},server=on,wait=off "
            f"-device kh-ramabs,chardev=ptr0,addr={addr},layout=point16le,"
            "width=800,height=600,nudge-units=1,nudge-px=1"
        )
        subprocess.run([os.path.join(rig, "launch.sh")], env=dict(os.environ, EXTRA=extra), capture_output=True)
        time.sleep(1.5)
        q = Q(rig)
        q.cmd("cont")
        time.sleep(1.0)
        p = socket.socket(socket.AF_UNIX)
        p.connect(ptr)
        pf = p.makefile("rw")
        pf.readline()  # HELLO; the device starts its write probe now
        time.sleep(1.5)
        pf.write("1 STAT\n")
        pf.flush()
        stat = pf.readline().strip()
        res = []
        if "verified=yes" in stat:
            for i, (x, y) in enumerate([(100, 100), (700, 500), (20, 560), (780, 30), (400, 300)]):
                pf.write(f"{i + 2} MOVEA {x} {y}\n")
                pf.flush()
                pf.readline()
                time.sleep(0.4)
                q.cmd("screendump", filename=f"{rig}/w{i}.ppm", format="ppm")
                res.append(((x, y), locate(f"{rig}/w{i}.ppm")))
        print(addr, "|", stat[:160], "|", res, flush=True)
        p.close()


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "derive":
        derive(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "test":
        test(sys.argv[2], sys.argv[3:])
    else:
        sys.exit(__doc__)
