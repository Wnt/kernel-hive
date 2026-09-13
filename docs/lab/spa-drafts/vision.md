# `vision` — SPA / registry prose drafts (VisiCorp Visi On 1.0, 1983)

Written by the `spa` stream of the 2026-09-13 five-station wave (Claude Opus).
`registry/stations/vision.json` did not exist when this was written — the station
lead scaffolds it on branch `vision`. These are the fragments the coordinator
pastes in at landing, so that no two branches touch the same file.

Everything below is a draft from **verified period facts** plus the poster prose
in `registry/posters/vision.md`. Fields marked **LEAD** depend on what the
station lead actually proves on the framebuffer — trim or correct them then.

---

## 1. `museum` block for `registry/stations/vision.json`

```json
"museum": {
  "id": "vision",
  "displayName": "VisiCorp Visi On 1.0",
  "year": 1983,
  "lineage": "VisiCalc → VisiCorp Visi On 1.0 (1983) → sold with VisiCorp's assets to Control Data Corporation, 1984",
  "arch": "Intel 8088, IBM PC/XT class — the system and its applications run on VisiCorp's own portable Visi Machine byte code",
  "ramMB": 1,
  "era": "1980s",
  "accent": "#5b6b7a",
  "eraSoftware": [
    "Visi On Application Manager",
    "Visi On Calc",
    "Visi On Word",
    "Visi On Graph",
    "Visi On Help"
  ],
  "iconicApps": [
    "Visi On Calc",
    "Visi On Word",
    "Visi On Graph"
  ],
  "blurb": "The first integrated windowing desktop sold for the IBM PC: VisiCorp's 1983 Visi On, with a mouse, overlapping windows and one menu vocabulary for every application — two years before Windows 1.0.",
  "notes": "LEAD: fill in the launcher/golden facts here (this field is operator-facing and may name the emulator; blurb/lineage/arch may NOT — spa/src/data/tileWiring.test.ts RIG_WORDS). Period facts for the notes: Visi On needed a hard disk and 512 KB+, and would not start without a Mouse Systems serial mouse; the Application Manager was $495 and the mouse $250 more."
}
```

Checks done here:
- `blurb` is **196 characters**, under the 240 cap, and contains no `emulat*`,
  `MAME`, `QEMU`, `streamhost`, `qcow2`, `kiosk`, `snapshot`, `framebuffer`
  (the `RIG_WORDS` regex in `spa/src/data/tileWiring.test.ts:90`, which is
  applied to `blurb`/`lineage`/`arch` but not to `notes`).
- `ramMB` is the smallest whole megabyte that can express "512 KB and up" —
  **LEAD**: set it to whatever the launcher actually gives the machine, and keep
  the poster's "512 KB or more" wording honest against it.
- `accent` `#5b6b7a` is a graphite-blue standing in for a monochrome bitmapped
  screen (Visi On has no colour of its own). Pick something else freely; it only
  needs to be distinct from the neighbouring beige-PC tiles (`pcgeos` `#e08a3c`,
  `bootos`, `freedos`).
- No `periodBrowser` key: 1983, there is nothing to put in it.

## 2. `spa` block

```json
"spa": {
  "archetypeId": "beige-ibm-pc",
  "transport": "streamhost",
  "accentColor": "#5b6b7a",
  "eraLabel": "1983 · VisiCorp Visi On",
  "pointerRel": true
}
```

**LEAD**: `pointerRel` is a guess that must match the pointer route actually
proven. Visi On talks to a *Mouse Systems serial mouse* on a COM port, which is
a relative device — so unless the lead lands an absolute route (the `pcgeos`
`kh-ramabs` trick writes the visitor's pixel straight into the driver's own
coordinate; whether Visi On's mouse handler has an equivalent fixed cell is
unknown and unproven), `pointerRel: true` is the honest value. If an absolute
route does land, flip this to `false` and say so in `notes`.

## 3. `demoProgram`

```json
"demoProgram": null
```

Deliberate. Visi On has no command line and no typed program to run: every verb
is a word on the menu strip you point at. A type-in demo here would be
manufacturing an interaction the system does not have. If the lead wants a
guided action for the tile, it should be a *pointer* demo, not a `demoProgram`.

## 4. `spa/src/scene/assembliesByTile.ts`

Do **not** paste this until the landing pass — the file is rebuilt at the
lineup position. The row, in the file's own comment-then-entry style:

```ts
  // vision: an IBM PC/XT of 1983 — the wide beige desk box under a monochrome
  // CRT, the 83-key XT board, and the Mouse Systems serial mouse Visi On will
  // not start without (relative, on a COM port). Same case family as bootos and
  // pcgeos; the XT board plus a mouse is what makes the combination unique.
  vision: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtA',
    keyboard: 'keyboardD', mouse: 'paramMouseB',
  },
```

`pizzaBoxA|crtA|keyboardD|paramMouseB` reads as unused today (`bootos` is
`pizzaBoxA|crtA|keyboardD|none`, `pcgeos` is `pizzaBoxA|crtA|keyboardA|paramMouseA`),
but the assemblies test enforces uniqueness across the whole file — run it at
landing and vary the mouse/monitor part if it collides.

## 5. `spa/src/scene/machineIdentity.ts`

```ts
  // vision: a 1983 IBM PC/XT — 8088, a hard disk (Visi On refuses to install
  // without one) and a monochrome bitmapped screen. The badge names the machine
  // class rather than the CPU alone, because "needs an XT" is the fact that
  // decided this product's commercial life. Graphite accent: the screen is
  // black and white, so the registry accent is a tint, not a quotation.
  vision: {
    caseTint: '#cbbfa2', accentTint: '#5b6b7a', tintMix: 0.32,
    badge: 'PC/XT 8088', spec: 'MONO BITMAP • 1983', kit: 'office90',
  },
```

## 6. `spa/src/ui/keyboard/keyboardProfiles.ts`

```ts
  // Visi On: a full windowing desktop over DOS, but a mouse-first one — the
  // menu strip is the entire command vocabulary and there are no keyboard
  // chords of its own to profile. The dos rows lead with Ctrl+Alt+Del, which is
  // the honest way home from a 1983 PC, on an 83-key XT board.
  vision: 'dos',
```

No new `Family` union member is needed; `'dos'` already exists and is what
`pcgeos` — the other GUI-over-DOS station — takes, for the same stated reason.

## 7. Period material for the poster's image slot

Not downloaded (per brief). Candidates found, with licence posture — the
coordinator or a later media pass must check each before use:

- `https://archive.org/details/vision_202005` — "Visi On Desktop - 1983 desktop
  environment", Internet Archive software item. Item page carries screenshots of
  the running system. **Posture: the software itself is VisiCorp copyright; the
  Archive hosts it under its software-preservation collection. Treat as
  reference, not as a licensed image source.**
- `https://archive.org/details/VISI_ON_DOS` — second Internet Archive item for
  the same product. Same posture.
- `https://winworldpc.com/product/visi-on/1x` — WinWorld's Visi On 1.x product
  page, which carries box art and manual scans. **Posture: abandonware host, no
  free licence asserted.**
- `http://toastytech.com/guis/vision.html` — Nathan Lineback's GUI Gallery page,
  the most complete screenshot set of Visi On in use. **Posture: the author
  asserts his own copyright over the page; the screenshots are of copyrighted
  software. Cite as a fact source in prose, do not reuse the images.**

Recommendation: the hero and every gallery image should come from **our own
running station's framebuffer** (the smoke frame the lead ships), which is what
every other poster in the hall does and is the only image we can publish
cleanly. If a period *advertisement* is wanted for the gallery's "period
material" slot, the place to look is a 1983–84 trade-press run on the Internet
Archive (InfoWorld and BYTE are both there in full) rather than any of the
above — that search was not completed inside this stream's 25-minute budget.

## 8. Poster

`registry/posters/vision.md`, on this branch. Front-matter shape copied from
`registry/posters/pcgeos.md` / `lisa.md` / `medley.md`; `poster_registry.py
--check` is green. The hero path it declares is
`/posters/vision/desktop.webp` — the lead's smoke frame — and the single image
entry's `alt`/`caption` describe the rest state **conditionally**; trim them to
what the golden actually opens at once the lead reports the scene. The "What
you're looking at" section likewise says "the golden state this exhibit restores
opens at the Visi On screen with the menu strip live" and describes Services /
Options / Help — correct the specifics there, not the voice.
