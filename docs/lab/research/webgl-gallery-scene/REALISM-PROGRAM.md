# Realism program — closing the gap to the reference museum

Started 2026-07-28. Trigger: director-ordered comparison of the 9 reference
photos against the shipped /museum scene. Formal Codex gap judgment (17 images,
archived at `~/scene-v2-reference/review/gap-2026-07-28/gap-judgment.md`)
scored the scene **3/10** and ranked eight gap themes. This document is the
standing plan; each wave is a small codexit task with its own Codex-judge
screenshot loop, merged serially by the orchestrator.

## Judgment summary (ranked by score impact)

1. **Materials read as flat placeholders** — every room surface is a flat
   `meshStandardMaterial` color; photos have mottled carpet, knotty pine,
   laminate grain, aged plastics. Fix first; everything else is judged on top
   of it.
2. **Lighting lacks depth/grounding** — no contact shadows, no window-side
   gradient; objects float. (After materials.)
3. **Suspended acoustic ceiling missing as a construction system** — smooth
   slab + floating white rectangles instead of a 600 mm T-grid with recessed
   troffers in bays.
4. **Collection not packed vertically** — the ref-07/11-2 archive shelf wall
   (floor-to-ceiling pine, packed machines, box skyline) does not exist.
5. **Set dressing / museum identity sparse** — no posters, memorabilia,
   clocks, extinguisher, plants, manuals, varied placards.
6. **Repetition + perfect alignment** — identical desks/chairs, centered
   machines, parallel rows; needs seeded jitter + furniture variants.
7. **Scale/camera feel too expansive** — verify module dims, tighten focal
   feel, use dressing to compress aisles.
8. **Grade too neutral/synthetic** — warm editorial grade, lifted blacks —
   LAST, after materials + light.

Keep (do not regress): floor plan & era zoning, machine fleet silhouettes,
decade legibility, camera pin set.

## Waves

| Wave | Task | Theme(s) | Port | Depends on |
|------|------|----------|------|-----------|
| R1 | `r1-materials` — room-surface PBR texture set (MJ-sourced) wired into shell + desks | 1 | 5241 | — |
| R1 | `r1-ceiling` — real T-grid ceiling system, recessed troffers, perimeter reveal | 3 | 5242 | — |
| R1 | `r1-shelfwall` — packed archive shelf wall (Blender bays + instanced machines + boxes) | 4 | 5243 | — |
| R2 | `r2-light-ground` — window gradient, contact shadows/AO, troffer balance | 2 | 5244 | R1 |
| R2 | `r2-variety` — seeded jitter, chair/desk variants, per-machine tint variation | 6 (+1) | 5245 | R1 |
| R2 | `r2-dressing` — posters, memorabilia, placard variants, plants, boxes, clock, extinguisher | 5 | 5246 | R1 |
| R3 | `r3-scale-camera` — module/FOV audit, aisle compression | 7 | 5247 | R2 |
| R3 | `r3-grade` — final editorial grade | 8 | 5248 | R2 |
| R3 | `r3-qa` — full 8-pin × 9-ref judge gate (target ≥7/10), prod deploy | all | 5249 | R3 |

## Outcome (program closed 2026-07-29)

Score trajectory on the fixed rubric: **3/10 → 5/10 (R2) → 6/10 (R3) →
7/10 (R4)** — target ≥7 met. Every wave landed on main gate-green with
interaction E2E passing; production redeployed after each integration.
Waves as run: R1 room-textures/T-grid-ceiling/archive-wall → R2
variety/light-ground/dressing → R3 grade/spatial-compression/density → R4
baked hall lightmaps (A/B-proven Cycles bake, `blender/gen_hallbake.py` +
`hallLightmaps.ts`) + per-tile exhibit identity (`machineIdentity.ts`: 37
era-correct tints + nameplates + station kits). Remaining themes recorded by
the final judge (for any future R5): micro material variation
(roughness/wear/grime), curatorial rhythm (less grid, asymmetric focal
displays), object fidelity (silhouette diversity, cable disorder). Judgments
archived under `~/scene-v2-reference/review/codex-judgments/r*/`.

Rules of engagement (all tasks): dev server via `scripts/dev/scene-v2-server.sh`
on the assigned port only (5197/5199/5231 forbidden); judge loops via
`scripts/dev/codex-visual-judge.sh` with round caps (texture 2, scene geometry
3–4, final integration 1); reference photos stay outside the repo; FINISH
protocol = fetch + rebase origin/main + resolve conflicts + full quality gate +
single commit, no push. ≤3 capture-heavy tasks concurrently; only
`r1-materials` may drive the Midjourney Chrome (CDP :9222).
