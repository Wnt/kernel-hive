#!/usr/bin/env python3
"""Closed-loop absolute pointer for the IRIX-in-MAME install rig.

IRIX applies pointer acceleration (~1.5x observed), and the only motion channel
that reaches the guest is XTest RELATIVE motion, so an open-loop "move by dx"
lands far from where you asked. This drives the cursor to an absolute position
by measuring where it actually is, from real framebuffer snapshots:

  * home()    slam the cursor into the (0,0) corner -- clamping makes this exact
              regardless of acceleration
  * locate()  jiggle by a known offset, diff two MAME snapshots, and read the
              cursor's top-left (= the arrow hotspot) out of the changed bbox
  * moveto()  home, jump using the measured gain, then correct until within
              tolerance

Subcommands:
  point.py locate                     print the cursor position
  point.py moveto X Y                 move to (X, Y)
  point.py click X Y                  moveto then left-click
  point.py drag X1 Y1 X2 Y2           press at 1, move to 2, release (SGI menus)
  point.py shot OUT.png               grab a framebuffer snapshot
"""

import os
import subprocess
import sys
import time

import numpy as np
from PIL import Image

D = os.environ.get("IRIX_APPS_DIR", "/data/vms/soltest/irix-apps")
DISPLAY = os.environ.get("IRIX_APPS_DISPLAY", ":41")
RELMOVE = os.environ.get("IRIX_RELMOVE", "/data/vms/soltest/irix-mame/relmove")
SNAPDIR = os.path.join(D, "snap")
CMD = os.path.join(D, "irix_cmd")
STEP_US = os.environ.get("IRIX_RELMOVE_US", "1500")
TOL = 3
SETTLE = float(os.environ.get("IRIX_POINTER_SETTLE", "0.8"))


def send(line):
    with open(CMD, "a") as f:
        f.write(line + "\n")


def relmove(dx, dy, step_us=STEP_US):
    if dx == 0 and dy == 0:
        return
    env = dict(os.environ, DISPLAY=DISPLAY)
    subprocess.run([RELMOVE, str(int(dx)), str(int(dy)), str(step_us)], env=env, check=True)


def snaps():
    """MAME writes snapshots into <snapdir>/<machine>/NNNN.png."""
    out = []
    for root, _dirs, files in os.walk(SNAPDIR):
        out += [os.path.join(root, f) for f in files if f.endswith(".png")]
    return sorted(out)


def snapshot(timeout=60):
    """Ask MAME for a framebuffer snapshot and return it as an RGB array."""
    before = set(snaps())
    send("SNAP")
    deadline = time.time() + timeout
    while time.time() < deadline:
        new = set(snaps()) - before
        if new:
            path = sorted(new)[-1]
            time.sleep(0.3)  # let MAME finish writing
            return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16), path
        time.sleep(0.25)
    raise RuntimeError("MAME produced no snapshot")


def find_red(img, near=None):
    """Locate the IRIX pointer by colour.

    The 4Dwm cursor is bright red on a desktop that is otherwise SGI blue and
    grey, so a single snapshot is enough -- no jiggle-and-diff, no ambiguity
    from windows repainting underneath. Returns the top-left of the largest red
    cluster, which is the arrow's tip (its hotspot).
    """
    r = img[:, :, 0]
    g = img[:, :, 1]
    b = img[:, :, 2]
    mask = (r > 140) & (g < 110) & (b < 110) & (r - np.maximum(g, b) > 60)
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return None
    # Densest 16px cell wins -- unless a hint is given, in which case take the
    # cell NEAREST the hint. Dialogs draw red icons that are bigger than the
    # cursor (the "Critical System Error" box has one), so density alone lies.
    key = (ys // 16).astype(np.int32) * 10000 + (xs // 16).astype(np.int32)
    vals, counts = np.unique(key, return_counts=True)
    if near is None:
        peak = vals[int(np.argmax(counts))]
    else:
        cys = (vals // 10000) * 16 + 8
        cxs = (vals % 10000) * 16 + 8
        d = (cxs - near[0]) ** 2 + (cys - near[1]) ** 2
        peak = vals[int(np.argmin(d))]
    cy, cx = (peak // 10000) * 16 + 8, (peak % 10000) * 16 + 8
    near = (np.abs(ys - cy) < 24) & (np.abs(xs - cx) < 24)
    ys, xs = ys[near], xs[near]
    return int(xs.min()), int(ys.min())


def locate_stable(tries=6, near=None):
    """Read the cursor twice and only trust a position that stopped moving."""
    prev = locate(near=near)
    for _ in range(tries):
        cur = locate(near=near)
        if abs(cur[0] - prev[0]) <= 1 and abs(cur[1] - prev[1]) <= 1:
            return cur
        prev = cur
    return prev


def locate(retries=3, settle=SETTLE, near=None):
    """Return the current cursor hotspot.

    `settle` matters: XTest motion reaches the guest only as fast as MAME polls
    SDL and IRIX redraws, so a snapshot taken immediately after a relmove still
    shows the OLD cursor. Every read waits for the guest to catch up.
    """
    time.sleep(settle)
    for _ in range(retries):
        img, _ = snapshot()
        pos = find_red(img, near)
        if pos is not None:
            return pos
        time.sleep(0.5)
    raise RuntimeError("cursor not found: no red cursor cluster in the frame")


def home():
    relmove(-2400, -2400, step_us=700)
    return 0, 0


def moveto(tx, ty, gain=1.5, tries=8, home_first=True):
    """Drive the cursor to an absolute (tx, ty).

    home_first=False keeps the cursor where it is (mandatory while a button is
    held down for an SGI press-drag-release menu -- homing would drag the
    pointer out of the menu and cancel it).
    """
    if home_first:
        home()
        relmove(tx / gain, ty / gain)
    pos = locate_stable(near=(tx, ty))
    for i in range(tries):
        ex, ey = tx - pos[0], ty - pos[1]
        if abs(ex) <= TOL and abs(ey) <= TOL:
            print(f"at ({pos[0]},{pos[1]}) after {i} corrections (gain={gain:.2f})")
            return pos
        if i == 0 and tx > 200 and pos[0] > 20:
            measured = pos[0] / (tx / gain)
            if 0.5 < measured < 4:
                gain = measured
        # Small corrections are below IRIX's acceleration threshold: 1:1.
        step = 1.0 if max(abs(ex), abs(ey)) < 12 else gain
        relmove(ex / step, ey / step)
        pos = locate_stable(near=(tx, ty))
    print(f"WARN: settled at ({pos[0]},{pos[1]}), wanted ({tx},{ty})")
    return pos


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "locate":
        print(locate())
    elif cmd == "moveto":
        moveto(int(argv[2]), int(argv[3]))
    elif cmd == "drag_to":  # move with the button already held (menu navigation)
        moveto(int(argv[2]), int(argv[3]), home_first=False)
    elif cmd == "click":
        moveto(int(argv[2]), int(argv[3]))
        send("CLICK1")
    elif cmd == "drag":
        moveto(int(argv[2]), int(argv[3]))
        send("DOWN1")
        time.sleep(1.0)
        relmove((int(argv[4]) - int(argv[2])) / 1.5, (int(argv[5]) - int(argv[3])) / 1.5)
        time.sleep(1.0)
        send("UP1")
    elif cmd == "shot":
        _, path = snapshot()
        subprocess.run(["cp", path, argv[2]], check=True)
        print(argv[2])
    else:
        print(f"unknown subcommand {cmd}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
