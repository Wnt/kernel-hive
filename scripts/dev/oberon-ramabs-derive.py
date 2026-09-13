#!/usr/bin/env python3
"""oberon-ramabs-derive.py -- derive and write-test KH_RAMABS_ADDR for the oberon golden.

RE-RUN AFTER EVERY RE-BAKE (docs/lab/BEOS-ABSOLUTE-POINTER.md §3 says why: the
address is guest-physical and a golden restores RAM verbatim, so it is bound to
that checkpoint).

    oberon-ramabs-derive.py derive RIG            # 5 positions: screendump + 64 MB pmemsave, bias search
    oberon-ramabs-derive.py test   RIG ADDR...    # one QEMU start per candidate; the device's own
                                                  # connect-time probe is the write test, then a 5-target sweep

RIG needs qmp.sock and launch.sh (honours $EXTRA, $COLD). Locating is a diff
against RIG/ref.ppm -- the same frame with the pointer parked bottom-right --
because Native Oberon's arrow is drawn against whatever it sits over, so an
exact-match template bank needs one template per background (OBERON-WAVE.md
§Proofs) while a diff needs none. Hotspot is (0,0): the sprite's top-left IS
the pointer.

WHY THE SEARCH IS NOT JUST "x then y, little-endian". Oberon's INTEGER is 16
bits, its LONGINT 32, and the Oberon display coordinate system counts Y UP from
the bottom of the screen -- so the guest's own y may be `H-1 - y_screen`. All
four (width, field order, y direction) combinations are searched and the
surviving family is reported, because a transposed or flipped coordinate tracks
plausibly and lands wrong.
"""

import json
import os
import socket
import subprocess
import sys
import time

import numpy as np
from PIL import Image

RAM = 0x4000000  # 64 MB, the station's whole RAM


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

    def rel(self, dx, dy, step=126):
        """1.5 px per PS/2 unit, no acceleration (OBERON-WAVE.md) -- even steps only."""
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
            time.sleep(0.01)

    def shot(self, p):
        self.cmd("screendump", filename=p, format="ppm")

    def dump(self, p):
        self.cmd("pmemsave", val=0, size=RAM, filename=p)


HOME = (900, 300)  # where the reference frame's pointer is parked -- NOT a proof target


def locator(rig, q=None):
    """Diff-based sprite locator. The reference is this same desktop with the
    pointer parked at the CENTRE, not in a corner: the five-target proof uses
    all four corners, so a corner reference would have to mask the very pixels
    the proof is reading. Only the 32x32 box around the parked sprite is masked.
    Native Oberon draws its arrow against whatever it sits over -- blue on the
    grey desktop, black on a text viewer's white -- so an exact-match template
    bank needs one template per background while a diff needs none
    (docs/lab/OBERON-WAVE.md §Proofs). Hotspot is (0,0): the sprite's top-left
    IS the pointer."""
    ref_path = os.path.join(rig, "ref.ppm")
    if q is not None:
        q.rel(-2000, -2000)  # pin to (0,0)
        q.rel(HOME[0] * 2 // 3, HOME[1] * 2 // 3)  # 1.5 px/unit above the guest's
        time.sleep(0.6)  # acceleration threshold
        q.shot(ref_path)
    ref = np.asarray(Image.open(ref_path).convert("RGB")).astype(int)

    def locate(p):
        a = np.asarray(Image.open(p).convert("RGB")).astype(int)
        d = np.abs(a - ref).sum(2) > 0
        d[HOME[1] - 4 : HOME[1] + 32, HOME[0] - 4 : HOME[0] + 32] = False
        ys, xs = np.nonzero(d)
        return (int(xs.min()), int(ys.min())) if len(xs) else None

    return locate


def scan(rig, dt, esz, expected, tol):
    """Every word that tracks `expected` with a CONSTANT offset. Independent per
    word, NOT as an adjacent pair: Native Oberon does not keep x and y in one
    conventional pair, and a pair search that assumes it finds nothing. `tol`
    absorbs the locator's own +-1 px on x -- the arrow's leftmost column is
    drawn or not depending on the background it sits over, so xs.min() is one
    pixel left of the guest's x over some backgrounds (that is what made the
    first pair search return zero hits while the coordinate was plainly there)."""
    base = np.fromfile(f"{rig}/m0.bin", dtype=dt).astype(np.int32)
    bias = base - expected[0]
    ok = np.abs(bias) < 4096
    del base
    for i in range(1, len(expected)):
        d = np.fromfile(f"{rig}/m{i}.bin", dtype=dt).astype(np.int32)
        ok &= np.abs((d - expected[i]) - bias) <= tol
        del d
    return [(int(j) * esz, int(bias[j])) for j in np.nonzero(ok)[0]]


def derive(rig, height=1024, width=1280):
    q = Q(rig)
    q.cmd("cont")
    locate = locator(rig, q)
    moves = [(-500, -400), (300, 100), (-200, 200), (-250, -350), (400, 250)]
    loc = []
    for i, (dx, dy) in enumerate(moves):
        q.rel(dx, dy)
        time.sleep(0.6)
        q.shot(f"{rig}/d{i}.ppm")
        q.dump(f"{rig}/m{i}.bin")
        pos = locate(f"{rig}/d{i}.ppm")
        print(i, (dx, dy), pos, flush=True)
        if pos is None:
            sys.exit("pointer not located (did the guest resume?)")
        loc.append(pos)

    lx = [p[0] for p in loc]
    ly = [p[1] for p in loc]
    for dt, esz, w in (("<i2", 2, 16), ("<i4", 4, 32)):
        X = {a: b for a, b in scan(rig, dt, esz, lx, 1)}
        Y = {a: b for a, b in scan(rig, dt, esz, ly, 0)}
        U = {a: b for a, b in scan(rig, dt, esz, [-v for v in ly], 0)}
        print(f"i{w}: x-words {len(X)} y-words {len(Y)} yup-words {len(U)}", flush=True)
        for a in sorted(X):
            if a + esz in Y:
                print(f"CAND addr=0x{a:08x} layout=point{w}le bias={X[a]},{Y[a + esz]}", flush=True)
            if a + esz in U:
                print(f"CAND addr=0x{a:08x} layout=point{w}le_yup bias={X[a]},{U[a + esz]}", flush=True)
        for a in sorted(Y):
            if a + esz in X:
                print(f"CAND addr=0x{a:08x} layout=point{w}le_yx bias={Y[a]},{X[a + esz]}", flush=True)
        for a in sorted(U):
            if a + esz in X:
                print(f"CAND addr=0x{a:08x} layout=point{w}le_yup_yx bias={U[a]},{X[a + esz]}", flush=True)


TARGETS = [(20, 20), (1250, 20), (20, 1000), (1250, 1000), (640, 512)]


def test(rig, cands, layout=None, width=1280, height=1024):
    locate = locator(rig)
    for addr in cands:
        ptr = os.path.join(rig, "ptr.sock")
        if os.path.exists(ptr):
            os.remove(ptr)
        extra = (
            f"-chardev socket,id=ptr0,path={ptr},server=on,wait=off "
            f"-device kh-ramabs,chardev=ptr0,addr={addr},layout={layout},"
            f"width={width},height={height},nudge-units=1,nudge-px=1"
        )
        subprocess.run([os.path.join(rig, "launch.sh")], env=dict(os.environ, EXTRA=extra), capture_output=True)
        time.sleep(2.0)
        q = Q(rig)
        q.cmd("cont")
        time.sleep(1.0)
        p = socket.socket(socket.AF_UNIX)
        p.connect(ptr)
        pf = p.makefile("rw")
        pf.readline()
        time.sleep(2.0)
        pf.write("1 STAT\n")
        pf.flush()
        stat = pf.readline().strip()
        res = []
        if "verified=yes" in stat:
            for i, (x, y) in enumerate(TARGETS):
                pf.write(f"{i + 2} MOVEA {x} {y}\n")
                pf.flush()
                pf.readline()
                time.sleep(0.5)
                q.cmd("screendump", filename=f"{rig}/w{i}.ppm", format="ppm")
                res.append(((x, y), locate(f"{rig}/w{i}.ppm")))
        print(addr, "|", stat[:200], "|", res, flush=True)
        p.close()


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "derive":
        derive(sys.argv[2])
    elif len(sys.argv) >= 4 and sys.argv[1] == "test":
        # test RIG LAYOUT ADDR...
        test(sys.argv[2], sys.argv[4:], layout=sys.argv[3])
    else:
        sys.exit(__doc__)
