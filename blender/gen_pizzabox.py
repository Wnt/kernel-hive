"""Parametric horizontal desktop computer cases (variants A-F).

Run headless:
  blender -b --python blender/gen_pizzabox.py -- --variant C --out /tmp/pizzabox-c.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

Real-world dimensional ground truth:
- A follows the IBM PC/XT 5160 envelope: 500 W x 411 D x 147 H mm.
  IBM 5155/5160 Technical Reference, physical characteristics:
  https://www.minuszerodegrees.net/manuals/IBM_5155_5160_Technical_Reference_6280089_MAR86.pdf
- B follows the 1990 Macintosh LC "slim desktop" envelope:
  12.2 W x 15.3 D x 2.9 H in = 310 x 389 x 74 mm (https://support.apple.com/en-asia/112199),
  blended with the Compaq Deskpro 386s front architecture. GENERIC: no Apple
  badges or trade dress; the top vent field deliberately avoids the LC's
  full-lid pattern.
- C follows the SPARCstation 2 system unit: 16 W x 16 D x 2.8 H in =
  409 x 409 x 71 mm.
  https://docs.oracle.com/cd/E19127-01/sparc2.ws/800-5166-10/800-5166-10.pdf
- D follows the IBM PS/2 Model 77 envelope: 360 W x 395 D x 115 H mm.
  https://www.infania.net/misc1/techspecs/pdf/77.pdf
  Its sloped badge/control zone is generic PS/2-style language: no IBM mark.
- E follows the Compaq Deskpro EN SFF envelope: 318 W x 371 D x 90 H mm.
  https://kentie.net/article/retropc/deskpro_en_series.pdf
- F follows IBM PC 300PL Type 6562: 450 W x 450 D x 128 H mm.
  https://www.ibmfiles.com/ibmfiles/pc300/65xx_technical_information.pdf
- 5.25-inch full-height drive face: 146.1 x 82.6 mm; 3.5-inch face:
  101.6 x 25.4 mm. https://handwiki.org/wiki/Engineering:Drive_bay

Iteration 4 is the frozen best state after four design-review rounds
(judgments archived in ~/scene-v2-reference/review/design-judgments/
pizzabox-*/round[1-4].judgment.md):
- A: ONE deep near-black aperture holding two black full-height 5.25" drive
  faces, dense 16-slit vent bank, vertical metallic identity plate, folded
  steel lid + side seams, recessed side power switch, tall corner feet.
- B: molded full-width channel over a proud lower fascia band carrying an
  offset floppy bezel (slot/eject/LED), pocketed power rocker + LED, badge
  recess, wrapping lid seam, deep top groove field, broad feet.
- C: near-full-face dimple field, solid inset badge plate, indicator lens in
  a bore, recessed low floppy mouth with surround, flat chamfered lid with
  thin wraparound seam, flush grey side rails.
Round-4 residuals (noted, not resolved — the round cap was reached): the
judge still wants softer molded radii overall, an even deeper aperture read
on A, a stronger channel back on B, and higher-contrast dimples on C.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402
import lib_case_matrix as matrix_case  # noqa: E402
import lib_classicdesks as cd  # noqa: E402

FDD_W, FDD_H = 0.1016, 0.0254
BAY_FULL_W, BAY_FULL_H = 0.1461, 0.0826

PARAMS = {
    "A": dict(w=0.500, d=0.411, h=0.147, style="xt"),
    "B": dict(w=0.310, d=0.389, h=0.074, style="slim"),
    "C": dict(w=0.409, d=0.409, h=0.071, style="workstation"),
    "D": dict(w=0.360, d=0.395, h=0.115, style="ps2"),
    "E": dict(w=0.318, d=0.371, h=0.090, style="sff"),
    "F": dict(w=0.450, d=0.450, h=0.128, style="pc300"),
}

BAKE_KW = {
    "D": dict(
        tone=(1.09, 1.075, 1.04),
        ao_floor=0.50,
        ao_curve=(0.30, 0.94),
        grain_mul=0.72,
        wear_amt=0.04,
        rough=0.59,
        ao_samples=48,
    ),
    "E": dict(
        tone=(1.08, 1.075, 1.06),
        ao_floor=0.49,
        ao_curve=(0.31, 0.94),
        grain_mul=0.82,
        wear_amt=0.04,
        rough=0.58,
        ao_samples=48,
    ),
    "F": dict(
        tone=(1.085, 1.075, 1.045),
        ao_floor=0.50,
        ao_curve=(0.30, 0.94),
        grain_mul=0.74,
        wear_amt=0.04,
        rough=0.59,
        ao_samples=48,
    ),
}


def xt_drive(name, x, z, y_face):
    """Full-height 5.25-inch BLACK drive face: disk mouth, latch, lamp."""
    face = lib.box(name + "-face", (BAY_FULL_W, 0.005, BAY_FULL_H), (x, y_face, z), cd.mat("drive-face"))
    slot_z = z + 0.020
    lib.cut(face, lib.multi_box(name + "-slot-cut", [((0.112, 0.016, 0.0060), (x, y_face, slot_z))]))
    lib.box(name + "-slot-floor", (0.114, 0.0016, 0.0090), (x, y_face + 0.0042, slot_z), cd.mat("dark"))
    lib.box(name + "-latch", (0.0085, 0.0085, 0.026), (x, y_face - 0.0042, z - 0.006), cd.mat("dark"))
    lib.box(name + "-latch-hub", (0.020, 0.0060, 0.0085), (x, y_face - 0.0028, z - 0.006), cd.mat("drive-face"))
    lib.box(name + "-lamp", (0.0052, 0.0030, 0.0040), (x - 0.050, y_face - 0.0018, z - 0.028), cd.mat("recess"))
    lib.bevel(face, 0.0010, 1)


def xt_front(fascia, p, y_f, z0):
    """XT fascia: ONE deep dark aperture + dense vent bank + vertical badge."""
    ap_w, ap_h = 0.320, 0.100
    ap_x, ap_z = 0.070, z0 + 0.066
    lib.cut(fascia, lib.multi_box("aperture-cut", [((ap_w, 0.052, ap_h), (ap_x, y_f, ap_z))]))
    lib.pocket("aperture", ap_w - 0.0006, ap_h - 0.0006, 0.020, (ap_x, y_f + 0.0003, ap_z), mat=cd.mat("dark"))
    lib.box("aperture-floor", (ap_w - 0.002, 0.0020, ap_h - 0.002), (ap_x, y_f + 0.0202, ap_z), cd.mat("dark"))
    # drives sit INSIDE the shared black recess with minimal separation
    for i, dx in enumerate((-0.0745, 0.0745)):
        xt_drive(f"drive{i}", ap_x + dx, ap_z, y_f + 0.012)
    slits = []
    for i in range(16):
        x = -0.224 + i * 0.0068
        slits.append(((0.0038, 0.030, 0.052), (x, y_f, z0 + 0.034)))
    lib.cut(fascia, lib.multi_box("vent-cuts", slits))
    lib.box("vent-floor", (0.112, 0.0016, 0.062), (-0.173, y_f + 0.0080, z0 + 0.034), cd.mat("recess-deep"))
    # small vertical metallic identity plate directly above the vent bank
    lib.box("badge-well", (0.020, 0.0016, 0.050), (-0.216, y_f + 0.0008, z0 + 0.092), cd.mat("recess"))
    lib.box("badge-plate", (0.016, 0.0030, 0.046), (-0.216, y_f - 0.0006, z0 + 0.092), cd.mat("badge-label"))


def xt_body(p):
    """Folded-steel U-cover over a pan chassis; framed radiused fascia."""
    w, d, h = p["w"], p["d"], p["h"]
    z0 = 0.012
    y_f = -d / 2
    cd.feet(w, d, z0, inset=0.052, size=0.046)
    body_h = h - z0 - 0.005
    body = lib.box("body", (w - 0.006, d - 0.022, body_h), (0, 0.011, z0 + body_h / 2), cd.mat("abs-warm"))
    fascia = lib.box("fascia", (w - 0.002, 0.022, body_h), (0, y_f + 0.011, z0 + body_h / 2), cd.mat("abs"))
    # thin folded-steel lid: minimal overhang, shallow front fold
    lid = lib.box("lid", (w + 0.002, d + 0.002, 0.005), (0, -0.001, h - 0.0025), cd.mat("steel-warm"))
    lib.box("lid-skirt", (w + 0.002, 0.0032, 0.010), (0, y_f - 0.0004, h - 0.0075), cd.mat("steel-warm"))
    xt_front(fascia, p, y_f, z0)
    # seam lines: low side seam where the folded cover meets the pan
    lib.cut(
        body,
        lib.multi_box(
            "seam-cuts",
            [
                ((0.0030, d * 0.94, 0.0016), (-w / 2 + 0.0028, 0.011, z0 + 0.012)),
                ((0.0030, d * 0.94, 0.0016), (w / 2 - 0.0028, 0.011, z0 + 0.012)),
            ],
        ),
    )
    # side power switch housed on a recessed mounting plate
    lib.box("switch-plate", (0.0016, 0.052, 0.050), (w / 2 - 0.0024, 0.150, z0 + 0.068), cd.mat("recess"))
    lib.box("side-switch", (0.009, 0.026, 0.028), (w / 2 - 0.001, 0.150, z0 + 0.068), cd.mat("dark"))
    lib.bevel(body, 0.0016, 1)
    lib.bevel(fascia, 0.0030, 2)
    lib.bevel(lid, 0.0008, 1)


def slim_front(shell, p, y_f, z0):
    """Slim fascia: molded channel with returns, offset floppy bezel, rocker."""
    w = p["w"]
    ch_z, ch_h = 0.052, 0.017
    lib.cut(shell, lib.multi_box("channel-cut", [((w + 0.004, 0.012, ch_h), (0, y_f, ch_z))]))
    lib.pocket("channel", w - 0.0006, ch_h - 0.0006, 0.0058, (0, y_f + 0.0003, ch_z), mat=cd.mat("recess"))
    # pronounced lower fascia band: proud, tall, with its own top seam
    step_h = ch_z - ch_h / 2 - z0
    step = lib.box("fascia-step", (w, 0.0045, step_h), (0, y_f - 0.00225, z0 + step_h / 2), cd.mat("abs"))
    lib.cut(step, lib.multi_box("step-seam", [((w + 0.004, 0.0030, 0.0013), (0, y_f - 0.0035, z0 + step_h - 0.004))]))
    # floppy: unmistakable offset assembly ON the lower band — shallow bezel
    # plate, narrow slot with dark cavity, eject button, activity LED
    fd_x, fd_w = -0.070, 0.098
    bez = lib.box("floppy-bezel", (fd_w, 0.0035, 0.0165), (fd_x, y_f - 0.0035, 0.0295), cd.mat("abs-light"))
    lib.cut(bez, lib.multi_box("fd-slot-cut", [((0.078, 0.014, 0.0032), (fd_x - 0.005, y_f - 0.0035, 0.0330))]))
    lib.box("fd-slot-floor", (0.080, 0.0014, 0.0050), (fd_x - 0.005, y_f - 0.0012, 0.0330), cd.mat("dark"))
    lib.box("floppy-eject", (0.0095, 0.0060, 0.0044), (fd_x + 0.040, y_f - 0.0056, 0.0252), cd.mat("abs-grey"))
    lib.box("floppy-lamp", (0.0042, 0.0028, 0.0032), (fd_x - 0.040, y_f - 0.0044, 0.0252), cd.mat("dark"))
    lib.bevel(bez, 0.0010, 1)
    # badge: molded recess on the lower band, right of the floppy
    cd.badge_plate("badge", 0.050, 0.0125, y_f - 0.0045, 0.030, 0.028, plate_mat="badge-label")
    # power: its own recessed bezel on the lower band, clear of the channel
    lib.well(step, "power-pocket", 0.034, 0.023, y_f - 0.0045, 0.114, 0.0295, 0.007, mat=cd.mat("recess"))
    rocker = lib.box("power-rocker", (0.020, 0.012, 0.014), (0.114, y_f - 0.0055, 0.0295), cd.mat("abs-grey"))
    lib.bevel(rocker, 0.0016, 1)
    lib.box("power-led", (0.0044, 0.0028, 0.0040), (0.090, y_f - 0.0056, 0.0295), cd.mat("dark"))
    return step


def slim_body(p):
    """Slim shell: base return, square lid, wrapping seam, big groove field."""
    w, d, h = p["w"], p["d"], p["h"]
    z0 = 0.006
    y_f = -d / 2
    cd.feet(w, d, z0, inset=0.034, size=0.042)
    base = lib.box("base-return", (w - 0.005, d - 0.005, 0.010), (0, 0, z0 + 0.005), cd.mat("abs-warm"))
    shell_h = h - z0 - 0.010
    shell = lib.box("shell", (w, d, shell_h), (0, 0, z0 + 0.010 + shell_h / 2), cd.mat("abs"))
    step = slim_front(shell, p, y_f, z0)
    # lid seam: thin groove wrapping front + both sides just under the top
    seam_z = h - 0.0062
    lib.cut(
        shell,
        lib.multi_box(
            "lid-seam-cuts",
            [
                ((w + 0.004, 0.0040, 0.0015), (0, y_f + 0.0008, seam_z)),
                ((0.0040, d * 0.97, 0.0015), (-w / 2 + 0.0008, 0, seam_z)),
                ((0.0040, d * 0.97, 0.0015), (w / 2 - 0.0008, 0, seam_z)),
            ],
        ),
    )
    cd.groove_top(shell, "top-grooves", w * 0.70, 12, d * 0.02, d * 0.74, h, g_w=0.0048, g_d=0.0026)
    lib.bevel(base, 0.0014, 1)
    lib.bevel(shell, 0.0014, 1)
    lib.bevel(step, 0.0012, 1)


def workstation_body(p):
    """Sun-class pizza box: dimple fascia, flat chamfered lid, side rails."""
    w, d, h = p["w"], p["d"], p["h"]
    z0 = 0.009
    y_f = -d / 2
    # broad flat grey side rails, flush with the case sides — visible lift
    for sx in (-1, 1):
        rail = lib.box("foot-rail", (0.068, d - 0.050, z0), (sx * (w / 2 - 0.034), 0, z0 / 2), cd.mat("abs-grey"))
        lib.bevel(rail, 0.0012, 1)
    body_h = h - z0 - 0.0045
    body = lib.box("body", (w, d, body_h), (0, 0, z0 + body_h / 2), cd.mat("abs"))
    # flat lid, NARROW perimeter chamfer, planar top
    lid = lib.loft(
        "lid",
        "Z",
        [
            (0.0, w, d, 0.0),
            (0.0045, w - 0.011, d - 0.011, 0.0),
        ],
        (0, 0, h - 0.0045),
        cd.mat("abs"),
    )
    # unmistakable dimple field across nearly the full fascia
    cd.dimple_field(body, "dimples", 0.340, 0.044, y_f, -0.006, z0 + 0.0255, pitch=0.0138, r=0.0034, depth=0.0024)
    # solid inset identification plate, left
    lib.box("badge-well", (0.062, 0.0016, 0.018), (-0.150, y_f + 0.0008, z0 + 0.031), cd.mat("recess"))
    lib.box("badge-plate", (0.058, 0.0026, 0.015), (-0.150, y_f + 0.0002, z0 + 0.031), cd.mat("badge-label"))
    # tiny indicator lens seated in a real bore, right side of the fascia
    lib.cut(body, lib.cylinder("indicator-cut", 0.0030, 0.010, "Y", (0.182, y_f, z0 + 0.031), None, 12))
    lib.cylinder("indicator-bore", 0.0028, 0.0028, "Y", (0.182, y_f + 0.0026, z0 + 0.031), cd.mat("recess-deep"), 12)
    lib.cylinder("indicator", 0.0022, 0.0034, "Y", (0.182, y_f + 0.0014, z0 + 0.031), cd.mat("dark"), 12)
    # low floppy opening with a period surround: shallow recess, then mouth
    lib.cut(body, lib.multi_box("fd-surround-cut", [((0.104, 0.006, 0.0125), (-0.104, y_f, z0 + 0.0105))]))
    lib.pocket("fd-surround", 0.1034, 0.0119, 0.0028, (-0.104, y_f + 0.0003, z0 + 0.0105), mat=cd.mat("recess"))
    lib.cut(body, lib.multi_box("floppy-cut", [((0.090, 0.014, 0.0064), (-0.104, y_f, z0 + 0.0100))]))
    lib.pocket("floppy-mouth", 0.0894, 0.0058, 0.0060, (-0.104, y_f + 0.0028, z0 + 0.0100), mat=cd.mat("recess-deep"))
    # continuous thin lid seam wrapping front + sides
    seam_z = h - 0.0058
    lib.cut(
        body,
        lib.multi_box(
            "lid-seam-cuts",
            [
                ((w + 0.004, 0.0030, 0.0010), (0, y_f + 0.0008, seam_z)),
                ((0.0030, d * 0.97, 0.0010), (-w / 2 + 0.0008, 0, seam_z)),
                ((0.0030, d * 0.97, 0.0010), (w / 2 - 0.0008, 0, seam_z)),
            ],
        ),
    )
    lib.bevel(body, 0.0016, 1)
    lib.bevel(lid, 0.0006, 1)


def build(p):
    if p["style"] == "xt":
        xt_body(p)
    elif p["style"] == "slim":
        slim_body(p)
    elif p["style"] == "workstation":
        workstation_body(p)
    elif p["style"] == "ps2":
        matrix_case.build_pizzabox_ps2()
    elif p["style"] == "sff":
        matrix_case.build_pizzabox_sff()
    else:
        matrix_case.build_pizzabox_pc300()


def main():
    variant, out = lib.parse_args("A", "/tmp/param-pizzabox.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    lib_bake.maybe_bake_export(out, **BAKE_KW.get(variant, {}))


if __name__ == "__main__" and lib.bpy is not None:
    main()
