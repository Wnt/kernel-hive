"""Parametric CRT monitors (variants A-E).

Run headless:
  blender -b --python blender/gen_crt.py -- --variant B --out /path/crt-b.glb

Iteration 3 keeps iteration 2's modeled depth while separating the control
strip, glass backing, and bezel geometry so their solids cannot intersect.
Iteration 2 replaced every painted
dark detail with modeled depth — the glass sits behind a chamfered frustum
opening (sloped beige walls shade themselves), the control strip is a lined
blind recess with proud grey-beige buttons, the top vents are REAL grooves
(iteration 1's cutters missed the shell top by 1 mm and cut nothing) over a
warm-grey floor, and the bezel/shell corners are softly rounded. Near-black
remains only on the screen glass itself.

Real-world dimensional ground truth (do not invent proportions):
- Generic 14" color CRT datasheet: 350 W x 350 H x 360 D mm
  https://docs.rs-online.com/b4d8/0900766b80a7d69f.pdf
- 14" class CRTs are ~355 mm wide; a "14 inch" tube has ~13.2" viewable
  diagonal (=> 4:3 viewable ~268 x 201 mm)
  https://lowendmac.com/1999/crt-screen-size-resolution-and-sharpness/
  https://crtdatabase.com/crts/ibm/ibm-14v  (13" viewable, front buttons)
- Shape language (bezel cap proud of shell, deep glass recess, bulged
  face, bottom control strip, swivel base): Wikimedia Commons refs
  https://commons.wikimedia.org/wiki/File:Schneider-MM12-Monochrome-Monitor-1.jpg
  https://commons.wikimedia.org/wiki/File:Commodore1084_first_version_front.jpg
- D: IBM 5151-class 380 W x 280 H x 350 D mm green monochrome display.
  https://www.radiomuseum.org/r/ibm_monochrome_monitor_5151.html
  https://www.minuszerodegrees.net/manuals/IBM_5150_Technical_Reference_6025005_AUG81.pdf
- E: Sun/Sony GDM 17-inch class 404 W x 426 H x 450 D mm workstation CRT.
  https://shrubbery.net/~heas/sun-feh-2_1/Systems/Sun4/MONITOR_17_Premium_CRT.html
  https://pro.sony/s3/cms-static-content/operation-manual/3800980161.pdf

SCREEN-GLASS RECTANGLES (live-content planes; glTF x right, y up, z front):
- Variant D: center (-0.025, 0.157, 0.122), size 0.244 x 0.183 m.
- Variant E: center (0.000, 0.258, 0.174), size 0.320 x 0.240 m.
Screens are non-emissive dark glass; D carries only a dark green tint.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_display_matrix as matrix_display  # noqa: E402

BEZEL_D = 0.040  # bezel cap depth; the glass recess lives inside it
BEZEL_ROUND = 0.003  # rounded blank corners stay clear of the control opening

# view_* = 4:3 viewable glass; sag = geometric bulge of the tube face.
PARAMS = {
    "A": dict(  # compact 13"-class, twin analog knobs, fixed plinth
        w=0.340,
        fh=0.255,
        d=0.360,
        view_w=0.244,
        view_h=0.183,
        sag=0.008,
        controls="knobs",
        base="plinth",
        z0=0.050,
    ),
    "B": dict(  # classic 14" office SVGA, button strip, swivel base
        w=0.355,
        fh=0.270,
        d=0.380,
        view_w=0.268,
        view_h=0.201,
        sag=0.007,
        controls="buttons",
        base="swivel",
        z0=0.055,
    ),
    "C": dict(  # big 15"-class pro, fold-down door, wide swivel
        w=0.375,
        fh=0.285,
        d=0.410,
        view_w=0.282,
        view_h=0.211,
        sag=0.005,
        controls="panel",
        base="swivel",
        z0=0.058,
    ),
    "D": dict(style="mono-5151", w=0.380, fh=0.280, d=0.350),
    "E": dict(style="sun-17", w=0.404, fh=0.426, d=0.450),
}


def glass_recess(bezel, p, y_f, scr_z):
    """Chamfered frustum opening; the bulged glass sits well behind it."""
    vw, vh = p["view_w"], p["view_h"]
    cutter = lib.loft(
        "glass-cut",
        "Y",
        [
            (-0.006, vw + 0.030, vh + 0.030, 0.0),
            (0.018, vw + 0.006, vh + 0.006, 0.0),
            (0.032, vw + 0.006, vh + 0.006, 0.0),
        ],
        (0, y_f, scr_z),
    )
    lib.cut(bezel, cutter)
    lib.bulged_panel("glass", vw + 0.004, vh + 0.004, p["sag"], (0, y_f + 0.014, scr_z), lib.shared("glass"))
    lib.box("glass-back", (vw + 0.004, 0.002, vh + 0.004), (0, y_f + 0.019, scr_z), lib.shared("dark"))


def round_bezel_blank(bezel):
    """Round only the blank's outer corners before its front is booleaned."""
    modifier = lib.bevel(bezel, width=BEZEL_ROUND, segments=3)
    lib.bpy.context.view_layer.objects.active = bezel
    lib.bpy.ops.object.modifier_apply(modifier=modifier.name)


def control_strip(bezel, p, y_f, scr_z):
    """Lined blind recess with PROUD grey-beige controls (no black paint)."""
    vw = p["view_w"]
    strip_z = scr_z - p["view_h"] / 2 - 0.029
    if p["controls"] == "knobs":
        lib.well(bezel, "ctl", 0.164, 0.022, y_f, 0.05, strip_z, 0.007, mat=lib.shared("recess"))
        for i in range(2):
            lib.cylinder(
                "knob", 0.0085, 0.014, "Y", (0.09 - i * 0.035, y_f - 0.003, strip_z), lib.shared("abs-grey"), 24
            )
        lib.box("pwr-sw", (0.016, 0.011, 0.011), (0.03, y_f - 0.0025, strip_z), lib.shared("abs-grey"))
    elif p["controls"] == "buttons":
        lib.well(bezel, "ctl", vw * 0.9, 0.020, y_f, 0.0, strip_z, 0.007, mat=lib.shared("recess"))
        for i in range(4):
            lib.box("btn", (0.012, 0.011, 0.009), (-0.045 + i * 0.022, y_f - 0.003, strip_z), lib.shared("abs-grey"))
        lib.box("pwr-btn", (0.015, 0.011, 0.010), (vw * 0.45 - 0.014, y_f - 0.003, strip_z), lib.shared("abs-grey"))
        led_x = vw * 0.45 + 0.004
        lib.cut(bezel, lib.box("pwr-led-cut", (0.0044, 0.008, 0.0044), (led_x, y_f + 0.002, strip_z)))
        lib.box(
            "pwr-led",
            (0.004, 0.0036, 0.004),
            (led_x, y_f - 0.0016, strip_z),
            lib.material("led-g", "#3fae4a", 0.4),
        )
    else:  # closed fold-down door, proud of the bezel with a REAL top gap
        lib.well(bezel, "door-rec", vw * 0.76, 0.024, y_f, 0.0, strip_z, 0.007, mat=lib.shared("recess"))
        lib.box("door", (vw * 0.72, 0.005, 0.019), (0, y_f - 0.0008, strip_z - 0.0005), lib.shared("abs-grey"))
        pwr_x = vw * 0.45
        lib.cut(bezel, lib.box("pwr-cut", (0.017, 0.008, 0.012), (pwr_x, y_f + 0.002, strip_z)))
        lib.box("pwr-btn", (0.015, 0.011, 0.010), (pwr_x, y_f - 0.003, strip_z), lib.shared("abs-grey"))


def build(p):
    if p.get("style") == "mono-5151":
        matrix_display.build_crt_5151()
        return
    if p.get("style") == "sun-17":
        matrix_display.build_crt_sun()
        return
    w, fh, d, z0 = p["w"], p["fh"], p["d"], p["z0"]
    y_f = -d / 2.0
    zc = z0 + fh / 2.0  # body vertical center
    scr_z = zc + 0.008  # screen slightly high; controls live below

    # --- shell: bezel cap + front box + tube taper + rear cap -------------
    bezel = lib.box("bezel", (w, BEZEL_D, fh), (0, y_f + BEZEL_D / 2, zc), lib.shared("abs"))
    round_bezel_blank(bezel)
    shell = lib.box("shell", (w - 0.010, 0.132, fh - 0.010), (0, y_f + BEZEL_D + 0.066, zc), lib.shared("abs-warm"))
    bw, bh = w - 0.010, fh - 0.010
    lib.loft(
        "tube",
        "Y",
        [
            (y_f + 0.168, bw, bh, 0.0),
            (y_f + 0.246, bw * 0.86, bh * 0.86, 0.006),
            (y_f + d - 0.062, bw * 0.62, bh * 0.62, 0.012),
        ],
        (0, 0, zc),
        lib.shared("abs-warm"),
    )
    lib.box("tail", (bw * 0.60, 0.032, bh * 0.60), (0, y_f + d - 0.046, zc + 0.012), lib.shared("abs-warm"))
    lib.box("neck", (bw * 0.30, 0.018, bh * 0.30), (0, y_f + d - 0.024, zc + 0.010), lib.shared("recess-deep"))

    glass_recess(bezel, p, y_f, scr_z)
    control_strip(bezel, p, y_f, scr_z)

    # --- top vent grooves: REAL blind cuts over a warm-grey floor ----------
    zst = z0 + fh - 0.005  # shell top surface
    n = 11
    grooves = []
    for i in range(n):
        x = (i - (n - 1) / 2.0) * (w * 0.62 / n)
        grooves.append(((0.0038, 0.085, 0.010), (x, y_f + 0.098, zst)))
    lib.cut(shell, lib.multi_box("vents", grooves))
    lib.box("vent-floor", (w * 0.64, 0.081, 0.0016), (0, y_f + 0.098, zst - 0.0038), lib.shared("recess-deep"))

    # --- base ---------------------------------------------------------------
    bd = d * 0.66
    if p["base"] == "plinth":
        pl = lib.box(
            "plinth", (w * 0.78, bd, z0 - 0.006), (0, y_f + 0.035 + bd / 2, (z0 - 0.006) / 2), lib.shared("abs-warm")
        )
    else:
        pl = lib.box("plinth", (w * 0.80, bd, 0.030), (0, y_f + 0.03 + bd / 2, 0.015), lib.shared("abs-warm"))
        bm = lib.new_bm()
        ret = lib.bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=0.085)
        lib.bmesh.ops.scale(bm, vec=(1.0, 1.15, 0.5), verts=ret["verts"])
        lib.finalize(bm, "swivel-dome", lib.shared("abs-warm"), (0, y_f + 0.05 + bd / 2, 0.030))
    lib.bevel(pl, width=0.0045, segments=2)
    lib.bevel(shell, width=0.0035, segments=2)


def main():
    variant, out = lib.parse_args("B", "/tmp/param-crt.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    bake_kw = dict(
        tone=(1.06, 1.055, 1.03),
        ao_floor=0.50,
        ao_curve=(0.30, 0.94),
        grain_mul=0.80,
        wear_amt=0.04,
        rough=0.57,
        ao_samples=48,
    )
    if variant == "D":
        bake_kw.update(tone=(1.18, 1.14, 1.04), ao_floor=0.54, grain_mul=0.50, wear_amt=0.03)
    elif variant == "E":
        bake_kw.update(tone=(1.10, 1.095, 1.07), ao_floor=0.54, grain_mul=0.55, wear_amt=0.03)
    lib_bake.maybe_bake_export(out, **bake_kw)


if __name__ == "__main__" and lib.bpy is not None:
    main()
