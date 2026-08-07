"""Modern/industrial helpers + palette for gen_modern.py (scene v2).

lib.py is the shared retro toolkit and stays READ-ONLY; everything the
modern-hardware generator needs beyond it lives here: a dark/aluminium
palette (the aged-beige family in lib.SHARED_MATERIALS is wrong for
2020s hardware), a diamond-lattice mesh-front builder, rounded slabs for
mini-PC shells, and trapezoid prisms for D-sub connector bodies.

Same conventions as lib.py: meters, front faces -Y, base at z=0,
import-guarded so ruff/CI can parse without Blender.
"""

import sys
from math import ceil, cos, pi, radians, sin
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)

# Modern-hardware palette (flat massing stage). Dark charcoal family for the
# 2021 tower + industrial box, aluminium tones for the mini slab. Cavity
# interiors are DARK here by design — modern cases are dark inside, unlike
# the warm-grey retro recesses — but depth is still modeled, never painted.
MODERN_MATERIALS = {
    "charcoal": ("#3f4247", 0.62, 0.0),  # tower steel side/shell panels
    "charcoal-deep": ("#2e3034", 0.72, 0.0),  # tower molded-ABS fascia, feet
    "mesh-face": ("#37393d", 0.68, 0.0),  # lattice strips of the mesh front
    "cavity": ("#1d1f22", 0.74, 0.0),  # air volume behind mesh / vent floors
    "gloss-panel": ("#1b1d20", 0.16, 0.0),  # side-glass hint (solid glossy inset)
    "mesh-fine": ("#26282c", 0.72, 0.0),  # near-black dust mesh layer behind
    "fan-dark": ("#282a2e", 0.70, 0.0),  # fan ring/hub silhouettes in the cavity
    "alu": ("#d6d7d3", 0.32, 0.75),  # mini-slab shell (warm anodized)
    "alu-dark": ("#83878b", 0.48, 0.55),  # mini-slab rear vent band
    "plastic-top": ("#3c4043", 0.58, 0.0),  # mini-slab graphite top inset
    "powder": ("#51575d", 0.74, 0.0),  # industrial anthracite powder coat
    "powder-dark": ("#2e3236", 0.72, 0.0),  # industrial front IO block
    "steel": ("#d3d7db", 0.28, 0.45),  # D-sub shells, screws: bright zinc; kept
    # semi-metallic so the rim survives WebGL's weak env lighting
    "term-green": ("#35883f", 0.55, 0.0),  # phoenix terminal block
    "port-dark": ("#0f1011", 0.55, 0.0),  # port + connector cavities
    "led-green": ("#3da04a", 0.35, 0.0),
    "led-amber": ("#c08c34", 0.35, 0.0),
    "led-blue": ("#3f8fd4", 0.35, 0.0),
    "led-blue-dim": ("#33689c", 0.40, 0.0),  # muted power ring/button blue
    "rubber": ("#1a1b1c", 0.85, 0.0),  # feet
}


def modern(key):
    """Material from the modern palette, cached repo-wide."""
    hexc, rough, metal = MODERN_MATERIALS[key]
    return lib.material("modern-" + key, hexc, rough, metal)


def intersect(target, cutter):
    """Boolean-intersect `target` with `cutter`, apply, delete the cutter."""
    mod = target.modifiers.new("isect", "BOOLEAN")
    mod.operation = "INTERSECT"
    mod.solver = "EXACT"
    mod.use_self = True  # lattice strips cross each other inside one mesh
    mod.object = cutter
    lib.bpy.context.view_layer.objects.active = target
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    lib.bpy.data.objects.remove(cutter, do_unlink=True)


def lattice_panel(name, w, h, loc, pitch=0.012, strip=0.0022, depth=0.002, mat=None):
    """Diamond mesh-front lattice: two families of ±45° strips, clipped.

    Reads as the triangular/diamond perforated steel front of 2020s airflow
    cases (Corsair 4000D Airflow / Fractal Meshify class) at museum viewing
    distance. Real geometry: strips have thickness, the dark air volume shows
    THROUGH the gaps to a backing plate the caller places behind. `loc` is the
    panel center; the panel lies in an XZ plane at loc[1], strips run at ±45°.
    """
    x0, y0, z0 = loc
    diag = w + h  # overlong; clipped by the intersect box below
    bm = lib.new_bm()
    n = ceil(diag / pitch / 2)
    for family in (radians(45.0), radians(-45.0)):
        ca, sa = cos(family), sin(family)
        for i in range(-n, n + 1):
            t = i * pitch
            # rotating +X about Y by θ gives strip direction (cosθ, -sinθ) in
            # XZ; offset strip centers along the in-plane PERPENDICULAR
            px, pz = sa * t, ca * t
            ret = lib.bmesh.ops.create_cube(bm, size=1.0)
            lib.bmesh.ops.scale(bm, vec=(diag, depth, strip), verts=ret["verts"])
            rot = lib.Matrix.Rotation(family, 3, "Y")
            lib.bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=ret["verts"])
            lib.bmesh.ops.translate(bm, vec=(px, 0.0, pz), verts=ret["verts"])
    panel = lib.finalize(bm, name, mat, (x0, y0, z0))
    clip = lib.box(name + "-clip", (w, depth * 3.0, h), (x0, y0, z0))
    intersect(panel, clip)
    return panel


def grid_panel(name, w, h, loc, pitch=0.005, strip=0.001, depth=0.0012, mat=None):
    """Fine axis-aligned wire grid (the mesh layer BEHIND a lattice front).

    Vertical + horizontal strips at `pitch`, exact lengths — no booleans
    needed, so it stays cheap even at fine pitch. Same plane convention as
    lattice_panel.
    """
    x0, y0, z0 = loc
    bm = lib.new_bm()
    for axis_w, axis_h, vertical in ((w, h, True), (h, w, False)):
        n = int(axis_w / pitch)
        for i in range(n + 1):
            t = -axis_w / 2 + axis_w * i / n
            ret = lib.bmesh.ops.create_cube(bm, size=1.0)
            size = (strip, depth, axis_h) if vertical else (axis_h, depth, strip)
            off = (t, 0.0, 0.0) if vertical else (0.0, 0.0, t)
            lib.bmesh.ops.scale(bm, vec=size, verts=ret["verts"])
            lib.bmesh.ops.translate(bm, vec=off, verts=ret["verts"])
    return lib.finalize(bm, name, mat, (x0, y0, z0))


def round_well(target, name, r, depth, y_f, x, z, segs=24, mat=None):
    """Blind cylindrical recess cut into a -Y face, with a lined floor disc."""
    cutter = lib.cylinder(name + "-cut", r, depth * 2.0, "Y", (x, y_f, z), None, segs)
    lib.cut(target, cutter)
    return lib.cylinder(
        name + "-liner", r - 0.0003, depth - 0.001, "Y", (x, y_f + depth / 2, z), mat or modern("cavity"), segs
    )


def rounded_slab(name, w, d, h, r, loc=(0.0, 0.0, 0.0), mat=None, segs=7):
    """Rounded-rectangle prism (mini-PC / consumer-electronics shell).

    Footprint w x d with corner radius r, extruded to height h; base sits on
    z=loc[2]. Corner arcs get `segs` segments each.
    """
    cx = [(w / 2 - r, d / 2 - r), (-(w / 2 - r), d / 2 - r), (-(w / 2 - r), -(d / 2 - r)), (w / 2 - r, -(d / 2 - r))]
    start = [0.0, pi / 2, pi, 1.5 * pi]
    profile = []
    for (ccx, ccy), a0 in zip(cx, start):
        for i in range(segs + 1):
            a = a0 + (pi / 2) * i / segs
            profile.append((ccx + r * cos(a), ccy + r * sin(a)))
    bm = lib.new_bm()
    lo = [bm.verts.new((px, py, 0.0)) for px, py in profile]
    hi = [bm.verts.new((px, py, h)) for px, py in profile]
    nv = len(profile)
    for i in range(nv):
        j = (i + 1) % nv
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bm.faces.new(tuple(reversed(lo)))
    bm.faces.new(tuple(hi))
    return lib.finalize(bm, name, mat, loc)


def trapezoid_prism(name, w_top, w_bot, h, depth, loc=(0.0, 0.0, 0.0), mat=None):
    """D-sub-shaped trapezoid prism: XZ cross-section, extruded along Y.

    `loc` is the center of the front (-Y) face; the prism runs `depth`
    into +Y. Top edge w_top, bottom edge w_bot, height h.
    """
    x, y, z = loc
    bm = lib.new_bm()
    front = [
        bm.verts.new((x - w_bot / 2, y, z - h / 2)),
        bm.verts.new((x + w_bot / 2, y, z - h / 2)),
        bm.verts.new((x + w_top / 2, y, z + h / 2)),
        bm.verts.new((x - w_top / 2, y, z + h / 2)),
    ]
    back = [bm.verts.new((v.co.x, y + depth, v.co.z)) for v in front]
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((front[i], front[j], back[j], back[i]))
    bm.faces.new(tuple(reversed(front)))
    bm.faces.new(tuple(back))
    return lib.finalize(bm, name, mat)


def bar_vent(name, w, h, front_y, x, z, bars, target, depth=0.004, vertical=True, mat_bars=None, mat_floor=None):
    """Recessed vent: dark well cut into `target` + proud bars inside.

    The slot read comes from the dark gaps between real bars — never painted
    stripes. Bars run vertically (`vertical=True`) or horizontally.
    """
    lib.well(target, name, w, h, front_y, x, z, depth, mat=mat_floor or modern("cavity"))
    bm = lib.new_bm()
    if vertical:
        pitch = w / bars
        bw = pitch * 0.42
        for i in range(bars):
            bx = x - w / 2 + pitch * (i + 0.5)
            ret = lib.bmesh.ops.create_cube(bm, size=1.0)
            lib.bmesh.ops.scale(bm, vec=(bw, depth - 0.0012, h - 0.0024), verts=ret["verts"])
            lib.bmesh.ops.translate(bm, vec=(bx, front_y + depth / 2, z), verts=ret["verts"])
    else:
        pitch = h / bars
        bh = pitch * 0.42
        for i in range(bars):
            bz = z - h / 2 + pitch * (i + 0.5)
            ret = lib.bmesh.ops.create_cube(bm, size=1.0)
            lib.bmesh.ops.scale(bm, vec=(w - 0.0024, depth - 0.0012, bh), verts=ret["verts"])
            lib.bmesh.ops.translate(bm, vec=(x, front_y + depth / 2, bz), verts=ret["verts"])
    return lib.finalize(bm, name + "-bars", mat_bars or modern("mesh-face"))


# ------------------------------------------------------------- texture pass
# Cycles-baked AO + albedo (+roughness/metallic) into one 1024 atlas per
# variant. Albedo grain prefers the shared Midjourney-sourced material
# library at ~/scene-v2-reference/textures/ (INDEX.md; slugs used per variant
# are listed in gen_modern.TEXTURE_RULES) and falls back to procedural noise
# when a slug is absent, so the script stays self-contained.
TEXLIB = Path.home() / "scene-v2-reference" / "textures"


def texlib(slug):
    """Path to a shared library texture, or None (procedural fallback)."""
    p = TEXLIB / slug / (slug + ".png")
    return str(p) if p.exists() else None


def inject_grain(mat, img_path, blend, fac, scale, rough_var=0.0):
    """Mix tiling grain (object-space box projection) into Base Color.

    `rough_var` additionally modulates Roughness by +-rough_var around the
    material's flat value so painted metal/powder surfaces pick up the
    micro sheen variation the texture round asked for.
    """
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    base = tuple(bsdf.inputs["Base Color"].default_value)
    coord = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    s = 1.0 / scale
    mapping.inputs["Scale"].default_value = (s, s, s)
    nt.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    if img_path:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = lib.bpy.data.images.load(img_path, check_existing=True)
        tex.projection = "BOX"
        tex.projection_blend = 0.3
    else:  # library texture missing: subtle procedural noise instead
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = 60.0
        fac *= 0.5
    nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
    mix = nt.nodes.new("ShaderNodeMixRGB")
    mix.blend_type = blend
    mix.inputs["Fac"].default_value = fac
    mix.inputs["Color1"].default_value = base
    nt.links.new(tex.outputs["Color"], mix.inputs["Color2"])
    nt.links.new(mix.outputs["Color"], bsdf.inputs["Base Color"])
    if rough_var:
        base_r = bsdf.inputs["Roughness"].default_value
        sub = nt.nodes.new("ShaderNodeMath")
        sub.operation = "SUBTRACT"
        sub.inputs[1].default_value = 0.5
        nt.links.new(tex.outputs["Color"], sub.inputs[0])
        mul = nt.nodes.new("ShaderNodeMath")
        mul.operation = "MULTIPLY"
        mul.inputs[1].default_value = 2.0 * rough_var
        nt.links.new(sub.outputs["Value"], mul.inputs[0])
        add = nt.nodes.new("ShaderNodeMath")
        add.operation = "ADD"
        add.inputs[1].default_value = base_r
        nt.links.new(mul.outputs["Value"], add.inputs[0])
        nt.links.new(add.outputs["Value"], bsdf.inputs["Roughness"])


def label_material(sheet_path, crop=(0.42, 0.30, 0.14, 0.10)):
    """Generic spec-label material: crop of the labels-badges sheet.

    Microtext is unreadable by construction at atlas resolution. The label
    plate faces +/-X, so Generated coords are swizzled (y,z) -> image (u,v).
    Falls back to plain pale label stock when the sheet is missing.
    """
    mat = lib.material("modern-label", "#c9c8c1", 0.62)
    if mat.node_tree.nodes.get("LabelRows"):
        return mat
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    coord = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    comb = nt.nodes.new("ShaderNodeCombineXYZ")
    nt.links.new(coord.outputs["Generated"], sep.inputs["Vector"])
    nt.links.new(sep.outputs["Y"], comb.inputs["X"])
    nt.links.new(sep.outputs["Z"], comb.inputs["Y"])
    src_color = None
    if sheet_path:
        mapping = nt.nodes.new("ShaderNodeMapping")
        cx, cy, sw, sh = crop
        mapping.inputs["Location"].default_value = (cx, cy, 0.0)
        mapping.inputs["Scale"].default_value = (sw, sh, 1.0)
        nt.links.new(comb.outputs["Vector"], mapping.inputs["Vector"])
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = lib.bpy.data.images.load(sheet_path, check_existing=True)
        tex.extension = "CLIP"
        nt.links.new(mapping.outputs["Vector"], tex.inputs["Vector"])
        src_color = tex.outputs["Color"]
    # faint unreadable microtext rows: fract(v*rows) bands multiplied in,
    # so the sticker reads as printed spec text at any distance
    rows_m = nt.nodes.new("ShaderNodeMath")
    rows_m.name = "LabelRows"
    rows_m.operation = "MULTIPLY"
    rows_m.inputs[1].default_value = 11.0
    nt.links.new(sep.outputs["Z"], rows_m.inputs[0])
    fract = nt.nodes.new("ShaderNodeMath")
    fract.operation = "FRACT"
    nt.links.new(rows_m.outputs["Value"], fract.inputs[0])
    band = nt.nodes.new("ShaderNodeMath")
    band.operation = "LESS_THAN"
    band.inputs[1].default_value = 0.42
    nt.links.new(fract.outputs["Value"], band.inputs[0])
    faint = nt.nodes.new("ShaderNodeMath")
    faint.operation = "MULTIPLY"
    faint.inputs[1].default_value = 0.35
    nt.links.new(band.outputs["Value"], faint.inputs[0])
    dim = nt.nodes.new("ShaderNodeMixRGB")
    dim.blend_type = "MULTIPLY"
    dim.inputs["Color1"].default_value = (0.75, 0.74, 0.71, 1.0)
    dim.inputs["Color2"].default_value = (0.25, 0.25, 0.27, 1.0)
    nt.links.new(faint.outputs["Value"], dim.inputs["Fac"])
    if src_color is not None:
        base_mix = nt.nodes.new("ShaderNodeMixRGB")
        base_mix.blend_type = "MULTIPLY"
        base_mix.inputs["Fac"].default_value = 0.85
        base_mix.inputs["Color1"].default_value = (0.9, 0.9, 0.88, 1.0)
        nt.links.new(src_color, base_mix.inputs["Color2"])
        nt.links.new(base_mix.outputs["Color"], dim.inputs["Color1"])
    nt.links.new(dim.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def _join_all(exclude_materials=None):
    """Apply modifiers on every mesh object and join into one.

    bmesh-built meshes can carry uninitialized material_index attribute
    values (garbage like -30136), which silently breaks Cycles baking after
    join — every generator object has exactly one material slot, so force
    all faces to slot 0 first.
    """
    import numpy as np

    bpy = lib.bpy
    excluded = set(exclude_materials or ())
    meshes = [
        o
        for o in bpy.context.scene.collection.objects
        if o.type == "MESH" and not ({m.name for m in o.data.materials if m} & excluded)
    ]
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    bpy.ops.object.convert(target="MESH")  # applies modifiers on selection
    for o in meshes:
        n = len(o.data.polygons)
        if n:
            o.data.polygons.foreach_set("material_index", np.zeros(n, dtype=np.int32))
    bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def _new_img(name, res, srgb):
    img = lib.bpy.data.images.new(name, res, res, alpha=False)
    img.colorspace_settings.name = "sRGB" if srgb else "Non-Color"
    return img


def _bake_to(joined, img, bake_type, pass_filter=None, samples=1):
    bpy = lib.bpy
    for mat in joined.data.materials:
        nt = mat.node_tree
        node = nt.nodes.get("BakeTarget") or nt.nodes.new("ShaderNodeTexImage")
        node.name = "BakeTarget"
        node.image = img
        nt.nodes.active = node
    bpy.context.scene.cycles.samples = samples
    kw = {"type": bake_type, "margin": 4, "use_clear": True}
    if pass_filter:
        kw["pass_filter"] = pass_filter
    bpy.ops.object.bake(**kw)


def _pixels(img):
    import numpy as np

    a = np.empty(img.size[0] * img.size[1] * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(-1, 4)


def bake_textures(grain_rules, out_prefix, res=1024, ao_strength=0.68):
    """Join, smart-UV, bake albedo/AO/rough/metal, rebuild one PBR material.

    `grain_rules`: {material-name-suffix: (lib-slug, blend, factor, tile-m)}.
    Saves <out_prefix>-albedo.jpg + <out_prefix>-orm.png and rewires the
    joined mesh to a single baked material ready for GLB export.
    """
    import numpy as np

    bpy = lib.bpy
    for mat in bpy.data.materials:
        rule = grain_rules.get(mat.name.replace("modern-", "", 1))
        if rule:
            slug, blend, fac, tile, rough_var = rule
            inject_grain(mat, texlib(slug), blend, fac, tile, rough_var)
    joined = _join_all({"modern-window-glass"})
    metallics = [m.node_tree.nodes["Principled BSDF"].inputs["Metallic"].default_value for m in joined.data.materials]
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=radians(66.0), island_margin=0.002)
    bpy.ops.object.mode_set(mode="OBJECT")
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    # the box's system Blender ships without OpenImageDenoiser; leaving
    # denoising on makes every bake silently come out black
    scene.cycles.use_denoising = False
    alb = _new_img("bake-albedo", res, True)
    _bake_to(joined, alb, "DIFFUSE", {"COLOR"}, samples=1)
    rough = _new_img("bake-rough", res, False)
    _bake_to(joined, rough, "ROUGHNESS", samples=1)
    ao = _new_img("bake-ao", res, False)
    _bake_to(joined, ao, "AO", samples=48)
    # metallic has no bake pass: rewire Base Color to the metallic value and
    # re-run a diffuse color bake (materials are discarded afterwards)
    for mat, mval in zip(joined.data.materials, metallics):
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        for lnk in list(mat.node_tree.links):
            if lnk.to_node == bsdf and lnk.to_socket.name == "Base Color":
                mat.node_tree.links.remove(lnk)
        bsdf.inputs["Base Color"].default_value = (mval, mval, mval, 1.0)
        bsdf.inputs["Metallic"].default_value = 0.0
    metal = _new_img("bake-metal", res, False)
    _bake_to(joined, metal, "DIFFUSE", {"COLOR"}, samples=1)

    pa, pao, pr, pm = _pixels(alb), _pixels(ao), _pixels(rough), _pixels(metal)
    # remap AO so open faces stay clean while true recesses keep tight,
    # strong contact shading (texture-round-2 asks on all three variants)
    pao = np.clip((pao - 0.34) / 0.66, 0.0, 1.0)
    pa[:, :3] *= 1.0 - (1.0 - pao[:, :1]) * ao_strength  # AO into albedo
    alb.pixels.foreach_set(np.ascontiguousarray(pa.reshape(-1)))
    orm = _new_img("bake-orm", res, False)
    po = np.ones_like(pa)
    po[:, 0], po[:, 1], po[:, 2] = pao[:, 0], pr[:, 0], pm[:, 0]
    orm.pixels.foreach_set(np.ascontiguousarray(po.reshape(-1)))
    orm.scale(res // 4, res // 4)  # rough/metal vary slowly; shrink for size
    alb.filepath_raw = out_prefix + "-albedo.jpg"
    alb.file_format = "JPEG"
    alb.save(quality=88)
    orm.filepath_raw = out_prefix + "-orm.png"
    orm.file_format = "PNG"
    orm.save()

    final = bpy.data.materials.new("modern-baked")
    final.use_nodes = True
    nt = final.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    talb = nt.nodes.new("ShaderNodeTexImage")
    talb.image = bpy.data.images.load(out_prefix + "-albedo.jpg")
    nt.links.new(talb.outputs["Color"], bsdf.inputs["Base Color"])
    torm = nt.nodes.new("ShaderNodeTexImage")
    torm.image = bpy.data.images.load(out_prefix + "-orm.png")
    torm.image.colorspace_settings.name = "Non-Color"
    sep = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(torm.outputs["Color"], sep.inputs["Color"])
    nt.links.new(sep.outputs["Green"], bsdf.inputs["Roughness"])
    nt.links.new(sep.outputs["Blue"], bsdf.inputs["Metallic"])
    joined.data.materials.clear()
    joined.data.materials.append(final)
    return joined
