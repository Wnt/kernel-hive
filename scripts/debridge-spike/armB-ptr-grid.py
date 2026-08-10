#!/usr/bin/env python3
"""Measure and verify arm B's pointer COUNT GRID -- the SH_MAMESOCK_PTR_GRID map.

Run ON the box. Both subcommands drive the arm through its loopback input bench,
which feeds the SAME production input router a browser feeds, so what is measured
is what a visitor gets:

    armB-ptr-grid.py measure   # -> the left,top,right,bottom,cols,rows spec
    armB-ptr-grid.py verify    # -> per-target landing error, in counts

WHY A GRID AND NOT PIXELS. MAME's stkbd latches the 8-bit :ikbd MOUSEX/MOUSEY
ioport every 4 ticks of a 500 Hz timer, keeps only the DIRECTION of the change
and emits one quadrature cycle per latch. The ST pointer therefore moves in
fixed COUNT steps -- one count is ~9.7 surface px across and ~12.3 down -- and
the whole desktop is about 81 x 52 reachable positions. There is no hardware
cursor for the ctlsock module to close a loop against, so streamhost states its
MOVEA targets on that grid and lets the module's open-loop delta be a count
delta. Get the map wrong and the pointer is skewed; leave it out and the module
issues one count per PIXEL, overshoots tenfold and the pointer runs away.

MEASURE walks the pointer between known count targets and reads the cursor's
position off the published framebuffer, so the map is measured end to end rather
than derived from the emulator's geometry. VERIFY is the acceptance check: it
commands surface points and reports how far the cursor landed from each, in
counts -- under one count is exact, because one count is the finest step this
machine has.

Expect ~0.5 counts of error on a jump and 2-3 counts after a long walk: the
module paces one count per 8 emulated ms against a latch on its own 8 ms phase,
so a few percent of counts merge and are lost. That drift is bounded, not
cumulative: entering any screen edge carries a full-axis slam that re-pins the
guest and the model together, and 30 s of pointer silence re-homes outright.
"""

import socket
import subprocess
import sys
import time

RIG = "/data/vms/soltest/debridge-7f3a"
SHM = RIG + "/armB/fb.shm"
SHMPNG = "/data/vms/soltest/drawshm-9c1e/shmpng.py"
BENCH = ("127.0.0.1", 57932)
PARK = (880, 690)  # empty desktop, far from the menu bar and every icon


def bench(x, y, settle):
    with socket.create_connection(BENCH, timeout=5) as s:
        s.sendall(f"M {x} {y}\n".encode())
    time.sleep(settle)


def shot(out):
    subprocess.run(["python3", SHMPNG, SHM, out], check=True, capture_output=True)
    return out


def raw(path):
    px = subprocess.run(
        ["convert", path, "-depth", "8", "-colorspace", "sRGB", "rgb:-"],
        check=True,
        capture_output=True,
    ).stdout
    wh = subprocess.run(["identify", "-format", "%w %h", path], check=True, capture_output=True).stdout.split()
    return int(wh[0]), int(wh[1]), px


def changed(ref, cur, excl=None):
    w, h, a = raw(ref)
    _, _, b = raw(cur)
    out = []
    for y in range(h):
        row = y * w * 3
        for x in range(w):
            if excl and excl[0] <= x <= excl[2] and excl[1] <= y <= excl[3]:
                continue
            i = row + x * 3
            if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
                out.append((x, y))
    return out


def tip(pts):
    """The GEM arrow's hotspot: the topmost row's leftmost changed pixel."""
    if not pts:
        return None
    top = min(p[1] for p in pts)
    return (min(p[0] for p in pts if p[1] == top), top)


def probe(target, ref, excl, settle=3.0):
    bench(target[0], target[1], settle)
    return tip(changed(ref, shot(f"/tmp/armB-ptr-{target[0]}-{target[1]}.png"), excl))


def park_ref():
    """Park in a corner twice (the second is a no-op that lets the paced drain
    finish) and capture the frame every probe is differenced against."""
    bench(PARK[0], PARK[1], 6.0)
    bench(PARK[0], PARK[1], 3.0)
    return shot("/tmp/armB-ptr-ref.png"), (PARK[0] - 40, PARK[1] - 40, 10000, 10000)


def measure():
    """Fit surface = m*count + k from interior probes, then find the far clamps.

    Interior first, deliberately: a clamp tells you where an axis ENDS but not
    its scale, and the scale is what the fit needs. The clamps then give the
    grid's extent in counts without assuming the emulated raster's geometry.
    """
    ref, excl = park_ref()
    # The daemon must already be running SOME grid for these targets to be
    # count-shaped; the numbers below are relative, so an approximate one is
    # enough to bootstrap an exact one.
    fit = {}
    for axis, targets in (("x", (200, 500, 800)), ("y", (200, 400, 600))):
        pts = []
        for t in targets:
            p = probe((t, 400) if axis == "x" else (500, t), ref, excl)
            if p:
                pts.append((t, p[0] if axis == "x" else p[1]))
        if len(pts) >= 2:
            (t0, v0), (t1, v1) = pts[0], pts[-1]
            fit[axis] = (v1 - v0) / (t1 - t0), v0, t0
            print(f"  {axis}: {pts}  slope={(v1 - v0) / (t1 - t0):.3f}")
    lo = probe((0, 0), ref, excl, settle=8.0)
    hi = probe((10000, 10000), ref, excl, settle=8.0)
    print(f"  clamps: top-left={lo} bottom-right={hi}")
    if lo and hi and "x" in fit and "y" in fit:
        # One count is 4 ST px; recover it from the current spec's own scale.
        div_x = (hi[0] - lo[0]) / max(1, round((hi[0] - lo[0]) / 9.70))
        div_y = (hi[1] - lo[1]) / max(1, round((hi[1] - lo[1]) / 12.57))
        cols = round((hi[0] - lo[0]) / div_x) + 1
        rows = round((hi[1] - lo[1]) / div_y) + 1
        print(f"SH_MAMESOCK_PTR_GRID={lo[0]},{lo[1]},{hi[0]},{hi[1]},{cols},{rows}")
        print(f"MAME_CTL_SCREEN={cols}x{rows}")


def verify():
    ref, excl = park_ref()
    div = (9.70, 12.57)
    worst = 0.0
    for target in [
        (500, 300),
        (200, 200),
        (800, 600),
        (300, 650),
        (700, 160),
        (140, 700),
        (891, 150),
        (134, 692),
    ]:
        p = probe(target, ref, excl)
        if not p:
            print(f"target {target} -> NOT FOUND")
            continue
        ex, ey = p[0] - target[0], p[1] - target[1]
        cx, cy = ex / div[0], ey / div[1]
        worst = max(worst, abs(cx), abs(cy))
        print(
            f"target {target[0]:4d},{target[1]:4d} -> cursor {p[0]:4d},{p[1]:4d}"
            f"  err {ex:+4d},{ey:+4d} px = {cx:+5.2f},{cy:+5.2f} counts"
        )
    print(f"worst axis error: {worst:.2f} counts")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "measure":
        measure()
    elif cmd == "verify":
        verify()
    else:
        print(__doc__)
        sys.exit(2)
