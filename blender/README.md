# blender/ — parametric retro-hardware pipeline (scene v2)

Era-accurate hardware modeled **from internet image references** via headless
Blender. The director never opens Blender: agents write `bpy` scripts, render
candidates through the museum-lighting lineup, and the director judges PNGs in
the LAN review app (`:5197`).

## How it works

1. **Reference research first.** Each generator's docstring records the real
   dimensions it uses **with source URLs** (drive-bay faceplate specs, CRT
   datasheets, keyboard spec sheets, Wikimedia Commons photos). Proportions are
   never invented.
2. **Generate** (Blender 4.0, headless — real meters, front faces +Z in glTF):

   ```sh
   blender -b --python blender/gen_tower.py -- --variant A \
     --out ~/scene-v2-reference/parametric/tower-a.glb
   ```

   Generators: `gen_tower.py` (mid-90s beige mid-tower), `gen_crt.py`
   (~14" 4:3 CRT), `gen_keyboard.py` (~102-key layout massing). Each takes
   `--variant A|B|C` (three tuned silhouettes) and `--out <path.glb>`.
3. **Screenshot** through the museum lineup. Copy the GLB to
   `spa/public/assets/models/v2/dev/<name>.glb` (gitignored), then:

   ```sh
   cd ~/e2e && node v2-shot1.mjs \
     'http://127.0.0.1:5199/museum2?lineup=dev:<name>:<realHeightMeters>&shot=lineupOne' \
     /tmp/param-<name>.png
   ```

   Pass the model's **real height** so the plinth shot stays 1:1. The agent
   READS every screenshot and iterates the generator — first drafts are always
   wrong somewhere (proportions, bay sizes, bezel depth).
4. **Install review candidates** once a subject's three variants convince:
   `~/scene-v2-reference/review/candidates/param-<subject>/` with
   `a.png`/`b.png`/`c.png` + `meta.json` (`{"question": …}`). The review app
   picks them up automatically.

## Conventions (`lib.py`)

- Build space: Blender +Z up, model front faces **-Y**, base at z=0; the glTF
  exporter's +Y-up conversion turns that into **front = +Z, base at y=0** —
  the contract `spa/src/scene/NormalizedModel.tsx` normalizes against.
- Flat materials only for massing (hex + roughness, aged-beige palette from
  `docs/lab/research/webgl-gallery-scene/ART-DIRECTION.md`); textures come in
  a later texturing pass. Generators draw from `lib.SHARED_MATERIALS` /
  `lib.shared(key)` — an aged-ABS family with per-part tone variation, warm
  **grey** recess interiors, and near-black reserved for true dark parts
  (screen glass, badge text). Never paint depth.
- **Depth is modeled, never painted** (iteration-2 rule after the director's
  "cartoonish outlines" verdict): openings are boolean cavities lined with
  `pocket` (open-front warm-grey liner) or `well` (blind lined recess);
  faces sit INSIDE cavities behind a few-mm reveal; buttons are proud solids
  standing in wells.
- Helpers: `box`, `multi_box` (single-mesh cutters/backing plates), `loft`
  (CRT tube tapers, keycap frusta), `wedge_box`, `bulged_panel` (geometric
  sphere-section CRT face), `cylinder`, `pocket`/`well` (lined recesses),
  `bevel` (add after booleans), `cut` (boolean difference), `export_glb`,
  `parse_args`.
- Every file stays import-guarded (`bpy = None` fallback) so the repo Python
  gate (`ruff check` / `ruff format --check`) parses without Blender; the
  scripts only execute geometry when run inside `blender -b`.

## Outputs

- Canonical GLBs: `~/scene-v2-reference/parametric/` (outside git).
- Dev copies for the lineup: `spa/public/assets/models/v2/dev/` — `*.glb`
  is gitignored there; only curated models get promoted into git later.
