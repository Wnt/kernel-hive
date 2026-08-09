#!/usr/bin/env python3
"""Draw FSN's landscape as an IRIX FTI icon program.

The IRIX icon language has no raster primitive and the desktop draws an icon
into 50x50 screen pixels from a 16-colour table in which every other colour is
a screen-aligned 2x2 dither of two of those sixteen. A direct transcription of
FSN's own Fsn.icon (85x67 SGI RGB) therefore lands as per-pixel speckle -- it
was built, rendered on the guest and rejected on the framebuffer. What survives
at 50 px is FSN's COMPOSITION: light sky, dark green field, a white pedestal
slab, and the ranked colour bars of the Jurassic Park landscape.

Colour indices are the ones measured on this exhibit (see docs/guests/irix.md):
0..15 are the pure IRIS GL colours, negative indices are dithers.
"""

import sys

SKY = -38  # dither(blue, cyan)   -> light blue
SKY2 = 6  # pure cyan            -> haze above the horizon
FAR = -2  # dither(black, green) -> dark green far field
SLAB = 7  # white
SLAB_SIDE = 8  # gray
FRAME = "outlinecolor"

# x, width, height above the slab, body colour, top-face colour
BARS = [
    (18, 5, 30, 1, 9),
    (24, 4, 18, 3, 3),
    (29, 5, 44, 3, 3),
    (35, 4, 26, 7, 15),
    (40, 5, 36, 4, 12),
    (46, 4, 20, 5, 13),
    (51, 6, 50, 3, 3),
    (58, 4, 28, 1, 9),
    (63, 5, 38, 4, 12),
    (69, 4, 22, 5, 13),
    (74, 5, 32, 1, 9),
]

X0, X1, Y0, Y1 = 6.0, 94.0, 12.0, 88.0
HORIZON = 62.0
SLAB_TOP = 30.0


def quad(f, color, x0, y0, x1, y1):
    f.write(f"\t\tcolor({color});\n\t\tbgnpolygon();\n")
    for vx, vy in ((x0, y0), (x1, y0), (x1, y1), (x0, y1)):
        f.write(f"\t\t\tvertex({vx:.2f}, {vy:.2f});\n")
    f.write("\t\tendpolygon();\n")


def main(out):
    with open(out, "w") as f:
        f.write("#\tFSN -- the landscape from SGI's File System Navigator.\n")
        # The desktop drops an icon program's FIRST colour() call, so the
        # opening quad is emitted twice; the stale one is overdrawn in place.
        quad(f, SKY, X0, HORIZON, X1, Y1)
        quad(f, SKY, X0, HORIZON, X1, Y1)
        quad(f, SKY2, X0, HORIZON, X1, HORIZON + 4)
        quad(f, FAR, X0, Y0, X1, HORIZON)
        # the ranked pedestals
        for x, w, h, body, top in BARS:
            quad(f, body, x, SLAB_TOP, x + w, SLAB_TOP + h)
            quad(f, top, x, SLAB_TOP + h - 3, x + w, SLAB_TOP + h)
        # the white pedestal slab the tower stands on
        quad(f, SLAB_SIDE, X0 + 4, Y0 + 2, X1 - 4, SLAB_TOP - 6)
        quad(f, SLAB, X0 + 4, SLAB_TOP - 6, X1 - 4, SLAB_TOP)
        f.write(f"\t\tcolor({FRAME});\n\t\tbgnclosedline();\n")
        for vx, vy in ((X0, Y0), (X1, Y0), (X1, Y1), (X0, Y1)):
            f.write(f"\t\t\tvertex({vx:.2f}, {vy:.2f});\n")
        f.write("\t\tendclosedline();\n")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Fsn.fti")
