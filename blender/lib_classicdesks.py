"""Shared bpy helpers for the classic-desks families (pizzabox + terminal).

Extends lib.py (which stays read-only for other agents) with the machinery the
The design-review iteration rounds demanded: rounded-corner bezel windows, extruded
side profiles for one-piece 70s shells, sectioned two-tone keyboards, dimple
fields, visible feet, and drive/badge furniture built from REAL recessed
geometry (painted-on detail is a standing director rejection).

Import-guarded like lib.py: CI lints without Blender; geometry paths only run
under `blender -b --python gen_*.py`.
"""

import sys
from math import cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402

try:  # only present inside Blender's bundled python
    import bmesh
    from mathutils import Matrix
except ImportError:  # plain python (ruff/CI): definitions only, never run
    bmesh = None
    Matrix = None

# Extra shared materials for the classic-desks families. Near-black keycaps are
# a REAL dark part on 70s terminals (VT100/ADM-3A class), same standing as the
# palette's badge text; not a painted shadow.
EXTRA_MATERIALS = {
    "keycap-black": ("#37332d", 0.52),  # 70s terminal keycaps
    "keycap-grey": ("#a29a86", 0.55),  # two-tone modifier blocks
    "green-glass": ("#183129", 0.14),  # archive-unit dark phosphor glass
    "blue-glass": ("#22262e", 0.10),  # 80s office-terminal blue-grey CRT glass
    "steel-warm": ("#cfc6ae", 0.48),  # painted sheet-steel covers
    "drive-face": ("#3f3a33", 0.50),  # black full-height 5.25" drive fronts
    "badge-label": ("#d9d2c0", 0.50),  # identity plates; label rows at bake
}


def mat(key):
    """Material from lib.shared() or the classic-desks extras, cached."""
    if key in EXTRA_MATERIALS:
        hexc, rough = EXTRA_MATERIALS[key]
        return lib.material("cd-" + key, hexc, rough)
    return lib.shared(key)


def _rounded_rect_points(w, h, r, segs=5):
    """2D outline (x, z) of a w x h rectangle with corner radius r."""
    r = min(r, w / 2 - 1e-4, h / 2 - 1e-4)
    cx, cz = w / 2 - r, h / 2 - r
    pts = []
    corners = [
        (cx, cz, 0.0),  # top-right, angles 0..90
        (-cx, cz, 0.5 * pi),  # top-left
        (-cx, -cz, pi),  # bottom-left
        (cx, -cz, 1.5 * pi),  # bottom-right
    ]
    for ox, oz, a0 in corners:
        for i in range(segs + 1):
            a = a0 + (0.5 * pi) * i / segs
            pts.append((ox + r * cos(a), oz + r * sin(a)))
    return pts


def rounded_prism(name, w, h, r, depth, loc, mat_=None, segs=5, rot_x=0.0):
    """Rounded-rectangle prism along +Y: bezel-window cutter / glass frame.

    `loc` is the center of the front face; the prism runs `depth` into +Y.
    `rot_x` (degrees) tilts it about X through `loc` — used to cut windows
    into raked terminal faces perpendicular to the face.
    """
    bm = bmesh.new()
    pts = _rounded_rect_points(w, h, r, segs)
    front = [bm.verts.new((x, 0.0, z)) for x, z in pts]
    back = [bm.verts.new((x, depth, z)) for x, z in pts]
    n = len(pts)
    for i in range(n):
        bm.faces.new((front[i], front[(i + 1) % n], back[(i + 1) % n], back[i]))
    bm.faces.new(tuple(reversed(front)))
    bm.faces.new(tuple(back))
    if rot_x:
        rot = Matrix.Rotation(radians(rot_x), 3, "X")
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=bm.verts)
    return lib.finalize(bm, name, mat_, loc)


def bezel_frame(name, w, h, r, frame, depth, loc, mat_=None, segs=6, rot_x=0.0):
    """Rounded-rectangle FRAME (outer prism minus inner window), one boolean.

    The molded dark bezel band of 70s/80s terminals: outer w x h with corner
    radius r, window inset by `frame` on every side. `rot_x` tilts the whole
    frame for raked faces.
    """
    outer = rounded_prism(name, w, h, r, depth, loc, mat_, segs, rot_x)
    # start the cutter proud of the frame front (along the tilted axis) so no
    # coplanar boolean faces survive
    a_y, a_z = cos(radians(rot_x)), sin(radians(rot_x))
    hole_loc = (loc[0], loc[1] - 0.01 * a_y, loc[2] - 0.01 * a_z)
    hole = rounded_prism(
        name + "-hole",
        w - 2 * frame,
        h - 2 * frame,
        max(0.004, r - frame),
        depth + 0.02,
        hole_loc,
        None,
        segs,
        rot_x,
    )
    lib.cut(outer, hole)
    return outer


def profile_shell(name, width, points, loc=(0.0, 0.0, 0.0), mat_=None, inset_top=0.0):
    """Side-profile polygon (y, z) extruded along X — one-piece 70s shells.

    `points` walk the silhouette counter-clockwise viewed from +X (front at
    -Y). `inset_top` narrows the extrusion for points above the profile's
    mid-height, hinting at molded draft angle without real curvature cost.
    """
    bm = bmesh.new()
    zmid = (min(p[1] for p in points) + max(p[1] for p in points)) / 2.0
    left, right = [], []
    for y, z in points:
        half = width / 2.0 - (inset_top if z > zmid else 0.0)
        left.append(bm.verts.new((-half, y, z)))
        right.append(bm.verts.new((half, y, z)))
    n = len(points)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((left[i], left[j], right[j], right[i]))
    bm.faces.new(tuple(left))
    bm.faces.new(tuple(reversed(right)))
    return lib.finalize(bm, name, mat_, loc)


def feet(w, d, h=0.008, inset=0.035, size=0.034, rail=False):
    """Visible dark feet lifting the case, creating the real shadow gap.

    `rail=True` builds two wide side rails (Sun workstation stance) instead
    of four corner pads. Case bodies must start at z=h.
    """
    m = mat("recess-deep")
    if rail:
        for sx in (-1, 1):
            lib.box("foot-rail", (0.060, d - 2 * inset, h), (sx * (w / 2 - 0.048), 0, h / 2), m)
    else:
        for sx in (-1, 1):
            for sy in (-1, 1):
                lib.box(
                    "foot",
                    (size, size, h),
                    (sx * (w / 2 - inset), sy * (d / 2 - inset), h / 2),
                    m,
                )


def badge_plate(name, w, h, y_f, x, z, plate_mat="abs-grey"):
    """Recessed badge well with a raised blank plate (generic, logo-free)."""
    lib.box(name + "-well", (w, 0.0016, h), (x, y_f + 0.0008, z), mat("recess"))
    lib.box(name + "-plate", (w - 0.006, 0.0030, h - 0.005), (x, y_f - 0.0006, z), mat(plate_mat))


def dimple_field(target, name, w, h, y_f, x, z, pitch=0.0165, r=0.0026, depth=0.0012):
    """Field of small round dents cut into a solid fascia (SS2 front idiom).

    One multi-cylinder cutter, one boolean; the dents expose real interior
    faces of the fascia solid, so flat museum light still shades them.
    """
    bm = bmesh.new()
    cols = max(2, int(w / pitch))
    rows = max(2, int(h / pitch))
    for i in range(cols):
        for j in range(rows):
            cxx = x - w / 2 + (i + 0.5) * w / cols
            czz = z - h / 2 + (j + 0.5) * h / rows
            ret = bmesh.ops.create_cone(bm, cap_ends=True, segments=10, radius1=r, radius2=r, depth=depth * 2)
            rot = Matrix.Rotation(radians(90.0), 3, "X")
            bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=ret["verts"])
            bmesh.ops.translate(bm, vec=(cxx, y_f, czz), verts=ret["verts"])
    lib.cut(target, lib.finalize(bm, name + "-cuts"))


def groove_top(target, name, span_w, count, y_c, d_len, z_top, g_w=0.0032, g_d=0.0016):
    """Field of longitudinal top vent grooves (90s slim-desktop idiom).

    Real cuts into the lid solid: `count` grooves across `span_w`, each
    `d_len` long centered at `y_c`, sunk `g_d` below `z_top`.
    """
    items = []
    for i in range(count):
        x = (i - (count - 1) / 2) * span_w / count
        items.append(((g_w, d_len, g_d * 2), (x, y_c, z_top)))
    lib.cut(target, lib.multi_box(name + "-cuts", items))


def key_rows(name, x0, y0, z_of, rows, pitch=0.0165, key_mat="keycap-black"):
    """Key field from row specs: (row_y_index, n_keys, lead_in, wide_last).

    `z_of(cy)` maps a key's Y center to its Z top — lets keys ride wedges or
    aprons. Every row is one multi_box for cheap real geometry.
    """
    items = []
    for r_i, n, lead, wide in rows:
        cy = y0 + r_i * pitch
        for k in range(n):
            kw = pitch * (1.7 if (wide and k == n - 1) else 0.8)
            cx = x0 + lead * pitch + k * pitch + (0.45 * pitch if (wide and k == n - 1) else 0)
            items.append(((kw, pitch * 0.78, 0.0085), (cx, cy, z_of(cy))))
    return lib.multi_box(name, items, mat(key_mat))


def terminal_keyboard(name, w, d, h, y, sections=True, key_mat="abs-light", mod_mat="keycap-grey"):
    """Detached low terminal keyboard: framed key well + sectioned blocks.

    VT-class two-tone layout: alnum block left, nav cluster, numeric pad
    right; a shallow recessed well frames the field so keys sit IN the case.
    """
    body = lib.wedge_box(name + "-case", w, d, h * 0.72, h, (0, y, 0), mat("abs"))
    lib.bevel(body, 0.003, 2)
    well_w, well_d = w - 0.030, d - 0.026
    lib.box(name + "-well", (well_w, well_d, 0.003), (0, y, h * 0.80), mat("recess"))
    pitch = 0.0165
    z_top = h * 0.80 + 0.004

    def flat(_cy):
        return z_top

    main_w = well_w * (0.58 if sections else 0.94)
    cols = int(main_w / pitch)
    rows = int((well_d - 0.004) / pitch)
    x0 = -well_w / 2 + 0.006 + pitch / 2
    y0 = y - well_d / 2 + 0.006 + pitch / 2
    key_rows(
        name + "-alnum",
        x0,
        y0,
        flat,
        [(r, cols, 0, r == 0) for r in range(rows)],
        pitch,
        key_mat,
    )
    if sections:
        nav_x = x0 + (cols + 0.8) * pitch
        key_rows(
            name + "-nav",
            nav_x,
            y0,
            flat,
            [(r, 3, 0, False) for r in range(rows - 1)],
            pitch,
            mod_mat,
        )
        num_x = nav_x + 3.8 * pitch
        key_rows(
            name + "-num",
            num_x,
            y0,
            flat,
            [(r, 4, 0, False) for r in range(rows)],
            pitch,
            mod_mat,
        )
    return body
