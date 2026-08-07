"""Parametric keyboard family (legacy A-C plus HARDWARE-MATRIX D-H).

Run headless:
  blender -b --python blender/gen_keyboard.py -- --variant C --out /path/kbd-c.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

Iteration 2 (director picked C, the Model-M-deep-bezel board): the case is now
two stacked shells — a lower slab and an inset upper wedge — so a real step
ridge runs around the body (the Model M's case seam); keycap tops carry a
raised rim with a slightly sunken center (cheap dish read); the lock-light
panel is a lined recess cut into the shell instead of a plate glued on top.
Per-cluster two-tone material grouping is unchanged.

Real-world dimensional ground truth (do not invent proportions):
- IBM Model M (101-key): 492 x 210 x 44 mm
  https://www.clickykeyboards.com/frequently-asked-questions/
- Cherry G80-3000 (mid-90s full-size): ~470 x 195 x 44 mm
  https://www.cherry.de/en-us/product/g80-3000
- Key pitch 19.05 mm (0.75") standard; full-size = 23 key-units wide
  (main 15u + gap 0.5u + nav 3u + gap 0.5u + numpad 4u = 438 mm of keys).
- Cluster layout studied from the IBM Model M US-layout photo:
  https://commons.wikimedia.org/wiki/File:IBM_Model_M_keyboard_(US_layout_with_101_keys).jpg

Matrix-variant dimensional and silhouette sources:
- D, IBM Model F XT 83-key: 485 x 38 x 228 mm. The left F-key bank,
  numeric/cursor block, stepped rows, and large Enter follow:
  https://wiki.retrotechcollection.com/IBM_Model_F_%2883-key%29
  https://commons.wikimedia.org/wiki/File:IBM_model_F_3887360487_ca719998f0_o.jpg
- E, coordinated 2001 multimedia board: 458 x 25 x 163 mm envelope from the
  HP standard keyboard dimensions, with the period silver/graphite desk-set
  treatment established by the Dimension 8100 review:
  https://images10.newegg.com/UploadFilesForNewegg/itemintelligence/Hewlett-Packard/001455918_an_01_en_KURZ_HP_COMPAQ_I5_650_250G_W7PRO_REFURB_1470971831529.pdf
  https://www.computerworld.com/article/1411973/product-review-dell-dimension-8100.html
- F, generic USB membrane board: 442 x 24 x 127 mm:
  https://www.delltechnologies.com/asset/en-us/products/electronics-and-accessories/technical-support/dell_multimedia_keyboard_kb216_data_sheet.pdf.external
- G, compact wireless 79-key board: 279 x 16 x 124 mm:
  https://futureisnow.logitech.com/content/dam/logitech/en/business/pdf/k380-multi-device-blurtooth-keyboard.pdf
- H, Sun Type 5-class workstation board: 510 x 44 x 182 mm:
  https://docs.oracle.com/cd/E19127-01/sparc5.ws/801-6396-11/801-6396-11.pdf
  https://vtda.org/docs/computing/Sun/hardware/800-6802-12_Type5KeyboardandMouseProductNotes_RevA_Oct93.pdf

Identity marks and exact badge/outline trade dress are intentionally omitted.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_inputdevices as inp  # noqa: E402

U = 0.01905  # key pitch
GAP_FMAIN = 0.5  # vertical gap (units) between function row and main block
NAV_X, NUM_X = 15.5, 19.0  # cluster x offsets in units (gaps: 0.5u each)
TOTAL_U = 23.0
BASE_H = 0.012  # lower-shell slab height; the step seam sits here
STEP_IN = 0.0045  # upper shell inset per side => visible ridge width

# Per-row keycap heights: slight profile stagger (row 0 = function row).
ROW_H = {0: 0.0100, 1: 0.0112, 2: 0.0105, 3: 0.0098, 4: 0.0102, 5: 0.0108}

PARAMS = {
    "A": dict(  # compact Cherry-style slab, single-tone caps
        L=0.460,
        D=0.160,
        h_front=0.028,
        h_rear=0.040,
        two_tone=False,
        led_panel=False,
    ),
    "B": dict(  # classic two-tone office board
        L=0.466,
        D=0.168,
        h_front=0.030,
        h_rear=0.044,
        two_tone=True,
        led_panel=True,
    ),
    "C": dict(  # big Model-M-like deep-bezel board
        L=0.492,
        D=0.196,
        h_front=0.032,
        h_rear=0.048,
        two_tone=True,
        led_panel=True,
    ),
}

MATRIX_PARAMS = {
    "D": dict(L=0.485, D=0.228, H=0.038),
    "E": dict(L=0.458, D=0.163, H=0.025),
    "F": dict(L=0.442, D=0.127, H=0.024),
    "G": dict(L=0.279, D=0.124, H=0.016),
    "H": dict(L=0.510, D=0.182, H=0.044),
}

TEXTURE_PARAMS = {
    "D": dict(grain_scale=180.0, grain_mul=0.48, ao_floor=0.58, wear=0.030, rough=0.54),
    "E": dict(grain_scale=140.0, grain_mul=0.78, ao_floor=0.62, wear=0.025, rough=0.46),
    "F": dict(grain_scale=120.0, grain_mul=0.52, ao_floor=0.68, wear=0.018, rough=0.52),
    "G": dict(grain_scale=110.0, grain_mul=0.95, ao_floor=0.62, wear=0.022, rough=0.46),
    "H": dict(grain_scale=110.0, grain_mul=0.72, ao_floor=0.62, wear=0.025, rough=0.57),
}

# (row, x_units, widths) — negative width = gap. Row 0 is the function row.
MAIN_ROWS = [
    (1, 0.0, [1] * 13 + [2]),
    (2, 0.0, [1.5] + [1] * 12 + [1.5]),
    (3, 0.0, [1.75] + [1] * 11 + [2.25]),
    (4, 0.0, [2.25] + [1] * 10 + [2.75]),
    (5, 0.0, [1.5, -1, 1.5, 7, 1.5, -1, 1.5]),
    (0, 0.0, [1, -1, 1, 1, 1, 1, -0.5, 1, 1, 1, 1, -0.5, 1, 1, 1, 1]),
    (0, NAV_X, [1, 1, 1]),
    (1, NAV_X, [1, 1, 1]),
    (2, NAV_X, [1, 1, 1]),
    (4, NAV_X, [-1, 1, -1]),
    (5, NAV_X, [1, 1, 1]),
    (1, NUM_X, [1, 1, 1, 1]),
    (2, NUM_X, [1, 1, 1]),
    (3, NUM_X, [1, 1, 1]),
    (4, NUM_X, [1, 1, 1]),
    (5, NUM_X, [2, 1]),
]
# (row, x_units, w_units, rows_tall) — numpad double-height + and Enter.
TALL_KEYS = [(1, NUM_X + 3.0, 1, 2), (3, NUM_X + 3.0, 1, 2)]


def row_y(row, d_total):
    """Y center of a key row; rear (+Y) holds the function row."""
    rear = d_total / 2.0 - 0.014
    if row == 0:
        return rear - 0.5 * U
    return rear - (1 + GAP_FMAIN + (row - 0.5)) * U


def keycap(bm, xu, row, wu, p, rows_tall=1):
    """Tapered cap with a raised rim + slightly sunken top (dished read)."""
    kw = wu * U - 0.0009
    kd = rows_tall * U - 0.0009
    h = ROW_H[row]
    x0 = -TOTAL_U * U / 2.0
    cx = x0 + (xu + wu / 2.0) * U
    cy = row_y(row, p["D"]) - (rows_tall - 1) * U / 2.0
    slope = (p["h_rear"] - p["h_front"]) / (p["D"] - 0.004)
    zb = p["h_front"] + (cy + p["D"] / 2.0) * slope - 0.003
    shrink = 0.0052
    lib.loft_into(
        bm,
        "Z",
        [
            (0.0, kw, kd, 0.0),
            (h * 0.25, kw, kd, 0.0),
            (h, kw - shrink, kd - shrink - 0.0006, -0.0008),
            (h - 0.0008, kw - shrink - 0.0034, kd - shrink - 0.0040, -0.0008),
        ],
        (cx, cy, zb),
    )


def grey_of(row, xu, wu_pos, widths):
    """Two-tone rule (per the Model M reference photo): modifiers grey —
    Esc + PrtSc trio, outer keys of main rows, bottom row, nav cluster,
    and the numpad operator row."""
    if xu == NAV_X:
        return True  # nav cluster + arrows are grey on the Model M
    if xu == NUM_X:
        return row == 1  # NumLock / / * - operator row
    if row == 0:
        return wu_pos == 0  # Esc (PrtSc trio handled by the NAV_X rule)
    return wu_pos == 0 or wu_pos == len(widths) - 1 or row == 5


def build(p):
    # Two-shell case: lower slab + inset upper wedge => real step ridge.
    lower = lib.box("case-lower", (p["L"], p["D"], BASE_H), (0, 0, BASE_H / 2), lib.shared("abs-warm"))
    upper = lib.wedge_box(
        "case-upper",
        p["L"] - 2 * STEP_IN,
        p["D"] - 2 * STEP_IN,
        p["h_front"] - BASE_H,
        p["h_rear"] - BASE_H,
        (0, 0, BASE_H),
        lib.shared("abs"),
    )
    white = lib.new_bm()
    grey = lib.new_bm()
    for row, xoff, widths in MAIN_ROWS:
        xu = xoff
        for i, wu in enumerate(widths):
            if wu < 0:
                xu += -wu
                continue
            target = grey if p["two_tone"] and grey_of(row, xoff, i, widths) else white
            keycap(target, xu, row, wu, p)
            xu += wu
    for row, xu, wu, tall in TALL_KEYS:
        keycap(grey if p["two_tone"] else white, xu, row, wu, p, rows_tall=tall)
    lib.finalize(white, "keys-white", lib.shared("abs-light"))
    lib.finalize(grey, "keys-grey", lib.shared("abs-grey"))
    if p["led_panel"]:
        # Lock lights live in a real lined recess cut into the upper shell.
        px = (-TOTAL_U / 2.0 + NUM_X + 2.0) * U
        py = row_y(0, p["D"])
        up_slope = (p["h_rear"] - p["h_front"]) / (p["D"] - 2 * STEP_IN)
        top_z = p["h_front"] + (py + (p["D"] - 2 * STEP_IN) / 2.0) * up_slope
        lib.cut(upper, lib.multi_box("led-cut", [((3.5 * U, 0.016, 0.008), (px, py, top_z))]))
        lib.box("led-floor", (3.5 * U - 0.001, 0.015, 0.0016), (px, py, top_z - 0.0036), lib.shared("recess"))
        for i in range(3):
            lib.box(
                "led",
                (0.004, 0.0035, 0.0028),
                (px - 0.022 + i * 0.022, py, top_z - 0.0016),
                lib.material("led-g", "#3fae4a", 0.4),
            )
    lib.bevel(upper, width=0.0026, segments=2)
    lib.bevel(lower, width=0.0018, segments=1)


def _row(target, y, x_left, widths):
    """Append one key row in unit coordinates; negative widths are gaps."""
    x = x_left
    for width in widths:
        if width < 0:
            x -= width
            continue
        target.append((x + width / 2, y, width, 1))
        x += width


def _full_layout():
    """Generic enhanced layout split into ordinary and modifier key families."""
    regular, mods = [], []
    left = -TOTAL_U / 2
    _row(regular, 3.05, left, [1, -1, 1, 1, 1, 1, -0.5, 1, 1, 1, 1, -0.5, 1, 1, 1, 1])
    for y, widths in (
        (1.55, [1] * 13 + [2]),
        (0.55, [1.5] + [1] * 12 + [1.5]),
        (-0.45, [1.75] + [1] * 11 + [2.25]),
        (-1.45, [2.25] + [1] * 10 + [2.75]),
    ):
        _row(regular, y, left, widths)
    _row(mods, -2.45, left, [1.5, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25])
    for y in (3.05, 1.55, 0.55):
        _row(mods, y, 4.0, [1, 1, 1])
    _row(mods, -0.45, 4.0, [1, 1, 1])
    _row(mods, -1.45, 5.0, [1])
    _row(mods, -2.45, 4.0, [1, 1, 1])
    for y in (1.55, 0.55, -0.45, -1.45):
        _row(regular, y, 7.5, [1, 1, 1])
    _row(mods, 1.55, 10.5, [1])
    _row(mods, -0.45, 10.5, [1])
    _row(regular, -2.45, 7.5, [2, 1])
    return regular, mods


def _xt_layout():
    """83-key read: left F bank, big Enter, shared cursor/numeric block."""
    regular, dark = [], []
    main_left = -8.0
    _row(regular, 2.0, main_left, [1] * 12 + [2])
    _row(regular, 1.0, main_left, [1.5] + [1] * 11 + [1.5])
    _row(regular, 0.0, main_left, [1.75] + [1] * 10)
    _row(regular, -1.0, main_left, [2.25] + [1] * 9 + [2.25])
    _row(dark, -2.0, main_left, [1.5, 1.5, 7.0, 1.5, 1.5])
    for y in (2, 1, 0, -1, -2):
        _row(dark, y, -10.8, [1, 1])
    for y in (2, 1, 0, -1):
        _row(regular, y, 6.8, [1, 1, 1])
    _row(dark, 2, 9.8, [1])
    _row(dark, 0, 9.8, [1])
    _row(regular, -2, 6.8, [2, 1])
    return regular, dark


def _compact_layout():
    """79-key compact read with integrated arrows and no number pad."""
    regular, mods = [], []
    left = -8.0
    _row(regular, 2.7, left, [1] * 16)
    _row(regular, 1.35, left, [1] * 13 + [2])
    _row(regular, 0.35, left, [1.5] + [1] * 12 + [1.5])
    _row(regular, -0.65, left, [1.75] + [1] * 11 + [2.25])
    _row(regular, -1.65, left, [2.25] + [1] * 10 + [2.75])
    _row(mods, -2.65, left, [1.25, 1.25, 1.25, 5.5, 1.25, 1.25, -0.5, 1, 1, 1])
    mods.append((6.0, -1.65, 1, 1))
    return regular, mods


def _type5_layout():
    """Wide workstation layout with the characteristic left command bank."""
    regular, dark = _full_layout()
    shifted_regular = [(x + 1.2, y, w, d) for x, y, w, d in regular]
    shifted_dark = [(x + 1.2, y, w, d) for x, y, w, d in dark]
    for y in (2.8, 1.8, 0.8, -0.2, -1.2):
        _row(shifted_dark, y, -12.8, [1, 1])
    for x in (8.4, 9.6, 10.8):
        shifted_dark.append((x, 3.05, 1, 1))
    return shifted_regular, shifted_dark


def _add_indicator_recess(upper, p, x, y, width, led_mat):
    deck = inp.top_z(y, p["D"], p["front_h"], p["rear_h"])
    inp.recessed_cluster(upper, "status", width, 0.008, (x, y), deck, inp.mat("black-well"), 0.0016)
    for i in range(3):
        lib.box(
            "status-led",
            (0.0060, 0.0048, 0.0022),
            (x - width * 0.28 + i * width * 0.28, y, deck - 0.0007),
            led_mat,
        )


def _build_xt(p):
    p.update(front_h=0.024, rear_h=0.029)
    _, upper = inp.wedge_shell(
        "xt-case",
        p["L"],
        p["D"],
        p["front_h"],
        p["rear_h"],
        inp.mat("xt-shell"),
        inp.mat("xt-shell"),
        0.0045,
    )
    regular, dark = _xt_layout()
    z_at = lambda y: inp.top_z(y, p["D"], p["front_h"], p["rear_h"])  # noqa: E731
    inp.key_group("xt-keys-light", regular, inp.mat("xt-key-light"), 0.0188, 0.0190, z_at, 0.0090)
    inp.key_group("xt-keys-dark", dark, inp.mat("xt-key-dark"), 0.0188, 0.0190, z_at, 0.0090)
    # A physically stepped two-row Enter: the upper lobe is 1.55u wide and
    # the lower stem narrows to 1u, with a small overlap so it reads as one key.
    enter_x = (-8.0 + 13.25) * 0.0188
    enter_parts = [
        (enter_x / 0.0188, 0.55, 1.55, 1.12),
        ((enter_x + 0.0052) / 0.0188, -0.48, 1.0, 1.08),
    ]
    inp.key_group("xt-stepped-enter", enter_parts, inp.mat("xt-key-dark"), 0.0188, 0.0190, z_at, 0.0095)
    # Thick Model-F front lip and a visibly separate rear cable socket.
    lip = lib.box(
        "xt-front-lip",
        (p["L"] - 0.010, 0.052, 0.018),
        (0, -p["D"] / 2 + 0.027, 0.015),
        inp.mat("xt-shell"),
    )
    lib.bevel(lip, 0.0022, 2)
    lib.bevel(upper, 0.0028, 2)
    inp.coiled_cable("xt-coiled-cable", p["D"] / 2 - 0.004, 0.014, inp.mat("work-dark"), thick=True)


def _build_multimedia(p):
    p.update(front_h=0.0155, rear_h=0.0205)
    lower, upper = inp.wedge_shell(
        "multimedia-case",
        p["L"],
        p["D"],
        p["front_h"],
        p["rear_h"],
        inp.mat("graphite"),
        inp.mat("silver"),
        0.003,
    )
    # The graphite palm edge is a separate molded rail, not a color stripe.
    rail = lib.box(
        "graphite-palm-edge",
        (p["L"] - 0.012, 0.026, 0.008),
        (0, -p["D"] / 2 + 0.014, 0.011),
        inp.mat("graphite"),
    )
    lib.bevel(rail, 0.0020, 2)
    pitch_x, pitch_y = 0.0182, 0.0205
    regular, mods = _full_layout()
    for name, center, size in (
        ("main", (-4.3 * pitch_x, -0.007), (15.0 * pitch_x, 4.8 * pitch_y)),
        ("nav", (5.2 * pitch_x, -0.007), (3.0 * pitch_x, 4.8 * pitch_y)),
        ("num", (9.1 * pitch_x, -0.007), (4.0 * pitch_x, 4.8 * pitch_y)),
    ):
        deck = inp.top_z(center[1], p["D"], p["front_h"], p["rear_h"])
        inp.recessed_cluster(upper, name + "-well", *size, center, deck, inp.mat("black-well"), 0.0017)
    z_at = lambda y: inp.top_z(y, p["D"], p["front_h"], p["rear_h"]) - 0.0007  # noqa: E731
    inp.key_group("media-keys", regular, inp.mat("silver-light"), pitch_x, pitch_y, z_at, 0.0046, False)
    inp.key_group("media-modifiers", mods, inp.mat("graphite"), pitch_x, pitch_y, z_at, 0.0046, False)
    for i in range(3):
        button = lib.cylinder(
            "media-button",
            0.0042,
            0.0020,
            "Z",
            ((i - 1) * 0.013, 0.066, inp.top_z(0.066, p["D"], p["front_h"], p["rear_h"]) + 0.001),
            inp.mat("graphite"),
            20,
        )
        lib.bevel(button, 0.0005, 1)
    for x in (-p["L"] * 0.36, p["L"] * 0.36):
        lib.box("flip-foot", (0.027, 0.012, 0.004), (x, p["D"] / 2 - 0.018, 0.002), inp.mat("graphite"))
    lib.bevel(upper, 0.0024, 2)
    lib.bevel(lower, 0.0018, 2)


def _build_black_usb(p):
    p.update(front_h=0.0145, rear_h=0.0195)
    _, upper = inp.wedge_shell(
        "usb-case",
        p["L"],
        p["D"],
        p["front_h"],
        p["rear_h"],
        inp.mat("black-shell"),
        inp.mat("black-shell"),
        0.0025,
    )
    regular, mods = _full_layout()
    z_at = lambda y: inp.top_z(y, p["D"], p["front_h"], p["rear_h"])  # noqa: E731
    inp.key_group("usb-keys", regular + mods, inp.mat("black-key"), 0.0176, 0.0143, z_at, 0.0042, False)
    _add_indicator_recess(upper, p, 0.177, 0.047, 0.032, lib.material("input-led-white", "#b8d0b0", 0.35))
    # Tiny media glyphs are shallow raised bars on three F keys.
    for i in range(3):
        lib.box(
            "media-mark",
            (0.0100, 0.0022, 0.0018),
            (-0.030 + i * 0.0176, 3.05 * 0.0143, p["rear_h"] + 0.0040),
            inp.mat("silver"),
        )
    lib.bevel(upper, 0.0018, 2)
    inp.keyboard_usb_cable(p["D"] / 2 - 0.003, inp.mat("black-shell"))


def _build_compact(p):
    p.update(front_h=0.0105, rear_h=0.0130)
    shell = lib.wedge_box(
        "compact-one-piece",
        p["L"],
        p["D"],
        p["front_h"],
        p["rear_h"],
        (0, 0, 0),
        inp.mat("pale-shell"),
    )
    regular, mods = _compact_layout()
    z_at = lambda y: inp.top_z(y, p["D"], p["front_h"], p["rear_h"])  # noqa: E731
    inp.key_group("compact-keys", regular, inp.mat("pale-key"), 0.01625, 0.0150, z_at, 0.0028, False)
    inp.key_group("compact-modifiers", mods, inp.mat("silver-light"), 0.01625, 0.0150, z_at, 0.0028, False)
    # Wireless power slider and battery seam are both physical.
    lib.box("power-slider", (0.011, 0.0024, 0.0022), (0.105, p["D"] / 2 - 0.0012, 0.008), inp.mat("graphite"))
    battery = lib.box(
        "battery-step",
        (0.092, 0.011, 0.0026),
        (0, p["D"] / 2 - 0.007, 0.0105),
        inp.mat("silver"),
    )
    lib.bevel(battery, 0.0012, 2)
    lib.bevel(shell, 0.0028, 3)


def _build_type5(p):
    p.update(front_h=0.027, rear_h=0.0355)
    _, upper = inp.wedge_shell(
        "type5-case",
        p["L"],
        p["D"],
        p["front_h"],
        p["rear_h"],
        inp.mat("work-shell"),
        inp.mat("work-shell"),
        0.004,
    )
    regular, dark = _type5_layout()
    z_at = lambda y: inp.top_z(y, p["D"], p["front_h"], p["rear_h"])  # noqa: E731
    inp.key_group("type5-keys", regular, inp.mat("work-key"), 0.0184, 0.0170, z_at, 0.0080)
    inp.key_group("type5-command-keys", dark, inp.mat("work-dark"), 0.0184, 0.0170, z_at, 0.0080)
    # Isolated top-right power key receives a real recessed collar.
    power_x, power_y = 12.2 * 0.0184, 3.05 * 0.0170
    power_z = inp.top_z(power_y, p["D"], p["front_h"], p["rear_h"])
    inp.recessed_cluster(
        upper,
        "power-key-well",
        0.020,
        0.018,
        (power_x, power_y),
        power_z,
        inp.mat("work-dark"),
        0.0018,
    )
    inp.key_group(
        "type5-power-key",
        [(12.2, 3.05, 1, 1)],
        inp.mat("work-key"),
        0.0184,
        0.0170,
        z_at,
        0.0085,
    )
    lib.cylinder(
        "power-key-pip",
        0.0024,
        0.0012,
        "Z",
        (power_x, power_y, power_z + 0.0088),
        inp.mat("work-dark"),
        20,
    )
    lib.bevel(upper, 0.0028, 2)
    inp.coiled_cable(
        "type5-coiled-cable",
        p["D"] / 2 - 0.004,
        0.018,
        inp.mat("work-dark"),
        thick=True,
        side_coil=True,
    )


def build_matrix(variant):
    p = MATRIX_PARAMS[variant].copy()
    {
        "D": _build_xt,
        "E": _build_multimedia,
        "F": _build_black_usb,
        "G": _build_compact,
        "H": _build_type5,
    }[variant](p)
    lib.bpy.context.view_layer.update()


def main():
    variant, out = lib.parse_args("A", "/tmp/param-kbd.glb")
    lib.reset_scene()
    if variant in PARAMS:
        build(PARAMS[variant])
    else:
        build_matrix(variant)
    bake_params = TEXTURE_PARAMS.get(
        variant,
        dict(ao_floor=0.45, wear=0.045, rough=0.50, grain_scale=70.0),
    )
    lib_bake.maybe_bake_export(out, **bake_params)


if __name__ == "__main__" and lib.bpy is not None:
    main()
