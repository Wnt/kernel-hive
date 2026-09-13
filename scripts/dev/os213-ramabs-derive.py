#!/usr/bin/env python3
"""os213-ramabs-derive.py -- find OS/2 1.3's own pointer coordinate in guest RAM.

The os213 variant of `pcgeos-ramabs-derive.py` (read that one and
docs/lab/BEOS-ABSOLUTE-POINTER.md first; the mechanism and the
re-run-after-every-re-bake rule are identical). Three differences that matter:

* It dumps the WHOLE 16 MB of guest RAM, not the first 1 MB: OS/2 1.3 is a
  protected-mode system and its pointer copies live above the real-mode area
  (measured candidates at 0x10fe20 as well as 0x19514).
* It searches FOUR encodings, because Presentation Manager's own coordinate
  space has its origin at the BOTTOM-left: x,y and y,x order, and y both as
  the screen row and as (479 - row). The winning encoding on this guest is
  plain x,y with bias (0,0) -- the guest holds the exact screen pixel, and the
  PM arrow's hotspot is its top-left tip, so the sprite origin IS the pointer.
* Its locator picks the DENSEST 14x22 window of changed pixels rather than the
  bounding box of every changed pixel. The PM pointer is XOR-drawn and fast
  relative motion leaves dashed diagonal trails across the desktop; a
  bounding-box locator reports the pointer frozen because the trail dominates.
  Even so, settle between moves -- see docs/lab/OS213-WAVE.md.

Runs ON THE BOX against /data/vms/sandbox/os213-ptr/ramabs (RIG below), whose
launch.sh mirrors streamhost/stations/os213/qemu-streamhost.sh on
/opt/qemu-beos/bin/qemu-system-x86_64 and honours $EXTRA and COLD=1.

    python3 os213-ramabs-derive.py        # prints CAND-<encoding> addr=... bias=... vals=...

Then arm each candidate with
`-device kh-ramabs,chardev=ptr0,addr=<a>,layout=point16le,width=640,height=480,nudge-units=1,nudge-px=1`
and read the device's own connect-time write probe (`STAT` -> `verified=yes`).
Exactly ONE candidate must verify; if more do, stop and escalate.
"""

import contextlib
import json
import os
import socket
import sys
import time

import numpy as np
from PIL import Image

RIG = "/data/vms/sandbox/os213-ptr/ramabs"


class Q:
    def __init__(self, rig=RIG):
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
                if "error" in r:
                    raise SystemExit(f"{ex} {a} -> {r['error']}")
                return r

    def rel(self, dx, dy, step=1, gap=0.004):
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
            time.sleep(gap)

    def shot(self, p):
        self.cmd("screendump", filename=p, format="ppm")

    def dump(self, p):
        self.cmd("pmemsave", val=0, size=0x1000000, filename=p)


def locate_in(ref, p):
    a = np.asarray(Image.open(p).convert("RGB")).astype(int)
    d = (np.abs(a - ref).sum(2) > 0).astype(np.int32)
    H, W = d.shape
    ii = np.zeros((H + 1, W + 1), np.int32)
    ii[1:, 1:] = d.cumsum(0).cumsum(1)
    wh, ww = 22, 14
    win = ii[wh:, ww:] - ii[:-wh, ww:] - ii[wh:, :-ww] + ii[:-wh, :-ww]
    if win.max() < 20:
        return None
    fy, fx = np.unravel_index(int(win.argmax()), win.shape)
    sub = d[fy : fy + wh, fx : fx + ww]
    ys, xs = np.nonzero(sub)
    return (int(fx + xs.min()), int(fy + ys.min()), int(win.max()))


def locator(rig, q=None):
    ref = os.path.join(rig, "ref.ppm")
    if q is not None:
        q.rel(2000, 2000, step=20, gap=0.002)
        time.sleep(0.8)
        q.shot(ref)
    r = np.asarray(Image.open(ref).convert("RGB")).astype(int)
    return lambda p: locate_in(r, p)


def derive():
    q = Q()
    with contextlib.suppress(SystemExit):  # already running after a cold boot
        q.cmd("cont")
    locate = locator(RIG, q)
    # from the bottom-right park, walk to five spread positions with 1-unit events
    moves = [(-500, -700), (200, 300), (-100, -200), (300, -100), (-250, 400)]
    loc = []
    dumps = []
    for i, (dx, dy) in enumerate(moves):
        q.rel(dx, dy)
        time.sleep(0.6)
        q.shot(f"{RIG}/d{i}.ppm")
        q.dump(f"{RIG}/m{i}.bin")
        p = locate(f"{RIG}/d{i}.ppm")
        print(i, (dx, dy), p, flush=True)
        if p is None:
            sys.exit("pointer not located")
        loc.append((p[0], p[1]))
    dumps = [np.fromfile(f"{RIG}/m{i}.bin", dtype="<i2").astype(np.int32) for i in range(len(moves))]
    n = len(dumps[0])
    X = [np.array([l[0] for l in loc]), np.array([l[1] for l in loc])]

    def track(target):
        b = dumps[0] - target[0]
        ok = np.ones(n, bool)
        for d, t in zip(dumps[1:], target[1:]):
            ok &= (d - t) == b
        ok &= np.abs(b) < 4096
        return ok, b

    okx, bx = track(X[0])
    oky, by = track(X[1])
    okyn, byn = track(-X[1])
    # also half-scale y (driver may store y in a doubled space)
    oky2, by2 = track(X[1] * 2)
    okyn2, byn2 = track(-X[1] * 2)
    print(
        f"counts x={okx.sum()} y={oky.sum()} yneg={okyn.sum()} y2={oky2.sum()} yneg2={okyn2.sum()}",
        flush=True,
    )

    def pairs(name, oky_, by_):
        idx = np.nonzero(okx[:-1] & oky_[1:])[0]
        for i in idx[:60]:
            vals = [(int(d[i]), int(d[i + 1])) for d in dumps]
            print(f"CAND-{name} addr=0x{i * 2:07x} bias=({bx[i]},{by_[i + 1]}) vals={vals}")
        print(f"pairs-{name}={len(idx)}")

    pairs("xy", oky, by)
    pairs("xyneg", okyn, byn)
    pairs("xy2", oky2, by2)
    pairs("xyneg2", okyn2, byn2)
    # reversed order (y then x)
    idx = np.nonzero(oky[:-1] & okx[1:])[0]
    for i in idx[:30]:
        vals = [(int(d[i]), int(d[i + 1])) for d in dumps]
        print(f"CAND-yx addr=0x{i * 2:07x} bias=({by[i]},{bx[i + 1]}) vals={vals}")
    print(f"pairs-yx={len(idx)}")
    np.save(f"{RIG}/okx.npy", okx)
    np.save(f"{RIG}/oky.npy", oky)
    np.save(f"{RIG}/okyn.npy", okyn)
    for nm, arr in (("x", okx), ("y", oky), ("yneg", okyn), ("y2", oky2), ("yneg2", okyn2)):
        ii = np.nonzero(arr)[0]
        print(nm, "addrs:", [hex(int(i) * 2) for i in ii[:40]])


if __name__ == "__main__":
    derive()
