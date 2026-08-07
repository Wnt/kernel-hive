# Scene Architecture, Navigation & Live-Screen Integration for a Professional Virtual Museum

*(react-three-fiber 9 / three.js 0.185 / drei / zustand — 33 exhibits, 30 live WebCodecs OS streams)*

## 1. Recommended target architecture

### 1.1 Environment as asset — hybrid pattern (recommended)

The consistent pattern across every professional-grade example (Bruno Simon's room, the interactive-portfolio museum scene, Cartier's pavilion, Virtual Beeb) is: **Blender-authored, baked shell + code-driven dynamic content**. Pure-procedural JSX halls read as "tech demo"; pure-baked scenes can't host 33 data-driven exhibits. The hybrid is:

1. **Hall shell modeled + lit + baked in Blender**, exported glTF. Bake lightmaps on a dedicated UV channel; the canonical r3f workflow (test-bake low samples first, denoise, 4px+ margins, keep Principled BSDF with baked texture, strip vertex colors) is documented in [tchayen's baked-lighting-in-r3f writeup](https://tchayen.github.io/posts/baked-lighting-in-r3f) and batch-bake tooling exists ([Blender batch lightmap script, three.js forum](https://discourse.threejs.org/t/made-a-blender-script-for-batch-baking-lightmaps-to-optimize-models-for-threejs/82346)). Bruno Simon's [my-room-in-3d](https://github.com/brunosimon/my-room-in-3d) (open source) is the reference for a baked shell whose *screens stay live* — his shader mixes baked maps with runtime "light strength" uniforms (uLightTvStrength etc.), exactly the museum-hall-with-glowing-CRTs mood ([GIGAZINE breakdown](https://gigazine.net/gsc_news/en/20210913-my-room-in-3d/)).
2. **Exhibit slots as named Empties in the Blender file.** Export Empties (`Slot_01`…`Slot_33`, plus per-slot metadata via custom properties → glTF `extras`). At load, code reads node transforms and mounts registry-driven exhibits into slots. This keeps your manifest-driven layout: the *registry* decides which OS goes in which slot; the *artist* decides where slots are, at what height, under which spotlight. [gltfjsx](https://github.com/pmndrs/gltfjsx) turns the glTF into a typed JSX graph so slots and meshes are addressable by name instead of scene traversal.
3. **Machine archetypes as separate glTF assets** (CRT terminal, beige tower + monitor, workstation, home micro, handheld…), instantiated per registry entry into slots. 33 exhibits ≈ 5–8 archetypes; this is where reuse/instancing lives (§3).
4. **Dynamic-props lighting**: baked shell uses `lightMap`; the code-placed machines can't be in the bake. Options, in order of practicality: (a) a single low-cost `Environment` map + 1–2 real lights confined to props; (b) light probes baked in Blender and imported — [blender-probes-export](https://github.com/gillesboisson/blender-probes-export) + [threejs-probes-test](https://github.com/gillesboisson/threejs-probes-test) implement exactly "baked scene + probe-lit dynamic objects"; three.js `LightProbe`/`LightProbeGenerator` is core ([docs](https://threejs.org/docs/pages/LightProbe.html)). For a dim museum hall where screens are the hero light source, (a) plus per-exhibit emissive spill (a small PointLight or baked-in spotlight pool per slot) is enough — my-room-in-3d fakes all of it in the bake + uniforms with zero real lights.

**Fixed curated slots beat fully-dynamic layout.** Your current procedural tiered-shelf grid can survive as the *fallback/dev* layout, but curation (sight lines, era grouping, hero placement) is what makes museums read as professional — Cartier's pavilion is literally "one alcove per exhibit" and won SOTD on that structure ([Utsubo's 2026 roundup](https://www.utsubo.com/blog/best-threejs-websites-2026)). With 33 slots exported as Empties, adding exhibit #34 is a Blender edit, not a code change — and the registry→slot assignment stays data.

### 1.2 Navigation model

Findings across the survey:

- **Free-walk (WASD/joystick)** works when the audience is gamers (Active Theory's [20 Years of Xbox Museum](https://www.awwwards.com/sites/20-years-of-xbox-museum) used avatars + WASD deliberately for that audience) but has high interaction cost for everyone else. NN/g's research on virtual tours: navigation is "slow and confusing", tours have [high interaction cost, moderate usefulness](https://www.nngroup.com/articles/virtual-tours/) — never make walking mandatory.
- **Scroll-driven rails** (drei ScrollControls, optionally Theatre.js-keyframed — [Codrops fly-through tutorial](https://tympanus.net/codrops/2023/02/14/animate-a-camera-fly-through-on-scroll-using-theatre-js-and-react-three-fiber/)) are the dominant *marketing-site* pattern (Cartier, IVRESS, Shopify Editions per [Utsubo](https://www.utsubo.com/blog/best-threejs-websites-2026)). Great for narrative, wrong as the *primary* mode for a museum where users stop and *operate* an OS for minutes — scroll position and "I'm using this exhibit" fight each other.
- **Point-and-click focus (point-of-interest teleport)** performs comparably to free navigation with less disorientation ([POI portal navigation study, Springer 2025](https://link.springer.com/chapter/10.1007/978-3-032-03805-0_16)) and is what gallery sites converge on ([Hush Gallery](https://discourse.threejs.org/t/hush-gallery-a-meditative-3d-art-museum/92935): click painting → move camera; Bartlett Summer Show's "doorway metaphor" transitions, [Awwwards collection](https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html)).

**Recommendation — three-mode model, matching what you already half-have:**

1. **Overview / idle drift** (current rig, keep): slow rail drift through the hall; doubles as attract-mode.
2. **Browse**: constrained orbit/dolly along the hall + click any exhibit or an always-visible index (mini-map/exhibit list — museums need direct access, not forced walking).
3. **Focused / control mode**: camera flies to a per-slot authored viewpoint; input handed to the OS stream.

**Implement transitions with `camera-controls` (drei `<CameraControls>`), not tweened OrbitControls.** It's purpose-built for this: `setLookAt(...args, true)` / `fitToBox(mesh, true)` with `smoothTime` easing, await-able transitions, azimuth/polar/distance clamps, `setBoundary`, and — the elegant fix for your "OrbitControls fighting in-screen control" problem — **per-input action remapping**: in focused mode set `controls.mouseButtons.left = ACTION.NONE` / `touches.one = ACTION.NONE` (or `controls.enabled = false`) so pointer events pass through to the screen mesh while pinch-zoom can stay live ([yomotsu/camera-controls](https://github.com/yomotsu/camera-controls), [API docs](https://yomotsu.github.io/camera-controls/), [drei controls](https://drei.docs.pmnd.rs/controls/introduction)). r3f's event system already delivers pointer events with UV to the mesh; no global listener juggling. Store the focused-slot camera pose (position + target Empties per slot, authored in Blender) rather than computing it — `fitToBox` is the fallback for unauthored slots. Authoring option for the drift rail: keyframe it visually in Theatre.js Studio and export JSON ([Codrops](https://tympanus.net/codrops/2023/02/14/animate-a-camera-fly-through-on-scroll-using-theatre-js-and-react-three-fiber/)).

**Mobile touch mapping:** default OrbitControls touch conventions (1-finger orbit, 2-finger dolly/pan) are the discoverable baseline; 3-finger anything is undiscoverable ([three.js #11855](https://github.com/mrdoob/three.js/issues/11855)). camera-controls lets you remap `touches.one/two/three` per mode — in focused mode, 1-finger goes to the OS, 2-finger pinch = zoom toward screen, and an explicit on-screen "Back" button exits (gesture-only exits fail on iOS Safari due to native gesture conflicts — [MDN pinch-zoom pointer events](https://developer.mozilla.org/en-US/docs/Web/API/Pointer_events/Pinch_zoom_gestures)).

Optional polish on focus: subtle DoF via postprocessing bokeh with focus distance = exhibit distance — but with 30 live streams, treat any fullscreen post chain as a perf budget item (§3.4).

## 2. The live-screen-on-glTF integration recipe

### 2.1 Texture path: `VideoFrameTexture.setFrame()` — the direct WebCodecs fit

Your current pipeline (VideoDecoder → three texture) has an official fast path since **r173**: `VideoFrameTexture`, added specifically because "doing it naively can leave lots of performance on the table" ([PR #30269](https://github.com/mrdoob/three.js/pull/30269)); three 0.185 has it. The backing issue quantified why: routing a `VideoFrame` through `CanvasTexture` uses the texStorage + `texSubImage2D` path, ~**5x slower on the OpenGL/ANGLE backend** (i.e. Windows Chrome — most of your users) than the `texImage2D` path `VideoTexture` uses internally ([issue #28980](https://github.com/mrdoob/three.js/issues/28980)); naive `drawImage`/`texSubImage2D` reports show 80fps→10fps collapses ([w3c/webcodecs #421](https://github.com/w3c/webcodecs/issues/421)). Independent measurements confirm direct `texImage2D` beats three's texSubImage path 0.6–1.0ms vs 1.5–3.5ms for large textures ([three.js #31093](https://github.com/mrdoob/three.js/issues/31093)).

Recipe per exhibit:
- One `VideoFrameTexture` per stream; on each decoded frame of a **visible** exhibit: `tex.setFrame(frame)` then `frame.close()` after the render that consumed it; for non-visible exhibits, `frame.close()` immediately (§3.2).
- Crucially, `setFrame` is **manual-cadence by design** — this sidesteps the classic `VideoTexture` bug where the texture re-uploads to GPU every rAF even when the video is paused ([#16946](https://github.com/mrdoob/three.js/issues/16946), [#22380](https://github.com/mrdoob/three.js/issues/22380), [r3f fps-drop report](https://discourse.threejs.org/t/react-three-fiber-low-framerate-when-using-videotexture-even-when-video-is-paused/43651)). Your 30 streams only cost upload when frames actually arrive and the exhibit is visible.
- If you ever move to WebGPURenderer, the equivalent zero-copy end state is `importExternalTexture` ([WebGPUFundamentals](https://webgpufundamentals.org/webgpu/lessons/webgpu-textures-external-video.html), [gpuweb #1380](https://github.com/gpuweb/gpuweb/issues/1380)) — another reason to keep the texture behind one abstraction.

### 2.2 Emissive glowing-screen material

- Material: `MeshStandardMaterial` with **`map` and `emissiveMap` pointing at the same VideoFrameTexture**, `emissive: 0xffffff`, `emissiveIntensity` ~1–1.6, plus low `roughness`-driven reflection of the hall on a *separate thin "glass" shell* mesh if you want authored screen glass (you already have curved screen glass — keep it; put the video on the phosphor face beneath).
- Bloom: use **emissive-driven threshold bloom**, not per-object selective bloom layers. The official pattern is bloom keyed off emissive output ([three.js webgpu bloom_emissive example](https://threejs.org/examples/webgpu_postprocessing_bloom_emissive.html)); in WebGL/pmndrs-postprocessing, set `luminanceThreshold` just above diffuse scene brightness so only emissive screens cross it — the classic pitfall is the whole model blooming because albedo crosses threshold ([forum: SelectiveBloom blooming whole model](https://discourse.threejs.org/t/selectivebloom-blooming-the-whole-model-emissive-texture/33679), [selective bloom thread](https://discourse.threejs.org/t/selective-bloom-in-three-js/35345)). Keep the hall bake slightly darker than you think; it makes 30 glowing CRTs carry the room, which is exactly the "living museum at night" look.
- Optional CRT character: Virtual Beeb layered a phosphor-dot + noise CRT shader over the live emulator texture and it's the single most-praised visual in that project ([Virtual Beeb writeup](https://www.dompajak.com/blog/webxr-beeb-virtual-beeb/index.html)) — cheap, per-screen-only fragment cost, huge era-authenticity payoff.

### 2.3 Curved CRT face in Blender: naming + UV conventions

- **Naming convention:** inside each archetype, name the phosphor mesh `<Archetype>_Screen` with material `ScreenVideo` (and glass shell `ScreenGlass`). gltfjsx exposes `nodes.X/materials.Y` by these names, so mounting code does `nodes[`${type}_Screen`]` and swaps in the live material — the standard "find named mesh, replace material" workflow ([gltfjsx](https://github.com/pmndrs/gltfjsx), [Victor Dibia's Blender→R3F guide](https://victordibia.com/blog/blender-to-react/)).
- **UV rule:** UV-unwrap the curved screen face to the **full 0–1 square, undistorted** (project-from-view then relax, or straight before adding curvature via shrinkwrap onto the curved surface). The stream then maps with no code contortions, and…
- **…pointer mapping is free:** three's Raycaster returns `intersection.uv` barycentrically interpolated on *any* geometry with a `uv` attribute — curvature is irrelevant ([Raycaster docs](https://threejs.org/docs/pages/Raycaster.html), [barycentric-UV discussion #6762](https://github.com/mrdoob/three.js/issues/6762)); r3f pointer events hand you `e.uv` directly. Gotchas: (a) the screen face UV island must not share/overlap with other islands; (b) if you letterbox via `texture.repeat/offset` or shader, **apply the inverse transform to the picked UV** before converting to OS coordinates (`texture.transformUv` does the forward direction); (c) glTF flipY (`texture.flipY = false` for glTF-loaded textures — your VideoFrameTexture is code-created, so establish one convention and test); (d) `material.side` — keep `FrontSide` so rays can't hit the back; (e) raycast **only** against screen meshes + slot hit-proxies (a curated `raycast`-targets list, or `mesh.raycast = () => {}` on everything else) and add [three-mesh-bvh](https://github.com/gkjohnson/three-mesh-bvh) / drei [`<Bvh>`](https://drei.docs.pmnd.rs/performances/bvh) on the hall shell so hover-frequency raycasts stay sub-ms.
- **Letterboxing per OS:** simplest correct approach is `THREE.TextureUtils.contain(texture, screenAspect)` (CSS `object-fit: contain` semantics) with black `material.color` under the bars, or one branch in a small shared shader; recompute on stream-resolution change. Forum precedents: [video aspect on material](https://discourse.threejs.org/t/video-texture-how-to-keep-video-aspect-in-new-material/6319), [repeat/offset technique](https://discourse.threejs.org/t/texture-aspect-ratio-repeat/60591). Since pointer→UV must invert this, wrap letterbox state + UV inversion + texture in one `ExhibitScreen` object so it can't drift.

## 3. LOD & performance plan for 33 exhibits / 30 live screens

### 3.1 Geometry: archetypes, not 33 uniques

- 5–8 archetype glTFs; chassis/keyboard geometry **shared** between exhibits of the same archetype. True `InstancedMesh` with *per-instance video* is not practical — WebGL can't index samplers per instance ([forum](https://discourse.threejs.org/t/how-to-set-different-textures-on-each-instancedmesh/29433)); `DataArrayTexture` layers require equal dimensions and you'd still re-upload layers per stream ([forum](https://discourse.threejs.org/t/instanced-textures-with-dataarraytexture-error/43187)). The right split: **instance/batch the dead geometry** (cases, keycaps, desks — Virtual Beeb instanced its keycaps to help cut 102→23 draw calls, [writeup](https://www.dompajak.com/blog/webxr-beeb-virtual-beeb/index.html)) and keep **one small unique screen mesh per exhibit** (30 draw calls for screens is nothing; the texture uploads are the real budget).
- Mesh LOD via drei `<Detailed>` per archetype (full / mid / box+poster) — reduce vertex load for the far end of the hall ([r3f scaling-performance](https://r3f.docs.pmnd.rs/advanced/scaling-performance)).

### 3.2 The real budget: texture uploads — tiered update policy

A 1024×768 RGBA upload is ~3MB; 30 streams × 30fps ≈ 2.8GB/s of texture traffic if unthrottled — mobile GPUs die long before that. Tier by exhibit state (you already pace input at ~33/s; this is the output-side twin):

| Tier | Condition | Update policy |
|---|---|---|
| **Focused** | user controlling | every decoded frame → `setFrame` |
| **Near/visible** | in frustum, < N m | throttle to 10–15fps (drop frames: `close()` without upload) |
| **Far/visible** | in frustum, far | 1–2fps "alive" flicker |
| **Culled** | off-frustum / occluded | no upload; optionally tell streamhost to drop to poster/keyframe cadence |

Frustum test against slot bounding spheres each frame is trivial for 33 items. This dovetails with your daemon-side backlog control (SH_SEND_MAX_BACKLOG) — the ideal is signaling tier upstream so the network also quiets down, which your per-tile daemon architecture supports.

### 3.3 Frameloop: `demand` + frame-driven invalidation

`frameloop="demand"` normally conflicts with video, but with manual `setFrame` you get the best of both: call `invalidate()` only when (a) a visible exhibit uploaded a frame, (b) camera/controls moved (drei controls invalidate automatically), or (c) an animation is running ([r3f scaling-performance](https://r3f.docs.pmnd.rs/advanced/scaling-performance)). With your fleet's idle auto-pause, an untouched gallery tab renders **zero** frames — matching the 80%→1.4% idle-CPU philosophy on the host side, now on the client.

### 3.4 React & misc hygiene

- Never `setState` in `useFrame`; mutate refs; use zustand transient subscriptions for focus/tier state (you're already on zustand). Reuse vectors; no object churn in the loop ([r3f scaling-performance](https://r3f.docs.pmnd.rs/advanced/scaling-performance)).
- Postprocessing: one composer, bloom only; on low-tier devices (drei `PerformanceMonitor` / DPR scaling) drop bloom before dropping stream tiers.
- Utsubo's ["100 three.js tips" (2026)](https://www.utsubo.com/blog/threejs-best-practices-100-tips) is a good checklist source: draw-call ceilings, dispose discipline, DPR clamp ≤2.

### 3.5 Asset budget (mobile-first)

- **KTX2/Basis for all baked textures**: stays compressed on GPU, ~10x VRAM saving vs PNG (a 200KB PNG can occupy 20MB+ VRAM decompressed) — critical when 30 live RGBA streams already eat VRAM. ETC1S for lightmaps/albedo, UASTC for normals ([Don McCurdy, "Choosing texture formats", 2024](https://www.donmccurdy.com/2024/02/11/web-texture-formats/)).
- **`gltf-transform optimize` with meshopt** on hall + archetypes ([Needle optimization guide](https://engine.needle.tools/docs/how-to-guides/optimization/)).

## 4. Progressive loading UX

1. **Instant shell**: branded HTML/`useProgress` loader ([drei Progress](http://drei.docs.pmnd.rs/loaders/progress-use-progress), [Wawa Sensei loading-screen lesson](https://wawasensei.dev/courses/react-three-fiber/lessons/loading-screen)) → hall shell (small, KTX2) inside `<Suspense>`; enter the hall before archetypes finish.
2. **Placeholder → swap**: each slot mounts instantly as a cheap poster stand-in (poster/keyframe from the stream — you already have showcase posters as a concept) suspending independently per archetype; `useGLTF.preload` archetypes in slot-proximity order ([loading-assets guide](https://aaronclaes.be/blogs/react-three-fiber/loading-assets)).
3. **Streams last**: connect focused/near streams first; far tiles connect lazily or on approach. (Matches NN/g guidance: get users to content fast, don't gate on a 100% bar.)
4. Camera intro: play the idle-drift rail as the "doors open" moment once the shell is in — Bartlett's doorway metaphor shows transitions themselves can mask loading ([Awwwards collection](https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html)).

## 5. Exemplars — what to steal from each

| Site | Steal this |
|---|---|
| **[Virtual Beeb](https://www.dompajak.com/blog/webxr-beeb-virtual-beeb/index.html)** — 3D BBC Micro w/ live emulator | The closest existing thing to one of your exhibits. CRT phosphor/noise shader over the live texture; emulator in a Worker; instanced keycaps; draw calls 102→23; per-key audio feedback (huge tactility win for your focused mode). |
| **[my-room-in-3d](https://github.com/brunosimon/my-room-in-3d)** (Bruno Simon, open source) | The baked-shell + live-screens material system: baked lightmaps mixed with runtime light-strength uniforms; screens as emissive light sources with faked spill. Study the shader, not just the workflow. |
| **[20 Years of Xbox Museum](https://www.awwwards.com/sites/20-years-of-xbox-museum)** (Active Theory) | Museum information architecture: nostalgic entry scene → console-per-era rooms; audience-appropriate navigation choice; "your personal museum" data-driven exhibits. |
| **[Cartier Watches & Wonders pavilion](https://www.utsubo.com/blog/best-threejs-websites-2026)** (Immersive Garden) | Alcove-per-exhibit staging with entrance/hold/exit beats — the template for your focused-mode camera choreography and per-slot lighting drama. |
| **[Hush Gallery](https://discourse.threejs.org/t/hush-gallery-a-meditative-3d-art-museum/92935)** | Restraint: click-to-view, deep zoom, themed rooms, no gimmicks. Proof that simple navigation + great content reads as professional. |
| **[Bartlett Summer Show 2020](https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html)** | Doorway-metaphor transitions between wings — a model for era/section grouping of 33 machines. |
| **[Interactive Portfolio / Virtual Museum Scene](https://discourse.threejs.org/t/interactive-portfolio-virtual-museum-scene/43743)** | Small-scale proof of your exact stack pattern: Blender-modeled+baked museum, walk + click-inspect, r3f. |
| **[Zendesk Museum of Annoying Experiences](https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html)** | Tone: playful exhibit copy/placards elevate a museum from asset-viewer to experience. |
| **[Theatre.js fly-through (Codrops)](https://tympanus.net/codrops/2023/02/14/animate-a-camera-fly-through-on-scroll-using-theatre-js-and-react-three-fiber/)** | The authoring workflow for your idle-drift rail: keyframe visually in Studio, ship JSON. |
| **[Emupedia](https://emupedia.fit/) / [RetroWeb Museum](http://retroweb.maclab.org/)** | Content/curation peers (2D): placard writing, era grouping, "try it" framing for live vintage software. |

**Anti-patterns observed:** mandatory free-walk with no index (NN/g's interaction-cost complaint); scroll-rails as the only navigation in a place users need to *dwell*; full-scene selective-bloom layer hacks; `VideoTexture` auto-update with many streams; fully procedural halls with uniform lighting (reads as CMS template, not museum).

## 6. Annotated link list

**Museums / galleries / showcases**
1. https://www.dompajak.com/blog/webxr-beeb-virtual-beeb/index.html — Virtual Beeb build log; live emulator on 3D CRT, CRT shader, perf numbers.
2. https://github.com/brunosimon/my-room-in-3d — open-source baked room + live screens; https://gigazine.net/gsc_news/en/20210913-my-room-in-3d/ — uniform-mix breakdown.
3. https://www.awwwards.com/sites/20-years-of-xbox-museum — Active Theory Xbox museum (SOTD/Site of the Month).
4. https://www.awwwards.com/immersive-webgl-virtual-gallery-exhibition-collection.html — Awwwards curated virtual-exhibition collection (Bartlett, Foam Talent, Zendesk, Penderecki's Garden…).
5. https://discourse.threejs.org/t/hush-gallery-a-meditative-3d-art-museum/92935 — Hush Gallery (2026).
6. https://discourse.threejs.org/t/interactive-portfolio-virtual-museum-scene/43743 — Blender-baked museum in r3f.
7. https://www.utsubo.com/blog/best-threejs-websites-2026 — 2026 technique survey incl. Cartier pavilion.
8. https://www.nngroup.com/articles/virtual-tours/ — NN/g virtual-tour usability.
9. https://link.springer.com/chapter/10.1007/978-3-032-03805-0_16 — POI/portal navigation for virtual museums (2025).

**Environment-as-asset workflow**
10. https://tchayen.github.io/posts/baked-lighting-in-r3f — end-to-end Blender bake → r3f.
11. https://github.com/pmndrs/gltfjsx — glTF → typed JSX; named-node access for screen/slot conventions.
12. https://github.com/gillesboisson/blender-probes-export (+ https://github.com/gillesboisson/threejs-probes-test) — baked probes for dynamic objects in baked scenes.
13. https://www.donmccurdy.com/2024/02/11/web-texture-formats/ — KTX2/ETC1S/UASTC decision guide.
14. https://engine.needle.tools/docs/how-to-guides/optimization/ — gltf-transform optimize pipeline.

**Live video textures**
15. https://github.com/mrdoob/three.js/pull/30269 — VideoFrameTexture (r173) for WebCodecs.
16. https://github.com/mrdoob/three.js/issues/28980 — VideoFrame upload paths; ~5x ANGLE penalty via texSubImage2D.
17. https://github.com/mrdoob/three.js/issues/31093 — texImage2D vs texSubImage2D timings.
18. https://github.com/mrdoob/three.js/issues/16946 + https://github.com/mrdoob/three.js/issues/22380 — VideoTexture uploads-when-paused pitfall.
19. https://webgpufundamentals.org/webgpu/lessons/webgpu-textures-external-video.html — importExternalTexture zero-copy (future path).
20. https://threejs.org/examples/webgpu_postprocessing_bloom_emissive.html + https://discourse.threejs.org/t/selectivebloom-blooming-the-whole-model-emissive-texture/33679 — emissive-keyed bloom, and its classic failure mode.

**Perf / interaction / loading**
21. https://r3f.docs.pmnd.rs/advanced/scaling-performance — frameloop demand, invalidate, instancing, LOD.
22. https://github.com/gkjohnson/three-mesh-bvh + https://drei.docs.pmnd.rs/performances/bvh — accelerated raycasting.
23. https://github.com/yomotsu/camera-controls — setLookAt/fitToBox transitions, per-input action remapping (the OrbitControls-fight fix).
24. https://tympanus.net/codrops/2023/02/14/animate-a-camera-fly-through-on-scroll-using-theatre-js-and-react-three-fiber/ — visual camera-rail authoring.
25. http://drei.docs.pmnd.rs/loaders/progress-use-progress + https://aaronclaes.be/blogs/react-three-fiber/loading-assets — suspense loading UX.

### Bottom line
Hybrid **Blender-baked hall + Empty-slot registry mounting**; **point-and-click focus navigation on camera-controls** (keep idle drift, add an index, keep constrained browse orbit); screens = **VideoFrameTexture.setFrame from your existing WebCodecs decoder** with map+emissiveMap and emissive-threshold bloom; **tiered texture-update policy + demand frameloop** is the single highest-leverage perf move for 30 streams; archetype instancing for chassis, unique small screen meshes; KTX2 everything baked. Virtual Beeb and my-room-in-3d together contain ~80% of the recipes, already proven in production.
