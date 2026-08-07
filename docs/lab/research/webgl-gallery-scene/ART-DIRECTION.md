# Scene v2 — Art Direction (director-approved reference set, 2026-07-27)

**Authority:** this document + the nine reference photos in `reference/` are the
visual target for the scene-v2 rebuild. The user acts as director; agents build
to THIS, not to generic "3D museum" taste, and **not** to the dark-spotlit-hall
direction assumed in early drafts of the research (superseded — see "The big
pivot" below). The obsolete art-direction transcodes formerly stored in
`spa/public/assets/photos/` were removed at cutover.

**Tooling constraint (hard):** the director does not open Blender or any 3D
app. All Blender work is agent-written headless `blender --background
--python` scripts; the director reviews *rendered screenshots only* and gives
feedback in words + reference-photo pointers.

## The big pivot

Scene v1 (and the generic WebGL-museum cliché) is a dark dramatic hall where
glowing CRTs carry the room. The reference photos define the opposite and we
build THAT:

> **A bright, flat-lit, functional, lived-in computer museum room.** Suspended
> acoustic-tile ceiling with recessed fluorescent troffers, daylight from a
> shop-window wall, blue-grey carpet, warm pine paneling, school desks and
> chairs, machines packed densely on pine shelves. Intimate room scale, not
> cathedral scale. Editorial-photo grade: slightly warm, gently lifted blacks,
> honest colors.

Why this is right for us: it is distinctive (nobody's WebGL museum looks like
this), authentic to a *living* museum, technically kinder (even light bakes
beautifully, minimal bloom, no shadow drama to fake), and powered-off machines
— dark grey-green glass with room reflections — are part of the look instead
of a failure state. A few live glowing screens scattered among dark ones
(ref-07's green terminal inset in the shelf wall) is the money shot.

## Reference photo manifest

Files go in `reference/` (director supplies originals; see reference/README.md).

| ID | File | What it anchors |
|----|------|-----------------|
| ref-01 | `ref-01-hall-wide.jpg` | Master shot of front-of-house: ceiling grid + troffers, window wall with daylight, carpet, desk rows, pine accent wall w/ Apple lightbox, poster row above windows, overall density + palette. |
| ref-02 | `ref-02-shelfwall-cases.jpg` | Mid-room composition: packed shelf wall behind, glass display cases (worn white bases) mid-floor, red chairs, retail-box skyline on top shelves, era mixing. |
| ref-03 | `ref-03-single-shelf-unit.jpg` | One pine plank shelf unit as a "unit of exhibition": machines + leaning white QR placards + big-box-on-top + tape drives below; orange floral wallpaper sliver as accent. |
| ref-04 | `ref-04-corner-luggables.jpg` | Corner detail: white slatwall panels, glass wall shelves w/ boxed printers + Tandy boxes + bags, banner flag, stacked luggables on grey table, blue office chairs, coiled cables, laminated placard, plant, live blue DOS screens. |
| ref-05 | `ref-05-desk-row-perspective.jpg` | Desk-row rhythm: chair+desk+machine repeating, placards standing by each machine, carpet→tile floor transition, pine wall with framed poster, machines under covers as background filler. |
| ref-06 | `ref-06-philips-vignette.jpg` | The brand-vignette pattern: striped-wallpaper accent panel + wall clock + framed brand poster; antique dark-wood pedestal desk + orange striped chair; flanking étagère shelving; fire extinguisher; brand cardboard box as floor prop. |
| ref-07 | `ref-07-pine-shelf-wall.jpg` | THE archive wall: floor-to-ceiling honey-pine grid packed with machines, Commodore/MB retail boxes on top, placards, **desk+chair inset into the wall with one live green-phosphor terminal among dark CRTs**, glass case foreground (Epson HX-20), grey tile floor zone. |
| ref-08 | `ref-08-depot-steel-shelving.jpg` | The depot (second space / stretch goal): boltless black steel shelving, white hardboard decks, laminated year-header placards (1977/1978), banker's-box rows on top, game standee, industrial ceiling, cooler flatter light. |
| ref-09 | `ref-09-apple-corner.jpg` | Hero vignette: Apple Computer lightbox on pine, red jacket hung on wall, small wooden shelf w/ sign, Macintosh + desk lamp + lavender plant on school desk, Apple II/III row, orange chairs, kidney/typist desks, white ceiling band over pine. |

## Palette (approx, from photos)

| Element | Approx | Notes |
|---|---|---|
| Carpet | `#4f5a63` blue-grey | slight mottle, low sheen |
| Tile floor zone | `#b4b2ad` | light grey, subtle grid, satin |
| Pine paneling/shelves | `#c8933f`–`#d9a45a` | honey, visible knots `#8a5a28`, vertical T&G on walls |
| Walls | `#f2efe9` warm white | plaster/panel; slatwall in corners |
| Ceiling tiles | `#e8e6e0`, grid `#cfccc4` | 600×600 |
| Machine putty/beige | `#d6cbb2`, yellowed `#cfc0a0` | non-uniform yellowing |
| Desk tops | `#d1a86b` beech | grey steel legs `#b9bcbe` |
| Accents | red `#b5342c`, orange `#d97427`, blue upholstery `#7a8894` | chairs, box art, memorabilia |
| Depot shelving | `#2b2d2f` steel, decks `#d8cfc0` | ref-08 only |

## Lighting plan

- **Primary:** rows of recessed fluorescent troffers in the ceiling grid,
  ~4000K neutral-cool, even coverage — baked in Cycles as emissive rectangles
  in the tile grid. Visible fixtures ARE part of the look (ref-01/02).
- **Secondary:** shop-window wall (one long side) with soft overcast daylight
  ~6000K; brighter zone + gentle direction near the windows (ref-01).
- **No** dramatic spots, no god rays, no colored gels, no vignette-as-mood.
- **Screens:** emissive surfaces that read "lit from within" against bright
  ambience; troffer/window reflections visible on glass. Bloom minimal
  (threshold 1.0; only screens ever cross).
- **Grade:** slightly warm exposure, gently lifted blacks, honest saturation —
  match the editorial look of the reference photos, tuned via leva then baked
  into constants. AgX tone mapping.

## Space plan (draft — director to confirm)

One main hall (front-of-house), four walls with distinct characters:

1. **Window wall** (ref-01 left): shop windows + daylight, poster row above,
   low cabinets/printers under the sills.
2. **Pine accent wall** (ref-01/09): brand vignettes — Apple corner (lightbox,
   jacket, memorabilia shelf) and 1–2 more (Philips corner per ref-06 with
   striped-wallpaper panel + antique desk). Hero machines on desks along it.
3. **Archive shelf wall** (ref-07): floor-to-ceiling pine grid packed with
   machines + retail-box skyline. Mostly non-interactive dressing (dark CRTs,
   duplicates, filler) with **1–3 live tiles inset at desk height** (serial
   terminal / 9front style green phosphor) — the ref-07 money shot.
4. **Fourth side:** corner detail per ref-04 (slatwall, glass shelves, boxed
   software, luggables) transitioning to the entrance.
5. **Mid-floor:** desk rows (ref-05 rhythm) carrying most of the ~20
   interactive tiles — each machine on a school desk with a chair and a
   standing placard; plus 1–2 glass display cases (ref-02) as dressing.
   Carpet everywhere except a grey-tile strip along the shelf wall (ref-05/07).
6. **The depot (ref-08): stretch goal** — a second, plainer space (steel
   shelving, year placards, banker's boxes) reachable later; natural home for
   "era timeline" browsing. Not in v2 scope unless cheap.

Exhibit mapping stays registry-driven: slots exported as named Empties from the
agent-generated hall .blend; the registry assigns tile → slot. Desk slots =
interactive; shelf slots = ambient/low-rate; poster/showcase tiles live as
framed posters or boxed displays.

## Set-dressing vocabulary (the authenticity layer)

Retail-box skyline on shelf tops (period boxes: worn corners, sun-fade) ·
white A6 placards w/ QR leaning by each machine + laminated year headers ·
framed brand posters + dealer signs + lightbox · memorabilia (jacket, shirt,
flag banner) · coiled keyboard cables + power cords sagging behind desks ·
glass display cases with worn white bases · machines under dust covers as
filler silhouettes · fire extinguisher, wall clock, desk lamps, potted plants
(one lavender on the Mac desk, ref-09) · boxed printers/bags on glass wall
shelves · tape reels/drives on low shelves · orange floral wallpaper sliver
(ref-03) as one-off accent.

Density rule: shelves read as *archive* (packed, touching), desks read as
*hands-on* (one machine + placard + clair space). Do not sanitize; do not
align perfectly; slight rotation jitter (±2–4°) and varied spacing everywhere.

## Scale & camera rules (meters, hard constraints)

- Ceiling 2.8 m; desk tops 0.72 m; chair seats 0.45 m; pine shelf units
  2.0–2.2 m tall; placards A6/A5; ceiling grid 0.6 m.
- Machines at real-world dimensions (spec sheets — see research report 05).
- Camera: standing eye height 1.60 m (browse/idle), seated 1.15–1.25 m at
  focus (pulling up the chair IS the focus metaphor); FOV 35–45, constant;
  keep verticals near-vertical (architectural framing like the photos).

## Screens in bright light (CRT treatment tune)

Glass shell reflections (troffers + window) always visible; powered-off =
dark grey-green glass, NO emissive; powered-on = emissive video with subtle
scanline/phosphor mask, brightness balanced to read clearly without blowing
out; a live screen should look like ref-04/ref-07's — present, not radioactive.
Most shelf-wall CRTs stay dark; that's authentic, and it relaxes the stream
budget (few high-rate textures, many dark/static ones).

## What NOT to do (anti-checklist)

Dark moody hall · spotlight pools · sprite god-rays · full-screen scanline/CA/
noise/heavy vignette · photo billboards as architecture · floating machines on
metal racks · uniform pristine surfaces · perfect grid alignment · neon/cyber
anything · oversized cathedral proportions.
