"""Shared helpers for the small-object generators (gen_mouse.py, gen_phone.py).

Adds what lib.py lacks for palm-sized exhibits: superellipse shell lofts for
curved mouse bodies, drooping cable tubes (cables must rest on the desk, never
float), top-face recess wells, a tilt helper for phones leaning on museum
cradles, a small extension palette for phone-era plastics, and a Cycles bake
pipeline (adapted from blender/lib_bake.py, the classic-desks pipeline on
main) sized for palm objects. lib.py itself is shared/read-only; everything
small-object-specific lives here.

Import-guarded exactly like lib.py: plain python (ruff/CI) only parses it.
"""

import os
import sys
from math import cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402

try:  # only present inside Blender's bundled python
    import numpy as np
except ImportError:  # plain python (ruff/CI): definitions only, never run
    np = None

# Extension palette: modern-handset tones. Museum-wide beige stays in
# lib.SHARED_MATERIALS; phones are genuinely dark hardware, but bodies stay
# mid-grey — near-black remains reserved for true dark parts (screen glass).
# Values retuned per the design-review texture round (round-tex1 judgments): darker
# smoother buttons/cables, lifted charcoal handset tones, cooler cradle,
# dedicated key-grey and screen-glass tones for part separation.
PALETTE = {
    "phone-body": ("#3c4046", 0.50),  # dark grey-blue slab plastic
    "phone-frame": ("#5b5f66", 0.55),  # bumper rims, side frames
    "phone-back": ("#3d4046", 0.60),  # matte back covers
    "stand": ("#7f7a71", 0.50),  # museum cradle, cool powder-coat grey
    "button-dark": ("#5a554b", 0.42),  # dark 80s button plastic (green-eye/Amiga class)
    "button-grey": ("#a89f8d", 0.50),  # grey-beige one-button cap (mouse C)
    "phone-key": ("#a09889", 0.48),  # chin keys / trackball ring (phone A)
    "cable": ("#8f887c", 0.55),  # aged PVC cable/boot, darker than the shells
    "bezel-dark": ("#2b2d31", 0.45),  # screen bezel reveal on dark handsets
    "glass-screen": ("#26292e", 0.16),  # handset display glass, no emission
}


def mat(key):
    """Material by key: extension palette first, then lib.shared fallback."""
    if key in PALETTE:
        hexc, rough = PALETTE[key]
        return lib.material("so-" + key, hexc, rough)
    return lib.shared(key)


def _superellipse_ring(bm, z, w, d, y_off, expo, segments, front_narrow=0.0):
    pts = []
    for i in range(segments):
        t = 2.0 * pi * i / segments
        c, s = cos(t), sin(t)
        x = (abs(c) ** (2.0 / expo)) * (1.0 if c >= 0 else -1.0) * w / 2.0
        y = (abs(s) ** (2.0 / expo)) * (1.0 if s >= 0 else -1.0) * d / 2.0 + y_off
        if front_narrow and s < 0.0:  # front half (-Y): pull sides inward
            x *= 1.0 - front_narrow * (-s)
        pts.append(bm.verts.new((x, y, z)))
    return pts


def shell(name, sections, mat_=None, segments=24, front_narrow=0.0):
    """Closed curved solid from stacked superellipse rings (mouse shells).

    sections: [(z, width, depth, y_offset, exponent), ...] bottom to top.
    exponent 2 = ellipse, higher = squarer ring; y_offset lets the dome peak
    drift rearward like real 90s mice; front_narrow tapers the plan toward
    the button end (0.06 = 6% narrower at the nose). Capped flat both ends.
    """
    bm = lib.new_bm()
    rings = [_superellipse_ring(bm, *sec, segments, front_narrow) for sec in sections]
    for r0, r1 in zip(rings, rings[1:]):
        for i in range(segments):
            bm.faces.new((r0[i], r0[(i + 1) % segments], r1[(i + 1) % segments], r1[i]))
    bm.faces.new(tuple(reversed(rings[0])))
    bm.faces.new(tuple(rings[-1]))
    return lib.finalize(bm, name, mat_)


def tube(name, points, radius, mat_=None, resolution=12):
    """Smooth tube along a bezier path — mouse cables drooping to the desk.

    Auto handles give a natural catenary-ish sag; converted to a real mesh so
    the GLB carries geometry, not a curve.
    """
    curve = lib.bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    sp = curve.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for bp, p in zip(sp.bezier_points, points):
        bp.co = p
        bp.handle_left_type = "AUTO"
        bp.handle_right_type = "AUTO"
    curve.bevel_depth = radius
    curve.bevel_resolution = 3
    curve.resolution_u = resolution
    curve.use_fill_caps = True
    obj = lib.bpy.data.objects.new(name, curve)
    lib.bpy.context.scene.collection.objects.link(obj)
    for o in lib.bpy.context.scene.collection.objects:
        o.select_set(o is obj)
    lib.bpy.context.view_layer.objects.active = obj
    lib.bpy.ops.object.convert(target="MESH")
    obj = lib.bpy.context.view_layer.objects.active
    if mat_ is not None:
        obj.data.materials.append(mat_)
    return obj


def top_well(target, name, w, d, top_z, x, y, depth=0.004, mat_=None):
    """Blind recess cut into a TOP face (z = top_z), lined with real walls.

    The z-axis sibling of lib.well(): button decks sit inside it as proud
    solids, so control layouts read as depth, never as painted lines.
    """
    lib.cut(target, lib.multi_box(name + "-cut", [((w, d, depth * 2.0), (x, y, top_z))]))
    fw, fd = w - 0.0006, d - 0.0006
    z0 = top_z - depth
    wall = 0.0012
    items = [
        ((fw, fd, wall), (x, y, z0 + wall / 2)),
        ((wall, fd, depth), (x - fw / 2 + wall / 2, y, z0 + depth / 2)),
        ((wall, fd, depth), (x + fw / 2 - wall / 2, y, z0 + depth / 2)),
        ((fw, wall, depth), (x, y - fd / 2 + wall / 2, z0 + depth / 2)),
        ((fw, wall, depth), (x, y + fd / 2 - wall / 2, z0 + depth / 2)),
    ]
    return lib.multi_box(name + "-liner", items, mat_ or lib.shared("recess"))


def ellipsoid(name, radii, loc, mat_, u=32, v=16):
    """Scaled uv-sphere (mouse balls, trackballs, palm domes)."""
    bm = lib.new_bm()
    ret = lib.bmesh.ops.create_uvsphere(bm, u_segments=u, v_segments=v, radius=1.0)
    lib.bmesh.ops.scale(bm, vec=radii, verts=ret["verts"])
    return lib.finalize(bm, name, mat_, loc)


def shade_smooth(obj, angle=60.0):
    """Smooth-shade with an autosmooth split angle: molded curves read as
    curves while grooves and seams keep crisp edges (Blender 4.0 API)."""
    for p in obj.data.polygons:
        p.use_smooth = True
    obj.data.use_auto_smooth = True
    obj.data.auto_smooth_angle = radians(angle)


def scene_objects():
    """Snapshot of linked objects — diff before/after to group phone parts."""
    return set(lib.bpy.context.scene.collection.objects)


def tilt_x(objs, deg, pivot=(0.0, 0.0, 0.0)):
    """Rotate objects about global X around pivot (lean a phone on a cradle).

    view_layer.update() first: matrix_world of a freshly created object is
    stale identity until the depsgraph runs, which would silently drop the
    object's location (buttons buried at the origin — a real bug once).
    """
    lib.bpy.context.view_layer.update()
    piv = lib.Matrix.Translation(pivot)
    m = piv @ lib.Matrix.Rotation(radians(deg), 4, "X") @ piv.inverted()
    for o in objs:
        o.matrix_world = m @ o.matrix_world


def rot_z(objs, deg, pivot=(0.0, 0.0, 0.0)):
    """Rotate objects about global Z around pivot (aim connectors, stands)."""
    lib.bpy.context.view_layer.update()
    piv = lib.Matrix.Translation(pivot)
    m = piv @ lib.Matrix.Rotation(radians(deg), 4, "Z") @ piv.inverted()
    for o in objs:
        o.matrix_world = m @ o.matrix_world


def move(objs, vec):
    """Translate a group of objects by vec."""
    lib.bpy.context.view_layer.update()
    m = lib.Matrix.Translation(vec)
    for o in objs:
        o.matrix_world = m @ o.matrix_world


def min_z(objs):
    """Lowest world-space bbox corner of a group (settle phones onto stands)."""
    lib.bpy.context.view_layer.update()
    lo = None
    for o in objs:
        for c in o.bound_box:
            z = (o.matrix_world @ lib.Matrix.Translation(c).to_translation()).z
            lo = z if lo is None else min(lo, z)
    return lo


# ---------------------------------------------------------------------------
# Texture bake pipeline — adapted from blender/lib_bake.py (classic-desks,
# on main; this worktree branched before it landed, so the approach is reused
# here under this module rather than duplicating that filename). Smart-UV
# atlas -> Cycles diffuse/AO/pointiness bakes -> numpy compose -> one baked
# Principled material. Screen glass stays flat/glossy outside the atlas.
#
# Grain sources: the shared Midjourney library ~/scene-v2-reference/textures/
# (INDEX.md). Library files used here: abs-beige-clean.png (mouse shells,
# phone-A body), abs-beige-yellowed.png (warm/grey parts, cables/boots),
# abs-charcoal.png (dark buttons, dark handset plastics),
# metal-powdercoat.png (museum cradles). Grain is BOX-projected in object
# space and OVERLAY-mixed toward the palette tone; a missing file degrades
# gracefully to the flat color.

TEX_LIB = os.path.expanduser("~/scene-v2-reference/textures")

# Texture-round retune (round-tex1, all six judges agreed): grain amplitude
# roughly halved and frequency ~2.5x finer so it reads as molded ABS, not
# fabric; cables/boots much smoother PVC; charcoal parts keep only a trace.
BAKE_GRAIN = {
    "shared-abs": ("abs-beige-clean/abs-beige-clean.png", 0.16),
    "shared-abs-light": ("abs-beige-clean/abs-beige-clean.png", 0.15),
    "shared-abs-warm": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.18),
    "shared-abs-grey": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.16),
    "shared-recess": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.14),
    "shared-recess-deep": ("abs-charcoal/abs-charcoal.png", 0.18),
    "so-button-dark": ("abs-charcoal/abs-charcoal.png", 0.16),
    "so-button-grey": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.14),
    "so-phone-key": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.14),
    "so-cable": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.10),
    "so-phone-body": ("abs-charcoal/abs-charcoal.png", 0.16),
    "so-phone-frame": ("abs-charcoal/abs-charcoal.png", 0.15),
    "so-phone-back": ("abs-charcoal/abs-charcoal.png", 0.16),
    "so-bezel-dark": ("abs-charcoal/abs-charcoal.png", 0.12),
    "so-stand": ("metal-powdercoat/metal-powdercoat.png", 0.15),
    "input-mouse-pale": ("abs-beige-clean/abs-beige-clean.png", 0.14),
    "input-mouse-silver": ("metal-powdercoat/metal-powdercoat.png", 0.12),
    "input-mouse-black": ("abs-charcoal/abs-charcoal.png", 0.15),
    "input-mouse-black-key": ("abs-charcoal/abs-charcoal.png", 0.14),
    "input-mouse-cream": ("abs-beige-clean/abs-beige-clean.png", 0.16),
    "input-mouse-cream-key": ("abs-beige-clean/abs-beige-clean.png", 0.14),
    "input-mouse-rail": ("metal-powdercoat/metal-powdercoat.png", 0.12),
    "input-wheel": ("abs-charcoal/abs-charcoal.png", 0.12),
    "input-black-well": ("abs-charcoal/abs-charcoal.png", 0.10),
    "input-sensor-red": ("abs-charcoal/abs-charcoal.png", 0.05),
}
BAKE_GLASS = {"shared-glass", "so-glass-screen"}
GRAIN_SCALE = 240.0  # box-projection repeats per meter — ~0.2 mm features


def _augment_material(mat_, atlas, grain_scale=None, grain_mul=1.0):
    """Wire library grain into Base Color and add the atlas bake target."""
    nt = mat_.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    base = tuple(bsdf.inputs["Base Color"].default_value)
    spec = BAKE_GRAIN.get(mat_.name)
    if spec is not None:
        path = os.path.join(TEX_LIB, spec[0])
        if os.path.exists(path):
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = lib.bpy.data.images.load(path, check_existing=True)
            tex.projection = "BOX"
            tex.projection_blend = 0.25
            coords = nt.nodes.new("ShaderNodeTexCoord")
            mapping = nt.nodes.new("ShaderNodeMapping")
            mapping.inputs["Scale"].default_value = (grain_scale or GRAIN_SCALE,) * 3
            nt.links.new(coords.outputs["Object"], mapping.inputs["Vector"])
            nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
            mix = nt.nodes.new("ShaderNodeMixRGB")
            mix.blend_type = "OVERLAY"
            mix.inputs["Fac"].default_value = spec[1] * grain_mul
            mix.inputs["Color1"].default_value = base
            nt.links.new(tex.outputs["Color"], mix.inputs["Color2"])
            nt.links.new(mix.outputs["Color"], bsdf.inputs["Base Color"])
    for n in nt.nodes:
        n.select = False
    node = nt.nodes.new("ShaderNodeTexImage")
    node.image = atlas
    node.select = True
    nt.nodes.active = node


def _grab(img, size):
    px = np.empty(size * size * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    return px.reshape(size, size, 4)


def bake_export(
    out_path,
    size=512,
    roughness=0.55,
    ao_samples=24,
    grain_scale=None,
    grain_mul=1.0,
    ao_floor=0.66,
):
    """Join solids, UV-atlas, bake, compose, export a textured GLB.

    Mice bake at 512, phones at 1024. AO shading plus faint pointiness edge
    wear keep recesses readable under the museum's flat light.
    """
    bpy = lib.bpy
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    # this box's Blender build ships without OpenImageDenoise: with denoising
    # left on, every bake silently comes back BLACK — keep it off
    scn.cycles.use_denoising = False
    solids = []
    for obj in list(scn.objects):
        if obj.type != "MESH":
            continue
        names = {m.name for m in obj.data.materials if m}
        if not (names & BAKE_GLASS):
            solids.append(obj)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in solids:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = solids[0]
    bpy.ops.object.convert(target="MESH")  # applies bevels on all selected
    # bmesh-built meshes can carry invalid material indices after modifiers.
    # Every small object has one slot at this stage, so normalize before join.
    for obj in solids:
        n = len(obj.data.polygons)
        if n:
            obj.data.polygons.foreach_set("material_index", np.zeros(n, dtype=np.int32))
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = "so-baked"
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=radians(66.0), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")

    atlas = bpy.data.images.new("atlas", size, size, alpha=False)
    for mat_ in joined.data.materials:
        _augment_material(mat_, atlas, grain_scale, grain_mul)
    scn.cycles.samples = 1
    bpy.ops.object.bake(type="DIFFUSE", pass_filter={"COLOR"}, margin=4)
    albedo = _grab(atlas, size)
    scn.cycles.samples = ao_samples
    bpy.ops.object.bake(type="AO", margin=4)
    ao = _grab(atlas, size)
    # pointiness -> EMIT for faint edge wear (convex edges catch light wear)
    for mat_ in joined.data.materials:
        nt = mat_.node_tree
        out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        emit = nt.nodes.new("ShaderNodeEmission")
        nt.links.new(geo.outputs["Pointiness"], emit.inputs["Color"])
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    scn.cycles.samples = 1
    bpy.ops.object.bake(type="EMIT", margin=4)
    pointy = _grab(atlas, size)

    # round-tex1: shallower AO (no painted-black crevices), halved edge wear
    shade = ao_floor + (1.0 - ao_floor) * ao[..., :3]
    wear = np.clip((pointy[..., :3] - 0.60) * 2.0, 0.0, 1.0) * 0.045
    final = np.clip(albedo[..., :3] * shade + wear, 0.0, 1.0)
    px = np.ones((size, size, 4), dtype=np.float32)
    px[..., :3] = final
    atlas.pixels.foreach_set(px.ravel())

    baked = bpy.data.materials.new("so-baked-mat")
    baked.use_nodes = True
    bb = baked.node_tree.nodes["Principled BSDF"]
    tex = baked.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = atlas
    baked.node_tree.links.new(tex.outputs["Color"], bb.inputs["Base Color"])
    bb.inputs["Roughness"].default_value = roughness
    joined.data.materials.clear()
    joined.data.materials.append(baked)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=out_path,
        export_format="GLB",
        export_apply=True,
        export_yup=True,
        export_image_format="JPEG",
    )
    print("exported textured", out_path)


def maybe_bake_export(out_path, size=512, roughness=0.55, **bake_kw):
    """`--textured` in the argv tail bakes; otherwise flat export via lib."""
    if "--textured" in sys.argv:
        bake_export(out_path, size=size, roughness=roughness, **bake_kw)
    else:
        lib.export_glb(out_path)
