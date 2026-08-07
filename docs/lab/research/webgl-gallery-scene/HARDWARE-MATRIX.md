# Per-OS hardware matrix

This is the binding hardware specification for the 36-entry Scene v2
integration cohort named in [MODEL-ROADMAP.md](MODEL-ROADMAP.md). The later
`openvms` registry addition is outside this baseline. Re-integration must
follow these complete signatures rather than the older shared-archetype
assignments.

The body, monitor, keyboard, and mouse together form one desk signature. No
two rows have the same complete signature, and successive rows alternate
silhouette, display generation, finish, or input profile. A named body remains
the identity body for each foreign architecture. `Integrated` means that the
part is modeled into the body; `none` is an intentional period-typical
absence. Finish and dressing cues in prose are requirements, not optional
suggestions.

Variant status:

- **Existing:** already exported or an unused variant in the current
  `gen_*.py` generators.
- **Incoming:** `gen_c64`, `gen_amiga`, `gen_8bitwedge`, `gen_homecrt`,
  `gen_lcd`, and `gen_compact`, which are treated as available.
- **New:** a variant specified in the work list below. These are the only
  additions required by this matrix.

## Binding 36-entry matrix

| Order | Entry and one-line era/context | Case or body | Monitor | Keyboard | Mouse | Research basis |
|---:|---|---|---|---|---|---|
| 0 | `freedos` — 1994 community DOS on a thrift-conscious 386/486 | Existing `gen_pizzabox.py` B: low beige desktop, 3.5-inch and 5.25-inch bays | Existing `gen_crt.py` A: compact 13-inch VGA CRT | Existing `gen_keyboard.py` A: compact single-tone AT slab | Existing `gen_mouse.py` A: boxy serial two-button | [FreeDOS history][freedos-history] · [FreeDOS low-end target][freedos-spec] |
| 1 | `kolibrios` — 2004 tiny i586 OS, commonly tried on an already-owned commodity PC | Existing `gen_tower.py` B: late-beige ATX tower | Existing `gen_crt.py` C: deep 15-inch late CRT | Existing `gen_keyboard.py` B: two-tone membrane office board | **New** `gen_mouse.py` D: pale/silver early optical, three-button wheel | [KolibriOS install requirements][kolibri-install] · [2001 coordinated PC set][dimension-review] |
| 2 | `toaruos` — 2011 university-born x86 hobby desktop on a used Core 2-era machine | **New** `gen_tower.py` E: anonymous black business microtower | Incoming `gen_lcd.py` B: black 16:9 LCD | **New** `gen_keyboard.py` F: plain black full-size USB membrane | **New** `gen_mouse.py` E: plain black wired optical | [ToaruOS origin][toaru-about] · [2008 office-tower reference][dc5800] |
| 3 | `win311` — 1992 386/486 small-office desktop | Existing `gen_pizzabox.py` B: low beige desktop | Existing `gen_crt.py` B: 14-inch beige VGA CRT | Existing `gen_keyboard.py` B: two-tone enhanced layout | Existing `gen_mouse.py` A: boxy two-button serial mouse | [Windows 3.1 release context][windows31] · [PS/ValuePoint period and form][valuepoint] |
| 4 | `win95` — 1995 family Pentium upgrade with a newly prominent tower | Existing `gen_tower.py` A: short beige mini-tower | Existing `gen_crt.py` B: 14-inch beige VGA CRT | Existing `gen_keyboard.py` A: simple single-tone 101/102-key board | Existing `gen_mouse.py` B: rounded 1990s ball mouse | [Windows 95 launch exhibit][windows95-launch] · [Gateway 2000 period set][gateway-photo] |
| 5 | `win98se` — 1998 multimedia/home-internet ATX desk | Existing `gen_tower.py` C: tall three-bay beige multimedia tower | Existing `gen_crt.py` C: 15-inch flat-faced late CRT | Existing `gen_keyboard.py` B: two-tone Windows-key membrane board | Existing `gen_mouse.py` B: rounded ball mouse | [Windows 98 period][windows98] · [Deskpro 2000 case families][deskpro2000] |
| 6 | `win2000` — 2000 managed corporate workstation | **New** `gen_pizzabox.py` E: Compaq Deskpro EN-class small-form-factor desktop | Existing `gen_crt.py` C: conservative 15-inch business CRT | Existing `gen_keyboard.py` A: low-profile beige office board | **New** `gen_mouse.py` D: early optical three-button wheel mouse | [Windows 2000 Ready PC program][windows2000-ready] · [Deskpro EN dimensions/design][deskpro-en] |
| 7 | `winxp` — 2001 consumer Pentium 4 desk at the silver/black transition | **New** `gen_tower.py` D: silver-front, graphite-side consumer tower | Incoming `gen_lcd.py` A: early silver-bezel 4:3 LCD | **New** `gen_keyboard.py` E: matching silver/black full-size multimedia board | **New** `gen_mouse.py` D: matching pale/silver optical wheel mouse | [Windows XP unveiling][windowsxp-launch] · [Dell Dimension 8100 coordinated set][dimension-review] |
| 8 | `alpine` — 2005 lightweight server/router OS on a reused office SFF PC | **New** `gen_pizzabox.py` E: reused corporate SFF chassis | Incoming `gen_lcd.py` A: early 4:3 office LCD | Existing `gen_keyboard.py` A: older beige PS/2 board | **New** `gen_mouse.py` D: older optical wheel mouse | [Alpine x86/server targets][alpine-downloads] · [Deskpro EN SFF reference][deskpro-en] |
| 9 | `tinycore` — 2009 ultra-light i486 system keeping a 1990s home PC useful | Existing `gen_tower.py` A: yellowed short mini-tower | Existing `gen_crt.py` A: compact 13-inch CRT | Existing `gen_keyboard.py` A: compact single-tone AT board | Existing `gen_mouse.py` B: rounded ball mouse | [Tiny Core minimum hardware][tinycore-faq] · [Gateway-era home set][gateway-photo] |
| 10 | `ninefront` — Plan 9 Fourth Edition's 2002 PC-terminal context, presented through the later 9front lineage | Existing `gen_tower.py` B: ordinary beige PC terminal host | Existing `gen_crt.py` C: large high-resolution CRT | Existing `gen_keyboard.py` C: deep Model M-like board | **New** `gen_mouse.py` D: three-button optical wheel mouse for button chording | [Plan 9 Fourth Edition model][plan9-about] · [9front PC hardware practice][ninefront-fqa] |
| 11 | `helenos` — 2006 AMD64 research OS on a lab-built consumer workstation | **New** `gen_tower.py` D: silver/graphite carry-over performance tower | **New** `gen_lcd.py` C: black 17-inch 5:4 office LCD | **New** `gen_keyboard.py` F: black USB membrane board | **New** `gen_mouse.py` E: black wired optical | [HelenOS AMD64 context][helenos-amd64] · [HelenOS hardware support][helenos-hardware] |
| 12 | `solaris` — 1994 engineering workstation on Sun SPARC architecture | Existing `gen_pizzabox.py` C: SPARCstation 5-class low square workstation | **New** `gen_crt.py` E: wedge-sided 17-inch Sun/Sony workstation CRT | **New** `gen_keyboard.py` H: wide Sun Type 5-style layout with left function bank | **New** `gen_mouse.py` G: angular three-button workstation mouse | [SPARCstation 5 manual and dimensions][sparc5-manual] · [Sun 17-inch GDM reference][sun-gdm] |
| 13 | `nt351` — 1995 high-end Pentium/486 professional workstation | Existing `gen_tower.py` C: tall beige expansion tower | Existing `gen_crt.py` C: 15-inch professional CRT | Existing `gen_keyboard.py` C: heavy enhanced keyboard | Existing `gen_mouse.py` B: rounded ball mouse | [Windows NT 3.51 workstation context][nt351] · [Deskpro 2000 technical guide][deskpro2000] |
| 15 | `serenityos` — 2018 hobbyist OS on its developer's self-built x86-64 desktop | **New** `gen_modern.py` D: windowed enthusiast mid-tower with visible fan | Incoming `gen_lcd.py` B: modern 16:9 LCD | **New** `gen_keyboard.py` F: black USB keyboard | **New** `gen_mouse.py` E: black optical mouse | [SerenityOS 2018 origin][serenity-origin] · [2018 NZXT H500 reference][nzxt-h500] |
| 16 | `android` — 2008 first-wave consumer Android handset | Existing `gen_phone.py` A: thick HTC Dream-class slider with chin | Integrated 3.2-inch touchscreen | Integrated slide-out hardware QWERTY | Integrated trackball plus touch | [HTC Dream form, date, and dimensions][htc-dream] |
| 17 | `postmarketos` — 2017 Linux project explicitly repurposing old Android phones | Existing `gen_phone.py` C: screw-visible, repairable Fairphone 2-class handset | Integrated replaceable touchscreen module | Integrated on-screen keyboard | `none`: touch-first handset | [postmarketOS introduction][postmarket-intro] · [Fairphone 2 product overview][fairphone2] |
| 18 | `sailfishos` — 2013 Jolla consumer smartphone | Existing `gen_phone.py` B: slim 2013 slab with two-part shell | Integrated 4.5-inch touchscreen | Integrated on-screen keyboard | `none`: touch-first handset | [Sailfish OS history][sailfish-info] · [Jolla phone form and dimensions][jolla-phone] |
| 19 | `templeos` — 2013 x86-64 hobby system deliberately evoking a 640×480-era personal computer | **New** `gen_tower.py` E: unadorned black Core 2-era office tower | Existing `gen_crt.py` B: intentionally retained 14-inch CRT | **New** `gen_keyboard.py` F: plain black wired keyboard | **New** `gen_mouse.py` E: plain black optical mouse | [TempleOS platform and 640×480 constraint][templeos] · [2008 commodity office tower][dc5800] |
| 20 | `reactos` — 2024 x86-compatible Windows reimplementation demonstrated on older business hardware | **New** `gen_pizzabox.py` E: de-badged corporate SFF desktop | **New** `gen_lcd.py` C: black 17-inch 5:4 LCD | **New** `gen_keyboard.py` F: black USB membrane board | **New** `gen_mouse.py` E: black wired optical | [ReactOS x86 release context][reactos-release] · [Deskpro EN SFF reference][deskpro-en] |
| 21 | `haiku` — 2024 x86-64 hobby desktop on a clean contemporary DIY PC | Existing `gen_modern.py` A: dark airflow mid-tower | Incoming `gen_lcd.py` B: modern 16:9 LCD | **New** `gen_keyboard.py` G: compact low-profile wireless board | **New** `gen_mouse.py` E: black optical mouse | [Haiku architecture and requirements][haiku-faq] · [modern airflow-case envelope][corsair-4000d] |
| 22 | `os2warp` — 1996 IBM business desktop with unmistakable PS/2 industrial language | **New** `gen_pizzabox.py` D: PS/2 Model 77-class IBM desktop | Existing `gen_crt.py` C: 15-inch beige IBM-office CRT | Existing `gen_keyboard.py` C: Model M-like buckling-spring board | Existing `gen_mouse.py` B: rounded beige ball mouse | [OS/2 Warp 4 history][os2-history] · [PS/2 Model 77 specification][ps2-model77] |
| 23 | `aros` — 2024 Amiga-descended OS on an x86 enthusiast PC | **New** `gen_tower.py` D: tasteful silver/graphite enthusiast tower | **New** `gen_lcd.py` C: black 5:4 LCD | **New** `gen_keyboard.py` E: silver/black full-size board | **New** `gen_mouse.py` E: black optical mouse | [AROS PC-AT/x86 port][aros-ports] · [AROS hardware FAQ][aros-faq] |
| 24 | `qnx` — 2010 embedded/automotive x86 development station | Existing `gen_modern.py` C: fanless industrial embedded box | **New** `gen_lcd.py` C: compact black 5:4 engineering LCD | **New** `gen_keyboard.py` F: no-frills black USB keyboard | **New** `gen_mouse.py` E: black wired optical | [QNX automotive context in 2010][qnx-2010] · [QNX reference-design practice][qnx-reference] |
| 25 | `msdoswin1` — DOS 6.22 exhibit framing the 1985 Windows 1.01 experience on XT-class hardware | Existing `gen_pizzabox.py` A: full-width IBM XT-class desktop | **New** `gen_crt.py` D: IBM 5151-class 12-inch green-phosphor mono CRT | **New** `gen_keyboard.py` D: XT Model F-style 83-key klacker | Existing `gen_mouse.py` A: boxy two-button serial mouse | [IBM XT museum set][ibm-xt-museum] · [IBM XT technical reference][ibm-xt-manual] |
| 26 | `c64` — 1982 breadbin home computer, dressed for the later GEOS 2.0 interaction | Incoming `gen_c64.py` A: brown breadbin with integrated keyboard | Incoming `gen_homecrt.py` B: 13-inch composite color monitor | Integrated tall-key home-computer keyboard | Existing `gen_mouse.py` A: recolored 1351-class two-button mouse | [Commodore 64 form and period][commodore64] · [Commodore 1702 monitor manual][c1702] |
| 27 | `atarist` — 1985 European 68000 home/creative computer | Existing `gen_atarist.py` A: 1040STF-class wedge with integrated keyboard | **New** `gen_homecrt.py` C: Atari SM124-class high-resolution mono CRT | Integrated low-profile ST keyboard | Existing `gen_mouse.py` A: recolored angular ST-class two-button mouse | [Atari 1040STF setup][atari1040] · [SM124 dimensions and shape][sm124-manual] |
| 28 | `apple2` — 1988 classroom/home Apple IIe exhibit | Incoming `gen_8bitwedge.py` A: generic vented 8-bit wedge, Apple-II-role without copied trade dress | **New** `gen_homecrt.py` D: compact Monitor II-class green mono CRT | Integrated full-travel wedge keyboard | Existing `gen_mouse.py` C: optional square one-button mouse | [Apple IIe integrated form][apple2e] · [Monitor II manual and dimensions][monitorii-manual] |
| 29 | `amiga` — 1987 Amiga 500 home/creative desk | Incoming `gen_amiga.py` A: A500-class keyboard computer | Incoming `gen_homecrt.py` A: 1084-class color RGB monitor | Integrated Amiga keyboard | Existing `gen_mouse.py` A: matching angular two-button mouse | [Amiga 500 standard package and form][amiga500] · [Amiga 500 service manual][amiga-service] |
| 30 | `win11` (showcase) — 2021 mainstream x86-64 custom desktop | Existing `gen_modern.py` A: dark airflow mid-tower | Incoming `gen_lcd.py` B: modern 16:9 LCD | **New** `gen_keyboard.py` F: black full-size USB board | **New** `gen_mouse.py` E: black wired optical | [Windows 11 requirements][windows11-req] · [airflow-case dimensions][corsair-4000d] |
| 31 | `riscos` (showcase) — RISC OS 5 exhibit grounded in Acorn's British education lineage | Existing `gen_acorn.py` A: A3000-class ARM keyboard computer | Existing `gen_crt.py` A: compact 13-inch color CRT | Integrated Acorn keyboard | **New** `gen_mouse.py` G: cream angular three-button workstation mouse | [Acorn A3000 education/form][acorn-a3000] · [A3000 service manual][acorn-service] |
| 32 | `macos` (showcase) — 2024 arm64 compact-desktop desk | Existing `gen_modern.py` B: logo-free ARM mini, avoiding copied trade dress | Incoming `gen_lcd.py` B: thin modern 16:9 display | **New** `gen_keyboard.py` G: pale compact low-profile wireless board | **New** `gen_mouse.py` F: pale low-profile touch-surface mouse | [2024 Mac mini desk reference][mac-mini] · [2024 Mac mini dimensions][mac-mini-spec] |
| 33 | `redstar2` — 2009 DPRK institutional desktop assembled from ordinary imported/OEM PC parts | **New** `gen_tower.py` E: anonymous black/grey Asian-OEM office tower | **New** `gen_lcd.py` C: thick-bezel black 5:4 LCD | **New** `gen_keyboard.py` F: generic black membrane board | **New** `gen_mouse.py` E: generic black optical mouse | [Red Star on white-box PCs][redstar-fastco] · [DPRK computer-lab desks][dprk-labs] |
| 34 | `redstar3` — 2013 DPRK office desktop in the mature flat-panel era | **New** `gen_pizzabox.py` E: plain graphite corporate SFF chassis | **New** `gen_lcd.py` C: black 5:4 LCD | **New** `gen_keyboard.py` F: generic black membrane board | **New** `gen_mouse.py` D: older two-tone optical wheel mouse | [Red Star 3 desktop release][redstar3] · [DPRK flat-screen lab reference][dprk-labs] |
| 35 | `amstradcpc` — 1985 British/European CPC 6128 with its monitor-powered computer set | Existing `gen_amstradcpc.py` B: CPC 6128-class long wedge and integrated disk drive | **New** `gen_homecrt.py` E: matching CTM644-class color monitor | Integrated CPC keyboard | `none`: joystick-era desk, no typical mouse | [CPC 6128 bundled monitor context][cpc6128] · [CTM644 service dimensions][ctm644] |
| 36 | `nt4` — 1996 corporate Pentium desktop, distinct from the IBM OS/2 desk | **New** `gen_pizzabox.py` F: IBM PC 300PL-class corporate desktop | Existing `gen_crt.py` B: 14-inch beige VGA CRT | Existing `gen_keyboard.py` B: quieter two-tone office membrane board | Existing `gen_mouse.py` B: rounded beige ball mouse | [Windows NT 4 hardware list][nt4-hcl] · [PC 300PL technical dimensions][pc300pl] |

### Required desk dressing

These props do not change the component signature, but they prevent the
hardware reuse that remains from reading as copy/paste:

- `freedos`: one dog-eared boot disk and a handwritten `CONFIG.SYS` card.
- `ninefront`: three-button-use placard and a slim network cable, not a
  vintage serial terminal; the exhibit context is a PC terminal.
- `serenityos`: the side window must reveal one fan, a CPU cooler, and tidy
  home-builder cabling.
- `aros`: a small red/white checkered-ball desk ornament, abstracted enough
  not to copy the Amiga logo.
- `qnx`: a loose DB-9/CAN-style development lead and small interface board.
- `redstar2` and `redstar3`: no invented national-brand styling. Keep both
  anonymous, with the older tower versus newer SFF silhouette doing the work.

## New-variants work list

The matrix needs **21 new variants**. All other referenced elements already
exist or are in the named incoming set. Dimensions below are modeling
envelopes in `W × H × D`; where the exact reference is inappropriate to copy,
the geometry keeps its envelope and era cues but removes badges, logos, and
protected trade dress.

| Generator | New variants | Count |
|---|---|---:|
| `gen_pizzabox.py` | D, E, F | 3 |
| `gen_tower.py` | D, E | 2 |
| `gen_modern.py` | D | 1 |
| `gen_crt.py` | D, E | 2 |
| `gen_homecrt.py` | C, D, E | 3 |
| `gen_lcd.py` | C | 1 |
| `gen_keyboard.py` | D, E, F, G, H | 5 |
| `gen_mouse.py` | D, E, F, G | 4 |
| **Total** |  | **21** |

### `gen_pizzabox.py` — 3 variants

- **D — IBM PS/2 business desktop.** Model an IBM PS/2 Model 77-class
  `360 × 115 × 395 mm` chassis: shallow sloped badge/control zone, one
  3.5-inch bay, one low 5.25-inch bay, vertical front vent columns, broad
  planar lid, and four dark feet. The [Model 77 specification][ps2-model77]
  supplies the exact envelope. Keep the shapes and IBM industrial rhythm,
  but omit wordmarks and striped logos.
- **E — turn-of-century corporate SFF.** Model a Compaq Deskpro EN-class
  `318 × 90 × 371 mm` convertible desktop: thin horizontal chassis, single
  optical bay over a 3.5-inch slot, small round power button, side/front
  perforation, and a slightly proud faceplate. The
  [Deskpro EN guide][deskpro-en] supplies dimensions. Neutral trim/material
  parameters must support both warm grey and graphite exhibit finishes.
- **F — late-1990s corporate desktop.** Model an IBM PC 300PL Type 6562-class
  `450 × 128 × 450 mm` desktop: wide square lid, left-side vertical intake,
  offset stacked removable-media bays, narrow control strip, and low dark
  feet. Use the exact [PC 300PL technical envelope][pc300pl], with all
  identity marks removed. Its broad, formal face must not collapse into D's
  compact PS/2 proportions.

### `gen_tower.py` — 2 variants

- **D — 2001 silver/graphite consumer tower.** Model a Dell Dimension
  8100-class `222 × 491 × 453 mm` mid-tower: dark side shell, tall silver
  central face, paired optical bays, a rounded lower intake, and a small
  front-I/O door. The [Dimension 8100 manual][dimension8100-manual] supplies
  the envelope and the [period review][dimension-review] establishes the
  coordinated black/silver look. Avoid the Dell badge and exact front-mask
  contour.
- **E — 2008 anonymous office microtower.** Model an HP Compaq dc5800-class
  `177 × 377 × 428 mm` black/charcoal tower: straight steel sides, recessed
  twin 5.25-inch stack, separate 3.5-inch slot, rectangular power button, and
  a large split perforated lower intake. The [dc5800 QuickSpecs][dc5800]
  supply the `6.95 × 14.85 × 16.85 in` envelope. It should read as an
  inexpensive Asian-OEM/institutional PC when badges are absent.

### `gen_modern.py` — 1 variant

- **D — 2018 windowed hobby build.** Model an NZXT H500-class
  `210 × 460 × 428 mm` mid-tower with one clear side panel, full-length PSU
  shroud, flat front, top/front ventilation seam, visible rear 120 mm fan,
  CPU tower cooler, and restrained internal cabling. The
  [H500 review and dimensions][nzxt-h500] supply the envelope. Keep the
  silhouette generic and omit brand-shaped cable bars or logos.

### `gen_crt.py` — 2 variants

- **D — IBM 5151-class monochrome display.** Model a `380 × 280 × 350 mm`
  12-inch CRT with heavy rectangular bezel, long-persistence green phosphor,
  nearly square side shell, right-lower brightness/contrast knobs, and no
  swivel plinth. The [5151 reference dimensions][ibm5151-dims] and
  [IBM technical reference][ibm-5150-manual] ground the envelope and display
  type.
- **E — 17-inch Sun/Sony engineering display.** Model a warm-grey
  `404 × 426 × 450 mm` 17-inch aperture-grille CRT: wedge sidewalls,
  deep rear taper, broad lower bezel, compact button strip, and a wide
  tilt/swivel foot. Sun's [GDM-17E10 parts reference][sun-gdm] establishes
  the workstation monitor, while the closely related
  [Sony GDM-17E20 manual][sony-gdm17] supplies the dimensional class.

### `gen_homecrt.py` — 3 variants

- **C — Atari SM124-class mono display.** Model a pale-grey
  `325 × 307 × 282 mm` 12-inch CRT with a black inset screen surround,
  crisp chamfered shell, narrow lower ledge, and fixed wedge foot. The
  [SM124 manual][sm124-manual] supplies the `12.8 × 12.1 × 11.1 in`
  envelope. Do not add Atari wordmarks.
- **D — Apple Monitor II-class mono display.** Model a light warm-grey
  `370 × 270 × 318 mm` compact CRT: low horizontal body, tightly radiused
  bezel, top-right power control, central lower tuning control, and
  green-phosphor screen. The [Monitor II manual][monitorii-manual] supplies
  exact dimensions and controls; remove logos and do not reproduce the exact
  vent pattern.
- **E — Amstrad CTM644-class color display.** Model a dark-grey
  `375 × 340 × 365 mm` 14-inch CRT with a broad lower control band, side
  power switch, blocky rear shell, and power-lead cue feeding the CPC body.
  The [CTM644 service manual][ctm644] supplies the exact envelope and confirms
  the monitor-powered computer arrangement.

### `gen_lcd.py` — 1 variant

- **C — 2007–2013 black office 5:4 LCD.** Model a `367 × 384 × 188 mm`
  17-inch display on its tilt stand: thick matte-black bezel, 5:4 panel,
  lower-right button row, shallow CCFL-era rear bulge, rectangular stem, and
  broad oval/rectangular foot. The [EIZO S1703 specification][eizo-s1703]
  supplies the tilt-stand envelope and office context. It must remain visibly
  thicker and squarer than incoming modern LCD B.

### `gen_keyboard.py` — 5 variants

- **D — XT 83-key Model F class.** Model a `485 × 38 × 228 mm` deep beige
  board with a left function-key bank, ten-key numeric block sharing cursor
  functions, no isolated inverted-T cluster, stepped key rows, thick front
  lip, and coiled cable. The [83-key Model F reference][model-f83] supplies
  dimensions and layout.
- **E — 2001 coordinated multimedia board.** Model a silver upper shell with
  graphite palm edge, dark key wells, full navigation/numeric groups, three
  small volume/media buttons, shallow flip feet, and an approximately
  `458 × 25 × 163 mm` standard-PC envelope. The
  [Dimension 8100 review][dimension-review] establishes the coordinated
  finish; the period-appropriate [HP standard keyboard dimensions][hp-kbd]
  establish the envelope. Do not copy Dell's outline or badge.
- **F — generic black office USB board.** Model a `442 × 24 × 127 mm`
  low-cost full-size membrane keyboard: straight front edge, low cylindrical
  keycaps, three status LEDs, tiny media legends, and no palm rest. The
  [Dell KB216 data sheet][dell-kb216] supplies dimensions and mechanism.
  Remove logos and keep the case generic enough for lab, OEM, and DPRK desks.
- **G — compact modern low-profile board.** Model a `279 × 16 × 124 mm`
  wireless 79-key layout with scissor-style shallow round-rect keycaps,
  integrated arrows, no number pad, one-piece low-profile shell, and pale or
  dark material parameter. The [Logitech K380 data sheet][logitech-k380]
  supplies exact dimensions and key count; do not copy its circular key
  shapes or device-switch legends.
- **H — Sun Type 5-class workstation board.** Model a
  `510 × 44 × 182 mm` wide warm-grey board with a vertical left function bank,
  separated navigation island, large numeric pad, top-right power key,
  sculpted rows, and coiled workstation cable. The
  [SPARCstation 5 manual][sparc5-manual] supplies the keyboard dimensions and
  the [Type 5 product notes][sun-type5] ground its distinctive layout. Omit
  Sun legends and logos.

### `gen_mouse.py` — 4 variants

- **D — 2000/2001 three-button optical wheel mouse.** Model a pale-grey
  body with silver side accents, symmetric waist, two main buttons, clickable
  wheel as the third button, low red optical glow, and
  `68 × 39 × 126 mm` envelope. Microsoft's
  [IntelliMouse Optical specification][intellimouse-spec] supplies exact
  dimensions, while its [2001 launch][intellimouse-launch] fixes the era.
  Keep the form generic and remove side-logo/industrial-design specifics.
- **E — anonymous black wired optical mouse.** Model a
  `62 × 38 × 113 mm` ambidextrous shell with two buttons, narrow clickable
  wheel, red sensor glow, simple cable strain relief, and no side controls.
  The [Logitech M100 specification][logitech-m100] supplies exact dimensions.
- **F — low-profile touch-surface mouse.** Model a pale or dark
  `57 × 22 × 114 mm` continuous top shell, hidden left/right click division,
  very low side rail, and wireless underside, taking dimensions from the
  [2024 Magic Mouse specification][magic-mouse]. Preserve the generic
  low-profile idea, not Apple's exact curvature, seam, or trade dress.
- **G — angular three-button workstation mouse.** Model an
  `80 × 50 × 100 mm` cream/warm-grey puck with three visibly separate
  full-length buttons, straight sides, shallow rear taper, and thick cable.
  The [SPARCstation 5 manual][sparc5-manual] supplies the mouse envelope and
  [Sun Type 5 notes][sun-type5] establish the three-button companion. A
  material-only cream treatment lets the same generic workstation geometry
  sit with the Acorn desk without copying either maker.

## Source links

[freedos-history]: https://www.freedos.org/about/
[freedos-spec]: https://help.freedos.org/docs/about/fdspec.html
[kolibri-install]: https://docs.kolibrios.org/html/eng/INSTALL.HTML
[toaru-about]: https://toaruos.org/pages/about.html
[windows31]: https://en.wikipedia.org/wiki/Windows_3.1
[valuepoint]: https://en.wikipedia.org/wiki/IBM_PS/ValuePoint
[windows95-launch]: https://www.computerhistory.org/revolution/personal-computers/17/303/1209
[gateway-photo]: https://commons.wikimedia.org/wiki/File:Gateway_2000.jpg
[windows98]: https://en.wikipedia.org/wiki/Windows_98
[deskpro2000]: https://ftp.zx.net.nz/pub/archive/ftp.compaq.com/pub/supportinformation/forum/Desktops/Deskpro_2000/Deskpro_2000_Technical_Reference_Guide.pdf
[windows2000-ready]: https://news.microsoft.com/1998/11/16/microsoft-and-pc-manufacturers-announce-windows-2000-ready-pc-program/
[deskpro-en]: https://kentie.net/article/retropc/deskpro_en_series.pdf
[windowsxp-launch]: https://news.microsoft.com/source/2001/02/13/bill-gates-unveils-microsoft-windows-xp-the-new-windows/
[dimension-review]: https://www.computerworld.com/article/1411973/product-review-dell-dimension-8100.html
[alpine-downloads]: https://www.alpinelinux.org/downloads/
[tinycore-faq]: https://distro.ibiblio.org/tinycorelinux/faq.html
[plan9-about]: https://plan9.io/plan9/about.html
[ninefront-fqa]: https://git.9front.org/sl/fqa.9front.org/e7422424f56d5bc6eff76f546c8e5dc68bfee090/fqa3.ms/f.html
[helenos-amd64]: https://www.helenos.org/index.fcgi/wiki/Arch/Amd64
[helenos-hardware]: https://www.helenos.org/wiki/HardwareSupport
[sparc5-manual]: https://docs.oracle.com/cd/E19127-01/sparc5.ws/801-6396-11/801-6396-11.pdf
[sun-gdm]: https://shrubbery.net/~heas/sun-feh-2_1/Systems/Sun4/MONITOR_17_Premium_CRT.html
[nt351]: https://en.wikipedia.org/wiki/Windows_NT_3.51
[serenity-origin]: https://serenityos.org/happy/4th/
[nzxt-h500]: https://gamersnexus.net/hwreviews/3309-nzxt-h500-case-review-thermals-noise-vs-s340
[htc-dream]: https://en.wikipedia.org/wiki/HTC_Dream
[postmarket-intro]: https://postmarketos.org/blog/2017/05/26/intro/
[fairphone2]: https://www.fairphone.com/wp-content/uploads/2016/09/For-reviewers.-Fairphone-2-product-overview_Darias-MacBook-Air_Oct-28-110128-2016_Conflict.pdf
[sailfish-info]: https://sailfishos.org/info/
[jolla-phone]: https://en.wikipedia.org/wiki/Jolla_%28smartphone%29
[templeos]: https://en.wikipedia.org/wiki/TempleOS
[reactos-release]: https://reactos.org/project-news/reactos-0414-released/
[haiku-faq]: https://www.haiku-os.org/about/faq/
[corsair-4000d]: https://www.corsair.com/us/en/p/pc-cases/cc-9011200-ww/4000d-airflow-tempered-glass-mid-tower-atx-case-black-cc-9011200-ww
[os2-history]: https://www.os2museum.com/wp/os2-history/os2-warp-4/
[ps2-model77]: https://www.infania.net/misc1/techspecs/pdf/77.pdf
[aros-ports]: https://aros.sourceforge.io/introduction/ports.html
[aros-faq]: https://www.aros.org/documentation/faq.html
[qnx-2010]: https://www.qnx.com/news/pr_4376_1.html
[qnx-reference]: https://www.qnx.org/products/reference-design/
[ibm-xt-museum]: https://collection.sciencemuseumgroup.org.uk/objects/co427890/ibm-xt-personal-computer-1985
[ibm-xt-manual]: https://www.minuszerodegrees.net/manuals/IBM_5155_5160_Technical_Reference_6280089_MAR86.pdf
[commodore64]: https://en.wikipedia.org/wiki/Commodore_64
[c1702]: https://datassette.org/manuais/us-estados-unidos-monitores-commodore-manuais/1702-monitor-users-manual
[atari1040]: https://wiki.retrotechcollection.com/Atari_1040STF
[sm124-manual]: https://www.atarimuseum.de/pics/scans/Manuals/sm124.pdf
[apple2e]: https://wiki.retrotechcollection.com/Apple_IIe
[monitorii-manual]: https://mirrors.apple2.org.za/Apple%20II%20Documentation%20Project/Peripherals/Monitors/Apple%20Monitor%20II/Manuals/Apple%20Monitor%20II%20User%27s%20Manual.pdf
[amiga500]: https://en.wikipedia.org/wiki/Amiga_500
[amiga-service]: https://www.devili.iki.fi/library/publication/430.en.html
[windows11-req]: https://support.microsoft.com/en-us/windows/windows-11-system-requirements
[acorn-a3000]: https://www.computinghistory.org.uk/det/2721/Acorn-A3000/
[acorn-service]: https://manualzz.com/doc/4154576/acorn-a3000-computer-service-manual
[mac-mini]: https://www.apple.com/mac-mini/
[mac-mini-spec]: https://support.apple.com/en-euro/121555
[redstar-fastco]: https://www.fastcompany.com/3036046/what-its-like-to-use-north-koreas-red-star-os
[dprk-labs]: https://www.northkoreatech.org/2010/11/26/a-look-at-kim-il-sung-universitys-computer-labs/
[redstar3]: https://www.northkoreatech.org/2014/12/30/red-star-3-0-desktop-finally-becomes-public/
[cpc6128]: https://amstrad.eu/amstrad-cpc-6128/
[ctm644]: https://manualzz.com/doc/64274931/amstrad-cpc664--ctm644-service-manual
[nt4-hcl]: https://www.bitsavers.org/pdf/microsoft/windows_NT_4.0/69727-0796_Microsoft_Windows_NT_Version_4.0_Hardware_Compatibility_List_199607.pdf
[pc300pl]: https://www.ibmfiles.com/ibmfiles/pc300/65xx_technical_information.pdf
[dc5800]: https://manualzilla.com/doc/7317687/compaq-dc5800---microtower-pc-quickspecs
[dimension8100-manual]: https://manualmachine.com/dell/dimension8100/1431430-user-manual/
[ibm5151-dims]: https://www.radiomuseum.org/r/ibm_monochrome_monitor_5151.html
[ibm-5150-manual]: https://www.minuszerodegrees.net/manuals/IBM_5150_Technical_Reference_6025005_AUG81.pdf
[sony-gdm17]: https://pro.sony/s3/cms-static-content/operation-manual/3800980161.pdf
[eizo-s1703]: https://www.eizo.com/products/flexscan/s1703/
[model-f83]: https://wiki.retrotechcollection.com/IBM_Model_F_%2883-key%29
[hp-kbd]: https://images10.newegg.com/UploadFilesForNewegg/itemintelligence/Hewlett-Packard/001455918_an_01_en_KURZ_HP_COMPAQ_I5_650_250G_W7PRO_REFURB_1470971831529.pdf
[dell-kb216]: https://www.delltechnologies.com/asset/en-us/products/electronics-and-accessories/technical-support/dell_multimedia_keyboard_kb216_data_sheet.pdf.external
[logitech-k380]: https://futureisnow.logitech.com/content/dam/logitech/en/business/pdf/k380-multi-device-blurtooth-keyboard.pdf
[sun-type5]: https://vtda.org/docs/computing/Sun/hardware/800-6802-12_Type5KeyboardandMouseProductNotes_RevA_Oct93.pdf
[intellimouse-spec]: https://download.microsoft.com/download/c/d/7/cd79e2f2-aacc-47c9-820b-f30de9b95b16/tds_intellimouseoptical_0704a.pdf
[intellimouse-launch]: https://news.microsoft.com/source/2001/09/25/new-microsoft-mouse-family-unleashes-wireless-intellimouse-explorer/
[logitech-m100]: https://www.logitech.com/en-ae/products/mice/m100-usb-mouse.html
[magic-mouse]: https://support.apple.com/en-ie/121931
