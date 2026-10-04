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
| vic20 c64basic pet2001 cbm8032 c128 plus4 cbm2 | Commodore BASIC at power-on (c64basic is the C64 that stops at READY; the GEOS `c64` stays out) |
| bbcmicro armeval | BBC BASIC (armeval: ARM BASIC on the tube) |
| msx2 svi728 svi328 | MSX-BASIC / SV BASIC at power-on |
| amstradcpc | Locomotive BASIC |
| dragon32 oricatmos mpf2 | Microsoft-family BASICs (Color, Oric, Applesoft-like) |
| sinclairql | SuperBASIC |
| samcoupe | SAM BASIC, one keypress away (the `hint` tells the visitor to press B first) |
| kc854 | HC-BASIC, one typed command away (the `hint` tells the visitor to type BASIC and press ENTER twice; [details below](#kc-854-getting-into-hc-basic-and-what-basic-does-twice)) |

| Out | Why |
|---|---|
| zxspectrum, zx81 | **Keyword entry.** One key *is* a keyword (P gives PRINT), so ASCII typed letter by letter arrives as garbage. The demo listing types keystroke form (`10 b1`) for exactly this reason. Supporting them needs a keyword transcoder, which is a follow-up; its measured design is [below](#keyword-transcoder-for-zxspectrum-and-zx81-measured-not-built). |
| svi328cpm, svi738 | Boot to CP/M; MBASIC has to be loaded first (their demo listings do that with a 20 s settle). |
| atari800xl, apple2e | Boot to a menu or a DOS, not to an interpreter. |
| c64 | Boots to the GEOS deskTop, not to BASIC. The C64 with the editor is its sibling [`c64basic`](guests/c64basic.md): the same x64sc binary, stopped at the BASIC V2 READY prompt. |
| apple2, msxturbor | Boot to GEOS / MSX View desktops. |

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
| `maxLineChars` | The machine's logical line length. The editor strikes through what the screen editor would cut off. Declared only where the number is certain (VIC-20 88, PET/8032 80, C64 80, C128 160). |
| `hint` | One sentence above the Type button, for a step the machine needs first. |
| `settleAfter` | A longer ENTER settle after a named direct command, keyed by the whole line in upper case. On samcoupe, `{"NEW": 2000}`: `NEW` redraws the MGT banner, and that eats the next key. With the default 600 ms, line 10 was lost in 4 of 7 runs; with 1.5 s it was lost in 1 of 7 (examples-sinclair rig, `tl-06…08.png`). The SAM demo listing waits 2 s after its own `NEW` (`demoProgram.enterDelayMs: [2000]`). |
| `unreachable` | Printable ASCII that the station's keymap cannot produce. On samcoupe these are `< > ? [ ] { } \` and the vertical bar; on c64basic `{ }` (VICE's C64 keymap has no braces, and they vanish). The editor paints these red and blocks typing, exactly as it does for non-ASCII. The examples validator refuses them too. |

`stations-registry.py new --like` does **not** copy `typeIn`. The dialect and
case rule are facts about the sibling's interpreter, so a new machine opts in
once its own typing is proven.

### The case rule

`typeText()` presses what a US PC keyboard would, so `A` is Shift+a. That is
wrong on most of these machines:

| `case` | What reaches the guest | Stations |
|---|---|---|
| `unshifted` | every letter goes down unshifted | vic20 c64basic pet2001 c128 plus4 (Shift+letter is a graphics glyph); bbcmicro armeval oricatmos (CAPS LOCK on at reset: every letter arrives upper case whichever way it is sent, so unshifted is simply the demo listings' proven path; lower case inside a string is out of reach either way); dragon32 mpf2 (no lower case) |
| `code-lower` | letters outside strings, REM and DATA go down unshifted; literals keep the visitor's case | cbm8032 cbm2 (business keyboard, text mode: unshifted is lower case, and BASIC wants it) |
| `code-upper` | code is upper-cased, literals kept | msx2 svi728 svi328 (the proven demo path) |
| `as-typed` (default) | unchanged | amstradcpc sinclairql samcoupe kc854 |

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
- lines fit `maxLineChars` and use no `unreachable` symbol;
- the first line is not `NEW` (see below);
- manual URLs are `https://` and `lang` is a two-letter code.

A station with no folder simply has no examples. That is never an error.

**The editor clears the machine first.** A program typed over another keeps
the old program's lines wherever the new one does not reuse their numbers.
That happens to the second example a visitor opens, and to the SAM's boot-menu
program (lines 85 and 9000 survive pressing B). So a run starts with the
dialect's `NEW` (`clearCommand` in `basicDialects.ts`; it is `NEW` in all ten, HC-BASIC included).
The panel's "Clear the machine's old program first" checkbox controls it. It is
on by default and turns back on whenever an example or a file is opened. A
visitor adding lines to a program already in memory can untick it. A listing
that already starts with `NEW` (the SAM and SV-328 demo listings) does not get
a second one. Example files therefore never carry `NEW`, and the validator
refuses one that does, so the editor is the one place it comes from.
Line 10 of the SAM and QL examples is a REM title on purpose: if a machine
still eats a key after `NEW`, the worst case is a lost title, not a lost
statement.

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

The C64 is worse, and slowing down does not help (c64basic, 2026-10-04, rig
of the station's own x64sc restored from its golden). The listing was a
10-line stress test with 44 such characters per pass (25 `:`, 14 `*`, 4 `+`
and one `@`), typed as a rollover burst at 6 keys/s and read back the same
way:

| Path | module hold/gap | corrupted lines |
|---|---|---|
| Shift_L press, then the shifted keysym | 60/60 | 12 of 60 (a `*` lost or a `:` turned `[`, about 1 such character in 20) |
| Shift_L press, then the shifted keysym | 100/100 | 10 of 30 (also a lost `@` and a lost `+`) |
| The keysym alone, no Shift edge (control) | 60/60 | 0 of 30 |

So the station keeps the VICE floor of 60/60: no character without a Shift
edge was lost at that pace, and the failure rate did not fall at 100/100. The
c64basic examples keep `:` and `*` few for the same reason. Through the real
editor on the live station it hit once in four listing runs: a `+` in Quick
Draw's line 40 arrived as the shifted-`+` graphics glyph, and RUN stopped with
`?SYNTAX ERROR IN 40` ([`guests/c64basic.md`](guests/c64basic.md#verification-2026-10-04-live)).

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
`\` `|` have no `charMap` entry, so the station declares them in
`typeIn.unreachable`. The editor paints them red and will not type a listing
holding one, and the examples validator refuses them. Typed anyway, `<` lands as `,`, `>` as `.`,
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
runs; the seventh is unexplained. **Fixed in `typeIn`, not in the listings:**
`settleAfter: {"NEW": 2000}` makes the editor wait 2 s after the `NEW` it
types, and the station's demo listing (`NEW`, then `10 MODE 4`) waits 2 s
after its own `NEW` (`demoProgram.enterDelayMs: [2000]`).

### MPF-II, Dragon 32 and the MSX family: punctuation and the MPF-II scroll

**The MPF-II `charMap` used to drop quotes.** It covered only `= - + ( ) *`.
A typed `"` went to the PC apostrophe key, which has no matrix position on the
MPF-II, so it vanished; `:` and `;` came out swapped, as did `/` and `?`, and
`&` / `'` landed one key along. Every `PRINT "…"` and every multi-statement
line was wrong. The map now carries all of them, each read back on a rig
framebuffer on 2026-10-04 (`docs/guests/mpf2.md`).

**The MPF-II loses keys while it scrolls.** Its text is painted into the hires
bitmap and scrolled in software, and the keyboard is not scanned meanwhile.
When a typed line wrapped past column 39 at the bottom of the screen, the next
one or two characters were lost (`CANNOT` arrived as `CAOT`, and a `:` after a
closing quote disappeared). The MPF-II examples keep every line within 38
characters. A visitor's longer line is still exposed: a pause in the typist at
the wrap column, or `maxLineChars: 38` (which would strike text the machine
does not actually cut off), are the two candidate fixes. Keys pressed while a
program prints are lost the same way; there is no type-ahead buffer.

**`unreachable` for the five Microsoft-BASIC stations** was derived from each
keymap and checked on the framebuffer for msx2 and svi328. On the MSX keyboards
the PC backslash key is the MSX backtick key and the PC backtick is a dead key,
so backslash, vertical bar, backtick and tilde cannot be typed (MSX BASIC's
integer-division `\` included); the SV-328 loses only the last three. The
Dragon 32 also cannot reach `[ ] ^ _ { }`: its `^` lives on the up-arrow key,
and a typed `^` arrives as `&`. The MPF-II has no `[ ] _ { }` either.

### KC 85/4: getting into HC-BASIC, and what BASIC does twice

**Proven on a sandbox rig of the station's own MAME binary and 80/80 pacing, 2026-10-04**, typing through the registry `charMap` at the editor's 260 ms/char with 260/600 ms line and ENTER settles.

**The way in.** The machine boots to the CAOS 4.2 menu. `BASIC` + ENTER answers `MEMORY END ? :`, and a bare ENTER accepts the default: `47854 BYTES FREE`, `OK`. That is the `hint` ("First type BASIC and press ENTER twice to wake HC-BASIC."). The registry carries no preamble field, and the examples do not start with `BASIC`.

**`BASIC` typed again inside HC-BASIC is harmless.** HC-BASIC reads it as a variable name and answers `?SN ERROR` / `OK`; the next bare ENTER is an empty line (a program in memory was not tried). A visitor who follows the hint twice loses nothing. (To leave and come back with the program kept, CAOS has `REBASIC`; `BYE` leaves HC-BASIC. The BASIC-Handbuch chapter 1 documents both.)

**Case.** The case rule is `as-typed`. The KC's unshifted letters are capitals, and the station `charMap` swaps the case, so a capital listing arrives unshifted. HC-BASIC also accepts keywords in lower case (`print 1+2` printed 3), so a visitor's lower-case code does not break either.

**The dialect.** The `kc-basic` word list is read from the two token tables in the shipping ROMs: the 8 KB BASIC ROM, and CAOS 4.2's extension table (`CLS`, `PSET`, `PRESET`, `LINE`, `CIRCLE`, `LOCATE`, `INKEY$`, `COLOR`, `INK`, `PAPER`, `BEEP`, `SOUND` and others). Graphics coordinates are 320 by 256 with `y` counted up from the bottom; the colour is the last argument (`CIRCLE x,y,r,c`, 2 red, 4 green, 6 yellow, 7 white). `LOCATE` takes row, then column. `INPUT` works only inside a program (direct mode gives `?ID ERROR`).

**Traps found.** `THEN END ELSE 20` is a `?SN ERROR`; use two lines. `LIST` of a long program stops when the screen fills and swallows the next keys until one is typed, so type something harmless before `RUN`.

**Examples (`registry/examples/kc854/`).** Each was typed whole with the editor's timing and read off the framebuffer: *Rainbow target* draws six coloured rings and a crosshair; *Times table* asks for a number and prints its ten-times table (typed 7, got 7 x 1 = 7 down to 7 x 10 = 70); *Stop the dot* stops on a key (OFF BY 7 and OFF BY 2 in two rounds), replays on any key and ends cleanly on N. The manuals are the original German BASIC-Handbuch and Systemhandbuch (1988).

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
