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

| In (19) | Why |
|---|---|
| vic20 pet2001 cbm8032 c128 plus4 cbm2 | Commodore BASIC at power-on |
| bbcmicro armeval | BBC BASIC (armeval: ARM BASIC on the tube) |
| msx2 svi728 svi328 | MSX-BASIC / SV BASIC at power-on |
| amstradcpc | Locomotive BASIC |
| dragon32 oricatmos mpf2 | Microsoft-family BASICs (Color, Oric, Applesoft-like) |
| sinclairql | SuperBASIC |
| samcoupe | SAM BASIC, one keypress away (the `hint` tells the visitor to press B first) |
| zxspectrum zx81 | Keyword entry (48K Sinclair BASIC, ZX81 BASIC), typed as key chords by the [keyword transcoder](#the-keyword-transcoder-zxspectrum-zx81) |

| Out | Why |
|---|---|
| svi328cpm, svi738 | Boot to CP/M; MBASIC has to be loaded first (their demo listings do that with a 20 s settle). |
| kc854 | Boots to the CAOS 4.2 command menu. HC-BASIC is one typed command away, proven on a rig on 2026-10-04: `BASIC` + ENTER gives `MEMORY END ? :`, a bare ENTER gives `47854 BYTES FREE` / `OK`, and `10 PRINT "KC 85/4: ";6*7` typed through the existing `charMap` at 260 ms/char RUNs to `KC 85/4:  42`. The open question is the two-line preamble: a `typeIn` field for it, or examples that begin with `BASIC` and an empty line. Typing `BASIC` when HC-BASIC is already running is untested. |
| atari800xl, apple2e | Boot to a menu or a DOS, not to an interpreter. |
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
| `dialect` | Keyword list for the highlighter (`spa/src/ui/typein/basicDialects.ts`): `cbm-basic bbc-basic msx-basic locomotive-basic superbasic sam-basic oric-basic color-basic applesoft`, and the two keyword-entry dialects `sinclair-basic zx81-basic`, which also select the [keyword transcoder](#the-keyword-transcoder-zxspectrum-zx81). |
| `perCharMs` | **Required.** The wait after every typed character. Must be ≥ hold+gap (`scripts/stations_registry/validate_typein.py`). It is never defaulted: the demo may fall back to the SPA's 70 ms, but the editor may not. |
| `lineDelayMs` / `enterDelayMs` | The pause before a line's ENTER and the settle after it, for BASIC to tokenise. They default to the demo typist's 260 / 600 ms. **These three numbers are the tuning surface for long listings.** Change them here, never in a component. |
| `enterDelayPerLineMs` | Added to the settle after line N, N times (0-based), for a machine whose redraw after ENTER grows with the listing (the ZX81). Default 0. |
| `newDelayMs` | The settle after a line that is just `NEW`, instead of `enterDelayMs`, for a machine that ignores keys while it clears its memory (the 48K Spectrum). Default: `enterDelayMs`. |
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

The keyword-entry dialects take no `case` (the validator refuses one): the
transcoder decides. On the Spectrum a lower-case letter is the bare key and a
capital is CAPS SHIFT + key; the ZX81 has no lower case, so every letter is the
bare key.

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

The editor types exactly the file and sends nothing else, so `NEW` is part of
the listing where a machine may already hold a program. The SAM Coupé must
start with `NEW`: after B the boot menu's own program is still in memory, and
its stray lines (85, 9000) would interleave with an example. The QL examples
start with `NEW` too, so a second example does not inherit the first one's
higher line numbers. Line 10 of those listings is a REM title on purpose. If a
machine eats the first key after `NEW` (the SAM does, below), the worst case is
a lost title, not a lost statement.

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
- **What a keyword-entry machine cannot type as written** (zxspectrum, zx81)
  is listed under the listing and painted red, and blocks typing: a statement
  keyword where the cursor cannot be K (`LET a=PRINT`), a statement that does
  not start with a keyword (`10 a=1`: these BASICs need `LET`), a letter after
  `:` inside a Spectrum REM, and any character the machine has no key for
  (the ZX81 has no `! @ # % & ' [ ] ^ _ { | } ~`; the Spectrum no backtick).
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

## Proving it — and tuning the pace

`scripts/e2e/typein-editor-probe.mjs` drives the REAL editor in the real SPA
the way a visitor does: ☰ → Code editor, paste, Type into machine. It waits for
the run to end, then optionally types RUN, captures the station framebuffer
(`labctl shot`), presses Stop mid-run, or restores the golden. It prints
lines, characters, wall clock and effective ms/char. Use it for long listings
when tuning `perCharMs` / `enterDelayMs`, and watch the daemon's
`dropped`/`overflow`/`ack timeout` counters in
`journalctl -u streamhost@<id>` beside it.

```sh
INVITE=<code or path> GALLERY_URL=https://kernelhive.madekivi.fi \
  node typein-editor-probe.mjs vic20 listing.bas --run run \
  --fb-shot /data/vms/sandbox/<name>/proof --restore
```

It needs a signed-in session to see the stream at all (see
`station-open.mjs`'s `signIn`).

**First proof, 2026-10-04, live vic20.** The probe pasted
`10 PRINT "EDITOR OK"` / `20 FOR I=1 TO 3:PRINT I*I:NEXT` (written in capitals)
and pressed Type into machine. The framebuffer showed both lines exactly:
keywords right, so the letters went down unshifted, and `"`, `=`, `*`, `:`
intact. RUN printed `EDITOR OK`, 1, 4, 9. It took 11.3 s for 50 characters
(226 ms/char all-in at `perCharMs` 170 with the 260/600 ms line and ENTER
settles), and the daemon counted `dropped=0 overflow=0` with no ack timeouts.
A second run pressed Stop during line 2. The framebuffer right after Stop and
3 s later differed only in the blinking cursor cell, so no key left after
Stop. The run ended with the visitor's Restore to golden, and the framebuffer
returned to the clean READY screen.

### Known defect: shifted punctuation on the VICE stations

**Open as of 2026-10-04.** On the VICE machines, a character that needs Shift
on a US keyboard but is an unshifted key on a Commodore (`:` and `*`) sometimes
arrives with the Commodore Shift still applied, or not at all. `:` becomes `[`
on the VIC-20 and C128 and `*` on the 8032, and a `*` occasionally vanishes.
The rate is about 1 in 50, so most multi-statement listings meet one.

It was measured on sandbox rigs of the stations' own binaries. Keys went
through the `vicectl` module at the stations' 60/60 pacing, and each listing
was read back byte for byte from a `SAVEST` snapshot, tokenised with VICE's
`petcat`. The test was a 6-line stress listing with 11 such characters a line,
typed three times on each rig:

| Path | vic20 | c128 | cbm8032 |
|---|---|---|---|
| Shift_L press, then the shifted keysym (what the daemon forwards) | 3 of 198 | 5 of 198, plus one line lost whole | 3 of 198 |
| The keysym alone, no Shift edge (control) | 0 of 198 | 0 of 198 | 0 of 198 |

A module trace (`VICE_CTL_TRACE=1`) shows a failing `:` with exactly the same
edge order and spacing as the good ones: Shift down, `:` down three frames
later, `:` up, Shift up. The queue is not the cause. The fault is VICE's
deshift of a held host Shift racing the KERNAL's matrix scan, so the fix
belongs in the module or the sink, not the pacing. A visitor typing `:` on
the physical keyboard holds Shift too, so this is not only the editor's
problem.

### Known defect: every shifted character is lost on the QL

**Open as of 2026-10-04.** This was measured on a sandbox rig with
sinclairql's live configuration: the same MAME 0.289 `ql` binary, the
`ctlsock` module at the station's 40/40 hold/gap, and `MAME_CTL_KEY_EXCL=:Y`.
Keys were sent with the edges `typeText()` produces: Left Shift down, key
down, key up, Left Shift up, back to back. The daemon forwards them unchanged.
The module applies Shift and the key in the **same drain pass**. The QL's 8049
keyboard processor then never reports the key at all. Capitals and all shifted
punctuation (`" : ( ) + * & $ !`) vanish, while unshifted keys land:

| Edges sent | Result on the framebuffer |
|---|---|
| `typeText()` style, `print 1+2` | `print 12` |
| `typeText()` style, `PRINT "AB"` | nothing |
| `typeText()` style, `10 REMark Sunburst` | `10 ark unburst` |
| Shift released 120 ms late, pressed with the key | nothing |
| Shift pressed 60 ms before the key | `PRINT "PRE"`, intact |
| Shift 60 ms early, module's 40 ms key hold, a 195-character listing | 2 lost (one `*`, one ENTER) |
| Shift 100 ms early, keys held 100 ms, about 1,000 characters | 0 lost |

The QL needs Shift down at least one keyboard scan **before** the key. The fix
belongs in the module or the sink, which should give a modifier press a lead
before the next key press. Pacing is not the fix. It affects everything typed
through `typeText()` on the QL, including its demo listing. The QL example
programs were proven with the 100/100 timing. A visitor's physical typing is
not affected, because a person presses Shift well before the letter.

### SAM Coupé: what the typist cannot reach, and what NEW does

**Keys a US typist cannot produce on the SAM.** `<` `>` `?` `[` `]` `{` `}`
`\` `|` have no `charMap` entry. Typed anyway, `<` lands as `,`, `>` as `.`,
`?` toggles inverse video (the INV key), and `[` / `]` land as `=` / `"`. The
SAM examples avoid them all and compare with `SGN`. Everything else in the
`charMap`, including capitals, landed exactly through the `typeText()` path
in every listing typed.

**`NEW` can bring back the MGT banner, and the banner eats a key.** After `NEW`
with a program in memory, the SAM sometimes redraws the
`MILES GORDON TECHNOLOGY PLC © 1990 SAM Coupé 512K` banner for about a second.
The next keypress only dismisses it. With the editor's 600 ms ENTER settle,
that keypress is the `1` of line `10`. The SAM then rejects `0 REM …` with
`29 Not understood` and typing carries on, so the listing loses its first line.
A frame-by-frame capture shows the banner up from 0.1 s to at least 0.5 s
after the ENTER, and gone once the `1` arrives at 0.6 s. It happened in 4 of
the 7 runs at 600 ms. Waiting 1.5 s or more after `NEW` avoided it in 6 of 7
runs; the seventh is unexplained. A per-line settle after `NEW` (at least 2 s) is
the fix, and it belongs in `typeIn`, not in the listings. That field now exists
(`typeIn.newDelayMs`, built for the 48K Spectrum below), but the SAM does not
declare it yet: the loss stands until a value is proven on a SAM rig. The
station's demo listing (`NEW`, then `10 MODE 4`) is exposed to the same loss.

### The keyword transcoder (zxspectrum, zx81)

Both machines boot into keyword entry: the 48K Spectrum (`spectrum`,
`-bios en`, the untouched 1982 screen; not 128K BASIC) and the ZX81
(`-bios 2nd`, 1 KB, a lone `K` cursor). ASCII through the `typeText()` path
does not just fail; on the Spectrum it can **succeed wrongly**.
`10 PRINT "Hi"` was accepted as `10 PRINT rint hi`: P in K mode gave PRINT,
the remaining letters became a variable name, and the quotes were dropped
(SYMBOL SHIFT is host Right Shift, and `typeText()` only sends Left Shift). On
the ZX81 the same line became `10 "S<=(<<> **(` and was rejected. So on these
two stations the editor (and the Spectrum's demo listing) types **key chords**,
never characters.

**The transcoder** (`spa/src/ui/typein/keywordEntry.ts`, `transcodeLine`) turns
one ASCII line into chords. It tracks the cursor mode the ROM will be in, the
way the ROM's own line printer decides it:

- **K** at the start of a statement: after the line number, after THEN, and on
  the Spectrum after a `:` outside quotes. Digits and spaces leave the mode
  alone. Here a statement keyword is one key, matched greedily, longest
  spelling first (`INPUT` before `IN`), case-insensitively, with or without
  spaces (`GO TO`/`GOTO`, `OPEN #`/`OPEN#`; `CONT` and `RAND` are accepted for
  the Spectrum's `CONTINUE` and `RANDOMIZE`).
- **L** everywhere else. A keyword here must be a whole word (`total` is not
  `TO`), and it is a SYMBOL SHIFT / SHIFT chord, or an E-mode (Spectrum: CAPS +
  SYMBOL together) or FUNCTION (ZX81: SHIFT + NEWLINE) prefix and then the key.
  Symbols are shift chords; `<=` `>=` `<>` (and the ZX81's `**`) are one token
  each. Letters follow the machine's case: Spectrum lower case is the bare key
  and capitals are CAPS SHIFT + key; every ZX81 letter is the bare key.
- **Literal** inside quotes and after REM: every character is its own key.
  Spaces between tokens are dropped (the ROM prints its own), but kept inside
  strings and REM, except the one straight after REM, which the ROM prints. A
  `""` inside a ZX81 string is its one quote-image key (SHIFT + Q).

Two ROM facts were measured on rigs before they were modelled. **The
Spectrum's ROM reads `:` as a statement start even inside a REM**: `10 REM a:b`
keyed letter by letter listed as `10 REM a: BORDER`. A letter after `:` in a
REM is therefore reported, not typed. **The ZX81 returns to K after THEN**
(`IF A=1 THEN` then P gave PRINT) and has no statement separator, so its `:`
is a plain character.

What the machine cannot type is an issue the editor shows (see above), never a
silent drop. Typing does not start until the listing is clean.

**The key table** (`spa/src/data/keywordKeys.ts`) is GENERATED by
`stations-registry.py generate` (`scripts/stations_registry/keyword_keys.py`)
from the station's own keymap, so the chords are exactly the scancodes the
daemon maps to those keys. Each keymap field name is MAME's key legend, e.g.
`p    P    "      TAB      (c)    PRINT`: key, CAPS, SYMBOL, E, E + SYMBOL,
K. Only two things are hand-entered, each checked against the ROM's own key
tables and a rig:

- MAME 0.289 names the Spectrum's 8 and 9 keys with CAT and POINT swapped. The
  ROM's extended-mode digit table reads 8 = POINT, 9 = CAT, and E + SYMBOL + 8
  typed POINT on a rig. The generator asserts MAME's wrong names, so a fixed
  MAME fails generation instead of being "fixed" twice.
- MAME's zx81 names carry no FUNCTION legends and no K keyword for Z X C V.
  Both come from the keyboard drawing in chapter 2 of the ZX81 manual (Q SIN,
  W COS … B INKEY$, N NOT, M PI; COPY CLEAR CONT CLS), and match the ROM's
  FUNCTION table key for key.

**The chord typist.** `StreamControlHandle.typeChord(scancodes)` presses the
scancodes in order and releases them in reverse, back to back
(`spa/src/three/syntheticTyping.ts`). `typeLines(…, { chords })` sends one chord
per call and waits `perCharMs` after each, so every edge of a chord, its
modifier releases included, is applied before the next chord's first press
(the reason is under `DEMO_CHUNK_CHARS` in `typeDemoProgram.ts`). The station's
key module applies a chord's modifiers in the same pass as its key and releases
them with it, so a chord drains in hold + gap like one character. The
validator holds `perCharMs`, `enterDelayMs` and `newDelayMs` to at least hold +
gap on a keyword-entry station, because ENTER is a chord too.

**Modifier timing.** No chord lost its SYMBOL SHIFT, CAPS SHIFT, SHIFT or E-mode
prefix on either machine in about 1,100 chords typed on rigs on 2026-10-04,
several hundred of them shifted. Both ROMs read the whole matrix in one pass
per frame, so a shift that lands in the same scan as its key is read with it.
This is unlike the QL's 8049 (above), so no station declares a longer modifier
hold.

**Pace, measured on rigs of the stations' own binaries** (2026-10-04):

| Station | Value | Why |
|---|---|---|
| zxspectrum | `perCharMs` 400 | One chord at the station's 200/200 hold/gap. The ROM's interrupt latches a key it is too busy to read at once, so one chord's budget is enough: all three examples, about 400 chords, typed exactly |
| zxspectrum | `newDelayMs` 3000 | `NEW` makes the 48K ROM clear and re-test its memory with interrupts off. Keys sent 0.6, 1.2 and 1.8 s after its ENTER were lost; 2.4 s landed |
| zx81 | `perCharMs` 400 | Hold + gap is only 100/100, but the 1 KB ZX81 rebuilds its edit line after every key, and in SLOW mode that takes longer as the line grows: 100–150 ms early in a line, 200–360 ms at the end of a 36-character one. At a 200 ms pitch the `(` after the second `SIN` in `20 PLOT 20+12*SIN (T/4),22+10*SIN (T/2)` was lost |
| zx81 | `enterDelayMs` 1000, `enterDelayPerLineMs` 100 | After ENTER it re-lists the program into its collapsed display, about 90 ms more per listed line (170 ms after `NEW`, 1.5 s after the 14th line of a test listing). A key that arrives during the redraw is lost: at a flat 600 ms, line `40`'s number went missing and the rest ran as a direct command (`2/0`) |

These are wall-clock waits, and the key module paces in emulated time. On a
host at load ~100 (16 cores), a rig's MAME ran at ~30 % speed: key edges still
arrived intact, but every settle shrank in emulated time and lines were lost.
The values above leave margin for an ordinary load, not for that.

**Examples** (`registry/examples/zxspectrum/`, `zx81/`) start with `NEW`, so a
second example does not inherit the first one's lines. They were typed on rigs
through the transcoder's own chord stream (`transcodeLine` + `paceFor`, played
into the station's ctlsock module through its keymap), LISTed and RUN, and the
framebuffer read:

| Example | What the frame showed |
|---|---|
| Spectrum `draw.bas` Colour web | the exact listing; cyan rays and six coloured rings, rays recoloured where they cross a ring (attribute clash), `0 OK, 70:1` |
| Spectrum `input.bas` Times table | `A number?` prompt; 7 gave `1 x 7 = 7` … `10 x 7 = 70` |
| Spectrum `game.bas` Catch | the bat moved right on P and left on O; the score counted catches |
| ZX81 `draw.bas` Figure of eight | the exact listing; a sideways figure of eight in block pixels, `0/30` |
| ZX81 `input.bas` Square and cube | `NUMBER?`; 7 gave `7 SQUARED IS 49`, `7 CUBED IS 343` |
| ZX81 `game.bas` Letter dash | a random letter; pressing it printed `TIME` and drew the next |

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
