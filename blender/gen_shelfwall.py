"""Parametric packed archive-wall furniture and shelf dressing.

Run headless:
  blender -b --python blender/gen_shelfwall.py -- \
    --variant shelfbayA --out /tmp/shelfbay-a.glb --textured

Variants are independent real-world-meter assets, built +Z up with their
front toward Blender -Y (glTF +Z):
- shelfbayA/B: 2.1 m honey-pine open bays with four occupied levels and a top.
- boxstackA/B/C: retail cartons, banker's boxes, and software big-box rows.
- shelfclutterA/B: manuals, binders, keyboards, cable coils, and tape reels.
"""

import sys
from math import cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402


def archive_material(name, color, roughness=0.72, metallic=0.0):
    return lib.material(name, color, roughness, metallic)


def rounded_box(name, size, loc, material, bevel=0.006, rotation=(0.0, 0.0, 0.0)):
    obj = lib.box(name, size, loc, material)
    obj.rotation_euler = tuple(radians(angle) for angle in rotation)
    if bevel:
        lib.bevel(obj, bevel, 2)
    return obj


def pine(axis, tone):
    colors = ("#d9a45a", "#c8933f", "#d6a251", "#cf9848")
    return archive_material(f"archive-pine-{axis}-{tone}", colors[tone], 0.74)


def sagging_shelf(name, width, depth, z, tone):
    """Five subtly pitched segments form a 6 mm center sag."""
    count = 5
    segment_w = width / count + 0.004
    offsets = (0.0, -0.004, -0.006, -0.004, 0.0)
    pitches = (-0.8, -0.45, 0.0, 0.45, 0.8)
    for index in range(count):
        x = -width / 2 + width * (index + 0.5) / count
        rounded_box(
            f"{name}-board",
            (segment_w, depth, 0.045),
            (x, 0.0, z + offsets[index]),
            pine("x", (tone + index) % 4),
            0.004,
            (0.0, pitches[index], 0.0),
        )


def shelf_bay(width, levels, top, variant):
    """Chunky open-plank bay with non-identical boards and slight lean."""
    depth = 0.45
    upright_w = 0.075
    for side, lean in ((-1, -0.35), (1, 0.28)):
        rounded_box(
            f"{variant}-upright",
            (upright_w, depth, top),
            (side * (width / 2 - upright_w / 2), 0.0, top / 2),
            pine("z", 0 if side < 0 else 2),
            0.006,
            (0.0, lean, 0.0),
        )
    inner = width - upright_w * 1.35
    for index, level in enumerate(levels):
        sagging_shelf(f"{variant}-shelf-{index}", inner, depth, level, index % 4)
    # The top is a deeper, slightly proud cap like the reference's pine grid.
    sagging_shelf(f"{variant}-top", width + 0.025, depth + 0.018, top, 3)
    # Narrow rear cleats are visible through gaps but keep the bay open.
    for level in levels[1:]:
        rounded_box(
            f"{variant}-rear-cleat",
            (inner, 0.026, 0.052),
            (0.0, depth / 2 - 0.018, level + 0.06),
            pine("x", 1),
            0.004,
        )


def label_panel(name, loc, size, color, bars=2, circle=False):
    panel = archive_material(f"{name}-panel", color, 0.76)
    dark = archive_material(f"{name}-ink", "#40372c", 0.70)
    light = archive_material(f"{name}-paper", "#ddd0ad", 0.82)
    x, y, z = loc
    w, h = size
    rounded_box(name, (w, 0.006, h), (x, y, z), panel, 0.003)
    for index in range(bars):
        bar_w = w * (0.55 - index * 0.09)
        rounded_box(
            f"{name}-text",
            (bar_w, 0.003, max(0.008, h * 0.055)),
            (x - w * 0.10, y - 0.004, z + h * (0.22 - index * 0.13)),
            light if index == 0 else dark,
            0.001,
        )
    if circle:
        lib.cylinder(
            f"{name}-roundel",
            h * 0.15,
            0.008,
            "Y",
            (x + w * 0.28, y - 0.006, z - h * 0.15),
            light,
            16,
        )


def worn_box(name, size, loc, color, label_color, label_scale=0.72):
    w, d, h = size
    x, y, z = loc
    card = archive_material("archive-card", color, 0.83)
    edge = archive_material("archive-card-wear", "#9b7650", 0.90)
    rounded_box(name, size, loc, card, min(0.012, min(size) * 0.08))
    front_y = y - d / 2 - 0.004
    label_panel(
        f"{name}-label",
        (x, front_y, z),
        (w * label_scale, h * 0.58),
        label_color,
        3,
        True,
    )
    # Small exposed-kraft patches sell rubbed corners without brand graphics.
    patch = min(0.035, w * 0.08, h * 0.15)
    for side in (-1, 1):
        rounded_box(
            f"{name}-corner-wear",
            (patch, 0.008, patch),
            (x + side * (w / 2 - patch / 2), front_y - 0.005, z + h / 2 - patch / 2),
            edge,
            0.002,
        )


def box_stack_a():
    """Uneven retail-carton skyline with horizontal and upright packages."""
    worn_box("retail-wide", (0.48, 0.29, 0.25), (-0.14, 0.0, 0.125), "#b47b45", "#5d6e78")
    worn_box("retail-top", (0.34, 0.27, 0.20), (-0.10, 0.005, 0.354), "#bcb07d", "#a44c3f")
    worn_box("retail-upright", (0.20, 0.24, 0.44), (0.25, 0.01, 0.22), "#817c68", "#d2a14b")


def box_stack_b():
    """Two banker's boxes with lids plus a faded small equipment carton."""
    card = archive_material("archive-card", "#bba17a", 0.86)
    blue = archive_material("archive-banker-blue", "#617685", 0.78)
    for index, x in enumerate((-0.22, 0.22)):
        rounded_box("banker-body", (0.40, 0.34, 0.28), (x, 0.0, 0.14), card, 0.008)
        rounded_box("banker-lid", (0.43, 0.36, 0.045), (x, 0.0, 0.295), blue, 0.006)
        label_panel(
            f"banker-{index}-label",
            (x, -0.174, 0.16),
            (0.25, 0.105),
            "#ded7c5",
            2,
        )
    worn_box("banker-top", (0.36, 0.30, 0.18), (0.08, 0.0, 0.405), "#9a8f77", "#8c493e")


def box_stack_c():
    """A touching row of slim software big-boxes with sun-faded spines."""
    colors = ("#7f6c55", "#9b5150", "#5f7280", "#b09458", "#777763", "#8d654a")
    widths = (0.105, 0.12, 0.095, 0.14, 0.11, 0.105)
    cursor = -sum(widths) / 2
    for index, (width, color) in enumerate(zip(widths, colors)):
        height = 0.37 + (index % 3) * 0.045
        x = cursor + width / 2
        worn_box(
            f"software-{index}",
            (width, 0.21 + (index % 2) * 0.025, height),
            (x, 0.0, height / 2),
            color,
            "#c9ba8d",
            0.64,
        )
        cursor += width


def keyboard_stack(name, loc, width=0.48, rotations=(0.0, -2.5, 2.0)):
    shell = archive_material("archive-keyboard-shell", "#bfb49b", 0.68)
    keys = archive_material("archive-keyboard-keys", "#d8cdb5", 0.63)
    x, y, z = loc
    for index, angle in enumerate(rotations):
        base_z = z + index * 0.065
        board = lib.wedge_box(
            name,
            width - index * 0.025,
            0.19,
            0.025,
            0.052,
            (x, y, base_z),
            shell,
        )
        board.rotation_euler[2] = radians(angle)
        lib.bevel(board, 0.006, 2)
        for row in range(3):
            rounded_box(
                f"{name}-key-row",
                (width * (0.72 - row * 0.04), 0.025, 0.008),
                (x, y - 0.094 - row * 0.031, base_z + 0.039 - row * 0.003),
                keys,
                0.002,
                (0.0, 0.0, angle),
            )


def binder_row(start_x, count, base_z, lean_every=3):
    colors = ("#965b48", "#697b83", "#b49b64", "#6f725f", "#8b6655")
    for index in range(count):
        width = 0.045 + (index % 2) * 0.009
        height = 0.27 + (index % 4) * 0.018
        x = start_x + index * 0.058
        angle = -4.0 if index % lean_every == lean_every - 1 else (index % 2) * 1.2
        rounded_box(
            "manual-binder",
            (width, 0.16, height),
            (x, 0.025, base_z + height / 2),
            archive_material(f"archive-binder-{index % 5}", colors[index % 5], 0.77),
            0.004,
            (0.0, angle, 0.0),
        )
        rounded_box(
            "binder-spine-label",
            (width * 0.58, 0.006, height * 0.33),
            (x, -0.058, base_z + height * 0.58),
            archive_material("archive-paper", "#d7cfb7", 0.84),
            0.002,
            (0.0, angle, 0.0),
        )


def torus(name, major_radius, minor_radius, loc, material, rotation=(90.0, 0.0, 0.0)):
    lib.bpy.ops.mesh.primitive_torus_add(
        align="WORLD",
        major_segments=20,
        minor_segments=6,
        location=loc,
        major_radius=major_radius,
        minor_radius=minor_radius,
    )
    obj = lib.bpy.context.object
    obj.name = name
    obj.rotation_euler = tuple(radians(angle) for angle in rotation)
    obj.data.materials.append(material)
    return obj


def cable_bundle(loc):
    cable = archive_material("archive-cable", "#343431", 0.66)
    x, y, z = loc
    for index in range(3):
        torus(
            "coiled-cable",
            0.086 + index * 0.008,
            0.006,
            (x, y + index * 0.012, z + index * 0.004),
            cable,
        )
    rounded_box(
        "cable-tie", (0.028, 0.028, 0.20), (x, y - 0.018, z), archive_material("archive-tie", "#a98b58", 0.78), 0.004
    )


def tape_reel(name, loc, radius, color):
    x, y, z = loc
    reel = archive_material(f"{name}-reel", color, 0.54, 0.08)
    dark = archive_material(f"{name}-hub", "#4b4943", 0.50, 0.12)
    lib.cylinder(name, radius, 0.028, "Y", loc, reel, 24)
    lib.cylinder(f"{name}-hub", radius * 0.22, 0.034, "Y", (x, y - 0.004, z), dark, 16)
    for index in range(6):
        angle = index * pi / 3
        rounded_box(
            f"{name}-spoke",
            (radius * 0.09, 0.035, radius * 0.58),
            (
                x + sin(angle) * radius * 0.35,
                y - 0.006,
                z + cos(angle) * radius * 0.35,
            ),
            dark,
            0.003,
            (0.0, angle * 180 / pi, 0.0),
        )


def shelf_clutter_a():
    binder_row(-0.38, 8, 0.0)
    keyboard_stack("stacked-keyboards", (0.22, 0.04, 0.01), 0.45, (1.5, -2.0))
    cable_bundle((0.36, -0.015, 0.25))


def shelf_clutter_b():
    binder_row(-0.42, 5, 0.0, 2)
    tape_reel("tape-reel-a", (0.03, 0.03, 0.15), 0.145, "#a9a89a")
    tape_reel("tape-reel-b", (0.31, 0.04, 0.13), 0.125, "#6e7d81")
    keyboard_stack("keyboard-pile", (-0.10, 0.05, 0.315), 0.50, (-3.0, 2.5))
    cable_bundle((0.39, -0.02, 0.34))


BUILDERS = {
    "SHELFBAYA": lambda: shelf_bay(1.02, (0.075, 0.52, 0.98, 1.44), 2.08, "shelfbay-a"),
    "SHELFBAYB": lambda: shelf_bay(0.92, (0.085, 0.48, 0.91, 1.38), 2.12, "shelfbay-b"),
    "BOXSTACKA": box_stack_a,
    "BOXSTACKB": box_stack_b,
    "BOXSTACKC": box_stack_c,
    "SHELFCLUTTERA": shelf_clutter_a,
    "SHELFCLUTTERB": shelf_clutter_b,
}

BAKE_PARAMS = {
    "SHELFBAYA": dict(
        size=1024,
        ao_floor=0.58,
        grain_mul=0.18,
        grain_scale=95.0,
        wear_amt=0.075,
        rough=0.72,
        rough_texture=True,
        rough_variation=0.08,
    ),
    "SHELFBAYB": dict(
        size=1024,
        ao_floor=0.58,
        grain_mul=0.18,
        grain_scale=95.0,
        wear_amt=0.075,
        rough=0.72,
        rough_texture=True,
        rough_variation=0.08,
    ),
    "BOXSTACKA": dict(size=512, ao_floor=0.56, wear_amt=0.10, rough=0.79),
    "BOXSTACKB": dict(size=512, ao_floor=0.56, wear_amt=0.10, rough=0.80),
    "BOXSTACKC": dict(size=512, ao_floor=0.58, wear_amt=0.09, rough=0.78),
    "SHELFCLUTTERA": dict(size=512, ao_floor=0.50, wear_amt=0.07, rough=0.70),
    "SHELFCLUTTERB": dict(size=512, ao_floor=0.48, wear_amt=0.07, rough=0.68),
}


def main():
    variant, out = lib.parse_args("shelfbayA", "/tmp/param-shelfwall.glb")
    if variant not in BUILDERS:
        choices = ", ".join(BUILDERS)
        raise ValueError(f"unknown shelf-wall variant {variant!r}; choose one of {choices}")
    lib.reset_scene()
    BUILDERS[variant]()
    lib.bpy.context.view_layer.update()
    lib_bake.maybe_bake_export(out, **BAKE_PARAMS[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
