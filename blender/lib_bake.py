"""Cycles bake pipeline for the classic-desks generators (--textured export).

Turns the flat-material geometry into a single baked-atlas GLB:
Smart-UV atlas -> Cycles bakes (diffuse color with library grain composited,
AO, pointiness) -> numpy compose (AO shading + faint edge wear) -> one
Principled material with the baked albedo. Screen-glass materials keep their
glossy flat shading and stay out of the atlas.

Grain sources come from the shared Midjourney-sourced material library at
~/scene-v2-reference/textures/ (see its INDEX.md; files stay outside the
repo). Each grain is composited via BOX projection in object space and
color-corrected toward the lib.shared() palette tone by an overlay mix, so a
missing library file degrades gracefully to the flat palette color.
Library files used: abs-beige-clean.png (clean ABS shells), abs-beige-
yellowed.png (dirtier body/keycap tones), abs-charcoal.png (dark plastics,
drive faces), metal-powdercoat.png (folded-steel covers).

Import-guarded like lib.py: CI lints without Blender.
"""

import os
from math import radians

import lib

try:  # only present inside Blender's bundled python
    import bpy
    import numpy as np
except ImportError:  # plain python (ruff/CI): definitions only, never run
    bpy = None
    np = None

TEX_LIB = os.path.expanduser("~/scene-v2-reference/textures")

# material name -> (library grain file, overlay factor). Tone stays the
# palette color; the grain modulates it. Unlisted materials bake flat.
# Texture-round polish (judge notes, round5-tex): cooler grey-ivory read —
# yellowed overlays dialed down so aging stays subtle, not khaki.
GRAIN = {
    "shared-abs": ("abs-beige-clean/abs-beige-clean.png", 0.34),
    "shared-abs-light": ("abs-beige-clean/abs-beige-clean.png", 0.30),
    "shared-abs-warm": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.36),
    "shared-abs-grey": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.32),
    "shared-recess": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.28),
    "shared-recess-deep": ("abs-charcoal/abs-charcoal.png", 0.35),
    "shared-dark": ("abs-charcoal/abs-charcoal.png", 0.30),
    # Institutional set-dressing props (gen_props). The available shared MJ
    # library has no upholstery/paper scans, so those use the closest restrained
    # family at low strength; metal and PVC use their direct library families.
    "shared-steel": ("metal-powdercoat/metal-powdercoat.png", 0.34),
    "shared-steel-light": ("metal-powdercoat/metal-powdercoat.png", 0.28),
    "shared-vinyl": ("abs-charcoal/abs-charcoal.png", 0.16),
    "shared-cable": ("abs-charcoal/abs-charcoal.png", 0.12),
    "shared-paper": ("abs-beige-clean/abs-beige-clean.png", 0.10),
    "shared-cardboard": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.16),
    "furniture-burgundy": ("abs-charcoal/abs-charcoal.png", 0.14),
    "furniture-orange-plywood": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.22),
    "furniture-plywood-edge": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.18),
    "furniture-task-blue": ("abs-charcoal/abs-charcoal.png", 0.12),
    "furniture-dark-wood": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.25),
    "furniture-dark-wood-edge": ("abs-charcoal/abs-charcoal.png", 0.16),
    # Archive-wall cartons use the clean/yellowed case families at low
    # strength; their period graphics are modeled as separate geometry.
    "archive-card": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.18),
    "archive-paper": ("abs-beige-clean/abs-beige-clean.png", 0.12),
    "cd-keycap-black": ("abs-charcoal/abs-charcoal.png", 0.40),
    "cd-keycap-grey": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.32),
    "cd-drive-face": ("abs-charcoal/abs-charcoal.png", 0.40),
    "cd-steel-warm": ("metal-powdercoat/metal-powdercoat.png", 0.40),
    "cd-badge-label": (None, 0.0),  # procedural label text rows
    # display-fleet families (gen_homecrt / gen_lcd / gen_compact)
    "hc-dark": ("abs-charcoal/abs-charcoal.png", 0.38),
    "hc-dark-deep": ("abs-charcoal/abs-charcoal.png", 0.34),
    "lcd-shell": ("abs-charcoal/abs-charcoal.png", 0.45),
    "lcd-bezel": ("abs-charcoal/abs-charcoal.png", 0.40),
    "lcd-deep": ("abs-charcoal/abs-charcoal.png", 0.35),
    "lcd-btn": ("abs-charcoal/abs-charcoal.png", 0.40),
    # HARDWARE-MATRIX case variants
    "case-silver": ("metal-powdercoat/metal-powdercoat.png", 0.30),
    "case-silver-light": ("metal-powdercoat/metal-powdercoat.png", 0.26),
    "case-graphite": ("metal-powdercoat/metal-powdercoat.png", 0.40),
    "case-graphite-light": ("abs-charcoal/abs-charcoal.png", 0.36),
    "case-black": ("abs-charcoal/abs-charcoal.png", 0.42),
    "case-black-deep": ("abs-charcoal/abs-charcoal.png", 0.35),
    "case-warm-grey": ("metal-powdercoat/metal-powdercoat.png", 0.34),
    "case-warm-grey-light": ("abs-beige-clean/abs-beige-clean.png", 0.28),
    # Matrix display shells use the same MJ library families.
    "display-sun-grey": ("abs-beige-clean/abs-beige-clean.png", 0.32),
    "display-home-grey": ("abs-beige-clean/abs-beige-clean.png", 0.32),
    "display-home-light": ("abs-beige-clean/abs-beige-clean.png", 0.28),
    "display-home-dark": ("abs-charcoal/abs-charcoal.png", 0.40),
    "display-home-deep": ("abs-charcoal/abs-charcoal.png", 0.34),
    # input-device matrix variants
    "input-xt-shell": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.30),
    "input-xt-key-light": ("abs-beige-clean/abs-beige-clean.png", 0.28),
    "input-xt-key-dark": ("abs-charcoal/abs-charcoal.png", 0.22),
    "input-silver": ("metal-powdercoat/metal-powdercoat.png", 0.24),
    "input-silver-light": ("metal-powdercoat/metal-powdercoat.png", 0.20),
    "input-graphite": ("abs-charcoal/abs-charcoal.png", 0.28),
    "input-black-shell": ("abs-charcoal/abs-charcoal.png", 0.28),
    "input-black-key": ("abs-charcoal/abs-charcoal.png", 0.24),
    "input-black-well": ("abs-charcoal/abs-charcoal.png", 0.20),
    "input-pale-shell": ("abs-beige-clean/abs-beige-clean.png", 0.22),
    "input-pale-key": ("abs-beige-clean/abs-beige-clean.png", 0.20),
    "input-work-shell": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.28),
    "input-work-key": ("abs-beige-clean/abs-beige-clean.png", 0.25),
    "input-work-dark": ("abs-beige-yellowed/abs-beige-yellowed.png", 0.22),
}
GLASS = {"shared-glass", "cd-green-glass", "cd-blue-glass", "hc-glass", "lcd-glass"}
GRAIN_SCALE = 40.0  # box-projection repeats per meter — fine molded grain


def _augment_material(mat, atlas, grain_scale=None, grain_mul=1.0, rough_variation=0.0):
    """Wire grain/label into Base Color and add the atlas bake target node."""
    nt = mat.node_tree
    bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
    base = tuple(bsdf.inputs["Base Color"].default_value)
    spec = GRAIN.get(mat.name)
    if mat.name.startswith("archive-pine-"):
        # Calm honey pine: fine straight grain that merges into the board tone
        # at room distance, plus a few genuinely dark knots. The first shelf
        # bake used a broad, distorted wave at full contrast and read as zebra
        # stripes; keep both contrast and distortion deliberately restrained.
        coords = nt.nodes.new("ShaderNodeTexCoord")
        mapping = nt.nodes.new("ShaderNodeMapping")
        nt.links.new(coords.outputs["Object"], mapping.inputs["Vector"])
        wave = nt.nodes.new("ShaderNodeTexWave")
        wave.wave_type = "BANDS"
        wave.bands_direction = "X" if "-x-" in mat.name else "Z"
        wave.inputs["Scale"].default_value = grain_scale or 90.0
        wave.inputs["Distortion"].default_value = 0.45
        wave.inputs["Detail"].default_value = 2.0
        nt.links.new(mapping.outputs["Vector"], wave.inputs["Vector"])
        grain_ramp = nt.nodes.new("ShaderNodeValToRGB")
        grain_ramp.color_ramp.elements[0].position = 0.34
        grain_ramp.color_ramp.elements[0].color = (
            base[0] * 0.74,
            base[1] * 0.72,
            base[2] * 0.70,
            1.0,
        )
        grain_ramp.color_ramp.elements[1].position = 0.66
        grain_ramp.color_ramp.elements[1].color = (
            min(base[0] * 1.06, 1.0),
            min(base[1] * 1.05, 1.0),
            min(base[2] * 1.04, 1.0),
            1.0,
        )
        nt.links.new(wave.outputs["Color"], grain_ramp.inputs["Fac"])
        grain_mix = nt.nodes.new("ShaderNodeMixRGB")
        grain_mix.blend_type = "MIX"
        grain_mix.inputs["Fac"].default_value = min(0.12, grain_mul * 0.5)
        grain_mix.inputs["Color1"].default_value = base
        nt.links.new(grain_ramp.outputs["Color"], grain_mix.inputs["Color2"])

        knot_cells = nt.nodes.new("ShaderNodeTexVoronoi")
        knot_cells.distance = "EUCLIDEAN"
        knot_cells.inputs["Scale"].default_value = 1.8
        nt.links.new(mapping.outputs["Vector"], knot_cells.inputs["Vector"])
        knots = nt.nodes.new("ShaderNodeValToRGB")
        knots.color_ramp.elements[0].position = 0.035
        knots.color_ramp.elements[0].color = (1.0, 1.0, 1.0, 1.0)
        knots.color_ramp.elements[1].position = 0.075
        knots.color_ramp.elements[1].color = (0.0, 0.0, 0.0, 1.0)
        nt.links.new(knot_cells.outputs["Distance"], knots.inputs["Fac"])
        knot_mix = nt.nodes.new("ShaderNodeMixRGB")
        knot_mix.blend_type = "MIX"
        knot_mix.inputs["Color2"].default_value = (0.254, 0.102, 0.021, 1.0)
        nt.links.new(grain_mix.outputs["Color"], knot_mix.inputs["Color1"])
        nt.links.new(knots.outputs["Color"], knot_mix.inputs["Fac"])
        nt.links.new(knot_mix.outputs["Color"], bsdf.inputs["Base Color"])
    elif spec and spec[0] is not None:
        path = os.path.join(TEX_LIB, spec[0])
        if os.path.exists(path):
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image = bpy.data.images.load(path, check_existing=True)
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
            if rough_variation:
                # Preserve material response through the atlas bake: the MJ
                # grain modulates roughness around each source material's real
                # Principled value, instead of every joined prop becoming one
                # uniformly matte surface.
                base_rough = bsdf.inputs["Roughness"].default_value
                ramp = nt.nodes.new("ShaderNodeValToRGB")
                ramp.color_ramp.elements[0].color = (max(0.0, base_rough - rough_variation),) * 3 + (1.0,)
                ramp.color_ramp.elements[1].color = (min(1.0, base_rough + rough_variation),) * 3 + (1.0,)
                nt.links.new(tex.outputs["Color"], ramp.inputs["Fac"])
                nt.links.new(ramp.outputs["Color"], bsdf.inputs["Roughness"])
    elif spec and mat.name == "cd-badge-label":
        # era-plausible generic label: restrained horizontal unreadable
        # text bars (judge round5-tex: line-based pseudo-typography)
        wave = nt.nodes.new("ShaderNodeTexWave")
        wave.wave_type = "BANDS"
        wave.bands_direction = "Z"
        wave.inputs["Scale"].default_value = 420.0
        wave.inputs["Distortion"].default_value = 3.0
        wave.inputs["Detail"].default_value = 1.0
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        ramp.color_ramp.elements[0].position = 0.40
        ramp.color_ramp.elements[1].position = 0.52
        mix = nt.nodes.new("ShaderNodeMixRGB")
        mix.blend_type = "MIX"
        mix.inputs["Color1"].default_value = base
        mix.inputs["Color2"].default_value = (0.16, 0.15, 0.14, 1.0)
        nt.links.new(wave.outputs["Fac"], ramp.inputs["Fac"])
        nt.links.new(ramp.outputs["Color"], mix.inputs["Fac"])
        nt.links.new(mix.outputs["Color"], bsdf.inputs["Base Color"])
    for n in nt.nodes:
        n.select = False
    node = nt.nodes.new("ShaderNodeTexImage")
    node.image = atlas
    node.select = True
    nt.nodes.active = node
    return bsdf


def _bake(kind, **kw):
    bpy.ops.object.bake(type=kind, margin=4, **kw)


def _grab(img, size, debug_stage=None):
    px = np.empty(size * size * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    if debug_stage and os.environ.get("CD_BAKE_DEBUG"):
        print(f"[bake-debug] {debug_stage}: min={px.min():.3f} max={px.max():.3f} mean={px.mean():.4f}", flush=True)
        img.filepath_raw = f"/tmp/cd-bake-{debug_stage}.png"
        img.file_format = "PNG"
        img.save()
    return px.reshape(size, size, 4)


def bake_export(
    out_path,
    size=1024,
    ao_samples=24,
    tone=None,
    ao_floor=0.55,
    grain_mul=1.0,
    wear_amt=0.085,
    ao_curve=(0.0, 1.0),
    wear=None,
    rough=0.56,
    grain_scale=None,
    rough_texture=False,
    rough_variation=0.0,
):
    """Join solids, UV-atlas, bake, compose, export a textured GLB.

    Per-generator texture-round knobs (judge-driven, union of the home-micro
    and display families): `tone` multiplies the final albedo (warm/lighten
    shifts), `ao_floor` sets the deepest recess shade, `ao_curve` remaps AO
    so tight recesses darken while open faces stay clean, `grain_mul` scales
    every GRAIN overlay factor, `grain_scale` overrides the box-projection
    repeats per meter (finer micrograin), `wear_amt` scales the pointiness
    edge-wear pass (`wear` is its legacy alias), `rough` sets the baked
    material roughness. `rough_texture` also bakes the source materials'
    roughness (including optional MJ-driven `rough_variation`) into a second
    atlas so paper, PVC, ABS, and powder-coat retain distinct light response.
    """
    if wear is not None:
        wear_amt = wear
    scn = bpy.context.scene
    scn.render.engine = "CYCLES"
    scn.cycles.device = "CPU"
    # this box's Blender build ships without OpenImageDenoise: with denoising
    # left on, every bake silently comes back BLACK — keep it off
    scn.cycles.use_denoising = False
    solids, glasses = [], []
    for obj in list(scn.objects):
        if obj.type != "MESH":
            continue
        names = {m.name for m in obj.data.materials if m}
        (glasses if names & GLASS else solids).append(obj)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in solids:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = solids[0]
    bpy.ops.object.convert(target="MESH")  # applies bevels on all selected
    # bmesh-built meshes can carry garbage material_index values that break
    # Cycles baking after join — every object has one slot, force slot 0
    for obj in solids:
        n = len(obj.data.polygons)
        if n:
            obj.data.polygons.foreach_set("material_index", np.zeros(n, dtype=np.int32))
    bpy.ops.object.join()
    joined = bpy.context.view_layer.objects.active
    joined.name = "case-baked"
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=radians(66.0), island_margin=0.004)
    bpy.ops.object.mode_set(mode="OBJECT")

    atlas = bpy.data.images.new("atlas", size, size, alpha=False)
    bsdfs = []
    for mat in joined.data.materials:
        bsdfs.append(_augment_material(mat, atlas, grain_scale, grain_mul, rough_variation))
    scn.cycles.samples = 1
    _bake("DIFFUSE", pass_filter={"COLOR"})
    albedo = _grab(atlas, size, "albedo")
    rough_px = None
    if rough_texture:
        _bake("ROUGHNESS")
        rough_px = _grab(atlas, size, "roughness")
    scn.cycles.samples = ao_samples
    _bake("AO")
    ao = _grab(atlas, size, "ao")
    # pointiness -> EMIT for faint edge wear (convex edges catch light wear)
    for mat in joined.data.materials:
        nt = mat.node_tree
        out = next(n for n in nt.nodes if n.type == "OUTPUT_MATERIAL")
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        emit = nt.nodes.new("ShaderNodeEmission")
        nt.links.new(geo.outputs["Pointiness"], emit.inputs["Color"])
        nt.links.new(emit.outputs["Emission"], out.inputs["Surface"])
    scn.cycles.samples = 1
    _bake("EMIT")
    pointy = _grab(atlas, size)

    # stronger AO so recesses survive the museum's flat light (round5-tex);
    # ao_curve remaps AO so tight recesses darken while open faces stay clean
    lo, hi = ao_curve
    ao_n = np.clip((ao[..., :3] - lo) / (hi - lo), 0.0, 1.0)
    shade = ao_floor + (1.0 - ao_floor) * ao_n
    wear_px = np.clip((pointy[..., :3] - 0.60) * 2.0, 0.0, 1.0) * wear_amt
    final = np.clip(albedo[..., :3] * shade + wear_px, 0.0, 1.0)
    if tone is not None:
        final = np.clip(final * np.asarray(tone, dtype=np.float32), 0.0, 1.0)
    px = np.ones((size, size, 4), dtype=np.float32)
    px[..., :3] = final
    atlas.pixels.foreach_set(px.ravel())

    baked = bpy.data.materials.new("baked-case")
    baked.use_nodes = True
    bb = baked.node_tree.nodes["Principled BSDF"]
    tex = baked.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = atlas
    baked.node_tree.links.new(tex.outputs["Color"], bb.inputs["Base Color"])
    bb.inputs["Roughness"].default_value = rough
    if rough_px is not None:
        rough_atlas = bpy.data.images.new("roughness-atlas", size, size, alpha=False)
        rough_out = np.ones((size, size, 4), dtype=np.float32)
        rough_out[..., :3] = rough_px[..., :3]
        rough_atlas.pixels.foreach_set(rough_out.ravel())
        rough_atlas.colorspace_settings.name = "Non-Color"
        rough_tex = baked.node_tree.nodes.new("ShaderNodeTexImage")
        rough_tex.image = rough_atlas
        baked.node_tree.links.new(rough_tex.outputs["Color"], bb.inputs["Roughness"])
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


def maybe_bake_export(out_path, **bake_kw):
    """--textured in the argv tail bakes; otherwise flat export (lib)."""
    import sys

    if "--textured" in sys.argv:
        bake_export(out_path, **bake_kw)
    else:
        lib.export_glb(out_path)
