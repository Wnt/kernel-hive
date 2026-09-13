# fmtowns — SPA / registry prose drafts

Station: `fmtowns` — Fujitsu FM TOWNS, **Towns OS V2.1 L51 (1995)**, platform
introduced **February 1989**. Written by the `spa` stream of the 2026-09-13
five-station wave, before `registry/stations/fmtowns.json` existed; the lead
scaffolds the entry on branch `fmtowns` and the coordinator merges these
fragments into it. Nothing here edits a `.ts` file — the rows below are copy-in
text for whoever lands them.

Poster prose: [`registry/posters/fmtowns.md`](../../../registry/posters/fmtowns.md).

## Period material (cited, not downloaded)

- Fujitsu FM TOWNS period catalogues, brochures and magazine scans:
  <https://archive.org/details/FMTowns> (富士通 FMタウンズ / Fujitsu FM Towns).
  Use for the hardware photography and the Towns OS screen shots that date the
  TownsMENU look; **do not commit any bits** — cite the URL only (wave rule:
  fetch from origin, record URL + sha256 in the ledger, never commit media).

## 1. `museum` fragment

```json
"museum": {
  "id": "fmtowns",
  "displayName": "FM TOWNS (Towns OS)",
  "year": 1995,
  "lineage": "Fujitsu FM TOWNS — Towns System Software (Towns OS) on MS-DOS",
  "arch": "i386",
  "ramMB": 16,
  "era": "1990s",
  "accent": "#CC3D33",
  "eraSoftware": [
    "TownsMENU",
    "Towns System Software V2.1 L51",
    "MS-DOS (Towns)",
    "CD-DA player"
  ],
  "periodBrowser": null,
  "iconicApps": [
    "TownsMENU",
    "CDプレーヤー",
    "電卓",
    "Free Software Collection"
  ],
  "blurb": "Fujitsu shipped a CD-ROM drive as standard in a consumer PC in 1989, years early. Towns OS is its icon-first Japanese desktop on DOS — sprites, 16.7M-colour modes, Red Book soundtracks, sold in one country."
}
```

Notes for whoever lands it:

- `year: 1995` is the **software** year (Towns OS V2.1 L51). The **platform**
  year is **1989** — that belongs in the poster and the `eraLabel`, not in
  `museum.year`, which the lineup sorts by. Do not "fix" one to match the other.
- `ramMB` is a guess pending the lead's launcher — replace it with the value in
  `station.env.fixture`, do not carry this number forward unverified.
- `periodBrowser: null` — the Towns library is CD titles and system software,
  not a TCP/IP stack. If a browser is ever proven on this guest it is a fact,
  not metadata (see the retronet note in MEMORY: `periodBrowser` is metadata,
  not fact).
- `blurb` is 206 characters, under the 240 cap, and contains no "emulat*".

## 2. `spa` fragment

```json
"spa": {
  "archetypeId": "beige-tower-crt",
  "transport": "streamhost",
  "accentColor": "#CC3D33",
  "eraLabel": "1995 · Towns OS V2.1 L51 — FM TOWNS (1989)",
  "pointerRel": true
}
```

- `pointerRel: true` is the **conservative default**. Flip it to `false` only
  when the golden stream reports a proven absolute pointer (two-target warp +
  readback on the framebuffer). Do not flip it on a guess.
- Archetype: `beige-tower-crt` is the closest existing archetype. The real
  FM TOWNS model 1/2 is a **dark grey vertical tower** with a front-loading CD
  slot, not a beige AT box — the accent and `caseTint` below carry that; an
  ideal archetype would be a dark Japanese multimedia tower. Same comment
  convention as the `amigaos35` / `amix` rows in `archetypeRegistry.ts`.

## 3. `demoProgram` fragment — CONDITIONAL

**Default: `"demoProgram": null`.** Towns OS boots to the TownsMENU launcher,
not to a BASIC prompt, and there is no proven type-in surface yet.

Land a `demoProgram` **only if** the golden stream reports one of:

- **F-BASIC386 reachable from TownsMENU** — then a type-in listing is worth
  having, and it should be authored against the real prompt, not guessed here;
  F-BASIC386's statement set is not Microsoft BASIC's and an unverified listing
  would type a syntax error in front of a visitor.
- **A DOS prompt reachable from the launcher** — a `demoProgram` is a poor fit
  for a DOS prompt on a Japanese system (the shell messages are in kanji and
  half the value of a type-in is reading what comes back), so prefer `null`.

If neither is proven inside the wave, ship `null`. A station with no type-in
demo is normal (`pcgeos`, `apple2e` and `chokanji` all carry `null`).

## 4. Row for `spa/src/scene/assembliesByTile.ts`

Insert near the `chokanji` row (its Japanese-desktop neighbour), in the same
comment-then-object shape:

```ts
  // fmtowns: Fujitsu FM TOWNS (1989 hardware, 1995 Towns OS V2.1 L51) — Japan's
  // CD-ROM-as-standard multimedia PC. A vertical tower with a front CD slot under
  // a Japanese-market CRT; towerC/crtC is the closest silhouette the kit has, and
  // the dark caseTint + Towns red accent (machineIdentity) separate it from the
  // beige PC clones around it.
  fmtowns: {
    kind: 'towerSetup', body: 'towerC', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseB',
  },
```

## 5. Row for `spa/src/scene/machineIdentity.ts`

```ts
  // fmtowns: the FM TOWNS was not a beige box — model 1/2 is a dark grey/charcoal
  // vertical tower, the CD slot on the front the whole point of the design. Towns
  // red accent; the badge names the machine because "Fujitsu" alone spans FM-7,
  // FM TOWNS and the PC/AT clones that replaced it.
  fmtowns: {
    caseTint: '#4a4a4e', accentTint: '#CC3D33', tintMix: 0.42,
    badge: 'FM TOWNS', spec: '386 • TOWNS OS V2.1 L51 • 1995', kit: 'office90',
  },
```

## 6. Row for `spa/src/ui/keyboard/keyboardProfiles.ts`

```ts
  fmtowns: 'generic', // Towns OS V2.1 L51 — TownsMENU is an icon launcher, and the
  //                     Towns keyboard is a Japanese layout (変換 / 無変換 / カナ,
  //                     and no US-ANSI chord set). No PC chord family applies.
```

### Keyboard notes (what a US keyboard does and does not reach)

The FM TOWNS keyboard is a **Japanese layout**. Three of its keys have no
US-ANSI equivalent at all, and a visitor typing on a US keyboard simply cannot
send them:

- **変換 (henkan, "convert")** — commits/cycles an IME conversion. On a US
  keyboard this is nothing; the qcode `henkan` exists in QEMU's Japanese keymap
  but the browser never produces it from a US layout.
- **無変換 (muhenkan, "no convert")** — the opposite key; likewise unreachable.
- **カナ / 半角全角** — kana-mode and width toggles, same story.

Consequences for the exhibit, and what is OPEN:

- **A US keyboard reaches the ASCII rows, Enter, Escape, the arrows and the
  function keys, and nothing else.** That is enough to drive TownsMENU, which
  is the point: the exhibit's primary verb is the pointer, not the keyboard.
- **Do not advertise Japanese text entry.** Until someone proves a route, the
  poster and the SPA say the desktop *is* in Japanese, never that a visitor can
  *type* Japanese.
- **OPEN for the docs/golden stream:** whether the SPA keyboard overlay should
  expose explicit 変換/無変換 buttons (the streamhost key path can send the
  qcodes even when a US keyboard cannot produce them — `labctl key fmtowns
  henkan` is the check), and whether Towns OS's own IME is even enabled in the
  golden scene. Measure before writing either into a profile.
- Pacing: ship the fleet floor **40/40** (`SH_KEY_MIN_HOLD_MS` /
  `SH_KEY_MIN_GAP_MS`) unless characters are observed dropping on the
  framebuffer. Do not bisect pacing inside the wave.

## 7. Hero / frames

The lead ships `spa/public/posters/fmtowns/desktop.webp` from the smoke frame in
the ledger commit. The poster front-matter above expects exactly that one image;
if better frames exist when the golden scene is up, add them as extra `images:`
entries (TownsMENU, an accessory window, the CD player) with the same alt/caption
discipline as `registry/posters/pcgeos.md`.
