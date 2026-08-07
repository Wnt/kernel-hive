"""Parametric serial-terminal family (variants A/B/C, iteration 4).

Run headless:
  blender -b --python blender/gen_terminal.py -- --variant A --out /tmp/terminal-a.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

Real-world dimensional ground truth:
- VT100 monitor/system unit: 457.2 W x 362.0 H x 368.3 D mm; keyboard:
  457.2 W x 88.9 H x 203.2 D mm.
  DEC VT100 Series Technical Manual, chapter 1:
  https://vt100.net/docs/vt100-tm/chapter1.html
- VT220 terminal: 333 W x 283 H x 387 D mm; keyboard:
  533 W x 51 H x 171 D mm; terminal tilt range +5 to -15 degrees.
  DEC VT220 Technical Manual, Appendix A:
  https://bitsavers.org/pdf/dec/terminal/vt220/EK-VT220-TM-001_VT220_Technical_Manual_Nov84.pdf
- C is an ADM-3A-class one-piece clamshell within a 360 W x 400 D x 320 H mm
  envelope (generic; no Lear Siegler trade dress). Its screen stays dark
  green glass with no emission for the archive shelf.

No logos anywhere. All bezels, wells and vents are cut geometry.

Iteration 4 is the frozen best state after four design-review rounds
(judgments archived in ~/scene-v2-reference/review/design-judgments/
terminal-*/round[1-4].judgment.md):
- A: broad deep shell (taper only at the back) on a grey pedestal with a tall
  undercut-chin band, screen assembly offset LEFT behind a thick dark
  rounded bezel with deeply recessed glass, badge on the right band, rear-top
  vents, fully detached wedge keyboard with black key field + numpad.
- B: rounded shell that swells mid-depth then tapers, slightly tilted back on
  a mostly hidden swivel base, huge-radius screen opening with blue-grey
  glass, brow vents, badge plate + indicator, thick sectioned two-tone
  detached keyboard.
- C: one continuous sail-profile clamshell over a thin darker underside,
  wide rounded-square green-glass window high in the raked face, integrated
  chunky black key apron with long spacebar, seated brightness knob.
Round-4 residuals (noted, not resolved — the round cap was reached): the
judge still asks for more molded curvature on all three shells, a more
sculpted VT100 bezel cavity, and an even longer ADM-class apron.
"""

import sys
from math import cos, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402
import lib_bake  # noqa: E402
import lib_classicdesks as cd  # noqa: E402

PARAMS = {
    "A": dict(style="big", w=0.4572, d=0.3683, h=0.3620, view_w=0.292, view_h=0.219),
    "B": dict(style="compact", w=0.3330, d=0.3870, h=0.2830, view_w=0.232, view_h=0.174),
    "C": dict(style="archive", w=0.3600, d=0.4000, h=0.3200, view_w=0.230, view_h=0.180),
}


def glass_stack(p, y_glass, zc, glass_key="glass", x=0.0):
    """Recessed bulged CRT glass + dark cavity floor behind the bezel."""
    vw, vh = p["view_w"], p["view_h"]
    lib.bulged_panel("screen-glass", vw + 0.006, vh + 0.006, 0.006, (x, y_glass, zc), cd.mat(glass_key))
    lib.box("screen-cavity", (vw + 0.030, 0.0016, vh + 0.030), (x, y_glass + 0.006, zc), cd.mat("recess-deep"))


def vt100_monitor(p):
    """Broad tapered VT100-class shell on a pedestal with undercut chin."""
    w, d, h = p["w"], p["d"], p["h"]
    base_h = 0.034
    lib.box("pedestal", (w * 0.70, d * 0.60, base_h), (0, 0.030, base_h / 2), cd.mat("abs-grey"))
    shell_h = h - base_h
    y_f = -d * 0.42
    zc = base_h + shell_h / 2
    fascia_d = 0.055
    fascia = lib.box("fascia", (w, fascia_d, shell_h), (0, y_f + fascia_d / 2, zc), cd.mat("abs"))
    # rear shell: broad and deep for most of its run, tapering only at the back
    shell = lib.loft(
        "rear-shell",
        "Y",
        [
            (fascia_d - 0.004, w - 0.010, shell_h - 0.010, 0.0),
            (d * 0.62, w * 0.94, shell_h * 0.94, 0.008),
            (d - 0.020, w * 0.70, shell_h * 0.68, 0.020),
        ],
        (0, y_f, zc),
        cd.mat("abs-warm"),
    )
    lib.bevel(shell, 0.006, 2)
    # wide fascia -> thick dark rounded bezel -> recessed window -> glass;
    # screen assembly OFFSET LEFT, wide beige service band on the right
    screen_x = -0.026
    screen_z = zc + 0.022
    lib.cut(fascia, cd.rounded_prism("bezel-cut", 0.366, 0.268, 0.056, 0.12, (screen_x, y_f - 0.001, screen_z)))
    cd.bezel_frame("bezel", 0.364, 0.266, 0.055, 0.034, 0.034, (screen_x, y_f + 0.008, screen_z), cd.mat("dark"))
    lib.box("bezel-throat", (0.330, 0.0016, 0.232), (screen_x, y_f + 0.0415, screen_z), cd.mat("dark"))
    glass_stack(p, y_f + 0.040, screen_z, x=screen_x)
    # undercut chin: tall recessed shadow band low on the fascia
    lib.well(fascia, "chin", w * 0.92, 0.019, y_f, 0, base_h + 0.014, 0.008, mat=cd.mat("recess-deep"))
    cd.badge_plate("badge", 0.056, 0.014, y_f, w / 2 - 0.048, base_h + 0.034, plate_mat="badge-label")
    # vent slots on the tapering rear top
    vents = []
    for i in range(9):
        vents.append(((0.0042, d * 0.16, 0.020), ((i - 4) * 0.030, y_f + d * 0.46, base_h + shell_h * 0.955)))
    vent_cap = lib.box(
        "vent-cap", (0.30, d * 0.18, 0.010), (0, y_f + d * 0.46, base_h + shell_h * 0.925), cd.mat("abs-warm")
    )
    lib.cut(vent_cap, lib.multi_box("vent-cuts", vents))
    lib.bevel(fascia, 0.008, 3)
    lib.bevel(vent_cap, 0.0016, 1)


def vt100_keyboard(y_center):
    """Detached VT100-class wedge: black key field + numpad filling the case."""
    w, d, h = 0.4572, 0.2032, 0.0889
    case = lib.wedge_box("kb-case", w, d, h * 0.42, h, (0, y_center, 0), cd.mat("abs"))
    well = lib.box("kb-well", (w - 0.036, d - 0.048, 0.0026), (0, y_center - 0.004, h * 0.635), cd.mat("dark"))
    well.rotation_euler[0] = lib.radians(14.2)  # ride the wedge top slope
    pitch = 0.0185
    rows = [(0, 15, 0.0, False), (1, 15, 0.3, False), (2, 14, 0.6, True), (3, 13, 0.9, False)]

    def z_of(cy):
        along = (cy - (y_center - d / 2)) / d
        return h * 0.52 + along * h * 0.40 + 0.004

    x0 = -w / 2 + 0.038
    y0 = y_center - d / 2 + 0.032
    cd.key_rows("kb-keys", x0, y0, z_of, rows, pitch, "keycap-black")
    cd.key_rows("kb-num", 0.114, y0, z_of, [(r, 4, 0.0, False) for r in range(4)], pitch, "keycap-black")
    lib.box(
        "kb-space",
        (pitch * 5.4, pitch * 0.7, 0.0075),
        (-0.030, y0 + 4 * pitch, z_of(y0 + 4 * pitch)),
        cd.mat("keycap-black"),
    )
    lib.bevel(case, 0.006, 2)


def vt220_terminal(p):
    """Compact rounded VT220-class shell, slightly tilted on a hidden base."""
    w, d, h = p["w"], p["d"], p["h"]
    base_h = 0.030
    before = {o.name for o in lib.bpy.context.scene.objects}
    shell_h = h - base_h
    y_f = -d * 0.46
    zc = base_h + shell_h / 2
    fascia_d = 0.040
    fascia = lib.box("fascia", (w, fascia_d, shell_h), (0, y_f + fascia_d / 2, zc), cd.mat("abs"))
    # deep rear volume: swells slightly mid-depth, then tapers
    lib.loft(
        "rear-shell",
        "Y",
        [
            (fascia_d - 0.004, w - 0.008, shell_h - 0.008, 0.0),
            (d * 0.55, w * 0.985, shell_h * 0.97, 0.004),
            (d - 0.026, w * 0.70, shell_h * 0.66, 0.020),
        ],
        (0, y_f, zc),
        cd.mat("abs-warm"),
    )
    # screen dominates: large-radius opening, thin surround, shallow chin
    screen_z = zc + 0.012
    lib.cut(fascia, cd.rounded_prism("bezel-cut", 0.284, 0.216, 0.060, 0.10, (0, y_f - 0.001, screen_z)))
    cd.bezel_frame("bezel", 0.282, 0.214, 0.059, 0.020, 0.024, (0, y_f + 0.008, screen_z), cd.mat("recess-deep"))
    lib.box("bezel-throat", (0.258, 0.0016, 0.190), (0, y_f + 0.031, screen_z), cd.mat("dark"))
    glass_stack(p, y_f + 0.028, screen_z, glass_key="blue-glass")
    cd.badge_plate("badge", 0.058, 0.014, y_f, -w / 2 + 0.056, base_h + 0.020, plate_mat="badge-label")
    lib.box("indicator", (0.0060, 0.0026, 0.0036), (w / 2 - 0.052, y_f + 0.0006, base_h + 0.020), cd.mat("dark"))
    # brow vents: shallow recessed grooves across the top front
    brows = []
    for i in range(5):
        brows.append(((w * 0.62, 0.0042, 0.0030), (0, y_f + 0.016 + i * 0.0085, base_h + shell_h - 0.0012)))
    lib.cut(fascia, lib.multi_box("brow-cuts", brows))
    lib.bevel(fascia, 0.010, 3)
    # slight backward tilt of the whole shell around the base pivot
    tilt = lib.radians(-4.0)
    cs, sn = cos(tilt), sin(tilt)
    piv_y, piv_z = 0.045, base_h
    for obj in lib.bpy.context.scene.objects:
        if obj.name in before:
            continue
        ry, rz = obj.location[1] - piv_y, obj.location[2] - piv_z
        obj.location[1] = piv_y + ry * cs - rz * sn
        obj.location[2] = piv_z + ry * sn + rz * cs
        obj.rotation_euler[0] += tilt
    # mostly hidden tilt-swivel base with a visible seam under the shell
    lib.box("tilt-base", (0.170, 0.170, base_h + 0.004), (0, 0.055, (base_h + 0.004) / 2), cd.mat("abs-warm"))
    lib.cylinder("tilt-pivot", 0.055, 0.020, "Z", (0, 0.055, base_h + 0.006), cd.mat("abs-grey"), 20)


def adm3a_shell(p):
    """One continuous sail-profile clamshell over a darker tub (ADM-3A class)."""
    w, d, h = p["w"], p["d"], p["h"]
    hd = d / 2
    # darker underside: a thin tub following the shell footprint
    tub = lib.box("tub", (w - 0.010, d - 0.010, 0.040), (0, 0, 0.020), cd.mat("abs-grey"))
    # side silhouette: keyboard apron sweeping up a raked screen face into a
    # forward crest, then a long curved hump falling to the rear
    profile = [
        (-hd, 0.038),
        (hd, 0.038),
        (hd, 0.066),
        (hd - 0.014, 0.148),
        (hd - 0.042, 0.238),
        (hd - 0.072, 0.272),
        (hd - 0.108, 0.296),
        (hd - 0.180, h - 0.003),
        (-hd + 0.128, h),
        (-hd + 0.112, h - 0.012),
        (-0.134, 0.098),
        (-hd + 0.004, 0.078),
        (-hd, 0.058),
    ]
    shell = cd.profile_shell("shell", w, profile, (0, 0, 0), cd.mat("abs"), inset_top=0.006)
    # raked screen face runs (-0.134, 0.098) -> (-0.088, 0.308): ~13 deg rake
    rake = -13.0
    view_w, view_h = 0.235, 0.150
    face_c = (0, -0.1110, 0.210)
    lib.cut(shell, cd.rounded_prism("screen-cut", view_w + 0.036, view_h + 0.036, 0.042, 0.10, face_c, None, 6, rake))
    cd.bezel_frame(
        "screen-bezel",
        view_w + 0.034,
        view_h + 0.034,
        0.041,
        0.016,
        0.020,
        (face_c[0], face_c[1] + 0.010, face_c[2] - 0.0025),
        cd.mat("recess-deep"),
        6,
        rake,
    )
    lib.box(
        "screen-cavity",
        (view_w + 0.020, 0.0016, view_h + 0.020),
        (0, face_c[1] + 0.032, face_c[2] - 0.008),
        cd.mat("dark"),
    )
    glass = lib.bulged_panel(
        "screen-glass",
        view_w + 0.004,
        view_h + 0.004,
        0.005,
        (0, face_c[1] + 0.024, face_c[2] - 0.006),
        cd.mat("green-glass"),
    )
    glass.rotation_euler[0] = lib.radians(rake)

    # integrated key apron riding the sloped deck: dark bed + chunky keys
    def apron_z(cy):
        return 0.078 + 0.323 * (cy + 0.196)  # the gentler apron plane

    bed = lib.box("key-bed", (w - 0.058, 0.060, 0.0026), (0, -0.165, apron_z(-0.165) + 0.001), cd.mat("dark"))
    bed.rotation_euler[0] = lib.radians(18.0)
    pitch = 0.0160

    def z_of(cy):
        return apron_z(cy) + 0.0058

    rows = [(1, 12, 0.0, False), (2, 12, 0.35, False), (3, 11, 0.7, True)]
    x0 = -0.106
    y0 = -0.193
    cd.key_rows("apron-keys", x0, y0, z_of, rows, pitch, "keycap-black")
    lib.box("apron-space", (pitch * 6.0, pitch * 0.72, 0.0075), (0.006, y0, z_of(y0)), cd.mat("keycap-black"))
    # brightness knob seated into the apron near the screen's lower corner
    lib.cylinder("knob", 0.0060, 0.0110, "Y", (w / 2 - 0.050, -0.140, 0.112), cd.mat("dark"), 16)
    lib.bevel(shell, 0.012, 3, 30.0)
    lib.bevel(tub, 0.003, 2)


def build(p):
    if p["style"] == "big":
        vt100_monitor(p)
        vt100_keyboard(-p["d"] * 0.42 - 0.036 - 0.1016)
    elif p["style"] == "compact":
        vt220_terminal(p)
        cd.terminal_keyboard("kb", 0.533, 0.171, 0.045, -p["d"] * 0.46 - 0.030 - 0.0855)
    else:
        adm3a_shell(p)


def main():
    variant, out = lib.parse_args("A", "/tmp/param-terminal.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    lib_bake.maybe_bake_export(out)


if __name__ == "__main__" and lib.bpy is not None:
    main()
