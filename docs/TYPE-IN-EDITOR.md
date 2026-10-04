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
| zxspectrum, zx81 | **Keyword entry.** One key *is* a keyword (P gives PRINT), so ASCII typed letter by letter arrives as garbage. The demo listing types keystroke form (`10 b1`) for exactly this reason. Supporting them needs a keyword transcoder, which is a follow-up; its measured design is [below](#keyword-transcoder-for-zxspectrum-and-zx81-measured-not-built). |
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

### Shifted characters: the modifier lead

`typeText()` sends a shifted character as Shift down, key down, key up, Shift
up, back to back, and the daemon forwards those edges unchanged. Until
2026-10-04 both emulator key modules then put Shift and the key into the
emulated keyboard **at the same instant**, which a person never does: their
Shift goes down tens of milliseconds before the key. Two machines failed on
that one shape in two different ways. Both modules now hold a key press until
the Shift level in front of it has been visible to the machine for a
**modifier lead**, declared per station as `SH_KEY_MOD_LEAD_MS` in the station
env. The launchers pass it to the module as `MAME_CTL_KEY_MOD_LEAD` or
`VICE_CTL_KEY_MOD_LEAD`; unset or 0 is the old engine, byte for byte. The
validator counts the lead in the drain rate: a shifted character costs at most
HOLD + max(GAP, LEAD) + LEAD, and `perCharMs` must cover that.

**The QL, MAME `ctlsock`: the key vanished.** The module applied Shift and the
key in the same drain pass. A trace shows `:Y7|SHIFT=1` and `:Y3|=  +=1` both
applied at emulated 53.894 s. The QL's 8049 IPC then never reports the key, so
every capital and every shifted symbol was lost: `print 1+2` landed as
`print 12`, `10 REMark Sunburst` as `10 ark unburst`. With the lead, a
non-modifier press waits that many emulated milliseconds after the last
applied Shift or Ctrl edge, press or release. The test was a 12-line
SuperBASIC listing with 251 shifted characters, typed with the editor's edges
at its 400 ms per character into a rig of the station's own binary, golden and
40/40 pacing. It was then LISTed and compared pixel for pixel, line by line,
with a reference typed with Shift held 150 ms ahead by hand:

| Lead | Listing lines exact |
|---|---|
| 0, the old engine | 0 of 12: every line `bad line` |
| 1 ms, one module tick | 3 of 12 |
| 2, 5, 10 ms | 12 of 12 |
| 20 ms | 12 of 12 in three runs |
| 40, 60 ms | 12 of 12 (three runs at 40) |

The threshold is between 1 and 2 ms, and sinclairql ships 20 ms, ten times
that. The lead is emulated time, so host load cannot eat it. It costs a
shifted character at most 40 ms against the editor's 400.

**The Commodores, VICE `vicectl`: the scan tore the latch.** VICE resolves a
keysym through the machine's `.vkm` keymap, and on a VIC-20 `:` `*` `+` `@`
are Shift+key on a US keyboard but unshifted keys (the keymap's *deshift*),
while `'` `[` `]` are the other way round (*virtual shift*). VICE applies each
host key event at its own random point 1 to 2 frames later. A key whose keymap
entry changes the emulated SHIFT therefore flips SHIFT and sets the key in ONE
copy of the matrix. The KERNAL reads the matrix column by column over about
1,000 cycles of its jiffy interrupt. When that copy lands mid-scan, the guest
reads SHIFT from before it and the key from after it: `:` became `[` (VIC-20,
C128) or `*` (8032), and on the C128 a `*` vanished outright. The trace of a
failing `:` is indistinguishable from a good one, because the race is inside
VICE.

With a lead, the module **stages the Shift level**. The visitor's Shift edges
set a level and are no longer passed to VICE directly. Before each press the
module gives VICE the host Shift that key needs: none for a deshift key, Shift
for a virtual-shift key, and the visitor's own level otherwise. It then holds
the press until that level has been visible for the lead, and hands the
visitor's level back once nothing is down. VICE's keymap then finds the level
already in place, so nothing changes SHIFT in the key's own latch. The
three barrier rules of `key_drain()` are unchanged, and the lead is one more
dwell gate, cleared by time alone. A `:` typed with Shift held never touches
VICE's Shift at all.

The test was a 12-line stress listing with 122 level-changing characters a
pass (`:` `*` `+` `'`, among `"` `( )` `$` `=`). It was typed with the
editor's edges at 170 ms per character, then read back byte for byte from a
`SAVEST` snapshot and tokenised with VICE's `petcat`:

| Station | Old binary | New binary, lead 40 ms (2 frames) |
|---|---|---|
| vic20 | 4 bad lines in 3 passes | 0 in 3 (and 0 in 3 at 1 frame, 0 in 2 at 3 frames) |
| cbm8032 | 5 bad lines in 3 passes | 0 in 3 |
| c128 | 6 bad lines in 3 passes | 0 in 3 |

Two frames is the shipped value because it is the smallest one that is safe by
construction rather than by luck. VICE latches an event at most about a frame
and 1,000 cycles after it is pushed, so with a two-frame lead a whole frame
always separates the Shift latch from the key's latch. One jiffy scan cannot
straddle both. A visitor typing `:` on a physical keyboard got the same
`[`, and is fixed by the same change.

VICE's own 8-slot `kbd_queue`, which drops silently when full, cannot overflow
from this module. Under `VICE_CTL_KEY_EXCL=1`, which every VICE station runs,
a frame's drain applies at most one press, one release and one edge per
modifier key, and the queue empties within about a frame.

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
the fix, and it belongs in `typeIn`, not in the listings. The station's demo
listing (`NEW`, then `10 MODE 4`) is exposed to the same loss.

### Keyword transcoder for zxspectrum and zx81 (measured, not built)

Both machines boot into keyword entry: the 48K Spectrum (`spectrum`,
`-bios en`, the untouched 1982 screen; not 128K BASIC) and the ZX81
(`-bios 2nd`, 1 KB, a lone `K` cursor). ASCII through the `typeText()` path
does not just fail; on the Spectrum it can **succeed wrongly**.
`10 PRINT "Hi"` was accepted as `10 PRINT rint hi`: P in K mode gave PRINT,
the remaining letters became a variable name, and the quotes were dropped
(SYMBOL SHIFT is host Right Shift, and `typeText()` only sends Left Shift). On
the ZX81 the same line became `10 "S<=(<<> **(` and was rejected, because every
capital went out as SHIFT+letter, which on the ZX81 is a symbol or token. The
station has no `keyboard` block, so this happens to any typed text there.

What works, proven on rigs on 2026-10-04 by sending key chords instead of ASCII:

- **Spectrum**: `10 PRINT "Hi"` / `20 INK 2: CIRCLE 128,88,40` keyed as 26
  chords. These were `p` for PRINT in K mode, RShift+`p` for `"`,
  LShift+`h`, RShift+`z` for `:`, and CAPS+SYMBOL (E mode) then RShift+`x`
  for INK and RShift+`h` for CIRCLE. The listing came out exact, and RUN
  printed `Hi` and drew a red circle.
- **ZX81**: `10 PRINT "HI"` / `20 PRINT INT (RND*9)` keyed as `p` for PRINT,
  SHIFT+`p` for `"`, and FUNCTION (SHIFT+NEWLINE) then `r` for INT and `t` for
  RND. The listing came out exact, and RUN printed `HI` and a digit.

The smallest transcoder that would carry an ASCII listing:

1. **Track the cursor mode the ROM will be in.** K at the start of a statement
   (after the line number, after `:`, after THEN), L otherwise, and literal
   text inside quotes and after REM.
2. **Tokenise greedily against a per-machine table**, mapping each keyword or
   symbol to a chord sequence:
   - a K-mode statement keyword is one key;
   - an L-mode operator or keyword (TO STEP THEN AND OR NOT AT `<=` `<>`
     `>=`) and every symbol is a shift chord: SYMBOL SHIFT (RShift) on the
     Spectrum, SHIFT on the ZX81;
   - a function is E mode (Spectrum: LShift+RShift, then the key, plus RShift
     for INK PAPER FLASH BRIGHT INVERSE OVER CIRCLE BEEP …) or FUNCTION mode
     (ZX81: SHIFT+NEWLINE, then the key);
   - letters: on the Spectrum lower case is the bare key and upper case is
     LShift+key; on the ZX81 every letter is the bare key.
3. **Drop spaces between tokens.** The ROM prints its own. Keep them inside
   strings and REM.
4. **Send chords, not characters.** This needs a typist call that can send
   RShift and multi-key chords, which `typeText()` cannot.

The Spectrum table can be generated mechanically: `zxspectrum.keymap`'s
comments already list each key's K, CAPS, SYMBOL, E and E+SYMBOL legends.
`zx81.keymap` carries the K and SHIFT legends only, so the FUNCTION-mode
column comes from the ZX81 manual's key legends (R=INT and T=RND are proven
above). Pace at the stations' own hold/gap: 200/200 on the Spectrum and a
100/100 window on the ZX81. The ZX81's 1 KB also caps an example at a few
hundred bytes, screen included.

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
