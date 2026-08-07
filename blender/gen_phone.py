"""Parametric museum handsets (variants A/B/C, iteration 3 — design-reviewed)
with integrated display cradles.

Run headless:
  blender -b --python blender/gen_phone.py -- --variant A --out /tmp/phone-a.glb

Each GLB is the handset PLUS an integrated angled display cradle (thin base
plate, two separated riser pads carrying the bottom edge, a capturing front
lip, a narrow tilted back strut) so it stands upright on a museum desk.
Screens are recessed dark glass with NO emission; strictly generic — no
manufacturer trade dress, no logos.

Real-world dimensional ground truth (class references, generic results):
- A (2008 early Android form: chin band, physical keys, trackball, small
  screen — HTC-Dream-class): 117.7 L x 55.7 W x 17.1 D mm, 3.2 in display:
  https://en.wikipedia.org/wiki/HTC_Dream
  Photo refs: https://commons.wikimedia.org/wiki/File:HTC_Dream_(front_view).jpg
  (Design direction widened the body to 60.5 mm for the squatter
  G1-class read at museum distance.)
- B (2013 thin slab, ~5 in screen, thin bezels — Nexus-5 / Jolla class):
  137.84 L x 69.17 W x 8.59 D mm: https://en.wikipedia.org/wiki/Nexus_5
  (the Jolla, the sailfishos-tile handset, is 131 x 68 x 9.9 mm:
  https://en.wikipedia.org/wiki/Jolla_(smartphone); design direction
  thinned the slab to 7.6 mm to sharpen the thin-slab read.)
- C (2017 repairable/modular look: bumper rim, visible screws, seams —
  Fairphone-2-class): 143 L x 73 W x 11 D mm:
  https://en.wikipedia.org/wiki/Fairphone_2
  Teardown refs: https://commons.wikimedia.org/wiki/File:Teardown_Fairphone_2.jpg
  (Design direction widened the body to 77.5 mm.)

Iteration 3, applying the round-2 design judgments (archived in
~/scene-v2-reference/review/design-judgments/phone-*): A gets a wider squat
body, a crisp full-width chin crease, taller rounder keys, a raised
trackball socket and a subtle back belly; B is thinner with smoother
multi-section shoulders; C is wider with bigger corner lofts, cross-seams
carried onto the front bumper edge and larger grille slots; the cradle now
reads as an engineered dock — two separated riser pads (real gap under the
phone), a capturing lip, a narrow strut ending below the silhouette.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_smallobjects as so  # noqa: E402

PARAMS = {
    # cradle tuple: (pad_x, pad_w, pad_d, lip_style, lip_w, strut_w, strut_frac)
    "A": dict(
        w=0.0605,
        t=0.0171,
        hh=0.1177,
        tilt=20.0,
        style="chin2008",
        cradle=(0.019, 0.0070, 0.0075, "center", 0.016, 0.0105, 0.38),
    ),
    "B": dict(
        w=0.0692,
        t=0.0076,
        hh=0.1379,
        tilt=24.0,
        style="slab2013",
        cradle=(0.018, 0.0080, 0.0095, "center", 0.020, 0.0140, 0.44),
    ),
    "C": dict(
        w=0.0790,
        t=0.0110,
        hh=0.1400,
        tilt=20.0,
        style="modular2017",
        cradle=(0.021, 0.0065, 0.0075, "corners", 0.0075, 0.0140, 0.42),
    ),
}


def screen(target, w, h, front_y, z_c, depth=0.0010, liner="bezel-dark"):
    """Recessed dark-glass display: real bezel reveal walls, glass inset
    `depth` behind the fascia, no emission. (lib.well's blind back plate
    would sit in FRONT of glass at these shallow depths, so build it here.)"""
    lib.cut(target, lib.multi_box("screen-cut", [((w, depth * 2.0, h), (0, front_y, z_c))]))
    lib.pocket(
        "screen-liner",
        w - 0.0004,
        h - 0.0004,
        depth + 0.0008,
        (0, front_y + 0.0002, z_c),
        0.0010,
        so.mat(liner),
        back=False,
    )
    lib.box("screen-glass", (w - 0.0016, 0.0008, h - 0.0016), (0, front_y + depth, z_c), so.mat("glass-screen"))


def slit(target, name, w, h, front_y, x, z):
    """Small dark recessed slit (earpiece/speaker) with a real floor."""
    lib.cut(target, lib.multi_box(name + "-cut", [((w, 0.0024, h), (x, front_y, z))]))
    lib.pocket(
        name + "-liner", w - 0.0003, h - 0.0003, 0.0014, (x, front_y + 0.0002, z), 0.0006, lib.shared("recess-deep")
    )


def rounded_slab(name, w, t, hh, shoulder, mat_):
    """Phone slab with continuous multi-section rounded shoulders in the
    front view — bevel alone cannot give readable 6-9 mm corner radii."""
    secs = []
    for s, f in ((0.0, 1.55), (0.12, 0.95), (0.45, 0.42), (1.0, 0.0)):
        secs.append((shoulder * s, w - shoulder * f * 2.0, t - (0.001 if s == 0.0 else 0.0), 0.0))
    top = [(hh - z, ww, tt, off) for z, ww, tt, off in reversed(secs)]
    body = lib.loft(name, "Z", secs + top, (0, 0, 0), mat_)
    lib.bevel(body, 0.0026, 3)
    return body


def phone_a(p):
    """A: 2008 chin phone — squat beige-white body, crisp full-width chin
    crease, staggered arc of rounded keys around a prominent socketed
    trackball (the G1 control-cluster read), back belly."""
    w, t, hh = p["w"], p["t"], p["hh"]
    body = lib.loft(
        "body",
        "Z",
        [
            (0.0, w - 0.016, t + 0.0090, -0.0038),
            (0.002, w - 0.0125, t + 0.0098, -0.0042),
            (0.005, w - 0.003, t + 0.0105, -0.0050),
            (0.028, w - 0.001, t + 0.0018, -0.0008),
            (0.030, w, t, 0.0),
            (hh * 0.5, w, t + 0.0012, 0.0006),
            (hh - 0.008, w, t, 0.0),
            (hh - 0.003, w - 0.005, t - 0.001, 0.0),
            (hh, w - 0.012, t - 0.002, 0.0),
        ],
        (0, 0, 0),
        lib.shared("abs-light"),
    )
    lib.bevel(body, 0.0026, 3)
    screen(body, 0.042, 0.056, -t / 2, 0.080, 0.0014, "recess-deep")
    slit(body, "earpiece", 0.014, 0.0025, -t / 2, 0, 0.111)

    # chin face slopes out below the z=0.030 crease; controls ride the slope
    def chin_face(z):
        return -t / 2 - 0.0105 * (1 - z / 0.030)

    chin_ang = 18.0
    # staggered key arc: inner pair higher, outer pill pair lower + tucked
    for x, z, kw in (
        (-0.0136, 0.0180, 0.0106),
        (0.0136, 0.0180, 0.0106),
        (-0.0235, 0.0122, 0.0100),
        (0.0235, 0.0122, 0.0100),
    ):
        kf = chin_face(z)
        key = lib.box("chin-key", (kw, 0.0034, 0.0086), (x, kf - 0.0006, z), so.mat("phone-key"))
        lib.bevel(key, 0.0018, 3)
        so.tilt_x([key], chin_ang, (x, kf - 0.0006, z))
    bz = 0.0155
    bf = chin_face(bz)
    ring = lib.cylinder("trackball-ring", 0.0059, 0.0033, "Y", (0, bf + 0.0002, bz), so.mat("phone-key"), 28)
    so.tilt_x([ring], chin_ang, (0, bf + 0.0002, bz))
    so.ellipsoid("trackball", (0.0046, 0.0046, 0.0046), (0, bf + 0.0020, bz), lib.shared("abs-warm"))
    lib.cylinder("camera-ring", 0.0045, 0.0018, "Y", (0, t / 2 + 0.0004, 0.095), lib.shared("abs-grey"), 24)
    lib.cylinder("camera-lens", 0.0028, 0.0010, "Y", (0, t / 2 + 0.0012, 0.095), lib.shared("glass"), 18)


def phone_b(p):
    """B: 2013 thin slab — smooth rounded shoulders, near edge-to-edge dark
    glass, earpiece slit, side nubs, back camera ring. Generic, logo-free."""
    w, t, hh = p["w"], p["t"], p["hh"]
    body = rounded_slab("body", w, t, hh, 0.0062, so.mat("phone-body"))
    screen(body, 0.0612, 0.114, -t / 2, 0.071, 0.0008)
    slit(body, "earpiece", 0.011, 0.0014, -t / 2, 0, 0.1315)
    power = lib.box("power-nub", (0.0018, 0.0022, 0.0105), (w / 2 + 0.0005, 0, 0.100), so.mat("phone-frame"))
    lib.bevel(power, 0.0006, 2)
    vol = lib.box("volume-nub", (0.0018, 0.0022, 0.0165), (-w / 2 - 0.0005, 0, 0.096), so.mat("phone-frame"))
    lib.bevel(vol, 0.0006, 2)
    lib.cylinder("camera-ring", 0.0050, 0.0018, "Y", (-0.016, t / 2 + 0.0004, 0.121), so.mat("phone-frame"), 24)
    lib.cylinder("camera-lens", 0.0030, 0.0010, "Y", (-0.016, t / 2 + 0.0012, 0.121), lib.shared("glass"), 18)


def phone_c(p):
    """C: 2017 repairable/modular — proud stepped bumper rim with deep top
    and bottom zones, parting seam with cross-seams carried onto the front
    bumper edge, four big slotted bezel screws, five-slot grille in the
    upper zone, chunky camera block."""
    w, t, hh = p["w"], p["t"], p["hh"]
    frame = rounded_slab("frame", w, t, hh, 0.0075, so.mat("phone-frame"))
    lib.cut(frame, lib.multi_box("frame-cut", [((w - 0.0080, t + 0.004, hh - 0.0130), (0, 0, hh / 2))]))
    core = lib.box("core", (w - 0.0064, t - 0.0032, hh - 0.0110), (0, 0, hh / 2), so.mat("phone-body"))
    cf = -(t - 0.0032) / 2
    screen(core, 0.060, 0.104, cf, 0.068, 0.0012)
    # five-slot grille in the UPPER zone (earpiece read; never a wordmark)
    for i in range(5):
        slit(core, "grille-%d" % i, 0.0024, 0.0022, cf, -0.0088 + i * 0.0044, hh - 0.0165)
    # parting seam around sides/top + module cross-seams reaching the front
    lib.cut(
        frame,
        lib.multi_box(
            "seam-cut",
            [
                ((0.0026, 0.0024, hh - 0.012), (-w / 2, t * 0.16, hh / 2)),
                ((0.0026, 0.0024, hh - 0.012), (w / 2, t * 0.16, hh / 2)),
                ((w - 0.008, 0.0024, 0.0026), (0, t * 0.16, hh)),
                ((0.0026, 0.0110, 0.0015), (-w / 2, t * 0.06, 0.052)),
                ((0.0026, 0.0110, 0.0015), (w / 2, t * 0.06, 0.052)),
                ((0.0026, 0.0110, 0.0015), (-w / 2, t * 0.06, 0.096)),
                ((0.0026, 0.0110, 0.0015), (w / 2, t * 0.06, 0.096)),
                ((0.0085, 0.0026, 0.0015), (-w / 2 + 0.0020, -t / 2, 0.052)),
                ((0.0085, 0.0026, 0.0015), (w / 2 - 0.0020, -t / 2, 0.052)),
                ((0.0085, 0.0026, 0.0015), (-w / 2 + 0.0020, -t / 2, 0.096)),
                ((0.0085, 0.0026, 0.0015), (w / 2 - 0.0020, -t / 2, 0.096)),
            ],
        ),
    )
    # four big slotted bezel screws, recessed heads (~4 mm across)
    for x, z in (
        (-w / 2 + 0.0072, 0.0100),
        (w / 2 - 0.0072, 0.0100),
        (-w / 2 + 0.0072, hh - 0.0100),
        (w / 2 - 0.0072, hh - 0.0100),
    ):
        lib.cut(frame, lib.cylinder("screw-rec", 0.00245, 0.0024, "Y", (x, -t / 2, z), None, 18))
        lib.cylinder("screw", 0.00200, 0.0018, "Y", (x, -t / 2 + 0.0002, z), lib.shared("abs-grey"), 14)
        lib.box("screw-slot", (0.0034, 0.0007, 0.0006), (x, -t / 2 - 0.0007, z), so.mat("button-dark"))
    cam = lib.box("camera-block", (0.018, 0.0028, 0.012), (0, t / 2 + 0.0010, hh - 0.016), so.mat("phone-frame"))
    lib.bevel(cam, 0.0009, 2)
    lib.cylinder("camera-lens", 0.0032, 0.0012, "Y", (0, t / 2 + 0.0022, hh - 0.016), lib.shared("glass"), 18)
    power = lib.box("power-nub", (0.0018, 0.0024, 0.011), (w / 2 + 0.0005, 0.0028, 0.104), so.mat("phone-frame"))
    lib.bevel(power, 0.0006, 2)


def cradle(p):
    """Engineered museum dock: thin base plate, TWO separated riser pads
    carrying the bottom edge (clear daylight under the phone between them),
    a capturing front lip (central, or two corner lips leaving the lower
    bumper face visible), a narrow strut ending below the handset
    silhouette. Every contact is real geometry."""
    t, hh = p["t"], p["hh"]
    pad_x, pad_w, pad_d, lip_style, lip_w, strut_w, strut_frac = p["cradle"]
    base = lib.box("stand-base", (min(p["w"] * 0.85, 0.058), 0.050, 0.0040), (0, 0.003, 0.0020), so.mat("stand"))
    lib.bevel(base, 0.0010, 2)
    for x in (-pad_x, pad_x):
        pad = lib.box("stand-pad", (pad_w, pad_d, 0.0062), (x, t / 2 - 0.002, 0.0040 + 0.0031), so.mat("stand"))
        lib.bevel(pad, 0.0008, 2)
    corner_z = 0.0102 + 0.342 * t  # bottom-front corner after settling
    lip_h = corner_z + 0.0025 - 0.0040
    lip_xs = (0.0,) if lip_style == "center" else (-0.0145, 0.0145)
    for lx in lip_xs:
        lip = lib.box(
            "stand-lip", (lip_w, 0.0026, lip_h), (lx, -0.44 * t - 0.0016, 0.0040 + lip_h / 2), so.mat("stand")
        )
        lib.bevel(lip, 0.0008, 2)
    sl = hh * strut_frac
    ys = t / 2 + 0.0020
    strut = lib.box("stand-strut", (strut_w, 0.0035, sl), (0, ys, 0.0040 + sl / 2), so.mat("stand"))
    lib.bevel(strut, 0.0009, 2)
    so.tilt_x([strut], -p["tilt"], (0, ys, 0.0040))


def build(p):
    before = so.scene_objects()
    {"chin2008": phone_a, "slab2013": phone_b, "modular2017": phone_c}[p["style"]](p)
    phone = list(so.scene_objects() - before)
    so.tilt_x(phone, -p["tilt"], (0, p["t"] / 2, 0))
    so.move(phone, (0, 0, 0.0102 - so.min_z(phone)))
    cradle(p)


def main():
    variant, out = lib.parse_args("A", "/tmp/param-phone.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    # `--textured`: 1024px baked atlas (phone budget), else flat massing GLB
    so.maybe_bake_export(out, size=1024, roughness=0.52)


if __name__ == "__main__" and lib.bpy is not None:
    main()
