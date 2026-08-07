# Hall shell lightmaps

These six grayscale JPEGs contain Cycles-baked diffuse lighting and ambient
occlusion for the production N=37 hall (`12.8 × 19.0 × 2.8 m`). They multiply
the shell's indirect light, so the tiled albedo and roughness maps remain
independent.

Regenerate from the repository root:

```sh
blender --background --python blender/gen_hallbake.py -- \
  --out-dir spa/public/assets/textures/hall-lightmaps \
  --size 1024 --samples 16 --ao-samples 16 --jpeg-quality 86
```

The bake rig mirrors the current layout algorithm's N=37 dimensions, troffer
pattern, decade row centers, window bays, and archive-wall run. Runtime code in
`hallLightmaps.ts` checks the dimensions before loading these assets; changed
layouts such as `?hallTest=50` render without baked maps until regenerated.
Use `?bakedLight=0` for the unbaked A/B baseline.
