# Midjourney recreation prompts for the 9 reference photos (v2 — Codex-derived)

The director's original photos are **reference-only and are never committed**;
they live on the dev box at `~/scene-v2-reference/originals/`. Per the
standing rule, **Codex (`codex exec -i`) described each original photo**
(exhaustive inventory + a ≤95-word Midjourney prompt; full descriptions in
`~/scene-v2-reference/descriptions/`), and those prompts — with real brand and
model names, per the director's call — replace the v1 hand-written ones (v1 in
git history). Picked upscales get committed here as `ref-XX-mj.png` and serve
as the in-repo visual anchor + `--sref` style source for later 2D art.

Original-file ↔ reference mapping (originals stay off-repo):

| ref | original file | shot |
|-----|---------------|------|
| ref-01 | 2-1.jpg | hall-wide from front-right, Apple sign + two jackets |
| ref-02 | 2-2.jpg | shelf wall + display cases, SVI-728 poster |
| ref-03 | 2-4.jpg | 1970s shelf bays: IBM 5100, Wang 2200, Teletype 33 |
| ref-04 | 3-1.jpg | corner w/ boxed printers, Tandy/Vendex cartons, luggables (portrait) |
| ref-05 | 3-2.jpg | desk-row aisle perspective, ATARI display (portrait) |
| ref-06 | 3-3.jpg | Philips vignette: P2000T, pinstripe wallpaper, walnut desk |
| ref-07 | 3-4.jpg | pine archive wall: PET/CBM, C64 + 1084S cartons, desk nook |
| ref-08 | 6-2.1500.jpg | depot: teal steel shelving, Compucolor II/OSI, 1977–78 placards |
| ref-09 | 11-2.jpg | Apple display wall: Lisa, Mac 128K/Plus, Apple II, lightbox |

Generation workflow (xdesk VNC Chrome, CDP :9222; driver scripts in
`~/e2e/mj*.mjs` on the dev box): submit prompt + flags → judge grid against
the Codex inventory → upscale pick (Subtle) → download → commit. Flags
appended to every prompt: `--style raw --ar <as below> --sref <ref-01 anchor>
--fast`. Anchor = the director-approved ref-01 pick
(`https://cdn.midjourney.com/a29b9d38-1242-4766-867c-e1bbf0580067/0_3.png`).

---

## ref-01 — `--ar 3:2`

Photorealistic editorial interior photograph of a real retro-computer museum,
wide 3:2 landscape, eye-level 20mm viewpoint from the front-right corner
looking diagonally toward the rear-left. Low suspended acoustic-tile ceiling
packed with cool-white fluorescent panels, dark blue-gray carpet, warm
knotty-pine right wall, white columns, rear windows and double doors. Dense
rows of beige 1980s-90s Apple II systems, Macintosh 128K/SE/Classic computers,
CRT monitors, keyboards and drives on mismatched school tables and chairs,
several cyan/green screens glowing. Large rainbow Apple Computer sign, two red
Apple jackets, shelves of boxed hardware, loose cables.

## ref-02 — `--ar 3:2`

Photorealistic editorial interior photograph of a crowded real retro-computer
museum, landscape, eye-level 24mm wide-angle view facing the back wall. Low
gray acoustic-tile ceiling packed with cool fluorescent panels, dark blue-gray
carpet, white walls and left windows. Honey-colored wooden shelves overflow
with yellowed beige and black 1970s-1990s CRT computers, early Apple Macintosh
systems, Commodore 64 box, Spectravideo SVI-728 poster, manuals and colorful
cartons. Two worn cream glass display cabinets centered foreground, computer
tables left, red upholstered chairs and glowing green/cyan CRT workstations
right, dense cables, museum placards, deep focus.

## ref-03 — `--ar 3:2`

Photorealistic editorial interior photograph of a real 1970s retro-computer
museum display: three joined honey-pine open shelving bays plus a shorter
door-backed bay, packed with an IBM 5100, Wang 2200-series cabinet workstation
with green CRT, Teletype Model 33 ASR, dual 8-inch floppy cabinet, charcoal
front-panel microcomputers, exposed electronics, reels, disk packs, cables,
and white museum placards. White partition walls, suspended acoustic-tile
ceiling, dark teal carpet, orange floral wallpaper strip. Cool diffuse
fluorescent daylight from left. Straight-on eye-level 20mm wide-angle,
symmetrical landscape framing, no people.

## ref-04 — `--ar 2:3` (portrait)

Photorealistic editorial interior photograph of a cramped retro-computer
museum, portrait orientation, eye-level wide-angle view diagonally into a
display corner. Three glass wall shelves hold Star LC24-10 and multicolour
printer boxes, Tandy 1000 and Vendex HeadStart Explorer cartons, vintage
software, and dark canvas Apple rainbow-logo computer bags. Below, densely
stacked yellowed 1970s-80s beige CRT microcomputers, keyboards and
floppy-drive units; one screen glows cyan text, others are off. Long white
desk, two cobalt-blue office chairs, leafy plant, cassette boombox, placards,
tangled cables, gray museum banner, acoustic-tile ceiling, neutral fluorescent
light, authentic clutter.

## ref-05 — `--ar 2:3` (portrait)

Photorealistic editorial interior photograph of a cramped real retro-computer
museum, portrait orientation, eye-level view diagonally down a carpeted aisle;
right side packed with honey-wood school desks and bent-plywood chairs
supporting bulky cream, gray and charcoal 1970s-80s CRT terminals, keyboards,
printers and taped cardboard risers, red drive lights glowing; cropped massive
black computer keyboard and blue-black CRT in foreground. Back wall of
vertical knotty pine, ATARI display, beige Apple Macintosh-like computer, cyan
text on one small CRT, framed blue computer poster, museum placards, metal
electronics shelving left, warm soft light, shallow background focus.

## ref-06 — `--ar 3:2`

Photorealistic editorial interior photograph of a 1980s Philips retro-computer
museum display, straight-on eye-level landscape view, 35mm lens. Center a
walnut double-pedestal desk and black tubular chair with orange-red striped
cushions against multicolor vertical-pinstripe wallpaper, analog clock and
framed PHILIPS advert. A powered Philips P2000T with small CRT displays a
calculator grid. Crowded gray metal shelving left and pine shelving right with
beige Philips P2000M systems, monochrome CRTs, floppy drives, manuals, binders
and large black printer; blue-gray carpet, cool fluorescent light, open museum
aisle left, extinguisher, tangled cables and Philips boxes.

## ref-07 — `--ar 3:2`

Photorealistic editorial interior photograph of a cramped retro-computer
museum, landscape orientation, eye-level straight-on wide-angle view.
Floor-to-ceiling honey-colored wooden shelving packed with beige, gray and
black 1970s-1980s CRT computers, Commodore PET/CBM terminals, Commodore 64,
disk drives and printers; vintage Commodore 64, VIC Monitor and 1084S cartons
above. Most green screens dark, several glowing cyan or red. Central desk with
turquoise CRT, cream keyboard, white lamp and taupe chair; glass display case
left, white table and red chairs right, museum placards, fluorescent drop
ceiling, gray tiled floor, deep focus.

## ref-08 — `--ar 3:2`

Photorealistic editorial interior photograph of a retro-computer museum
storeroom, straight-on eye-level landscape framing, 35mm lens. Three adjoining
dark teal industrial steel shelving bays fill the frame against an off-white
wall, crowded with 1977-1978 computers: woodgrain Compucolor II CRT with
keyboard, cream OSI computer, beige all-in-one CRT terminals, monochrome
monitors, typewriter-style keyboards, calculator consoles, open wooden
electronics chassis. All screens off, dusty reflective glass. Top shelf:
archive boxes, brown carton, black Philips service case, torn Worms Armageddon
PlayStation poster. Museum placards, manuals, cables, empty gaps; cool diffuse
overhead industrial lighting, muted teal-and-orange filmic color grade.

## ref-09 — `--ar 3:2`

Photorealistic editorial interior photograph of a real 1980s retro-computer
museum, landscape orientation, eye-level wide-angle view from front-left
looking obliquely down a long display wall. Honey knotty-pine vertical
paneling, blue-gray carpet, white suspended acoustic-tile ceiling with cool
fluorescent panels, central white boxed column. Mismatched school desks hold
beige Apple II systems, an Apple Lisa, Macintosh 128K/Plus computers, glowing
green and cyan CRTs, keyboards and floppy drives; gray swivel chairs and
orange tubular-steel chairs. Huge framed rainbow Apple Computer poster, red
Apple jacket, wooden shelf, Apple Computer lightbox, placards, manuals,
trailing cables, warm documentary color grade.

---

## Picked generations (2026-07-27, MJ V8.2, fast mode)

All picks upscaled (Subtle) and committed as `ref-XX-mj.webp`. Grid position
1–4 = TL/TR/BL/BR. Upscale job UUIDs (cdn.midjourney.com/<uuid>/0_0.png):

| ref | grid pick | upscale uuid |
|-----|-----------|--------------|
| ref-01 | #4 | 99609245-aff9-473e-bea8-371495ec8fd8 |
| ref-02 | #1 | 4b9fe05f-5dec-4342-851c-727d27afd6ae |
| ref-03 | #2 | 09561e24-219d-415f-ad85-8446529f8f29 |
| ref-04 | #4 | 06563db9-8807-489b-ab65-c1c613be5a7d |
| ref-05 | #2 | fc7c6977-052d-4833-8aba-25da72b1eabe |
| ref-06 | #1 | c1bd4fc8-90b5-4dd9-8cab-2d9cbaf33bd3 |
| ref-07 | #3 | 33d7ec73-a3cf-4612-8726-f625b06c58e0 |
| ref-08 | #2 | f407a904-0438-4f37-9467-3262c1e002c9 |
| ref-09 | #2 | ede7a66c-363c-4f95-ab53-ed9b80ea1d34 |
