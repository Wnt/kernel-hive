# SPA draft — `perq` (POS G.7) and `accent` (Accent S6 + Spice Lisp)

Written by the `spa` stream of the 2026-09-13 five-station wave (Claude Opus).
The registry entries did not exist yet when this was written: the lead scaffolds
`registry/stations/perq.json` and `registry/stations/accent.json` on branch
`perq`. **Everything below is a fragment to paste into those files, or a row to
paste into a `.ts` file — this stream edited no `.ts` file and no station JSON.**

Anything the golden scene has not proven is marked `TODO(golden)`. Blurbs are
measured: `perq` 236 chars, `accent` 238 chars, both ≤ 240, neither contains
`emulat*`.

---

## 1. `registry/stations/perq.json` — `museum`

```json
"museum": {
  "id": "perq",
  "displayName": "PERQ POS G.7",
  "year": 1986,
  "lineage": "Three Rivers Computer Corporation, Pittsburgh (PERQ, 1979-1980) -- sold in the UK as the ICL PERQ from 1981",
  "arch": "Three Rivers PERQ 1: a microcoded 16-bit bit-slice CPU executing Q-codes (a byte-code instruction set cut to fit compiled Pascal), 768x1024 portrait bitmap display, Kriz graphics tablet, 14-inch Shugart hard disk",
  "ramMB": 1,
  "era": "1980s",
  "accent": "#7FA8C9",
  "eraSoftware": [
    "POS, the PERQ Operating System -- written in Pascal at Three Rivers",
    "the POS windowed shell and its screen editor",
    "the Pascal compiler and environment the whole machine is shaped around"
  ],
  "periodBrowser": "none -- a 1980 workstation whose networking was Ethernet to other PERQs, a decade before the web",
  "iconicApps": [
    "the POS shell",
    "the POS screen editor",
    "the Pascal environment"
  ],
  "blurb": "The first commercial workstation with a bitmapped display and a pointing device -- Pittsburgh, 1980, a year before the Xerox Star. Its 16-bit CPU has no fixed instruction set: writable microcode makes it a Pascal machine, and so is POS.",
  "notes": "TODO(lead) -- the lead owns `notes` (tier, runtime, media, sandbox verdict, reset path). The spa stream states only the visitor-facing facts: PORTRAIT EXHIBIT, 768x1024, one bit deep -- the second portrait tile in the collection after alto, so the 3D scene must not reuse alto's crtF signature blindly (see the assembliesByTile row below). Pointing device is a KRIZ TABLET (absolute, a puck on a surface), not a mouse -- if the pointer path lands absolute, say so in the poster; if it lands relative, the poster's `What you're looking at` needs the star.md caveat paragraph."
}
```

## 2. `registry/stations/perq.json` — `spa`

```json
"spa": {
  "archetypeId": "mono-terminal",
  "transport": "streamhost",
  "accentColor": "#7FA8C9",
  "eraLabel": "1986 · POS G.7 (Three Rivers PERQ 1, portrait display)"
}
```

`archetypeId` follows `alto` (`mono-terminal`) because the exhibit rests at a
one-bit portrait prompt, not at an icon desktop. If the golden scene turns out to
be the windowed shell with the editor already open, `beige-tower-crt` (lisa,
medley) is the better archetype — **the lead decides once the scene is known.**

## 3. `registry/stations/perq.json` — `demoProgram`

`TODO(golden)` — write this only once the golden scene is known. Two shapes,
pick by scene:

**If the scene rests at the POS shell prompt:**

```json
"demoProgram": {
  "label": "Ask POS what is on the disk (click the shell window first)",
  "lines": [
    "directory"
  ],
  "runCommand": "directory",
  "perCharMs": 80
}
```

**If the scene rests inside the editor**, `demoProgram: null` and let the
keyboard profile's buttons carry the visit — a type-in demo into a screen editor
that owns the whole page reads as vandalism, not as a demo.

---

## 4. `registry/stations/accent.json` — `museum`

```json
"museum": {
  "id": "accent",
  "displayName": "Accent S6",
  "year": 1986,
  "lineage": "Carnegie Mellon University, the SPICE project -- Accent (Rashid & Robertson, 1981) -> Mach (1985) -> NeXTSTEP, then Mac OS X and iOS",
  "arch": "Three Rivers PERQ 1 with CMU's own microcode: the same microcoded 16-bit bit-slice CPU, rewritten below the instruction set, 768x1024 portrait bitmap display, Kriz graphics tablet",
  "ramMB": 1,
  "era": "1980s",
  "accent": "#C98A3C",
  "eraSoftware": [
    "the Accent message-passing kernel -- ports, not system calls",
    "Spice Lisp, CMU's Common Lisp, the direct ancestor of CMU Common Lisp and so of SBCL",
    "the Accent window system"
  ],
  "periodBrowser": "none -- Accent's network was messages to ports on other CMU machines, years before the web",
  "iconicApps": [
    "the Spice Lisp listener",
    "the Accent window system"
  ],
  "blurb": "CMU's 1981 message-passing kernel, on the same PERQ with new microcode: programs talk to ports, not to the system, and memory and messages are one mechanism. Accent became Mach -- the kernel inside macOS and iOS. Here, S6 with Spice Lisp.",
  "notes": "TODO(lead). Visitor-facing facts from this stream: SAME MACHINE as the perq tile, different microcode and a different operating system on top -- the two tiles must read as a pair on the rail (same case, same portrait glass, different accent colour), and each poster's Legacy section points at the other. The lineage claim in `lineage` is load-bearing and checked: Accent -> Mach -> NeXTSTEP -> Mac OS X is a code-and-people lineage, not a resemblance; do not soften it to 'inspired'."
}
```

## 5. `registry/stations/accent.json` — `spa`

```json
"spa": {
  "archetypeId": "mono-terminal",
  "transport": "streamhost",
  "accentColor": "#C98A3C",
  "eraLabel": "1986 · Accent S6 with Spice Lisp (CMU SPICE, on a PERQ 1)"
}
```

## 6. `registry/stations/accent.json` — `demoProgram`

`TODO(golden)` — if the Lisp listener is the resting scene, this is the strongest
demo in the wave, and it is `medley`'s shape:

```json
"demoProgram": {
  "label": "Type a Lisp form into the listener (click in the listener window first)",
  "lines": [
    "(defun fact (n) (if (= n 0) 1 (* n (fact (- n 1)))))",
    "(mapcar #'fact '(1 2 3 4 5 6 7 8 9 10))"
  ],
  "runCommand": "(format t \"~&Spice Lisp, CMU SPICE, 1986~%\")",
  "perCharMs": 80
}
```

**Unproven**: Spice Lisp predates the Common Lisp standard, so `mapcar #'` and
`format ~&` are the two forms most likely to differ. The golden stream must type
both on the framebuffer before this ships; if either is rejected, fall back to
`(fact 10)` on one line and drop `runCommand`.

---

## 7. Row for `spa/src/scene/assembliesByTile.ts`

**Not applied by this stream.** Paste beside the `alto` / `star` block; keep the
comments, they are the file's convention and they are what stops a signature
collision.

```ts
  // Three Rivers PERQ 1: a floor cabinet beside the desk with a TALL screen on
  // top of it — the second portrait exhibit in the hall, and the only one that
  // is not a Xerox. crtF is alto's portrait tube and alto's alone, so the PERQ
  // pair take crtF's shape through a different body: towerB, which nothing in
  // the Xerox corner holds, keeps `towerB|crtF` unique to this machine. The
  // pointing device is a Kriz TABLET, not a mouse — paramMouseB is the closest
  // puck-like silhouette in the kit and is not held by any portrait tile.
  perq: {
    kind: 'towerSetup', body: 'towerB', monitor: 'crtF',
    keyboard: 'keyboardD', mouse: 'paramMouseB',
  },
  // The same cabinet, because it IS the same cabinet: accent is a PERQ 1 with
  // CMU's microcode in it. Identical assembly to `perq` on purpose — the two
  // tiles are one machine booted two ways, and machineIdentity carries the only
  // difference the visitor should see (the badge and the accent tint).
  accent: {
    kind: 'towerSetup', body: 'towerB', monitor: 'crtF',
    keyboard: 'keyboardD', mouse: 'paramMouseB',
  },
```

`TODO(ts-owner)`: confirm `towerB` and `paramMouseB` are free in the current
signature table before applying — this stream did not open the part inventory,
and the file's rule is that no two tiles share a full signature.

## 8. Rows for `spa/src/scene/machineIdentity.ts`

```ts
  // Three Rivers' office beige, a touch greyer than the Xerox putty next to it
  // so the two portrait machines do not read as one exhibit. The display is one
  // bit — the accent is the phosphor white the page is drawn in.
  perq: {
    caseTint: '#c9c3b6', accentTint: '#eef2f6', tintMix: 0.34,
    badge: 'PERQ 1', spec: 'Q-CODE MICROCODE • 768x1024 • POS G.7',
    kit: 'workstation',
  },
  // The same cabinet as `perq`, deliberately: same caseTint, same kit. What
  // changes is the badge — CMU's kernel, not Three Rivers' — and a warm accent
  // that separates the pair at a glance on the rail.
  accent: {
    caseTint: '#c9c3b6', accentTint: '#e2a24e', tintMix: 0.34,
    badge: 'PERQ 1 · ACCENT S6', spec: 'CMU SPICE • MACH ANCESTOR • 1986',
    kit: 'workstation',
  },
```

## 9. Rows for `spa/src/ui/keyboard/keyboardProfiles.ts` / `.data.exotic.ts`

### 9a. The PERQ keyboard, and how a PC keyboard maps onto it

Facts this stream is confident of: the PERQ 1's keyboard is a **plain typewriter
board** — letters, digits, punctuation, Return, Backspace — with **no PC
function block, no Alt, no Windows key, and no arrow cluster in the PC sense**;
the pointing is done on the **Kriz tablet**, so nothing that a PC keyboard's
navigation keys do has a PERQ equivalent to map onto. That means the mapping is
the *easy* direction: every printable key a visitor types goes straight through,
and the profile exists to supply the handful of words worth a button rather than
to translate a foreign key block (the `xerox-star` / `xerox-dwarf` Level-V
problem does **not** arise here).

`TODO(golden)`: two things must be measured on the framebuffer before this ships.

1. **Which host key is POS's line kill / delete.** 1980s Pascal shells commonly
   used `Ctrl-U` or `Ctrl-X`, and `Backspace` may arrive as `Delete`. Type one
   wrong character at the shell prompt and try to erase it.
2. **Whether Shift survives the wire.** `alto`'s profile carries an explicit
   warning that a Shift arriving in the same field as its letter is dropped, and
   both PERQ stations go through the same pacing path. If POS's shell is
   case-insensitive, follow `alto` and use lower case everywhere; if the Lisp
   listener needs `#'` and `(`, those are shifted printables and must be sent as
   explicit chords (see `alto`'s `alto-dir` macro for the pattern).

### 9b. `keyboardProfiles.ts`

Add to the `Family` union (line ~45):

```ts
  | 'perq'
```

Add to `OS_FAMILY` (both stations share the one family — the keyboard is the
same board; only the buttons differ, and those live in the profile):

```ts
  perq: 'perq', accent: 'perq',
```

### 9c. `keyboardProfiles.data.exotic.ts`

Add `'perq'` to the exotic family union, then the profile. Two candidate row
sets; the golden scene picks one, and the *other station's* buttons must not
ship on the wrong tile — if POS and Accent need different buttons, split into
`perq` and `accent` families rather than putting dead buttons on either.

```ts
  // Three Rivers PERQ 1. A plain typewriter keyboard with no function block and
  // no navigation cluster — the pointing was a Kriz tablet, so there is nothing
  // foreign to translate. The profile therefore exists for the WORDS, not for a
  // key layer: the two or three commands that are worth thirty seconds of a
  // visit, exactly as `alto` does it.
  perq: {
    family: 'perq',
    rows: [[
      // TODO(golden): confirm each of these at the POS prompt before shipping.
      // A button that answers with an error is worse than an absent button —
      // see the deliberate absence of LAUREL in the `alto` profile.
      cmd('perq-dir', 'DIRECTORY', 'directory',
        'directory — POS lists what is on the 14-inch Shugart disk'),
      cmd('perq-help', 'HELP', 'help',
        'help — the PERQ Operating System’s own list of what it can do'),
      tap('ret', '⏎', XK.Return),
      tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
      ...ARROWS,
    ]],
  },
```

If `accent` needs its own family (a Lisp listener wants parentheses and quote
far more than it wants command words):

```ts
  // Accent S6 + Spice Lisp. The same physical board as `perq`, but the visitor
  // is typing FORMS, not commands — so the buttons are the characters a US PC
  // keyboard makes awkward on a phone, not a command vocabulary.
  accent: {
    family: 'accent',
    rows: [[
      // TODO(golden): `(` and `)` are Shift+9 / Shift+0 and the wire rules
      // forbid a shifted printable keysym — these MUST be explicit macros in
      // the `alto-dir` shape, not cmd()/tap() calls.
      tap('ret', '⏎', XK.Return),
      tap('bksp', '⌫', XK.BackSpace, { repeat: true }),
      ...ARROWS,
    ]],
  },
```

---

## 10. Period material — cited, not downloaded

No file was fetched by this stream. Each URL is where the lead or the media agent
should go; **verify each one resolves before citing it in a poster caption.**

| What | Where |
|---|---|
| bitsavers PERQ documentation (POS manuals, PERQ hardware and microcode references) | `http://bitsavers.org/pdf/perq/` |
| bitsavers PERQ software / source trees | `http://bitsavers.org/bits/PERQ/` |
| ICL PERQ brochures and UK marketing material | `http://bitsavers.org/pdf/icl/` (ICL's PERQ material files under the ICL tree, not the Three Rivers one) |
| Rashid & Robertson, *Accent: A Communication Oriented Network Operating System Kernel*, SOSP-8, December 1981 | ACM DL, `https://doi.org/10.1145/800216.806593`; also CMU tech report CMU-CS-81-123 via `http://reports-archive.adm.cs.cmu.edu/` |
| Spice Lisp / CMU Common Lisp lineage | `https://www.cons.org/cmucl/` (the CMUCL project's own history page) |
| PERQemu — the emulator that keeps the machine alive, by Skeezics Boondoggle and Josh Dersch | `https://github.com/skeezicsb/PERQemu` (the maintained line); the original is `https://github.com/jdersch/PERQemu` |

Credit line for the poster footer, if the wave uses one: *"PERQemu, by Skeezics
Boondoggle and Josh Dersch, is why this machine still runs."*

## 11. What this stream did NOT do

- No `.ts` file was edited (rows above are drafts for whoever owns those files).
- No `registry/stations/*.json` was touched — the lead owns both entries.
- No hero image: `spa/public/posters/perq/desktop.webp` and
  `spa/public/posters/accent/desktop.webp` come from the lead's smoke frame, and
  both posters' `images:` blocks carry `PLACEHOLDER` alt and caption text that
  **must be rewritten from the real frame** before the stations are listed.
- Nothing was downloaded.
