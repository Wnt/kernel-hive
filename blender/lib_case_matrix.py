"""Geometry for the HARDWARE-MATRIX case variants.

Shared by gen_pizzabox, gen_tower, and gen_modern. Dimensions are meters;
front is -Y and every envelope starts at z=0. Identity marks are deliberately
absent: the PS/2-derived parts retain only generic industrial-design rhythm.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_classicdesks as cd  # noqa: E402
import lib_modern as lm  # noqa: E402

CASE_MATERIALS = {
    "silver": ("#d9dcda", 0.46, 0.16),
    "silver-light": ("#ececea", 0.48, 0.10),
    "graphite": ("#3d4145", 0.62, 0.0),
    "graphite-light": ("#555a5e", 0.58, 0.0),
    "black": ("#3b3f44", 0.68, 0.0),
    "black-deep": ("#292c30", 0.74, 0.0),
    "component": ("#a0a7ad", 0.54, 0.10),
    "component-light": ("#e1e4e6", 0.42, 0.32),
    "warm-grey": ("#aaa79d", 0.60, 0.0),
    "warm-grey-light": ("#c3beb0", 0.56, 0.0),
}


def case_mat(key):
    hexc, rough, metal = CASE_MATERIALS[key]
    return lib.material("case-" + key, hexc, rough, metal)


def modern_d_mat(key):
    """D-only lifted charcoal; retains lib_modern material names for grain."""
    lifted = {
        "charcoal": ("#4b4e53", 0.62, 0.0),
        "charcoal-deep": ("#383b3f", 0.72, 0.0),
    }
    if key not in lifted:
        return lm.modern(key)
    hexc, rough, metal = lifted[key]
    return lib.material("modern-" + key, hexc, rough, metal)


def _feet(w, d, h=0.008, inset=0.030, size=0.030):
    for sx in (-1, 1):
        for sy in (-1, 1):
            lib.box(
                "foot",
                (size, size, h),
                (sx * (w / 2 - inset), sy * (d / 2 - inset), h / 2),
                case_mat("black-deep"),
            )


def _bay(target, name, w, h, y_f, x, z, face_mat, depth=0.012):
    lib.cut(target, lib.box(name + "-cut", (w + 0.008, depth * 2, h + 0.008), (x, y_f, z)))
    lib.pocket(
        name + "-liner",
        w + 0.0074,
        h + 0.0074,
        depth,
        (x, y_f + 0.0003, z),
        mat=case_mat("black-deep"),
    )
    return lib.box(name + "-face", (w, 0.004, h), (x, y_f + depth * 0.55, z), face_mat)


def _optical(target, name, y_f, x, z, mat):
    face = _bay(target, name, 0.1461, 0.0413, y_f, x, z, mat)
    lib.cut(face, lib.box(name + "-tray-gap", (0.132, 0.012, 0.0020), (x, y_f + 0.006, z + 0.010)))
    lib.box(name + "-eject", (0.011, 0.005, 0.004), (x + 0.058, y_f + 0.004, z - 0.011), mat)
    lib.bevel(face, 0.0008, 1)


def _floppy(target, name, y_f, x, z, mat, full_face=True):
    if full_face:
        face = _bay(target, name, 0.1016, 0.0254, y_f, x, z, mat, 0.010)
    else:
        face = target
    lib.cut(face, lib.box(name + "-slot", (0.084, 0.018, 0.0032), (x - 0.003, y_f + 0.005, z + 0.003)))
    lib.box(name + "-slot-floor", (0.086, 0.0016, 0.005), (x - 0.003, y_f + 0.009, z + 0.003), case_mat("black-deep"))
    lib.box(name + "-eject", (0.008, 0.005, 0.005), (x + 0.043, y_f + 0.003, z - 0.006), mat)
    if full_face:
        lib.bevel(face, 0.0008, 1)


def _slot_vent(target, name, y_f, x, z, w, h, count, vertical=True, mat=None):
    lm.bar_vent(
        name,
        w,
        h,
        y_f,
        x,
        z,
        count,
        target,
        depth=0.006,
        vertical=vertical,
        mat_bars=mat or case_mat("graphite-light"),
        mat_floor=case_mat("black-deep"),
    )


def build_pizzabox_ps2():
    """D: generic PS/2 Model 77-class desktop, 360 x 115 x 395 mm."""
    w, h, d = 0.360, 0.115, 0.395
    y_f, z0 = -d / 2 + 0.012, 0.008
    _feet(w, d, z0, 0.035, 0.032)
    body = lib.box("body", (w, d - 0.018, h - z0), (0, 0.009, z0 + (h - z0) / 2), case_mat("warm-grey"))
    lid = lib.box("planar-lid", (w - 0.006, d - 0.026, 0.005), (0, 0.010, h - 0.0025), case_mat("warm-grey-light"))
    fascia = lib.box("upper-fascia", (w, 0.020, h - z0), (0, y_f + 0.010, z0 + (h - z0) / 2), case_mat("warm-grey"))
    # Shallow, localized sloped control/badge zone: the front edge projects
    # 9 mm without turning the broad planar lid into a wedge.
    apron = cd.profile_shell(
        "sloped-control-zone",
        0.142,
        [(y_f - 0.009, 0.014), (y_f + 0.010, 0.014), (y_f + 0.010, 0.044), (y_f - 0.002, 0.052)],
        loc=(-0.099, 0, 0),
        mat_=case_mat("warm-grey-light"),
    )
    _slot_vent(fascia, "vent-columns", y_f, -0.142, 0.081, 0.052, 0.054, 7, True, case_mat("warm-grey-light"))
    _optical(fascia, "low-525", y_f, 0.075, 0.084, case_mat("warm-grey-light"))
    _floppy(fascia, "floppy", y_f, 0.088, 0.041, case_mat("graphite-light"))
    lib.well(apron, "badge-zone", 0.078, 0.016, y_f - 0.006, -0.096, 0.030, 0.004, mat=case_mat("warm-grey"))
    lib.box("blank-id-plate", (0.064, 0.003, 0.010), (-0.096, y_f - 0.008, 0.030), case_mat("graphite-light"))
    lm.round_well(apron, "power-well", 0.0085, 0.004, y_f - 0.006, 0.145, 0.028, 24, case_mat("graphite"))
    lib.cylinder("power", 0.0065, 0.006, "Y", (0.145, y_f - 0.009, 0.028), case_mat("graphite"), 24)
    lib.bevel(body, 0.0016, 1)
    lib.bevel(lid, 0.0008, 1)


def build_pizzabox_sff():
    """E: Deskpro EN-class convertible SFF, 318 x 90 x 371 mm."""
    w, h, d = 0.318, 0.090, 0.371
    y_f, z0 = -d / 2 + 0.0055, 0.006
    _feet(w, d, z0, 0.030, 0.026)
    body = lib.box("body", (w - 0.004, d - 0.014, h - z0), (0, 0.007, z0 + (h - z0) / 2), case_mat("graphite"))
    face = lib.box("proud-faceplate", (w, 0.018, h - z0), (0, y_f + 0.009, z0 + (h - z0) / 2), case_mat("warm-grey"))
    _optical(face, "optical", y_f, -0.050, 0.062, case_mat("warm-grey-light"))
    _floppy(face, "floppy", y_f, -0.070, 0.026, case_mat("warm-grey-light"))
    _slot_vent(face, "front-perf", y_f, 0.113, 0.054, 0.058, 0.040, 8, True, case_mat("warm-grey-light"))
    lm.round_well(face, "power-well", 0.008, 0.005, y_f, 0.104, 0.024, 24, case_mat("black-deep"))
    lib.cylinder("power", 0.0062, 0.007, "Y", (0.104, y_f - 0.002, 0.024), case_mat("graphite-light"), 24)
    # Side perforation is a real field of through slots in the +X flank.
    cuts = [((0.014, 0.004, 0.018), (w / 2, -0.075 + i * 0.013, 0.048)) for i in range(11)]
    lib.cut(body, lib.multi_box("side-perf-cuts", cuts))
    lib.box("side-perf-floor", (0.0016, 0.148, 0.025), (w / 2 - 0.004, -0.010, 0.048), case_mat("black-deep"))
    lib.bevel(body, 0.0014, 1)
    lib.bevel(face, 0.0018, 2)


def build_pizzabox_pc300():
    """F: PC 300PL 6562-class formal desktop, 450 x 128 x 450 mm."""
    w, h, d = 0.450, 0.128, 0.450
    y_f, z0 = -d / 2 + 0.0055, 0.008
    _feet(w, d, z0, 0.044, 0.034)
    body = lib.box("body", (w, d - 0.020, h - z0), (0, 0.010, z0 + (h - z0) / 2), case_mat("warm-grey"))
    lid = lib.box("wide-lid", (w - 0.008, d - 0.024, 0.005), (0, 0.010, h - 0.0025), case_mat("warm-grey-light"))
    fascia = lib.box("formal-fascia", (w, 0.020, h - z0), (0, y_f + 0.010, z0 + (h - z0) / 2), case_mat("warm-grey"))
    _slot_vent(fascia, "left-intake", y_f, -0.181, 0.071, 0.062, 0.078, 9, True, case_mat("warm-grey-light"))
    _optical(fascia, "optical", y_f, 0.060, 0.092, case_mat("warm-grey-light"))
    _floppy(fascia, "floppy", y_f, 0.086, 0.054, case_mat("warm-grey-light"))
    lib.well(fascia, "control-strip", 0.198, 0.020, y_f, 0.086, 0.025, 0.006, mat=case_mat("black-deep"))
    lib.box("power", (0.022, 0.007, 0.011), (0.155, y_f - 0.002, 0.025), case_mat("warm-grey-light"))
    for i in range(3):
        lib.box("status", (0.003, 0.004, 0.003), (0.105 + i * 0.010, y_f - 0.002, 0.025), case_mat("warm-grey-light"))
    lib.bevel(body, 0.0015, 1)
    lib.bevel(lid, 0.0008, 1)
    lib.bevel(fascia, 0.0020, 2)


def build_tower_dimension():
    """D: Dimension 8100-class consumer tower, 222 x 491 x 453 mm."""
    w, h, d = 0.222, 0.491, 0.453
    y_f = -d / 2 + 0.0055
    _feet(w, d, 0.010, 0.028, 0.032)
    body = lib.box(
        "graphite-shell", (w, d - 0.018, h - 0.010), (0, 0.009, 0.010 + (h - 0.010) / 2), case_mat("graphite")
    )
    face = lib.box(
        "silver-center", (0.178, 0.024, h - 0.020), (0, y_f + 0.012, 0.010 + (h - 0.020) / 2), case_mat("silver")
    )
    for sx in (-1, 1):
        lib.box(
            "graphite-cheek",
            (0.022, 0.026, h - 0.030),
            (sx * 0.100, y_f + 0.013, 0.015 + (h - 0.030) / 2),
            case_mat("graphite"),
        )
    _optical(face, "optical0", y_f, 0, 0.431, case_mat("graphite-light"))
    _optical(face, "optical1", y_f, 0, 0.378, case_mat("graphite-light"))
    _floppy(face, "floppy", y_f, 0, 0.330, case_mat("silver-light"))
    # Rounded lower intake is a genuine recessed opening.
    intake = cd.rounded_prism("intake-cut", 0.130, 0.150, 0.030, 0.050, (0, y_f, 0.145))
    lib.cut(face, intake)
    lib.pocket("intake-liner", 0.127, 0.147, 0.014, (0, y_f + 0.0003, 0.145), mat=case_mat("black-deep"))
    # The slats follow the rounded opening instead of cutting a second,
    # rectangular well through it.
    bars = []
    for i in range(8):
        z = 0.097 + i * 0.014
        half = abs(z - 0.146) / 0.056
        width = 0.108 - 0.014 * min(1.0, half)
        bars.append(((width, 0.010, 0.005), (0, y_f + 0.005, z)))
    lib.multi_box("rounded-intake-slats", bars, case_mat("graphite-light"))
    lib.well(face, "io-door-well", 0.078, 0.036, y_f, 0, 0.257, 0.006, mat=case_mat("graphite"))
    door = lib.box("io-door", (0.070, 0.006, 0.028), (0, y_f - 0.001, 0.257), case_mat("silver-light"))
    lib.bevel(door, 0.003, 2)
    lm.round_well(face, "power-well", 0.012, 0.005, y_f, 0, 0.205, 28, case_mat("graphite"))
    lib.cylinder("power", 0.009, 0.007, "Y", (0, y_f - 0.002, 0.205), case_mat("graphite-light"), 28)
    lib.bevel(face, 0.0035, 3)
    lib.bevel(body, 0.0015, 1)


def build_tower_oem():
    """E: anonymous dc5800-class office tower, 177 x 377 x 428 mm."""
    w, h, d = 0.177, 0.377, 0.428
    y_f = -d / 2 + 0.0055
    _feet(w, d, 0.008, 0.023, 0.028)
    body = lib.box("steel-shell", (w, d - 0.016, h - 0.008), (0, 0.008, 0.008 + (h - 0.008) / 2), case_mat("graphite"))
    face = lib.box("straight-face", (w, 0.020, h - 0.012), (0, y_f + 0.010, 0.006 + (h - 0.012) / 2), case_mat("black"))
    _optical(face, "optical0", y_f, 0, 0.337, case_mat("black"))
    _optical(face, "optical1", y_f, 0, 0.289, case_mat("black"))
    _floppy(face, "floppy", y_f, 0, 0.247, case_mat("black"))
    for x in (-0.042, 0.042):
        _slot_vent(face, f"split-intake{x}", y_f, x, 0.105, 0.068, 0.158, 9, True, case_mat("graphite-light"))
    lib.box("intake-divider", (0.010, 0.009, 0.164), (0, y_f + 0.003, 0.105), case_mat("black"))
    lib.well(face, "power-well", 0.031, 0.045, y_f, 0, 0.211, 0.006, mat=case_mat("black-deep"))
    lib.box("power", (0.021, 0.007, 0.034), (0, y_f - 0.002, 0.211), case_mat("graphite-light"))
    for i, x in enumerate((-0.032, -0.014, 0.014, 0.032)):
        lib.well(face, f"port{i}", 0.010, 0.006, y_f, x, 0.181, 0.005, mat=case_mat("black-deep"))
    lib.bevel(body, 0.0012, 1)
    lib.bevel(face, 0.0018, 2)


def _fan(name, axis, loc, radius=0.060):
    ring = lib.cylinder(name + "-ring", radius, 0.004, axis, loc, case_mat("component"), 40)
    lib.cut(ring, lib.cylinder(name + "-ring-cut", radius - 0.007, 0.012, axis, loc, None, 40))
    lib.cylinder(name + "-hub", radius * 0.25, 0.005, axis, loc, case_mat("component-light"), 28)
    x, y, z = loc
    if axis == "X":
        span = radius * 1.72
        for sy, sz, dy, dz in ((-1, 0, 0.007, span), (1, 0, 0.007, span), (0, -1, span, 0.007), (0, 1, span, 0.007)):
            lib.box(
                name + "-frame",
                (0.004, dy, dz),
                (x, y + sy * (span - 0.007) / 2, z + sz * (span - 0.007) / 2),
                case_mat("component"),
            )
        for sy, sz in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            lib.box(
                name + "-spoke",
                (0.005, 0.012 + abs(sy) * 0.050, 0.012 + abs(sz) * 0.050),
                (x, y + sy * 0.030, z + sz * 0.030),
                case_mat("component"),
            )
    else:
        span = radius * 1.72
        for sx, sz, dx, dz in ((-1, 0, 0.007, span), (1, 0, 0.007, span), (0, -1, span, 0.007), (0, 1, span, 0.007)):
            lib.box(
                name + "-frame",
                (dx, 0.004, dz),
                (x + sx * (span - 0.007) / 2, y, z + sz * (span - 0.007) / 2),
                case_mat("component"),
            )
        for sx, sz in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            lib.box(
                name + "-spoke",
                (0.012 + abs(sx) * 0.050, 0.005, 0.012 + abs(sz) * 0.050),
                (x + sx * 0.030, y, z + sz * 0.030),
                case_mat("component"),
            )


def window_glass():
    mat = lib.material("modern-window-glass", "#59636c", 0.12)
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (0.060, 0.080, 0.095, 0.16)
    bsdf.inputs["Alpha"].default_value = 0.16
    if "Transmission Weight" in bsdf.inputs:
        bsdf.inputs["Transmission Weight"].default_value = 0.80
    mat.diffuse_color = (0.08, 0.11, 0.13, 0.16)
    if hasattr(mat, "surface_render_method"):
        mat.surface_render_method = "DITHERED"
    elif hasattr(mat, "blend_method"):
        mat.blend_method = "BLEND"
    return mat


def build_modern_windowed(p):
    """D: generic H500-class windowed hobby tower, 210 x 460 x 428 mm."""
    w, h, d = p["w"], p["h"], p["d"]
    y_f = -d / 2
    for sx in (-1, 1):
        for sy in (0.038, d - 0.038):
            lib.box("foot", (0.030, 0.050, 0.012), (sx * (w / 2 - 0.025), y_f + sy, 0.006), lm.modern("rubber"))
    # Sheet-metal frame leaves the camera-visible +X side open for a real
    # clear panel.
    lib.box(
        "left-side",
        (0.008, d, h - 0.012),
        (-w / 2 + 0.004, 0, 0.012 + (h - 0.012) / 2),
        modern_d_mat("charcoal"),
    )
    lib.box(
        "front",
        (w, 0.010, h - 0.012),
        (0, y_f + 0.005, 0.012 + (h - 0.012) / 2),
        modern_d_mat("charcoal"),
    )
    lib.box(
        "rear",
        (w, 0.010, h - 0.012),
        (0, d / 2 - 0.005, 0.012 + (h - 0.012) / 2),
        modern_d_mat("charcoal-deep"),
    )
    top = lib.box("top", (w, d, 0.008), (0, 0, h - 0.004), modern_d_mat("charcoal"))
    # Top and front ventilation seams are recessed slots with dark floors.
    slots = [((0.006, 0.100, 0.014), (-0.070 + i * 0.014, 0.080, h)) for i in range(11)]
    lib.cut(top, lib.multi_box("top-vent-cuts", slots))
    lib.box("top-vent-floor", (0.160, 0.104, 0.0016), (0, 0.080, h - 0.006), lm.modern("cavity"))
    lib.box(
        "front-vent-seam",
        (0.008, 0.012, h - 0.070),
        (-w / 2 + 0.013, y_f + 0.006, 0.035 + (h - 0.070) / 2),
        lm.modern("cavity"),
    )
    # Full-length shroud and motherboard tray establish the dual-chamber read.
    lib.box("psu-shroud", (w - 0.016, d - 0.030, 0.090), (0, 0.010, 0.057), lm.modern("charcoal-deep"))
    lib.box("motherboard", (0.006, 0.270, 0.265), (-0.065, 0.035, 0.275), lm.modern("powder"))
    lib.box("gpu", (0.120, 0.245, 0.040), (-0.005, 0.030, 0.220), case_mat("component"))
    lib.box("gpu-edge", (0.012, 0.245, 0.010), (0.057, 0.030, 0.220), case_mat("component-light"))
    lib.box("cpu-cooler", (0.090, 0.072, 0.125), (0.005, 0.045, 0.330), case_mat("component-light"))
    for y in (0.019, 0.032, 0.045, 0.058, 0.071):
        lib.box("cooler-fin", (0.096, 0.004, 0.132), (0.005, y, 0.330), case_mat("component"))
    _fan("cpu-fan", "X", (0.052, 0.045, 0.330), 0.050)
    _fan("rear-fan", "Y", (0.015, d / 2 - 0.012, 0.355), 0.060)
    for y in (-0.035, 0.035, 0.105):
        lib.box("ram", (0.012, 0.050, 0.045), (0.048, y, 0.385), case_mat("component"))
    for y in (-0.030, 0.060):
        _fan("gpu-fan", "X", (0.058, y, 0.220), 0.018)
    # Restrained cabling: three dark, tidy runs rather than a brand-shaped bar.
    for i, (x, y, z, hh) in enumerate(
        ((-0.074, -0.035, 0.250, 0.220), (-0.078, 0.120, 0.245, 0.190), (-0.070, 0.175, 0.170, 0.100))
    ):
        lib.box(f"cable{i}", (0.007, 0.010, hh), (x, y, z), lm.modern("port-dark"))
    # Clear side panel and four fasteners sit slightly proud of the frame.
    lib.box("window", (0.003, d - 0.028, h - 0.045), (w / 2 - 0.0015, 0.004, 0.020 + (h - 0.045) / 2), window_glass())
    for y in (-d / 2 + 0.020, d / 2 - 0.020):
        lib.box(
            "window-edge", (0.006, 0.012, h - 0.045), (w / 2 - 0.003, y, 0.020 + (h - 0.045) / 2), lm.modern("charcoal")
        )
    for z in (0.026, h - 0.026):
        lib.box("window-edge", (0.006, d - 0.040, 0.012), (w / 2 - 0.003, 0, z), lm.modern("charcoal"))
    for y in (-d / 2 + 0.027, d / 2 - 0.027):
        for z in (0.035, h - 0.027):
            lib.cylinder("window-screw", 0.004, 0.006, "X", (w / 2 - 0.003, y, z), lm.modern("steel"), 16)
    power_x, power_y = -0.060, y_f + 0.035
    lib.cut(top, lib.cylinder("power-well-cut", 0.008, 0.014, "Z", (power_x, power_y, h), None, 28))
    lib.cylinder("power-well", 0.0075, 0.003, "Z", (power_x, power_y, h - 0.005), lm.modern("cavity"), 28)
    lib.cylinder("power", 0.0058, 0.004, "Z", (power_x, power_y, h - 0.002), lm.modern("charcoal-deep"), 28)
    lib.bevel(top, 0.0012, 1)
