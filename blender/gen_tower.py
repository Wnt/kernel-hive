"""Parametric tower cases (variants A-E).

Run headless:
  blender -b --python blender/gen_tower.py -- --variant B --out /path/tower-b.glb

Iteration 2 (director: variant B; "black outlines look too cartoonish"):
every painted dark rectangle from iteration 1 is replaced by REAL recessed
geometry — through-cut bay cavities with warm-grey plastic liners, drive
faces set INTO the cavities behind a few-mm reveal, buttons as proud solids
standing in blind wells, groove/vent shading from actual cut depth. The only
near-black left is the badge text plate and the keyhole core.

Real-world dimensional ground truth (do not invent proportions):
- 5.25" half-height bay faceplate: 146.1 x 41.3 mm
  https://handwiki.org/wiki/Engineering:Drive_bay
  https://www.micropolis.com/support/kb/disk-drive-and-drive-bay-form-factors
- 3.5" bay faceplate: 101.6 mm wide, slot-height 25.4/26.1 mm
  https://handwiki.org/wiki/Engineering:Drive_bay
- Mid-tower envelope ~430-490 H x 200-230 W x 400-480 D mm (ATX era, 1995+):
  https://www.newegg.com/insider/computer-case-size-buying-guide-a-technical-overview-for-pc-builders/
  1998 beige ATX mid-tower measured 457 H x 203 W x 406 D mm:
  https://www.mnpctech.com/products/vintage-beige-atx-case-with-cooling-mods-used-no-returns
- Front-detail language (proud fascia band, recessed drive faces, disc tray
  seam): Gateway 2000 P5-75 close-up + IBM Aptiva, Wikimedia Commons
  https://commons.wikimedia.org/wiki/File:Gateway_2000_P5-75_close-up.jpg
  https://commons.wikimedia.org/wiki/File:Ibm_aptiva.jpg
- D: Dell Dimension 8100-class 222 W x 491 H x 453 D mm consumer tower.
  https://manualmachine.com/dell/dimension8100/1431430-user-manual/
  Coordinated silver/graphite finish:
  https://www.computerworld.com/article/1411973/product-review-dell-dimension-8100.html
- E: HP Compaq dc5800-class 177 W x 377 H x 428 D mm microtower.
  https://manualzilla.com/doc/7317687/compaq-dc5800---microtower-pc-quickspecs
Both are anonymous, badge-free interpretations.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_case_matrix as matrix_case  # noqa: E402

BAY_W, BAY_H = 0.1461, 0.0413  # 5.25" half-height faceplate
FDD_W, FDD_H = 0.1016, 0.0254  # 3.5" faceplate
FASCIA_D = 0.024  # proud fascia thickness; every cavity lives inside it

# Three tuned silhouettes; heights/widths inside the researched envelope.
PARAMS = {
    "A": dict(w=0.185, h=0.380, d=0.400, bays525=2, power="round", reset=False, keylock=False, display=False, vents=6),
    "B": dict(w=0.195, h=0.420, d=0.430, bays525=2, power="square", reset=True, keylock=True, display=False, vents=8),
    "C": dict(w=0.210, h=0.480, d=0.450, bays525=3, power="square", reset=True, keylock=True, display=True, vents=10),
    "D": dict(w=0.222, h=0.491, d=0.453, style="dimension"),
    "E": dict(w=0.177, h=0.377, d=0.428, style="oem"),
}


def bay_cavity(fascia, name, ow, oh, y_f, zc, depth):
    """Through-cut a bay opening and line it: real interior, no painted ring."""
    lib.cut(fascia, lib.multi_box(name + "-cut", [((ow, 0.08, oh), (0, y_f + 0.01, zc))]))
    lib.pocket(name + "-liner", ow - 0.0006, oh - 0.0006, depth, (0, y_f + 0.0003, zc), 0.0014, lib.shared("recess"))


def cd_drive(y_f, zc):
    """CD-ROM face set 6 mm INTO its cavity; tray/button proud of the face."""
    face_y = y_f + 0.006  # front plane of the drive face
    lib.box("cd-face", (BAY_W, 0.004, BAY_H), (0, face_y + 0.002, zc), lib.shared("abs-light"))
    lib.box("cd-tray", (BAY_W - 0.014, 0.0036, 0.015), (0, face_y - 0.0018, zc + 0.0085), lib.shared("abs-light"))
    lib.box("cd-btn", (0.011, 0.0044, 0.004), (BAY_W / 2 - 0.015, face_y - 0.0016, zc - 0.0125), lib.shared("abs"))
    lib.box("cd-led", (0.003, 0.0040, 0.0024), (BAY_W / 2 - 0.029, face_y - 0.0014, zc - 0.0125), mat_led("g"))
    lib.cylinder(
        "cd-vol", 0.0028, 0.0040, "Y", (-BAY_W / 2 + 0.015, face_y - 0.0012, zc - 0.0125), lib.shared("abs-grey"), 16
    )


def blank_cover(i, y_f, zc):
    """Blank bay cover recessed 5 mm, with two real pressed grooves."""
    face_y = y_f + 0.005
    cover = lib.box(f"bay-cover{i}", (BAY_W, 0.004, BAY_H), (0, face_y + 0.002, zc), lib.shared("abs"))
    grooves = [((BAY_W - 0.016, 0.0024, 0.0022), (0, face_y, zc + s)) for s in (-0.007, 0.007)]
    lib.cut(cover, lib.multi_box(f"cover-grooves{i}", grooves))


def fdd_drive(fascia, y_f, zc):
    """3.5" floppy: recessed face with a REAL through-slot + proud eject."""
    bay_cavity(fascia, "fdd", FDD_W + 0.006, FDD_H + 0.006, y_f, zc, 0.014)
    face_y = y_f + 0.0055
    face = lib.box("fdd-face", (FDD_W, 0.004, FDD_H), (0, face_y + 0.002, zc), lib.shared("abs-light"))
    lib.cut(face, lib.multi_box("fdd-slot-cut", [((FDD_W - 0.016, 0.02, 0.0036), (0, face_y + 0.002, zc + 0.0045))]))
    lib.box(
        "fdd-slot-back", (FDD_W - 0.012, 0.0016, 0.008), (0, face_y + 0.0055, zc + 0.0045), lib.shared("recess-deep")
    )
    lib.box("fdd-btn", (0.0085, 0.0045, 0.005), (FDD_W / 2 - 0.013, face_y - 0.0018, zc - 0.0065), lib.shared("abs"))
    lib.box("fdd-led", (0.0028, 0.0040, 0.0022), (-FDD_W / 2 + 0.011, face_y - 0.0014, zc - 0.006), mat_led("g"))


def mat_led(kind):
    return lib.material("led-g", "#3fae4a", 0.4) if kind == "g" else lib.material("led-a", "#c78a2e", 0.4)


def round_well(fascia, name, r, depth, y_f, x, z, segs=24):
    """Blind cylindrical recess: boolean cylinder cut + warm-grey liner disc."""
    cutter = lib.cylinder(name + "-cut", r, depth * 2.0, "Y", (x, y_f, z), None, segs)
    lib.cut(fascia, cutter)
    lib.cylinder(name + "-liner", r - 0.0003, depth - 0.001, "Y", (x, y_f + depth / 2, z), lib.shared("recess"), segs)


def controls(fascia, p, y_f, h):
    """Power/reset as proud solids standing in real blind wells."""
    pb_z = h * 0.30
    if p["power"] == "round":
        round_well(fascia, "pw", 0.0128, 0.005, y_f, 0.0, pb_z, 28)
        lib.cylinder("power", 0.0095, 0.013, "Y", (0, y_f - 0.0025, pb_z), lib.shared("abs-light"), 28)
    else:
        lib.well(fascia, "pw", 0.028, 0.019, y_f, 0.030, pb_z, 0.006, mat=lib.shared("recess"))
        lib.box("power", (0.018, 0.014, 0.012), (0.030, y_f - 0.0035 + 0.007, pb_z), lib.shared("abs-light"))
    if p["reset"]:
        lib.well(fascia, "rst", 0.015, 0.010, y_f, 0.030, pb_z - 0.026, 0.004, mat=lib.shared("recess"))
        lib.box("reset", (0.010, 0.010, 0.006), (0.030, y_f - 0.0025 + 0.005, pb_z - 0.026), lib.shared("abs-light"))
    led_x = -0.026 if p["power"] == "square" else 0.024
    lib.box("led-pwr", (0.0038, 0.0040, 0.0038), (led_x, y_f - 0.0012, pb_z + 0.004), mat_led("g"))
    lib.box("led-hdd", (0.0038, 0.0040, 0.0038), (led_x, y_f - 0.0012, pb_z - 0.006), mat_led("a"))
    if p["keylock"]:
        round_well(fascia, "kl", 0.0075, 0.004, y_f, -0.030, pb_z - 0.026, 20)
        lib.cylinder("keylock", 0.0032, 0.003, "Y", (-0.030, y_f + 0.0028, pb_z - 0.026), lib.shared("dark"), 16)
    if p["display"]:  # AT-era MHz display: dark glass INSIDE a lined well
        lib.well(fascia, "mhz", 0.034, 0.019, y_f, 0.0, pb_z + 0.040, 0.004, mat=lib.shared("recess"))
        lib.box("mhz-glass", (0.030, 0.0016, 0.015), (0, y_f + 0.0022, pb_z + 0.040), lib.shared("dark"))


def build(p):
    if p.get("style") == "dimension":
        matrix_case.build_tower_dimension()
        return
    if p.get("style") == "oem":
        matrix_case.build_tower_oem()
        return
    w, h, d = p["w"], p["h"], p["d"]
    y_f = -d / 2.0  # fascia front plane
    body = lib.box(
        "body",
        (w, d - 0.016, h - 0.006),
        (0, y_f + FASCIA_D - 0.004 + (d - 0.016) / 2, (h + 0.006) / 2),
        lib.shared("abs-warm"),
    )
    for sx in (-1, 1):
        for sy in (0.06, d - 0.06):
            lib.box("foot", (0.03, 0.05, 0.007), (sx * (w / 2 - 0.03), y_f + sy, 0.0035), lib.shared("recess-deep"))
    fascia = lib.box(
        "fascia", (w + 0.004, FASCIA_D, h - 0.006), (0, y_f + FASCIA_D / 2, (h + 0.006) / 2), lib.shared("abs")
    )

    # --- bays: real cavities, faces set in behind a reveal -----------------
    z = h - 0.030
    bay_z = []
    for i in range(p["bays525"]):
        zc = z - BAY_H / 2
        bay_z.append(zc)
        bay_cavity(fascia, f"bay{i}", BAY_W + 0.006, BAY_H + 0.006, y_f, zc, 0.016)
        z -= BAY_H + 0.009
    z -= 0.006
    cd_drive(y_f, bay_z[0])
    for i, zc in enumerate(bay_z[1:]):
        blank_cover(i, y_f, zc)
    fdd_drive(fascia, y_f, z - FDD_H / 2)

    # --- vents: blind slots with a warm-grey floor plate -------------------
    vent_w = w * 0.55
    slots = [((vent_w, 0.010, 0.0028), (0, y_f, 0.042 + i * 0.0064)) for i in range(p["vents"])]
    lib.cut(fascia, lib.multi_box("vent-cuts", slots))
    span = p["vents"] * 0.0064
    lib.box(
        "vent-floor",
        (vent_w + 0.006, 0.0016, span + 0.006),
        (0, y_f + 0.0035, 0.042 + span / 2 - 0.0032),
        lib.shared("recess-deep"),
    )

    controls(fascia, p, y_f, h)

    # --- badge: shallow lined well, dark text plate inset ------------------
    lib.well(fascia, "badge", 0.028, 0.011, y_f, -w / 2 + 0.032, h - 0.017, 0.003, mat=lib.shared("recess"))
    lib.box("badge-plate", (0.024, 0.0014, 0.008), (-w / 2 + 0.032, y_f + 0.0016, h - 0.017), lib.shared("dark"))

    lib.bevel(fascia, width=0.0024, segments=2)
    lib.bevel(body, width=0.0016, segments=1)


def main():
    variant, out = lib.parse_args("B", "/tmp/param-tower.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    bake_kw = dict(
        tone=(1.04, 1.04, 1.05),
        ao_floor=0.47,
        ao_curve=(0.32, 0.94),
        grain_mul=1.15,
        wear_amt=0.05,
        rough=0.57,
        ao_samples=48,
    )
    if variant == "E":
        bake_kw.update(
            tone=(1.25, 1.25, 1.27),
            ao_floor=0.64,
            grain_mul=0.85,
            wear_amt=0.04,
        )
    lib_bake.maybe_bake_export(out, **bake_kw)


if __name__ == "__main__" and lib.bpy is not None:
    main()
