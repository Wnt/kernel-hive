#!/usr/bin/env python3
"""Dump the framebuffer MAME publishes into a shm mapping as a PNG.

The exhibit's production capture path is `IRIX_CAPTURE=shm`: MAME runs
`-video none`, so there is no window and no X server to grab with ImageMagick.
Every "verify on the REAL framebuffer" rule on this tile still applies, so the
shm path needs its own screendump. This is it.

Also prints `mean sd` (and, with a crop, the crop's `sd`) because the boot /
login / desktop state machine on this exhibit is decided from those numbers —
see scripts/build-guests/irix/irix-park-desktop.sh for the measured signatures.

  shmpng.py <fb.shm> [out.png] [--crop WxH+X+Y]

Wire format: streamhost/streamhost/src/capture/shm.rs.
"""

import struct
import sys

import numpy as np
from PIL import Image

MAGIC = 0x31424649  # 'IFB1'
HEADER = 64


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    crop = next((a[len("--crop=") :] for a in sys.argv[1:] if a.startswith("--crop=")), None)
    path = args[0]
    out = args[1] if len(args) > 1 else None
    with open(path, "rb") as fh:
        blob = fh.read()
    magic, _ver, w, h = struct.unpack_from("<IIII", blob, 0)
    if magic != MAGIC or not (0 < w <= 4096 and 0 < h <= 4096):
        print("no valid frame header", file=sys.stderr)
        return 1
    need = HEADER + w * h * 4
    if len(blob) < need:
        print("mapping truncated", file=sys.stderr)
        return 1
    a = np.frombuffer(blob, dtype=np.uint8, count=w * h * 4, offset=HEADER).reshape(h, w, 4)
    rgb = a[:, :, [2, 1, 0]]  # stored BGRA
    f = rgb.astype(np.float32) / 255.0
    if out:
        # Before the --cursor early-return: `shmpng.py fb.shm out.png --cursor`
        # used to print the centroid and silently skip writing the PNG.
        Image.fromarray(rgb).save(out)
    if "--cursor" in sys.argv[1:]:
        # Where the pointer is, in EMULATED framebuffer pixels. IRIX's X cursor
        # is the only saturated red on a 4Dwm desktop, so a red-channel mask
        # finds it with no template matching. This is what makes open-loop
        # relative motion into CLOSED-LOOP positioning: drive a MOVEP, then read
        # back where the pointer actually landed instead of assuming it arrived.
        # Without it a button verb can be applied while a paced move is still
        # draining, and the press lands somewhere the gesture never intended.
        m = (rgb[:, :, 0] > 150) & (rgb[:, :, 1] < 100) & (rgb[:, :, 2] < 100)
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            print("- - 0")
            return 1
        print(f"{xs.mean():.1f} {ys.mean():.1f} {len(xs)}")
        return 0
    fields = [f"{w} {h}", f"{f.mean():.6f}", f"{f.std():.6f}"]
    if crop:
        wh, _, xy = crop.partition("+")
        cw, ch = (int(v) for v in wh.split("x"))
        cx, cy = (int(v) for v in xy.split("+"))
        c = f[cy : cy + ch, cx : cx + cw]
        fields.append(f"{c.std():.6f}")
    print(" ".join(fields))
    return 0


if __name__ == "__main__":
    sys.exit(main())
