"""Parametric Acorn RISC OS machine (variants A/B/C) for the riscos tile.

Run headless:
  blender -b --python blender/gen_acorn.py -- --variant A --out /tmp/acorn-a.glb

Variants: A = Acorn A3000 keyboard-wedge (PICK for the riscos showcase
homeMicro assembly — the red F1-F12 groups are the strongest museum-distance
Acorn identity), B = Acorn Risc PC 600 two-slice case (comparison
candidate), C = A3010-style trim (green function keys).

Real-world dimensional ground truth (do not invent proportions):
- A3000 photogrammetric off the Commons top view (19.05 mm key pitch as
  scale; Q..P = 10U = 675 px):
  https://commons.wikimedia.org/wiki/File:Acorn_Archimedes_A3000_Computer_Main_Unit.jpg
  => ~490 x 305 mm footprint (23U key field, 438 mm, + margins), rear deck
  ~66 mm with three top vent-slot banks (notched left bank), keyboard front
  lip ~30 mm. Case class compared to the Amiga 500 (474 x 330 x 76) by
  period reviews: https://en.wikipedia.org/wiki/Acorn_A3000
- Risc PC: 355 (w) x 384 (d) x 117 (h) mm per slice case
  https://en.wikipedia.org/wiki/Risc_PC

Era-defining details as REAL geometry: red function keys in 4-key groups,
recessed key tray, three cut vent-slot banks, Acorn + BBC badge recesses
with LEDs (A3000); slice seam, curved corner pillars, drive faces, side
vent grooves, ridged plinth (Risc PC). Never painted-on darkness.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_homemicros as hm  # noqa: E402

U = hm.U
PARAMS = {
    "A": dict(style="a3000", fkey="#dc4633"),
    "B": dict(style="riscpc"),
    "C": dict(style="a3000", fkey="#3f9e57"),
}

# ---- A3000 keyboard-wedge ------------------------------------------------
W, D = 0.490, 0.305
Y_F = -D / 2
STEP_Y = D / 2 - 0.150  # rear deck step (deck reaches further forward)
KB_Y0 = Y_F + 0.018  # front row center - 0.5U
X0 = -23.0 * U / 2
DECK_H = 0.064

MAIN_ROWS = [
    [1] * 13 + [2],
    [1.5] + [1] * 12 + [1.5],
    [1.75] + [1] * 11 + [2.25],
    [2.25] + [1] * 10 + [2.75],
    [1.5, -0.5, 1.5, 7.0, 1.5, -0.5, 1.5],
]
NAV_X, NUM_X = 15.5, 19.0


# Front-shell profile rings: (depth from the front edge, top height).
FRONT_RINGS = ((0.0, 0.0140), (0.005, 0.0225), (0.060, 0.0300), (STEP_Y - Y_F + 0.010, 0.0400))


def ft(y):
    """Front-section top height at depth y (piecewise over FRONT_RINGS)."""
    t = y - Y_F
    for (t0, h0), (t1, h1) in zip(FRONT_RINGS, FRONT_RINGS[1:]):
        if t <= t1:
            return h0 + (h1 - h0) * (t - t0) / (t1 - t0)
    return FRONT_RINGS[-1][1]


def a3000_case():
    # Continuous side taper: thin nose flowing up through the tray band into
    # the deck foot, so the deck reads as the wedge's continuation.
    widths = (W - 0.026, W - 0.004, W, W)
    front = lib.loft(
        "front-shell",
        "Y",
        [(t, w, h, h / 2) for (t, h), w in zip(FRONT_RINGS, widths)],
        (0, Y_F, 0),
        lib.shared("abs-light"),
    )
    deck = lib.loft(
        "deck",
        "Y",
        [
            (0.0, W - 0.002, 0.0615, 0.03075),
            (0.005, W, DECK_H, DECK_H / 2),
            (D / 2 - STEP_Y, W - 0.004, DECK_H, DECK_H / 2),
        ],
        (0, STEP_Y, 0),
        lib.shared("abs-light"),
    )
    # Keyboard tray: sloped recess (floor follows the shell profile) holding
    # the whole 23u field + F-row, keys seated at a consistent depth.
    tx0, tx1 = X0 - 0.008, X0 + 23.0 * U + 0.008
    ty0, ty1 = Y_F + 0.010, STEP_Y - 0.002
    lib.cut(front, hm.slab_on("tray-cut", tx0, tx1, ty0, ty1, lambda y: ft(y) - 0.0040, 0.05, segs=4))
    hm.slab_on(
        "tray-floor",
        tx0 + 0.0004,
        tx1 - 0.0004,
        ty0 + 0.0004,
        ty1 - 0.0004,
        lambda y: ft(y) - 0.0049,
        0.0012,
        lib.shared("abs-warm"),
        segs=4,
    )
    # Three top vent-slot banks; the left bank carries the A3000's notch
    # (its right half only ventilates the rear portion).
    vy0, vy1 = STEP_Y + 0.016, D / 2 - 0.020
    banks = (
        (-0.208, -0.158, vy0, vy1),
        (-0.152, -0.096, vy0 + 0.058, vy1),
        (-0.058, 0.075, vy0, vy1),
        (0.088, 0.208, vy0, vy1),
    )
    for bi, (x0, x1, y0, y1) in enumerate(banks):
        n = int((x1 - x0) / 0.0082)
        cy, dy = (y0 + y1) / 2, y1 - y0
        hm.slot_bank(
            deck,
            f"vent{bi}",
            n,
            0.0082,
            (0.0034, dy, 0.02),
            (x0 + 0.0041, cy, DECK_H),
            floor_pad=0.0075,
        )
    # Acorn badge: recessed plate on the deck step face, left.
    lib.cut(deck, lib.multi_box("acorn-badge-cut", [((0.088, 0.016, 0.016), (-W / 2 + 0.066, STEP_Y + 0.001, 0.050))]))
    lib.box("acorn-badge-floor", (0.084, 0.0014, 0.013), (-W / 2 + 0.066, STEP_Y + 0.0062, 0.050), lib.shared("recess"))
    lib.box("acorn-badge", (0.078, 0.0030, 0.0110), (-W / 2 + 0.066, STEP_Y + 0.0040, 0.050), lib.shared("abs-light"))
    lib.box(
        "acorn-chip",
        (0.010, 0.0018, 0.010),
        (-W / 2 + 0.038, STEP_Y + 0.0018, 0.050),
        lib.material("acorn-green", "#2f8c4a", 0.5),
    )
    lib.bevel(front, 0.0024, 2)
    lib.bevel(deck, 0.0026, 2)


def a3000_keys(p):
    field = hm.KeyField(origin_x=X0, gap=0.0016)

    def zk(cy):
        return ft(cy) - 0.0056

    for r, widths in enumerate(MAIN_ROWS):
        cy = KB_Y0 + (4.5 - r) * U
        field.row(widths, 0.0, cy, zk(cy), 0.0100, "light")
    # Nav block + cursors (grey-green like the modifiers).
    for r, widths in enumerate(([1, 1, 1], [1, 1, 1])):
        cy = KB_Y0 + (4.5 - r) * U
        field.row(widths, NAV_X, cy, zk(cy), 0.0100, "grey")
    field.row([-1, 1, -1], NAV_X, KB_Y0 + 1.5 * U, zk(KB_Y0 + 1.5 * U), 0.0100, "grey")
    field.row([1, 1, 1], NAV_X, KB_Y0 + 0.5 * U, zk(KB_Y0 + 0.5 * U), 0.0100, "grey")
    # Numpad.
    for r in range(4):
        cy = KB_Y0 + (4.5 - r) * U
        field.row([1, 1, 1, 1], NUM_X, cy, zk(cy), 0.0100, "light")
    field.row([2, 1, 1], NUM_X, KB_Y0 + 0.5 * U, zk(KB_Y0 + 0.5 * U), 0.0100, "light")
    # F-row shelf: Esc, then F1-F12 in THREE GROUPS OF FOUR tall red keys,
    # then Print/ScrollLock/Break — the Acorn signature.
    fy = KB_Y0 + 5.65 * U
    zf_row = zk(fy)
    field.row([1], 0.0, fy, zf_row, 0.0122, "grey")
    fx = 1.5
    for _ in range(3):
        field.row([1] * 4, fx, fy, zf_row, 0.0122, "red")
        fx += 4.65
    field.row([1, 1, 1], fx, fy, zf_row, 0.0122, "grey")
    field.finalize(
        "a3000",
        {
            "light": lib.shared("abs-light"),
            "grey": lib.shared("abs-grey"),
            "red": lib.material("acorn-fkey", p["fkey"], 0.5),
        },
    )
    # BBC badge strip right of the Break key, with power/disc LEDs.
    bx = X0 + 21.2 * U
    zb = ft(fy) - 0.0049 + 0.0020
    lib.box("bbc-badge", (0.078, 1.15 * U, 0.0028), (bx, fy, zb), lib.shared("abs-light"))
    # LED sockets: dark seats under the lamps so they read as real apertures.
    for dy_led in (0.004, -0.004):
        lib.box(
            "led-socket", (0.0055, 0.0045, 0.0010), (bx + 0.028, fy + dy_led, zb + 0.0016), lib.shared("recess-deep")
        )
    hm.led("led-power", bx + 0.028, fy + 0.004, zb + 0.0024)
    hm.led("led-disc", bx + 0.028, fy - 0.004, zb + 0.0024, "#d2a03c")


# ---- Risc PC 600 slice case ---------------------------------------------
RW, RD = 0.355, 0.384


def riscpc():
    ry_f = -RD / 2
    plinth = lib.box("plinth", (RW, RD, 0.016), (0, 0, 0.008), lib.shared("abs-warm"))
    for i in range(3):
        lib.cut(plinth, lib.multi_box(f"pl-groove{i}", [((RW + 0.02, 0.0018, 0.0016), (0, ry_f, 0.004 + i * 0.0042))]))
    lower = lib.box("slice-lower", (RW, RD, 0.050), (0, 0, 0.041), lib.shared("abs-light"))
    upper = lib.box("slice-upper", (RW, RD, 0.048), (0, 0, 0.092), lib.shared("abs-light"))
    lid = lib.box("lid", (RW - 0.006, RD - 0.006, 0.0035), (0, 0, 0.1178), lib.shared("abs"))
    # Slice seam: recessed dark band between the two slices.
    seam = lib.box("seam", (RW - 0.0015, RD - 0.0015, 0.0035), (0, 0, 0.0665), lib.shared("recess"))
    # Curved front corner pillars (the Risc PC's rounded lobes).
    for sx in (-1, 1):
        lib.cylinder(
            "pillar", 0.020, 0.104, "Z", (sx * (RW / 2 - 0.016), ry_f + 0.014, 0.068), lib.shared("abs-light"), 28
        )
    # Drive slots: 3.5-inch floppy (right) + CD tray (left) in the lower slice.
    lib.well(lower, "cd", 0.128, 0.020, ry_f, -0.052, 0.048, 0.007, mat=lib.shared("recess"))
    lib.box("cd-face", (0.122, 0.003, 0.016), (-0.052, ry_f + 0.005, 0.048), lib.shared("abs-light"))
    lib.box("cd-btn", (0.014, 0.0045, 0.0045), (-0.006, ry_f + 0.0028, 0.042), lib.shared("abs-grey"))
    lib.well(lower, "fdd", 0.096, 0.016, ry_f, 0.075, 0.030, 0.007, mat=lib.shared("recess"))
    fdd = lib.box("fdd-face", (0.090, 0.003, 0.012), (0.075, ry_f + 0.005, 0.030), lib.shared("abs-light"))
    lib.cut(fdd, lib.multi_box("fdd-slot", [((0.070, 0.02, 0.0035), (0.072, ry_f + 0.005, 0.0325))]))
    lib.box("fdd-slot-back", (0.074, 0.0014, 0.0060), (0.072, ry_f + 0.0068, 0.0325), lib.shared("recess-deep"))
    # Side vent grooves (vertical lines, rear half of both slices).
    for sx in (-1, 1):
        for target, z0, nz in ((lower, 0.041, 0.036), (upper, 0.092, 0.034)):
            grooves = [((0.006, 0.0022, nz), (sx * RW / 2, 0.03 + i * 0.011, z0)) for i in range(14)]
            lib.cut(target, lib.multi_box(f"vent-{sx}-{z0}", grooves))
    # Acorn badge lobe, front-right of the upper slice.
    lib.box("badge", (0.030, 0.004, 0.030), (RW / 2 - 0.052, ry_f - 0.0005, 0.092), lib.shared("abs-light"))
    lib.box(
        "badge-chip",
        (0.012, 0.002, 0.012),
        (RW / 2 - 0.052, ry_f - 0.0028, 0.092),
        lib.material("acorn-green", "#2f8c4a", 0.5),
    )
    for obj in (plinth, lower, upper, lid):
        lib.bevel(obj, 0.0022, 2)
    lib.bevel(seam, 0.001, 1)


def build(p):
    if p["style"] == "riscpc":
        riscpc()
    else:
        a3000_case()
        a3000_keys(p)


def main():
    variant, out = lib.parse_args("A", "/tmp/param-acorn.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    # Texture pass: sun-aged beige from the shared MJ texture library
    # (~/scene-v2-reference/textures/INDEX.md, abs-beige-yellowed pick),
    # procedural fallback if absent. Variant B (Risc PC) has no key meshes;
    # texture_model then bakes the body only.
    # Round-3 texture verdict corrections: warmer aged cream (+value), finer
    # 2x-tiled grain at reduced amplitude, deeper clamped AO, modifiers
    # darkened ~10% for the grey-green separation.
    grain = os.path.expanduser("~/scene-v2-reference/textures/abs-beige-yellowed/abs-beige-yellowed.png")
    hm.texture_model(
        "a3000",
        grain,
        grain_strength=0.10,
        grain_tile=2,
        ao_k=1.25,
        ao_floor=0.42,
        tint=(1.06, 1.035, 0.955),
        desat=0.08,
        value=1.05,
        key_mul={"shared-abs-grey": 0.90},
    )
    hm.export_glb_textured(out)


if __name__ == "__main__" and lib.bpy is not None:
    main()
