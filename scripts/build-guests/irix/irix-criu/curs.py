#!/usr/bin/env python3
"""Print the emulated pointer position as "x y n" out of the shm framebuffer.

The IRIX cursor is the only bright red object on an SGI-blue 4Dwm desktop, so a
colour threshold locates it without any guest cooperation. This is the liveness
probe the CRIU restore clock stops on: the pointer has MOVED in a real capture,
which no amount of "the process exists" can fake.

Prints "none" when no cursor-coloured pixels are present (a black or blanked
framebuffer), so a caller can tell "not drawn yet" from "drawn, unmoved".
"""

import struct
import sys

import numpy as np

with open(sys.argv[1], "rb") as fh:
    buf = fh.read()
w, h = struct.unpack_from("<II", buf, 8)
a = np.frombuffer(buf, dtype=np.uint8, count=w * h * 4, offset=64).reshape(h, w, 4)
r = a[:, :, 2].astype(int)
g = a[:, :, 1].astype(int)
b = a[:, :, 0].astype(int)
ys, xs = np.nonzero((r > 150) & (g < 90) & (b < 90))
print(f"{int(xs.mean())} {int(ys.mean())} {len(xs)}" if len(xs) else "none")
