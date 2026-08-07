"""Shared bpy helpers for the foreign-architecture home-micro generators.

Used by gen_atarist.py / gen_amstradcpc.py / gen_acorn.py — wedge
keyboard-computers whose identity lives in their key fields (colored accent
keys, red Acorn F-rows), vent grain, and integrated drive/datacorder blocks.
`blender/lib.py` is read-only shared infrastructure; everything
home-micro-specific lives here. Import-guarded like lib.py so the repo
Python gate parses without Blender.
"""

import os
import sys
from math import hypot, radians
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (Blender does not put the script dir on sys.path)

U = 0.01905  # standard key pitch (m) — 0.75 in, shared by all three machines


class KeyField:
    """Collects tapered keycaps into one bmesh per material key.

    These machines need per-key color grouping (CPC red/green/blue accents,
    Acorn's red F1-F12): finalize() emits one merged mesh object per color,
    keeping draw calls low while every cap stays real lofted geometry.
    `origin_x` is the meter position of key-unit x=0 (left edge of field).
    """

    def __init__(self, origin_x, taper=0.0050, lip=0.0008, gap=0.0009):
        self.bms = {}
        self.x0 = origin_x
        self.taper = taper
        self.lip = lip
        self.gap = gap

    def _bm(self, key):
        if key not in self.bms:
            self.bms[key] = lib.new_bm()
        return self.bms[key]

    def cap(self, matkey, xu, cy, z, wu, h, du=1.0, skew=0.0):
        """One keycap: chamfered frustum with a sunken-top lip (dished read).

        xu/wu in key units from the field origin; cy/z in meters; `skew`
        shifts the top toward +Y — the lean of the Atari ST function keys.
        """
        kw = wu * U - self.gap
        kd = du * U - self.gap
        t = self.taper
        cx = self.x0 + (xu + wu / 2.0) * U
        lib.loft_into(
            self._bm(matkey),
            "Z",
            [
                (0.0, kw, kd, 0.0),
                (h * 0.30, kw, kd, 0.0),
                (h, kw - t, kd - t - 0.0006, skew - 0.0008),
                (h - self.lip, kw - t - 0.0034, kd - t - 0.0040, skew - 0.0008),
            ],
            (cx, cy, z),
        )

    def row(self, widths, x0_u, cy, z, h, mat, overrides=None, du=1.0, skew=0.0):
        """Lay a key row. widths: key widths in units, negative = gap.

        overrides maps position index -> material key (accent colors).
        Returns the x (units) after the last key.
        """
        xu = x0_u
        for i, wu in enumerate(widths):
            if wu < 0:
                xu += -wu
                continue
            self.cap((overrides or {}).get(i, mat), xu, cy, z, wu, h, du, skew)
            xu += wu
        return xu

    def finalize(self, prefix, mats):
        """Emit one object per material key; mats: matkey -> bpy material."""
        for key, bm in self.bms.items():
            lib.finalize(bm, f"{prefix}-keys-{key}", mats[key])


def normalize_material_indices():
    """Zero every mesh polygon's material_index before join/bake.

    bmesh-built meshes can carry uninitialized material_index garbage (the
    lib_modern finding: values like -30136) which silently breaks Cycles
    bakes after join. Every generator object has exactly one material slot,
    so forcing slot 0 is always correct.
    """
    import numpy as np

    for o in lib.bpy.context.scene.collection.objects:
        if o.type == "MESH":
            n = len(o.data.polygons)
            if n:
                o.data.polygons.foreach_set("material_index", np.zeros(n, dtype=np.int32))


def clip(target, clipper):
    """Boolean-INTERSECT `target` with `clipper`, apply, delete the clipper."""
    mod = target.modifiers.new("clip", "BOOLEAN")
    mod.operation = "INTERSECT"
    mod.solver = "EXACT"
    mod.object = clipper
    lib.bpy.context.view_layer.objects.active = target
    lib.bpy.ops.object.modifier_apply(modifier=mod.name)
    lib.bpy.data.objects.remove(clipper, do_unlink=True)


def rib_field(name, w, d, z_floor, rib_h, pitch, rib_w, center, angle=0.0, mat=None):
    """Raised parallel ribs filling a w x d plan rectangle at (center) —
    the Atari ST's diagonal vent grain, CPC front ridges. Ribs run along Y,
    rotated `angle` degrees around Z, then clipped to the rectangle so the
    grain is real geometry with a clean border. Floor plane z_floor.
    """
    cx, cy = center
    span = hypot(w, d) + pitch
    n = int(span / pitch) + 1
    bm = lib.new_bm()
    for i in range(n):
        x = (i - (n - 1) / 2.0) * pitch
        ret = lib.bmesh.ops.create_cube(bm, size=1.0)
        lib.bmesh.ops.scale(bm, vec=(rib_w, span, rib_h), verts=ret["verts"])
        lib.bmesh.ops.translate(bm, vec=(x, 0.0, 0.0), verts=ret["verts"])
    if angle:
        rot = lib.Matrix.Rotation(radians(angle), 3, "Z")
        lib.bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=rot, verts=bm.verts)
    obj = lib.finalize(bm, name, mat, (cx, cy, z_floor + rib_h / 2.0))
    box = lib.box(name + "-clip", (w, d, rib_h * 3.0), (cx, cy, z_floor + rib_h / 2.0))
    clip(obj, box)
    return obj


def tooth_row(name, count, pitch, tooth, start, mat=None):
    """Serrated vent teeth along +X (the CPC's rear-edge serration).

    tooth=(w,d,h) per tooth; start=(x,y,z) center of the first tooth.
    """
    x0, y, z = start
    items = [(tooth, (x0 + i * pitch, y, z)) for i in range(count)]
    return lib.multi_box(name, items, mat)


def top_recess(target, name, w, d, x, y, z_top, depth=0.0025, mat=None):
    """Shallow recess sunk into a top surface + liner floor plate.

    Cut walls keep the host material; the floor plate carries the recess
    tone — same pattern as gen_keyboard's lock-light panel. Returns floor.
    """
    lib.cut(target, lib.multi_box(name + "-cut", [((w, d, depth * 2.0), (x, y, z_top))]))
    return lib.box(
        name + "-floor",
        (w - 0.0006, d - 0.0006, 0.0014),
        (x, y, z_top - depth + 0.0007),
        mat or lib.shared("recess"),
    )


def slot_bank(target, name, n, pitch, slot, first, floor_pad=0.004, mat=None):
    """Cut a bank of n parallel top slots + one warm floor plate under them.

    slot=(w,d,h) cutter size, first=(x,y,z) center of slot 0; slots advance
    along +X. Real cut openings — never painted-on vent lines.
    """
    x0, y, z = first
    cuts = [(slot, (x0 + i * pitch, y, z)) for i in range(n)]
    lib.cut(target, lib.multi_box(name + "-cuts", cuts))
    return lib.box(
        name + "-floor",
        ((n - 1) * pitch + slot[0] + 0.004, slot[1] + 0.002, 0.0015),
        (x0 + (n - 1) * pitch / 2.0, y, z - floor_pad),
        mat or lib.shared("recess-deep"),
    )


def side_slot(target, name, side_x, w_y, h, y, z, depth=0.010, mat=None):
    """Disk slot cut into a left/right side face + dark inner liner box.

    side_x: the face plane (+-W/2, sign gives the side). The liner sits just
    inside so the opening shows real interior geometry.
    """
    sgn = 1.0 if side_x > 0 else -1.0
    lib.cut(target, lib.multi_box(name + "-cut", [((depth * 2.0, w_y, h), (side_x, y, z))]))
    return lib.box(
        name + "-liner",
        (depth, w_y + 0.004, h + 0.004),
        (side_x - sgn * (depth / 2.0 + 0.0006), y, z),
        mat or lib.shared("recess-deep"),
    )


def led(name, x, y, z, color="#3fae4a", size=(0.004, 0.003, 0.0026)):
    """Tiny proud indicator lamp (power/disc LED)."""
    return lib.box(name, size, (x, y, z), lib.material("led-" + color, color, 0.35))


def slab_on(name, x0, x1, y0, y1, z_of, th, mat=None, segs=2):
    """Slab whose UNDERSIDE follows z_of(y) — for sloped-deck recess cutters,
    plaques and label plates on wedge tops (loft along Y)."""
    rings = []
    for i in range(segs + 1):
        y = y0 + (y1 - y0) * i / segs
        rings.append((y - y0, x1 - x0, th, z_of(y) + th / 2.0))
    return lib.loft(name, "Y", rings, ((x0 + x1) / 2.0, y0, 0.0), mat)


# ---------------------------------------------------------------------------
# Texture pass (shared by all three generators).
#
# Body: join all non-key objects, smart-UV, Cycles-bake DIFFUSE color + AO
# into a 1024 atlas, then composite a color-corrected grain map from the
# shared Midjourney texture library (~/scene-v2-reference/textures/, see its
# INDEX.md; abs-beige-yellowed / abs-beige-clean / abs-charcoal are used by
# the generators) — falling back to procedural value noise when the library
# is absent so the script stays self-contained.
# Keys: the KeyField meshes get a deterministic grid UV (every lofted cap is
# exactly 14 faces) and a numpy-built atlas: per-cap base color, grain, and a
# tiny generic glyph block per cap top — unreadable at close zoom by design.
# ---------------------------------------------------------------------------

CAP_FACES = 14  # faces per KeyField cap loft (3 bands x 4 + bottom + top)


def _srgb8(lin):
    c = max(0.0, min(1.0, lin))
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def _base_color(mat):
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    r, g, b, _ = bsdf.inputs["Base Color"].default_value
    return _srgb8(r), _srgb8(g), _srgb8(b)


def _grain(size, path, strength, tile=1):
    """Grain multiplier field (mean 1.0) from a library map or noise.

    `tile` repeats a downscaled copy NxN across the atlas so the features
    read as fine ABS micrograin instead of broad blotches.
    """
    import numpy as np

    if path and os.path.exists(path):
        img = lib.bpy.data.images.load(path)
        sub = max(8, size // tile)
        img.scale(sub, sub)
        px = np.array(img.pixels[:], dtype=np.float32).reshape(sub, sub, 4)[:, :, :3]
        lib.bpy.data.images.remove(img)
        px = np.tile(px, (tile + 1, tile + 1, 1))[:size, :size]
        g = 1.0 + (px - px.mean()) * strength  # centered, contrast-tamed
    else:  # procedural fallback: two-octave value noise
        rng = np.random.default_rng(7)
        base = rng.random((size // 8, size // 8)).repeat(8, 0).repeat(8, 1)
        fine = rng.random((size, size))
        g = (1.0 + (0.6 * base + 0.4 * fine - 0.5) * strength * 0.6)[:, :, None].repeat(3, 2)
    return np.clip(g, 0.55, 1.45)


def _color_xform(arr, tint, desat, value):
    """Shared albedo transform: desaturate toward luminance, tint, scale."""
    import numpy as np

    lum = arr.mean(axis=-1, keepdims=True)
    out = (arr * (1.0 - desat) + lum * desat) * np.asarray(tint, dtype=np.float32) * value
    return np.clip(out, 0.0, 1.0)


def _tex_material(name, image, rough):
    mat = lib.bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rough
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def uv_fullface(obj):
    """Map every quad of `obj` to the full [0,1] image — decal panels."""
    uv = obj.data.uv_layers.new(name="decal").data
    corners = ((0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0))
    for poly in obj.data.polygons:
        for k, li in enumerate(poly.loop_indices):
            uv[li].uv = corners[k % 4]


def decal_material(name, arr, size, rough=0.55):
    """Material carrying a numpy-drawn decal image (packed into the GLB)."""
    return _tex_material(name, _np_image(name + "-img", size, arr), rough)


def _select_only(obj):
    for o in lib.bpy.context.view_layer.objects:
        o.select_set(False)
    obj.select_set(True)
    lib.bpy.context.view_layer.objects.active = obj


def _np_image(name, size, arr):
    """Pack a HxWx3 float array (sRGB-encoded) as a scene image."""
    import numpy as np

    img = lib.bpy.data.images.new(name, size, size, alpha=False)
    rgba = np.ones((size, size, 4), dtype=np.float32)
    rgba[:, :, :3] = np.clip(arr, 0.0, 1.0)
    img.pixels.foreach_set(rgba.ravel())
    img.pack()
    return img


def _bake_body(body, size, samples):
    """Cycles-bake DIFFUSE color + AO of `body` into two size^2 arrays."""
    import numpy as np

    sc = lib.bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = samples
    # The box's Blender ships without OpenImageDenoiser; with denoising left
    # on, every bake silently comes out BLACK (same finding as lib_modern.py).
    sc.cycles.use_denoising = False
    out = {}
    for kind, filt in (("diff", {"COLOR"}), ("ao", None)):
        img = lib.bpy.data.images.new(f"bake-{kind}", size, size, alpha=False)
        nodes = []
        for slot in body.material_slots:
            nt = slot.material.node_tree
            node = nt.nodes.new("ShaderNodeTexImage")
            node.image = img
            nt.nodes.active = node
            nodes.append((nt, node))
        _select_only(body)
        # margin MUST stay below the UV island spacing or island colors
        # bleed into neighbours (the green-LED halo of the first bake).
        if filt:
            lib.bpy.ops.object.bake(type="DIFFUSE", pass_filter=filt, margin=2)
        else:
            lib.bpy.ops.object.bake(type="AO", margin=2)
        px = np.array(img.pixels[:], dtype=np.float32).reshape(size, size, 4)[:, :, :3]
        out[kind] = px
        for nt, node in nodes:
            nt.nodes.remove(node)
        lib.bpy.data.images.remove(img)
    return out["diff"], out["ao"]


def _keys_atlas(keys, size, grain, legend=True, key_mul=None):
    """Grid-UV the joined key mesh and build its numpy atlas.

    `key_mul` maps material names to a value multiplier (e.g. darkening the
    modifier caps for stronger two-tone separation).
    """
    import numpy as np
    from math import ceil, sqrt

    mesh = keys.data
    n = len(mesh.polygons) // CAP_FACES
    cols = max(1, ceil(sqrt(n)))
    cell = 1.0 / cols
    uv = mesh.uv_layers.new(name="atlas").data
    atlas = np.ones((size, size, 3), dtype=np.float32) * 0.5
    cpx = size // cols
    for poly in mesh.polygons:
        cap, part = divmod(poly.index, CAP_FACES)
        cu, cv = (cap % cols) * cell, (cap // cols) * cell
        # Inset boxes stay well inside the cell so mip levels do not blend
        # neighbouring cap colors across cell borders.
        if part == CAP_FACES - 1:  # top face -> inner box of the cell
            box = (cu + 0.16 * cell, cv + 0.36 * cell, cu + 0.84 * cell, cv + 0.84 * cell)
        else:  # sides/bottom -> lower strip of the same cell
            box = (cu + 0.16 * cell, cv + 0.10 * cell, cu + 0.84 * cell, cv + 0.28 * cell)
        corners = ((box[0], box[1]), (box[2], box[1]), (box[2], box[3]), (box[0], box[3]))
        for k, li in enumerate(poly.loop_indices):
            uv[li].uv = corners[k % 4]
    # Paint cells: per-cap base color x grain, plus a tiny glyph block.
    mats = [slot.material for slot in keys.material_slots]
    for cap in range(n):
        mat = mats[mesh.polygons[cap * CAP_FACES].material_index]
        color = np.array(_base_color(mat), dtype=np.float32)
        color *= (key_mul or {}).get(mat.name, 1.0)
        x0, y0 = (cap % cols) * cpx, (cap // cols) * cpx
        atlas[y0 : y0 + cpx, x0 : x0 + cpx] = color
        if legend:
            gx, gy = x0 + int(cpx * 0.22), y0 + int(cpx * 0.66)
            gw, gh = max(3, cpx // 5), max(2, cpx // 7)
            lum = float(color.mean())
            glyph = 0.18 if lum > 0.45 else 0.86
            atlas[gy : gy + gh, gx : gx + gw] = color * 0.42 + glyph * 0.58
    return atlas * grain


def texture_model(
    prefix,
    grain_path,
    grain_strength=0.10,
    grain_tile=3,
    ao_k=1.15,
    ao_floor=0.45,
    tint=(1.0, 1.0, 1.0),
    desat=0.0,
    value=1.0,
    body_size=1024,
    keys_size=512,
    body_rough=0.56,
    keys_rough=0.5,
    samples=48,
    legend=True,
    key_mul=None,
):
    """Full texture pass over the current scene (see module comment).

    tint/desat/value: shared albedo transform applied to BOTH atlases (the
    art-director tone corrections on top of the lib.shared palette).
    ao_k/ao_floor: shade = clip(1 - ao_k*(1-ao), ao_floor, 1) — deep in the
    crevices, clean on open panels.
    """
    import numpy as np

    objs = list(lib.bpy.context.scene.collection.objects)
    for o in objs:  # join drops non-active modifiers: apply bevels first
        if o.modifiers:
            _select_only(o)
            for m in list(o.modifiers):
                lib.bpy.ops.object.modifier_apply(modifier=m.name)
    key_objs = [o for o in objs if o.name.startswith(f"{prefix}-keys-")]
    # LEDs / logo chips / decal panels stay OUT of the bake: tiny saturated
    # islands only bleed into neighbours, and they read better dedicated.
    skip = [o for o in objs if o not in key_objs and ("led" in o.name or "chip" in o.name or "decal" in o.name)]
    body_objs = [o for o in objs if o not in key_objs and o not in skip]
    _select_only(body_objs[0])
    for o in body_objs:
        o.select_set(True)
    lib.bpy.ops.object.join()
    body = lib.bpy.context.view_layer.objects.active
    body.data.uv_layers.new(name="atlas")
    lib.bpy.ops.object.mode_set(mode="EDIT")
    lib.bpy.ops.mesh.select_all(action="SELECT")
    lib.bpy.ops.uv.smart_project(angle_limit=1.15, island_margin=0.006)
    lib.bpy.ops.object.mode_set(mode="OBJECT")
    diff, ao = _bake_body(body, body_size, samples)
    grain_b = _grain(body_size, grain_path, grain_strength, grain_tile)
    shade = np.clip(1.0 - ao_k * (1.0 - ao), ao_floor, 1.0)
    body_img = _np_image("body-atlas", body_size, _color_xform(diff, tint, desat, value) * shade * grain_b)
    body.data.materials.clear()
    body.data.materials.append(_tex_material("body-tex", body_img, body_rough))
    if key_objs:
        _select_only(key_objs[0])
        for o in key_objs:
            o.select_set(True)
        lib.bpy.ops.object.join()
        keys = lib.bpy.context.view_layer.objects.active
        grain_k = _grain(keys_size, grain_path, grain_strength * 0.7, grain_tile)
        atlas = _keys_atlas(keys, keys_size, grain_k, legend, key_mul)
        keys_img = _np_image("keys-atlas", keys_size, _color_xform(atlas, tint, desat, value))
        keys.data.materials.clear()
        keys.data.materials.append(_tex_material("keys-tex", keys_img, keys_rough))


def export_glb_textured(path):
    """GLB export like lib.export_glb but with JPEG-packed images (size)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    kwargs = dict(filepath=path, export_format="GLB", export_apply=True, export_yup=True, export_image_format="JPEG")
    try:
        lib.bpy.ops.export_scene.gltf(export_jpeg_quality=82, **kwargs)
    except TypeError:  # older exporter without the quality knob
        lib.bpy.ops.export_scene.gltf(**kwargs)
    print("exported", path)
