"""Geometry for the HARDWARE-MATRIX CRT/home-CRT/LCD variants.

Every bezel blank is beveled and APPLIED before its screen opening is cut.
This preserves the historical anti-scalloping rule for CRT-family shells.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_classicdesks as cd  # noqa: E402
import lib_modern as lm  # noqa: E402

DISPLAY_MATERIALS = {
    "sun-grey": ("#b8b1a2", 0.58),
    "home-grey": ("#bfc0b7", 0.57),
    "home-light": ("#d3d0c4", 0.55),
    "home-dark": ("#555858", 0.60),
    "home-deep": ("#383b3b", 0.68),
}


def display_mat(key):
    hexc, rough = DISPLAY_MATERIALS[key]
    return lib.material("display-" + key, hexc, rough)


def _rounded_blank(name, w, d, h, loc, mat, radius):
    obj = lib.box(name, (w, d, h), loc, mat)
    mod = lib.bevel(obj, radius, 3)
    lib.bpy.context.view_layer.objects.active = obj
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    return obj


def _window(bezel, name, vw, vh, y_f, x, z, radius, glass_mat, sag, depth=0.040, surround_mat=None):
    cutter = cd.rounded_prism(name + "-cut", vw + 0.030, vh + 0.030, radius, depth + 0.025, (x, y_f - 0.004, z))
    lib.cut(bezel, cutter)
    cd.bezel_frame(
        name + "-surround",
        vw + 0.028,
        vh + 0.028,
        radius,
        0.015,
        depth * 0.60,
        (x, y_f + 0.003, z),
        surround_mat or display_mat("home-deep"),
    )
    lib.bulged_panel(name + "-glass", vw, vh, sag, (x, y_f + depth, z), glass_mat, segs=32)
    lib.box(name + "-back", (vw + 0.004, 0.0016, vh + 0.004), (x, y_f + depth + 0.009, z), display_mat("home-deep"))


def _feet(w, d, y_f, h=0.008):
    for sx in (-1, 1):
        for sy in (0.040, d - 0.055):
            lib.box(
                "foot",
                (0.032, 0.038, h),
                (sx * (w / 2 - 0.038), y_f + sy, h / 2),
                display_mat("home-deep"),
            )


def _tube_shell(name, w, h, d, y_f, z0, front_d, mat, wedge=0.68, rise=0.010):
    zc = z0 + h / 2
    front = lib.box(name + "-front-shell", (w - 0.010, 0.105, h - 0.010), (0, y_f + front_d + 0.0525, zc), mat)
    mod = lib.bevel(front, 0.003, 2)
    lib.bpy.context.view_layer.objects.active = front
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    tube = lib.loft(
        name + "-tube",
        "Y",
        [
            (front_d + 0.095, w - 0.012, h - 0.012, 0.0),
            (d * 0.54, (w - 0.012) * 0.88, (h - 0.012) * 0.86, rise * 0.4),
            (d - 0.042, (w - 0.012) * wedge, (h - 0.012) * wedge, rise),
        ],
        (0, y_f, zc),
        mat,
    )
    lib.box(
        name + "-tail",
        ((w - 0.012) * wedge * 0.78, 0.030, (h - 0.012) * wedge * 0.78),
        (0, d / 2 - 0.015, zc + rise),
        mat,
    )
    return front, tube


def _top_vents(target, name, w, y, z, rows=2, cols=12, mat=None):
    slots = []
    for r in range(rows):
        for c in range(cols):
            x = (c - (cols - 1) / 2) * (w * 0.68 / cols)
            slots.append(((0.005, 0.020, 0.014), (x, y + r * 0.024, z)))
    lib.cut(target, lib.multi_box(name + "-cuts", slots))
    lib.box(
        name + "-floor",
        (w * 0.71, rows * 0.024 + 0.018, 0.0016),
        (0, y + (rows - 1) * 0.012, z - 0.004),
        mat or display_mat("home-deep"),
    )


def build_crt_5151():
    """D: 5151-class green monochrome CRT, 380 x 280 x 350 mm."""
    w, h, d = 0.380, 0.280, 0.350
    y_f = -d / 2 + 0.009
    _feet(w, d, y_f)
    bezel = _rounded_blank(
        "heavy-bezel", w, 0.058, h - 0.008, (0, y_f + 0.029, 0.008 + (h - 0.008) / 2), lib.shared("abs"), 0.003
    )
    _window(
        bezel,
        "screen",
        0.244,
        0.183,
        y_f,
        -0.025,
        0.157,
        0.010,
        lib.material("cd-green-glass", "#27483a", 0.20),
        0.028,
        0.044,
        lib.shared("abs-warm"),
    )
    front, _ = _tube_shell(
        "square-shell", w, h - 0.008, d, y_f, 0.008, 0.058, lib.shared("abs-warm"), wedge=0.76, rise=0.004
    )
    _top_vents(front, "top-vents", w, y_f + 0.092, h - 0.004, 2, 13)
    for i, z in enumerate((0.070, 0.044)):
        lm.round_well(bezel, f"knob-well{i}", 0.011, 0.006, y_f, 0.145, z, 24, lib.shared("recess"))
        lib.cylinder(f"knob{i}", 0.0085, 0.012, "Y", (0.145, y_f - 0.003, z), lib.shared("abs-grey"), 24)


def build_crt_sun():
    """E: Sun/Sony 17-inch engineering CRT, 404 x 426 x 450 mm."""
    w, h, d = 0.404, 0.426, 0.450
    y_f, z0, head_h = -d / 2 + 0.006, 0.066, 0.360
    # Wide tilt/swivel foot; overall top remains exactly 426 mm.
    foot = lib.box("wide-foot", (0.330, 0.280, 0.034), (0, y_f + 0.050 + 0.140, 0.017), display_mat("sun-grey"))
    lib.bevel(foot, 0.006, 2)
    lib.cylinder("swivel", 0.085, 0.032, "Z", (0, y_f + 0.185, 0.044), display_mat("sun-grey"), 32)
    bezel = _rounded_blank(
        "broad-bezel", w, 0.058, head_h, (0, y_f + 0.029, z0 + head_h / 2), display_mat("sun-grey"), 0.007
    )
    _window(
        bezel,
        "screen",
        0.320,
        0.240,
        y_f,
        0,
        0.258,
        0.014,
        lib.material("shared-glass", "#2c3435", 0.18),
        0.025,
        0.045,
    )
    front, _ = _tube_shell("wedge-shell", w, head_h, d, y_f, z0, 0.058, display_mat("sun-grey"), wedge=0.58, rise=0.018)
    _top_vents(front, "top-vents", w, y_f + 0.095, h - 0.004, 3, 14)
    strip_z = 0.105
    lib.well(bezel, "control-strip", 0.174, 0.023, y_f, 0.050, strip_z, 0.006, mat=lib.shared("recess"))
    for i in range(5):
        lib.box("control", (0.012, 0.008, 0.008), (0.002 + i * 0.024, y_f - 0.002, strip_z), lib.shared("abs-grey"))
    lib.cylinder("power", 0.008, 0.008, "Y", (0.154, y_f - 0.002, strip_z), lib.shared("abs-grey"), 24)


def build_home_sm124():
    """C: SM124-class pale-grey mono CRT, 325 x 307 x 282 mm."""
    w, h, d = 0.325, 0.307, 0.282
    y_f, z0 = -d / 2 + 0.0115, 0.030
    foot = cd.profile_shell(
        "fixed-wedge-foot",
        0.285,
        [(y_f + 0.025, 0.0), (y_f + 0.230, 0.0), (y_f + 0.205, z0), (y_f + 0.050, 0.022)],
        mat_=display_mat("home-grey"),
    )
    lib.bevel(foot, 0.003, 2)
    lib.box("foot-bridge", (0.230, 0.120, 0.022), (0, y_f + 0.110, 0.025), display_mat("home-grey"))
    bezel = _rounded_blank(
        "chamfered-bezel", w, 0.050, h - z0, (0, y_f + 0.025, z0 + (h - z0) / 2), display_mat("home-grey"), 0.007
    )
    _window(
        bezel,
        "screen",
        0.236,
        0.177,
        y_f,
        -0.010,
        0.172,
        0.007,
        lib.material("hc-glass", "#303a40", 0.13),
        0.024,
        0.042,
    )
    front, _ = _tube_shell(
        "crisp-shell", w, h - z0, d, y_f, z0, 0.050, display_mat("home-grey"), wedge=0.68, rise=0.008
    )
    _top_vents(front, "top-vents", w, y_f + 0.078, h - 0.004, 2, 12)
    lib.box("lower-ledge", (w - 0.020, 0.015, 0.018), (0, y_f - 0.004, z0 + 0.018), display_mat("home-light"))
    for i, x in enumerate((0.102, 0.126)):
        lib.cylinder(f"control{i}", 0.007, 0.010, "Y", (x, y_f - 0.006, 0.048), display_mat("home-dark"), 20)


def build_home_monitor2():
    """D: Monitor II-class green mono CRT, 370 x 270 x 318 mm."""
    w, h, d = 0.370, 0.270, 0.318
    y_f = -d / 2 + 0.008
    _feet(w, d, y_f, 0.007)
    bezel = _rounded_blank(
        "low-bezel", w, 0.052, h - 0.007, (0, y_f + 0.026, 0.007 + (h - 0.007) / 2), display_mat("home-light"), 0.006
    )
    _window(
        bezel,
        "screen",
        0.250,
        0.188,
        y_f,
        -0.018,
        0.145,
        0.014,
        lib.material("cd-green-glass", "#315e48", 0.20),
        0.017,
        0.040,
    )
    front, _ = _tube_shell(
        "compact-shell", w, h - 0.007, d, y_f, 0.007, 0.052, display_mat("home-grey"), wedge=0.70, rise=0.006
    )
    _top_vents(front, "top-vents", w, y_f + 0.076, h - 0.004, 2, 13)
    lm.round_well(bezel, "top-power-well", 0.008, 0.005, y_f, 0.142, 0.239, 22, display_mat("home-dark"))
    lib.cylinder("top-power", 0.006, 0.008, "Y", (0.142, y_f - 0.002, 0.239), display_mat("home-dark"), 22)
    lm.round_well(bezel, "tuning-well", 0.009, 0.005, y_f, 0, 0.028, 24, display_mat("home-dark"))
    lib.cylinder("tuning", 0.0065, 0.010, "Y", (0, y_f - 0.003, 0.028), display_mat("home-dark"), 24)


def build_home_ctm644():
    """E: CTM644-class colour CRT, 375 x 340 x 365 mm."""
    w, h, d = 0.375, 0.340, 0.365
    y_f = -d / 2 + 0.0085
    _feet(w, d, y_f)
    bezel = _rounded_blank(
        "dark-bezel", w, 0.058, h - 0.008, (0, y_f + 0.029, 0.008 + (h - 0.008) / 2), display_mat("home-dark"), 0.004
    )
    _window(
        bezel,
        "screen",
        0.274,
        0.206,
        y_f,
        -0.010,
        0.205,
        0.018,
        lib.material("hc-glass", "#465361", 0.20),
        0.012,
        0.045,
    )
    front, _ = _tube_shell(
        "blocky-shell", w, h - 0.008, d, y_f, 0.008, 0.058, display_mat("home-dark"), wedge=0.72, rise=0.004
    )
    _top_vents(front, "top-vents", w, y_f + 0.090, h - 0.004, 3, 13, display_mat("home-deep"))
    # Broad lower control band with real recessed trough and proud controls.
    lib.well(bezel, "control-band", 0.240, 0.040, y_f, 0.010, 0.050, 0.007, mat=display_mat("home-deep"))
    for i in range(2):
        lib.cylinder("knob", 0.0075, 0.011, "Y", (-0.060 + i * 0.035, y_f - 0.003, 0.050), display_mat("home-grey"), 22)
    lib.well(bezel, "side-switch-well", 0.028, 0.025, y_f, 0.155, 0.050, 0.006, mat=display_mat("home-deep"))
    lib.box("side-power", (0.018, 0.010, 0.016), (0.155, y_f - 0.003, 0.050), display_mat("home-grey"))
    # Power lead heads forward toward the CPC body without exceeding the set's
    # measured body-depth envelope.
    lib.cylinder("power-lead", 0.004, 0.060, "Y", (0.125, d / 2 - 0.030, 0.030), display_mat("home-deep"), 12)


def _lcd_mat(key):
    values = {
        "shell": ("#5a5e63", 0.62),
        "bezel": ("#44484d", 0.58),
        "deep": ("#292d31", 0.70),
        "button": ("#8a8f94", 0.54),
        "glass": ("#333d49", 0.16),
    }
    hexc, rough = values[key]
    return lib.material("lcd-" + ("btn" if key == "button" else key), hexc, rough)


def build_lcd_office():
    """C: 17-inch 5:4 office LCD, 367 x 384 x 188 mm."""
    w, h, d = 0.367, 0.384, 0.188
    view_w, view_h = 0.338, 0.270
    z0, head_h = 0.065, h - 0.065
    y_f = -0.055
    # Broad rounded-rectangle foot fills the specified 188 mm depth.
    lm.rounded_slab("foot", 0.255, d, 0.014, 0.035, (0, 0.012, 0), _lcd_mat("shell"))
    lm.rounded_slab("foot-top", 0.220, 0.150, 0.010, 0.026, (0, 0.008, 0.0135), _lcd_mat("shell"))
    stem = lib.box("rectangular-stem", (0.072, 0.045, 0.210), (0, 0.035, 0.023 + 0.105), _lcd_mat("shell"))
    lib.bevel(stem, 0.005, 2)
    lib.cylinder("tilt-hinge", 0.018, 0.090, "X", (0, 0.018, 0.092), _lcd_mat("button"), 24)
    bezel = _rounded_blank("thick-bezel", w, 0.020, head_h, (0, y_f + 0.010, z0 + head_h / 2), _lcd_mat("bezel"), 0.003)
    zc = z0 + 0.027 + view_h / 2
    lib.cut(bezel, lib.box("panel-cut", (view_w + 0.002, 0.060, view_h + 0.002), (0, y_f, zc)))
    lib.pocket(
        "panel-liner", view_w + 0.001, view_h + 0.001, 0.008, (0, y_f + 0.0003, zc), 0.0012, _lcd_mat("deep"), False
    )
    lib.box("glass", (view_w, 0.0016, view_h), (0, y_f + 0.004, zc), _lcd_mat("glass"))
    lib.box("glass-back", (view_w + 0.004, 0.0016, view_h + 0.004), (0, y_f + 0.008, zc), _lcd_mat("deep"))
    # Lower-right OSD row survives at 2-4 m as a grouped horizontal rhythm.
    lib.well(bezel, "button-trough", 0.104, 0.015, y_f, 0.108, 0.078, 0.004, mat=_lcd_mat("deep"))
    for i in range(5):
        lib.box("osd-button", (0.012, 0.006, 0.008), (0.072 + i * 0.019, y_f - 0.002, 0.078), _lcd_mat("button"))
    # Shallow CCFL-era rear bulge and top vent bank.
    back = lib.box(
        "rear-shell", (w - 0.006, 0.036, head_h - 0.006), (0, y_f + 0.038, z0 + head_h / 2), _lcd_mat("shell")
    )
    bulge = lib.box("rear-bulge", (0.285, 0.042, 0.225), (0, y_f + 0.077, 0.230), _lcd_mat("shell"))
    mod = lib.bevel(bulge, 0.006, 2)
    lib.bpy.context.view_layer.objects.active = bulge
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    _top_vents(bulge, "rear-vents", 0.285, y_f + 0.067, 0.344, 2, 15, _lcd_mat("deep"))
    lib.bevel(back, 0.002, 1)
