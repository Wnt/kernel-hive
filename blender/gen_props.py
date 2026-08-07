"""Parametric institutional set-dressing props for the scene-v2 gallery.

Run headless (named variants are independent, placeable assets):
  blender -b --python blender/gen_props.py -- \
    --variant officeChairA --out /tmp/office-chair-a.glb --textured

Variants:
- officeChairA: armless charcoal upholstered task chair on five castors.
- officeChairB: pale molded task chair with short armrests on five castors.
- chairTubularRed: burgundy upholstered classroom chair on a tubular frame.
- chairPlywoodOrange: orange-brown plywood school chair on four steel legs.
- chairTaskBlue: blue-grey high-backed operator chair on five castors.
- deskPedestalWood: older dark-wood twin-pedestal office desk.
- cableRun: desk-rear basket, hanging cable drop, and two floor-run covers.
- shelfUnit: powder-coated archive shelving with generic machine hulls/cartons.
- deskClutter: A5 manual, open ten-disk carton, and modeled 3.5-inch disks.

Real-world dimensional ground truth (meters in geometry):
- Both chairs use the compact IKEA LOBERGET/MALSKÄR task-chair envelope:
  0.670 W x 0.670 D x 0.899 H, 0.400 W x 0.429 D seat, 0.460-0.572
  adjustable seat height:
  https://www.ikea.com/us/en/p/loberget-malskaer-swivel-chair-pad-white-dark-gray-s59445453/
- The accumulated classroom variants keep the common 430-460 mm school-chair
  seat width and 450 mm seat height documented in the director-approved
  reference set; the desk keeps its required 720 mm museum work height.
- The archive shelf uses the BROR public-use powder-coated galvanized-steel
  unit: 0.851 W x 0.549 D x 1.899 H, five 19 mm-deep shelves:
  https://www.ikea.com/us/en/p/bror-shelving-unit-black-s89617443/
- Floor cable cover cross-section follows Wiremold Corduct CDBK-5:
  1.524 L x 0.064 W x 0.0114 H (shortened to fit the prop footprint):
  https://www.legrand.us/wire-and-cable-management/raceway-and-cord-covers/floor-based/corduct-5-overfloor-cord-protector-black/p/cdbk-5
  The 22 x 13 mm desk-rear/drop strip follows Wiremold 500 raceway:
  https://www.legrand.us/wire-and-cable-management/raceway-and-cord-covers/perimeter-based/wiremold-500-series-small-raceway-ivory/p/v500
- Manual stock is ISO A5, 148 x 210 mm:
  https://www.iso.org/standard/36631.html
- Disk geometry is the TEAC/ECMA 90 mm cartridge envelope, 90 x 94 x 3.3 mm:
  https://retrocmp.de/fdd/teac/TEAC_FD-35_Brochure_Mar85.pdf
  Standard scope: https://ecma-international.org/publications-and-standards/standards/ecma-125/

All forms are real mesh geometry. Recesses, shelf lips, disk shutters, cable
clips, wheel forks, chair controls, and booklet cover marks are not painted.
Materials come only from lib.shared(); --textured uses the shared MJ library
through lib_bake.
"""

import sys
from math import cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402
import lib_smallobjects as small  # noqa: E402

FURNITURE_MATERIALS = {
    "burgundy": ("#8d302f", 0.72),
    "orange-plywood": ("#b86627", 0.58),
    "plywood-edge": ("#704522", 0.68),
    "task-blue": ("#667d8e", 0.74),
    "dark-wood": ("#5a3825", 0.66),
    "dark-wood-edge": ("#38271e", 0.72),
}


def furniture_mat(key):
    color, roughness = FURNITURE_MATERIALS[key]
    return lib.material("furniture-" + key, color, roughness)


def rounded_box(name, size, loc, material, bevel=0.004, rotations=(0.0, 0.0, 0.0)):
    obj = lib.box(name, size, loc, material)
    obj.rotation_euler = tuple(radians(v) for v in rotations)
    if bevel:
        lib.bevel(obj, bevel, 2)
    return obj


def radial_xy(radius, angle):
    """XY point where angle zero points toward the rear (+Y)."""
    return (-radius * sin(angle), radius * cos(angle))


def chair_base(upholstery, pale=False):
    """Five-spoke 0.67 m task-chair base, gas lift, forks, and twin castors."""
    steel = lib.shared("steel-light" if pale else "steel")
    dark = lib.shared("cable")
    for i in range(5):
        angle = i * 2.0 * pi / 5.0
        x, y = radial_xy(0.172, angle)
        spoke = rounded_box(
            "base-spoke",
            (0.032, 0.305, 0.028),
            (x, y, 0.070),
            steel,
            0.009,
            (0, 0, angle * 180.0 / pi),
        )
        spoke.rotation_euler[0] = radians(-2.5)
        wx, wy = radial_xy(0.327, angle)
        # Fork above the axle; each castor has two independently modeled wheels.
        rounded_box("castor-fork", (0.026, 0.030, 0.052), (wx, wy, 0.045), dark, 0.006)
        for side in (-1, 1):
            wheel = lib.cylinder(
                "castor-wheel",
                0.027,
                0.013,
                "X",
                (wx + side * 0.010 * cos(angle), wy + side * 0.010 * sin(angle), 0.027),
                dark,
                20,
            )
            wheel.rotation_euler[2] = angle
            lib.bevel(wheel, 0.0015, 1)
    lib.cylinder("base-hub", 0.060, 0.060, "Z", (0, 0, 0.090), steel, 28)
    lib.cylinder("gas-lift", 0.025, 0.320, "Z", (0, 0, 0.260), dark, 28)
    lib.cylinder("gas-shroud", 0.041, 0.190, "Z", (0, 0, 0.285), steel, 28)
    rounded_box("tilt-mechanism", (0.180, 0.155, 0.045), (0, 0.015, 0.435), dark, 0.010)
    # Height paddle: horizontal stem + flattened grip.
    lib.cylinder("height-stem", 0.006, 0.150, "X", (-0.105, 0.025, 0.430), dark, 14)
    rounded_box("height-paddle", (0.045, 0.022, 0.014), (-0.184, 0.025, 0.430), upholstery, 0.006)


def chair_a():
    """Low-backed, armless upholstered operator chair."""
    upholstery = lib.shared("vinyl")
    chair_base(upholstery)
    rounded_box("seat-pan", (0.445, 0.420, 0.045), (0, 0, 0.468), lib.shared("cable"), 0.016)
    seat = rounded_box("seat-cushion", (0.425, 0.395, 0.068), (0, -0.010, 0.506), upholstery, 0.028)
    seat.scale.x = 1.04
    # Twin visible back uprights leave a real air gap below the back pad.
    for x in (-0.120, 0.120):
        small.tube(
            "back-upright",
            [(x, 0.150, 0.474), (x, 0.177, 0.600), (x, 0.195, 0.710)],
            0.011,
            lib.shared("steel"),
            6,
        )
    back = rounded_box(
        "back-cushion",
        (0.405, 0.070, 0.285),
        (0, 0.193, 0.735),
        upholstery,
        0.030,
        (-7.0, 0, 0),
    )
    # Upholstery welt is raised geometry around the front-facing perimeter.
    for x in (-0.188, 0.188):
        rounded_box("back-welt-side", (0.006, 0.006, 0.225), (x, 0.154, 0.735), lib.shared("steel"), 0.002)
    for z in (0.625, 0.845):
        rounded_box("back-welt-edge", (0.366, 0.006, 0.006), (0, 0.154, z), lib.shared("steel"), 0.002)
    lib.bevel(back, 0.010, 2)


def chair_b():
    """Pale molded-shell training/task chair with compact armrests."""
    shell = lib.shared("abs-grey")
    chair_base(shell, pale=True)
    rounded_box("seat-underpan", (0.430, 0.420, 0.045), (0, 0, 0.469), lib.shared("steel"), 0.015)
    rounded_box("seat-shell", (0.415, 0.400, 0.052), (0, -0.010, 0.505), shell, 0.026, (2.0, 0, 0))
    # Narrow pedestal spine and molded back with a shallow lumbar pad.
    small.tube(
        "back-spine",
        [(0, 0.135, 0.480), (0, 0.170, 0.610), (0, 0.205, 0.755)],
        0.020,
        lib.shared("steel-light"),
        8,
    )
    rounded_box("back-shell", (0.420, 0.045, 0.315), (0, 0.203, 0.742), shell, 0.030, (-8.0, 0, 0))
    rounded_box("lumbar-pad", (0.350, 0.022, 0.095), (0, 0.169, 0.686), lib.shared("abs-light"), 0.020)
    for side in (-1, 1):
        x = side * 0.232
        small.tube(
            "arm-support",
            [(side * 0.180, 0.080, 0.485), (x, 0.085, 0.620), (x, -0.030, 0.650)],
            0.012,
            lib.shared("steel-light"),
            6,
        )
        rounded_box("arm-pad", (0.065, 0.235, 0.025), (x, -0.020, 0.657), shell, 0.012)


def chair_tubular_red():
    """Burgundy vinyl classroom chair with a continuous chrome tube frame."""
    upholstery = furniture_mat("burgundy")
    steel = lib.shared("steel-light")
    dark = lib.shared("cable")
    # Four splayed legs and a continuous back hoop make a visibly older,
    # non-task-chair silhouette.
    for x in (-0.205, 0.205):
        for y in (-0.165, 0.165):
            sx = 1 if x > 0 else -1
            sy = 1 if y > 0 else -1
            small.tube(
                "tubular-leg",
                [(x, y, 0.455), (x + sx * 0.035, y + sy * 0.045, 0.035)],
                0.011,
                steel,
                8,
            )
            lib.cylinder(
                "rubber-foot",
                0.017,
                0.030,
                "Z",
                (x + sx * 0.035, y + sy * 0.045, 0.015),
                dark,
                16,
            )
    for x in (-0.205, 0.205):
        small.tube(
            "back-hoop",
            [(x, 0.165, 0.430), (x, 0.205, 0.675), (x * 0.92, 0.215, 0.805)],
            0.011,
            steel,
            8,
        )
    small.tube(
        "back-hoop-top",
        [(-0.188, 0.215, 0.805), (0.188, 0.215, 0.805)],
        0.011,
        steel,
        8,
    )
    rounded_box("seat-underpan", (0.455, 0.420, 0.028), (0, -0.005, 0.443), dark, 0.010)
    rounded_box("seat-cushion", (0.430, 0.395, 0.065), (0, -0.018, 0.478), upholstery, 0.026)
    rounded_box(
        "back-cushion",
        (0.410, 0.060, 0.235),
        (0, 0.188, 0.690),
        upholstery,
        0.025,
        (-5.0, 0, 0),
    )
    for x in (-0.190, 0.190):
        rounded_box("back-piping", (0.006, 0.006, 0.190), (x, 0.153, 0.690), dark, 0.002)


def chair_plywood_orange():
    """Orange-brown formed-plywood school chair with grey tubular legs."""
    plywood = furniture_mat("orange-plywood")
    edge = furniture_mat("plywood-edge")
    steel = lib.shared("steel")
    dark = lib.shared("cable")
    for x in (-0.190, 0.190):
        for y in (-0.155, 0.155):
            sx = 1 if x > 0 else -1
            sy = 1 if y > 0 else -1
            small.tube(
                "school-leg",
                [(x, y, 0.445), (x + sx * 0.030, y + sy * 0.045, 0.025)],
                0.010,
                steel,
                8,
            )
            lib.cylinder(
                "school-foot",
                0.016,
                0.022,
                "Z",
                (x + sx * 0.030, y + sy * 0.045, 0.011),
                dark,
                14,
            )
    for x in (-0.180, 0.180):
        small.tube(
            "back-support",
            [(x, 0.155, 0.430), (x, 0.185, 0.635), (x, 0.205, 0.755)],
            0.010,
            steel,
            8,
        )
    rounded_box("ply-seat-edge", (0.455, 0.410, 0.030), (0, -0.010, 0.447), edge, 0.025, (2.5, 0, 0))
    rounded_box("ply-seat-face", (0.442, 0.397, 0.018), (0, -0.014, 0.458), plywood, 0.022, (2.5, 0, 0))
    rounded_box(
        "ply-back-edge",
        (0.445, 0.032, 0.250),
        (0, 0.197, 0.675),
        edge,
        0.028,
        (-8.0, 0, 0),
    )
    rounded_box(
        "ply-back-face",
        (0.430, 0.020, 0.235),
        (0, 0.178, 0.676),
        plywood,
        0.025,
        (-8.0, 0, 0),
    )


def chair_task_blue():
    """Blue-grey high-backed task chair, deliberately armless and compact."""
    upholstery = furniture_mat("task-blue")
    chair_base(upholstery)
    rounded_box("blue-seat-pan", (0.455, 0.425, 0.044), (0, 0, 0.466), lib.shared("cable"), 0.016)
    rounded_box("blue-seat", (0.435, 0.405, 0.075), (0, -0.012, 0.507), upholstery, 0.030)
    small.tube(
        "blue-back-spine",
        [(0, 0.150, 0.475), (0, 0.190, 0.650), (0, 0.215, 0.805)],
        0.022,
        lib.shared("steel"),
        8,
    )
    rounded_box(
        "blue-back",
        (0.430, 0.075, 0.355),
        (0, 0.206, 0.715),
        upholstery,
        0.035,
        (-9.0, 0, 0),
    )
    # A real horizontal lumbar break keeps it from reading as chair A recolored.
    rounded_box("blue-lumbar", (0.380, 0.020, 0.060), (0, 0.162, 0.625), lib.shared("steel"), 0.018)


def desk_pedestal_wood():
    """Dark-wood 1970s twin-pedestal desk with a deep kneehole."""
    wood = furniture_mat("dark-wood")
    edge = furniture_mat("dark-wood-edge")
    steel = lib.shared("steel")
    # 1.46 x 0.72 m plan, exactly 0.72 m high to preserve exhibit placement.
    rounded_box("pedestal-top", (1.460, 0.720, 0.055), (0, 0, 0.6925), wood, 0.018)
    rounded_box("pedestal-top-edge", (1.475, 0.735, 0.025), (0, 0, 0.672), edge, 0.014)
    for x in (-0.535, 0.535):
        rounded_box("pedestal-carcass", (0.330, 0.610, 0.635), (x, 0.035, 0.3275), wood, 0.012)
        # Three proud drawer fronts face the visitor (-Y).
        for index, (z, height) in enumerate(((0.555, 0.150), (0.365, 0.190), (0.145, 0.220))):
            rounded_box(
                "drawer-front",
                (0.300, 0.024, height - 0.018),
                (x, -0.282, z),
                edge if index == 0 else wood,
                0.007,
            )
            rounded_box("drawer-pull", (0.105, 0.018, 0.018), (x, -0.306, z + 0.015), steel, 0.006)
    rounded_box("modesty-panel", (0.720, 0.035, 0.410), (0, 0.300, 0.385), edge, 0.008)
    for x in (-0.535, 0.535):
        rounded_box("pedestal-plinth", (0.350, 0.625, 0.035), (x, 0.035, 0.0175), edge, 0.007)


def floor_raceway(name, length, loc, angle=0.0):
    """Low trapezoidal PVC cord protector, modeled to Corduct cross-section."""
    raceway = lib.loft(
        name,
        "Z",
        [(0.0, length, 0.064, 0.0), (0.0114, length - 0.010, 0.030, 0.0)],
        loc,
        lib.shared("cable"),
    )
    raceway.rotation_euler[2] = radians(angle)
    lib.bevel(raceway, 0.002, 1)
    # Real cover joints, not a texture seam.
    for frac in (-0.26, 0.26):
        x = loc[0] + frac * length * cos(angle)
        y = loc[1] + frac * length * sin(angle)
        seam = rounded_box("raceway-joint", (0.004, 0.066, 0.013), (x, y, 0.0065), lib.shared("steel"), 0.001)
        seam.rotation_euler[2] = radians(angle)
    return raceway


def cable_run():
    """Desk-rear cable basket, loose drop loops, clips, and covered floor runs."""
    steel = lib.shared("steel")
    cable = lib.shared("cable")
    # Basket mounts at the unseen rear edge of a standard 0.72-0.76 m desk.
    rounded_box("basket-back", (0.760, 0.018, 0.090), (0, 0.105, 0.705), steel, 0.004)
    rounded_box("basket-floor", (0.760, 0.105, 0.012), (0, 0.055, 0.665), steel, 0.004)
    for x in (-0.345, 0.345):
        rounded_box("desk-hook", (0.035, 0.150, 0.012), (x, 0.000, 0.755), steel, 0.004)
        rounded_box("desk-hook-tab", (0.035, 0.012, 0.075), (x, -0.070, 0.724), steel, 0.004)
    # Five separate cables visibly leave the basket, sag, bunch, and reach floor.
    for i, x in enumerate((-0.260, -0.130, 0.0, 0.130, 0.260)):
        offset = (i - 2) * 0.006
        small.tube(
            "cable-drop",
            [
                (x, 0.040, 0.700),
                (x + offset, -0.015, 0.560),
                (0.300 + offset, 0.010, 0.400),
                (0.330 + offset, 0.075, 0.120),
                (0.330 + offset, 0.120, 0.018),
            ],
            0.0042 if i == 2 else 0.0032,
            (lib.shared("abs-grey") if i == 1 else lib.shared("recess-deep") if i == 3 else cable),
            8,
        )
    # Two wall/drop clips with real slots encircle the bundle visually.
    for z in (0.350, 0.205):
        rounded_box("bundle-clip", (0.060, 0.014, 0.018), (0.322, 0.072, z), steel, 0.005)
        rounded_box("clip-gap", (0.020, 0.006, 0.021), (0.322, 0.062, z), cable, 0.003)
    floor_raceway("floor-run-long", 1.180, (0.0, 0.165, 0.0))
    floor_raceway("floor-run-branch", 0.500, (0.420, 0.380, 0.0), 90.0)
    # Short exposed tails explain entry/exit from the covers.
    for y in (0.125, 0.205):
        small.tube(
            "floor-tail",
            [(0.325, y, 0.016), (0.390, y, 0.017), (0.470, y, 0.012)],
            0.0033,
            cable,
            5,
        )


def machine_hull(name, loc, size, warm=False, vents=4):
    """Generic archived equipment shell with a real front recess and vents."""
    x, y, z = loc
    w, d, h = size
    material = lib.shared("abs-warm" if warm else "abs-grey")
    body = rounded_box(name, size, loc, material, 0.008)
    front_y = y - d / 2
    lib.well(body, name + "-panel", w * 0.72, h * 0.38, front_y, x, z, 0.012, mat=lib.shared("recess"))
    for i in range(vents):
        vx = x - w * 0.27 + i * (w * 0.54 / max(vents - 1, 1))
        rounded_box(name + "-vent", (0.010, 0.004, h * 0.20), (vx, front_y - 0.002, z), lib.shared("dark"), 0.002)
    rounded_box(
        name + "-handle",
        (w * 0.22, 0.020, 0.018),
        (x, front_y - 0.015, z + h * 0.31),
        lib.shared("steel"),
        0.006,
    )


def shelf_unit():
    """Five-level public-use archive rack, populated but deliberately generic."""
    steel = lib.shared("steel")
    # Four 40 mm posts define the BROR 0.851 x 0.549 x 1.899 m envelope.
    for x in (-0.405, 0.405):
        for y in (-0.255, 0.255):
            rounded_box("shelf-post", (0.040, 0.040, 1.899), (x, y, 0.9495), steel, 0.005)
    levels = (0.045, 0.470, 0.900, 1.330, 1.850)
    for z in levels:
        rounded_box("shelf-deck", (0.825, 0.525, 0.019), (0, 0, z), lib.shared("steel-light"), 0.004)
        rounded_box("shelf-front-lip", (0.825, 0.025, 0.055), (0, -0.251, z + 0.018), steel, 0.004)
        rounded_box("shelf-rear-lip", (0.825, 0.020, 0.040), (0, 0.254, z + 0.012), steel, 0.004)
    # Rear anti-racking cross braces are visible through the open shelves.
    small.tube("brace-a", [(-0.385, 0.270, 0.080), (0.385, 0.270, 1.810)], 0.008, steel, 4)
    small.tube("brace-b", [(0.385, 0.275, 0.080), (-0.385, 0.275, 1.810)], 0.008, steel, 4)
    # Lower and middle machine hulls: deliberately asymmetrical archive stack.
    machine_hull("machine-large", (-0.115, -0.010, 0.205), (0.550, 0.430, 0.285), warm=True, vents=6)
    machine_hull("machine-small", (0.195, -0.025, 0.620), (0.350, 0.400, 0.230), vents=4)
    machine_hull("machine-flat", (-0.155, -0.020, 1.030), (0.465, 0.410, 0.160), warm=True, vents=5)
    # Cardboard archive cartons with separate lids, tape strips, and hand holes.
    for i, (x, z, w) in enumerate(((-0.205, 1.515, 0.360), (0.220, 1.500, 0.300))):
        rounded_box("archive-carton", (w, 0.400, 0.260), (x, 0.010, z), lib.shared("cardboard"), 0.008)
        rounded_box("carton-lid", (w + 0.012, 0.412, 0.030), (x, 0.010, z + 0.145), lib.shared("paper"), 0.006)
        rounded_box("carton-tape", (0.040, 0.416, 0.006), (x, 0.010, z + 0.162), lib.shared("abs-warm"), 0.002)
        rounded_box("carton-label", (w * 0.42, 0.005, 0.065), (x, -0.194, z + 0.035), lib.shared("paper"), 0.003)
        rounded_box("carton-mark", (w * 0.25, 0.006, 0.008), (x, -0.198, z + 0.045), steel, 0.002)
        if i == 0:
            rounded_box("carton-mark", (w * 0.18, 0.006, 0.008), (x, -0.198, z + 0.022), steel, 0.002)


def floppy_disk(name, loc, lean=0.0):
    """90 x 94 x 3.3 mm disk with modeled shutter, label, and hub recess."""
    x, y, z = loc
    disk = rounded_box(name, (0.090, 0.0033, 0.094), loc, lib.shared("abs-grey"), 0.003, (0, 0, lean))
    # The visible face is -Y; all details stand proud by fractions of a mm.
    rounded_box(name + "-shutter", (0.054, 0.0012, 0.032), (x, y - 0.0022, z + 0.027), lib.shared("steel-light"), 0.001)
    rounded_box(name + "-label", (0.066, 0.0010, 0.031), (x, y - 0.0023, z - 0.021), lib.shared("paper"), 0.001)
    lib.cylinder(name + "-hub", 0.011, 0.0012, "Y", (x, y - 0.0025, z + 0.001), lib.shared("steel"), 24)
    return disk


def desk_clutter():
    """A5 operations booklet beside an open carton of 3.5-inch disks."""
    # Closed A5 booklet with separate cover, page block, spine, and title bars.
    rounded_box("manual-pages", (0.146, 0.207, 0.008), (-0.105, -0.010, 0.010), lib.shared("paper"), 0.004, (0, 0, -8))
    rounded_box("manual-cover", (0.148, 0.210, 0.002), (-0.105, -0.010, 0.015), lib.shared("steel"), 0.003, (0, 0, -8))
    rounded_box("manual-spine", (0.010, 0.210, 0.012), (-0.174, -0.000, 0.011), lib.shared("steel"), 0.003, (0, 0, -8))
    rounded_box(
        "manual-title-field", (0.112, 0.100, 0.0025), (-0.100, -0.040, 0.017), lib.shared("paper"), 0.003, (0, 0, -8)
    )
    for i, width in enumerate((0.092, 0.066, 0.078, 0.050)):
        rounded_box(
            "manual-title-bar",
            (width, 0.010, 0.002),
            (-0.100, -0.075 + i * 0.023, 0.017),
            lib.shared("steel" if i == 0 else "abs-grey"),
            0.002,
            (0, 0, -8),
        )
    # Open ten-disk carton: lower box hides disk bottoms, rear flap stays open.
    bx, by = 0.125, 0.015
    cardboard = lib.shared("cardboard")
    rounded_box("floppy-box-bottom", (0.105, 0.062, 0.006), (bx, by, 0.006), cardboard, 0.003)
    rounded_box("floppy-box-front", (0.105, 0.004, 0.055), (bx, by - 0.031, 0.031), cardboard, 0.002)
    rounded_box("floppy-box-back", (0.105, 0.004, 0.088), (bx, by + 0.031, 0.048), cardboard, 0.002)
    for side in (-1, 1):
        rounded_box("floppy-box-side", (0.004, 0.062, 0.070), (bx + side * 0.0525, by, 0.040), cardboard, 0.002)
    rounded_box("floppy-box-flap", (0.105, 0.075, 0.004), (bx, by + 0.060, 0.103), cardboard, 0.002, (-25, 0, 0))
    for i, y in enumerate((0.006, 0.014, 0.022, 0.030)):
        floppy_disk("boxed-disk", (bx, y, 0.067 + i * 0.002), lean=(i - 1.5) * 1.5)
    # One loose disk overlaps the manual so its physical scale reads instantly.
    loose_loc = (-0.030, -0.005, 0.064)
    before = small.scene_objects()
    floppy_disk("loose-disk", loose_loc, lean=-12.0)
    loose_parts = small.scene_objects() - before
    small.tilt_x(loose_parts, 87.5, loose_loc)
    small.move(loose_parts, (0.0, 0.0, -0.047))


BUILDERS = {
    "OFFICECHAIRA": chair_a,
    "OFFICECHAIRB": chair_b,
    "CHAIRTUBULARRED": chair_tubular_red,
    "CHAIRPLYWOODORANGE": chair_plywood_orange,
    "CHAIRTASKBLUE": chair_task_blue,
    "DESKPEDESTALWOOD": desk_pedestal_wood,
    "CABLERUN": cable_run,
    "SHELFUNIT": shelf_unit,
    "DESKCLUTTER": desk_clutter,
}

BAKE_PARAMS = {
    "OFFICECHAIRA": dict(size=1024, ao_floor=0.58, grain_scale=70.0, rough=0.60),
    "OFFICECHAIRB": dict(size=1024, ao_floor=0.60, grain_scale=80.0, rough=0.56),
    "CHAIRTUBULARRED": dict(size=1024, ao_floor=0.58, grain_scale=75.0, rough=0.64),
    "CHAIRPLYWOODORANGE": dict(size=1024, ao_floor=0.56, grain_scale=64.0, rough=0.58),
    "CHAIRTASKBLUE": dict(size=1024, ao_floor=0.58, grain_scale=74.0, rough=0.64),
    "DESKPEDESTALWOOD": dict(
        size=1024,
        ao_floor=0.52,
        grain_scale=48.0,
        grain_mul=1.12,
        wear_amt=0.055,
        rough_texture=True,
        rough_variation=0.08,
    ),
    "CABLERUN": dict(
        size=1024,
        ao_floor=0.45,
        grain_scale=85.0,
        grain_mul=1.15,
        wear_amt=0.060,
        rough_texture=True,
        rough_variation=0.08,
    ),
    "SHELFUNIT": dict(
        size=1024,
        ao_floor=0.43,
        grain_scale=65.0,
        grain_mul=1.20,
        wear_amt=0.105,
        rough_texture=True,
        rough_variation=0.10,
    ),
    "DESKCLUTTER": dict(
        size=1024,
        ao_floor=0.48,
        grain_scale=100.0,
        grain_mul=1.25,
        wear_amt=0.075,
        rough_texture=True,
        rough_variation=0.12,
    ),
}


def main():
    variant, out = lib.parse_args("officeChairA", "/tmp/param-props.glb")
    if variant not in BUILDERS:
        choices = ", ".join(BUILDERS)
        raise ValueError(f"unknown prop variant {variant!r}; choose one of {choices}")
    lib.reset_scene()
    BUILDERS[variant]()
    lib.bpy.context.view_layer.update()
    lib_bake.maybe_bake_export(out, **BAKE_PARAMS[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
