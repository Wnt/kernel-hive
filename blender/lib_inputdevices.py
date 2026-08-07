"""Geometry helpers shared by the matrix keyboard and mouse variants.

All dimensions are meters in Blender build space: +Z up, hardware fronts -Y.
The helpers deliberately create physical cap relief, wheel ribs, cable coils,
and recessed key wells; none of those cues are painted into a texture.
"""

from math import pi, sin

import lib
import lib_smallobjects as so


INPUT_PALETTE = {
    "xt-shell": ("#c7b795", 0.62),
    "xt-key-light": ("#d8ccb2", 0.54),
    "xt-key-dark": ("#706b61", 0.55),
    "silver": ("#b9bfc0", 0.46),
    "silver-light": ("#d4d7d6", 0.44),
    "graphite": ("#474b4e", 0.54),
    "black-shell": ("#252729", 0.60),
    "black-key": ("#747a7f", 0.50),
    "black-well": ("#17191a", 0.68),
    "pale-shell": ("#8f9795", 0.50),
    "pale-key": ("#e4e1d9", 0.45),
    "work-shell": ("#aaa18d", 0.61),
    "work-key": ("#dfd6bf", 0.54),
    "work-dark": ("#625c52", 0.58),
    "mouse-pale": ("#778b89", 0.44),
    "mouse-pale-key": ("#c8cfcc", 0.42),
    "mouse-silver": ("#c3c9c8", 0.34),
    "mouse-black": ("#42474a", 0.54),
    "mouse-black-key": ("#555a5d", 0.50),
    "mouse-cream": ("#c7bea8", 0.60),
    "mouse-cream-key": ("#817a6e", 0.56),
    "mouse-rail": ("#747775", 0.50),
    "wheel": ("#2f3231", 0.64),
    "sensor-red": ("#d53226", 0.24),
}


def mat(key):
    hexc, rough = INPUT_PALETTE[key]
    metallic = 0.45 if key == "mouse-silver" else 0.0
    return lib.material("input-" + key, hexc, rough, metallic)


def wedge_shell(name, width, depth, front_h, rear_h, lower_mat, upper_mat, inset=0.003):
    """Two-piece keyboard case with a real perimeter step."""
    seam_h = min(0.007, front_h * 0.45)
    lower = lib.box(name + "-lower", (width, depth, seam_h), (0, 0, seam_h / 2), lower_mat)
    upper = lib.wedge_box(
        name + "-upper",
        width - inset * 2,
        depth - inset * 2,
        front_h - seam_h,
        rear_h - seam_h,
        (0, 0, seam_h),
        upper_mat,
    )
    lib.bevel(lower, min(0.0018, seam_h * 0.22), 2)
    return lower, upper


def top_z(y, depth, front_h, rear_h):
    return front_h + (y + depth / 2) / depth * (rear_h - front_h)


def key_group(name, specs, material, pitch_x, pitch_y, z_at, key_h, dish=True):
    """Build a complete key family as one mesh.

    specs entries are ``(x_units, y_units, width_units, depth_units)``.
    ``z_at(y_m)`` returns the deck height beneath each cap.
    """
    bm = lib.new_bm()
    for xu, yu, wu, du in specs:
        kw = wu * pitch_x - min(0.0010, pitch_x * 0.08)
        kd = du * pitch_y - min(0.0010, pitch_y * 0.08)
        cx, cy = xu * pitch_x, yu * pitch_y
        shrink = min(0.0032, kw * 0.16, kd * 0.16)
        sections = [
            (0.0, kw, kd, 0.0),
            (key_h * 0.25, kw, kd, 0.0),
            (key_h, kw - shrink, kd - shrink, -0.0004),
        ]
        if dish and min(kw, kd) > 0.008:
            sections.append(
                (
                    key_h - min(0.0007, key_h * 0.18),
                    kw - shrink - min(0.0022, kw * 0.10),
                    kd - shrink - min(0.0022, kd * 0.10),
                    -0.0004,
                )
            )
        lib.loft_into(bm, "Z", sections, (cx, cy, z_at(cy)))
    obj = lib.finalize(bm, name, material)
    if name.startswith("compact-"):
        lib.bevel(obj, min(0.0013, pitch_x * 0.08, pitch_y * 0.08), 2)
    return obj


def recessed_cluster(target, name, width, depth, center, deck_z, floor_mat, recess=0.0022):
    """Cut a shallow real key well and install its recessed floor."""
    cx, cy = center
    cutter = lib.multi_box(
        name + "-cut",
        [((width, depth, recess * 2.5), (cx, cy, deck_z + recess * 0.35))],
    )
    lib.cut(target, cutter)
    return lib.box(
        name + "-floor",
        (width - 0.0012, depth - 0.0012, 0.0010),
        (cx, cy, deck_z - recess + 0.0005),
        floor_mat,
    )


def coiled_cable(name, exit_y, exit_z, cable_mat, thick=False, side_coil=False):
    """Rear-exiting cable with a physical four-turn coil and desk-resting tail."""
    radius = 0.0023 if thick else 0.0018
    points = [(0.0, exit_y, exit_z), (0.0, exit_y + 0.020, max(0.003, exit_z * 0.7))]
    turns = 5 if side_coil else 4
    samples = 48
    coil_r = 0.010 if thick else 0.008
    if side_coil:
        points.append((0.205, exit_y + 0.025, radius + coil_r))
    for i in range(samples + 1):
        t = i / samples
        angle = t * turns * 2 * pi
        if side_coil:
            points.append(
                (
                    0.205 + t * 0.120,
                    exit_y + 0.032 + sin(angle) * coil_r,
                    radius + coil_r + sin(angle + pi / 2) * coil_r,
                )
            )
        else:
            points.append(
                (
                    sin(angle) * coil_r,
                    exit_y + 0.027 + t * (0.075 if thick else 0.060),
                    radius + coil_r + sin(angle + pi / 2) * coil_r,
                )
            )
    if side_coil:
        points.extend([(0.345, exit_y + 0.050, 0.0028), (0.390, exit_y + 0.070, 0.0026)])
    else:
        points.extend([(0.120, exit_y + 0.120, 0.0028), (0.315, exit_y + 0.132, 0.0026)])
    so.tube(name, points, radius, cable_mat, resolution=6)


def keyboard_usb_cable(exit_y, cable_mat):
    """Simple rear USB lead and molded plug for the black office board."""
    so.tube(
        "usb-cable",
        [
            (0, exit_y, 0.008),
            (0, exit_y + 0.030, 0.003),
            (0.095, exit_y + 0.065, 0.0022),
            (0.205, exit_y + 0.078, 0.0022),
            (0.285, exit_y + 0.066, 0.0022),
        ],
        0.0016,
        cable_mat,
        resolution=7,
    )
    collar = lib.box("usb-collar", (0.014, 0.010, 0.006), (0.285, exit_y + 0.064, 0.003), cable_mat)
    plug = lib.box("usb-plug", (0.030, 0.015, 0.007), (0.285, exit_y + 0.075, 0.0035), mat("graphite"))
    lib.bevel(collar, 0.0012, 2)
    lib.bevel(plug, 0.0010, 2)


def wheel(name, y, z, radius, width, material):
    """Clickable scroll wheel with real circumferential tread ribs."""
    main = lib.cylinder(name, radius, width, "X", (0, y, z), material, 28)
    for i in range(16):
        angle = 2 * pi * i / 16
        rib = lib.box(
            name + "-rib",
            (width + 0.0005, 0.00075, 0.00065),
            (0, y + sin(angle) * (radius + 0.0002), z + sin(angle + pi / 2) * (radius + 0.0002)),
            material,
        )
        rib.rotation_euler.x = angle
    return main


def optical_sensor(y, red_mat):
    """Recessed underside optical window plus a faint red geometry ring."""
    lib.cylinder("sensor-well", 0.0080, 0.0015, "Z", (0, y, 0.00075), mat("black-well"), 28)
    lib.cylinder("sensor-red", 0.0052, 0.0018, "Z", (0, y, 0.0010), red_mat, 28)
