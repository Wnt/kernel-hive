"""Parametric GENERIC late-70s/80s 8-bit home-computer wedge (variants A/B).

Run headless:
  blender -b --python blender/gen_8bitwedge.py -- --variant A --out /tmp/w8-a.glb
  add `--textured` for the lib_bake Cycles atlas bake.

Role: era stand-in for the apple2 tile — inspired by the Apple IIe class
of tall keyboard wedges but deliberately GENERIC (Apple trade dress is a
litigious IP outlier). Trade-dress separation, enforced by design review
each round:
- NO fruit/rainbow logo, NO "apple" badge — plain recessed rectangular
  badge chip only;
- altered proportions: 400 x 360 x 76 mm vs the IIe's measured
  383 x 464 x 110 mm case (4.3125 x 15.0625 x 18.25 in,
  https://www.applefritter.com/node/22888) — much shallower depth ratio
  and a lower rear mass (round-2 judge);
- different vent grammar: recessed horizontal side-louver wells at the
  REAR flanks + a rear-deck slot bank (the IIe uses vertical fin stacks
  at the FRONT corners);
- warm-grey keycaps with darker modifiers (the IIe field is dark brown);
- plain lid seam + flat deck instead of the IIe's sculpted lid.

Variants: A = vented wedge (76 mm crest, rear-down sloping deck, side
louvers), B = lower flat variant (61.5 mm, asymmetric left-shifted key
field + right control column, rear vents only).

Screen-relevant dims: n/a (no screen). machines.ts targets: overall body
W 0.400 m, H 0.076 m (A) / 0.0615 m (B), D 0.360 m.

Era-defining details as REAL geometry (never painted): sunken keyboard
tray with proud sculpted caps, stepped tall rear body with lid seam,
recessed side-louver wells, rear-deck vent slots, badge plate + chip,
power lamp, rear port band.

Key pitch 19.05 mm (industry standard, lib_homemicros.U).
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402
import lib_homemicros as hm  # noqa: E402

U = hm.U
W, D = 0.400, 0.360
Y_F = -D / 2

W8 = {
    "shell": ("#d2c3a3", 0.58),  # warm beige ABS body
    "panel": ("#ded4bc", 0.52),  # raised deck plate (lighter second level)
    "key": ("#9c9384", 0.52),  # warm-grey caps (NOT the IIe brown field)
    "key-dark": ("#635c51", 0.54),  # modifier accents
    "tray": ("#6b675f", 0.62),  # keyboard well floor
    "badge": ("#d2ccbc", 0.45),  # plain badge plate (no logo)
}

# (depth-from-front, width, height): keyboard apron -> tall rear body.
PROF_A = [
    (0.000, W - 0.012, 0.0185),
    (0.003, W, 0.0215),
    (0.150, W, 0.0395),
    (0.160, W, 0.0520),  # stepped transition: ledge, then second rise
    (0.168, W, 0.0580),
    (0.176, W, 0.0600),
    (0.184, W, 0.0700),
    (0.196, W, 0.0760),
    (0.230, W, 0.0755),
    (0.330, W, 0.0640),
    (0.348, W - 0.004, 0.0620),
    (D, W - 0.012, 0.0560),
]
PROF_B = [
    (0.000, W - 0.012, 0.0170),
    (0.003, W, 0.0200),
    (0.150, W, 0.0350),
    (0.165, W, 0.0470),
    (0.180, W, 0.0570),
    (0.195, W, 0.0615),
    (0.260, W, 0.0605),
    (0.335, W, 0.0530),
    (0.350, W - 0.004, 0.0515),
    (D, W - 0.012, 0.0470),
]

PARAMS = {
    "A": dict(prof=PROF_A, side_louvers=True, deck_y=0.190, port_z=0.036, xoff=0.0),
    "B": dict(prof=PROF_B, side_louvers=False, deck_y=0.195, port_z=0.028, xoff=-0.016),
}

SPAN = 14.5  # key-unit field width
X0 = -SPAN / 2 * U
TRAY_Y0 = Y_F + 0.016

# 61-key massing: 4 rows + space row (generic layout, deliberately not the
# IIe's exact modifier arrangement).
ROWS = [
    [1.0] * 13 + [1.5],
    [1.5] + [1.0] * 13,
    [1.75] + [1.0] * 11 + [1.75],
    [2.0] + [1.0] * 10 + [2.5],
    [-3.0, 8.5, -0.5, 1.0, 1.0],
]


def mat(key):
    hexc, rough = W8[key]
    return lib.material("w8-" + key, hexc, rough)


def top_z(y, prof):
    t = y - Y_F
    for (t0, _, h0), (t1, _, h1) in zip(prof, prof[1:]):
        if t <= t1:
            return h0 + (h1 - h0) * (t - t0) / max(t1 - t0, 1e-9)
    return prof[-1][2]


def build_case(p):
    prof = p["prof"]
    body = lib.loft("body", "Y", [(t, w, h, h / 2) for t, w, h in prof], (0, Y_F, 0), mat("shell"))
    # Sunken keyboard tray in the apron.
    tx0, tx1 = X0 - 0.009 + p["xoff"], X0 + SPAN * U + 0.009 + p["xoff"]
    ty0, ty1 = TRAY_Y0 - 0.006, TRAY_Y0 + 5.0 * U + 0.006
    zf = top_z(ty0, prof) - 0.0062
    # Crisp rectangular tray with near-vertical walls (round-1: less
    # IIe-like scoop, more angular surround).
    lib.cut(
        body,
        lib.loft(
            "tray-cut",
            "Z",
            [(0.0, tx1 - tx0 - 0.002, ty1 - ty0 - 0.002, 0.0), (0.050, tx1 - tx0 + 0.001, ty1 - ty0 + 0.001, 0.0)],
            ((tx0 + tx1) / 2, (ty0 + ty1) / 2, zf),
        ),
    )
    lib.box(
        "tray-floor",
        (tx1 - tx0 - 0.0030, ty1 - ty0 - 0.0030, 0.0012),
        ((tx0 + tx1) / 2, (ty0 + ty1) / 2, zf + 0.0005),
        mat("tray"),
    )
    # Angular side cheeks flanking the keyboard (segmented, not scooped).
    for sgn, cx in ((-1, tx0 - 0.024), (1, tx1 + 0.024)):
        lib.wedge_box(
            f"cheek{sgn}",
            0.040,
            ty1 - ty0 + 0.004,
            top_z(ty0, prof) + 0.0012,
            top_z(ty1, prof) + 0.0016,
            (cx, (ty0 + ty1) / 2, 0.0),
            mat("shell"),
        )
    # Lid seam: groove around the tall body where the removable lid meets
    # the base. The deck slopes rearward, so the flank seams follow top_z
    # (straight boxes would notch the deck top near the rear).
    d0 = Y_F + p["deck_y"]
    for sgn in (-1, 1):
        lib.cut(
            body,
            hm.slab_on(
                f"lid-seam{sgn}",
                sgn * W / 2 - 0.0018,
                sgn * W / 2 + 0.0018,
                d0,
                D / 2 - 0.002,
                lambda y: top_z(y, prof) - 0.016,
                0.0016,
                segs=4,
            ),
        )
    z_rear = top_z(D / 2 - 0.004, prof) - 0.014
    lib.cut(body, lib.multi_box("lid-seam-rear", [((W + 0.002, 0.0036, 0.0016), (0.0, D / 2, z_rear))]))
    # Lower-shell seam around the base.
    base = [
        ((W + 0.002, 0.0034, 0.0014), (0, Y_F, 0.0060)),
        ((0.0034, D - 0.006, 0.0014), (-W / 2, 0.0, 0.0060)),
        ((0.0034, D - 0.006, 0.0014), (W / 2, 0.0, 0.0060)),
    ]
    lib.cut(body, lib.multi_box("base-seam", base))
    return body, zf


def build_keys(p, zf):
    field = hm.KeyField(origin_x=X0 + p["xoff"], taper=0.0046, gap=0.0026)
    zk = zf - 0.0008
    overrides = {
        0: {13: "dark"},
        1: {0: "dark"},
        2: {},
        3: {0: "dark"},
        4: {},
    }
    for r, widths in enumerate(ROWS):
        cy = TRAY_Y0 + (4.5 - r) * U
        field.row(widths, 0.0, cy, zk + (4 - r) * 0.0010, 0.0128, "key", overrides=overrides[r])
    field.finalize("w8", {"key": mat("key"), "dark": mat("key-dark")})
    # Power lamp beside the tray's right rear corner.
    ly = TRAY_Y0 + 4.5 * U
    lx = X0 + SPAN * U + 0.022 + p["xoff"]
    hm.led("power-lamp", lx, ly, top_z(ly, p["prof"]) + 0.0010, "#3fae4a", size=(0.0050, 0.0036, 0.0024))
    if p["xoff"]:
        # Asymmetric right control column (B): two proud square buttons on
        # the widened right apron — era-clone control cluster, not IIe.
        for i in range(2):
            by = TRAY_Y0 + (1.2 + i * 1.4) * U
            lib.box(
                f"ctl-btn{i}",
                (0.016, 0.016, 0.0060),
                (0.165, by, top_z(by, p["prof"]) + 0.0016),
                mat("key-dark"),
            )


def deck_detail(p, body):
    prof = p["prof"]
    # Two compact vent grids at the deck rear corners (round-4: a small,
    # clearly ventilating feature, not a full-width printer-slot band).
    for sgn in (-1, 1):
        cxg = sgn * 0.115
        cuts = []
        for row in range(2):
            cyg = Y_F + 0.306 + row * 0.016
            cuts += [((0.0068, 0.0110, 0.02), (cxg + (i - 3.5) * 0.0125, cyg, top_z(cyg, prof))) for i in range(8)]
        lib.cut(body, lib.multi_box(f"deck-vents{sgn}", cuts))
        lib.box(
            f"deck-vent-floor{sgn}",
            (0.104, 0.040, 0.0014),
            (cxg, Y_F + 0.314, top_z(Y_F + 0.314, prof) - 0.0055),
            lib.shared("recess-deep"),
        )
    # Shallow inset panel on the housing's sloped front face + a raised
    # second-level deck plate (round-1: break up the blank rear mass).
    fy0, fy1 = Y_F + p["deck_y"] - 0.015, Y_F + p["deck_y"] - 0.007
    lib.cut(
        body,
        hm.slab_on(
            "face-panel-cut", -W / 2 + 0.030, W / 2 - 0.030, fy0, fy1, lambda y: top_z(y, prof) - 0.0012, 0.0024
        ),
    )
    # Abstract identity panel on the right FRONT APRON (round-5: away from
    # the IIe's upper-deck badge spot), square recess + chip + bar.
    bx, by = W / 2 - 0.052, TRAY_Y0 + 2.2 * U
    zb = top_z(by, prof)
    lib.cut(body, lib.multi_box("badge-cut", [((0.040, 0.028, 0.004), (bx, by, zb))]))
    lib.box("badge-plate", (0.037, 0.025, 0.0012), (bx, by, zb - 0.0014), mat("badge"))
    lib.box(
        "badge-chip",
        (0.018, 0.008, 0.0016),
        (bx, by + 0.0050, zb - 0.0002),
        lib.material("w8-vent-black", "#141210", 0.7),
    )
    lib.box(
        "badge-bar",
        (0.026, 0.0046, 0.0014),
        (bx, by - 0.0055, zb - 0.0004),
        lib.material("w8-vent-black", "#141210", 0.7),
    )
    if p["side_louvers"]:
        # Recessed louver wells on both REAR flanks: one deep well per
        # flank with uniformly spaced proud slats over a dark floor.
        for sgn in (-1, 1):
            sx = sgn * W / 2
            cy_l = Y_F + 0.268
            lib.cut(body, lib.multi_box(f"louver-cut{sgn}", [((0.0090, 0.072, 0.042), (sx, cy_l, 0.042))]))
            lib.box(
                f"louver-floor{sgn}",
                (0.0016, 0.070, 0.036),
                (sx - sgn * 0.0030, cy_l, 0.042),
                lib.material("w8-vent-black", "#141210", 0.7),
            )
            slats = [((0.0058, 0.068, 0.0052), (sx - sgn * 0.0024, cy_l, 0.0280 + i * 0.0100)) for i in range(4)]
            lib.multi_box(f"louver-slats{sgn}", slats, mat("shell"))
    # Restrained molding breaks on the broad rear face: two vertical seams.
    rz = (0.020 + top_z(D / 2 - 0.004, prof)) / 2
    rh = top_z(D / 2 - 0.004, prof) - 0.030
    lib.cut(
        body,
        lib.multi_box(
            "rear-seams",
            [((0.0030, 0.0040, rh), (-0.150, D / 2, rz)), ((0.0030, 0.0040, rh), (0.150, D / 2, rz))],
        ),
    )


def build_io(p, body):
    ry = D / 2
    lib.cut(body, lib.multi_box("port-cut", [((0.300, 0.016, 0.018), (0.0, ry, p["port_z"]))]))
    lib.box("port-floor", (0.296, 0.0016, 0.016), (0.0, ry - 0.0068, p["port_z"]), lib.shared("recess"))
    for pw, px in ((0.040, -0.115), (0.016, -0.055), (0.016, -0.022), (0.030, 0.030), (0.014, 0.080), (0.024, 0.120)):
        lib.box("port", (pw, 0.004, 0.0095), (px, ry - 0.0040, p["port_z"]), lib.shared("dark"))


def build(p):
    body, zf = build_case(p)
    build_keys(p, zf)
    deck_detail(p, body)
    build_io(p, body)
    lib.bevel(body, 0.0058, 2)


def main():
    variant, out = lib.parse_args("A", "/tmp/param-8bitwedge.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    hm.normalize_material_indices()
    tex = os.path.expanduser("~/scene-v2-reference/textures")
    if os.path.isdir(tex):  # register this generator's materials for the bake
        lib_bake.GRAIN.update(
            {
                "w8-shell": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.42),
                "w8-panel": ("abs-beige-clean/abs-beige-clean.png", 0.24),
                "w8-vent-black": ("abs-charcoal/abs-charcoal.png", 0.26),
                "w8-key": ("keycaps-worn/keycaps-worn.png", 0.36),
                "w8-key-dark": ("abs-charcoal/abs-charcoal.png", 0.28),
                "w8-tray": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.26),
                "w8-badge": ("abs-beige-clean/abs-beige-clean.png", 0.20),
            }
        )
    # A bakes at 1536 so its rear-deck vent grids stay crisp (round-6).
    size = 1536 if variant == "A" else 1024
    lib_bake.maybe_bake_export(out, size=size, ao_floor=0.38, wear=0.020, rough=0.50, grain_scale=60.0)


if __name__ == "__main__" and lib.bpy is not None:
    main()
