# magiccap — SPA / poster stream draft (2026-09-13 wave)

Author: Claude Opus 5 (1M context), `magiccap-spa` stream. The lead scaffolds
`registry/stations/magiccap.json` on branch `magiccap`; this file holds the
visitor-facing fragments to paste into that entry, plus the three `.ts` rows.
**This stream did not edit `registry/stations/magiccap.json` or any `.ts` file** —
by design, so the two branches merge without conflicts.

Station: Magic Cap 3.1, General Magic's Windows-hosted simulator build (2001, the
3.1 release of 2000), running inside a Windows 98 SE guest.

Poster prose: `registry/posters/magiccap.md` (this branch). Hero still owed by the
lead/coordinator: `spa/public/posters/magiccap/desktop.webp`, and the poster's
`alt`/`caption` describe the desk — if the golden scene rests somewhere else
(hallway, downtown), change those two strings and nothing else.

Constraint checked in `spa/src/data/tileWiring.test.ts`: `lineage`, `blurb` and
`arch` must not match
`/\b(MAME|QEMU|streamhost|qcow2|kiosk|VICE|hatari|cap32|fs-uae|LinApple|snapshot|framebuffer|emulat\w*)\b/i`.
`simulat*` is **not** on that list, but the fragments below avoid it anyway in
those three fields, so the copy describes the machine rather than the rig.
`lineage` ≤ 120 chars; `blurb` non-empty (the ≤ 240 char ceiling is the wave's
house rule, not a test — the blurb below is 139).

## `museum`

```json
"museum": {
  "id": "magiccap",
  "displayName": "Magic Cap 3.1",
  "year": 2000,
  "lineage": "Magic Cap",
  "arch": "i386",
  "ramMB": 96,
  "era": "1990s",
  "accent": "#c08a3e",
  "eraSoftware": [
    "Notebook",
    "Datebook",
    "Name Cards",
    "In Box / Out Box"
  ],
  "iconicApps": [
    "Notebook",
    "Phone",
    "Downtown"
  ],
  "blurb": "No windows and no files — a drawn desk, a hallway of rooms and a downtown street. General Magic's pocket communicator, in its last release."
}
```

Notes for whoever pastes this:
- `year` is the **release** year of Magic Cap 3.1 (2000); the platform's own
  debut is 1994 (Sony Magic Link PIC-1000, Motorola Envoy). The poster carries
  both; the card shows one, and 2000 is the build on the disk.
- `era`: `"1990s"` matches the platform and the neighbours it should sit beside.
  If the hall groups strictly by `year`, `"2000s"` is the alternative — a
  one-word change, coordinator's call.
- `ramMB`: 96 is the win98se host figure. Set it to whatever the lead's launcher
  actually gives the guest; do not leave a guessed number.
- `periodBrowser`: **deliberately omitted.** Magic Cap 3.x is claimed to carry an
  HTML browser, but this stream could not verify which build shipped it, and
  `periodBrowser` is metadata that reads as fact. Add it only if the lead sees a
  browser on the framebuffer.
- No `ramKB` needed (`ramMB` is non-zero).

## `spa`

```json
"spa": {
  "archetypeId": "beige-tower-crt",
  "transport": "streamhost",
  "accentColor": "#c08a3e",
  "eraLabel": "2000 · Magic Cap 3.1"
}
```

- `archetypeId` follows the host the code actually runs on (the win98se-shaped
  PC). If the lead prefers to present the handheld instead, that needs a new
  archetype and a scene assembly to match — out of scope for this wave.
- No `bootVideo` — none recorded.
- **Promotion reminder:** a listed station needs `spa.transport` flipped to
  `streamhost` (it already is above); a dark-launched rig that keeps its tile
  hidden is a `listing.state` decision on the lead's side.

## `demoProgram`

**Recommendation: `"demoProgram": null`.**

Magic Cap is pointer-first. There is no shell, no BASIC prompt and no command
line to type a program into — the type-in demo's whole shape (lines, then a
`runCommand`) has nothing to address here. Every pointer-first station in the
hall ships `demoProgram: null`, and this one should too.

If the coordinator wants a typing proof on the placard anyway, the only honest
target is the **Notebook**, and it is conditional on the golden scene: it needs a
Notebook page already open (or reachable in one tap from the rest state), which
this stream cannot confirm. Draft, to be deleted unless the lead confirms:

```json
"demoProgram": {
  "label": "Write a note",
  "lines": [
    "Sony Magic Link, 1994.",
    "No windows. No files.",
    "A desk, a hallway, a street."
  ],
  "runCommand": "",
  "perCharMs": 120
}
```
`perCharMs` 120 is a guess and must be measured before it ships; `runCommand` is
empty because there is nothing to run. Delete this block if the golden rests on
the desk rather than in the Notebook.

## `.ts` rows (do NOT let two streams edit these files — hand them to the integrator)

`spa/src/scene/assembliesByTile.ts` — win98se's shape, since it is the same
class of beige PC:

```ts
  // magiccap: Magic Cap 3.1's own Windows-hosted build on a period beige tower
  // under a 4:3 CRT. Pointer-first (the handheld was a stylus touchscreen), so
  // the mouse is the object that matters on the desk; keyboard is secondary.
  magiccap: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardB', mouse: 'paramMouseB',
  },
```

`spa/src/scene/machineIdentity.ts`:

```ts
  magiccap: {
    caseTint: '#bda47f', accentTint: '#8a6a3a', tintMix: 0.4,
    badge: 'MAGIC CAP', spec: 'COMMUNICATOR • 2000', kit: 'office90',
  },
```

`spa/src/ui/keyboard/keyboardProfiles.ts` — add to the `OS_FAMILY` map:

```ts
  magiccap: 'generic', // Magic Cap is pointer-first: no shell, no Explorer chords;
                       // the keyboard only enters text into an object already open
```

Keyboard notes for the on-screen keyboard copy: **the pointer is the interface.**
Every navigation act — opening an object on the desk, walking to the hallway,
entering a room, going downtown, opening a drawer or taking a stamp — is a tap.
The keyboard does one job, typing text into something already open, and no
shortcut chord set applies. If the tileWiring test ever grows a "pointer-only"
profile, `magiccap` is the station it should be introduced for.

## Period material (cited, not downloaded)

- **Sony Magic Link press kit, September 1994** (bitsavers scan, the PIC-1000
  launch material): <https://archive.org/details/bitsavers_generalMagsKitSep1994_15885034>
- **"Using Magic Cap"** — General Magic's own user documentation (bitsavers scan):
  <https://archive.org/details/bitsavers_generalMag_17377719>
- **Magic Cap pre-release 1.0, build 327** — General Magic, for dating the
  desk/hallway/downtown metaphor against the shipping build:
  <https://archive.org/details/magic-cap>

Nothing was downloaded by this stream. If the media agent wants period art for
the poster's second image, the 1994 press kit is where the Magic Link product
photography lives; check its licence posture before committing any bits (rule 1
and the wave's media contract — credit, never copy).

## Facts the prose rests on

Founded 1990 by Marc Porat, Bill Atkinson and Andy Hertzfeld, out of Apple's
"Paradigm" project · Magic Cap OS + Telescript agent language · shipped 1994 in
the Sony Magic Link PIC-1000 and the Motorola Envoy · AT&T PersonaLink as the
network, closed 1996 · spatial metaphor: desk (phone, notebook, datebook, in/out
boxes), stamps and drawers, hallway of rooms (game room, library, storeroom),
downtown street of services · touchscreen + stylus · alumni: Tony Fadell
(iPod/iPhone), Andy Rubin (Android), Pierre Omidyar (eBay) · 2018 documentary
"General Magic" · Magic Cap 3.1 (2000) the last release, in the DataRover 840
and as a Windows-hosted build — which is what this station runs.
