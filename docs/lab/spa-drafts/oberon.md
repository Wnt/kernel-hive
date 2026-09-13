# `oberon` — SPA / poster stream drafts (ETH Native Oberon 2.3.6, 1999)

Written by the `spa` stream of the 2026-09-13 five-station wave (Claude Opus).
The station lead scaffolds `registry/stations/oberon.json` on branch `oberon`;
these fragments are what the coordinator pastes into it, and the three `.ts`
rows below are copied in shape from `pcgeos`. **No `.ts` file is edited by this
stream.**

Anything below marked **CONDITIONAL** depends on what the golden scene actually
shows — the coordinator trims it when the lead reports the scene.

## `museum`

```json
{
  "id": "oberon",
  "displayName": "ETH Native Oberon",
  "year": 1999,
  "lineage": "Oberon language + OS (Wirth & Gutknecht, ETH Zürich 1985–1992, Project Oberon on Ceres) → System 3 / Gadgets → Native Oberon (Pieter Muller, 1994–) → Active Oberon / A2 (Bluebottle)",
  "arch": "i386, on bare PC hardware — no host operating system",
  "ramMB": 64,
  "era": "1990s",
  "accent": "#215caf",
  "family": "Oberon",
  "vendor": "ETH Zürich",
  "eraSoftware": [
    "Oberon compiler",
    "System log",
    "Edit",
    "Gadgets",
    "Desktops",
    "Draw"
  ],
  "periodBrowser": null,
  "iconicApps": [
    "Edit",
    "Draw",
    "Gadgets desktop",
    "Oberon compiler"
  ],
  "blurb": "Wirth and Gutknecht's language and operating system, designed together at ETH Zürich in about 12,000 lines: no menus and no dialogs, because any text on screen is a command you run with the middle mouse button.",
  "notes": "TODO(lead): fill from the golden scene. Native Oberon 2.3.6 (1999) boots from its own disk with its own PC drivers — nothing underneath it. Tiling two-track display (System track left, User track right); the mouse has three buttons and Oberon uses all three, plus interclicks. Licence: ETH Oberon."
}
```

Blurb is 210 characters, contains no form of "emulat*". `family` / `vendor` are
included per the wave brief; drop either key if the current schema does not
carry it on a `museum` block (`python3 scripts/stations-registry.py validate`).

## `spa`

```json
{
  "archetypeId": "beige-ibm-pc",
  "transport": "streamhost",
  "accentColor": "#215caf",
  "eraLabel": "1999 · ETH Native Oberon 2.3.6",
  "pointerRel": false
}
```

- `eraLabel` doubles as the tagline in the tile header.
- `archetypeId`: `beige-ibm-pc` is the pcgeos archetype and the right class for a
  1999 PC clone. **CONDITIONAL** — swap to whatever archetype the lead's
  `--like` sibling actually carries.
- `pointerRel`: `false` if the pointer lands absolute; **CONDITIONAL** on the
  lead's pointer proof. Oberon's UI is middle-click-driven, so a relative
  pointer would be visibly wrong and is worth re-baking for.

## `demoProgram`

Oberon's "type in a program" is a command line, not a BASIC listing: you type
text anywhere and middle-click it. The demo types a two-line module into a text
and compiles it, which is the shortest honest demonstration of the
text-is-command idea.

**CONDITIONAL on the golden scene** — if the golden opens on the Gadgets
desktop rather than a text viewer, drop `Edit.Open` from line 1 and let the
lead's scene supply the open text.

```json
{
  "label": "Compile a module, then run it",
  "lines": [
    "Edit.Open Hello.Mod",
    "MODULE Hello;",
    "  IMPORT Oberon, Texts;",
    "  VAR W: Texts.Writer;",
    "  PROCEDURE World*;",
    "  BEGIN Texts.WriteString(W, \"Hello from Oberon\"); Texts.WriteLn(W);",
    "    Texts.Append(Oberon.Log, W.buf)",
    "  END World;",
    "BEGIN Texts.OpenWriter(W)",
    "END Hello."
  ],
  "runCommand": "Compiler.Compile Hello.Mod\\\\ Hello.World",
  "perCharMs": 90
}
```

`runCommand` is two commands separated by the Oberon convention of a trailing
`\\` on the compile; if the daemon's `runCommand` is a single keystroke burst,
split this into `Compiler.Compile Hello.Mod` only and leave `Hello.World` in the
visitor prose. **The lead measures `perCharMs`**; 90 is the fleet QEMU
keyboard floor's neighbour and a starting guess, not a measurement.

## Visitor actions (poster §"What you're looking at" — all CONDITIONAL)

Written conditionally in `registry/posters/oberon.md`; the coordinator trims to
what the golden scene supports:

1. Middle-click a command word in any Text (`Module.Command`) — the core gesture.
2. `System.Directory *.Mod` in the System track to list sources.
3. `Edit.Open <name>` to open a text.
4. `Desktops.OpenDoc` to open a Gadgets document / the Gadgets desktop.

## `.ts` rows (copied in shape from `pcgeos`; this stream does NOT edit the files)

`spa/src/scene/assembliesByTile.ts` — a 1999 beige PC clone under a colour SVGA
CRT, with the three-button mouse Oberon's whole interface is built around:

```ts
  // oberon: a 1999 beige PC clone under a colour SVGA CRT. Native Oberon owns
  // the hardware directly — same case family as pcgeos and netbsd14 — and the
  // mouse on the desk matters more here than anywhere else in the hall: Oberon
  // uses all three buttons, and interclicks between them.
  oberon: {
    kind: 'pizzaBox', body: 'pizzaBoxA', monitor: 'crtC',
    keyboard: 'keyboardA', mouse: 'paramMouseA',
  },
```

`spa/src/scene/machineIdentity.ts`:

```ts
  // oberon: a 1999 PC clone running ETH Native Oberon 2.3.6 on bare hardware —
  // no DOS and no host OS under it, which is what the spec line says. Accent is
  // ETH Zürich's blue against Oberon's black-on-white screen.
  oberon: {
    caseTint: '#c9c3b4', accentTint: '#215caf', tintMix: 0.3,
    badge: '486/PENTIUM PC', spec: 'BARE METAL • 1999', kit: 'office90',
  },
```

`spa/src/ui/keyboard/keyboardProfiles.ts` — a plain PC keyboard, so the generic
rows; the interesting input is the mouse, not a chord set:

```ts
  // ETH Native Oberon 2.3.6: a plain 101-key PC keyboard, and no chord set worth
  // a profile — Oberon has no menus and no accelerators, because commands are
  // text you middle-click. The generic rows are the honest common ground. The
  // input that matters here is the THREE-button mouse and its interclicks, which
  // is a pointer concern, not a keyboard one.
  oberon: 'generic',
```

Keyboard notes for the tile help text: **a plain PC keyboard; the mouse has
three buttons and Oberon uses all three** — left selects, middle executes the
text you point at, right points at objects, and holding one while clicking
another (an *interclick*) is how copy, paste and delete are expressed.

## Period material (cited, not downloaded)

- *Project Oberon — The Design of an Operating System and Compiler*, Niklaus
  Wirth and Jürg Gutknecht, full book PDF: <https://www.projectoberon.net/>
  (also <https://people.inf.ethz.ch/wirth/ProjectOberon/>)
- ETH Zürich Native Oberon / System 3 archives and the 2.3.x release notes:
  <https://www.inf.ethz.ch/personal/wirth/> and the ETH Oberon site archive at
  <https://web.archive.org/web/*/http://www.oberon.ethz.ch/*>
- Licence: ETH Oberon licence (free for use and redistribution with the ETH
  notice). Nothing fetched by this stream; the media stream records URL +
  sha256 + byte size in `/data/assets-staging/oberon/SOURCES.md`.
