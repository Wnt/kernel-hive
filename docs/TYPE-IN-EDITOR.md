# The type-in code editor

On a machine that boots into BASIC, the stage menu (☰) carries **✎ Code editor**.
It opens a panel next to the picture (under it on a phone) where a visitor
can write a listing, paste one, open a `.bas`/`.txt` file, or pick one of the
machine's example programs. **⌨ Type into machine** then keys the listing into
the guest one character at a time, at the station's own pace, with a progress
line and a Stop button.

It answers a visitor's request (2026-10). They wanted to type magazine listings
into the toy computers by sending the clipboard as keystrokes through an
AutoHotkey script, and noted that "some buffer runs out" on a long line. The
editor does the clipboard part in the browser. The buffer part was the daemon
dropping long bursts (a 64-entry queue plus an ack timeout that flushed the
emulator's backlog). The `keyfeed` stream fixed that. The editor never makes a
burst in the first place: one character per `typeText()` call, then a wait.

Code: `spa/src/ui/typein/` (panel, hook, highlighter, listing rules, run). The
typing engine is `typeLines()` in
`spa/src/ui/grid/StreamView/typeDemoProgram.ts`, shared with the demo listing.

## Which stations, and why

The opt-in is DATA: a station gets the editor if its registry entry has a
`typeIn` block, and for no other reason. There are no id checks in the SPA.

| In (17) | Why |
|---|---|
| vic20 pet2001 cbm8032 c128 plus4 cbm2 | Commodore BASIC at power-on |
| bbcmicro armeval | BBC BASIC (armeval: ARM BASIC on the tube) |
| msx2 svi728 svi328 | MSX-BASIC / SV BASIC at power-on |
| amstradcpc | Locomotive BASIC |
| dragon32 oricatmos mpf2 | Microsoft-family BASICs (Color, Oric, Applesoft-like) |
| sinclairql | SuperBASIC |
| samcoupe | SAM BASIC, one keypress away (the `hint` tells the visitor to press B first) |

| Out | Why |
|---|---|
| zxspectrum, zx81 | **Keyword entry.** One key *is* a keyword (P gives PRINT), so ASCII typed letter by letter arrives as garbage. The demo listing types keystroke form (`10 b1`) for exactly this reason. Supporting them needs a keyword transcoder, which is a follow-up. |
| svi328cpm, svi738 | Boot to CP/M; MBASIC has to be loaded first (their demo listings do that with a 20 s settle). |
| kc854, atari800xl, apple2e | Boot to a menu or a DOS, not to an interpreter. |
| c64, apple2, msxturbor | Boot to GEOS / MSX View desktops. |

**A station without validated pacing never gets the editor.** The validator
refuses a `typeIn` block on a station whose env does not declare
`SH_KEY_MIN_HOLD_MS` + `SH_KEY_MIN_GAP_MS`. Without that drain rate there is
nothing to validate the editor's pace against.

## The registry block

```json
"typeIn": {
  "dialect": "cbm-basic",
  "perCharMs": 170,
  "case": "unshifted",
  "maxLineChars": 88
}
```

| Field | Meaning |
|---|---|
| `dialect` | Keyword list for the highlighter (`spa/src/ui/typein/basicDialects.ts`): `cbm-basic bbc-basic msx-basic locomotive-basic superbasic sam-basic oric-basic color-basic applesoft`. |
| `perCharMs` | **Required.** The wait after every typed character. Must be ≥ hold+gap (`scripts/stations_registry/validate_typein.py`). It is never defaulted: the demo may fall back to the SPA's 70 ms, but the editor may not. |
| `lineDelayMs` / `enterDelayMs` | The pause before a line's ENTER and the settle after it, for BASIC to tokenise. They default to the demo typist's 260 / 600 ms. **These three numbers are the tuning surface for long listings.** Change them here, never in a component. |
| `case` | How letters become keystrokes (below). |
| `maxLineChars` | The machine's logical line length. The editor strikes through what the screen editor would cut off. Declared only where the number is certain (VIC-20 88, PET/8032 80, C128 160). |
| `hint` | One sentence above the Type button, for a step the machine needs first. |

`stations-registry.py new --like` does **not** copy `typeIn`. The dialect and
case rule are facts about the sibling's interpreter, so a new machine opts in
once its own typing is proven.

### The case rule

`typeText()` presses what a US PC keyboard would, so `A` is Shift+a. That is
wrong on most of these machines:

| `case` | What reaches the guest | Stations |
|---|---|---|
| `unshifted` | every letter goes down unshifted | vic20 pet2001 c128 plus4 (Shift+letter is a graphics glyph); bbcmicro armeval oricatmos (CAPS LOCK on at reset, so Shift+letter gives *lower* case and BBC BASIC answers `Mistake`); dragon32 mpf2 (no lower case) |
| `code-lower` | letters outside strings, REM and DATA go down unshifted; literals keep the visitor's case | cbm8032 cbm2 (business keyboard, text mode: unshifted is lower case, and BASIC wants it) |
| `code-upper` | code is upper-cased, literals kept | msx2 svi728 svi328 (the proven demo path) |
| `as-typed` (default) | unchanged | amstradcpc sinclairql samcoupe |

The station `keyboard` block (`charMap`, `letterCase`) is applied after the
case rule, exactly as for the demo listing.

## Example programs and manual links

`registry/examples/<station-id>/` holds them. The content is written per
machine by separate agents. The contract:

```
registry/examples/<id>/index.json
{
  "examples": [ { "file": "draw.bas", "kind": "draw", "title": "…", "description": "one sentence" }, … ],
  "manuals":  [ { "title": "…", "url": "https://…", "lang": "en", "note": "optional" } ]
}
registry/examples/<id>/<file>.bas   plain ASCII, LF, one program line per text line
```

The validator (run by every `stations-registry.py validate`, so by the
pre-push gate) checks the following:

- the station has a `typeIn` block;
- `kind` is one of `draw input game sound other`;
- every listed file exists, and every `.bas`/`.txt` file in the folder is listed;
- the files are printable ASCII and LF only, with no tabs, CRs or trailing spaces;
- lines fit `maxLineChars`;
- manual URLs are `https://` and `lang` is a two-letter code.

A station with no folder simply has no examples. That is never an error.

Examples and manuals are **runtime content**. They are rendered into
`poster-docs.json` as a top-level `typeIn` key, a sibling of `posters`, and
never committed. A content commit therefore needs no regeneration, and only
goes live when `serve-https-spa.sh manifests` (or `deploy`) publishes. A
bundle that predates the editor ignores the key. The editor fetches the
document the first time it opens. The manuals also appear at the end of the
station's exhibit notes (ⓘ), so every machine links its manuals even when
nobody opens the editor.

## What the editor refuses to do quietly

- **Characters the machine cannot receive** (anything outside printable
  ASCII) stay visible, are painted red, and block typing. One button folds the
  typographic ones a web page or PDF smuggles in (curly quotes, dashes,
  ellipsis, no-break spaces). Anything else (`£`, accented letters) has no
  exact ASCII meaning, so the visitor has to decide.
- **Over-long lines** are struck through past the machine's limit and warned
  about. They are not blocked, because an abbreviation can shorten one.
- **Magazine control codes** such as `{CLR}` and `{DOWN}` are flagged on
  Commodore listings. They are typed literally; the warning suggests
  `CHR$(147)`. Translating them into the real cursor and colour keys is a
  follow-up.
- **No stream, no typing.** The button waits for a live picture and an open
  input channel. A run that loses the channel stops before the next key and
  says where. Closing the panel stops the run.
- **Stop means stop.** The engine checks before every key, and the wait in
  flight is aborted, so no key leaves after Stop.

Tokenised `.prg` files are out of scope. A file that looks binary is refused
with a pointer to LIST it on a machine instead. Drafts persist per station in
`localStorage`, as a convenience only.

## Analytics

`spa/src/analytics/catalogue/typein.ts` (area `keyboard`):

- probes `typein.editor.opened`, `.text.pasted`, `.file.opened`,
  `.example.loaded`, `.ascii.folded`, `.run.completed`, `.run.stopped`,
  `.manual.opened`, and `poster.manual.opened`;
- the flow `typein.run` (`start` → `typed`, failing as `stopped` /
  `disconnected` / `error`);
- the metric `typein.run.lineCount`, which says how long real listings are.

The keystrokes themselves are synthetic (`withSyntheticInput`) and never count
as `station.key.used`. No listing text leaves the tab.
