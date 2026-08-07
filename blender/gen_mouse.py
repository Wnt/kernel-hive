"""Parametric mouse family (legacy A-C plus HARDWARE-MATRIX D-G).

Run headless:
  blender -b --python blender/gen_mouse.py -- --variant B --out /tmp/mouse-b.glb

Real-world dimensional ground truth:
- A (boxy 80s two-button brick, Microsoft "green-eye" / Amiga-1000 class):
  the period Macintosh-era compact envelope measures 107.95 L x 63.5 W x
  38.1 H mm: https://www.si.edu/object/apple-macintosh-mouse:nmah_1328760
  Photo refs: https://commons.wikimedia.org/wiki/File:First_MS-Mouse.jpg and
  https://commons.wikimedia.org/wiki/File:Amiga_1000_Mouse.jpg
- B (curved 90s two-button ball mouse, Microsoft Mouse 2.0 / Logitech
  MouseMan class): the 1993 ADB Mouse II measured 108 L x 62 W x 38 H mm
  with a 19-22 mm ball: https://wiki.retrotechcollection.com/Apple_Desktop_Bus_Mouse_II
  Photo refs: https://commons.wikimedia.org/wiki/File:Mouse_Microsoft_PS2.jpg
  and https://commons.wikimedia.org/wiki/File:ADB_logitech_mouseman_(2215463902).jpg
- C (squarish one-button, generic — NO Apple trade dress, no logo): original
  M0100 documented as 97 L x 70 W x 36 H mm:
  https://wiki.retrotechcollection.com/Apple_Mouse
  Sun's one-piece workstation mouse envelope 100 L x 80 W x 50 H mm:
  https://docs.oracle.com/cd/E19127-01/sparc2.ws/800-5166-10/800-5166-10.pdf

Iteration 6, applying the round-3 design judgments (archived in
~/scene-v2-reference/review/design-judgments/mouse-*): bodies narrowed for a
longer read (the lineup camera foreshortens depth); button caps are thin
deck-following panels (~3 mm, ~1.8 mm proud, uniform reveal) and B gets two
REAL tapered caps on a planar slope-cut button face instead of incised
grooves; the boot is a 5-rib ~20 mm tapered unit seated in a cut socket; the
cable ends in a molded era connector lying on the desk — no blunt tube end.

Matrix-variant sources and exact body envelopes:
- D, 2000/2001 pale/silver three-button optical wheel mouse,
  68 W x 39 H x 126 D mm:
  https://download.microsoft.com/download/c/d/7/cd79e2f2-aacc-47c9-820b-f30de9b95b16/tds_intellimouseoptical_0704a.pdf
  https://news.microsoft.com/source/2001/09/25/new-microsoft-mouse-family-unleashes-wireless-intellimouse-explorer/
- E, anonymous black wired optical mouse, 62 x 38 x 113 mm:
  https://www.logitech.com/en-ae/products/mice/m100-usb-mouse.html
- F, continuous low-profile wireless touch mouse, 57 x 22 x 114 mm:
  https://support.apple.com/en-ie/121931
- G, angular three-button workstation mouse, 80 x 50 x 100 mm:
  https://docs.oracle.com/cd/E19127-01/sparc5.ws/801-6396-11/801-6396-11.pdf
  https://vtda.org/docs/computing/Sun/hardware/800-6802-12_Type5KeyboardandMouseProductNotes_RevA_Oct93.pdf

The bodies preserve generic era cues only; logos, exact seams, side controls,
and maker-specific contours are omitted. Front/button/cable end remains -Y
in Blender so it exports as +Z in glTF and receives the assembly's yaw-pi.
"""

import sys
from math import atan2, cos, degrees, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_inputdevices as inp  # noqa: E402
import lib_smallobjects as so  # noqa: E402

PARAMS = {
    "A": dict(w=0.063, d=0.112, h=0.040, style="boxy"),
    "B": dict(w=0.060, d=0.118, h=0.038, style="curved"),
    "C": dict(w=0.070, d=0.107, h=0.0345, style="square"),
    "D": dict(w=0.068, d=0.126, h=0.039, style="silver-optical"),
    "E": dict(w=0.062, d=0.113, h=0.038, style="black-optical"),
    "F": dict(w=0.057, d=0.114, h=0.022, style="touch"),
    "G": dict(w=0.080, d=0.100, h=0.050, style="workstation"),
}

TEXTURE_PARAMS = {
    "D": dict(roughness=0.48, grain_scale=100.0, grain_mul=0.72, ao_floor=0.76),
    "E": dict(roughness=0.52, grain_scale=100.0, grain_mul=1.65, ao_floor=0.74),
    "F": dict(roughness=0.44, grain_scale=100.0, grain_mul=1.70, ao_floor=0.76),
    "G": dict(roughness=0.56, grain_scale=110.0, grain_mul=1.70, ao_floor=0.68),
}


def cable(body, exit_y, exit_z):
    """5-rib tapered boot seated in a cut socket, drooping cable, and a
    molded connector on the desk so the cable never ends in a blunt tube."""
    lib.cut(body, lib.cylinder("socket-cut", 0.0052, 0.008, "Y", (0, exit_y + 0.002, exit_z), None, 24))
    for i, r in enumerate((0.0048, 0.0044, 0.0040, 0.0035, 0.0030)):
        lib.cylinder("boot-rib-%d" % i, r, 0.0038, "Y", (0, exit_y - 0.0016 - i * 0.0039, exit_z), so.mat("cable"), 20)
    s = exit_y - 0.0195
    so.tube(
        "cable",
        [
            (0.0, s + 0.004, exit_z),
            (0.0, s - 0.008, exit_z * 0.93),
            (0.0, s - 0.028, 0.0021),
            (0.022, s - 0.052, 0.0019),
            (0.062, s - 0.060, 0.0019),
            (0.096, s - 0.046, 0.0019),
            (0.110, s - 0.030, 0.0019),
            (0.110, s - 0.014, 0.0019),
        ],
        0.00195,
        so.mat("cable"),
    )
    lib.cylinder("conn-collar", 0.0028, 0.005, "Y", (0.110, s - 0.008, 0.0019), so.mat("cable"), 18)
    conn = lib.box("connector", (0.0105, 0.016, 0.0062), (0.110, s + 0.002, 0.0031), so.mat("cable"))
    lib.bevel(conn, 0.0012, 2)
    lib.box(
        "connector-contact",
        (0.0070, 0.0012, 0.0036),
        (0.110, s + 0.0102, 0.0031),
        inp.mat("black-well"),
    )


def slope_cut(body, w, y_rear, z_rear, y_front, z_front):
    """Shave the front-top wedge: a big tilted cutter whose bottom plane runs
    through the (y_rear, z_rear) -> (y_front, z_front) deck slope line."""
    ang = degrees(atan2(z_rear - z_front, y_rear - y_front))
    my, mz = (y_rear + y_front) / 2, (z_rear + z_front) / 2
    phi = radians(ang)
    hh = 0.011
    c = (0, my - sin(phi) * hh, mz + cos(phi) * hh)
    cutter = lib.multi_box("slope-cut", [((w + 0.02, abs(y_rear - y_front) + 0.03, 0.022), c)])
    so.tilt_x([cutter], ang, c)
    lib.cut(body, cutter)


def deck_caps(body, w_span, fy, y0, z0, y1, z1, count, gap, cap_mat, front_scale=1.0, lip_h=0.0060, lip_y_off=-0.0006):
    """Thin button panels on the sloped deck: a tilted 1.5 mm pocket with a
    uniform ~1.2 mm reveal, deck-following caps ~1.8 mm proud, and slim
    turned-down lips wrapping the leading edge. front_scale < 1 tapers the
    caps toward the nose (B's plan narrows there)."""
    ang = degrees(atan2(z1 - z0, y1 - y0))
    y_c, z_c = (y0 + y1) / 2, (z0 + z1) / 2
    length = y1 - y0
    cutter = lib.multi_box("deck-cut", [((w_span + 0.0024, length + 0.002, 0.0030), (0, y_c, z_c))])
    so.tilt_x([cutter], ang, (0, y_c, z_c))
    lib.cut(body, cutter)
    cap_w = (w_span - gap * (count - 1)) / count
    cap_len = length - 0.0016
    for i in range(count):
        x = -w_span / 2 + cap_w / 2 + i * (cap_w + gap)
        cap = lib.loft(
            "button-%d" % i,
            "Y",
            [(-cap_len / 2, cap_w * front_scale, 0.0030, 0.0), (cap_len / 2, cap_w, 0.0030, 0.0)],
            (x, y_c - 0.0008, z_c + 0.0003),
            so.mat(cap_mat),
        )
        lib.bevel(cap, 0.0010, 2)
        so.tilt_x([cap], ang, (x, y_c, z_c))
        if lip_h > 0:
            lip_w = cap_w * front_scale
            lip = lib.box(
                "button-lip-%d" % i,
                (lip_w, 0.0022, lip_h),
                (x, fy + lip_y_off, z0 + 0.0022 - lip_h / 2),
                so.mat(cap_mat),
            )
            lib.bevel(lip, 0.0009, 2)


def boxy_mouse(p):
    """A: 80s brick — long straight-sided shell, flat rear deck, sloped
    two-button front, thin caps wrapping the leading edge."""
    w, d, h = p["w"], p["d"], p["h"]
    body = so.shell(
        "body",
        [
            (0.0, w * 0.985, d * 0.985, 0.0, 6.2),
            (0.003, w, d, 0.0, 6.2),
            (h - 0.006, w * 0.99, d * 0.99, 0.0, 6.0),
            (h, w * 0.95, d * 0.96, 0.0, 5.5),
        ],
        lib.shared("abs"),
        segments=44,
        front_narrow=0.05,
    )
    fy = -d / 2 * 0.985
    z_front = 0.0295
    slope_cut(body, w, -0.006, h, fy - 0.002, z_front)
    y1 = -0.009
    z1 = z_front + (y1 - (fy - 0.002)) / (-0.006 - (fy - 0.002)) * (h - z_front)
    deck_caps(body, w - 0.016, fy, fy - 0.0008, z_front, y1, z1, 2, 0.0035, "button-dark")
    cable(body, fy, 0.017)


def curved_mouse(p):
    """B: 90s teardrop — dome peak ~46% from the nose, sharper rear downturn,
    planar slope-cut button face carrying two real tapered caps."""
    w, d = p["w"], p["d"]
    body = so.shell(
        "body",
        [
            (0.0, w * 0.95, d * 0.97, 0.0, 2.8),
            (0.005, w, d, 0.0, 2.8),
            (0.010, w * 0.995, d * 0.995, 0.0, 2.7),
            (0.021, w * 0.94, d * 0.90, 0.001, 2.5),
            (0.029, w * 0.86, d * 0.72, -0.001, 2.3),
            (0.035, w * 0.72, d * 0.50, -0.003, 2.2),
            (0.038, w * 0.50, d * 0.30, -0.004, 2.1),
        ],
        lib.shared("abs"),
        segments=48,
    )
    fy = -d / 2 - 0.001
    z_front = 0.012
    slope_cut(body, w, -0.020, 0.0345, fy - 0.001, z_front)
    y1 = -0.0225
    z1 = z_front + (y1 - (fy - 0.001)) / (-0.020 - (fy - 0.001)) * (0.0345 - z_front)
    deck_caps(body, 0.044, fy + 0.0015, fy + 0.0007, z_front, y1, z1, 2, 0.002, "abs", 0.66, 0.0050, 0.0018)
    so.shade_smooth(body, 46.0)
    cable(body, -d / 2 + 0.0015, 0.0065)


def one_button_mouse(p):
    """C: squarish one-button — continuous side draft, crowned plateau,
    single wide thin wrapping cap, unmarked shell."""
    w, d, h = p["w"], p["d"], p["h"]
    body = so.shell(
        "body",
        [
            (0.0, w * 0.99, d * 0.99, 0.0, 4.6),
            (0.004, w, d, 0.0, 4.6),
            (0.012, w * 0.975, d * 0.975, 0.0, 4.4),
            (h - 0.004, w * 0.86, d * 0.87, 0.001, 4.0),
            (h, w * 0.79, d * 0.81, 0.001, 3.8),
        ],
        lib.shared("abs"),
        segments=44,
        front_narrow=0.05,
    )
    fy = -d / 2 * 0.97
    z_front = 0.0255
    slope_cut(body, w, -0.010, h, fy - 0.002, z_front)
    y1 = fy + 0.028
    z1 = z_front + (y1 - (fy - 0.002)) / (-0.010 - (fy - 0.002)) * (h - z_front)
    deck_caps(body, 0.048, fy, fy - 0.0008, z_front, y1, z1, 1, 0.0, "button-grey")
    cable(body, fy, 0.015)


def _wheel_slot(body, y, z, length, width, radius=0.0055):
    cutter = lib.multi_box(
        "wheel-slot-cut",
        [((width + 0.004, length, 0.014), (0, y, z + 0.002))],
    )
    lib.cut(body, cutter)
    inp.wheel("click-wheel", y, z, radius, width, inp.mat("wheel"))


def _optical_body(p, dark=False):
    """D/E: symmetric wired optical shell with a real wheel pocket."""
    w, d, h = p["w"], p["d"], p["h"]
    body_mat = inp.mat("mouse-black" if dark else "mouse-pale")
    body = so.shell(
        "optical-body",
        [
            (0.0, w * 0.88, d * 0.94, 0.0, 2.6),
            (0.004, w, d, 0.0, 2.6),
            (0.010, w * 0.99, d * 0.98, 0.001, 2.5),
            (h * 0.62, w * 0.89, d * 0.79, 0.006, 2.35),
            (h * 0.88, w * 0.70, d * 0.55, 0.010, 2.2),
            (h, w * 0.45, d * 0.30, 0.011, 2.1),
        ],
        body_mat,
        56,
        0.13,
    )
    fy = -d / 2
    z_front = 0.0115
    y1 = -d * 0.11
    if dark:
        # E's buttons are shell-integrated like inexpensive office mice.
        # A real narrow groove divides the two click regions without adding
        # a projecting squared deck that would break the oval nose.
        seam = so.tube(
            "button-seam-cut",
            [
                (0, fy + 0.006, 0.015),
                (0, -d * 0.35, 0.022),
                (0, -d * 0.20, h * 0.77),
            ],
            0.0011,
            None,
            3,
        )
        lib.cut(body, seam)
        z1 = h * 0.76
    else:
        # D's two click regions remain part of the flowing shell. Narrow,
        # physically cut center and rear grooves articulate both buttons
        # without the detached shelf silhouette of separate projecting caps.
        z1 = h * 0.76
        center_seam = so.tube(
            "button-center-cut",
            [
                (0, fy + 0.005, z_front + 0.003),
                (0, -d * 0.34, h * 0.60),
                (0, d * 0.08, h * 0.82),
            ],
            0.0010,
            None,
            3,
        )
        lib.cut(body, center_seam)
        # Dark inset floors make the real grooves readable at museum scale.
        so.tube(
            "button-center-inset",
            [
                (0, fy + 0.005, z_front + 0.0025),
                (0, -d * 0.34, h * 0.595),
                (0, d * 0.08, h * 0.815),
            ],
            0.00072,
            inp.mat("black-well"),
            3,
        )
        # The rear groove stays geometry-only; a dark insert there reads as
        # two isolated pinholes at museum distance.
    wheel_y = -d * 0.25
    wheel_z = z_front + (wheel_y - fy) / (y1 - fy) * (z1 - z_front) + 0.002
    _wheel_slot(body, wheel_y, wheel_z, 0.020, 0.0085, 0.0070 if not dark else 0.0055)
    if not dark:
        # D's coordinated silver side accents are proud molded inserts.
        for x in (-w * 0.445, w * 0.445):
            accent = lib.box(
                "silver-side-accent",
                (0.0065, d * 0.58, 0.0065),
                (x * 0.90, 0, 0.013),
                inp.mat("mouse-silver"),
            )
            lib.bevel(accent, 0.0018, 3)
    so.shade_smooth(body, 50)
    cable(body, fy + 0.001, 0.0070)
    cable_mat = inp.mat("mouse-black-key" if dark else "mouse-pale")
    for obj in list(lib.bpy.context.scene.objects):
        if obj.name.startswith(("boot-rib", "cable", "conn", "connector")):
            obj.data.materials.clear()
            obj.data.materials.append(cable_mat)
    inp.optical_sensor(0.006, inp.mat("sensor-red"))


def _touch_mouse(p):
    """F: generic continuous touch shell over a very low side rail."""
    w, d, h = p["w"], p["d"], p["h"]
    rail = so.shell(
        "wireless-side-rail",
        [
            (0.0, w * 0.94, d * 0.94, 0.0, 2.8),
            (0.0048, w, d, 0.0, 2.8),
            (0.0062, w * 0.97, d * 0.98, 0.0, 2.8),
        ],
        inp.mat("graphite"),
        44,
        0.08,
    )
    top = so.shell(
        "continuous-touch-top",
        [
            (0.0048, w * 0.96, d * 0.97, 0.0, 2.7),
            (0.0080, w, d * 0.99, 0.0, 2.7),
            (0.0150, w * 0.94, d * 0.95, 0.001, 2.5),
            (h, w * 0.74, d * 0.86, 0.002, 2.3),
        ],
        inp.mat("mouse-pale"),
        48,
        0.11,
    )
    so.shade_smooth(rail, 48)
    so.shade_smooth(top, 48)
    # Wireless underside: twin glide rails, power slider, sensor window.
    for x in (-w * 0.34, w * 0.34):
        glide = lib.box("glide-rail", (0.0045, d * 0.70, 0.0012), (x, 0, 0.0006), inp.mat("black-well"))
        lib.bevel(glide, 0.0010, 2)
    lib.box("wireless-power", (0.010, 0.004, 0.0015), (0, d * 0.25, 0.0008), inp.mat("black-well"))
    inp.optical_sensor(0.006, inp.mat("sensor-red"))


def _workstation_cable(exit_y, exit_z):
    for i, radius in enumerate((0.0060, 0.0052, 0.0045, 0.0038)):
        lib.cylinder(
            "work-boot-rib",
            radius,
            0.0045,
            "Y",
            (0, exit_y - i * 0.0043, exit_z),
            inp.mat("work-dark"),
            20,
        )
    so.tube(
        "workstation-cable",
        [
            (0, exit_y - 0.014, exit_z),
            (0, exit_y - 0.030, 0.004),
            (-0.024, exit_y - 0.060, 0.0028),
            (-0.072, exit_y - 0.070, 0.0028),
            (-0.105, exit_y - 0.052, 0.0028),
        ],
        0.0027,
        inp.mat("work-dark"),
        8,
    )


def _workstation_mouse(p):
    """G: straight-sided three-button puck with shallow rear taper."""
    w, d, h = p["w"], p["d"], p["h"]
    body = lib.loft(
        "workstation-body",
        "Y",
        [
            (-d / 2, w * 0.93, h * 0.54, h * 0.27),
            (-d * 0.30, w, h * 0.72, h * 0.36),
            (d * 0.24, w * 0.98, h, h / 2),
            (d / 2, w * 0.82, h * 0.64, h * 0.32),
        ],
        (0, 0, 0),
        inp.mat("mouse-cream"),
    )
    fy = -d / 2
    slope_cut(body, w, d * 0.20, h * 0.93, fy - 0.001, h * 0.42)
    deck_caps(
        body,
        w - 0.012,
        fy,
        fy,
        h * 0.42,
        d * 0.18,
        h * 0.90,
        3,
        0.0042,
        "abs-light",
        0.96,
        0.006,
        -0.001,
    )
    for obj in list(lib.bpy.context.scene.objects):
        if obj.name.startswith("button"):
            obj.data.materials.clear()
            obj.data.materials.append(inp.mat("mouse-cream-key"))
    lib.bevel(body, 0.0032, 2)
    _workstation_cable(fy, 0.018)
    lib.cylinder("ball-retainer", 0.017, 0.0020, "Z", (0, 0.005, 0.0010), inp.mat("work-dark"), 28)
    so.ellipsoid("workstation-ball", (0.010, 0.010, 0.010), (0, 0.005, 0.0095), inp.mat("mouse-rail"))


def build(p):
    if p["style"] == "boxy":
        boxy_mouse(p)
    elif p["style"] == "curved":
        curved_mouse(p)
    elif p["style"] == "square":
        one_button_mouse(p)
    elif p["style"] == "silver-optical":
        _optical_body(p)
    elif p["style"] == "black-optical":
        _optical_body(p, dark=True)
    elif p["style"] == "touch":
        _touch_mouse(p)
    else:
        _workstation_mouse(p)
    if p["style"] in {"boxy", "curved", "square"}:
        # Underside ball ring — only glimpsed at the plinth edge, still real.
        lib.cylinder("ball-retainer", 0.0185, 0.0026, "Z", (0, 0.004, 0.0013), lib.shared("recess"), 32)
        so.ellipsoid("ball", (0.0105, 0.0105, 0.0105), (0, 0.004, 0.0104), lib.shared("abs-grey"))
    lib.bpy.context.view_layer.update()


def main():
    variant, out = lib.parse_args("A", "/tmp/param-mouse.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    # `--textured`: 512px baked atlas (mice budget), else flat massing GLB
    so.maybe_bake_export(out, size=512, **TEXTURE_PARAMS.get(variant, dict(roughness=0.55)))


if __name__ == "__main__" and lib.bpy is not None:
    main()
