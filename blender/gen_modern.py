"""Parametric modern/industrial cases — four machines in one generator.

Run headless:
  blender -b --python blender/gen_modern.py -- --variant A --out /path/modern-a.glb

Variants (MODEL-ROADMAP.md gaps, orders 30 / 32 / 24):
- A: 2021-class dark mid-tower for the win11 showcase — mesh/airflow front,
  glossy side-panel hint, top IO. Stands on the FLOOR beside a desk.
- B: logo-free compact ARM mini desktop slab for the macos showcase.
  Deliberately NOT Apple trade dress: non-square 180x130 footprint, front
  IO row, matte dark plastic top inset, rear vent band, chamfer-free radius.
- C: small fanless industrial/embedded box for the qnx tile — finned
  heatsink top, mounting ears, DB9 serial plates, status LEDs.
- D: 2018 windowed hobby build with one visible rear fan, CPU cooler,
  full-length PSU shroud, and tidy cabling.

Real-world dimensional ground truth (do not invent proportions):
- Modern airflow mid-towers: Corsair 4000D Airflow 453H x 230W x 466D mm
  https://www.corsair.com/us/en/p/pc-cases/cc-9011200-ww/4000d-airflow-tempered-glass-mid-tower-atx-case-black-cc-9011200-ww
  Fractal Meshify 2 Compact 475H x 210W x 424D mm
  https://www.fractal-design.com/app/uploads/2021/02/Meshify-2-Compact_Product-Sheet_EN.pdf
  Front-mesh look reference: Wikimedia Commons "Corsair 4000D Airflow
  mid-tower ATX case.tif" (diamond-perforated steel front, framed border,
  notched front feet).
- Mini PC slabs: Intel NUC8 117 x 112 x 51 mm (Commons photos
  "Intel NUC 2820FYKH - Front/Back.jpg": alu wrap, side slot vents, rear
  vent band); Apple Mac mini 197 x 197 x 35.8 mm is the trade-dress
  EXCLUSION ZONE (square plan, featureless front) — variant B uses a
  180 x 130 x 42 mm non-square plan with visible front IO instead.
- Industrial fanless boxes: Advantech UNO-2484G 200 x 140 x 40/70 mm
  https://www.advantech.com/en-us/products/1-2mlj9a/uno-2484g/mod_19fb1f0d-aadb-4d9d-b882-a6cc16f1129e
  Siemens SIMATIC IPC227E 191 x 100 x 60 mm; fin/IO language from Commons
  "ADLINK MXE-5501.jpg" + "Siemens SIMATIC IPC.jpg" (full-width fin field,
  DB9 pairs, phoenix terminal block, DIN ears). DE-9 connector: 30.8 mm
  flange, 16.3/12.5 mm trapezoid shell (DIN 41652 / MIL-DTL-24308).
- Windowed hobby tower: NZXT H500-class 210 W x 460 H x 428 D mm.
  https://gamersnexus.net/hwreviews/3309-nzxt-h500-case-review-thermals-noise-vs-s340
  The cable treatment and flat-front silhouette are generic and logo-free.
"""

import sys
from math import radians
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)
import lib_case_matrix as matrix_case  # noqa: E402
import lib_modern as lm  # noqa: E402

# ---------------------------------------------------------------- variant A
TOWER = dict(w=0.220, h=0.460, d=0.450, frame=0.012, border=0.0125)


def tower_top_io(body, w, h, d, y_f):
    """Top-front IO tray: recessed floor, flush power button, port wells."""
    ty = y_f + 0.030
    lib.cut(body, lib.multi_box("io-cut", [((0.096, 0.022, 0.008), (0.0, ty, h))]))
    lib.box("io-floor", (0.095, 0.021, 0.0016), (0.0, ty, h - 0.0032), lm.modern("cavity"))
    lib.cylinder("io-power", 0.0065, 0.0036, "Z", (-0.036, ty, h - 0.0022), lm.modern("charcoal-deep"), 24)
    lib.cylinder("io-power-ring", 0.0022, 0.0040, "Z", (-0.036, ty, h - 0.0018), lm.modern("led-blue"), 16)
    for i, px in enumerate((-0.012, 0.008)):
        lib.box(f"io-usb{i}", (0.0132, 0.0060, 0.0022), (px, ty, h - 0.0030), lm.modern("port-dark"))
    lib.cylinder("io-audio", 0.0030, 0.0022, "Z", (0.030, ty, h - 0.0030), lm.modern("port-dark"), 16)


def tower_top_vent(body, h, y_f):
    """Recessed top exhaust: dark tray + real cross bars, flush with the top."""
    y0, y1 = y_f + 0.075, y_f + 0.315
    yc = (y0 + y1) / 2
    lib.cut(body, lib.multi_box("tvent-cut", [((0.154, y1 - y0, 0.007), (0.0, yc, h))]))
    lib.box("tvent-floor", (0.153, y1 - y0 - 0.001, 0.0016), (0.0, yc, h - 0.0028), lm.modern("cavity"))
    bars = []
    n = 9
    for i in range(n):
        by = y0 + (y1 - y0) * (i + 0.5) / n
        bars.append(((0.148, 0.0056, 0.0050), (0.0, by, h - 0.0028)))
    lib.multi_box("tvent-bars", bars, lm.modern("charcoal"))


def tower_fascia_io(fascia, h, y_f):
    """Unbranded power + port cues on the upper front (rounds 2+3)."""
    zc = h - 0.012
    lm.round_well(fascia, "fio-pw", 0.0068, 0.0040, y_f, 0.050, zc, 32)
    lib.cylinder("fio-btn", 0.0056, 0.0046, "Y", (0.050, y_f + 0.0004, zc), lm.modern("charcoal"), 32)
    lib.cylinder("fio-dot", 0.0016, 0.0052, "Y", (0.050, y_f + 0.0002, zc), lm.modern("led-blue"), 12)
    for i, px in enumerate((0.072, 0.091)):
        lib.well(fascia, f"fio-usb{i}", 0.0110, 0.0042, y_f, px, zc, 0.005, mat=lm.modern("port-dark"))


def tower_fans(w_in, y_back, zc_list):
    """Recessed intake-fan silhouettes: real rings + hubs in the cavity."""
    del w_in  # ring size is class-standard 120 mm regardless of window width
    for i, zc in enumerate(zc_list):
        ring = lib.cylinder(f"fan-ring{i}", 0.060, 0.0012, "Y", (0.0, y_back, zc), lm.modern("fan-dark"), 40)
        lib.cut(ring, lib.cylinder(f"fan-ring-cut{i}", 0.054, 0.02, "Y", (0.0, y_back, zc), None, 40))
        lib.cylinder(f"fan-hub{i}", 0.017, 0.0012, "Y", (0.0, y_back, zc), lm.modern("fan-dark"), 24)
        for sa, sb in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            lib.box(
                f"fan-spoke{i}{sa}{sb}",
                (0.006 + abs(sa) * 0.030, 0.0012, 0.006 + abs(sb) * 0.030),
                (sa * 0.033, y_back, zc + sb * 0.033),
                lm.modern("fan-dark"),
            )


def tower_side_seam(body, w, h, d, y_f, fr):
    """Removable-panel cues on the visible +X side: seam groove + rear lip."""
    lib.cut(body, lib.multi_box("seam-cut", [((0.003, 0.0014, h - 0.052), (w / 2, y_f + fr + 0.0045, h / 2 + 0.004))]))
    lib.box(
        "side-lip",
        (0.0022, 0.014, h - 0.070),
        (w / 2 + 0.0004, d / 2 - 0.009, h / 2 + 0.004),
        lm.modern("charcoal-deep"),
    )


def tower_side_glass(body, w, h, d, y_f):
    """Side-panel glass hint: glossy solid panel set 2 mm INTO the -X wall."""
    y0, y1 = y_f + 0.018, y_f + 0.360
    z0, z1 = 0.054, 0.420
    yc, zc = (y0 + y1) / 2, (z0 + z1) / 2
    lib.cut(body, lib.multi_box("glass-cut", [((0.008, y1 - y0, z1 - z0), (-w / 2, yc, zc))]))
    lib.box("glass-back", (0.0016, y1 - y0 - 0.001, z1 - z0 - 0.001), (-w / 2 + 0.0035, yc, zc), lm.modern("cavity"))
    lib.box(
        "glass-panel",
        (0.0022, y1 - y0 - 0.006, z1 - z0 - 0.006),
        (-w / 2 + 0.0018, yc, zc),
        lm.modern("gloss-panel"),
    )


def build_tower(p):
    w, h, d, fr = p["w"], p["h"], p["d"], p["frame"]
    y_f = -d / 2
    # slim tapered feet + a recessed neck so a shadow line separates them
    # from the shell (round-3 asks 4+5)
    for i, (sx, sy) in enumerate(((-1, 0.030), (1, 0.030), (-1, d - 0.030), (1, d - 0.030))):
        fx = sx * (w / 2 - 0.022)
        lm.trapezoid_prism(
            f"foot{i}", 0.030, 0.024, 0.009, 0.048, (fx, y_f + sy - 0.024, 0.0045), lm.modern("charcoal-deep")
        )
        lib.box(f"foot-neck{i}", (0.022, 0.040, 0.004), (fx, y_f + sy, 0.011), lm.modern("cavity"))
    body = lib.box(
        "body", (w, d - fr, h - 0.012), (0.0, y_f + fr + (d - fr) / 2, 0.012 + (h - 0.012) / 2), lm.modern("charcoal")
    )
    fascia = lib.box(
        "fascia", (w, fr, h - 0.012), (0.0, y_f + fr / 2, 0.012 + (h - 0.012) / 2), lm.modern("charcoal-deep")
    )

    # mesh window: through-cut, dark lined cavity, diamond lattice inside,
    # finer second mesh layer behind it (round-2 judge asks 1+3)
    bw = p["border"]
    w_in, z0, z1 = w - 2 * bw, 0.030, h - 0.024
    h_in, zc = z1 - z0, (z0 + z1) / 2
    lib.cut(fascia, lib.multi_box("mesh-cut", [((w_in, 0.06, h_in), (0.0, y_f + 0.01, zc))]))
    lib.pocket(
        "mesh-liner",
        w_in - 0.0006,
        h_in - 0.0006,
        fr - 0.002,
        (0.0, y_f + 0.0003, zc),
        0.0014,
        lm.modern("cavity"),
        back=False,
    )
    # rigid perforated read: chunkier diamond lattice over a near-black fine
    # dust mesh, with recessed fan silhouettes deep in the cavity (round 3);
    # depth stack (from fascia front): lattice 3.5-6.5, grid 7.5-8.5,
    # fans 9.0-10.2, back plate 10.4-11.6 mm — nothing interpenetrates
    lm.lattice_panel(
        "mesh", w_in - 0.001, h_in - 0.001, (0.0, y_f + 0.005, zc), 0.0100, 0.0024, 0.003, lm.modern("mesh-face")
    )
    lm.grid_panel(
        "mesh-fine", w_in - 0.002, h_in - 0.002, (0.0, y_f + 0.0080, zc), 0.0050, 0.0011, 0.0010, lm.modern("mesh-fine")
    )
    tower_fans(w_in, y_f + 0.0096, (0.115, 0.245))
    lib.box("mesh-back", (w_in - 0.002, 0.0012, h_in - 0.002), (0.0, y_f + 0.0110, zc), lm.modern("cavity"))

    tower_top_io(body, w, h, d, y_f)
    tower_top_vent(body, h, y_f)
    tower_fascia_io(fascia, h, y_f)
    tower_side_seam(body, w, h, d, y_f, fr)
    tower_side_glass(body, w, h, d, y_f)
    lib.bevel(fascia, width=0.0018, segments=2)
    lib.bevel(body, width=0.0016, segments=1)


# ---------------------------------------------------------------- variant B
MINI = dict(w=0.180, d=0.130, h=0.042, r=0.012)


def port_bezel(name, w, h, y_face, x, z, rim=0.0008, mat=None):
    """Proud metal-edge frame around a port opening (single mesh, 4 strips)."""
    items = [
        ((w + 2 * rim, 0.0010, rim), (x, y_face, z + h / 2 + rim / 2)),
        ((w + 2 * rim, 0.0010, rim), (x, y_face, z - h / 2 - rim / 2)),
        ((rim, 0.0010, h), (x - w / 2 - rim / 2, y_face, z)),
        ((rim, 0.0010, h), (x + w / 2 + rim / 2, y_face, z)),
    ]
    return lib.multi_box(name, items, mat)


def mini_front(body, p, y_f):
    """Front IO row on the flat span between the corner radii."""
    zc = p["h"] * 0.52
    # 10 mm recessed round power button, high segment count (round-3 ask 3)
    lm.round_well(body, "pwr", 0.0056, 0.0032, y_f, -0.058, zc, 48)
    lib.cylinder("pwr-btn", 0.0046, 0.0040, "Y", (-0.058, y_f + 0.0004, zc), lm.modern("alu-dark"), 48)
    lib.box("pwr-led", (0.0020, 0.0044, 0.0020), (-0.044, y_f + 0.0012, zc), lm.modern("led-blue-dim"))
    # USB tunnels with proud steel edge bezels + offset tongue (round-3 ask 2)
    lib.well(body, "usbc", 0.0105, 0.0042, y_f, 0.026, zc, 0.006, mat=lm.modern("port-dark"))
    port_bezel("usbc-bezel", 0.0105, 0.0042, y_f - 0.0004, 0.026, zc, 0.0008, lm.modern("steel"))
    lib.well(body, "usba", 0.0145, 0.0075, y_f, 0.050, zc, 0.0075, mat=lm.modern("port-dark"))
    port_bezel("usba-bezel", 0.0145, 0.0075, y_f - 0.0004, 0.050, zc, 0.0008, lm.modern("steel"))
    lib.box("usba-tongue", (0.0118, 0.0018, 0.0015), (0.050, y_f + 0.0042, zc + 0.0020), lm.modern("steel"))
    # second small cue: 3.5 mm headphone jack (round-3 ask 5)
    lm.round_well(body, "jack", 0.0030, 0.0040, y_f, 0.068, zc, 20, mat=lm.modern("port-dark"))


def mini_side_vents(body, p):
    """Five deep slot vents low on both flanks — the NUC-class computer cue."""
    w, zc = p["w"], 0.013
    for sx in (-1, 1):
        xw = sx * w / 2
        lib.cut(body, lib.multi_box(f"svent-cut{sx}", [((0.007, 0.046, 0.012), (xw, 0.024, zc))]))
        lib.box(f"svent-floor{sx}", (0.0016, 0.0452, 0.0112), (xw - sx * 0.0028, 0.024, zc), lm.modern("cavity"))
        bars = []
        for i in range(5):
            by = 0.024 - 0.023 + 0.046 * (i + 0.5) / 5
            bars.append(((0.0020, 0.0030, 0.0104), (xw - sx * 0.0012, by, zc)))
        lib.multi_box(f"svent-bars{sx}", bars, lm.modern("alu-dark"))


def mini_rear_vent(body, p):
    """Full-width rear exhaust band: recessed dark slot + real vertical bars."""
    y_r = p["d"] / 2
    w_v, h_v, zc = p["w"] - 2 * p["r"] - 0.008, 0.0130, p["h"] * 0.52
    lib.cut(body, lib.multi_box("rvent-cut", [((w_v, 0.008, h_v), (0.0, y_r, zc))]))
    lib.box("rvent-floor", (w_v - 0.001, 0.0016, h_v - 0.001), (0.0, y_r - 0.0032, zc), lm.modern("cavity"))
    n, bars = 30, []
    for i in range(n):
        bx = -w_v / 2 + w_v * (i + 0.5) / n
        bars.append(((w_v / n * 0.40, 0.0026, h_v - 0.0020), (bx, y_r - 0.0014, zc)))
    lib.multi_box("rvent-bars", bars, lm.modern("alu-dark"))


def build_mini(p):
    w, d, h, r = p["w"], p["d"], p["h"], p["r"]
    y_f = -d / 2
    # tight 2 mm ground gap over an inset dark base (round-2 ask 3)
    lm.rounded_slab("base", w - 0.009, d - 0.009, 0.0022, r - 0.0025, (0.0, 0.0, 0.0), lm.modern("rubber"))
    body = lm.rounded_slab("body", w, d, h - 0.0020, r, (0.0, 0.0, 0.0020), lm.modern("alu"))
    # matte plastic top: uniform 2.5 mm reveal, real 1 mm step (round-2 asks 4+5)
    top_cut = lm.rounded_slab("top-cut", w - 0.005, d - 0.005, 0.020, r - 0.0015, (0.0, 0.0, h - 0.0018))
    lib.cut(body, top_cut)
    lm.rounded_slab(
        "top-panel", w - 0.0056, d - 0.0056, 0.0016, r - 0.0018, (0.0, 0.0, h - 0.0026), lm.modern("plastic-top")
    )
    mini_front(body, p, y_f)
    mini_side_vents(body, p)
    mini_rear_vent(body, p)
    lib.bevel(body, width=0.0012, segments=2)


# ---------------------------------------------------------------- variant C
INDUS = dict(w=0.220, d=0.150, h_body=0.052, fin_h=0.0155, fins=16)
WINDOWED = dict(w=0.210, h=0.460, d=0.428)


def indus_dsub(x, y_f, zc):
    """DE-9 serial: flange, trapezoid shell, DARK pin recess with real pins."""
    lib.box(f"db9-flange{x}", (0.0310, 0.0016, 0.0128), (x, y_f - 0.0008, zc), lm.modern("steel"))
    shell = lm.trapezoid_prism(
        f"db9-shell{x}", 0.0170, 0.0120, 0.0090, 0.0045, (x, y_f - 0.0061, zc), lm.modern("steel")
    )
    lm.trapezoid_prism(f"db9-face{x}", 0.0140, 0.0096, 0.0062, 0.0020, (x, y_f - 0.0041, zc), lm.modern("port-dark"))
    # 5+4 sparse bright pin field inside the dark face (round-3 ask 1)
    for row, (n_p, dz) in enumerate(((5, 0.0013), (4, -0.0013))):
        for j in range(n_p):
            px = x - 0.0040 * (n_p - 1) / 2 + 0.0040 * j
            lib.cylinder(f"db9-pin{x}{row}{j}", 0.0007, 0.0016, "Y", (px, y_f - 0.0044, zc + dz), lm.modern("steel"), 6)
    for sx in (-1, 1):
        lib.cylinder(
            f"db9-post{x}{sx}", 0.0030, 0.0050, "Y", (x + sx * 0.0130, y_f - 0.0026, zc), lm.modern("steel"), 12
        )
    return shell


def indus_front(body, p, y_f, zc):
    """Recessed IO zone: terminal block, DB9 pair, RJ45, USB, LEDs, button."""
    lib.well(body, "io", 0.196, 0.036, y_f, 0.0, zc, 0.0075, mat=lm.modern("powder-dark"))
    fy = y_f + 0.0020  # recessed mounting plane of the IO zone
    # 3-pin phoenix terminal block (left)
    lib.box("term", (0.0245, 0.0085, 0.0125), (-0.081, fy - 0.0028, zc), lm.modern("term-green"))
    for i in range(3):
        tx = -0.081 - 0.0068 + i * 0.0068
        lib.box(f"term-scr{i}", (0.0030, 0.0020, 0.0030), (tx, fy - 0.0075, zc + 0.0026), lm.modern("port-dark"))
    indus_dsub(-0.040, fy, zc)
    indus_dsub(0.002, fy, zc)
    # LAN pair + stacked USB block: unmistakable computer IO (round-3 asks 2+5)
    for k, rx in enumerate((0.030, 0.049)):
        lib.well(body, f"rj45{k}", 0.0150, 0.0125, y_f, rx, zc, 0.009, mat=lm.modern("port-dark"))
        port_bezel(f"rj45-bezel{k}", 0.0150, 0.0125, y_f - 0.0005, rx, zc, 0.0009, lm.modern("steel"))
        lib.box(f"rj45-tongue{k}", (0.0082, 0.0018, 0.0026), (rx, y_f + 0.0058, zc - 0.0036), lm.modern("steel"))
    lib.well(body, "usb2", 0.0148, 0.0148, y_f, 0.068, zc, 0.0075, mat=lm.modern("port-dark"))
    port_bezel("usb2-bezel", 0.0148, 0.0148, y_f - 0.0005, 0.068, zc, 0.0009, lm.modern("steel"))
    for k, tz in enumerate((0.0040, -0.0034)):
        lib.box(f"usb2-tongue{k}", (0.0118, 0.0018, 0.0015), (0.068, y_f + 0.0048, zc + tz), lm.modern("steel"))
    for i, (lx, mat) in enumerate(((0.080, "led-green"), (0.0852, "led-green"), (0.0904, "led-amber"))):
        lib.box(f"led{i}", (0.0024, 0.0030, 0.0024), (lx, fy - 0.0008, zc + 0.0060), lm.modern(mat))
    lib.cylinder("pwr", 0.0028, 0.0032, "Y", (0.0885, fy - 0.0008, zc - 0.0060), lm.modern("led-blue-dim"), 20)


def indus_ears(p):
    """Wall-mount flanges: thick, run under the chassis edge, real screw holes."""
    w = p["w"]
    for sx in (-1, 1):
        ear = lib.box(f"ear{sx}", (0.040, 0.116, 0.006), (sx * (w / 2 + 0.012), 0.0, 0.003))
        holes = []
        for sy in (-1, 1):
            holes.append(lib.cylinder(f"eh{sx}{sy}", 0.0052, 0.03, "Z", (sx * (w / 2 + 0.023), sy * 0.044, 0.003)))
        for hole in holes:
            lib.cut(ear, hole)
        ear.data.materials.append(lm.modern("powder"))
        lib.bevel(ear, width=0.0010, segments=1)


def build_indus(p):
    w, d, hb = p["w"], p["d"], p["h_body"]
    y_f = -d / 2
    body = lib.box("body", (w, d, hb), (0.0, 0.0, hb / 2), lm.modern("powder"))
    # heatsink fin field: real 15.5 mm grooves over nearly the full depth,
    # chamfered front ends (round-2 judge ask 3)
    n, fh = p["fins"], p["fin_h"]
    pitch = (w - 0.008) / n
    fins = []
    for i in range(n):
        fx = -(w - 0.008) / 2 + pitch * (i + 0.5)
        fins.append(((pitch * 0.30, d - 0.006, fh), (fx, 0.0, hb + fh / 2)))
    fin_obj = lib.multi_box("fins", fins, lm.modern("powder"))
    chamf = lib.box("fin-chamf", (w + 0.02, 0.055, 0.055), (0.0, y_f + 0.004, hb + fh + 0.012))
    chamf.rotation_euler = (radians(-38.0), 0.0, 0.0)
    lib.cut(fin_obj, chamf)
    indus_front(body, p, y_f, zc=0.024)
    indus_ears(p)
    # warning-label-sized generic spec sticker on the +X flank; microtext is
    # unreadable by construction (labels-badges sheet crop, or plain stock)
    lib.box(
        "label", (0.0008, 0.030, 0.016), (w / 2 + 0.0004, -0.030, 0.032), lm.label_material(lm.texlib("labels-badges"))
    )
    lib.box(
        "label-warn",
        (0.0004, 0.0060, 0.0060),
        (w / 2 + 0.0012, -0.0405, 0.0335),
        lib.material("modern-warn", "#a8862f", 0.6),
    )
    lib.bevel(body, width=0.0014, segments=1)


# ------------------------------------------------------------------- main
BUILDERS = {
    "A": (build_tower, TOWER),
    "B": (build_mini, MINI),
    "C": (build_indus, INDUS),
    "D": (matrix_case.build_modern_windowed, WINDOWED),
}

# Albedo grain per shared-library slug (~/scene-v2-reference/textures/, see
# its INDEX.md): {material: (slug, blend, factor, tile-meters)}. Slugs used:
# A abs-charcoal + vent-grille, B alu-brushed (+abs-charcoal lid),
# C metal-powdercoat + labels-badges (sticker). Procedural fallback applies
# when a slug is missing, keeping the script self-contained.
TEXTURE_RULES = {
    "A": {
        "charcoal": ("abs-charcoal", "OVERLAY", 0.35, 0.09, 0.09),  # painted steel: subtle color, sheen varies
        "charcoal-deep": ("abs-charcoal", "OVERLAY", 0.65, 0.07, 0.0),  # molded ABS: stronger grain
        "mesh-face": ("abs-charcoal", "OVERLAY", 0.40, 0.05, 0.0),
        "cavity": ("vent-grille", "MULTIPLY", 0.35, 0.024, 0.0),
    },
    "B": {
        "alu": ("alu-brushed", "OVERLAY", 0.50, 0.07, 0.06),
        "alu-dark": ("alu-brushed", "OVERLAY", 0.40, 0.06, 0.0),
        "plastic-top": ("abs-charcoal", "OVERLAY", 0.50, 0.08, 0.0),
    },
    "C": {
        "powder": ("metal-powdercoat", "SOFT_LIGHT", 0.70, 0.05, 0.07),
        "powder-dark": ("metal-powdercoat", "SOFT_LIGHT", 0.45, 0.05, 0.0),
    },
    "D": {
        "charcoal": ("metal-powdercoat", "SOFT_LIGHT", 0.55, 0.07, 0.05),
        "charcoal-deep": ("abs-charcoal", "OVERLAY", 0.55, 0.06, 0.0),
        "fan-dark": ("abs-charcoal", "OVERLAY", 0.45, 0.05, 0.0),
        "cavity": ("vent-grille", "MULTIPLY", 0.30, 0.025, 0.0),
    },
}


def main():
    variant, out = lib.parse_args("A", "/tmp/param-modern.glb")
    lib.reset_scene()
    builder, params = BUILDERS[variant]
    builder(params)
    if "--textured" in sys.argv:
        prefix = out[:-4] if out.endswith(".glb") else out
        lm.bake_textures(TEXTURE_RULES[variant], prefix, ao_strength=0.52 if variant == "D" else 0.68)
    lib.export_glb(out)


if __name__ == "__main__" and lib.bpy is not None:
    main()
