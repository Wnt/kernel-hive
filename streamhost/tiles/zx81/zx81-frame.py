#!/usr/bin/env python3
"""Measure a captured ZX81 frame, and decide whether it is the idle fixture.

A ZX81 at its power-on prompt is a WHITE field carrying exactly one mark: the
inverse-video `K` cursor in the bottom-left of the 32x24 character grid. That
makes every photometric predicate in the sibling builders useless here -- see
the header of scripts/build-guests/zx81.sh -- so this one is geometric.

WHAT IT MEASURES

  picture     the bounding box of paper-white pixels. MAME's aspect correction
              normally fills the whole 4:3 root, but if it ever letterboxes,
              the bars are black; finding the picture first makes everything
              below independent of the X root size and of how MAME chose to fit
              the raster into it.
  white       fraction of the PICTURE that is paper-white.
  ink_box     dark pixels inside the CURSOR BOX: column 0 of the last display
              row, with half a cell of slack to the left, two cells to the
              right and four rows of height.
  ink_out     dark pixels elsewhere in the 256x192 DISPLAY AREA.
  ink_border  dark pixels in the picture but outside the display area. Reported,
              never asserted on: it is the ZX81's own black blanking band at the
              foot of the raster, and it is there whatever the machine is doing.

  --assert idle  requires a picture at least half the frame in each dimension,
                 white >= 0.85, an ink_box between 0.4 and 3.5 character cells,
                 and ink_out no more than 0.35 of a cell.

  --whiteout <out.ppm> writes a copy with the cursor box painted paper-white.
                 That is the builder's model of the machine's OTHER white
                 screen -- the one it shows while it is computing with the
                 display switched off, and the one a cleared screen shows -- so
                 the predicate can be made to face it and fail.

Usage: zx81-frame.py <frame.ppm> [--assert idle] [--whiteout out.ppm]
                                 [--row R] [--rows N]
"""

import sys

# GEOMETRY, MEASURED -- not assumed. Taken from a headless MAME snapshot of this
# exact driver at its power-on screen (`-video none` plus a Lua frame-counting
# autoboot script, 2026-08-09), because the obvious assumption is wrong twice
# over:
#   * the 256x192 display area is NOT centred in the 384x311 raster. It sits at
#     x=54, y=56, so the borders are 54/74 and 56/63.
#   * raster rows 304..309 are a BLACK blanking band that belongs to the
#     picture, with a white row below them again. Natively that band is 2304
#     dark pixels -- forty-five times the cursor's ink -- so any test that
#     counts ink over the whole picture measures the band and nothing else.
# Ink is therefore counted inside the DISPLAY AREA only, which is the only place
# the ZX81 can draw anything.
RASTER_W, RASTER_H = 384, 311
DISP_X, DISP_Y = 54, 56
DISP_W, DISP_H = 256, 192
CELL = 8
# The `K` cursor of an idle 1 KB ZX81 sits in column 0 of the LAST display row
# (row 23, measured). The box spans four rows so a different ROM revision or RAM
# size cannot move it out, and two and a half columns so that the SECOND
# character of anything typed already falls outside it.
CURSOR_ROW = int(sys.argv[sys.argv.index("--row") + 1]) if "--row" in sys.argv else 23
CURSOR_ROWS = int(sys.argv[sys.argv.index("--rows") + 1]) if "--rows" in sys.argv else 4
WHITE, DARK = 200, 100
# Thresholds in CHARACTER CELLS, not pixels, so the same numbers hold at the
# native 384x311 and on the tile's 1024x768 root. The inverse-video cursor cell
# measures 51 of its 64 native pixels dark (0.80 of a cell): the glyph strokes
# are the white part. At the fixture, ink outside the box is exactly 0, and one
# extra typed character is about 0.4 of a cell.
INK_BOX_MIN_CELLS, INK_BOX_MAX_CELLS = 0.40, 3.50
INK_OUT_MAX_CELLS = 0.35


def read_ppm(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise SystemExit("not a binary PPM: %s" % path)
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(data) and data[pos : pos + 1].isspace():
            pos += 1
        if data[pos : pos + 1] == b"#":
            while data[pos : pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos : pos + 1].isspace():
            pos += 1
        fields.append(int(data[start:pos]))
    return fields[0], fields[1], data[pos + 1 :]


def is_white(row, i):
    return row[i] > WHITE and row[i + 1] > WHITE and row[i + 2] > WHITE


def is_dark(row, i):
    return row[i] < DARK and row[i + 1] < DARK and row[i + 2] < DARK


w, h, pix = read_ppm(sys.argv[1])
rows = [pix[y * w * 3 : (y + 1) * w * 3] for y in range(h)]

# Pass 1 -- where is the picture? Rows/columns that carry any paper-white pixel.
px0, py0, px1, py1 = w, h, -1, -1
for y in range(h):
    row = rows[y]
    first = last = -1
    for x in range(w):
        if is_white(row, 3 * x):
            if first < 0:
                first = x
            last = x
    if last >= 0:
        if py0 > y:
            py0 = y
        py1 = y + 1
        px0, px1 = min(px0, first), max(px1, last + 1)
if py1 < 0:
    px0 = py0 = px1 = py1 = 0
pw, ph = max(0, px1 - px0), max(0, py1 - py0)

# Geometry, derived from the picture rather than from the root.
if pw > 0 and ph > 0:
    sx, sy = pw / float(RASTER_W), ph / float(RASTER_H)
    cw, cht = CELL * sx, CELL * sy
    dx0, dy0 = px0 + DISP_X * sx, py0 + DISP_Y * sy
    dx1, dy1 = dx0 + DISP_W * sx, dy0 + DISP_H * sy
    bx0, bx1 = int(dx0 - 0.5 * cw), int(dx0 + 2 * cw)
    by0 = int(dy0 + (CURSOR_ROW + 1 - CURSOR_ROWS) * cht)
    by1 = int(dy0 + (CURSOR_ROW + 1) * cht)
    dx0, dy0, dx1, dy1 = int(dx0), int(dy0), int(dx1), int(dy1)
    cell_px = cw * cht
else:
    bx0 = by0 = bx1 = by1 = dx0 = dy0 = dx1 = dy1 = 0
    cell_px = 1.0

# Pass 2 -- count inside the picture, splitting the display area from its border.
white = ink_box = ink_out = ink_border = 0
for y in range(py0, py1):
    row = rows[y]
    in_disp_row = dy0 <= y < dy1
    in_box_row = by0 <= y < by1
    for x in range(px0, px1):
        i = 3 * x
        if is_white(row, i):
            white += 1
        elif is_dark(row, i):
            if in_disp_row and dx0 <= x < dx1:
                if in_box_row and bx0 <= x < bx1:
                    ink_box += 1
                else:
                    ink_out += 1
            else:
                ink_border += 1

area = pw * ph
print("w=%d h=%d" % (w, h))
print("picture=%d,%d,%d,%d (%dx%d)" % (px0, py0, px1, py1, pw, ph))
print("white=%.4f" % (white / float(area) if area else 0.0))
print("ink_box=%d ink_out=%d ink_border=%d" % (ink_box, ink_out, ink_border))
print("cell_px=%.1f box=%d,%d,%d,%d disp=%d,%d,%d,%d" % (cell_px, bx0, by0, bx1, by1, dx0, dy0, dx1, dy1))

if "--whiteout" in sys.argv:
    out = bytearray(pix)
    for y in range(max(0, by0), min(h, by1)):
        for x in range(max(0, bx0), min(w, bx1)):
            i = (y * w + x) * 3
            out[i : i + 3] = b"\xff\xff\xff"
    with open(sys.argv[sys.argv.index("--whiteout") + 1], "wb") as fh:
        fh.write(b"P6\n%d %d\n255\n" % (w, h))
        fh.write(bytes(out))

if "--assert" in sys.argv:
    what = sys.argv[sys.argv.index("--assert") + 1]
    if what != "idle":
        raise SystemExit("unknown assertion: %s" % what)
    frac = white / float(area) if area else 0.0
    box_cells, out_cells = ink_box / cell_px, ink_out / cell_px
    why = []
    if pw < w // 2 or ph < h // 2:
        why.append(
            "no picture (white bounding box %dx%d of a %dx%d frame): black X "
            "root, dead emulator, or a MAME warning panel" % (pw, ph, w, h)
        )
    elif frac < 0.85:
        why.append("the picture is not a white field (white=%.4f): this is not a ZX81 at rest" % frac)
    if not INK_BOX_MIN_CELLS <= box_cells <= INK_BOX_MAX_CELLS:
        why.append(
            "no single inverse-video cursor cell in the cursor box (%.2f cells "
            "of ink): an empty field -- display off while computing, or a "
            "cleared screen -- or the cursor is not where this ROM puts it" % box_cells
        )
    if out_cells > INK_OUT_MAX_CELLS:
        why.append(
            "ink elsewhere in the display area (%.2f cells): the screen carries "
            "typed text, a listing or a report code" % out_cells
        )
    if why:
        raise SystemExit("NOT the ZX81 idle fixture: " + "; ".join(why))
    print("idle=ok")
