#!/usr/bin/env python3
"""fb-react.py — did the guest REACT? Measure it, never eyeball it.

Rule 9 says the framebuffer is the only proof a guest reacted. This turns
"the frame looks the same" into a number: given two frames (PNG files, or
two captures of a host-native station's `fb.shm`), report the count and
bounding box of pixels that changed, with regions you do not care about
(the mouse cursor sprite, an on-screen clock) masked out.

Why it exists: the fmtowns click streams (docs/lab/FMTOWNS-WAVE.md SS Pointer)
kept reporting "no visible reaction" from a human look at two PNGs. A click
that selects an icon can change a few hundred pixels; a clock glyph ticking
changes a few dozen. Only a masked, counted diff separates those.

  shot   --shm /path/fb.shm --out frame.png
  react  before.png after.png [--mask X,Y,W,H ...] [--min-count N]
  locate before.png after.png            (where did the changed blob land)

`react` exits 0 when the change is at or above --min-count (default 1),
1 otherwise, so it can gate a race runner's proof.
"""

from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import numpy as np  # noqa: E402
from PIL import Image  # noqa: E402


def shm_frame(path: str) -> Image.Image:
    import shmshot  # noqa: PLC0415  (one reader, not a second copy)

    w, h, stride, pixels = shmshot.read_frame(path)
    return Image.frombytes("RGB", (w, h), shmshot.to_rgb(w, h, stride, pixels))


def load(path: str) -> np.ndarray:
    return np.asarray(Image.open(path).convert("RGB"), dtype=np.int16)


def parse_mask(spec: str) -> tuple[int, int, int, int]:
    parts = [int(p) for p in spec.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("mask must be X,Y,W,H")
    return parts[0], parts[1], parts[2], parts[3]


def react(a: np.ndarray, b: np.ndarray, masks, thresh: int):
    if a.shape != b.shape:
        raise SystemExit(f"shape mismatch {a.shape} vs {b.shape}")
    diff = np.abs(a - b).max(axis=2) > thresh
    for x, y, w, h in masks:
        diff[y : y + h, x : x + w] = False
    count = int(diff.sum())
    if not count:
        return 0, None, diff
    ys, xs = np.nonzero(diff)
    box = (int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max()))
    return count, box, diff


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("shot", help="capture one frame from a host-native fb.shm")
    s.add_argument("--shm", required=True)
    s.add_argument("--out", required=True)

    for name in ("react", "locate"):
        r = sub.add_parser(name, help="count/box the pixels that changed between two frames")
        r.add_argument("before")
        r.add_argument("after")
        r.add_argument(
            "--mask",
            type=parse_mask,
            action="append",
            default=[],
            help="X,Y,W,H region to ignore (repeatable): cursor, clock",
        )
        r.add_argument("--thresh", type=int, default=16, help="per-channel delta that counts as changed")
        r.add_argument("--min-count", type=int, default=1, help="exit 0 only at or above this many changed px")
        r.add_argument("--out-mask", help="write the changed-pixel mask as a PNG")

    a = ap.parse_args()
    if a.cmd == "shot":
        shm_frame(a.shm).save(a.out)
        print(f"shot {a.out}")
        return 0

    count, box, diff = react(load(a.before), load(a.after), a.mask, a.thresh)
    if a.out_mask:
        Image.fromarray((diff * 255).astype("uint8")).save(a.out_mask)
    if box is None:
        print(f"changed={count} bbox=- verdict=NO-REACTION")
        return 1
    x0, y0, x1, y1 = box
    print(
        f"changed={count} bbox={x0},{y0}-{x1},{y1} "
        f"({x1 - x0 + 1}x{y1 - y0 + 1}) "
        f"verdict={'REACTION' if count >= a.min_count else 'BELOW-FLOOR'}"
    )
    return 0 if count >= a.min_count else 1


if __name__ == "__main__":
    sys.exit(main())
