"""Parametric LCD-era desktop monitors (variants A-C).

Run headless:
  blender -b --python blender/gen_lcd.py -- --variant A --out /tmp/lcd-a.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

Replaces the sourced "monitorA" poly model behind winxp/toaruos/win11/
macos/qnx tiles. Generic, logo-free, charcoal ABS (the MJ abs-charcoal
grain family) — NOT the aged-beige retro palette.

Real-world dimensional ground truth (do not invent proportions):
- A: 2001-2004 15-inch 4:3 LCD, Samsung SyncMaster 152B class: set
  357.5 W x 184.5 D x 346.7 H mm on stand (folded head 357.5 x 50.7 x
  288.5), display area 304.1 x 228.1 mm, 0.297 mm pitch, VESA 75:
  SyncMaster 152B/152V user manual, Specifications appendix:
  https://archive.org/details/manualsbase-id-80262
  Chunky-bezel + square lamp-base stance from the photo set
  ~/scene-v2-reference/hw-refs/displays/lcd-15in/ (EIZO L461 et al).
- B: modern 23.8-inch 16:9 thin-bezel office monitor: active area
  527.0 x 296.5 mm follows from the marketed diagonal at 16:9
  (https://en.wikipedia.org/wiki/Display_size); VESA FDMI 100x100 rear
  mount (https://en.wikipedia.org/wiki/Flat_Display_Mounting_Interface);
  bezel/stand proportions measured off the Commons photos in
  ~/scene-v2-reference/hw-refs/displays/lcd-24in/.
- C: EIZO S1703-class 17-inch 5:4 office display, 367 W x 384 H x
  188 D mm on its tilt stand:
  https://www.eizo.com/products/flexscan/s1703/

SCREEN-GLASS RECTANGLES (for the live-content planes; glTF space: x right,
y up from base, z toward viewer, meters):
- Variant A: center (0.000, 0.205, 0.067), size 0.304 x 0.228.
- Variant B: center (0.000, 0.245, 0.026), size 0.527 x 0.297.
- Variant C: center (0.000, 0.227, 0.051), size 0.338 x 0.270.
Screen faces are dark glass only — no emission.

No logos anywhere. Openings are boolean cavities with lined interiors;
bezel blanks are beveled BEFORE boolean openings (the historical CRT
lesson — beveling after scallops the cut faces).

Iteration 4 + three texture rounds — frozen best state (judgments in
~/scene-v2-reference/review/design-judgments/param-lcd-{a,b}/): A grew a
layered lamp base, inclined column, hinge barrel, ribbed OSD band and
deep rear bulge; B a slim tapered raked column with mount block and
collars. Residuals (cap reached): the near-frontal museum camera hides
the stand mass and every rear feature (bulge/vents/VESA exist in
geometry but cannot be proven in-frame), and the judge keeps asking for
lighter charcoal + stronger recess AO in a narrowing band.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_display_matrix as matrix_display  # noqa: E402
import lib_modern as lm  # noqa: E402  (rounded slabs, round wells)

# Office-LCD charcoal ABS palette. lcd-glass is the panel face: an off LCD
# is a very dark glossy grey, flatter and colder than CRT glass.
MATERIALS = {
    "lcd-shell": ("#46484c", 0.60),
    "lcd-bezel": ("#33363a", 0.55),
    "lcd-deep": ("#232528", 0.68),
    "lcd-btn": ("#55585c", 0.50),
    "lcd-glass": ("#2e3540", 0.10),
    "lcd-led": ("#78b06a", 0.40),
    "lcd-led-w": ("#b8c4cc", 0.40),
}

PARAMS = {
    "A": dict(style="early", view_w=0.3041, view_h=0.2281),
    "B": dict(style="modern", view_w=0.527, view_h=0.2965),
    "C": dict(style="office-5x4", view_w=0.338, view_h=0.270),
}


def mat(key):
    hexc, rough = MATERIALS[key]
    return lib.material(key, hexc, rough)


def rounded_cap(name, w, d, h, loc, m, r=0.003):
    """Head-bezel blank, beveled BEFORE the panel opening is cut."""
    cap = lib.box(name, (w, d, h), loc, m)
    mod = lib.bevel(cap, width=r, segments=3)
    lib.bpy.context.view_layer.objects.active = cap
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    return cap


def panel_stack(bezel, vw, vh, y_face, zc, reveal=0.0035, xc=0.0):
    """Recessed flat LCD panel: cut window, dark liner, glass, backing."""
    lib.cut(bezel, lib.multi_box("win-cut", [((vw + 0.002, 0.08, vh + 0.002), (xc, y_face, zc))]))
    lib.pocket(
        "win-liner",
        vw + 0.0014,
        vh + 0.0014,
        reveal + 0.004,
        (xc, y_face + 0.0003, zc),
        0.0012,
        mat("lcd-deep"),
        back=False,
    )
    lib.box("glass", (vw + 0.001, 0.0015, vh + 0.001), (xc, y_face + reveal, zc), mat("lcd-glass"))
    lib.box("glass-back", (vw + 0.004, 0.0016, vh + 0.004), (xc, y_face + reveal + 0.003, zc), mat("lcd-deep"))


def vesa_boss(y_back, zc, pitch=0.075):
    """Rear mount boss: square plate + four screw dimples (VESA FDMI)."""
    lib.box("vesa", (pitch + 0.024, 0.005, pitch + 0.024), (0, y_back, zc), mat("lcd-shell"))
    for sx in (-1, 1):
        for sz in (-1, 1):
            lib.cylinder(
                "vesa-screw",
                0.0028,
                0.004,
                "Y",
                (sx * pitch / 2, y_back + 0.0015, zc + sz * pitch / 2),
                mat("lcd-deep"),
                10,
            )


def build_early(p):
    """A: 15-inch 4:3 office LCD on a square lamp base (2001-2004)."""
    vw, vh = p["view_w"], p["view_h"]
    head_w, head_h = 0.3575, 0.2885
    z0 = 0.058  # head bottom above desk
    zc = z0 + head_h / 2
    y_f = -0.070  # head front plane
    scr_zc = z0 + 0.038 + vh / 2  # 38 mm ribbed control band below panel

    # layered square lamp base + inclined column + pivot housing
    lm.rounded_slab("base", 0.240, 0.185, 0.014, 0.020, (0, 0.004, 0.0), mat("lcd-shell"))
    lm.rounded_slab("base-top", 0.212, 0.162, 0.013, 0.015, (0, 0.001, 0.0138), mat("lcd-shell"))
    lib.loft(
        "column",
        "Z",
        [(0.024, 0.080, 0.072, 0.045), (0.120, 0.070, 0.052, 0.000), (0.208, 0.062, 0.042, -0.040)],
        (0, 0.0, 0.0),
        mat("lcd-shell"),
    )
    hinge = lib.box("hinge-house", (0.080, 0.048, 0.050), (0, -0.030, 0.080), mat("lcd-shell"))
    lib.bevel(hinge, 0.006, 2)
    lib.cylinder("hinge", 0.019, 0.088, "X", (0, -0.038, 0.062), mat("lcd-btn"), 24)

    bezel = rounded_cap("head-bezel", head_w, 0.018, head_h, (0, y_f + 0.009, zc), mat("lcd-bezel"))
    panel_stack(bezel, vw, vh, y_f, scr_zc)

    # ribbed 38 mm chin band: full-width grooves + grouped OSD keys
    ribs = [((head_w * 0.88, 0.0030, 0.0024), (0, y_f, z0 + 0.0055 + i * 0.0046)) for i in range(5)]
    lib.cut(bezel, lib.multi_box("ribs", ribs))
    band_z = z0 + 0.0295
    lib.well(bezel, "osd-rec", 0.124, 0.015, y_f, 0.056, band_z, 0.003, mat=mat("lcd-deep"))
    for i, (bx, bw_) in enumerate(
        ((0.006, 0.0160), (0.028, 0.0120), (0.047, 0.0120), (0.066, 0.0120), (0.090, 0.0180))
    ):
        lib.box(f"osd-btn{i}", (bw_, 0.0050, 0.0090), (bx, y_f - 0.0015, band_z), mat("lcd-btn"))
    lib.box("led", (0.0042, 0.0036, 0.0042), (0.126, y_f - 0.0010, band_z), mat("lcd-led"))
    lm.round_well(bezel, "pwr", 0.0095, 0.003, y_f, 0.146, band_z, 24, mat=mat("lcd-deep"))
    lib.cylinder("pwr-btn", 0.0080, 0.0070, "Y", (0.146, y_f - 0.002, band_z), mat("lcd-btn"), 24)
    # blank brand plate stays empty (logo-free) but is a real inset
    lib.well(bezel, "brand", 0.052, 0.011, y_f, -0.118, band_z, 0.0025, mat=mat("lcd-deep"))

    # body + deep rear bulge with vent grooves, VESA 75 boss
    body = lib.box("body", (head_w - 0.004, 0.033, head_h - 0.004), (0, y_f + 0.0345, zc), mat("lcd-shell"))
    bulge = lib.box("bulge", (0.280, 0.020, 0.230), (0, y_f + 0.058, zc + 0.004), mat("lcd-shell"))
    grooves = [((0.0045, 0.034, 0.012), (-0.112 + i * 0.016, y_f + 0.056, zc + 0.119)) for i in range(15)]
    lib.cut(bulge, lib.multi_box("vents", grooves))
    lib.box("vent-floor", (0.260, 0.028, 0.0016), (0, y_f + 0.056, zc + 0.112), mat("lcd-deep"))
    vesa_boss(y_f + 0.0695, zc)
    lib.bevel(body, 0.0025, 2)
    lib.bevel(bulge, 0.0018, 1)


def build_modern(p):
    """B: 23.8-inch 16:9 thin-bezel monitor on a slim flat stand."""
    vw, vh = p["view_w"], p["view_h"]
    head_w, head_h = 0.540, 0.320
    z0 = 0.078
    zc = z0 + head_h / 2
    y_f = -0.030
    scr_zc = z0 + 0.019 + vh / 2  # 19 mm chin under the panel

    # flat rectangular base plate + slim tapered raked column + collars
    lm.rounded_slab("base", 0.275, 0.185, 0.007, 0.010, (0, 0.012, 0.0), mat("lcd-shell"))
    lm.rounded_slab("base-collar", 0.058, 0.036, 0.007, 0.008, (0, 0.056, 0.0065), mat("lcd-shell"))
    lib.loft(
        "column",
        "Z",
        [(0.012, 0.030, 0.020, 0.064), (0.290, 0.026, 0.017, 0.030)],
        (0, 0.0, 0.0),
        mat("lcd-shell"),
    )
    mount = lib.box("mount-block", (0.064, 0.040, 0.085), (0, 0.022, 0.140), mat("lcd-shell"))
    lib.bevel(mount, 0.006, 2)

    bezel = rounded_cap("head-bezel", head_w, 0.008, head_h, (0, y_f + 0.004, zc), mat("lcd-bezel"), r=0.002)
    panel_stack(bezel, vw, vh, y_f, scr_zc, reveal=0.0035)

    # chin: tiny power LED right, blank inset center-left
    lib.box("led", (0.0030, 0.0026, 0.0030), (0.235, y_f - 0.0006, z0 + 0.0095), mat("lcd-led-w"))
    lib.well(bezel, "brand", 0.056, 0.009, y_f, 0.0, z0 + 0.0095, 0.0028, mat=mat("lcd-deep"))

    # slim spine + lower electronics bulge with a top vent band, VESA 100
    spine = lib.box("spine", (head_w - 0.004, 0.012, head_h - 0.004), (0, y_f + 0.013, zc), mat("lcd-shell"))
    bulge = lib.box("bulge", (0.330, 0.026, 0.225), (0, y_f + 0.031, z0 + 0.128), mat("lcd-shell"))
    grooves = [((0.0045, 0.024, 0.012), (-0.144 + i * 0.016, y_f + 0.030, z0 + 0.235)) for i in range(19)]
    lib.cut(bulge, lib.multi_box("vents", grooves))
    lib.box("vent-floor", (0.310, 0.020, 0.0016), (0, y_f + 0.030, z0 + 0.228), mat("lcd-deep"))
    vesa_boss(y_f + 0.0455, z0 + 0.128, pitch=0.100)
    lib.bevel(spine, 0.0020, 2)
    lib.bevel(bulge, 0.0016, 1)


def build(p):
    if p["style"] == "early":
        build_early(p)
    elif p["style"] == "modern":
        build_modern(p)
    else:
        matrix_display.build_lcd_office()


# Texture-round knobs: charcoal office plastic — neutral tone, restrained
# grain, AO concentrated in the tight seams.
BAKE_KW = {
    "A": dict(
        tone=(1.07, 1.07, 1.09), ao_floor=0.45, grain_mul=1.6, wear_amt=0.07, ao_samples=48, ao_curve=(0.35, 0.92)
    ),
    "B": dict(
        tone=(1.04, 1.045, 1.07), ao_floor=0.48, grain_mul=1.3, wear_amt=0.06, ao_samples=48, ao_curve=(0.35, 0.92)
    ),
    "C": dict(
        tone=(1.18, 1.185, 1.21), ao_floor=0.60, grain_mul=1.3, wear_amt=0.05, ao_samples=48, ao_curve=(0.34, 0.92)
    ),
}


def main():
    variant, out = lib.parse_args("A", "/tmp/param-lcd.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    lib_bake.maybe_bake_export(out, **BAKE_KW[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
