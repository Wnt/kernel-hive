"""Parametric generic classic compact all-in-one (variants A/B).

Run headless:
  blender -b --python blender/gen_compact.py -- --variant A --out /tmp/compact-a.glb
Append --textured for the baked-atlas GLB (see lib_bake.py).

A one-piece late-80s compact: 9-inch CRT above a floppy slit in one cream
shell, carry-handle recess in the top, tilted rear. INSPIRED BY the
Macintosh Classic CLASS but deliberately NOT Apple trade dress — design
review checks each round that it reads "generic classic compact
all-in-one", not "a Macintosh". Differentiation is structural, not just
logo removal:
- wider, squatter stance (296/310 mm faces vs the Classic's narrow 246);
- rectangular HARD-stepped planar bezel tiers with tight corner radii,
  never the Classic's sculpted soft frame flowing into the shell;
- A: floppy module CENTERED in a full-width recessed drive band;
  B: screen OFFSET LEFT with a right utility column (vertical vent
  grooves + connector panel) — neither is the Classic chin composition;
- continuous inset shadow-gap base, no underbite curve, no feet pads;
- NO logo, badge or nameplate anywhere.

Real-world dimensional ground truth (do not invent proportions):
- Class datum (EXCLUSION benchmark, not copied): Apple Macintosh Classic
  335 H x 246 W x 284 D mm, 9-inch CRT:
  https://everymac.com/systems/apple/mac_classic/specs/mac_classic.html
- 9-inch 4:3 CRT viewable is ~180 x 135 mm (9-in class diagonal minus
  bezel overlap): https://lowendmac.com/1999/crt-screen-size-resolution-and-sharpness/
- 3.5-inch floppy aperture ~94 x 6 mm slit + eject button (DD drive
  faceplate class). Photo set (angles + shell language):
  ~/scene-v2-reference/hw-refs/displays/mac-classic/.

SCREEN-GLASS RECTANGLES (for the live-content planes; glTF space: x right,
y up from base, z toward viewer, meters):
- Variant A: center (0.000, 0.194, 0.115), size 0.180 x 0.135.
- Variant B: center (-0.030, 0.202, 0.120), size 0.180 x 0.135.
Screen faces are dark blue-grey glass only — no emission.

Openings are boolean cavities with lined interiors; bezel blanks are
beveled BEFORE boolean openings (the historical CRT lesson — beveling
after scallops the cut faces).

Iteration 4 + texture pass — FINAL, design-reviewed SHIP (archive in
~/scene-v2-reference/review/design-judgments/param-compact-{a,b}/):
rounds 1-3 failed the trade-dress gate ("unbadged Macintosh derivative");
the round-4 restructure (hard rectangular tiers, flush chamfered / inset
bases, B's screen offset left against a full-height service column of
stacked drive bays, transverse round grip bar) plus the quiet-toned
texture pass cleared it — both variants' final verdicts read "generic
classic compact all-in-one, not specifically a Macintosh".
"""

import sys
from math import radians
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_bake  # noqa: E402
import lib_classicdesks as cd  # noqa: E402

PARAMS = {
    "A": dict(style="cream", w=0.296, h=0.296, d=0.290, view_w=0.180, view_h=0.135, scr_z=0.194, scr_x=0.0),
    "B": dict(style="grey", w=0.310, h=0.318, d=0.300, view_w=0.180, view_h=0.135, scr_z=0.202, scr_x=-0.030),
}

GLASS_MAT = ("hc-glass", "#3a4560", 0.16)  # homecrt family glass, softer band


def glass(p, y_glass):
    name, hexc, rough = GLASS_MAT
    m = lib.material(name, hexc, rough)
    vw, vh = p["view_w"], p["view_h"]
    lib.bulged_panel("glass", vw + 0.012, vh + 0.008, 0.016, (p["scr_x"], y_glass, p["scr_z"]), m, segs=36)
    lib.box("glass-back", (vw + 0.010, 0.0016, vh + 0.010), (p["scr_x"], y_glass + 0.009, p["scr_z"]), cd.mat("dark"))


def rounded_cap(name, w, d, h, loc, mat, r=0.005):
    """Fascia blank beveled BEFORE boolean openings."""
    cap = lib.box(name, (w, d, h), loc, mat)
    mod = lib.bevel(cap, width=r, segments=3)
    lib.bpy.context.view_layer.objects.active = cap
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    return cap


def framed_window(name, ow, oh, r_out, r_win, win_w, win_h, depth, loc, mat):
    """Square-ish outer step + rounded inner window (decoupled radii)."""
    outer = cd.rounded_prism(name, ow, oh, r_out, depth, loc, mat)
    hole = cd.rounded_prism(name + "-hole", win_w, win_h, r_win, depth + 0.02, (loc[0], loc[1] - 0.01, loc[2]), None)
    lib.cut(outer, hole)
    return outer


def screen_stack(p, fascia, y_f, step_mat="abs-light"):
    """HARD rectangular stepped tiers -> lined funnel -> deep bulged glass.
    Tight 3-6 mm radii: planar tiers, not a sculpted Macintosh frame."""
    vw, vh, scr_z, scr_x = p["view_w"], p["view_h"], p["scr_z"], p["scr_x"]
    lib.cut(fascia, cd.rounded_prism("scr-cut", vw + 0.040, vh + 0.034, 0.002, 0.05, (scr_x, y_f - 0.001, scr_z)))
    framed_window(
        "scr-step",
        vw + 0.038,
        vh + 0.032,
        0.002,
        0.003,
        vw + 0.018,
        vh + 0.014,
        0.011,
        (scr_x, y_f + 0.004, scr_z),
        cd.mat(step_mat),
    )
    framed_window(
        "scr-funnel",
        vw + 0.022,
        vh + 0.018,
        0.003,
        0.005,
        vw + 0.008,
        vh + 0.002,
        0.014,
        (scr_x, y_f + 0.016, scr_z),
        cd.mat("recess"),
    )
    glass(p, y_f + 0.030)
    lib.box("cavity-back", (vw + 0.044, 0.0016, vh + 0.044), (scr_x, y_f + 0.0405, scr_z), cd.mat("recess-deep"))


def floppy_module(y_f, xc, zc, w_slit=0.104, margin=0.040, plate_mat="abs"):
    """3.5-inch drive module: proud faceplate framing a deep dark mouth,
    separate eject button and activity LED — mechanically credible."""
    fp_w, fp_h, t = w_slit + margin, 0.030, 0.0040
    frame = [
        ((fp_w, t, (fp_h - 0.011) / 2), (xc, y_f - t / 2, zc + 0.00275 + fp_h / 4)),
        ((fp_w, t, (fp_h - 0.011) / 2), (xc, y_f - t / 2, zc - 0.00275 - fp_h / 4)),
        (((fp_w - w_slit) / 2, t, fp_h), (xc - w_slit / 2 - (fp_w - w_slit) / 4, y_f - t / 2, zc)),
        (((fp_w - w_slit) / 2, t, fp_h), (xc + w_slit / 2 + (fp_w - w_slit) / 4, y_f - t / 2, zc)),
    ]
    lib.multi_box("drive-plate", frame, cd.mat(plate_mat))
    lib.box("slit-mouth", (w_slit, 0.0016, 0.011), (xc, y_f - 0.0004, zc), cd.mat("dark"))
    lib.box("eject", (0.016, 0.0060, 0.0110), (xc + w_slit / 2 - 0.014, y_f - 0.0060, zc - 0.019), cd.mat("abs-grey"))
    lib.box(
        "drive-led",
        (0.0048, 0.0048, 0.0048),
        (xc - w_slit / 2 + 0.011, y_f - 0.0045, zc - 0.018),
        lib.material("led-g", "#3fae4a", 0.4),
    )


def base_gap(w, d, y_f, mat_key="abs", flush=True):
    """Base treatment — explicitly NOT a Macintosh underbite: A gets a
    flush chamfered body-colored skirt, B a light plinth fully inside
    the footprint (no dark projecting seam)."""
    if flush:
        skirt = lib.box(
            "base", (w - 0.004, d - 0.040, 0.012), (0, y_f + 0.018 + (d - 0.040) / 2, 0.006), cd.mat(mat_key)
        )
        lib.bevel(skirt, 0.004, 2)
    else:
        lib.box("base", (w - 0.048, d - 0.070, 0.010), (0, y_f + 0.032 + (d - 0.070) / 2, 0.005), cd.mat("recess"))


def shell_with_tilt_and_handle(p, z0, mat_key="abs-warm"):
    """One-piece body behind the fascia: tilted rear top, forward handle
    recess with grip bar, rear vent columns."""
    w, h, d = p["w"], p["h"], p["d"]
    y_f = -d / 2.0
    bh = h - z0
    shell = lib.box(
        "shell", (w - 0.006, d - 0.048, bh), (0, y_f + 0.040 + (d - 0.048) / 2, z0 + bh / 2), cd.mat(mat_key)
    )
    # tilted rear: wedge cut sloping the top down toward the back
    wedge = lib.box("tilt-cut", (w + 0.02, d * 0.9, 0.10), (0, y_f + d * 0.70, h + 0.030))
    wedge.rotation_euler[0] = radians(-10.0)
    lib.cut(shell, wedge)
    # carry-handle recess pulled FORWARD so the museum camera reads it
    lib.cut(shell, lib.multi_box("handle-cut", [((0.130, 0.058, 0.034), (0, y_f + 0.068, h - 0.002))]))
    lib.box("handle-floor", (0.128, 0.056, 0.0016), (0, y_f + 0.068, h - 0.0185), cd.mat("recess-deep"))
    lib.cylinder("grip", 0.0085, 0.128, "X", (0, y_f + 0.062, h - 0.009), cd.mat(mat_key), 20)
    # rear vent columns high on the back face
    cols = [((0.0048, 0.012, 0.052), (-0.084 + i * 0.014, y_f + d - 0.033, z0 + bh * 0.70)) for i in range(13)]
    lib.cut(shell, lib.multi_box("rvents", cols))
    return shell


def build_cream(p):
    """A: cream compact — centered drive band, symmetric vent grooves."""
    w, h, d = p["w"], p["h"], p["d"]
    y_f = -d / 2.0
    z0 = 0.010
    base_gap(w, d, y_f)
    fascia = rounded_cap("fascia", w, 0.038, h - z0, (0, y_f + 0.019, z0 + (h - z0) / 2), cd.mat("abs"))
    screen_stack(p, fascia, y_f)
    # full-width recessed drive band, dark floor, centered floppy module
    lib.well(fascia, "band", 0.248, 0.048, y_f, 0.0, 0.072, 0.009, mat=cd.mat("recess-deep"))
    floppy_module(y_f, 0.0, 0.078)
    # symmetric vent grooves under the band with dark groove floors
    grooves = [((0.248, 0.0060, 0.0048), (0, y_f, 0.026 + i * 0.010)) for i in range(3)]
    lib.cut(fascia, lib.multi_box("grooves", grooves))
    for i in range(3):
        lib.box(
            f"groove-floor{i}", (0.246, 0.0016, 0.0044), (0, y_f + 0.0048, 0.026 + i * 0.010), cd.mat("recess-deep")
        )
    shell = shell_with_tilt_and_handle(p, z0)
    lib.bevel(shell, 0.005, 2)


def build_grey(p):
    """B: bigger warm-grey compact — screen OFFSET LEFT, utility column
    right, speaker field + drive module chin."""
    w, h, d = p["w"], p["h"], p["d"]
    y_f = -d / 2.0
    z0 = 0.010
    base_gap(w, d, y_f, flush=False)
    fascia = rounded_cap("fascia", w, 0.038, h - z0, (0, y_f + 0.019, z0 + (h - z0) / 2), cd.mat("abs"))
    screen_stack(p, fascia, y_f, step_mat="abs-light")
    # RIGHT SERVICE COLUMN: recessed full-height bay with the drives
    # stacked vertically — nothing like a Macintosh chin
    col_x = 0.112
    lib.well(fascia, "bay", 0.062, 0.180, y_f, col_x, 0.170, 0.006, mat=cd.mat("recess"))
    floppy_module(y_f - 0.001, col_x, 0.208, w_slit=0.044, margin=0.014, plate_mat="abs-grey")
    lib.well(fascia, "slot2", 0.044, 0.010, y_f, col_x, 0.150, 0.010, mat=cd.mat("recess-deep"))
    vgr = [((0.0048, 0.0060, 0.042), (col_x - 0.016 + i * 0.008, y_f, 0.108)) for i in range(5)]
    lib.cut(fascia, lib.multi_box("col-grooves", vgr))
    # industrial full-width vent groove bank low on the fascia
    bank = [((0.240, 0.0060, 0.0048), (-0.012, y_f, 0.030 + i * 0.010)) for i in range(3)]
    lib.cut(fascia, lib.multi_box("vent-bank", bank))
    for i in range(3):
        lib.box(
            f"bank-floor{i}", (0.238, 0.0016, 0.0044), (-0.012, y_f + 0.0048, 0.030 + i * 0.010), cd.mat("recess-deep")
        )
    # side grip recesses low on both flanks
    shell = shell_with_tilt_and_handle(p, z0, mat_key="abs-grey")
    for sx in (-1, 1):
        lib.cut(
            shell, lib.multi_box(f"grip{sx}", [((0.022, 0.095, 0.028), (sx * (w - 0.006) / 2, y_f + 0.125, 0.115))])
        )
    lib.bevel(shell, 0.005, 2)


def build(p):
    if p["style"] == "cream":
        build_cream(p)
    else:
        build_grey(p)


# Texture-round knobs (family defaults tuned on gen_homecrt's rounds).
BAKE_KW = {
    "A": dict(
        tone=(1.22, 1.175, 1.05), ao_floor=0.50, grain_mul=0.9, wear_amt=0.05, ao_samples=48, ao_curve=(0.32, 0.94)
    ),
    "B": dict(
        tone=(1.25, 1.21, 1.11), ao_floor=0.44, grain_mul=0.8, wear_amt=0.06, ao_samples=48, ao_curve=(0.36, 0.92)
    ),
}


def main():
    variant, out = lib.parse_args("A", "/tmp/param-compact.glb")
    lib.reset_scene()
    build(PARAMS[variant])
    lib_bake.maybe_bake_export(out, **BAKE_KW[variant])


if __name__ == "__main__" and lib.bpy is not None:
    main()
