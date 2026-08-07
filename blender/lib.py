"""Shared bpy helpers for the parametric retro-hardware generators.

Conventions (every generator MUST follow these):
- Units: real-world METERS.
- Blender build space: +Z up, the model FRONT faces -Y, base resting on z=0.
- glTF export keeps the exporter's default +Y-up conversion, which maps
  Blender -Y (our front) onto glTF +Z. Result: the FRONT of every exported
  model faces +Z, base at y=0 — exactly what spa NormalizedModel.tsx expects.
- Flat materials only (Principled base color + roughness); no textures yet.

Import-guarded: CI lints this file without Blender installed; the geometry
paths only execute under `blender -b --python gen_*.py`.
"""

import os
import sys
from math import radians, sqrt

try:  # only present inside Blender's bundled python
    import bmesh
    import bpy
    from mathutils import Matrix
except ImportError:  # plain python (ruff/CI): definitions only, never run
    bmesh = None
    bpy = None
    Matrix = None


def parse_args(default_variant="A", default_out="/tmp/param-out.glb"):
    """Parse `-- --variant A --out /path/x.glb` from Blender's argv tail."""
    argv = sys.argv
    tail = argv[argv.index("--") + 1 :] if "--" in argv else []
    variant, out = default_variant, default_out
    it = iter(tail)
    for a in it:
        if a == "--variant":
            variant = next(it)
        elif a == "--out":
            out = next(it)
    return variant.upper(), out


def reset_scene():
    """Start from a completely empty scene (no default cube/light/camera)."""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _srgb_to_linear(c8):
    c = c8 / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def material(name, hex_color, roughness=0.55, metallic=0.0):
    """Flat Principled material from an sRGB hex string, cached by name."""
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    h = hex_color.lstrip("#")
    rgb = [_srgb_to_linear(int(h[i : i + 2], 16)) for i in (0, 2, 4)]
    bsdf.inputs["Base Color"].default_value = (*rgb, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


# Shared aged-plastic palette (iteration 2, still the shapes+materials stage).
# Aged beige ABS family with slight per-part tone variation; recess interiors
# are WARM GREY plastic — depth is modeled, never painted black. Near-black is
# reserved for true dark parts only (screen glass, badge text, keyholes).
SHARED_MATERIALS = {
    "abs": ("#d6cbb2", 0.58),  # base aged beige ABS (fascias, shells)
    "abs-warm": ("#cec0a2", 0.62),  # dirtier body/base tone
    "abs-light": ("#ded3bb", 0.52),  # drive faces, buttons, white keycaps
    "abs-grey": ("#b3a992", 0.58),  # grey-beige (modifier caps, knobs, doors)
    "recess": ("#8f887a", 0.66),  # cavity interiors, reveals, wells
    "recess-deep": ("#6e6759", 0.70),  # deep slots, seams, vent floors
    "dark": ("#211f1b", 0.45),  # true dark ONLY: badge text, keyhole cores
    "glass": ("#20241f", 0.12),  # CRT screen glass
    # Set-dressing extension: restrained institutional materials. These stay
    # in the shared palette so furniture and loose props do not invent local
    # one-off colors.
    "steel": ("#777970", 0.48),  # grey powder-coated archive furniture
    "steel-light": ("#a9aaa0", 0.52),  # galvanized/pale powder-coated steel
    "vinyl": ("#454a47", 0.68),  # charcoal task-chair upholstery
    "cable": ("#343431", 0.58),  # flexible PVC and floor cord covers
    "paper": ("#d9d2bd", 0.72),  # aged manual stock / floppy labels
    "cardboard": ("#aa8d63", 0.76),  # uncoated archive/floppy cartons
}


def shared(key):
    """Material from the shared aged-plastic palette, cached repo-wide."""
    hexc, rough = SHARED_MATERIALS[key]
    return material("shared-" + key, hexc, rough)


def pocket(name, w, h, depth, loc, wall=0.0014, mat=None, back=True):
    """Open-front recess liner: four inward-facing walls + back plate.

    Slots just inside a boolean opening of the same w x h so a cavity shows
    real warm-grey interior faces instead of painted outlines. `loc` is the
    center of the FRONT opening; walls run `depth` into +Y (away from the
    viewer per the facing convention). Build it 0.3 mm smaller than the
    opening to avoid z-fighting the cut walls.
    """
    x, y, z = loc
    items = [
        ((wall, depth, h), (x - w / 2 + wall / 2, y + depth / 2, z)),
        ((wall, depth, h), (x + w / 2 - wall / 2, y + depth / 2, z)),
        ((w, depth, wall), (x, y + depth / 2, z + h / 2 - wall / 2)),
        ((w, depth, wall), (x, y + depth / 2, z - h / 2 + wall / 2)),
    ]
    if back:
        items.append(((w, 0.0016, h), (x, y + depth - 0.0008, z)))
    return multi_box(name, items, mat)


def well(target, name, w, h, front_y, x, z, depth=0.005, wall=0.0014, mat=None):
    """Blind rectangular recess cut into `target`'s front face, lined.

    Boolean-cuts a `depth`-deep pocket at (x, z) on the plane y=front_y, then
    installs a `pocket` liner 0.3 mm inside it so every interior face is real
    geometry in the recess material. Returns the liner object.
    """
    cut(target, multi_box(name + "-cut", [((w, depth * 2.0, h), (x, front_y, z))]))
    return pocket(name + "-liner", w - 0.0006, h - 0.0006, depth - 0.001, (x, front_y + 0.0003, z), wall, mat)


def new_bm():
    return bmesh.new()


def finalize(bm, name, mat=None, loc=(0.0, 0.0, 0.0)):
    """Recalc normals, convert a bmesh to a linked object, free the bmesh."""
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    obj.location = loc
    bpy.context.scene.collection.objects.link(obj)
    if mat is not None:
        obj.data.materials.append(mat)
    return obj


def box(name, size, loc=(0.0, 0.0, 0.0), mat=None):
    """Axis-aligned box; size=(x_width, y_depth, z_height), loc = center."""
    bm = bmesh.new()
    ret = bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=size, verts=ret["verts"])
    return finalize(bm, name, mat, loc)


def multi_box(name, items, mat=None):
    """One mesh containing many boxes; items = [(size, center), ...].

    The workhorse for boolean cutters (cut once, not N times) and for
    backing plates hidden inside solids.
    """
    bm = bmesh.new()
    for size, loc in items:
        ret = bmesh.ops.create_cube(bm, size=1.0)
        bmesh.ops.scale(bm, vec=size, verts=ret["verts"])
        bmesh.ops.translate(bm, vec=loc, verts=ret["verts"])
    return finalize(bm, name, mat)


def cylinder(name, r, depth, axis="Y", loc=(0.0, 0.0, 0.0), mat=None, segments=24):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segments, radius1=r, radius2=r, depth=depth)
    if axis == "Y":
        rot = Matrix.Rotation(radians(90.0), 3, "X")
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=bm.verts)
    elif axis == "X":
        rot = Matrix.Rotation(radians(90.0), 3, "Y")
        bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=bm.verts)
    return finalize(bm, name, mat, loc)


def loft_into(bm, axis, sections, center=(0.0, 0.0, 0.0)):
    """Add a closed 4-sided loft to `bm` along `axis` ('Y' depth or 'Z' up).

    Each section is (t, width_x, other, offset): at position t along the
    axis, a rectangle width_x wide; `other` is its size along the remaining
    dimension (Z-height for axis='Y', Y-depth for axis='Z'); `offset` shifts
    the rectangle's center along that remaining dimension. Used for CRT tube
    tapers (axis='Y') and chamfered keycap frusta (axis='Z').
    """
    cx, cy, cz = center
    rings = []
    for t, w, s, off in sections:
        hw, hs = w / 2.0, s / 2.0
        if axis == "Y":
            pts = [
                (cx - hw, cy + t, cz + off - hs),
                (cx + hw, cy + t, cz + off - hs),
                (cx + hw, cy + t, cz + off + hs),
                (cx - hw, cy + t, cz + off + hs),
            ]
        else:
            pts = [
                (cx - hw, cy + off - hs, cz + t),
                (cx + hw, cy + off - hs, cz + t),
                (cx + hw, cy + off + hs, cz + t),
                (cx - hw, cy + off + hs, cz + t),
            ]
        rings.append([bm.verts.new(p) for p in pts])
    for r0, r1 in zip(rings, rings[1:]):
        for i in range(4):
            bm.faces.new((r0[i], r0[(i + 1) % 4], r1[(i + 1) % 4], r1[i]))
    bm.faces.new(tuple(reversed(rings[0])))
    bm.faces.new(tuple(rings[-1]))
    return rings


def loft(name, axis, sections, center=(0.0, 0.0, 0.0), mat=None):
    bm = bmesh.new()
    loft_into(bm, axis, sections, center)
    return finalize(bm, name, mat)


def wedge_box(name, w, d, h_front, h_rear, loc=(0.0, 0.0, 0.0), mat=None):
    """Keyboard-style wedge: flat base, top face sloping up toward +Y (rear).

    Front (user) edge is at -Y per the shared facing convention.
    """
    hw, hd = w / 2.0, d / 2.0
    bm = bmesh.new()
    lo = [(-hw, -hd, 0.0), (hw, -hd, 0.0), (hw, hd, 0.0), (-hw, hd, 0.0)]
    hi = [
        (-hw, -hd, h_front),
        (hw, -hd, h_front),
        (hw, hd, h_rear),
        (-hw, hd, h_rear),
    ]
    vlo = [bm.verts.new(p) for p in lo]
    vhi = [bm.verts.new(p) for p in hi]
    for i in range(4):
        bm.faces.new((vlo[i], vlo[(i + 1) % 4], vhi[(i + 1) % 4], vhi[i]))
    bm.faces.new(tuple(reversed(vlo)))
    bm.faces.new(tuple(vhi))
    return finalize(bm, name, mat, loc)


def bulged_panel(name, w, h, sag, loc=(0.0, 0.0, 0.0), mat=None, segs=20):
    """Shallow sphere-section rectangle bulging toward -Y (the viewer).

    Corner verts sit on the y=0 plane of `loc`; the center apex reaches
    y=-sag. Radius follows from the half-diagonal: R=(a²+sag²)/(2·sag).
    Models a CRT tube face geometrically, per the art-direction brief.
    """
    a = sqrt((w / 2.0) ** 2 + (h / 2.0) ** 2)
    radius = (a * a + sag * sag) / (2.0 * sag)
    bm = bmesh.new()
    grid = []
    for i in range(segs + 1):
        x = -w / 2.0 + w * i / segs
        row = []
        for j in range(segs + 1):
            z = -h / 2.0 + h * j / segs
            y = -(sqrt(radius * radius - x * x - z * z) - (radius - sag))
            row.append(bm.verts.new((x, y, z)))
        grid.append(row)
    faces = []
    for i in range(segs):
        for j in range(segs):
            faces.append(bm.faces.new((grid[i][j], grid[i][j + 1], grid[i + 1][j + 1], grid[i + 1][j])))
    if sum(f.normal.y for f in faces) > 0.0:  # open surface: force -Y facing
        bmesh.ops.reverse_faces(bm, faces=faces)
    return finalize(bm, name, mat, loc)


def bevel(obj, width=0.002, segments=2, angle=40.0):
    """Edge-softening bevel. Add AFTER all boolean cuts on the object."""
    mod = obj.modifiers.new("bevel", "BEVEL")
    mod.width = width
    mod.segments = segments
    mod.limit_method = "ANGLE"
    mod.angle_limit = radians(angle)
    mod.use_clamp_overlap = True
    return mod


def cut(target, cutter):
    """Boolean-subtract `cutter` from `target`, apply, delete the cutter."""
    mod = target.modifiers.new("cut", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.solver = "EXACT"
    mod.object = cutter
    bpy.context.view_layer.objects.active = target
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def export_glb(path):
    """GLB export honoring the facing convention (modifiers applied)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", export_apply=True, export_yup=True)
    print("exported", path)
