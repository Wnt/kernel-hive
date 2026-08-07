"""Parametric museum-identity and lived-in dressing props for scene v2.

Run headless, one independently placeable real-scale asset at a time:
  blender -b --python blender/gen_dressing.py -- \
    --variant wallClock --out /tmp/dressing-clock.glb

Build convention follows :mod:`lib`: meters, +Z up, front toward Blender -Y.
Every solid asset is Smart-UV baked through :mod:`lib_bake`; the display-case
glass remains a separate transmissive material in the exported GLB.

Variants:
- wallClock: 300 mm institutional quartz wall clock.
- fireExtinguisher: 6 kg dry-powder extinguisher with hose and wall bracket.
- pottedPlant / lavenderPlant: floor foliage and small desk lavender.
- deskLamp: articulated task lamp with pivot hardware and conical shade.
- displayCase: worn white 1.2 m plinth with a glass vitrine.
- framedPosterTall / framedPosterWide: one parametric frame at two aspects.
- dustCoverSmall / dustCoverLarge: cloth-covered machine silhouettes.
- hangingJacket: red museum jacket on a pine peg.
- mousePad: worn neoprene mouse mat.
- manualBinderStack: manuals and ring binders with varied spines.
- floppyBox: open 3.5-inch disk carton with visible disks.

Dimensional anchors:
- ISO 216 A5 manuals: 148 x 210 mm.
- ECMA-125 90 mm flexible-disk cartridge: 90 x 94 x 3.3 mm.
- Common 6 kg extinguisher envelope: approximately 550 x 300 mm.
- Museum case and A-series paper dimensions follow the scene scale rules in
  docs/lab/research/webgl-gallery-scene/ART-DIRECTION.md.
"""

import sys
from math import cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402
import lib_smallobjects as small  # noqa: E402


def rounded_box(name, size, loc, material, bevel=0.004, rotation=(0.0, 0.0, 0.0)):
    obj = lib.box(name, size, loc, material)
    obj.rotation_euler = tuple(radians(angle) for angle in rotation)
    if bevel:
        lib.bevel(obj, bevel, 2)
    return obj


def tube(name, points, radius, material, sides=8):
    return small.tube(name, points, radius, material, sides)


def torus(name, major_radius, minor_radius, loc, material, rotation=(90.0, 0.0, 0.0)):
    lib.bpy.ops.mesh.primitive_torus_add(
        align="WORLD",
        major_segments=24,
        minor_segments=8,
        location=loc,
        major_radius=major_radius,
        minor_radius=minor_radius,
    )
    obj = lib.bpy.context.object
    obj.name = name
    obj.rotation_euler = tuple(radians(angle) for angle in rotation)
    obj.data.materials.append(material)
    return obj


def wall_clock():
    """Shallow white institutional clock, rear at +Y and readable from -Y."""
    rim = lib.shared("abs-light")
    face = lib.shared("paper")
    ink = lib.shared("dark")
    lib.cylinder("clock-rim", 0.155, 0.038, "Y", (0, 0.018, 0.155), rim, 48)
    lib.cylinder("clock-face", 0.139, 0.004, "Y", (0, -0.003, 0.155), face, 48)
    lib.cylinder("clock-hub", 0.008, 0.008, "Y", (0, -0.009, 0.155), ink, 16)
    for index in range(12):
        angle = index * 2 * pi / 12
        x = sin(angle) * 0.113
        z = 0.155 + cos(angle) * 0.113
        tick = rounded_box("clock-tick", (0.005, 0.006, 0.018), (x, -0.008, z), ink, 0.001)
        tick.rotation_euler[1] = -angle
    tube("clock-hour-hand", [(0, -0.013, 0.155), (-0.050, -0.013, 0.190)], 0.004, ink, 6)
    tube("clock-minute-hand", [(0, -0.014, 0.155), (0.020, -0.014, 0.238)], 0.003, ink, 6)


def fire_extinguisher():
    """Red wall extinguisher, front toward -Y, with hose and bracket."""
    red = lib.material("dressing-extinguisher-red", "#b5342c", 0.52)
    dark = lib.shared("cable")
    metal = lib.shared("steel")
    paper = lib.shared("paper")
    lib.cylinder("extinguisher-cylinder", 0.092, 0.405, "Z", (0, 0, 0.255), red, 40)
    lib.bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=16, location=(0, 0, 0.458))
    dome = lib.bpy.context.object
    dome.name = "extinguisher-dome"
    dome.scale = (0.092, 0.092, 0.062)
    dome.data.materials.append(red)
    lib.cylinder("valve-neck", 0.029, 0.070, "Z", (0, 0, 0.527), metal, 24)
    rounded_box("valve-body", (0.080, 0.042, 0.035), (0, -0.005, 0.566), metal, 0.009)
    rounded_box("handle-fixed", (0.105, 0.022, 0.018), (0.025, 0, 0.596), dark, 0.006, (0, -8, 0))
    rounded_box("handle-lever", (0.095, 0.017, 0.015), (0.020, -0.025, 0.575), metal, 0.005, (0, 11, 0))
    lib.cylinder("pressure-gauge", 0.024, 0.014, "Y", (-0.052, -0.034, 0.561), paper, 20)
    tube(
        "extinguisher-hose",
        [(0.048, 0, 0.548), (0.115, -0.005, 0.490), (0.125, -0.012, 0.280), (0.100, -0.018, 0.145)],
        0.009,
        dark,
        10,
    )
    lib.cylinder("hose-nozzle", 0.014, 0.105, "Z", (0.100, -0.018, 0.086), dark, 18)
    rounded_box("instruction-label", (0.105, 0.006, 0.175), (0, -0.094, 0.315), paper, 0.006)
    for index, width in enumerate((0.075, 0.060, 0.078, 0.055, 0.068)):
        rounded_box(
            "label-rule",
            (width, 0.003, 0.006),
            (0, -0.099, 0.365 - index * 0.023),
            red if index == 0 else dark,
            0.001,
        )
    rounded_box("wall-bracket", (0.145, 0.030, 0.310), (0, 0.090, 0.285), metal, 0.005)


def leaf(name, loc, scale, angle, material):
    """Low-poly lanceolate leaf built as a flattened tapered ellipsoid."""
    x, y, z = loc
    lib.bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, location=loc)
    obj = lib.bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.rotation_euler = (radians(angle[0]), radians(angle[1]), radians(angle[2]))
    obj.data.materials.append(material)
    return obj


def plant_pot(radius, height, loc=(0.0, 0.0, 0.0), lavender=False):
    x, y, z = loc
    ceramic = lib.material(
        "dressing-pot-lavender" if lavender else "dressing-pot-terracotta",
        "#b7aeb0" if lavender else "#b66d42",
        0.76,
    )
    soil = lib.material("dressing-soil", "#51412f", 0.92)
    lib.bpy.ops.mesh.primitive_cone_add(
        vertices=32,
        radius1=radius * 0.78,
        radius2=radius,
        depth=height,
        location=(x, y, z + height / 2),
    )
    pot = lib.bpy.context.object
    pot.name = "plant-pot"
    pot.data.materials.append(ceramic)
    torus("plant-pot-rim", radius * 0.91, radius * 0.10, (x, y, z + height * 0.89), ceramic, (0, 0, 0))
    lib.cylinder("plant-soil", radius * 0.82, 0.012, "Z", (x, y, z + height * 0.90), soil, 28)
    return z + height * 0.93


def potted_plant():
    green_a = lib.material("dressing-leaf-green", "#4f6c45", 0.78)
    green_b = lib.material("dressing-leaf-light", "#708154", 0.80)
    base = plant_pot(0.165, 0.235)
    for index in range(15):
        angle = index * 2 * pi / 15
        radius = 0.055 + (index % 4) * 0.014
        height = 0.25 + (index % 5) * 0.055
        tube(
            "plant-stem",
            [
                (0, 0, base),
                (sin(angle) * radius * 0.6, cos(angle) * radius * 0.6, base + height * 0.55),
                (sin(angle) * radius * 1.8, cos(angle) * radius * 1.8, base + height),
            ],
            0.005,
            green_a,
            6,
        )
        leaf(
            "plant-leaf",
            (sin(angle) * radius * 1.7, cos(angle) * radius * 1.7, base + height * 0.82),
            (0.045, 0.012, 0.13 + (index % 3) * 0.015),
            (18 * sin(angle), angle * 180 / pi, -angle * 180 / pi),
            green_a if index % 2 == 0 else green_b,
        )


def lavender_plant():
    green = lib.material("dressing-lavender-leaf", "#667b5b", 0.80)
    purple = lib.material("dressing-lavender-flower", "#806a91", 0.78)
    base = plant_pot(0.075, 0.105, lavender=True)
    for index in range(13):
        angle = index * 2 * pi / 13
        radius = 0.018 + (index % 3) * 0.008
        height = 0.13 + (index % 4) * 0.025
        end = (sin(angle) * radius, cos(angle) * radius, base + height)
        tube("lavender-stem", [(0, 0, base), end], 0.0025, green, 5)
        for flower in range(4):
            flower_z = end[2] - flower * 0.014
            leaf(
                "lavender-bloom",
                (end[0], end[1], flower_z),
                (0.009, 0.009, 0.018),
                (0, flower * 40, 0),
                purple,
            )


def desk_lamp():
    """Two-link anglepoise lamp in a readable bent pose."""
    steel = lib.shared("steel")
    dark = lib.shared("cable")
    shade = lib.material("dressing-lamp-shade", "#4c514d", 0.56)
    warm = lib.material("dressing-lamp-reflector", "#d8c8a7", 0.46)
    lib.cylinder("lamp-base", 0.095, 0.020, "Z", (0, 0, 0.010), shade, 32)
    lib.cylinder("lamp-base-step", 0.070, 0.024, "Z", (0, 0, 0.030), steel, 28)
    pivot_a = (0, 0, 0.055)
    pivot_b = (-0.055, 0.015, 0.315)
    pivot_c = (0.075, -0.010, 0.515)
    for side in (-1, 1):
        offset = side * 0.012
        tube(
            "lamp-lower-arm", [(offset, 0, pivot_a[2]), (pivot_b[0] + offset, pivot_b[1], pivot_b[2])], 0.006, steel, 8
        )
        tube(
            "lamp-upper-arm",
            [(pivot_b[0] + offset, pivot_b[1], pivot_b[2]), (pivot_c[0] + offset, pivot_c[1], pivot_c[2])],
            0.006,
            steel,
            8,
        )
    for pivot in (pivot_a, pivot_b, pivot_c):
        lib.cylinder("lamp-pivot", 0.022, 0.040, "X", pivot, dark, 20)
    # Cone opens toward the user (-Y), with a warm reflector disk.
    lib.bpy.ops.mesh.primitive_cone_add(
        vertices=32,
        radius1=0.105,
        radius2=0.055,
        depth=0.145,
        location=(0.075, -0.075, 0.545),
        rotation=(radians(90), 0, 0),
    )
    hood = lib.bpy.context.object
    hood.name = "lamp-shade"
    hood.data.materials.append(shade)
    lib.cylinder("lamp-reflector", 0.088, 0.006, "Y", (0.075, -0.151, 0.545), warm, 28)
    tube("lamp-cord", [(0, 0.02, 0.045), (0.08, 0.05, 0.015), (0.20, 0.06, 0.009)], 0.003, dark, 6)


def glass_material():
    material = lib.shared("glass")
    bsdf = material.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (0.55, 0.68, 0.70, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.08
    transmission = bsdf.inputs.get("Transmission Weight") or bsdf.inputs.get("Transmission")
    if transmission is not None:
        transmission.default_value = 0.82
    bsdf.inputs["Alpha"].default_value = 0.24
    material.blend_method = "BLEND"
    return material


def display_case():
    """Worn white plinth with four glass sides and a top."""
    white = lib.material("dressing-case-white", "#dedbd2", 0.72)
    wear = lib.material("dressing-case-wear", "#aaa69c", 0.82)
    trim = lib.shared("steel-light")
    glass = glass_material()
    rounded_box("case-plinth", (1.20, 0.68, 0.72), (0, 0, 0.36), white, 0.014)
    rounded_box("case-sockle", (1.16, 0.64, 0.055), (0, 0, 0.028), wear, 0.008)
    rounded_box("case-deck", (1.22, 0.70, 0.045), (0, 0, 0.742), trim, 0.006)
    # One chipped corner and scuffed lower strips keep the plinth non-pristine.
    rounded_box("case-chip", (0.105, 0.010, 0.050), (-0.51, -0.344, 0.085), wear, 0.003)
    rounded_box("case-scuff", (0.30, 0.008, 0.018), (0.25, -0.345, 0.190), wear, 0.003, (0, 0, -2))
    vitrine_bottom = 0.765
    vitrine_height = 0.42
    thickness = 0.008
    rounded_box("case-glass-front", (1.16, thickness, vitrine_height), (0, -0.326, vitrine_bottom + 0.21), glass, 0.002)
    rounded_box("case-glass-back", (1.16, thickness, vitrine_height), (0, 0.326, vitrine_bottom + 0.21), glass, 0.002)
    rounded_box("case-glass-left", (thickness, 0.65, vitrine_height), (-0.576, 0, vitrine_bottom + 0.21), glass, 0.002)
    rounded_box("case-glass-right", (thickness, 0.65, vitrine_height), (0.576, 0, vitrine_bottom + 0.21), glass, 0.002)
    rounded_box("case-glass-top", (1.16, 0.65, thickness), (0, 0, vitrine_bottom + vitrine_height), glass, 0.002)
    # Low generic artifact inside gives reflections something to enclose.
    rounded_box("case-artifact", (0.46, 0.27, 0.10), (-0.10, 0, 0.822), lib.shared("abs-warm"), 0.012, (0, 0, -5))
    rounded_box("case-artifact-panel", (0.24, 0.008, 0.036), (-0.10, -0.140, 0.830), lib.shared("recess"), 0.003)


def framed_poster(aspect):
    """Frame geometry whose opening aspect is supplied by the variant."""
    height = 0.62 if aspect < 1 else 0.42
    width = height * aspect
    rail = 0.045
    depth = 0.028
    wood = lib.material("dressing-frame-darkwood", "#6e4a2f", 0.65)
    backing = lib.material("dressing-frame-backing", "#d7d0c1", 0.82)
    rounded_box("frame-left", (rail, depth, height), (-width / 2 + rail / 2, 0, height / 2), wood, 0.005)
    rounded_box("frame-right", (rail, depth, height), (width / 2 - rail / 2, 0, height / 2), wood, 0.005)
    rounded_box("frame-top", (width, depth, rail), (0, 0, height - rail / 2), wood, 0.005)
    rounded_box("frame-bottom", (width, depth, rail), (0, 0, rail / 2), wood, 0.005)
    rounded_box(
        "frame-backing",
        (width - rail * 1.55, 0.008, height - rail * 1.55),
        (0, 0.014, height / 2),
        backing,
        0.002,
    )


def dust_cover(size):
    """Faceted loose cloth over a compact CRT or a larger tower setup."""
    if size == "small":
        width, depth, height = 0.46, 0.36, 0.38
    else:
        width, depth, height = 0.72, 0.48, 0.54
    cloth = lib.material("dressing-dust-cloth", "#d6d1c3", 0.94)
    shadow = lib.material("dressing-dust-fold", "#b9b4a8", 0.96)
    sections = [
        (0.0, width * 0.90, depth * 0.90, 0.0),
        (height * 0.42, width, depth, 0.015),
        (height * 0.82, width * 0.72, depth * 0.72, -0.020),
        (height, width * 0.38, depth * 0.44, -0.025),
    ]
    cover = lib.loft("dust-cover", "Z", sections, (0, 0, 0), cloth)
    lib.bevel(cover, 0.018, 2)
    for side in (-1, 1):
        tube(
            "dust-cover-fold",
            [
                (side * width * 0.30, -depth * 0.46, 0.02),
                (side * width * 0.34, -depth * 0.49, height * 0.42),
                (side * width * 0.22, -depth * 0.37, height * 0.82),
            ],
            0.008,
            shadow,
            6,
        )


def hanging_jacket():
    """Red zip jacket displayed on a hook, back plane at +Y."""
    red = lib.material("dressing-jacket-red", "#a92f2c", 0.84)
    red_dark = lib.material("dressing-jacket-fold", "#7e2826", 0.88)
    zip_metal = lib.shared("steel-light")
    pine = lib.material("dressing-jacket-peg", "#9a672f", 0.70)
    # A faceted torso plus sleeves reads as cloth at room distance.
    torso = lib.loft(
        "jacket-torso",
        "Z",
        [
            (0.0, 0.48, 0.055, 0.0),
            (0.42, 0.52, 0.080, 0.0),
            (0.72, 0.42, 0.070, 0.0),
        ],
        (0, 0, 0),
        red,
    )
    lib.bevel(torso, 0.018, 2)
    for side in (-1, 1):
        sleeve = lib.loft(
            "jacket-sleeve",
            "Z",
            [
                (0.10, 0.13, 0.060, 0.0),
                (0.48, 0.16, 0.070, side * 0.09),
                (0.67, 0.20, 0.075, side * 0.16),
            ],
            (side * 0.35, 0, 0),
            red,
        )
        sleeve.rotation_euler[1] = radians(-side * 13)
        lib.bevel(sleeve, 0.015, 2)
        rounded_box("jacket-cuff", (0.14, 0.072, 0.055), (side * 0.43, -0.004, 0.105), red_dark, 0.012)
    rounded_box("jacket-zip", (0.012, 0.010, 0.59), (0, -0.044, 0.34), zip_metal, 0.002)
    for side in (-1, 1):
        rounded_box(
            "jacket-pocket", (0.14, 0.009, 0.012), (side * 0.13, -0.046, 0.23), red_dark, 0.003, (0, 0, side * 18)
        )
    torus("jacket-collar", 0.105, 0.035, (0, 0, 0.705), red_dark, (90, 0, 0))
    lib.cylinder("jacket-wall-peg", 0.025, 0.105, "Y", (0, 0.10, 0.78), pine, 18)


def mouse_pad():
    rubber = lib.material("dressing-mousepad-rubber", "#333a3d", 0.90)
    ink = lib.material("dressing-mousepad-ink", "#526e76", 0.84)
    rounded_box("mouse-pad", (0.245, 0.205, 0.006), (0, 0, 0.003), rubber, 0.020)
    rounded_box("mouse-pad-print", (0.17, 0.008, 0.002), (0, -0.035, 0.007), ink, 0.004, (0, 0, -5))


def book(name, size, loc, cover, rotation=0):
    width, depth, height = size
    pages = lib.shared("paper")
    rounded_box(name, (width, depth, height), loc, pages, 0.004, (0, 0, rotation))
    rounded_box(
        f"{name}-cover",
        (width + 0.006, depth + 0.008, 0.003),
        (loc[0], loc[1], loc[2] + height / 2 + 0.002),
        cover,
        0.003,
        (0, 0, rotation),
    )


def manual_binder_stack():
    blue = lib.material("dressing-binder-blue", "#546d78", 0.74)
    ochre = lib.material("dressing-binder-ochre", "#9c7442", 0.76)
    red = lib.material("dressing-binder-red", "#8d4b43", 0.76)
    book("manual-a", (0.148, 0.210, 0.018), (-0.075, 0, 0.012), blue, -5)
    book("manual-b", (0.165, 0.225, 0.025), (-0.055, 0.008, 0.035), ochre, 3)
    for index, (x, color, lean) in enumerate(((-0.20, red, -5), (-0.12, blue, 3), (-0.035, ochre, -2))):
        height = 0.245 + index * 0.018
        rounded_box("upright-binder", (0.060, 0.190, height), (x, 0.025, height / 2), color, 0.006, (0, lean, 0))
        rounded_box(
            "binder-label",
            (0.032, 0.008, height * 0.38),
            (x, -0.074, height * 0.57),
            lib.shared("paper"),
            0.003,
            (0, lean, 0),
        )


def floppy_disk(name, loc, color, lean=0):
    x, y, z = loc
    rounded_box(name, (0.090, 0.0033, 0.094), loc, color, 0.003, (0, 0, lean))
    rounded_box(f"{name}-shutter", (0.054, 0.0015, 0.030), (x, y - 0.0025, z + 0.028), lib.shared("steel-light"), 0.001)
    rounded_box(f"{name}-label", (0.062, 0.0012, 0.032), (x, y - 0.0026, z - 0.020), lib.shared("paper"), 0.001)


def floppy_box():
    card = lib.shared("cardboard")
    colors = (
        lib.material("dressing-floppy-blue", "#566b78", 0.68),
        lib.material("dressing-floppy-grey", "#6f706b", 0.70),
        lib.material("dressing-floppy-red", "#8a4e48", 0.70),
    )
    rounded_box("floppy-carton-bottom", (0.12, 0.105, 0.010), (0, 0, 0.005), card, 0.003)
    rounded_box("floppy-carton-front", (0.12, 0.006, 0.075), (0, -0.052, 0.042), card, 0.002)
    rounded_box("floppy-carton-back", (0.12, 0.006, 0.105), (0, 0.052, 0.058), card, 0.002)
    for side in (-1, 1):
        rounded_box("floppy-carton-side", (0.006, 0.105, 0.090), (side * 0.057, 0, 0.050), card, 0.002)
    rounded_box("floppy-carton-lid", (0.12, 0.110, 0.006), (0, 0.085, 0.130), card, 0.003, (-28, 0, 0))
    for index in range(6):
        floppy_disk(
            "boxed-floppy",
            (0, -0.030 + index * 0.013, 0.092 + index * 0.002),
            colors[index % len(colors)],
            (index - 2.5) * 0.8,
        )


BUILDERS = {
    "WALLCLOCK": wall_clock,
    "FIREEXTINGUISHER": fire_extinguisher,
    "POTTEDPLANT": potted_plant,
    "LAVENDERPLANT": lavender_plant,
    "DESKLAMP": desk_lamp,
    "DISPLAYCASE": display_case,
    "FRAMEDPOSTERTALL": lambda: framed_poster(0.72),
    "FRAMEDPOSTERWIDE": lambda: framed_poster(1.65),
    "DUSTCOVERSMALL": lambda: dust_cover("small"),
    "DUSTCOVERLARGE": lambda: dust_cover("large"),
    "HANGINGJACKET": hanging_jacket,
    "MOUSEPAD": mouse_pad,
    "MANUALBINDERSTACK": manual_binder_stack,
    "FLOPPYBOX": floppy_box,
}

BAKE_PARAMS = {
    "WALLCLOCK": dict(size=256, ao_floor=0.62, wear_amt=0.025, rough=0.68),
    "FIREEXTINGUISHER": dict(size=512, ao_floor=0.52, wear_amt=0.065, rough=0.58),
    "POTTEDPLANT": dict(size=512, ao_floor=0.56, wear_amt=0.045, rough=0.77),
    "LAVENDERPLANT": dict(size=512, ao_floor=0.58, wear_amt=0.035, rough=0.78),
    "DESKLAMP": dict(size=512, ao_floor=0.50, wear_amt=0.060, rough=0.58),
    "DISPLAYCASE": dict(size=512, ao_floor=0.54, wear_amt=0.090, rough=0.72),
    "FRAMEDPOSTERTALL": dict(size=256, ao_floor=0.60, wear_amt=0.055, rough=0.70),
    "FRAMEDPOSTERWIDE": dict(size=256, ao_floor=0.60, wear_amt=0.055, rough=0.70),
    "DUSTCOVERSMALL": dict(size=256, ao_floor=0.54, wear_amt=0.035, rough=0.94),
    "DUSTCOVERLARGE": dict(size=256, ao_floor=0.54, wear_amt=0.035, rough=0.94),
    "HANGINGJACKET": dict(size=512, ao_floor=0.48, wear_amt=0.040, rough=0.84),
    "MOUSEPAD": dict(size=256, ao_floor=0.64, wear_amt=0.050, rough=0.88),
    "MANUALBINDERSTACK": dict(size=512, ao_floor=0.52, wear_amt=0.075, rough=0.76),
    "FLOPPYBOX": dict(size=512, ao_floor=0.50, wear_amt=0.075, rough=0.76),
}


def main():
    variant, out = lib.parse_args("wallClock", "/tmp/dressing.glb")
    if variant not in BUILDERS:
        choices = ", ".join(BUILDERS)
        raise ValueError(f"unknown dressing variant {variant!r}; choose one of {choices}")
    lib.reset_scene()
    BUILDERS[variant]()
    lib.bpy.context.view_layer.update()
    lib_bake.maybe_bake_export(out, **BAKE_PARAMS[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
