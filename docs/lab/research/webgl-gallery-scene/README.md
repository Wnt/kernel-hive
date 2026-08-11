# WebGL gallery scene v2 — research synthesis (2026-07-27)

> **Status (2026-07-28): PROMOTED.** SceneV2 now serves `/museum`,
> the compatibility route redirects there, and the former v1 museum implementation and its
> exclusive assets have been removed.

Six-angle parallel study on replacing the then-current UI 3D view (procedural box-primitive
machines, canvas textures, billboard backdrops, analytic-light soup) with a
professional-grade museum scene, built primarily with agentic coding tools
(Claude Code / Codex) plus Midjourney. Full per-angle reports with annotated
sources live next to this file:

| # | Report | Angle |
|---|--------|-------|
| 01 | [01-agentic-workflows.md](01-agentic-workflows.md) | How to drive coding agents to build good 3D scenes |
| 02 | [02-asset-pipeline.md](02-asset-pipeline.md) | Getting real 3D models: AI gen vs buy vs scan vs model; delivery |
| 03 | [03-scene-quality.md](03-scene-quality.md) | What separates pro from amateur scenes; ranked fixes for ours |
| 04 | [04-texturing.md](04-texturing.md) | PBR sourcing, AI texture gen, baking, material recipes |
| 05 | [05-retro-hardware.md](05-retro-hardware.md) | Per-machine model sourcing, CRT rendering, realism details, IP |
| 06 | [06-scene-architecture.md](06-scene-architecture.md) | Museum architecture, navigation, live streams on glTF, perf |

> **Phase 0 is DONE — see [ART-DIRECTION.md](ART-DIRECTION.md)** (2026-07-27):
> the director supplied nine reference photos (`reference/`) that **supersede
> the "dark hall, glowing screens carry the room" framing used in these
> reports.** The locked direction is a bright, flat-lit, lived-in museum room
> (fluorescent troffers + window daylight, carpet, pine, school desks). All
> technique recommendations below still stand (bake-first, IBL, AgX,
> asset-first, VideoFrameTexture, tiered updates) — only the lighting *mood*
> and the bloom-drama assumptions change. The director does not use Blender or
> other 3D tools; every Blender step must be agent-driven headless scripting
> with screenshot review.

## Historical diagnosis — why the former v1 scene read "noob"

Grounded in the pre-cutover `spa/src/three/` implementation as of this study:

1. **No real assets.** Machines are `boxGeometry` assemblies written in JSX
   (`archetypes/*.tsx`) — the documented #1 quality killer of LLM-built scenes
   ("primitive soup"). No glTF anywhere in the app.
2. **No image-based lighting.** Seven analytic lights, zero environment map.
   `metalness: 0.8` shelves with no envmap = dead grey; plastics have no sheen;
   CRT glass has nothing to reflect.
3. **Broken color pipeline.** `toneMapped={false}` + `>1` color multipliers
   (`HERO_TINT`) opt half the scene out of tone mapping — the "pasted-on
   billboard" look is a direct consequence.
4. **Albedo-only texturing.** Midjourney images used raw as diffuse; no
   roughness/normal/AO maps, so every surface has uniform, lifeless response.
5. **Amateur post stack.** Full-screen scanlines + chromatic aberration + noise
   + heavy vignette (0.82) + low bloom threshold — "cheap lighting rescued by
   loud post", inverted from how pro scenes work.
6. **Billboard architecture.** A photo of a hall behind the 3D hall, additive
   sprite god-rays, 150 firefly sparkles.
7. **Diorama scale.** Camera at y=3.15 looking over toy-sized machines instead
   of eye-level (~1.6 m) walk-through of real-world-scale (meters) exhibits.

## The converged verdict (all six studies agree)

**Asset-first, bake-first, agent-verified.** The professional pattern for every
acclaimed WebGL room/museum (Bruno Simon's my-room-in-3d, the Codrops 3D museum,
Virtual Beeb) is: model + light + **bake in Blender**, export glTF + KTX2, let
three.js mostly *display*; keep live/dynamic elements (our 30 streamed screens)
as emissive surfaces layered on the baked shell. LLM agents are excellent at the
*pipeline* (scripts, loaders, shaders, perf machinery) and bad at freehand
aesthetics — so agents assemble and verify, humans art-direct via reference
images and tuning dials, and geometry comes from assets, never from prompted
primitives.

### Target architecture

- **Blender-authored hall shell** (real-world meters), lit in Cycles, lightmaps
  baked to UV2, exported glTF; rendered basically unlit (`MeshBasicMaterial` /
  `lightMap`) at ~zero runtime cost.
- **Exhibit slots as named Empties** in the .blend (`Slot_01…`, camera-pose
  Empties per slot, metadata via glTF `extras`). The station registry keeps
  deciding *which OS* sits in *which slot* — curation moves to Blender, data
  stays in `registry/`. Adding exhibit #34 = a Blender edit, not code.
- **5–8 machine-archetype glTFs** (sourced per the split below), instanced
  chassis + one unique screen mesh per exhibit, 2 LODs each.
- **Screens:** three r173+ `VideoFrameTexture.setFrame()` fed straight from our
  existing WebCodecs decoder (we're on 0.185 — the API exists and is the fast
  path; the CanvasTexture route is ~5x slower on ANGLE). Same texture as `map`
  + `emissiveMap`; shared CRT shader (libretro crt-geom/Lottes-derived:
  barrel UV distort + scanline/phosphor mask + convergence error) patched into
  the **emissive** term so real lighting layers on top; separate
  `MeshPhysicalMaterial` glass shell (clearcoat, low roughness) that reflects
  the room via the environment map — powered-off machines become dark glass
  with reflections, which *is* the correct look.
- **Lighting:** one CC0 dark-interior HDRI or drei `<Lightformer>` rig as
  environment; delete most analytic lights; AgX tone mapping; bloom threshold
  1.0 so **only** emissive screens glow; N8AO (subtle) + light vignette; kill
  full-screen scanline/CA/noise, sprite god-rays, photo backplates, and every
  `toneMapped={false}` hack outside genuine emitters.
- **Navigation:** keep the three-mode model we half-have — idle drift
  (attract), constrained browse + always-visible exhibit index, click-to-focus
  with authored per-slot camera poses. Implement with **drei `<CameraControls>`
  (yomotsu camera-controls)**: await-able `setLookAt`, and per-input action
  remapping (`mouseButtons.left = ACTION.NONE` in control mode) properly solves
  the OrbitControls-vs-guest-input fight we currently hack around.
- **Perf spine:** tiered stream-texture updates (focused = full rate; near =
  10–15 fps; far = 1–2 fps; culled = drop frames on arrival) +
  `frameloop="demand"` with invalidate-on-frame — the client-side twin of the
  fleet's 80%→1.4% idle-CPU work. KTX2 (ETC1S albedo/lightmaps, UASTC normals),
  meshopt (not Draco — decode cost), ORM channel packing, instancing.
  Budgets: hero GLB ≤1–2 MB, scene ≤25 MB desktop / ~10 MB before-interactive
  mobile, DPR cap 1.0–1.5.

### Asset sourcing split (report 05 has the per-machine table)

- **Download free CC-BY** (attribute on a credits page): C64, Amiga 500,
  Apple II, IBM 5150+5151, VT100, 90s beige PC+CRT, early LCD, smartphone —
  ~10 of our 12 archetypes exist today at usable quality (best single source:
  Sketchfab user dark_igorek's consistent-style pack). **Archive downloads
  now** — Epic is winding down Sketchfab hosting.
- **Buy 2–3 hero upgrades** (<$100): e.g. Jim Platt C64 (19k tris, 4K PBR,
  glTF-ready); prefer Fab/CC-clean licenses. ⚠️ **TurboSquid's license
  effectively prohibits three.js/glTF web delivery** (WebGL carve-out is
  engine-locked); CGTrader RF is a gray zone (needs "not retrievable"
  packaging). Check before buying anywhere.
- **Scratch-model in agent-driven headless Blender**: SPARCstation pizza box +
  Sun CRT (marketplace gap), possibly Atari ST. Ground truth: Thingiverse
  STLs, the-blueprints.com orthos, vt100.net / minuszerodegrees.net spec dims.
- **AI 3D generation (Meshy 6 / Tripo / TRELLIS.2): background props only.**
  All 2026 comparisons agree image-to-3D smears exactly what identifies a retro
  machine (badges, keycap legends, panel lines). ⚠️ **Hunyuan3D's community
  license excludes the EU** — for self-hosted open weights use MS TRELLIS.2
  (MIT). Photogrammetry of glossy beige: skip (harvest front-panel *photos* as
  decal textures instead).
- **Midjourney's real role:** style-locked reference boards (`--sref`),
  tileable material albedos (`--tile`, un-upscaled), badge/label/poster art —
  not scene backdrops, not 3D conditioning.

### Texturing pipeline (report 04)

CC0 libraries first (Poly Haven + ambientCG — both have JSON APIs an agent can
script; HDRIs too). Bespoke albedos: Midjourney `--tile` → **DeepBump** (free,
Python CLI) for normal/height extraction; author roughness as base value + wear
masks rather than trusting extraction. Hero materials: **Blender procedural
node graphs written as `bpy` scripts** (yellowing gradients driven by
light-exposure masks — "failed retrobright" is period-authentic; AO-masked
grime; edge wear via pointiness), baked headlessly to per-model PBR sets — the
reusable, CI-able "material factory". Floor: drei `MeshReflectorMaterial`
(subtle), not SSR. Dead pool (do not plan around): Quixel Mixer (discontinued),
withpoly/Ponzu (dead), free Megascans (ended 2024), Poliigon (license bad fit
for web delivery).

### The agentic method (report 01)

1. **Art direction before code.** Midjourney reference boards (`--sref`-locked)
   + a written `ART-DIRECTION.md` (palette, materials list, lighting plan,
   camera height/FOV, real-world scale rules). Agents follow written
   constraints far better than taste; the missing target is the root cause of
   scene v1.
2. **Screenshot feedback loop, mandatory.** Named camera bookmarks via URL
   param (`?shot=…`), fixed DPR, Playwright captures (extend `tests/e2e-live/`),
   committed baselines; every visual task ends with the agent *reading* an
   actual rendered frame — the UI-side twin of our framebuffer-verification
   rule. Nobody credible reports good 3D from a blind agent.
3. **Skills + scene introspection.** Install curated three.js/R3F rule packs
   (emalorenzo/three-agent-skills; crib the visual-scorecard idea from
   majidmanzarpour/threejs-game-skills) to stop stale-API/anti-pattern output;
   optionally wire threejs-devtools-mcp for live scene-graph inspection
   (pixels say *what's wrong*, the graph says *which node*).
4. **Hybrid tuning loop.** Agents build the machinery and expose leva/lil-gui
   panels for every aesthetic parameter; the human turns dials; the agent
   persists chosen values. Text-tuning aesthetics is the slowest possible loop
   ("modality gap").
5. **Small sequential tasks, never "make it beautiful".** The documented
   failure mode of one-shot prompts is "95% done, code irreparable".
   Blender work as committed, reviewed `blender --background --python`
   scripts (deterministic, diffable) — Blender MCP has 22k stars and ~zero
   credible hands-on success reports; use it only for interactive one-offs.

## Phased plan (proposal)

- **Phase 0 — Art direction + harness** (no scene code): reference boards,
  `ART-DIRECTION.md`, screenshot harness + camera bookmarks, skills install,
  leva dev panel. Exit: agent can render/compare/report a frame.
- **Phase 1 — Clean-slate scene rewrite (DONE; promoted 2026-07-28)**
  (director's call 2026-07-27: the v1
  scene is "ugly, unusable, cluttered, twitchy" — rewrite, don't patch):
  the new `spa/src/scene/` module is mounted at `/museum`; the old route is a
  compatibility redirect and the old scene is deleted. The streaming/input layer
  (`streamClient`, `useStreamhostSession`, `useStreamControl`, WebRTC
  fallback) survives; the presentation layer does not. Skeleton landed:
  real-scale hall shell (hallSpec.ts is the dimensional source of truth),
  Lightformer-IBL-only rig, AgX, demand frameloop, CameraControls with
  eye-level clamps (no idle drift, no pointer parallax), draft slot layout
  with placeholder desks + dust-cover machines, `?shot=` bookmarks +
  `tests/e2e-live/scene-shots.mjs` harness. Exit: harness shots at every
  bookmark judged against the reference set.
- **Phase 2 — Machines become assets**: source/buy/download per the split,
  normalize in a headless-Blender pass (scale, `<Archetype>_Screen` /
  `ScreenGlass` naming, full-0–1 undistorted screen UVs), gltf-transform
  meshopt+KTX2, gltfjsx components, shared CRT screen material,
  `VideoFrameTexture` swap-in, tiered update policy. Registry mapping
  archetype→model. SPARCstation scratch-build as the pilot agent-Blender
  project.
- **Phase 3 — The hall**: Blender shell + slot Empties + Cycles bake (the
  Codrops-museum recipe: UV2 lightmaps, 4K sets, EXR→KTX2), camera-controls
  navigation + authored per-slot poses, exhibit index UI, progressive loading
  (shell → posters → models → streams).
- **Phase 4 — Set dressing + polish**: cables (catenary TubeGeometry), decals/
  badges, dust, troika placards, DoF-on-focus, mobile tier tuning,
  credits/attribution page (CC-BY obligations + trademark notice; genericize
  Apple trade dress — it's the one litigious outlier).

Each phase is a natural bounded-agent brief with the screenshot harness as its
acceptance gate.

## Key risks / cautions

- **Licenses:** TurboSquid≠web-glTF; Hunyuan3D≠EU; Sketchfab downloads may
  disappear (archive now); Poliigon embedding restrictions; Fab forbids
  redistributable raw assets (KTX2-compressed in-app use is standard practice).
- **Perf ceiling is texture upload, not geometry:** 30 unthrottled streams ≈
  GB/s of texture traffic; the tiered update policy is not optional on mobile.
- **Baked = static:** bake the architecture only; machines keep
  contact/accumulative shadows so the select-animation still works.
- **Agent blindness:** no visual claim without a rendered frame; no freehand
  primitive geometry; no giant one-shot rewrites.
