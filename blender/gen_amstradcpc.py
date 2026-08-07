"""Parametric Amstrad CPC keyboard-computer (variants A/B/C).

Run headless:
  blender -b --python blender/gen_amstradcpc.py -- --variant B --out /tmp/cpc-b.glb

Variants: A = CPC 464 (datacorder block, full 464 color language),
B = CPC 6128 (ROADMAP TARGET: integrated 3-inch disk drive block on the
right, colored accent keys per the art-direction brief), C = CPC 6128 stock
trim (all-cream keys) for comparison.

Real-world dimensional ground truth (do not invent proportions):
- Photogrammetric off the Commons near-top view (key pitch 19.05 mm as
  scale; Q..P = 10U = 652 px):
  https://commons.wikimedia.org/wiki/File:AMSTRAD_CPC_6128.jpg
  => case ~530 x 173 mm; 18U key field (343 mm) checks exactly; drive block
  ~112 mm wide; rear ~62 mm + vent serration, front edge ~46 mm.
- Color language from https://commons.wikimedia.org/wiki/File:Amstrad_CPC464.jpg
  and https://commons.wikimedia.org/wiki/File:Amstrad_CPC_keyboard_closeup.jpg
  (red ESC, green modifiers, blue f-number island, navy alphas on the 464).
  The 6128 variant keeps its cream main field but carries the red/green/blue
  accents the director mandated for museum recognizability.

Era-defining details as REAL geometry: sunken sloped keyboard tray, rear
serration teeth, raised drive/datacorder block with recessed 3-inch drive
face (slot + eject + LED) or cassette lid, recessed badge strip with rainbow
chips, front ridge lines. Never painted-on darkness.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_homemicros as hm  # noqa: E402

U = hm.U
W, D = 0.530, 0.173
Y_F = -D / 2
H_F, H_R = 0.044, 0.060  # wedge shell heights (serration teeth on top of rear)
X0 = -W / 2 + 0.030  # key-unit origin (left margin measured off the photo)
TRAY_Y0 = Y_F + 0.022  # first (front) key row center - 0.5U

# CPC-specific dark ABS palette (the shared beige family stays for ST/Acorn).
DARK = {
    "case": ("#454139", 0.60),
    "case-deep": ("#322f2a", 0.62),
    "tray": ("#3a362f", 0.64),
    "cream": ("#d9d2c2", 0.52),
    "navy": ("#454c60", 0.55),
    "red": ("#c03a30", 0.50),
    "green": ("#3f9e57", 0.50),
    "blue": ("#4a6fb5", 0.50),
    "drv-face": ("#57534a", 0.58),
    "grey-btn": ("#6a655c", 0.55),
}


def mat(key):
    hexc, rough = DARK[key]
    return lib.material("cpc-" + key, hexc, rough)


PARAMS = {
    "A": dict(alpha="navy", accents=True, drive=False, badge="CPC464"),
    "B": dict(alpha="cream", accents=True, drive=True, badge="CPC6128"),
    "C": dict(alpha="cream", accents=False, drive=True, badge="CPC6128"),
}

# Main block rows, 15u wide (ESC row .. CTRL/COPY row) per the top-view photo.
ROWS = [
    ([1] * 15, {0: "red"}),
    ([1.5] + [1] * 12, {0: "green"}),
    ([1.75] + [1] * 12, {0: "green"}),
    ([2.0] + [1] * 10 + [2.5], {0: "green"}),
    ([1.75, 1.25, 8.0, -0.5, 1.5], {0: "green", 1: "green"}),
]
ISL_X = 15.4  # f-key/cursor island offset (units)


def wt(y):
    """Wedge shell top height at depth y."""
    return H_F + (y - Y_F) / D * (H_R - H_F)


def tray_floor(y):
    """Tray floor: flat, 5 mm under the FRONT lip => deep sloped surround
    toward the rear, keys held inside the silhouette."""
    return wt(Y_F + 0.014) - 0.0058


def build_case(p):
    # Shell: loft along Y — a lower front lip with a chamfer band flowing
    # into the wedge (not a tall vertical fascia slab).
    body = lib.loft(
        "body",
        "Y",
        [
            (0.0, W, 0.0375, 0.01875),
            (0.011, W, wt(Y_F + 0.011), wt(Y_F + 0.011) / 2),
            (D, W, H_R, H_R / 2),
        ],
        (0, Y_F, 0),
        mat("case"),
    )
    # Deep keyboard tray with sloping surround walls (tapered loft cutter);
    # keycaps sit INSIDE the case silhouette.
    tx0, tx1 = X0 - 0.006, X0 + 18.8 * U
    ty0, ty1 = Y_F + 0.014, TRAY_Y0 + 5.15 * U
    tw, td = tx1 - tx0, ty1 - ty0
    zf = tray_floor(ty0)
    lib.cut(
        body,
        lib.loft(
            "tray-cut",
            "Z",
            [(0.0, tw - 0.009, td - 0.009, 0.0), (0.032, tw + 0.004, td + 0.004, 0.0)],
            ((tx0 + tx1) / 2, (ty0 + ty1) / 2, zf),
        ),
    )
    lib.box(
        "tray-floor",
        (tw - 0.0095, td - 0.0095, 0.0012),
        ((tx0 + tx1) / 2, (ty0 + ty1) / 2, zf + 0.0005),
        mat("tray"),
    )
    # Rear serration teeth (the CPC's toothed vent silhouette), full width
    # minus the drive block (which carries its own, higher, row).
    n = 46 if p["drive"] else 60
    hm.tooth_row(
        "serration",
        n,
        0.007,
        (0.0038, 0.011, 0.0042),
        (-W / 2 + 0.014, D / 2 - 0.009, wt(D / 2 - 0.009) + 0.0016),
        mat("case"),
    )
    # Badge strip band across the deck rear: recessed, dark plate + rainbow
    # chips + power LED (text comes in the texture pass).
    by0, by1 = D / 2 - 0.0335, D / 2 - 0.0215
    lib.cut(body, hm.slab_on("badge-cut", -W / 2 + 0.022, X0 + 18.8 * U, by0, by1, lambda y: wt(y) - 0.0018, 0.02))
    hm.slab_on(
        "badge-plate",
        -W / 2 + 0.024,
        -W / 2 + 0.190,
        by0 + 0.0005,
        by1 - 0.0005,
        lambda y: wt(y) - 0.0015,
        0.0012,
        mat("case-deep"),
    )
    cx = X0 + 15.7 * U
    for i, c in enumerate(("#c03a30", "#3f9e57", "#4a6fb5")):
        hm.slab_on(
            f"chip{i}",
            cx + i * 0.0105,
            cx + i * 0.0105 + 0.0078,
            by0 + 0.0015,
            by1 - 0.0015,
            lambda y: wt(y) - 0.0014,
            0.0013,
            lib.material("cpc-chip-" + c, c, 0.5),
        )
    hm.led("power-led", X0 + 18.0 * U, (by0 + by1) / 2, wt((by0 + by1) / 2) + 0.0004, "#d04038")
    # Front face ridge lines (real proud strips, per the 464/6128 fascia).
    for z in (0.011, 0.017):
        lib.box("front-rib", (W - 0.024, 0.0013, 0.0011), (0, Y_F - 0.0005, z), mat("case-deep"))
    return body


def build_keys(p):
    field = hm.KeyField(origin_x=X0, taper=0.0058)
    acc = p["accents"]

    def m(k):
        return k if acc else p["alpha"]

    zk = tray_floor(0.0) - 0.0008
    for r, (widths, colored) in enumerate(ROWS):
        cy = TRAY_Y0 + (4.5 - r) * U
        field.row(widths, 0.0, cy, zk, 0.0105, p["alpha"], overrides={i: m(c) for i, c in colored.items()})
    # Big RETURN spanning rows 1-2 beside the main block (green on the 464).
    ret_mat = m("green") if p["alpha"] == "navy" else p["alpha"]
    field.cap(ret_mat, 13.80, TRAY_Y0 + 3.0 * U, zk, 1.20, 0.0115, du=2.0)
    # f-number island: f7..f0 blue; cursor cross + dot stay in the main tone
    # (selective 464 accent placement, not a solid blue slab).
    for r in range(3):
        cy = TRAY_Y0 + (4.5 - r) * U
        field.row([1, 1, 1], ISL_X, cy, zk, 0.0105, m("blue"))
    field.row([1, 1, 1], ISL_X, TRAY_Y0 + 1.5 * U, zk, 0.0105, p["alpha"], overrides={0: m("blue")})
    field.row([1, 1, 1], ISL_X, TRAY_Y0 + 0.5 * U, zk, 0.0105, p["alpha"])
    mats = {k: mat(k) for k in ("cream", "navy", "red", "green", "blue") if k in field.bms}
    field.finalize("cpc", mats)


def _panel_decal(size=256):
    """Drive-block label panel: dark floor, off-white linework rows in two
    column groups, one red + one green rule (texture-round-3 request)."""
    import numpy as np

    arr = np.full((size, size, 3), (0.185, 0.175, 0.158), dtype=np.float32)
    line = np.array((0.66, 0.64, 0.58), dtype=np.float32)
    for y0, y1, x0, x1, c in (
        (34, 37, 20, 236, np.array((0.55, 0.24, 0.20))),  # red rule
        (126, 129, 20, 236, np.array((0.27, 0.47, 0.30))),  # green rule
    ):
        arr[y0:y1, x0:x1] = arr[y0:y1, x0:x1] * 0.2 + c * 0.8
    for row in range(6):  # faint table rows, two column groups
        y = 148 + row * 15
        arr[y : y + 2, 24:118] = line * 0.55 + arr[y : y + 2, 24:118] * 0.45
        arr[y : y + 2, 138:232] = line * 0.55 + arr[y : y + 2, 138:232] * 0.45
    for row in range(4):  # dash marks under the red rule (title-ish blocks)
        y = 52 + row * 17
        w = 60 + (row * 37) % 90
        arr[y : y + 3, 24 : 24 + w] = line * 0.5 + arr[y : y + 3, 24 : 24 + w] * 0.5
    return hm.decal_material("cpc-panel-decal", arr, size, rough=0.5)


def drive_block(p):
    """Right-end block MOLDED into the wedge (slight rise, chamfered front):
    3-inch drive (6128) or datacorder (464)."""
    bx0, bx1 = W / 2 - 0.120, W / 2  # flush with the right case edge
    cx = (bx0 + bx1) / 2
    bw = bx1 - bx0

    def top(y):
        return wt(y) + 0.004

    def ring(y):
        return (y - Y_F, bw, top(y), top(y) / 2)

    blk = lib.loft(
        "block",
        "Y",
        [
            (0.0, bw, 0.0395, 0.01975),
            (0.011, bw, wt(Y_F + 0.011) + 0.001, (wt(Y_F + 0.011) + 0.001) / 2),
            ring(Y_F + 0.024),
            ring(D / 2 - 0.008),
        ],
        (cx, Y_F, 0),
        mat("case"),
    )

    hm.tooth_row(
        "blk-serration",
        15,
        0.007,
        (0.0038, 0.011, 0.0042),
        (bx0 + 0.010, D / 2 - 0.012, top(D / 2 - 0.012) + 0.0016),
        mat("case"),
    )
    # Recessed label panel on the block top: thin framed border, real inset,
    # floor carrying a numpy-drawn label decal (the 6128's disc-codes table
    # with its red/green rules — linework only, unreadable by design).
    lib.cut(
        blk,
        hm.slab_on("panel-cut", bx0 + 0.005, bx1 - 0.005, Y_F + 0.028, D / 2 - 0.024, lambda y: top(y) - 0.0028, 0.02),
    )
    panel = hm.slab_on(
        "panel-decal",
        bx0 + 0.0056,
        bx1 - 0.0056,
        Y_F + 0.0286,
        D / 2 - 0.0246,
        lambda y: top(y) - 0.0025,
        0.0012,
        _panel_decal(),
        segs=1,
    )
    hm.uv_fullface(panel)
    if p["drive"]:
        # 3-inch drive bay: deep front recess, inset drive face with a REAL
        # slot cavity, proud eject bar, LED.
        fy = Y_F
        lib.well(blk, "drv", 0.102, 0.036, fy, cx + 0.002, 0.021, 0.011, mat=mat("case-deep"))
        face = lib.box("drv-face", (0.096, 0.0022, 0.030), (cx + 0.002, fy + 0.0085, 0.020), mat("drv-face"))
        lib.cut(face, lib.multi_box("drv-slot-cut", [((0.068, 0.02, 0.0052), (cx - 0.002, fy + 0.0085, 0.0285))]))
        lib.box("drv-slot-back", (0.072, 0.0016, 0.0092), (cx - 0.002, fy + 0.0105, 0.0285), mat("case-deep"))
        lib.box("drv-eject", (0.017, 0.0085, 0.0070), (cx + 0.030, fy + 0.0058, 0.0125), mat("grey-btn"))
        hm.led("drv-led", cx - 0.038, fy + 0.0072, 0.0125, "#d04038")
    else:
        # 464 datacorder: cassette lid raised inside the top panel + piano keys.
        hm.slab_on(
            "cass-lid",
            bx0 + 0.020,
            bx1 - 0.020,
            Y_F + 0.048,
            D / 2 - 0.048,
            lambda y: top(y) - 0.0012,
            0.0035,
            mat("case"),
        )
        hm.slab_on(
            "cass-win",
            bx0 + 0.032,
            bx1 - 0.032,
            Y_F + 0.060,
            D / 2 - 0.060,
            lambda y: top(y) + 0.0008,
            0.0012,
            lib.shared("glass"),
        )
        for i in range(6):
            km = mat("red") if i == 0 else mat("case-deep")
            lib.box("piano", (0.0125, 0.0085, 0.0062), (bx0 + 0.014 + i * 0.0165, Y_F + 0.0035, 0.0125), km)
    lib.bevel(blk, 0.0022, 2)
    return blk


def build(p):
    body = build_case(p)
    build_keys(p)
    drive_block(p)
    lib.bevel(body, 0.0020, 2)


def main():
    variant, out = lib.parse_args("B", "/tmp/param-amstradcpc.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    # Texture pass: dark charcoal ABS from the shared MJ texture library
    # (~/scene-v2-reference/textures/INDEX.md, abs-charcoal pick; its
    # judgment note about near-black crushing is handled by the mean-centered
    # grain normalization), procedural fallback if absent.
    # Round-3 texture verdict corrections: cooler slightly-lifted charcoal,
    # near-invisible diffuse grain (fine 3x tile), deeper clamped AO, and
    # the drive-panel label decal (see _panel_decal).
    grain = os.path.expanduser("~/scene-v2-reference/textures/abs-charcoal/abs-charcoal.png")
    hm.texture_model(
        "cpc",
        grain,
        grain_strength=0.05,
        grain_tile=3,
        ao_k=1.2,
        ao_floor=0.5,
        tint=(0.955, 0.985, 1.04),
        desat=0.10,
        value=1.05,
        body_rough=0.60,
    )
    hm.export_glb_textured(out)


if __name__ == "__main__" and lib.bpy is not None:
    main()
