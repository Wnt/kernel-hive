# Asset pipeline research: real 3D models for the Kernel Hive museum scene

*(react-three-fiber 9 / three.js 0.185, ~33 exhibits from ~10–15 distinct machine types, self-hosted, desktop Chrome + decent mobile — researched 2026-07-27)*

## TL;DR — what I would actually do

Retro computers are a **worst case for AI image-to-3D and photogrammetry, and a best case for buying + kitbashing**: the shapes are trivial (wedges, boxes, a pizza box — you already have box primitives), and all the perceived quality lives in **crisp labels, keycaps, bevels, vents and badges** — precisely the things AI generation smears and glossy-beige photogrammetry fails on. Meanwhile the vintage-computing niche is unusually well served by human artists selling exact-model replicas for $10–50.

**Recommended pipeline:**

1. **Source (per machine, in priority order):**
   - **Buy human-made models** for iconic silhouettes: 3Dee (`fab.com/sellers/3Dee`, ex-Sketchfab) has a C64, C64 tape drive, disk drive, Compaq portable, VT100 and a whole "Computers and Consoles" collection; TurboSquid has an Amiga 500 (~$35) and C64 (~$19); CGTrader has a 3-model Commodore PBR collection ($45) and a Commodore 1084S CRT. VT100-style terminals exist on 4+ stores for ~$10. **But read the licensing section below first — this is the biggest trap in the whole pipeline.**
   - **Free CC assets** for fillers/stylized fallback: Poly Pizza returns 99 "retro computer" hits (Macintosh Classic, "Computer 90s", CRT Monitor, Quaternius "Computer Large" — CC0/CC-BY), BlenderKit has free RF/CC0 retro desktops.
   - **AI generation only for texture-light background props and one-offs nobody inspects** (a beige printer, a shelf server). Best-in-class today: Meshy 6 (hosted, $20/mo, you own outputs) or **TRELLIS.2 (MIT, open weights)** — notably, **Tencent Hunyuan3D's community license excludes the EU**, so as a Finland-based user the open-weights choice is TRELLIS.2, not Hunyuan.
   - **Photogrammetry: skip for the fleet.** If you own 1–2 machines, harvest *textures* (straight-on photos of front panels/keyboards → decals) rather than scanning geometry.
2. **Cleanup hub — Blender headless, agent-driven:** `blender --background --python cleanup.py` scripts (or Blender MCP interactively) for: apply transforms, decimate/remesh, merge materials, bake AO, rename nodes for gltfjsx, export glTF. This is the layer where Claude Code/Codex earns its keep — the operations are repetitive and scriptable.
3. **Optimize — glTF-Transform:** `gltf-transform optimize in.glb out.glb --compress meshopt --texture-compress ktx2` (ETC1S for albedo, UASTC for normals), plus `npx gltfjsx --transform --instance` to emit typed R3F components with instancing.
4. **Runtime:** drei `useGLTF` (Draco/meshopt decoding built in), KTX2Loader with transcoder wired via the loader-extension callback, `<Detailed>`/LOD for the room view, instanced meshes for repeated machines, brotli + long-cache headers from your HTTPS server.

Budget that works for this scene: **≤1–2 MB per hero GLB, ≤25 MB total desktop, ~10 MB before-interactive on mobile** (details in §6).

---

## 1. AI 3D generation state of the art (2025–2026)

### Comparison table

| Tool | Model (2026) | Geometry quality | Topology / UV | PBR out | glTF | Price | Output license | Verdict for a hero C64 |
|---|---|---|---|---|---|---|---|---|
| **Meshy** | Meshy 6 | Most consistently usable; hallucinates detail | Smart Remesh: quad or tri, 1k–300k target polycount, free, "sensible UVs" | Best-in-class; 4K base color hero, 2K PBR maps | GLB (recommended path) | Free 100 cr/mo; Pro $20, Studio $60 | Paid = you own outputs; free tier = **CC BY 4.0 + models are public** | Closest, still not label-crisp |
| **Tripo** | Tripo v3 / P1 | Fast, clean quad-flow, good stylized; fills hollows (lost a trigger cavity in tests) | Best quad topology of hosted tools | Decent, weaker than Meshy | GLB/FBX/OBJ/USD | Free 300 cr; Pro $19.90/mo (annual ~$12) | Free = CC BY, non-commercial; paid = commercial rights | Good shape, soft detail |
| **Rodin (Hyper3D)** | Gen-2 (10B params) | Highest hard-surface geometric fidelity, clean panel lines | Needs manual retopo; non-manifold exports reported (20–40 min Blender repair) | Weakest — muddy, assumes Substance re-texture | Yes | Creator $30/mo, Business $120/mo, pay-per-download credits | All plans commercial; Shutterstock-licensed training data | Best geometry, worst textures |
| **TRELLIS.2** (Microsoft) | 4B, O-Voxel, Dec 2025 | Handles open surfaces/non-manifold; 512³–1536³; ~17 s at 1024³ on H100 | Not artist topology; dense | Base Color/Roughness/Metallic/Opacity | GLB export | **Free, MIT**, self-host; needs 24 GB VRAM (community forks ~8 GB) | MIT — no strings, EU-safe | Best free option |
| **Hunyuan3D 2.1/2.5** (Tencent) | Open weights | Max-settings output most detailed among open models; 40k–1.5M face control | Configurable | Full PBR pipeline (2.1+) | Yes | Free weights | **Community license explicitly excludes EU/UK/South Korea — unusable for you in Finland** | Disqualified by license |
| **Hitem3D / Sparc3D** | Sparc3D + Ultra3D, 1536³ | Sharpest surface detail of hosted tools (NeurIPS 2025 paper); multi-view input | Clean watertight mesh, print-oriented | Relightable, auto-delight | Yes | Freemium/credits | Commercial on paid | New leader for fine detail; watch it |
| **Luma Genie** | — | — | — | — | — | — | 3DGS-focused; **no longer actively updated** for mesh workflows | Skip |
| **Sloyd** | Parametric + AI | Clean topology, UVs, LODs by construction — but template-bound (fantasy/game props, not vintage hardware) | Excellent | Basic | GLB | Freemium | Commercial on paid | Wrong template library |
| **Spline AI** | — | Design-tool grade | Limited | Limited; glTF export loses material layers, exports "too big for production" | Partial | Freemium | — | Not for this |
| **CSM Cube 2** | — | Lower geometric fidelity, best rigging/quad flow (characters) | Real quad flow | Weak | Yes | $30–119/mo | Commercial on paid | Character tool, skip |

### The reality check for your use case

- Every serious comparison agrees textures from all generators "need significant refinement before production use" and are "insufficient resolution for close-ups" ([ideate.xyz test, Apr 2025](https://ideate.xyz/blogs/posts/ai-3d-model-comparison-trellis-tripo-meshy-rodin-hunyuan)). A C64's identity is its badge, function-key legends, and two-tone keycaps — exactly the fine text/label detail that single-image reconstruction smears, and back/underside geometry is invented ("the back looks melted in a microwave" — [QWE tutorial on image-to-3D failure modes](https://www.qwe.edu.pl/tutorial/create-ai-generated-3d-models-from-images/)).
- Keyboards are a known killer: ~100 small repeated protrusions with per-key text. No 2026 generator produces clickably-crisp keycaps from a photo. For your stations' hero machines (viewed up close), AI output would need Blender surgery that exceeds the cost of buying a $20 human-made model.
- Where AI generation **is** worth it for you: background clutter (shelves, boxes, cables, a generic beige printer), and geometry drafts you then re-texture with your own decal textures.

## 2. Midjourney → 3D workflows

Documented chains exist and work, with caveats:

- **Tripo's own Midjourney guide** ([tripo3d.ai blog](https://www.tripo3d.ai/blog/tripo-user-guide-xi-combining-with-midjourney)) and [Midlibrary's Tripo guide](https://midlibrary.io/midguide/tripo-ai-midjourney-to-3d): generate a clean object shot in Midjourney (isolated, neutral background, ¾ view), feed image-to-3D, optionally re-project the MJ image as texture.
- Best-practice refinements from 2025–26 workflows: generate **multi-view** inputs (front/side/back — some people use Gemini/GPT-image to synthesize the missing views from the MJ render) before feeding tools that accept multi-view (Tripo, Hitem3D, Hunyuan); isometric-style MJ renders + TRELLIS is a documented game-asset combo.
- Honest assessment for your case: Midjourney → image-to-3D is best for *stylized* museum props. For real, recognizable machines (Amiga 500, SPARCstation), a photo of the actual machine is a strictly better conditioning image than an MJ render — and both hit the same keycap/label wall. Midjourney's most useful role in your pipeline is **texture/decal synthesis and reference boards**, not 3D conditioning.

## 3. Buying and downloading — what actually exists (concrete finds)

The vintage-computing niche is well covered. Concrete examples found:

| Item | Where | Price / license | Notes |
|---|---|---|---|
| Commodore 64 by **3Dee** | [Sketchfab store listing](https://sketchfab.com/3d-models/commodore-64-c8aefefc1d0842ab8c3782617f9c5907) → now sold via `fab.com/sellers/3Dee` | Royalty-free (Fab Standard) | 28.6k tris, Blender-made; author ships an upgraded v2 |
| C64 tape drive, old disk drive, "Vintage Portable Computer" (Compaq), DEC VT100 | Same seller ([collection](https://sketchfab.com/mellydeeis/collections/computers-and-consoles-34dd957dd8594c598e00ce62a765d72c)) | Mixed free + paid | The single best one-stop shop for your exact theme |
| Commodore Amiga 500 + monitor | [TurboSquid 2061326](https://www.turbosquid.com/3d-models/commodore-amiga-500-computer-with-monitor-3d-model-2061326) / [Free3D variant](https://free3d.com/3d-model/commodore-amiga-500-computer-with-monitor-9395.html) | $35 (TS) / $79 (Free3D, multi-format) | TS also lists a C64 at ~$19 and a PBR low-poly "retro computer" at ~$50 |
| Commodore old computer Collection (3 PBR models) | [CGTrader](https://www.cgtrader.com/3d-model-collections/commodore-old-computer-collection) | $45, royalty-free | Blender + Substance, FBX/OBJ/BLEND |
| Commodore 1084S CRT monitor | [CGTrader](https://www.cgtrader.com/3d-models/electronics/computer/commodore-1084s-monitor-vintage-crt) | Paid, RF | Maya + Substance PBR, non-overlapping UVs |
| Retro Computer Monitor (game-ready) | [CGTrader free](https://www.cgtrader.com/free-3d-models/electronics/computer/retro-computer-monitor) | Free | 2K PBR maps (color/normal/metal/rough) |
| DEC VT100 terminal | [TurboSquid 1820661](https://www.turbosquid.com/3d-models/dec-vt100-video-terminal-3d-1820661), [CGTrader](https://www.cgtrader.com/3d-models/electronics/computer/dec-vt-100-video-terminal), [3DModels.org ($10, incl. glTF)](https://3dmodels.org/3d-models/dec-vt100-video-terminal/), [RenderHub ($9.99)](https://www.renderhub.com/bsw2142/dec-vt100-video-terminal), Sketchfab store (3Dee + Brandon Westlake) | ~$10 each | Your DEC-terminal exhibit is trivially sourceable |
| "Retro computer" free low-poly, 99 hits | [Poly Pizza search](https://poly.pizza/search/retro%20computer) | Free; CC0 (Kenney/Quaternius) & CC-BY (ex-Google Poly) | Macintosh Classic, "Computer 90s", CRT Monitor, "iFruit", Quaternius "Computer Large" — instant stylized fallback for the whole fleet |
| Retro Gadget Pack (2 vintage PCs, CRT TV, VCR, reel-to-reel) | [Fab](https://www.fab.com/listings/e56e5667-9deb-48e4-9193-c2af27e8161f) | Fab Standard license | 1K/2K/4K PNG textures + separate AO/rough/metal |
| Electronics Asset Pack (11 low-poly 90s props) | [Fab](https://www.fab.com/listings/d54d92d3-7c9b-46b8-a9c2-41da865d9da7) | Fab Standard | Includes CRT-era computer, TV, phone |
| SPARCstation | Nothing good commercial found. [3D-printable SPARCstation IPX (piSparc, GitHub)](https://github.com/jonn-reenthused/piSparc), a Sun Blade on 3D Warehouse, misc on [Sketchfab tags/sun](https://sketchfab.com/tags/sun) | — | **Gap item — but a pizza box + real front-panel texture is a 30-minute Blender job** |
| Free BlenderKit retro desktops | [Tiny Retro Computer](https://www.blenderkit.com/asset-gallery-detail/0d42296d-6f1b-4ab1-9f06-a3dbf0b366b4/) etc. | Free RF/CC0 | Pulls directly into Blender |

**Marketplace status note:** the Sketchfab *store* closed and merged into Epic's **Fab** (Oct 2024); Sketchfab.com still hosts free CC-licensed downloads but Epic has signaled winding down Sketchfab's downloadable content, so **archive any free Sketchfab models you rely on now** ([Sketchfab blog](https://sketchfab.com/blogs/community/sketchfab-update-what-you-need-to-know-now-that-fabs-live/), [80.lv on the migration backlash](https://80.lv/articles/historians-are-concerned-about-epic-games-sketchfab-to-fab-migration)). KitBash3D: environment/building kits, nothing retro-computer-specific — not useful here.

### The licensing trap for a web app (important)

Serving glTF from a website means the raw asset is one DevTools tab away from extraction, and stock licenses care:

- **TurboSquid** is the strictest: models must be "contained in proprietary formats so that they cannot be opened or imported in a publicly available software application," and its WebGL carve-out **only whitelists Unity/Unreal/Lumberyard exports — other WebGL delivery (i.e., three.js + glTF) is explicitly prohibited** ([TurboSquid license](https://www.turbosquid.com/licensing)). Strictly read, TurboSquid models cannot legally ship in your app as GLB files.
- **CGTrader** royalty-free requires the model be an "Incorporated Product" that a third party "cannot retrieve on its own" ([CGTrader RF license](https://help.cgtrader.com/hc/en-us/articles/360015124437-Royalty-Free-License)). Meshopt-compressed KTX2 GLBs are a defensible "industry standard measure," but it's a gray zone — worth a one-line message to the seller.
- **Fab Standard** (Personal/Professional price tiers by revenue) is written for interactive products and is the most web-game-friendly of the paid options ([Fab licensing docs](https://dev.epicgames.com/documentation/fab/licenses-and-pricing-in-fab)).
- **Clean paths:** CC0 (Kenney, Quaternius, BlenderKit CC0) — zero obligations; CC-BY (Poly Pizza's ex-Google models) — add an attribution page; **AI-generated on a paid plan** (Meshy/Tripo/Rodin grant ownership/commercial rights) or TRELLIS.2 (MIT); and your **own Blender models/scans** — fully yours.
- Trademark footnote: Commodore/Atari/Apple badges on replicas in a non-commercial museum app are low-risk and universally practiced by the stores above, but it's one more reason to keep the app non-commercial or keep logos subtle if you ever publish widely.

## 4. Photogrammetry of a real collection — verdict: not for the fleet

- **Tooling is excellent and free now:** Epic rebranded RealityCapture as **RealityScan 2.0** (June 2025; 2.1 in Nov 2025) — free below $1M revenue, AI background masking, phone capture app ([CG Channel](https://www.cgchannel.com/2025/06/epic-games-releases-realityscan-2-0-and-realityscan-mobile-1-7/), [realityscan.com](https://www.realityscan.com/news/realityscan-20-new-release-brings-powerful-new-features-to-a-rebranded-realityscan)). Phone apps: **KIRI Engine** ($6.99/mo, best free tier, cloud reconstruction, strong on Android), **Polycam** (Pro $17.99/mo, most export formats); **Luma AI is 3DGS-only and no longer actively updated** — not a mesh pipeline ([2026 comparison](https://swiftwand.com/en/smartphone-3d-scanning-app-comparison-2026-en/)).
- **Your subjects are the pathological case:** uniform featureless beige (nothing for feature matching to lock onto), glossy dark plastic and specular CRT glass (view-dependent highlights corrupt both geometry and albedo). Workarounds are real but lab-grade: **cross-polarization** (polarizing film on the flash + CPL on the lens, black-velvet environment) ([Pix-Pro guide](https://www.pix-pro.com/blog/cross-polarization), [Sketchfab community guide on reflective objects](https://sketchfab.com/blogs/community/capturing-reflective-objects-in-3d/)) or vanishing scanning spray (AESUB blue) — which kills the specular problem but also destroys the texture pass, and you likely don't want to spray a vintage collection.
- **Hobbyist verdict:** an evening per machine, plus cleanup, for geometry a box-modeler beats in 30 minutes. **The practical harvest is textures, not meshes**: straight-on, diffuse-lit photos of front panels, badges and keyboards → perspective-correct in any image editor → albedo decals on simple modeled geometry. That preserves the authentic labels AI can't produce, at zero mesh-cleanup cost.

## 5. Blender as the hub — non-artist, agent-driven

- **Export best practice** ([Khronos Blender glTF I/O post](https://www.khronos.org/blog/blender-gltf-i-o-support-for-gltf-pbr-material-extensions), Blender manual): materials must be **Principled BSDF** with image textures plugged directly (base color, ORM occlusion-roughness-metallic packing, normal); Mapping-node transforms export as `KHR_texture_transform`; anything procedural must be **baked** (Cycles bake, tangent-space normal defaults are glTF-correct); PNG/JPEG textures in the glTF (KTX2 conversion happens post-export in glTF-Transform, don't fight it in Blender).
- **Kitbashing workflow for you:** import purchased FBX/BLEND → apply scale/rotation → join per-machine → merge to one material with one texture atlas where possible (draw calls, see §6) → export GLB per machine type. A consistent real-world scale (1 unit = 1 m) across all 33 exhibits saves endless pain in R3F.
- **Agent-driven cleanup — this is your leverage point:** `blender --background --python script.py` is fully scriptable (bpy: import, `bpy.ops.object.transform_apply`, Decimate modifier, Smart UV Project, bake AO, `bpy.ops.export_scene.gltf`). Batch all 15 machine types with one reviewed script — exactly the shape of work Claude Code/Codex does well, with a render-to-PNG check per model as the verification step (same philosophy as your framebuffer-verification rule).
- **Blender MCP** (free, open source — [blender-mcp ecosystem](https://blendermcp.org/), [ClaudeLog notes](https://claudelog.com/claude-code-mcps/blender-mcp/)) gives Claude a live bidirectional bridge: create/modify objects, materials, lighting, run arbitrary Python, and notably **pull Poly Haven assets and drive Hyper3D Rodin / Hunyuan3D generation from inside Blender**. Caveats: Blender 4.2+, no geometry-nodes editing. For your repetitive-batch use case I'd still prefer reviewed headless scripts (deterministic, CI-able); MCP shines for interactive "fix this one model" sessions.

## 6. Web delivery — toolchain and budgets

**Toolchain (settled consensus):**

- **[glTF-Transform](https://gltf-transform.dev/)** (Don McCurdy) as the programmable optimizer: `gltf-transform optimize in.glb out.glb --compress meshopt --texture-compress ktx2` covers dedup, prune, weld, simplify, meshopt geometry compression and KTX2/BasisU textures in one pass. **[gltfpack/meshoptimizer](https://meshoptimizer.org/gltf/)** is the fast single-binary alternative (`-cc -tc`) and its `-si` simplification is a cheap LOD generator.
- **Draco vs meshopt:** Draco compresses geometry hardest (90–95%) but costs ~100 ms+ WASM decode per load; **meshopt + brotli reaches similar wire size with near-zero decode cost** — the right choice when you're serving many models from a home server ([three.js forum](https://discourse.threejs.org/t/compression-draco-ktx2-example/31382), [meshoptimizer docs](https://meshoptimizer.org/gltf/)). Use meshopt.
- **KTX2 is not optional on mobile:** PNG/JPG textures decompress to raw RGBA in VRAM — a 200 KB PNG can occupy 20 MB+ of GPU memory, and real-world conversions report 300 MB → 30 MB VRAM ([Wawa Sensei on r3f KTX2](https://wawasensei.dev/tuto/fix-loading-model-freezes-threejs-react-ktx2), [Krapton r3f mobile deep-dive](https://www.krapton.com/blog/boosting-react-three-fiber-mobile-performance-in-2026-a-deep-dive-d6105c)). Rule: **ETC1S for albedo/AO, UASTC for normal maps.**
- **R3F integration:** [`gltfjsx --transform --instance`](https://github.com/pmndrs/gltfjsx) runs glTF-Transform for you and emits typed components with instanced re-occurring geometry — made for "10–15 models × 33 placements." drei `useGLTF` ships Draco + meshopt decoding; KTX2 needs the transcoder wired once via the loader-extensions callback (see [drei discussion #1335](https://github.com/pmndrs/drei/discussions/1335), [issue #2639](https://github.com/pmndrs/drei/issues/2639)). Use drei `<Detailed>` for LOD swaps between room view and close-up.

**Budgets I'd commit to** (grounded in the mobile guidance above: ≈5 MB mobile / 20 MB desktop scene downloads, ≤50 mobile / ≤100 desktop draw calls):

| Asset class | Triangles | Textures (KTX2) | GLB wire size |
|---|---|---|---|
| Hero machine (close-up, 2 LODs) | 20–60k (LOD0), 5–10k (LOD1) | 2K albedo, 1K normal/ORM | 1–2 MB |
| Mid machine | 5–15k | 1K set | 300–700 KB |
| Filler/stylized (Poly Pizza class) | 0.5–3k | 512 or vertex colors | ≤150 KB |
| **Scene total (15 uniques + room)** | ≤1.5M rendered after instancing | — | **≤25 MB desktop, ~10 MB before-interactive mobile** (lazy-load hero LOD0s on approach) |

One atlas/material per machine type; with instancing that's ~15–20 draw calls for all 33 exhibits — comfortably inside mobile budget. Serve with brotli (meshopt profits from it) and immutable cache headers; on your self-hosted HTTPS server this is config, not infra.

## Annotated link list

**AI generation:** [StraySpark: Meshy/Rodin/Tripo/CSM hands-on, Apr 2026](https://www.strayspark.studio/blog/generative-3d-tools-comparison-meshy-rodin-tripo-csm-2026) (most honest hosted-tool comparison found) · [ideate.xyz 5-way test incl. TRELLIS/Hunyuan](https://ideate.xyz/blogs/posts/ai-3d-model-comparison-trellis-tripo-meshy-rodin-hunyuan) · [microsoft/TRELLIS.2](https://github.com/microsoft/TRELLIS.2) (MIT, 4B, GLB+PBR out, 24 GB VRAM) · [Hunyuan3D-2.1 LICENSE — EU excluded](https://github.com/Tencent-Hunyuan/Hunyuan3D-2.1/blob/main/LICENSE) + [HN thread](https://news.ycombinator.com/item?id=42786403) · [Meshy pricing/ownership](https://www.meshy.ai/pricing) + [free-plan CC-BY terms](https://help.meshy.ai/en/articles/15696428-what-is-included-on-the-free-plan) · [Tripo pricing](https://www.tripo3d.ai/pricing) · [Hyper3D/Rodin pricing](https://hyper3d.ai/pricing) · [Tripo × Midjourney guide](https://www.tripo3d.ai/blog/tripo-user-guide-xi-combining-with-midjourney) · [image-to-3D failure modes](https://www.qwe.edu.pl/tutorial/create-ai-generated-3d-models-from-images/)

**Buying:** [3Dee's Computers & Consoles collection](https://sketchfab.com/mellydeeis/collections/computers-and-consoles-34dd957dd8594c598e00ce62a765d72c) (→ fab.com/sellers/3Dee) · [Poly Pizza "retro computer" (99 free)](https://poly.pizza/search/retro%20computer) · [CGTrader Commodore collection $45](https://www.cgtrader.com/3d-model-collections/commodore-old-computer-collection) · [TurboSquid Amiga 500](https://www.turbosquid.com/3d-models/commodore-amiga-500-computer-with-monitor-3d-model-2061326) · [Fab Retro Gadget Pack](https://www.fab.com/listings/e56e5667-9deb-48e4-9193-c2af27e8161f) · [TurboSquid license — WebGL restriction](https://www.turbosquid.com/licensing) · [CGTrader RF license](https://help.cgtrader.com/hc/en-us/articles/360015124437-Royalty-Free-License) · [Sketchfab→Fab status](https://sketchfab.com/blogs/community/sketchfab-update-what-you-need-to-know-now-that-fabs-live/)

**Scanning:** [RealityScan 2.0 release](https://www.realityscan.com/news/realityscan-20-new-release-brings-powerful-new-features-to-a-rebranded-realityscan) · [2026 phone-scanning comparison](https://swiftwand.com/en/smartphone-3d-scanning-app-comparison-2026-en/) · [cross-polarization setup](https://www.pix-pro.com/blog/cross-polarization) · [Sketchfab: capturing reflective objects](https://sketchfab.com/blogs/community/capturing-reflective-objects-in-3d/)

**Blender & delivery:** [Khronos: Blender glTF PBR extensions](https://www.khronos.org/blog/blender-gltf-i-o-support-for-gltf-pbr-material-extensions) · [Blender MCP](https://blendermcp.org/) · [glTF-Transform](https://gltf-transform.dev/) · [gltfpack](https://meshoptimizer.org/gltf/) · [pmndrs/gltfjsx](https://github.com/pmndrs/gltfjsx) · [KTX2 in r3f (Wawa Sensei)](https://wawasensei.dev/tuto/fix-loading-model-freezes-threejs-react-ktx2) · [r3f mobile performance 2026](https://www.krapton.com/blog/boosting-react-three-fiber-mobile-performance-in-2026-a-deep-dive-d6105c) · [utsubo: 100 three.js performance tips](https://www.utsubo.com/blog/threejs-best-practices-100-tips)

**Bottom line:** buy 3Dee/CGTrader heroes for the iconic machines (budget ~$100–200 total, prefer Fab/CC-clean licenses over TurboSquid for glTF delivery), fill with Poly Pizza CC0/CC-BY, box-model the SPARCstation and DEC terminal yourself in Blender with photo-derived front-panel textures, reserve Meshy/TRELLIS.2 for background props, run everything through a headless-Blender cleanup script and `gltf-transform optimize` (meshopt + KTX2), and load via gltfjsx-generated instanced components with two LODs.
