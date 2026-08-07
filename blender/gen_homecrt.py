"""Parametric 80s home-computer RGB/composite monitors (variants A-E).

Run headless:
  blender -b --python blender/gen_homecrt.py -- --variant A --out /tmp/homecrt-a.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

These sit BEHIND home micros (Amiga/ST/CPC/Acorn assemblies) at ~0.32 m tall
on 0.72 m desks — the boxy big-bezel silhouette must read at 2-4 m.

Real-world dimensional ground truth (do not invent proportions):
- A: Commodore 1084S (Philips CM8833 family): 320 H x 350 W x 387 D mm,
  14-inch in-line slotted tube, 0.42 mm pitch, 90 deg deflection; front
  band with badge plate, control strip and power switch. Commodore 1084S
  Monitor User's Guide (1988), Technical specifications appendix:
  https://archive.org/details/Commodore_1084S_Monitor_Users_Guide_1988_Commodore
  Viewable window 264 x 198 mm (13.2-in class):
  https://lowendmac.com/1999/crt-screen-size-resolution-and-sharpness/
- B: Commodore 1701/1702 class 13-inch composite: Hitachi 370KNB22 tube,
  13-inch slot mask, 0.64 mm pitch
  (https://crtdatabase.com/crts/commodore/commodore-1702a); envelope
  368 W x 324 H x 395 D mm measured off the Commons front/back photos
  scaled by the 370 mm tube-class width; side carry handles noted by
  https://www.c64-wiki.com/wiki/Commodore_1702. Photo set:
  ~/scene-v2-reference/hw-refs/displays/commodore-1702/.
- C: Atari SM124-class 325 W x 307 H x 282 D mm mono display:
  https://www.atarimuseum.de/pics/scans/Manuals/sm124.pdf
- D: Monitor II-class 370 W x 270 H x 318 D mm green mono display:
  https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Peripherals/Monitors/Apple%20Monitor%20II/Manuals/Apple%20Monitor%20II%20User%27s%20Manual.pdf
  Geometry is generic and carries no Apple trade dress or marks.
- E: Amstrad CTM644-class 375 W x 340 H x 365 D mm colour display:
  https://manualzz.com/doc/64274931/amstrad-cpc664--ctm644-service-manual

SCREEN-GLASS RECTANGLES (for the live-content planes; glTF space: x right,
y up from base, z toward viewer, meters):
- Variant A: center (0.000, 0.172, 0.144), size 0.264 x 0.198.
- Variant B: center (-0.022, 0.190, 0.158), size 0.250 x 0.188.
- Variant C: center (-0.010, 0.172, 0.088), size 0.236 x 0.177.
- Variant D: center (-0.018, 0.145, 0.111), size 0.250 x 0.188.
- Variant E: center (-0.010, 0.205, 0.129), size 0.274 x 0.206.
Screen faces are dark blue-grey glass only — no emission.

No logos anywhere; badge plates stay blank. Openings are boolean cavities
with lined interiors; bezel blanks are beveled BEFORE boolean openings
(the historical CRT lesson — beveling after scallops the cut faces).

Iteration 4 — frozen best state after four design-review rounds
(judgments in ~/scene-v2-reference/review/design-judgments/param-homecrt-*):
- A: squared outer cabinet (6 mm arrises), thin dark reveal, two stepped
  funnel frames down to a 16 mm-deep convex blue-grey glass, 42 mm control
  band with really-recessed badge/trough/rocker/LED sockets, 4x15 top vent
  slots, full-width chassis for 280 mm before a short stepped taper.
- B: near-square dark bezel plate (5 mm corners) opening to 246 x 185,
  upper-right pinstripe field + recessed grille, control-panel chin (wide
  shallow dark panel, 11 mm collared RCA pair, 18 mm rocker), dark hump
  swelling to full width over the rear 275 mm, handhold recesses, twin top
  vent fields (beige collar + dark hump).
Round-4 residuals (noted, cap reached): the judge still wants even squarer
A-corners and a boxier perceived rear at the fixed near-frontal museum
angle; both would need a camera change to read. Four texture rounds
followed (warmer/lighter ivory, AO curve remap, soft blue-grey glass);
frozen at t4 with narrow tonal residuals — the judge oscillated between
"too khaki" and "too desaturated" across rounds.
"""

import sys
from math import radians
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_classicdesks as cd  # noqa: E402
import lib_display_matrix as matrix_display  # noqa: E402
import lib_modern as lm  # noqa: E402  (round_well for RCA sockets)

# Dark-brown composite-era front plastics (1702 family) are REAL dark parts
# like 70s keycaps, not painted shadow. hc-glass: broad soft CRT response.
EXTRA = {
    "hc-dark": ("#43392f", 0.56),
    "hc-dark-deep": ("#2c251e", 0.62),
    "hc-glass": ("#3a4560", 0.12),
}

PARAMS = {
    "A": dict(
        style="rgb",
        w=0.350,
        h=0.320,
        d=0.387,
        view_w=0.264,
        view_h=0.198,
        scr_z=0.172,
        sag=0.014,
        band_top=0.042,
    ),
    "B": dict(
        style="composite",
        w=0.368,
        h=0.324,
        d=0.395,
        view_w=0.244,
        view_h=0.183,
        scr_z=0.190,
        sag=0.014,
        band_top=0.058,
    ),
    "C": dict(style="sm124", w=0.325, h=0.307, d=0.282),
    "D": dict(style="monitor2", w=0.370, h=0.270, d=0.318),
    "E": dict(style="ctm644", w=0.375, h=0.340, d=0.365),
}


def hc(key):
    if key in EXTRA:
        hexc, rough = EXTRA[key]
        return lib.material(key, hexc, rough)
    return cd.mat(key)


def rounded_cap(name, w, d, h, loc, mat, r=0.004):
    """Bezel-cap blank with softly rounded outer corners, beveled BEFORE
    any boolean opening is cut into it."""
    cap = lib.box(name, (w, d, h), loc, mat)
    mod = lib.bevel(cap, width=r, segments=4)
    lib.bpy.context.view_layer.objects.active = cap
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    return cap


def glass_stack(p, x, y_glass, grow=0.004):
    """Recessed bulged soft blue-grey tube face + dark floor behind it."""
    vw, vh = p["view_w"], p["view_h"]
    lib.bulged_panel("glass", vw + grow, vh + grow, p["sag"], (x, y_glass, p["scr_z"]), hc("hc-glass"), segs=36)
    lib.box("glass-back", (vw + grow + 0.004, 0.0016, vh + grow + 0.004), (x, y_glass + 0.009, p["scr_z"]), hc("dark"))


def monitor_feet(w, d, y_f, rear_x=0.100):
    """Corner pads pulled IN under the tapered rear (nothing may float)."""
    m = cd.mat("recess-deep")
    for sx in (-1, 1):
        lib.box("foot-f", (0.034, 0.034, 0.008), (sx * (w / 2 - 0.036), y_f + 0.055, 0.004), m)
        lib.box("foot-r", (0.034, 0.034, 0.008), (sx * rear_x, y_f + d - 0.085, 0.004), m)


def top_vent_field(
    target, p, y0, z_top, rows=3, cols=13, span=0.72, gap=0.030, slot_len=0.024, floor_mat="recess-deep"
):
    """Class-defining top vent field: rows of real slot grooves over a
    floor plate hidden inside the shell (dark rhythm from above)."""
    w = p["w"]
    slots = []
    for r in range(rows):
        for c in range(cols):
            x = (c - (cols - 1) / 2.0) * (w * span / cols)
            slots.append(((0.0060, slot_len, 0.016), (x, y0 + r * gap, z_top)))
    lib.cut(target, lib.multi_box("tvents", slots))
    depth_y = (rows - 1) * gap + slot_len + 0.004
    lib.box(
        "tvent-floor",
        (w * (span + 0.02), depth_y, 0.0016),
        (0, y0 + (rows - 1) * gap / 2.0, z_top - 0.0034),
        hc(floor_mat),
    )


def framed_window(name, ow, oh, r_out, r_win, win_w, win_h, depth, loc, mat):
    """Frame with a SQUARE-ish outer edge but a rounded inner window —
    bezel_frame cannot decouple the two radii, this can."""
    outer = cd.rounded_prism(name, ow, oh, r_out, depth, loc, mat)
    hole = cd.rounded_prism(name + "-hole", win_w, win_h, r_win, depth + 0.02, (loc[0], loc[1] - 0.01, loc[2]), None)
    lib.cut(outer, hole)
    return outer


def build_rgb(p):
    """A: 1084S/CM8833-class RGB monitor — squared cabinet, funnel stack."""
    w, h, d = p["w"], p["h"], p["d"]
    fh = h - 0.008
    zc = 0.008 + fh / 2.0
    y_f = -d / 2.0
    scr_z, vw, vh = p["scr_z"], p["view_w"], p["view_h"]
    monitor_feet(w, d, y_f)

    fascia_d = 0.060
    bezel = rounded_cap("bezel", w, fascia_d, fh, (0, y_f + fascia_d / 2, zc), hc("abs"), r=0.006)
    # square panel recess -> thin dark reveal -> stepped funnel -> glass
    lib.cut(bezel, cd.rounded_prism("scr-cut", vw + 0.048, vh + 0.048, 0.010, 0.075, (0, y_f - 0.001, scr_z)))
    cd.bezel_frame("reveal", vw + 0.046, vh + 0.046, 0.009, 0.0045, 0.016, (0, y_f + 0.006, scr_z), hc("recess-deep"))
    framed_window(
        "funnel1",
        vw + 0.040,
        vh + 0.040,
        0.011,
        0.016,
        vw + 0.020,
        vh + 0.020,
        0.014,
        (0, y_f + 0.020, scr_z),
        hc("recess"),
    )
    framed_window(
        "funnel2",
        vw + 0.024,
        vh + 0.024,
        0.013,
        0.014,
        vw + 0.001,
        vh + 0.001,
        0.014,
        (0, y_f + 0.033, scr_z),
        hc("recess"),
    )
    glass_stack(p, 0.0, y_f + 0.050)
    lib.box("cavity-back", (vw + 0.056, 0.0016, vh + 0.056), (0, y_f + 0.0585, scr_z), hc("recess-deep"))

    # 42 mm control band: seam groove, inset badge, trough, rocker + LED
    band_z = (0.008 + p["band_top"]) / 2.0
    lib.cut(bezel, lib.multi_box("seam", [((w * 0.985, 0.0035, 0.0024), (0, y_f, p["band_top"]))]))
    lib.well(bezel, "badge-rec", 0.058, 0.020, y_f, -w / 2 + 0.058, band_z, 0.004, mat=hc("recess"))
    lib.box("badge", (0.050, 0.0045, 0.013), (-w / 2 + 0.058, y_f - 0.0008, band_z), hc("abs-light"))
    lib.well(bezel, "ctl", 0.118, 0.025, y_f, 0.028, band_z, 0.009, mat=hc("recess"))
    for i in range(3):
        lib.cylinder("knob", 0.0080, 0.013, "Y", (-0.008 + i * 0.030, y_f - 0.0035, band_z), hc("abs-grey"), 24)
    lib.box("slider", (0.018, 0.010, 0.0070), (0.076, y_f - 0.0025, band_z), hc("abs-grey"))
    lib.well(bezel, "pwr-rec", 0.027, 0.019, y_f, w / 2 - 0.040, band_z, 0.008, mat=hc("recess"))
    rocker = lib.box("pwr", (0.018, 0.012, 0.012), (w / 2 - 0.040, y_f - 0.0045, band_z), hc("abs-grey"))
    rocker.rotation_euler[0] = radians(6.0)
    led_x = w / 2 - 0.018
    lm.round_well(bezel, "led-socket", 0.0036, 0.004, y_f, led_x, band_z + 0.007, 12, mat=hc("recess-deep"))
    lib.cylinder(
        "led", 0.0024, 0.005, "Y", (led_x, y_f - 0.001, band_z + 0.007), lib.material("led-r", "#b0432f", 0.4), 12
    )

    # long boxy rear: full section for ~280 mm, short stepped taper after
    bw, bh = w - 0.008, fh - 0.008
    shell = lib.box("shell", (bw, 0.220, bh), (0, y_f + fascia_d + 0.110, zc), hc("abs-warm"))
    lib.loft(
        "tube",
        "Y",
        [
            (fascia_d + 0.216, bw, bh, 0.0),
            (d - 0.070, bw * 0.94, bh * 0.94, 0.002),
            (d - 0.038, bw * 0.78, bh * 0.76, 0.006),
        ],
        (0, y_f, zc),
        hc("abs-warm"),
    )
    lib.box("tail", (bw * 0.60, 0.030, bh * 0.64), (0, y_f + d - 0.026, zc + 0.010), hc("abs-warm"))
    top_vent_field(shell, p, y_f + 0.070, 0.008 + bh, rows=4, cols=15, span=0.75, gap=0.032, slot_len=0.026)
    # rear-flank vertical vent stacks (1084S-P back photo)
    for sx in (-1, 1):
        cols = [((0.010, 0.0042, 0.058), (sx * bw / 2, y_f + 0.150 + i * 0.011, zc + 0.02)) for i in range(6)]
        lib.cut(shell, lib.multi_box(f"svent{sx}", cols))
    lib.bevel(shell, 0.005, 2)


def composite_fascia(p, bezel, y_f, scr_x):
    """B front: dark bezel plate, utility strip, control-panel chin."""
    w = p["w"]
    scr_z, vw, vh = p["scr_z"], p["view_w"], p["view_h"]
    lib.cut(bezel, cd.rounded_prism("scr-cut", vw + 0.062, vh + 0.062, 0.008, 0.062, (scr_x, y_f - 0.001, scr_z)))
    framed_window(
        "frame-dark",
        vw + 0.060,
        vh + 0.050,
        0.005,
        0.020,
        vw + 0.006,
        vh + 0.005,
        0.036,
        (scr_x, y_f + 0.004, scr_z),
        hc("hc-dark"),
    )
    glass_stack(p, scr_x, y_f + 0.040, grow=0.010)
    lib.box("cavity-back", (vw + 0.070, 0.0016, vh + 0.070), (scr_x, y_f + 0.0485, scr_z), hc("hc-dark-deep"))

    # upper-right utility strip: pinstripe field over a recessed grille
    col_x = 0.156
    stripes = [((0.048, 0.0035, 0.0028), (col_x, y_f, 0.196 + i * 0.0056)) for i in range(8)]
    lib.cut(bezel, lib.multi_box("pinstripes", stripes))
    lib.well(bezel, "grille", 0.044, 0.026, y_f, col_x, 0.162, 0.006, mat=hc("hc-dark-deep"))
    bars = [((0.0028, 0.004, 0.022), (col_x - 0.014 + i * 0.007, y_f + 0.0012, 0.162)) for i in range(5)]
    bars += [((0.040, 0.004, 0.0022), (col_x, y_f + 0.0012, 0.156 + j * 0.012)) for j in range(2)]
    lib.multi_box("grille-bars", bars, hc("abs"))

    # chin: one broad shallow control panel + badge + RCA pair + rocker
    band_top = p["band_top"]
    lib.cut(bezel, lib.multi_box("seam", [((w * 0.985, 0.0035, 0.0024), (0, y_f, band_top))]))
    lib.well(bezel, "panel", 0.110, 0.012, y_f, -0.010, 0.040, 0.005, mat=hc("hc-dark-deep"))
    lib.well(bezel, "badge-rec", 0.086, 0.020, y_f, -w / 2 + 0.078, 0.040, 0.004, mat=hc("recess"))
    lib.box("badge", (0.078, 0.0045, 0.015), (-w / 2 + 0.078, y_f - 0.0008, 0.040), hc("abs-light"))
    for i, jx in enumerate((0.082, 0.104)):
        lm.round_well(bezel, f"rca{i}", 0.0060, 0.006, y_f, jx, 0.026, 20, mat=hc("hc-dark-deep"))
        lib.cylinder(f"rca-ring{i}", 0.0048, 0.012, "Y", (jx, y_f - 0.003, 0.026), hc("abs-light"), 20)
        lib.cylinder(f"rca-pin{i}", 0.0020, 0.015, "Y", (jx, y_f - 0.004, 0.026), hc("hc-dark-deep"), 12)
    lib.well(bezel, "pwr-rec", 0.024, 0.022, y_f, w / 2 - 0.044, 0.030, 0.008, mat=hc("hc-dark-deep"))
    rocker = lib.box("pwr", (0.018, 0.013, 0.016), (w / 2 - 0.044, y_f - 0.004, 0.030), hc("abs-grey"))
    rocker.rotation_euler[0] = radians(8.0)


def build_composite(p):
    """B: 1701/1702-class composite monitor — two-tone, bulbous rear hump."""
    w, h, d = p["w"], p["h"], p["d"]
    fh = h - 0.008
    zc = 0.008 + fh / 2.0
    y_f = -d / 2.0
    scr_x = -0.022  # screen offset left; utility strip on the right
    monitor_feet(w, d, y_f)

    fascia_d = 0.050
    bezel = rounded_cap("bezel", w, fascia_d, fh, (0, y_f + fascia_d / 2, zc), hc("abs"), r=0.005)
    composite_fascia(p, bezel, y_f, scr_x)

    # two-tone rear: short beige collar, dark hump swelling to full width
    bw, bh = w - 0.008, fh - 0.008
    collar = lib.box("collar", (bw, 0.070, bh), (0, y_f + fascia_d + 0.035, zc), hc("abs-warm"))
    hump = lib.loft(
        "hump",
        "Y",
        [
            (fascia_d + 0.068, bw * 0.999, bh * 0.999, 0.0),
            (0.200, bw, bh, 0.001),
            (d * 0.62, bw * 0.97, bh * 0.955, 0.004),
            (d - 0.055, bw * 0.82, bh * 0.80, 0.010),
            (d - 0.026, bw * 0.60, bh * 0.56, 0.016),
        ],
        (0, y_f, zc),
        hc("hc-dark"),
    )
    top_vent_field(collar, p, y_f + 0.054, 0.008 + bh, rows=2, cols=16, span=0.70, gap=0.022, slot_len=0.018)
    hump_slots = []
    for r in range(3):
        for c in range(16):
            x = (c - 7.5) * (w * 0.70 / 16)
            hump_slots.append(((0.0060, 0.018, 0.016), (x, y_f + 0.112 + r * 0.021, 0.008 + bh)))
    lib.cut(hump, lib.multi_box("hvents", hump_slots))
    lib.box("hvent-floor", (w * 0.72, 0.064, 0.0016), (0, y_f + 0.133, 0.008 + bh - 0.0034), hc("hc-dark-deep"))
    # one real handhold recess per flank (portable set)
    for sx in (-1, 1):
        lib.cut(hump, lib.multi_box(f"grip{sx}", [((0.026, 0.105, 0.030), (sx * 0.181, y_f + 0.185, zc + 0.085))]))
    lib.bevel(collar, 0.0035, 2)


def build(p):
    if p["style"] == "rgb":
        build_rgb(p)
    elif p["style"] == "composite":
        build_composite(p)
    elif p["style"] == "sm124":
        matrix_display.build_home_sm124()
    elif p["style"] == "monitor2":
        matrix_display.build_home_monitor2()
    else:
        matrix_display.build_home_ctm644()


# Texture-round knobs (judge round-t1 verdicts): warmer lighter ivory, less
# large-scale mottle on A, stronger small-recess AO on B, gentler edge wear.
BAKE_KW = {
    "A": dict(
        tone=(1.15, 1.135, 1.10), ao_floor=0.55, grain_mul=0.38, wear_amt=0.04, ao_samples=48, ao_curve=(0.30, 0.95)
    ),
    "B": dict(
        tone=(1.13, 1.115, 1.08), ao_floor=0.48, grain_mul=0.60, wear_amt=0.06, ao_samples=48, ao_curve=(0.30, 0.95)
    ),
    "C": dict(
        tone=(1.08, 1.08, 1.06), ao_floor=0.50, grain_mul=0.75, wear_amt=0.04, ao_samples=48, ao_curve=(0.30, 0.94)
    ),
    "D": dict(
        tone=(1.11, 1.09, 1.05), ao_floor=0.54, grain_mul=0.90, wear_amt=0.05, ao_samples=48, ao_curve=(0.30, 0.94)
    ),
    "E": dict(
        tone=(1.22, 1.22, 1.24), ao_floor=0.60, grain_mul=1.00, wear_amt=0.05, ao_samples=48, ao_curve=(0.32, 0.94)
    ),
}


def main():
    variant, out = lib.parse_args("A", "/tmp/param-homecrt.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    lib_bake.maybe_bake_export(out, **BAKE_KW[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
