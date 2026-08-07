"""Bake dimension-keyed GI/AO multipliers for the scene-v2 hall shell.

This rig is intentionally coupled to the production N=37 layout produced by
``spa/src/scene/hallLayout.ts`` on 2026-07-29:

    width=12.8 m, depth=19.0 m, height=2.8 m, tile strip=1.6 m

The row proxy positions below mirror the layout algorithm's five decade
sections.  They are deliberately simple occluders: their job is to ground the
static shell, not duplicate the runtime furniture.  Non-matching runtime
dimensions skip these maps in ``hallLightmaps.ts``.

Run headlessly from the repository root:

    blender --background --python blender/gen_hallbake.py -- \
      --out-dir spa/public/assets/textures/hall-lightmaps

Cycles bakes diffuse direct+indirect lighting and AO separately.  Denoising is
disabled because OIDN is unavailable in the house Blender build; sample count
plus a three-pixel Blender compositor Gaussian blur controls residual noise.
"""

from __future__ import annotations

import argparse
import math
import sys
import tempfile
from pathlib import Path

try:
    import bpy
    import numpy as np
except ImportError:  # Keep the repo's host-side ruff gate importable.
    bpy = None
    np = None


WIDTH = 12.8
DEPTH = 19.0
HEIGHT = 2.8
TILE_STRIP_DEPTH = 1.6
TROFFER_PITCH = 2.4
TROFFER_SIZE = (1.2, 0.6)
DIM_KEY = "12p8x19p0"

# N=37 section row centers from computeHall: [6, 8, 9, 7, 7] exhibits.
DESK_ROW_Z = (6.95, 4.85, 3.75, 1.55, 0.45, -1.75, -2.85, -5.05, -6.15)

SURFACES = (
    "floor",
    "ceiling",
    "back-wall",
    "front-wall",
    "pine-wall",
    "window-wall",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        default="spa/public/assets/textures/hall-lightmaps",
    )
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--samples", type=int, default=96)
    parser.add_argument("--ao-samples", type=int, default=64)
    parser.add_argument("--jpeg-quality", type=int, default=86)
    parser.add_argument("--surface", choices=SURFACES)
    return parser.parse_args(sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else [])


def material(name: str, color: tuple[float, float, float, float], emission=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = 0.88
    if emission:
        bsdf.inputs["Emission Color"].default_value = color
        bsdf.inputs["Emission Strength"].default_value = emission
    return mat


def box(name, location, scale, mat, *, hide_bake=False):
    bpy.ops.mesh.primitive_cube_add(location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (scale[0] / 2, scale[1] / 2, scale[2] / 2)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    obj.hide_render = hide_bake
    return obj


def quad(name, vertices, uvs, mat):
    mesh = bpy.data.meshes.new(f"{name}-mesh")
    # Vertex lists are written in runtime UV order; reversed winding points
    # every receiver into the room, matching Three.js FrontSide shell planes.
    mesh.from_pydata(vertices, [], [(0, 3, 2, 1)])
    mesh.update()
    uv_layer = mesh.uv_layers.new(name="UVMap")
    for loop in mesh.loops:
        uv_layer.data[loop.index].uv = uvs[loop.vertex_index]
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj


def build_receivers(mats):
    x0, x1 = -WIDTH / 2, WIDTH / 2
    y0, y1 = -DEPTH / 2, DEPTH / 2
    return {
        # Runtime floor UV: u +X, v -runtime-Z.
        "floor": quad(
            "bake-floor",
            [(x0, y1, 0), (x1, y1, 0), (x1, y0, 0), (x0, y0, 0)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["carpet"],
        ),
        # Runtime ceiling UV: u +X, v +runtime-Z.
        "ceiling": quad(
            "bake-ceiling",
            [(x0, y0, HEIGHT), (x1, y0, HEIGHT), (x1, y1, HEIGHT), (x0, y1, HEIGHT)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["ceiling"],
        ),
        # Wall UVs duplicate the transformed PlaneGeometry directions in
        # HallShell: back +X, front -X, pine +Z, window -Z; all v +height.
        "back-wall": quad(
            "bake-back-wall",
            [(x0, y0, 0), (x1, y0, 0), (x1, y0, HEIGHT), (x0, y0, HEIGHT)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["plaster"],
        ),
        "front-wall": quad(
            "bake-front-wall",
            [(x1, y1, 0), (x0, y1, 0), (x0, y1, HEIGHT), (x1, y1, HEIGHT)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["plaster"],
        ),
        "pine-wall": quad(
            "bake-pine-wall",
            [(x1, y0, 0), (x1, y1, 0), (x1, y1, HEIGHT), (x1, y0, HEIGHT)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["pine"],
        ),
        "window-wall": quad(
            "bake-window-wall",
            [(x0, y1, 0), (x0, y0, 0), (x0, y0, HEIGHT), (x0, y1, HEIGHT)],
            [(0, 0), (1, 0), (1, 1), (0, 1)],
            mats["plaster"],
        ),
    }


def build_emitters_and_proxies(mats):
    min_x = math.ceil((-WIDTH / 2 + 1.2) / TROFFER_PITCH)
    max_x = math.floor((WIDTH / 2 - 1.2) / TROFFER_PITCH)
    min_y = math.ceil((-DEPTH / 2 + 1.2) / TROFFER_PITCH)
    max_y = math.floor((DEPTH / 2 - 1.2) / TROFFER_PITCH)
    for yi in range(min_y, max_y + 1):
        for xi in range(min_x, max_x + 1):
            box(
                f"troffer-{xi}-{yi}",
                (xi * TROFFER_PITCH, yi * TROFFER_PITCH, HEIGHT - 0.018),
                (TROFFER_SIZE[0] - 0.08, TROFFER_SIZE[1] - 0.08, 0.018),
                mats["troffer"],
            )

    window_count = math.ceil(DEPTH / 2.4)
    bay_width = DEPTH / window_count
    sill_h = 0.85
    win_h = HEIGHT - sill_h - 0.45
    for index in range(window_count):
        y = -DEPTH / 2 + bay_width * (index + 0.5)
        box(
            f"window-{index}",
            (-WIDTH / 2 + 0.022, y, sill_h + win_h / 2),
            (0.018, bay_width - 0.14, win_h),
            mats["window"],
        )

    # Continuous row slabs are a bounded proxy for desks + machines.  Their
    # narrow depth leaves the cross aisles open so floor occlusion stays soft.
    for index, y in enumerate(DESK_ROW_Z):
        box(f"desk-top-{index}", (0, y, 0.72), (9.9, 0.72, 0.055), mats["desk"])
        box(f"machine-band-{index}", (0, y - 0.08, 0.98), (9.45, 0.34, 0.46), mats["putty"])

    # Runtime ArchiveWall: 12 bays on the rear wall with a box skyline.
    pitch = 0.97
    bay_count = max(6, math.floor((WIDTH - 0.9) / pitch))
    run_width = (bay_count - 1) * pitch
    for bay in range(bay_count):
        x = -run_width / 2 + bay * pitch
        box(f"archive-bay-{bay}", (x, -DEPTH / 2 + 0.26, 1.08), (0.87, 0.46, 2.16), mats["pine"])
        box(
            f"archive-box-{bay}",
            (x, -DEPTH / 2 + 0.27, 2.33),
            (0.7, 0.38, 0.34 + (bay % 3) * 0.045),
            mats["cardboard"],
        )


def prepare_scene(args):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.image_settings.file_format = "PNG"
    scene.render.resolution_percentage = 100
    scene.world = bpy.data.worlds.new("hall-world")
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.78, 0.84, 0.91, 1)
    background.inputs["Strength"].default_value = 0.18

    mats = {
        "carpet": material("carpet", (0.078, 0.10, 0.125, 1)),
        "ceiling": material("ceiling", (0.80, 0.79, 0.75, 1)),
        "plaster": material("plaster", (0.88, 0.85, 0.80, 1)),
        "pine": material("pine", (0.58, 0.31, 0.09, 1)),
        "desk": material("desk", (0.62, 0.40, 0.18, 1)),
        "putty": material("putty", (0.60, 0.56, 0.45, 1)),
        "cardboard": material("cardboard", (0.52, 0.30, 0.12, 1)),
        "troffer": material("troffer-emitter", (1.0, 0.88, 0.70, 1), emission=22.0),
        "window": material("window-emitter", (0.66, 0.82, 1.0, 1), emission=7.5),
    }
    receivers = build_receivers(mats)
    build_emitters_and_proxies(mats)

    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 4
    scene.cycles.diffuse_bounces = 3
    scene.render.bake.margin = 8
    return scene, receivers


def pixels(image):
    values = np.empty(len(image.pixels), dtype=np.float32)
    image.pixels.foreach_get(values)
    return values.reshape((image.size[1], image.size[0], 4))


def compositor_blur(scene, image, temp_dir, label):
    """Run one bake pass through Blender's three-pixel Gaussian compositor."""
    scene.use_nodes = True
    nodes = scene.node_tree.nodes
    nodes.clear()
    source = nodes.new("CompositorNodeImage")
    source.image = image
    blur = nodes.new("CompositorNodeBlur")
    blur.filter_type = "GAUSS"
    blur.size_x = 3
    blur.size_y = 3
    output = nodes.new("CompositorNodeOutputFile")
    output.base_path = temp_dir
    output.file_slots[0].path = f"{label}-blur-"
    output.format.file_format = "OPEN_EXR"
    output.format.color_depth = "32"
    scene.node_tree.links.new(source.outputs["Image"], blur.inputs["Image"])
    scene.node_tree.links.new(blur.outputs["Image"], output.inputs["Image"])

    original_engine = scene.render.engine
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x = image.size[0]
    scene.render.resolution_y = image.size[1]
    scene.render.resolution_percentage = 100
    if scene.camera is None:
        bpy.ops.object.camera_add(location=(0, 0, 20))
        scene.camera = bpy.context.object
    bpy.ops.render.render()
    scene.render.engine = original_engine
    result_path = Path(temp_dir) / f"{label}-blur-0001.exr"
    blurred = bpy.data.images.load(str(result_path), check_existing=False)
    return blurred


def bake_pass(scene, receiver, name, size, samples, pass_type):
    image = bpy.data.images.new(
        f"{name}-{pass_type.lower()}",
        width=size,
        height=size,
        alpha=False,
        float_buffer=True,
    )
    image.colorspace_settings.name = "Non-Color"
    nodes = receiver.data.materials[0].node_tree.nodes
    target = nodes.new("ShaderNodeTexImage")
    target.name = f"bake-target-{pass_type}"
    target.image = image
    nodes.active = target

    bpy.ops.object.select_all(action="DESELECT")
    receiver.select_set(True)
    bpy.context.view_layer.objects.active = receiver
    scene.cycles.samples = samples
    if pass_type == "DIFFUSE":
        bpy.ops.object.bake(
            type="DIFFUSE",
            pass_filter={"DIRECT", "INDIRECT"},
            margin=8,
            use_clear=True,
        )
    else:
        bpy.ops.object.bake(type="AO", margin=8, use_clear=True)
    nodes.remove(target)
    return image


def save_multiplier(scene, receiver, surface, out_dir, args, temp_dir):
    print(f"[hallbake] {surface}: diffuse {args.samples} samples", flush=True)
    lighting = bake_pass(scene, receiver, surface, args.size, args.samples, "DIFFUSE")
    blurred = compositor_blur(scene, lighting, temp_dir, f"{surface}-light")
    print(f"[hallbake] {surface}: AO {args.ao_samples} samples", flush=True)
    ao = bake_pass(scene, receiver, surface, args.size, args.ao_samples, "AO")
    blurred_ao = compositor_blur(scene, ao, temp_dir, f"{surface}-ao")

    lit = pixels(blurred)[..., :3]
    occ = pixels(blurred_ao)[..., 0]
    luma = lit[..., 0] * 0.2126 + lit[..., 1] * 0.7152 + lit[..., 2] * 0.0722
    positive = luma[luma > 1e-5]
    scale = np.percentile(positive, 94) if positive.size else 1.0
    normalized = np.clip(luma / max(scale, 1e-5), 0.0, 1.0)
    # Bright-room discipline: preserve directional falloff and contacts while
    # keeping the darkest baked multiplier gently lifted.
    multiplier = 0.58 + 0.42 * np.sqrt(normalized)
    multiplier *= 0.86 + 0.14 * np.clip(occ, 0.0, 1.0)
    multiplier = np.clip(multiplier, 0.52, 1.0)

    result = bpy.data.images.new(
        f"hall-{DIM_KEY}-{surface}",
        width=args.size,
        height=args.size,
        alpha=False,
        float_buffer=False,
    )
    rgba = np.empty((args.size, args.size, 4), dtype=np.float32)
    rgba[..., :3] = multiplier[..., None]
    rgba[..., 3] = 1.0
    result.pixels.foreach_set(rgba.reshape(-1))
    result.file_format = "JPEG"
    result.filepath_raw = str(out_dir / f"hall-{DIM_KEY}-{surface}.jpg")
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.image_settings.quality = args.jpeg_quality
    result.save()
    print(
        f"[hallbake] wrote {result.filepath_raw} "
        f"(min={multiplier.min():.3f}, mean={multiplier.mean():.3f}, max={multiplier.max():.3f})",
        flush=True,
    )


def main():
    if bpy is None or np is None:
        raise RuntimeError("run this generator inside Blender")
    args = parse_args()
    if args.size < 256 or args.size > 2048 or args.size & (args.size - 1):
        raise ValueError("--size must be a power of two from 256 through 2048")
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    scene, receivers = prepare_scene(args)
    with tempfile.TemporaryDirectory(prefix="hallbake-") as temp_dir:
        surfaces = (args.surface,) if args.surface else SURFACES
        for surface in surfaces:
            save_multiplier(
                scene,
                receivers[surface],
                surface,
                out_dir,
                args,
                temp_dir,
            )


if __name__ == "__main__":
    main()
