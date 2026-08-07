"""Parametric Atari ST wedge keyboard-computer (variants A/B/C).

Run headless:
  blender -b --python blender/gen_atarist.py -- --variant A --out /tmp/atarist-a.glb

Variants: A = 1040STF (roadmap target: internal right-side floppy, tall rear
deck), B = 520ST trim (no internal drive, slightly lower deck), C = 1040STE
trim (STE badge proportions, darker accent keys).

Real-world dimensional ground truth (do not invent proportions):
- 1040ST(E/F) shell: 470 x 300 x 60 mm — flight-case measurement thread
  https://www.atari-forum.com/viewtopic.php?t=12419
- Key pitch 19.05 mm standard; layout measured off the Commons photo
  https://commons.wikimedia.org/wiki/File:Atari_1040STf.jpg
  (Q..P = 10U calibration; main block 15u, cursor island 3u, numpad 4u,
  ten wide back-leaning function keys over ~14.5u, diagonal-ribbed vent
  field spanning ~410 mm of the rear deck).
- 3.5-inch drive slot on the RIGHT side face toward the rear (1040STF).

Era-defining details modeled as REAL geometry (no painted-on darkness):
back-leaning parallelogram F-keys on their own ledge, diagonal vent grain in
a recessed field, right-side floppy slot + eject button, recessed badge
strip, rear connector bay, left cartridge slot.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_homemicros as hm  # noqa: E402

U = hm.U
W, D = 0.470, 0.300
Y_F = -D / 2  # front edge
KB_Y0 = Y_F + 0.020  # front apron ends / key field starts
FROW_Y = KB_Y0 + 5.30 * U  # function-key ledge center band
DECK_Y0 = KB_Y0 + 6.55 * U  # rear deck rises here

PARAMS = {
    "A": dict(badge="1040STF", drive=True, deck_h=0.060, accent="light"),
    "B": dict(badge="520ST", drive=False, deck_h=0.056, accent="light"),
    "C": dict(badge="1040STE", drive=True, deck_h=0.060, accent="grey"),
}

# Main block rows (widths in key units; negative = gap), 15u wide, from the
# 1040STf photo: Esc+numbers+BS / Tab..Delete / Control..Return / Shift row /
# Alternate+space+CapsLock (the ST's odd CapsLock right of space).
MAIN_ROWS = [
    [1] * 13 + [2],
    [1.5] + [1] * 12 + [1.5],
    [1.75] + [1] * 11 + [2.25],
    [2.25] + [1] * 10 + [2.75],
    [-1.0, 1.5, 9.0, 1.5],
]
CUR_X, NUM_X = 15.5, 19.0  # cursor island / numpad offsets (units)


def kb_z(y):
    """Keyboard-plane (body wedge top) height at depth y: 26 -> 36 mm."""
    return 0.026 + (y - Y_F) / D * 0.010


def build_case(p):
    # Body: loft along Y so the front edge is a THIN chamfered lip (17 mm)
    # flowing into the keyboard wedge — not a tall vertical apron slab.
    body = lib.loft(
        "body",
        "Y",
        [
            (0.0, W - 0.024, 0.0155, 0.00775),
            (0.004, W - 0.006, 0.0215, 0.01075),
            (0.010, W, 0.0272, 0.0136),
            (D, W, 0.036, 0.018),
        ],
        (0, Y_F, 0),
        lib.shared("abs"),
    )
    # Stepped wells: the cursor island and numpad sit in their own shallow
    # recessed trays (flat floors cut into the sloped top) — distinct groups.
    x0 = -23.0 * U / 2
    wells = (("island-well", 15.30, 18.80, 3.5, 3.4), ("numpad-well", 18.90, 23.20, 2.5, 5.4))
    for name, ua, ub, cy_u, d_u in wells:
        cyw = KB_Y0 + cy_u * U
        zf = kb_z(cyw) - 0.0065
        cx = x0 + (ua + ub) / 2 * U
        lib.cut(body, lib.multi_box(name + "-cut", [(((ub - ua) * U, d_u * U, 0.03), (cx, cyw, zf + 0.015))]))
    ledge = lib.wedge_box(
        "frow-ledge",
        W - 0.006,
        DECK_Y0 - (FROW_Y - 0.75 * U),
        0.0355,
        0.046,
        (0, (FROW_Y - 0.75 * U + DECK_Y0) / 2, 0),
        lib.shared("abs"),
    )
    # Rear deck: lofted so its front face leans back instead of a hard slab.
    deck = lib.loft(
        "deck",
        "Y",
        [
            (0.0, W - 0.010, 0.0465, 0.02325),
            (0.006, W - 0.005, 0.0505, 0.02525),
            (0.014, W - 0.004, 0.0535, 0.02675),
            (D / 2 - DECK_Y0, W - 0.004, p["deck_h"], p["deck_h"] / 2),
        ],
        (0, DECK_Y0, 0),
        lib.shared("abs-warm"),
    )
    # Diagonal-ribbed vent field recessed into the deck top (real grain).
    vy = (DECK_Y0 + D / 2) / 2 + 0.004
    vd = D / 2 - DECK_Y0 - 0.038
    z_floor = 0.0475
    lib.cut(deck, lib.multi_box("vent-cut", [((0.410, vd, 0.05), (0, vy, z_floor + 0.025))]))
    lib.box("vent-floor", (0.410, vd, 0.0016), (0, vy, z_floor + 0.0008), lib.shared("recess"))
    hm.rib_field("vent-ribs", 0.407, vd - 0.0015, z_floor, 0.0045, 0.0085, 0.0042, (0, vy), 45.0, lib.shared("abs"))
    # Badge: recessed plaque on the ledge slope RIGHT of the F-keys (its real
    # 1040STF location) — sloped cutter + inset plate, both real geometry.
    yl0 = FROW_Y - 0.75 * U
    slope = (0.046 - 0.0355) / (DECK_Y0 - yl0)
    by0, by1 = FROW_Y - 0.55 * U, FROW_Y + 0.55 * U
    z_s = 0.0355 + (by0 - yl0) * slope

    def sloped(name, x0, x1, y0, y1, z_at, th, mat=None):
        return lib.loft(
            name,
            "Y",
            [(0.0, x1 - x0, th, 0.0), (y1 - y0, x1 - x0, th, (y1 - y0) * slope)],
            ((x0 + x1) / 2, y0, z_at),
            mat,
        )

    lib.cut(ledge, sloped("badge-cut", 0.085, 0.210, by0, by1, z_s, 0.005))
    sloped("badge-plate", 0.0862, 0.2088, by0 + 0.0006, by1 - 0.0006, z_s - 0.0014, 0.0016, lib.shared("abs-light"))
    return body, ledge, deck


def build_keys(p):
    field = hm.KeyField(origin_x=-23.0 * U / 2)
    for r, widths in enumerate(MAIN_ROWS):
        cy = KB_Y0 + (4.5 - r) * U
        field.row(widths, 0.0, cy, kb_z(cy) - 0.0025, 0.0105, "light", du=1.0)
    # Cursor island + numpad sit LOWER, inside their stepped wells (flat
    # floors), so the clusters read as distinct recessed groups.
    z_isl = kb_z(KB_Y0 + 3.5 * U) - 0.0080
    for r, widths in enumerate(([1.5, 1.5], [1, 1, 1], [1, 1, 1])):
        cy = KB_Y0 + (4.5 - r) * U
        field.row(widths, CUR_X, cy, z_isl, 0.0105, p["accent"])
    z_num = kb_z(KB_Y0 + 2.5 * U) - 0.0080
    for r in range(4):
        cy = KB_Y0 + (4.5 - r) * U
        field.row([1, 1, 1, 1], NUM_X, cy, z_num, 0.0105, "light")
    field.row([2, 1], NUM_X, KB_Y0 + 0.5 * U, z_num, 0.0105, "light")
    # Ten wide back-leaning function keys on the ledge (era signature),
    # seated on the slope with REAL gaps between neighbours.
    fy = FROW_Y + 0.15 * U
    fkeys = [1.32, -0.13] * 9 + [1.32]
    field.row(fkeys, 0.25, fy, 0.0368, 0.0100, "grey", du=1.35, skew=0.0062)
    field.finalize("st", {"light": lib.shared("abs-light"), "grey": lib.shared("abs-grey")})


def build_io(p, body, deck):
    if p["drive"]:
        sx, dy = W / 2, D / 2 - 0.085
        # Molded bezel recess in the side wall; the drive face sits inside it
        # and the slot is cut through that face into a dark cavity.
        lib.cut(body, lib.multi_box("drv-bez-cut", [((0.006, 0.114, 0.0190), (sx, dy, 0.0235))]))
        face = lib.box("drv-face", (0.0018, 0.110, 0.0170), (sx - 0.0028, dy, 0.0235), lib.shared("abs-light"))
        lib.cut(face, lib.multi_box("drv-slot-cut", [((0.02, 0.094, 0.0068), (sx - 0.0028, dy, 0.0255))]))
        lib.box("drv-cavity", (0.005, 0.098, 0.010), (sx - 0.0065, dy, 0.0255), lib.shared("recess-deep"))
        # Eject button seated in its own small well, nearly flush.
        lib.cut(body, lib.multi_box("eject-cut", [((0.005, 0.014, 0.009), (sx, dy - 0.036, 0.0145))]))
        lib.box("eject", (0.0042, 0.0105, 0.006), (sx - 0.0008, dy - 0.036, 0.0145), lib.shared("abs-grey"))
    # Rear connector bay: recessed band with dark port blanks (real cavity).
    lib.cut(deck, lib.multi_box("rear-cut", [((0.300, 0.016, 0.026), (0.02, D / 2, 0.030))]))
    lib.box("rear-floor", (0.296, 0.0016, 0.024), (0.02, D / 2 - 0.007, 0.030), lib.shared("recess"))
    for i, pw in enumerate((0.032, 0.032, 0.024, 0.050, 0.024)):
        x = -0.11 + i * 0.062
        lib.box("port", (pw, 0.004, 0.014), (x, D / 2 - 0.0055, 0.028), lib.shared("dark"))
    # Left cartridge slot toward the front half.
    hm.side_slot(body, "cart", -W / 2, 0.070, 0.006, Y_F + 0.105, 0.020)
    hm.led("power-led", -W / 2 + 0.030, Y_F + 0.009, 0.0245)


def build(p):
    body, ledge, deck = build_case(p)
    build_keys(p)
    build_io(p, body, deck)
    lib.bevel(body, 0.0026, 2)
    lib.bevel(ledge, 0.0020, 1)
    lib.bevel(deck, 0.0030, 2)


def main():
    variant, out = lib.parse_args("A", "/tmp/param-atarist.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    # Texture pass: aged pearl-grey ABS from the shared MJ texture library
    # (~/scene-v2-reference/textures/INDEX.md, abs-beige-clean pick), with a
    # procedural-noise fallback when the library is absent.
    # Round-4 texture verdict corrections: pearl-grey shift (desat + cool
    # tint + value drop toward #A7A79C), finer 3x-tiled grain at ~half
    # amplitude, deeper clamped AO.
    grain = os.path.expanduser("~/scene-v2-reference/textures/abs-beige-clean/abs-beige-clean.png")
    hm.texture_model(
        "st",
        grain,
        grain_strength=0.09,
        grain_tile=3,
        ao_k=1.25,
        ao_floor=0.42,
        tint=(0.985, 1.0, 1.03),
        desat=0.45,
        value=0.86,
        key_mul={"shared-abs-grey": 0.96},
    )
    hm.export_glb_textured(out)


if __name__ == "__main__" and lib.bpy is not None:
    main()
