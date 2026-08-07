# What separates professional three.js scenes from amateur ones — and how to close the gap for the Kernel Hive museum hall

> **Historical v1 assessment (2026-07-27).** The `Museum.tsx` and `Effects.tsx`
> implementation analyzed below was deleted when SceneV2 became `/museum` on
> 2026-07-28. The report is retained as research, not as current-code guidance.

Scene facts referenced below come from the actual code: `spa/src/three/Museum.tsx` (7 analytic lights, 1024px shadow map on one directional, `HERO_TINT = Color(1.12, 1.07, 0.99)` with `toneMapped={false}`, additive billboard shafts, 150 Sparkles, albedo-only `meshStandardMaterial` everywhere, `dpr [1,1.8]`, fov 45) and `spa/src/three/Effects.tsx` (SMAA + Bloom + ChromaticAberration + Scanline + Noise + Vignette `darkness 0.82`).

## Part 1 — Ranked changes, highest visual ROI first

### 1. Add image-based lighting (the single biggest transform for material response)

The scene has zero environment map. Seven analytic lights cannot produce the specular response that makes PBR materials read as "real": beige plastic sheen, brushed-metal shelf reflections, CRT glass glints. This is the #1 amateur tell — `metalness: 0.8` on the shelves (Museum.tsx:310) with no envmap produces the classic dull/dark metal because metals get essentially all their appearance from reflections. With an environment map, PBR materials can be lit convincingly with *no* analytic lights at all ([sbcode Environment tutorial](https://sbcode.net/react-three-fiber/environment/)).

Concrete technique:
- `<Environment>` from drei with a **file-hosted** HDRI (the `preset` prop "is not meant to be used in production environments and may fail as it relies on CDNs" — [drei Environment docs](https://drei.docs.pmnd.rs/staging/environment)). Self-host via `@pmndrs/assets` or a [Poly Haven](https://polyhaven.com/hdris) CC0 HDRI — a dark interior/night one for this hall.
- Better for art direction here: a **custom environment built from `<Lightformer>` children** — rect/circle/ring emitters rendered once into an off-buffer cube camera ([drei docs](https://drei.docs.pmnd.rs/staging/environment), [three.js forum on Lightformers](https://discourse.threejs.org/t/more-natural-ways-to-see-any-objects-with-lightformers-of-environments/47684)). Place warm strip Lightformers overhead (matching the "track lighting" story) and a faint cool one behind-left (replacing the rim directional). "It will act like a real light without the expense, you can have as many as you want."
- Control response per-material with `envMapIntensity`, and globally with `environmentIntensity` (three ≥0.163; you're on 0.185).
- Then **delete most analytic lights**: keep one shadow-casting directional (or none after baking, see #3) + the environment. Fewer, motivated lights is the professional pattern; a pile of colored ambient/hemi/point fills is the amateur one ([Understanding Three.js Lighting](https://dev.to/outriding/understanding-threejs-lighting-a-concise-reference-3e8b)).

### 2. Fix the color/tone pipeline and stop opting out of it

R3F already gives you the correct default pipeline: `outputColorSpace = SRGBColorSpace` + `ACESFilmicToneMapping` ([R3F Canvas docs](https://docs.pmnd.rs/react-three-fiber/api/canvas), [r3f issue #1547](https://github.com/pmndrs/react-three-fiber/issues/1547)); since r152 three.js has proper color management on by default ([Don McCurdy, three.js discourse: r152 color management updates](https://discourse.threejs.org/t/updates-to-color-management-in-three-js-r152/50791)). The current scene then punches holes in it:

- **`toneMapped={false}` on the backplate, banners, shafts, glow pools, picture-light bars** — each of these renders in a *different* color pipeline than the lit scene, which is exactly why they look pasted-on. The only legitimate use of `toneMapped:false` is the selective-bloom pattern (see #7): "For this to work `toneMapped` has to be false on the materials, because it would otherwise clamp colors between 0 and 1 again" — i.e. it exists for HDR emitters, not for "keep my poster bright" ([react-postprocessing Bloom docs](https://react-postprocessing.docs.pmnd.rs/effects/bloom)).
- **`HERO_TINT = Color(1.12, 1.07, 0.99)`** — a >1 multiplier to fight the tone mapper is exposure hacking. Professionals fix exposure once (`renderer.toneMappingExposure`, or the HDRI/Lightformer intensities) and let every surface go through the same transform.
- **Tone mapper choice is now a real decision**: ACES desaturates strongly (bright saturated colors are "impossible to output" under ACES — [Khronos PBR Neutral press release](https://www.khronos.org/news/press/khronos-pbr-neutral-tone-mapper-released-for-true-to-life-color-rendering-of-3d-products)); **AgX** (added r160, Blender 4.0's default look — [three.js #27362](https://github.com/mrdoob/three.js/issues/27362), [r160 release](https://github.com/mrdoob/three.js/releases/tag/r160)) handles saturated emissive colors (your CRT screens!) far more gracefully; **NeutralToneMapping** (Khronos PBR Neutral) preserves base color faithfully for product-like accuracy ([model-viewer comparison page](https://modelviewer.dev/examples/tone-mapping)). Side-by-side gallery: [Tone Mapping Overview thread](https://discourse.threejs.org/t/tone-mapping-overview/75204). For a dark hall full of glowing saturated screens, **AgX is the strongest candidate** — it's designed not to skew hue as emitters clip.
- Keep the r152 texture rules: color maps `SRGBColorSpace`, normal/roughness/AO/data maps linear (default) ([discourse r152 thread](https://discourse.threejs.org/t/updates-to-color-management-in-three-js-r152/50791)). The code already does this for color maps — good.

### 3. Bake the hall in Blender (the confirmed common thread of every acclaimed "room/museum" scene)

This is the pattern behind essentially all admired WebGL interiors: **model + UV + light + bake in Blender, export glTF + compressed textures, three.js just displays `MeshBasicMaterial`**. Confirmed in:
- Bruno Simon's [my-room-in-3d](https://my-room-in-3d.vercel.app/) ([repo](https://github.com/brunosimon/my-room-in-3d), [GIGAZINE writeup](https://gigazine.net/gsc_news/en/20210913-my-room-in-3d/)) and his Three.js Journey **Portal Scene chapter** — lessons "Creating a scene in Blender", "Baking and exporting the scene", "Importing and optimizing the scene" ([threejs-journey.com](https://threejs-journey.com/)).
- Codrops' **immersive 3D museum** by Andrew Woan: entire scene baked, "converting to MeshBasicMaterial in Three.js for better performance"; 4096px bakes split into ~9 texture sets, EXR intermediates, KTX2 delivery ([Codrops: Building a Fully-Featured 3D World in the Browser with Blender and Three.js](https://tympanus.net/codrops/2025/04/08/3d-world-in-the-browser-with-blender-and-three-js/)).
- [Wawa Sensei: How to Bake Lighting with Blender for Three.js](https://wawasensei.dev/tuto/how-to-bake-lighting) — "Real-time rendering engines like Three.js can't process complex lighting the same way Blender's Cycles does"; demo repo [wass08/r3f-baking](https://github.com/wass08/r3f-baking).
- [tchayen: Baked lighting in r3f](https://tchayen.github.io/posts/baked-lighting-in-r3f) — full gotcha list (dual UVs, margins, normals).
- [Codrops: Cyberpunk-inspired Three.js scene with Blender](https://tympanus.net/codrops/2023/03/22/cyberpunk-inspired-three-js-scene-with-javascript-and-blender/).

For this scene specifically: the hall shell (floor, walls, shelf racks, frames, plinths) is static — bake global illumination, soft shadows and the warm spot pools into lightmaps. The Cycles bake gives you bounce light, contact darkening and penumbra quality that no real-time budget touches, at ~zero runtime cost. The 33 machines stay dynamic (they animate on select), lit by the #1 environment map — this hybrid is exactly the portal-scene pattern (baked room + live elements). Full workflow in Part 2.

### 4. Ambient occlusion — the "grounding" the scene is missing

Nothing in the scene has AO, so machines float visually on their shelves. Two complementary fixes:
- **N8AO** as the first post effect: an SSAO "with an emphasis on temporal stability and artist control", pmndrs-postprocessing-compatible, with a half-resolution mode giving a 2–4× perf boost ([n8ao npm](https://www.npmjs.com/package/n8ao), [demo](https://n8programs.com/n8ao/), [HBAO vs N8AO forum comparison](https://discourse.threejs.org/t/new-ambient-occlusion-example-hbao-vs-n8ao/58847)). Keep it *subtle* — pros use AO you feel, not see.
- **Baked AO** in the Blender pass for the static hall (comes free with #3), and per-archetype AO maps if the machines move to glTF assets.

### 5. Professional shadow strategy: accumulate/bake instead of one soft-starved 1024px map

A single 1024px shadow map over a ~15m hall gives blocky, crawling shadows — an instant amateur read. Options, in order of quality-per-cost for a mostly-static scene:
- **`<AccumulativeShadows>` + `<RandomizedLight>`** under the exhibit rows: "a planar, Y-up oriented shadow-catcher that can accumulate into soft shadows and has zero performance impact after all frames have accumulated"; RandomizedLight "jiggles a set of lights around, creating realistic raycast-like shadows and ambient occlusion" ([drei AccumulativeShadows docs](https://drei.docs.pmnd.rs/staging/accumulative-shadows)). Re-trigger accumulation after layout changes.
- **`<ContactShadows>`** per machine — cheap blurred ground-contact, render-once for static frames ([drei docs](https://drei.docs.pmnd.rs/staging/contact-shadows); usage survey in [sbcode shadows](https://sbcode.net/react-three-fiber/shadows/)).
- **`<BakeShadows>`** to freeze the shadow map for static frames ([drei](https://github.com/pmndrs/drei)).
- Or eliminate runtime shadows for the hall entirely via #3's lightmaps.

### 6. Materials: from albedo-only boxes to full PBR + the right glass

Current archetypes are box geometry + flat color/canvas-texture `meshStandardMaterial` (e.g. `BeigeIbmPcCRT.tsx`), with only a `bumpMap` vent. What pros do:
- **Roughness variation is the big one.** Uniform roughness is the flattest possible response; real beige plastic has fingerprints, sheen gradients, texture grain. A tiling roughness map (even 512px, from [Poly Haven](https://polyhaven.com/textures)/AmbientCG) + subtle normal map transforms it. Consistent **texel density** across exhibits keeps detail believable ([RebusFarm texel density guide](https://rebusfarm.net/blog/texel-density-basics-every-artist-should-know), [Beyond Extent deep dive](https://www.beyondextent.com/deep-dives/deepdive-texeldensity)).
- **CRT glass = `MeshPhysicalMaterial`**: a slightly curved glass shell over the screen surface with `clearcoat`, low `roughness`, and either `transmission` or plain low-opacity + envmap reflection. "In the real world, transparent objects reflect light and show glare… traditional opacity … appears ghostly" ([Codrops: Transparent Glass and Plastic in Three.js](https://tympanus.net/codrops/2021/10/27/creating-the-effect-of-transparent-glass-and-plastic-in-three-js/), [MeshPhysicalMaterial docs](https://threejs.org/docs/pages/MeshPhysicalMaterial.html), [sbcode glass transmission](https://sbcode.net/threejs/glass-transmission/)). The environment map from #1 is what makes this pay off — a faint warm window/light reflection sliding across CRT glass as the camera drifts is the single most "museum photograph" detail available. `clearcoat` also sells 90s molded plastic.
- **Matcaps** are the cheap alternative where full PBR isn't worth it (background props): zero lights needed, one texture encodes material+lighting ([Spectrum of Materials overview](https://www.ramijames.com/learn-threejs/building-blocks/the-spectrum-of-materials)).

### 7. Post-processing taste: subtract the mood stack, keep discipline

The current stack (CA + Scanline + Noise + Vignette 0.82 + bloom threshold 0.6) is the textbook amateur configuration — global "vibe" filters applied to everything. The professional stack for a scene like this is: **SMAA → N8AO (subtle) → Bloom (strict) → light Vignette**, optionally DoF while an exhibit is selected.

- **Bloom discipline**: raise `luminanceThreshold` to 1 and drive bloom *only* from genuine emitters — screens and lamp fixtures with `emissiveIntensity > 1` + `toneMapped={false}`. "Set luminanceThreshold={1} to ensure only the materials you pick will glow" ([react-postprocessing Bloom docs](https://react-postprocessing.docs.pmnd.rs/effects/bloom)). This makes CRTs *glow* while nothing else blooms — precisely the museum-of-glowing-screens look, and it makes the current threshold-0.6 shimmer problem (documented in Effects.tsx comments) disappear by construction.
- **Scanlines belong on the CRT, not the camera.** A full-screen Scanline pass says "Instagram filter"; scanlines/aperture-grille in the *screen material shader* (or baked into the poster textures) say "CRT physics". Same for chromatic aberration — real CA lives in the phosphor/glass, not on the whole frame; if kept at all, keep it barely measurable.
- You're already on the right library: pmndrs/postprocessing merges compatible effects into a single fullscreen pass — "makes it possible to combine many effects without the performance penalties of traditional pass chaining", unlike three's stock EffectComposer ([Effect Merging wiki](https://github.com/pmndrs/postprocessing/wiki/Effect-Merging), [pmndrs/postprocessing](https://github.com/pmndrs/postprocessing)). Settings-tuning walkthrough: [Postprocessing Settings in React Three Fiber](https://www.balazsfarago.dev/blog/postprocessing-react-three-fibe).

### 8. Replace the billboard "god rays" and glow sprites

Additive billboard planes with `toneMapped={false}` (LightShafts, glow pools, picture-light bars) are the most identifiable amateur artifact in the scene — they don't respond to camera angle and double-brighten over each other. Options in ascending effort:
- Delete the shafts and let **bloom from real emitters + baked light pools** (from #3) carry the atmosphere. Most pro museum scenes do exactly this.
- Cone-geometry fake volumetrics with a fresnel/depth-fade shader (soft edges, view-dependent) — the standard middle ground.
- Real raymarched volumetric light as a post pass — Maxime Heckel's [On Shaping Light: Real-Time Volumetric Lighting with Post-Processing and Raymarching](https://blog.maximeheckel.com/posts/shaping-light-volumetric-lighting-with-post-processing-and-raymarching/) is the definitive web writeup, built for exactly this "overlay volumetric light on an existing R3F scene" case.
- Keep Sparkles dust but cut counts/opacity ~50% and remove `toneMapped:false`; dust should be subliminal.

### 9. Composition, scale and set dressing that sells "museum"

- **Real-world units.** three.js/glTF convention is meters, and physically-based lighting assumes it ([three.js forum on units](https://discourse.threejs.org/t/feature-idea-world-scale-or-unit-scale/49063)). Make a CRT 0.4m wide, shelf height ~0.9m, camera at human eye height (~1.6m) instead of the current 3.15 — an eye-level dolly through correctly-scaled machines *feels* like standing in a museum; the current elevated wide view feels like a diorama.
- **FOV discipline**: fov 45 is reasonable (perspective camera default film format is 35mm — [PerspectiveCamera docs](https://threejs.org/docs/pages/PerspectiveCamera.html)); professional interior/product framing usually sits at 35–50, and *stays constant* — resist widening to fit content, move the camera instead.
- **Set dressing**: the details that sell a "living museum" are exactly the ones a beginner's scene omits — power cables drooping behind machines, wall sockets/cable trays along shelf backs, wear decals (scuffs, yellowed-plastic gradients on the beige cases — very era-authentic), small museum plinth cards. The Codrops museum piece shows how far strategic clutter + noise-blended materials go toward de-uniforming a scene ([Codrops 3D museum](https://tympanus.net/codrops/2025/04/08/3d-world-in-the-browser-with-blender-and-three-js/)).
- **Signage/typography in 3D**: use drei `<Text>` (troika-three-text) — SDF glyph rendering with derivative-based antialiasing, parses real font files, runs layout in a worker; crisp at any zoom and works with lighting/fog ([troika-three-text](https://protectwise.github.io/troika/troika-three-text/), [three.js forum announcement](https://discourse.threejs.org/t/troika-3d-text-library-for-sdf-text-rendering/15111)). Museum-style label plaques per exhibit (name, year, one-liner) add more "institution" credibility than any shader.

### 10. Performance architecture for 33 exhibits

- **Instancing / merging**: shelf decks, kick rails, frames, plinths, and repeated archetype parts should go through drei `<Instances>`/`<Merged>` — "each type will cost you exactly one draw call, no matter how many you use" ([R3F scaling performance](https://r3f.docs.pmnd.rs/advanced/scaling-performance), [Codrops instancing guide](https://tympanus.net/codrops/2025/07/10/three-js-instances-rendering-multiple-objects-simultaneously/)). With ~33 exhibits × ~8 meshes each plus furniture you're likely at several hundred draw calls that could be tens.
- **Budgets from a comparable pro project**: Niccolò Fanton's Codrops guide lands a full scene in ~40k triangles, 2.1MB assets; caps DPR at **1.0 desktop / 1.5 mobile** and uses drei `PerformanceMonitor` to degrade DPR ×0.8 under load; profiles with r3f-perf and Spector.js ([Codrops: Building Efficient Three.js Scenes](https://tympanus.net/codrops/2025/02/11/building-efficient-three-js-scenes-optimize-performance-while-maintaining-quality/)). Your current `dpr [1,1.8]` with the 6-effect post stack is likely the main mobile cost.
- **Texture delivery**: bake outputs → **KTX2/Basis Universal** via `gltf-transform` (the Codrops museum used `etc1s` quality 155–255) — GPU-native compressed textures stay compressed in VRAM, unlike PNG/WebP ([Don McCurdy: Choosing texture formats for WebGL/WebGPU](https://www.donmccurdy.com/2024/02/11/web-texture-formats/), [Khronos KTX 2.0](https://www.khronos.org/ktx/)). `gltfjsx -S -T` gave Fanton "90% asset size reduction".
- Baking (#3) removes the shadow pass and most lights, which is itself the biggest perf win — the reason the pattern dominates award scenes on mobile.

## Part 2 — The baked-Blender workflow, end to end

The canonical pipeline (Three.js Journey Portal Scene chapter; Codrops museum; my-room-in-3d; tchayen; Wawa Sensei — sources above):

1. **Model the hall in Blender at real-world scale (meters).** Walls, floor, tiered shelf racks, frames, plinths, cable trays. Apply all transforms; fix normals (bad normals bake black — [tchayen](https://tchayen.github.io/posts/baked-lighting-in-r3f)).
2. **Two UV channels per object**: UV0 for any tiling detail maps, UV1 ("Bake") non-overlapping, packed. Use Smart UV Project + manual seams for long meshes; tools: UVPackmaster, Zen UV; SimpleBake automates the bake loop (used in the Codrops museum).
3. **Light in Cycles** with the intended look: warm area lights as track fixtures, faint cool fill, *and* small emissive planes where the CRT screens sit so machines receive believable screen spill from below/front — this bakes the "glowing museum" mood into the architecture.
4. **Test-bake tiny** (1 sample, 512px) to catch UV/normal errors, then final bake — Combined pass (or Diffuse+lighting), 128+ samples, denoise on, **margin >4px** to avoid seam bleeding (tchayen's black-edge gotcha). The Codrops museum baked 4096×4096 per texture set, ~9 sets grouped by proximity, saved as 32-bit EXR intermediates before tonemapped PNG conversion.
5. **Export glTF**: only selected objects, apply modifiers, keep Principled BSDF with the baked image plugged in, no vertex colors (they export black — tchayen). Join static objects that share a texture set to cut draw calls.
6. **Compress**: `gltf-transform` — Draco/meshopt for geometry, `etc1s`/`uastc` for KTX2 textures (etc1s for lightmaps, uastc for normal maps). ([glTF-Transform](https://gltf-transform.dev/), [KHR_texture_basisu](https://github.com/KhronosGroup/glTF/blob/main/extensions/2.0/Khronos/KHR_texture_basisu/README.md))
7. **Display in R3F**: `useGLTF` + KTX2Loader; hall materials become `MeshBasicMaterial` with the baked map (`flipY = false` for glTF textures, `SRGBColorSpace`) — no lights needed for the shell. Alternatively `lightMap` on the second UV channel over a base color map if you want live tinting.
8. **Live elements on top**: 33 machines + video screens stay dynamic, lit by the `<Environment>`; AccumulativeShadows/ContactShadows glue them to the baked shelves. This hybrid is exactly Bruno Simon's portal pattern (baked scene + live emissives).
9. **Constraint to accept**: baked = static. The current layout *reflows* per view mode and machines fly to center stage — so bake the architecture only, never machine shadows onto shelves (tchayen's "objects cannot move post-baking" warning). Contact/accumulative shadows handle the movable layer.

## Part 3 — Taste guide: what to remove (subtraction is most of professionalism)

| Remove / reduce | Why |
|---|---|
| `toneMapped={false}` on backplate, banners, shafts, pools, bars | Opting surfaces out of the shared color pipeline is why they look composited, not photographed. Reserve it solely for bloom emitters. |
| `HERO_TINT` >1 multipliers | Exposure belongs in `toneMappingExposure`/light intensity, once, globally. |
| Full-screen Scanline + ChromaticAberration + Noise | The "retro" belongs *in the CRTs* (screen-space shader on the glass), not on the viewer's camera. Global filters read as a beginner hiding a weak render. |
| Vignette `darkness 0.82` | A pro vignette is felt, not seen — ~0.3–0.45. Heavy vignette + CA is the canonical amateur combo. |
| 4 of the 7 analytic lights | Ambient+hemi+point fills flatten; envmap + one key + baked GI replaces them with better contrast. |
| Additive billboard god-rays | Static camera-agnostic sprites; replace per #8 or delete — bloom + baked pools carry the mood. |
| Photo billboards as architecture (hero backplate, era banners) | A photo of a hall behind a 3D hall reads instantly as a skybox trick, and its baked-in lighting will contradict yours. Extend the real (baked) hall geometry into the fog instead; keep photos as *framed artwork* (diegetic), where photos are expected. |
| Half of the Sparkles | Dust should be subliminal; 150 large warm sparkles read as fireflies. |
| Bloom threshold 0.6 | Threshold 1.0 + HDR emissives = only screens/lamps bloom, and the documented shimmer problem vanishes. |

Rule of thumb from every case study above: professional scenes get their look from **lighting quality (baked/IBL), material response, and correct color pipeline**, then add at most 2–3 quiet post effects. Amateur scenes invert this: cheap lighting rescued by loud post.

## Part 4 — Annotated link list

**Lighting / IBL**
1. [drei Environment docs](https://drei.docs.pmnd.rs/staging/environment) — Environment, Lightformer children, environmentIntensity, ground projection; preset-CDN production warning.
2. [Poly Haven](https://polyhaven.com/hdris) — CC0 HDRIs/textures used by nearly every case study here.
3. [Lightformers in vanilla three.js — forum](https://discourse.threejs.org/t/r3f-lightformers-in-vanilla-three-js/48495) — how drei builds envmaps from emitter planes.
4. [drei AccumulativeShadows](https://drei.docs.pmnd.rs/staging/accumulative-shadows) — soft accumulated shadows, zero cost once converged.
5. [Understanding Three.js Lighting](https://dev.to/outriding/understanding-threejs-lighting-a-concise-reference-3e8b) — key/fill/rim discipline, light-count restraint.
6. [Maxime Heckel — On Shaping Light](https://blog.maximeheckel.com/posts/shaping-light-volumetric-lighting-with-post-processing-and-raymarching/) — real volumetric shafts for R3F scenes.

**Color / tone**
7. [Updates to Color Management in three.js r152 — discourse](https://discourse.threejs.org/t/updates-to-color-management-in-three-js-r152/50791) — the authoritative sRGB/linear rules.
8. [three.js r160 release (AgX)](https://github.com/mrdoob/three.js/releases/tag/r160) + [AgX issue #27362](https://github.com/mrdoob/three.js/issues/27362).
9. [Khronos PBR Neutral press release](https://www.khronos.org/news/press/khronos-pbr-neutral-tone-mapper-released-for-true-to-life-color-rendering-of-3d-products) + [model-viewer tone-mapping comparison](https://modelviewer.dev/examples/tone-mapping) — why ACES desaturates; Neutral/AgX alternatives.
10. [Tone Mapping Overview — three.js forum](https://discourse.threejs.org/t/tone-mapping-overview/75204) — visual side-by-sides of all operators.
11. [R3F Canvas API](https://docs.pmnd.rs/react-three-fiber/api/canvas) — default ACES + sRGB, `flat`/`linear` escape hatches.

**Baked workflow / case studies**
12. [Codrops — Building a Fully-Featured 3D World with Blender and Three.js](https://tympanus.net/codrops/2025/04/08/3d-world-in-the-browser-with-blender-and-three-js/) — an actual 3D *museum*: full bake pipeline with numbers (4K bakes, 9 texture sets, EXR→KTX2 etc1s, draco, instancing, iOS chunk loading).
13. [Three.js Journey](https://threejs-journey.com/) — lessons 24 "Environment map", 25 "Realistic render", 45 "Post-processing", 46 "Performance tips", 49–52 Portal Scene (Blender bake → export → import/optimize).
14. [my-room-in-3d live](https://my-room-in-3d.vercel.app/) + [source](https://github.com/brunosimon/my-room-in-3d) — Bruno Simon's baked-room reference implementation.
15. [Wawa Sensei — How to Bake Lighting](https://wawasensei.dev/tuto/how-to-bake-lighting) + [r3f-baking repo](https://github.com/wass08/r3f-baking).
16. [tchayen — Baked lighting in r3f](https://tchayen.github.io/posts/baked-lighting-in-r3f) — the honest gotcha list (dual UVs, margins, vertex-color black meshes).
17. [Codrops — Cyberpunk Three.js scene with Blender](https://tympanus.net/codrops/2023/03/22/cyberpunk-inspired-three-js-scene-with-javascript-and-blender/).
18. [Awwwards — curated WebGL technical case studies](https://www.awwwards.com/inspiration/curated-list-of-technical-case-studies-on-webgl-and-creative-development) + [Immersive WebGL virtual galleries collection](https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html) — browseable award-level references.
19. [Vide Infra — triple SOTD WebGL case study](https://videinfra.com/blog/case-study-a-triple-site-of-the-day-winner-powered-by-webgl) — studio-level art-direction/post decisions.
20. [Poolsuite on Awwwards](https://www.awwwards.com/inspiration/music-website-inspired-by-a-90s-os-poolside) — retro-OS art direction done with taste (2D, but the closest kin to this gallery's theme).

**Materials / post / perf**
21. [Codrops — Transparent Glass and Plastic](https://tympanus.net/codrops/2021/10/27/creating-the-effect-of-transparent-glass-and-plastic-in-three-js/) + [MeshPhysicalMaterial docs](https://threejs.org/docs/pages/MeshPhysicalMaterial.html) — transmission/clearcoat for CRT glass.
22. [n8ao](https://www.npmjs.com/package/n8ao) + [HBAO vs N8AO comparison](https://discourse.threejs.org/t/new-ambient-occlusion-example-hbao-vs-n8ao/58847).
23. [react-postprocessing Bloom docs](https://react-postprocessing.docs.pmnd.rs/effects/bloom) — the canonical selective-bloom pattern; [pmndrs/postprocessing Effect Merging](https://github.com/pmndrs/postprocessing/wiki/Effect-Merging) — why this composer outperforms three's.
24. [Codrops — Building Efficient Three.js Scenes](https://tympanus.net/codrops/2025/02/11/building-efficient-three-js-scenes-optimize-performance-while-maintaining-quality/) — DPR caps, 40k-tri budget, gltfjsx flags, profiling tools; [R3F scaling performance](https://r3f.docs.pmnd.rs/advanced/scaling-performance) + [Codrops instancing](https://tympanus.net/codrops/2025/07/10/three-js-instances-rendering-multiple-objects-simultaneously/).
25. [Don McCurdy — Choosing texture formats](https://www.donmccurdy.com/2024/02/11/web-texture-formats/) — KTX2 vs WebP/AVIF decision guide; [troika-three-text](https://protectwise.github.io/troika/troika-three-text/) — SDF text for museum signage; [texel density deep dive](https://www.beyondextent.com/deep-dives/deepdive-texeldensity).

**Bottom line**: the three moves that would each visibly re-class this scene are (1) an HDRI/Lightformer environment replacing most analytic lights, (2) a unified tone pipeline (AgX, no `toneMapped:false` hacks, threshold-1 selective bloom so only screens glow), and (3) baking the static hall in Blender à la the portal-scene/Codrops-museum pattern. Everything else — AO, physical CRT glass, subtractive post, real-scale composition, instancing/KTX2 — compounds on those three.
