#!/usr/bin/env python3
"""Report the bounding box of the pixels that changed between two frames.

The readback tool for an XOR/inverting guest cursor, where
scripts/dev/cursor-locate.py's exact-sprite match cannot work (it returns
AMBIGUOUS at every coordinate over a uniform background — see
docs/lab/VISION-WAVE.md §"the readback"). Two captures taken at two pointer
positions differ in exactly two places: where the cursor was and where it now
is. Pass the two frames plus, optionally, the previous frame's own bbox so the
old position can be excluded and the new one reported alone.

usage: fb-diff-bbox.py A.png B.png [--split]
       --split  report the two largest changed clusters separately (old/new
                cursor position) instead of one bbox over both.
"""

import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert("RGB"), dtype=np.int16)


def bbox(mask):
    ys, xs = np.nonzero(mask)
    if not len(ys):
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def report(name, b):
    x0, y0, x1, y1 = b
    print(
        f"{name}: bbox=({x0},{y0})-({x1},{y1}) size={x1 - x0 + 1}x{y1 - y0 + 1} "
        f"centroid=({(x0 + x1) / 2:.1f},{(y0 + y1) / 2:.1f})"
    )


def main(argv):
    split = "--split" in argv
    a, b = [x for x in argv[1:] if not x.startswith("--")][:2]
    d = np.abs(load(a) - load(b)).sum(axis=2) > 12
    whole = bbox(d)
    if whole is None:
        print("no change")
        return 1
    if not split:
        report("changed", whole)
        return 0
    # two clusters: split on the widest gap, along whichever axis separates them
    best = (0, None, None)  # gap, axis, cut
    for axis in (0, 1):  # 0 = split on x (columns), 1 = split on y (rows)
        idx = np.nonzero(d.any(axis=0 if axis == 0 else 1))[0]
        gaps = np.diff(idx)
        if len(gaps) and gaps.max() > best[0]:
            best = (int(gaps.max()), axis, int(idx[int(np.argmax(gaps))]))
    gap, axis, cut = best
    if cut is None or gap <= 4:
        report("changed (single cluster)", whole)
        return 0
    first, second = d.copy(), d.copy()
    if axis == 0:
        first[:, cut + 1 :] = False
        second[:, : cut + 1] = False
    else:
        first[cut + 1 :, :] = False
        second[: cut + 1, :] = False
    report("cluster A", bbox(first))
    report("cluster B", bbox(second))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
