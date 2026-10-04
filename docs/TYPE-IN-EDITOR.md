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

| In (22) | Why |
|---|---|
| vic20 c64basic pet2001 cbm8032 c128 plus4 cbm2 | Commodore BASIC at power-on (c64basic is the C64 that stops at READY; the GEOS `c64` stays out) |
| bbcmicro armeval | BBC BASIC (armeval: ARM BASIC on the tube) |
| msx2 svi728 svi328 | MSX-BASIC / SV BASIC at power-on |
| amstradcpc | Locomotive BASIC |
| dragon32 oricatmos mpf2 | Microsoft-family BASICs (Color, Oric, Applesoft-like) |
| sinclairql | SuperBASIC |
| samcoupe | SAM BASIC, one keypress away (the `hint` tells the visitor to press B first) |
| zxspectrum zx81 | Keyword entry (48K Sinclair BASIC, ZX81 BASIC), typed as key chords by the [keyword transcoder](#the-keyword-transcoder-zxspectrum-zx81) |
| kc854 | HC-BASIC, one typed command away (the `hint` tells the visitor to type BASIC and press ENTER twice; [details below](#kc-854-getting-into-hc-basic-and-what-basic-does-twice)) |
| apple2e | Applesoft BASIC, one keypress away: the ProDOS menu's `[B] BASIC prompt` (the `hint` tells the visitor to press B first; [details below](#apple-e-the-b-key-and-the-shift-key-it-never-had)) |

| Out | Why |
|---|---|
| svi328cpm, svi738 | Boot to CP/M; MBASIC has to be loaded first (their demo listings do that with a 20 s settle). |
| atari800xl | Boots to a menu (MyPicoDos), and its Atari BASIC exit does not reach READY. |
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
| `dialect` | Keyword list for the highlighter (`spa/src/ui/typein/basicDialects.ts`): `cbm-basic bbc-basic msx-basic locomotive-basic superbasic sam-basic oric-basic color-basic applesoft`, and the two keyword-entry dialects `sinclair-basic zx81-basic`, which also select the [keyword transcoder](#the-keyword-transcoder-zxspectrum-zx81). |
| `perCharMs` | **Required.** The wait after every typed character. Must be ≥ hold+gap (`scripts/stations_registry/validate_typein.py`). It is never defaulted: the demo may fall back to the SPA's 70 ms, but the editor may not. |
| `lineDelayMs` / `enterDelayMs` | The pause before a line's ENTER and the settle after it, for BASIC to tokenise. They default to the demo typist's 260 / 600 ms. **These three numbers are the tuning surface for long listings.** Change them here, never in a component. |
| `enterDelayPerLineMs` | Added to the settle after line N, N times (0-based), for a machine whose redraw after ENTER grows with the listing (the ZX81). Default 0. |
| `wrapPause` | `{ "cols": 40, "ms": 500, "promptCols": 1 }`. For a machine that drops keys while it scrolls: after every `cols`-th screen column of a typed line (the screen width) the typist waits `ms` more before the next character. `promptCols` (default 0) is how many columns the prompt takes on the first row, so the first wrap comes that many characters sooner. Not after a line's last character. Absent = no pause. Measured on mpf2: [below](#mpf-ii-dragon-32-and-the-msx-family-punctuation-and-the-mpf-ii-scroll). |
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
| `unshifted` | every letter goes down unshifted | vic20 c64basic pet2001 c128 plus4 (Shift+letter is a graphics glyph); bbcmicro armeval oricatmos apple2e (CAPS LOCK on at reset: every letter arrives upper case whichever way it is sent, so unshifted is simply the demo listings' proven path; lower case inside a string is out of reach either way); dragon32 mpf2 (no lower case) |
| `code-lower` | letters outside strings, REM and DATA go down unshifted; literals keep the visitor's case | cbm8032 cbm2 (business keyboard, text mode: unshifted is lower case, and BASIC wants it) |
| `code-upper` | code is upper-cased, literals kept | msx2 svi728 svi328 (the proven demo path) |
| `as-typed` (default) | unchanged | amstradcpc sinclairql samcoupe kc854 |

The keyword-entry dialects take no `case` (the validator refuses one): the
transcoder decides. On the Spectrum a lower-case letter is the bare key and a
capital is CAPS SHIFT + key; the ZX81 has no lower case, so every letter is the
bare key.

The station `keyboard` block (`charMap`, `letterCase`) is applied after the
case rule, exactly as for the demo listing.

**The same rule on the visitor's keyboard.** On every `case: unshifted` station
whose letter keys ARE the capitals (the Commodores and the rest of that row), a
capital letter that reaches the SPA without the visitor physically holding
Shift (Caps Lock, AutoHotkey `SendText`, an IME or a paste tool) goes to the
guest as the plain unshifted letter key. Without this, `asdfghASDFGH` showed
`ASDFGH` and then graphics glyphs on a VIC-20, because the SPA turns `A` into a
synthetic Shift+a. The data source is `typeIn.case === 'unshifted'`
(`spa/src/three/capitalsAsLetters.ts`), not `keyboard.letterCase`, which only a
subset declares and which `zxspectrum` also sets (there CAPS SHIFT + letter is a
real capital). cbm8032 and cbm2 (`code-lower`), c64 (GEOS, no `typeIn`) and
every PC and Unix station are untouched. A letter typed while Shift is held
(physically, or latched on the on-screen keyboard) keeps its Shift, so the
graphics set stays reachable. The unshifted press is an ordinary make/break, so
hold and repeat work and the keyup releases the same scancode. The on-screen
keyboard's `char` keys (`typeText`) are NOT changed: its shifted layer is the
visitor choosing Shift, and the editor's own typing already follows `case`.

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
dialect's `NEW` (`clearCommand` in `basicDialects.ts`; it is `NEW` in all twelve, HC-BASIC and the two keyword-entry dialects included).
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

## The visitor's keyboard is paused while the editor types

A physical key that reaches the guest mid-run corrupts the listing. On
2026-10-04 a macOS screenshot (Cmd+Shift+4) during the vic20 "Colour Squares"
run put physical Shift and Cmd down between two typed characters. The guest saw
Shift held, so `UB 100` arrived as graphics glyphs (shifted letters on a
VIC-20) until the typist's next `:` released it, and line 50 failed with
`?UNDEF'D STATEMENT`.

The editor now prevents it. While a run (the editor's, and the stage menu's demo
listing) is typing, `StreamControlHandle.holdKeyboard()` is held and the
visitor's keys are dropped before they reach the guest: key down and up,
modifiers included, and the on-screen keyboard. The mechanism is
`spa/src/three/keyHold.ts`:

- at run start, keys the guest believes are down are released;
- a key held at the start, or pressed during the run, has its repeats and its
  release swallowed after the run, so no orphan release is sent and nothing is
  "pressed" retroactively;
- when the run ends, is stopped, or the stream drops, forwarding resumes from a
  clean slate.

The progress line carries the note "Your keyboard is paused while the editor
types — press Stop to take over." Stop is the way back (Escape is not bound).

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

**Without exclusive-scan, the lead needs the ordering barriers too.** The
module's three ordering rules (a modifier edge never moves; a press never
overtakes a press or a waiting modifier; a release may overtake a waiting
press) used to apply only under `MAME_CTL_KEY_EXCL`. The QL has EXCL, so its
lead worked. On a station without it the lead deferred the key press, but
Shift's own release is another field that nothing held back, so it applied in
the same pass and the key landed unshifted. The apple2e, which has no EXCL,
typed `(` as `9` and `$` as `4` with the first build of the lead. Since
2026-10-04 a lead above 0 turns the three rules on for every station. A
station with EXCL behaves exactly as before, and lead 0 without EXCL is still
the old engine, byte for byte.

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

The first test (vic20, cbm8032, c128) was a 12-line stress listing with 122
level-changing characters a pass (`:` `*` `+` `'`, among `"` `( )` `$` `=`).
It was typed with the editor's edges at 170 ms per character, then read back
byte for byte from a `SAVEST` snapshot and tokenised with VICE's `petcat`. On
the old binaries vic20 tore 4 lines in 3 passes, cbm8032 5 and c128 6; with
the lead at two frames, none.

**Every VICE station, 2026-10-04.** The rollout to the rest of the family
used a 14-line listing, the 12 above plus two lines dense in `@` `[` `]`
(`/data/vms/streamhost/stations/<id>/evidence/shift-lead-2026-10-04/cbm-stress.bas`).
Every pass went through the real daemon: a sandbox daemon in front of a rig of
the station's own binary, golden and pacing, typed by
`scripts/e2e/key-burst-proof.mjs` at the station's `typeIn` pace with `NEW`
first, exactly as the editor does, and read back from a snapshot. The three
examples were typed the same way, three times each:

| Station | Frame (measured) | Lead | Stress listing, old binary | New binary | Examples, new binary |
|---|---|---|---|---|---|
| vic20 | PAL, 22 152 cycles | 40 ms = 2 frames | 4 bad lines in 3 passes (12-line listing) | 0 in 3 | 30 of 30 |
| pet2001 | **60 Hz**, 16 640 cycles | **33 ms** = 2 frames | 0 in 3 | 0 in 3 | 9 of 9 |
| cbm8032 | 50 Hz CRTC, 20 032 cycles | 40 ms = 2 frames | 1 in 3 (`:` -> `*`) | 0 in 3 | 9 of 9 |
| c128 | PAL, 19 656 cycles | 40 ms = 2 frames | 10 in 3 (`:` -> `[`, `+` -> its glyph, `*` gone) | 0 in 3 | 10 of 10 |
| plus4 | PAL TED, 35 568 cycles | 40 ms = 2 frames | 9 in 3 | 0 in 3 | 9 of 9 |
| cbm2 | 50 Hz CRTC, 40 064 cycles | 40 ms = 2 frames | 0 in 3 | 0 in 3 | 9 of 9 |
| c64basic | PAL, 19 656 cycles | 40 ms = 2 frames | 20 in 3 | 0 in 3 | 9 of 9 |
| c64 (GEOS) | PAL, 19 656 cycles | 40 ms = 2 frames | no BASIC; same x64sc as c64basic | GEOS rename field: 3 entries exact | no `typeIn` |

How exposed a machine is follows from its keymap. The VIC-20, C64, C128 and
Plus/4 share the deshift set `:` `*` `+` `@` and the virtual-shift set `'`
`[` `]`, and tore the most. On the 8032's business keyboard only `:` and `'`
change the level. On the CBM-II keyboard, laid out like a US one, none of the
listing's characters do. On the 2001's graphics keyboard every shifted symbol
is a deshift key, yet the old binary lost none in three passes; its KERNAL
did not read a torn latch at this sample size. All of them ship the lead
anyway, because the engine is one, and the frame argument below holds for
each.

Two frames is the shipped value because it is the smallest one that is safe by
construction rather than by luck. VICE latches an event at most about a frame
and 1,000 cycles after it is pushed, so with a two-frame lead a whole frame
always separates the Shift latch from the key's latch. One jiffy scan cannot
straddle both. A visitor typing `:` on a physical keyboard got the same
`[`, and is fixed by the same change. **The frame is the machine's own, so the
millisecond value differs.** `vicectl` counts the lead in frames and converts
the knob by rounding up at the rate it reads at start-up: 50 on every VICE
machine here, the PET 2001 included, whose real frame is 60 Hz (its 60 ms HOLD
is three frames, not four). On the 50 Hz machines two frames are 40 ms. On the
2001 they are 33 ms, and 33 is two frames under either rate, where 40 would
become three at 60. `-model 8032` is not a 60 Hz machine: it boots the 50 Hz
editor ROM (`edit-4-80-b-50Hz`), measured at 20 032 cycles a frame.

The C64 was the worst of the family. On c64basic (a rig of the station's own
x64sc and golden) a 10-line stress listing with 44 such characters a pass lost
about one in 20 at 60/60 (12 bad lines of 60), and still 10 of 30 at
100/100, while the same keysyms sent without a Shift edge lost none: slowing
the pacing does not help, because the tear is not a pacing fault. Through the
real editor on the live station it hit once in four listing runs, a `+` in
Quick Draw's line 40 arriving as the shifted-`+` graphics glyph
([`guests/c64basic.md`](guests/c64basic.md#keyboard)).

VICE's own 8-slot `kbd_queue`, which drops silently when full, cannot overflow
from this module. Under `VICE_CTL_KEY_EXCL=1`, which every VICE station runs,
a frame's drain applies at most one press, one release and one edge per
modifier key, and the queue empties within about a frame.

**Proof through the real daemon.** `scripts/e2e/key-burst-proof.mjs --char-ms`
types with the editor's own edges and cadence over a WebTransport session into
a sandbox daemon in front of a rig. On the old binaries this reproduces the
loss: sinclairql 0 of 12 lines, vic20 and cbm8032 11 of 12, and oricatmos one
line in two runs. On the new ones, sinclairql, vic20, cbm8032 and oricatmos
were all byte-exact. vic20's three examples were typed exactly as the editor
types them, `NEW` first, ten times each through the daemon at 40 ms: 30 of 30
byte-exact, with `dropped=0 overflow=0` throughout.

**Live since 2026-10-04 on sinclairql and every VICE station.** sinclairql and
vic20 went first as the canary; pet2001, cbm8032, c128, plus4, cbm2, c64 and
c64basic followed the same day, one station at a time. Every golden restores
unchanged under the new binary: the frames are pixel-identical to the old
binary's (pet2001 and plus4 cold-boot, and their power-on frames are identical
too), and the QL's savestate signature is the same. On each live station
`typein-editor-probe.mjs` then typed an example through the real editor, RUN
ran it, LIST was exact, and Restore to golden brought the scene back. On the
GEOS `c64`, which has no editor, the real SPA keyboard sent C= W and C= M, and
the rename field echoed `Ab:C*1+2@x` exactly; the rename was never committed.
The old binaries are kept beside the new ones as `ql.pre-shiftlead-20261004`
and `vice-native.pre-shiftlead-20261004`, and each station's previous env and
launcher as `station.env.pre-shiftlead-20261004` and
`x11-runtime.sh.pre-shiftlead-20261004`. Evidence is in
`/data/vms/streamhost/stations/<id>/evidence/shift-lead-2026-10-04/`.

**Which other stations are exposed.** Every MAME keyboard station applied
Shift and the key in one drain pass before this, by construction. How much that
costs depends on how the machine scans its keyboard. Each station was measured
on a rig of its live binary, typing a 16-line listing with 176 shifted
characters through its own editor rules (`survey` frames in the evidence):

| Station | Shifted characters lost on the old binary (lead 0) |
|---|---|
| sinclairql | all of them (fixed, 20 ms) |
| oricatmos | 6 in 5 passes, e.g. `(` -> `9`, `$` -> `4`, `*` -> `8`; 0 in 6 with the new binary at 20 ms, not deployed |
| apple2e | `PRINT 6502*2` arrived as `650282` (seen by the Acorn examples agent, not measured here) |
| bbcmicro, dragon32, samcoupe, svi728, mpf2 | 0 in one pass |
| msx2 | 0 in lines 2 to 16 of three passes (line 1: see below) |
| zxspectrum, zx81 | 0 in 60 and 40 Symbol Shift / SHIFT chords |
| amstradcpc | on the Caprice32 kiosk (daemon dbus pacer), 1 in about 4,500 (`"` as `2`), plus far more keys of every kind under host load (below). Host-native MAME since 2026-10-04: 0 at lead 0, 1, 2, 5 and 10 in one pass each; ships 20 ms |
| freedos (daemon dbus pacer, PC BIOS) | 0 in three 95-character bursts sent with no pacing at all |
| vax43bsd's xterm (daemon x11test sink) | 0 in three 307-character bursts at 40/40 |

msx2 loses keys at the start of its first line in every run, old binary or new
(`10 PRINT` arrives as `10 NT`). That is not Shift: the lead does not change
it. Every VICE station has the fix (above).

**The daemon's own pacers.** The QEMU/dbus key gate (`key_quirks.rs`,
`pace_edge`) forwarded Shift and the key back to back as well, and amstradcpc
once typed `)` as `9` there (`IF INKEY(71)` arrived as `IF INKEY(719`). Since
2026-10-04 that gate reads the same `SH_KEY_MOD_LEAD_MS`: a non-modifier press
waits until the last Shift, Ctrl or Alt edge it sent to QEMU (press or
release, either side) has been out that long. Modifier presses and all
releases never wait it, the order of edges and the one FIFO gate are
unchanged, and unset or 0 is the old gate, number for number. The x11test sink
does not read it. The binary with this gate and the x11test key FIFO
(`streamhost-98f78ebf`) went fleet-wide on 2026-10-04: 116 of 121 stations,
with armeval, bbcmicro, c64basic, cbm2 and vic20 held back by claims or a
visitor. Each shape was measured through a sandbox daemon of the new
binary in front of a rig (`key-burst-proof.mjs`, the result read back from the
framebuffer or as bytes). Two of the three shapes cannot tear at all:

- **PC guests** (freedos) decode scancodes in order in the BIOS and keep their
  own Shift state. There is no matrix to scan, so there is nothing to tear.
- **x11test** feeds an X client (vax43bsd's xterm), which takes the modifier
  state from each KeyPress event.
- **amstradcpc** could, while it was a kiosk. It has a matrix, scanned by the
  CPC's firmware 50 times a second, and it ran behind Caprice32 in a Debian
  kiosk guest. Caprice32 puts a shifted key's Shift and the key into the
  matrix in one update, and a scan that straddles that update reads the key
  unshifted: once in about 4,500 shifted keys at lead 0 (`"` as `2`), so the
  kiosk got a 20 ms lead by construction. Far more often, it lost keys of
  every kind when labhost was loaded: when the kiosk guest stalled, one key's
  press and release (or a repeated key's release and re-press) reached
  Caprice32 in the same frame. At 40/40 every one of 12 passes lost 1 to 11
  keys at a 1-minute load of 25 to 60 (`$$` as `$`, `110` as `10`); 80/80 with
  the lead was exact in 5 of 6 at load 35 to 54 on a clone, nothing survived
  load 70, and through the real editor on the live station it still dropped 4
  to 9 keys a run. A stall compresses host-side timing of every kind, the lead
  included, so no daemon pacing could fix it. **The station has been
  host-native MAME since 2026-10-04**: the ctlsock module paces in emulated
  time, 40/40 with a 20 ms lead, and the editor types at 120 ms per character.
  Its 15-line stress listing and all three examples LIST byte-exact, and the
  hold/gap floor is one 50 Hz scan (10/10 loses nearly everything, 20/20 is
  exact). Measurements in [`guests/amstradcpc.md`](guests/amstradcpc.md).

Evidence: `/data/vms/streamhost/stations/{amstradcpc,freedos,vax43bsd}/evidence/daemon-mod-lead-2026-10-04/`.

**A visitor's own keys reach the guest during a run.** The editor does not
take the keyboard away while it types. On 2026-10-04 the operator's run of
vic20's Colour Squares came out with `GOSUB 100` as `GOS` plus six graphics
glyphs. The SPA's key recorder (`serve/key-trace.py`, session `9061260b`) shows
why: a physical Shift (`0x2a`) and Left-GUI (`0xe05b`) went down mid-run,
148 ms after the `s`, off the typist's 171 ms cadence. That is Cmd+Shift, the
macOS screenshot shortcut. The guest then typed `u b space 1 0 0` shifted,
until the typist's next `:` released Shift. Replaying exactly those recorded
edges into a rig reproduces line 50. The modules are not at fault: a held
Shift is a Shift. Keeping the visitor's keys out of a run is an editor change.

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

**The MPF-II loses keys while it scrolls, so the typist pauses at the wrap.**
Its text is painted into the hires bitmap and scrolled in software, and the
keyboard is not scanned meanwhile. A typed line that wraps at the
bottom row (40 columns, the `>` prompt owning column 0) scrolls the display, and
keys that arrive meanwhile are lost: `CANNOT` arrived as `CAOT`, a `:` after a
closing quote vanished (examples-msbasic rig). `typeIn.wrapPause` is the fix:
`{ "cols": 40, "ms": 500, "promptCols": 1 }`.

Measured 2026-10-04 on a sandbox clone (MAME 0.289 binary of 2026-08-16, hold/gap
32/32, `perCharMs` 70), through the real path: `key-burst-proof.mjs --char-ms 70
--wrap-cols 40 --wrap-ms N --wrap-prompt 1`, a daemon in front of the rig. The
listing is 20 short lines (to put the cursor on the bottom row) and seven REM
lines of 62 to 100 characters, so every wrap scrolls. The final screen was
compared pixel for pixel against a reference typed with a 2 s pause.

| pause after a wrap | runs byte-exact |
|---|---|
| none | 0 of 3 (characters lost at each wrap) |
| 100 / 120 ms | 0 of 1 / 0 of 2 |
| 140 ms | 3 of 5 |
| 160 ms | 5 of 5 |
| 200 ms | 5 of 5 |
| 250 ms | 5 of 5 in the sandbox; 1 of 2 through the live editor (a lost `PA` at the last wrap) |
| 500 ms (shipped) | 3 of 3 through the live editor on /os/mpf2 (`LIST 100,160` frame-identical, all seven long lines intact); sandbox 1 of 1 |

Pausing after the 40th typed character, not the 39th, loses a letter at each
wrap: the prompt is column 0, so the wrap comes after 39 typed characters.
That is why `promptCols` exists. The smallest pause that was byte-exact in 5 of 5 is 160 ms. The shipped 500 ms
is margin for the real path: through the browser the key writes arrive with
jitter that eats part of the pause, and 250 ms lost two characters in one live
run. It costs 500 ms per screen row of a long line (about 17% on top of the
2.8 s a row already takes). Evidence:
`/data/vms/streamhost/stations/mpf2/evidence/wrap-pause-2026-10-04/`.
Keys pressed while a program is PRINTING are also lost, about 2 in 20; the
editor does not type then, so it is not covered. The MPF-II examples still
keep every line within 38 characters.

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

### Apple //e: the B key, and the Shift key it never had

**The way in.** The station boots ProDOS into its own Applesoft `STARTUP` menu
(`[1]` AppleWorks, `[2]` Dazzle Draw, `[B]` BASIC prompt). One keypress, B,
reaches Applesoft's `]` prompt; that is the `hint`. B leaves `STARTUP` in
memory (`LIST` shows it), which is exactly what the editor's `NEW` is for.

**Case.** `unshifted`: the //e boots with CAPS LOCK down, so letters arrive
upper case whichever way they are sent, and lower case inside a string is out
of reach, as on the Oric and the BBC.

**Shift was never mapped.** Until 2026-10-04 `apple2e.keymap` had no Shift,
Control or Apple-key rows: it was generated from the `:X0`..`:X8` matrix ports
only, and the //e keeps its modifiers on `:keyb_special`. Every Shift edge was
`unmapped` in the daemon, so every shifted character arrived unshifted
(`PRINT 6502*2` as `PRINT 650282`). That, not timing, was the loss reported
earlier. With the keymap regenerated over every port, the old binary typed the
stress listing exactly; the //e's own encoder reads Shift when it latches a
key. It gets the 10 ms lead with the rest of the fleet.

**Examples (`registry/examples/apple2e/`).** *Hi-res starburst* draws 126
coloured lines from the centre of the hi-res screen; *Prime checker* answers
whether a number is prime or names its smallest factor; *Guess my letter* is a
GET loop that says earlier or later in the alphabet. The manuals are Apple's
IIe Owner's Manual and the Applesoft BASIC Programmer's Reference Manual for
the //e.

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
validator holds `perCharMs` and `enterDelayMs` to at least one chord's drain on
a keyword-entry station, because ENTER is a chord too (`settleAfter` only ever
lengthens a settle).

**Modifier timing.** No chord lost its SYMBOL SHIFT, CAPS SHIFT, SHIFT or E-mode
prefix on either machine in about 1,100 chords typed on rigs on 2026-10-04,
several hundred of them shifted. Both ROMs read the whole matrix in one pass
per frame, so a shift that lands in the same scan as its key is read with it.
This is unlike the QL's 8049 (above), and agrees with the modifier-lead survey
(0 losses in 60 and 40 chords), so neither station declares a lead.

**Pace, measured on rigs of the stations' own binaries** (2026-10-04):

| Station | Value | Why |
|---|---|---|
| zxspectrum | `perCharMs` 400 | One chord at the station's 200/200 hold/gap. The ROM's interrupt latches a key it is too busy to read at once, so one chord's budget is enough: all three examples, about 400 chords, typed exactly |
| zxspectrum | `settleAfter` `{"NEW": 3000}` | `NEW` (which the editor types first) makes the 48K ROM clear and re-test its memory with interrupts off. Keys sent 0.6, 1.2 and 1.8 s after its ENTER were lost; 2.4 s landed |
| zx81 | `perCharMs` 400 | Hold + gap is only 100/100, but the 1 KB ZX81 rebuilds its edit line after every key, and in SLOW mode that takes longer as the line grows: 100–150 ms early in a line, 200–360 ms at the end of a 36-character one. At a 200 ms pitch the `(` after the second `SIN` in `20 PLOT 20+12*SIN (T/4),22+10*SIN (T/2)` was lost |
| zx81 | `enterDelayMs` 1000, `enterDelayPerLineMs` 100 | After ENTER it re-lists the program into its collapsed display, about 90 ms more per listed line (170 ms after `NEW`, 1.5 s after the 14th line of a test listing). A key that arrives during the redraw is lost: at a flat 600 ms, line `40`'s number went missing and the rest ran as a direct command (`2/0`) |

These are wall-clock waits, and the key module paces in emulated time. On a
host at load ~100 (16 cores), a rig's MAME ran at ~30 % speed: key edges still
arrived intact, but every settle shrank in emulated time and lines were lost.
The values above leave margin for an ordinary load, not for that.

**Examples** (`registry/examples/zxspectrum/`, `zx81/`), each run preceded by
the `NEW` the editor types, were typed on rigs through the transcoder's own
chord stream (`transcodeLine` + `paceFor`, played
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

**Then live, through the real editor** (2026-10-04,
`scripts/e2e/typein-editor-probe.mjs` signed in at the public origin; its
`--then` steps pressed the visitor's next keys through the real SPA keyboard).
All six examples went in byte-exact at the registry pace, NEW first, and each
frame above was seen again on the live station: the colour web, `10 x 7 = 70`,
the bat following P and O, the figure of eight, `7 CUBED IS 343`, and `TIME 447`
after the shown letter was pressed. Each run ended with Restore to golden, and
both stations were back at their power-on screens afterwards. The Spectrum's
ASCII demo listing, typed from the stage menu, listed exactly and, after ENTER,
cycled the border. A listing written to fail (`10 a=1`, a backtick, `LET
b=PRINT`, a letter after `:` in a REM) was listed with all four problems in red,
the Type button stayed off, and the framebuffer before and after was identical.
Frames: `/data/vms/streamhost/stations/{zxspectrum,zx81}/evidence/keyword-transcoder-2026-10-04/`
(`typein-*` live, `untypable-*`, `demo-*`, and the rig frames).

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
