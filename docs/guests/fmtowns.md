# fmtowns — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Status: **native, keyboard, golden restore, pointer (1:1 absolute, plus
click/drag) and `/os/fmtowns` publish all proven on the framebuffer**
(2026-09-13); the station is landed and listed. Command Mode / MS-DOS prompt
and the other TOWNSSYSTEM icons are still not opened (no keyboard-only launch
path found for them). See [`docs/lab/FMTOWNS-WAVE.md`](../lab/FMTOWNS-WAVE.md)
for the ledger, the race and every proof frame. This file is the station's
operating manual; every number in it is measured or marked OPEN.

## Identity and source

- Public ID / station dir: `fmtowns`; slot / UDP / VMID `196` / `54196` / `196`;
  x11warp display `:96` (allocated, inert while `SH_CAPTURE=shm`).
- Guest: Towns System Software V2.1 L51 (Fujitsu, 1995) — Towns OS, whose
  desktop is TownsMENU over an MS-DOS kernel. It boots **from the CD**; no
  hard disk is installed (the richer MS-DOS 6.2 + Towns OS on a 512 MB disk
  is a later golden, OPEN).
- Media: five Fujitsu system ROMs (MAME 0.272 merged `fmtowns.7z`) and the
  System Software CD (CloneCD image from the Neo Kobe FM Towns set) — URL,
  size and sha256 pinned in `scripts/build-guests/tiles/fmtowns.sh`; bits under
  `/data/assets-staging/fmtowns/` and `/data/vms/streamhost/assets/fmtowns/`,
  never committed.
- Retronet: none — Towns OS V2.1 ships no TCP/IP stack, so the station was
  allocated without `--retronet` on purpose.

## Emulator and device set

- Host-native MAME (fleet pin 0.289) via
  `scripts/build-guests/emulators/native.d/fmtowns.sh` and the shared
  `streamhost/stations/mame-native/x11-runtime.sh` launcher: drawshm frames,
  ctlsock keys through `streamhost/stations/fmtowns/fmtowns.keymap`, FIFO
  audio. Machine and exact device set: see the wave doc's race table (the
  machine is the one whose romset the staged ROMs boot the CD on).
- `-pad1 townspad -pad2 mouse` (driver defaults, set explicitly), `-cdrom
  <townsos-v21l51.chd>` composed by `tiles/fmtowns.sh` with `chdman createcd`.
- Every fmtowns-family machine is `MACHINE_NOT_WORKING`; the binary carries
  `mame-irix-skip-warnings.patch` and the fixture sets
  `MAME_NATIVE_SKIP_WARNINGS=1`, otherwise the warning panel pauses the
  headless kiosk forever (atari800xl/domainos finding).

## Golden, input, reset

- Reset = relaunch restoring the golden save state (`MAME_NATIVE_CHECKPOINT=1`).
  Measured: `SAVEST` at the settled TownsMENU desktop took 334 ms and wrote
  797 714 bytes to `sta/fmtownsftv/golden.sta`; a FRESH process relaunched with
  `-state golden` against the real station dir settled in 5.2 s (CD mount
  included) to a frame pixel-identical to the capture except a 1×9 px sliver
  at the on-screen clock glyph (the guest reads real wall-clock time). Proof
  frames: `docs/lab/FMTOWNS-WAVE.md` §Proofs.
- Keyboard: real ctlsock `KEY` path through the generated
  `fmtowns.keymap` (79 of 146 dumped fields matched; `mame-keymap.py` against
  the live rig). Proven: `Ctrl`+`Esc` opens the guest's own タスクリスト (Task
  List) dialog, and pressed again a different one (サイドワークリスト), so each
  keypress is read live. Typed text, exclusive scan and the modifier lead:
  see "Keyboard (2026-10-04)" below.
- Pointer: see §Pointer below — 1:1 absolute, write route, landed 2026-09-13.
- Credentials: none (`guest/fmtowns` is a placeholder reference).
- Rollback: `/os/fmtowns` is dark-launched and then landed via
  `scripts/dev/darklaunch-station.py` (`smoke-rig.sh` does not fit a
  MAME-native/shm-capture rig — see the wave doc's §Publish for why); the
  station is `listing.state`-free (listed) since 2026-09-13.

## Keyboard (2026-10-04)

The first full line typed on this station: double-click コマンドモード
(published 555,555), and at the `Q>` prompt type `PRINT "A+B*C:D(E)$!";1+2*3`
through the station's `charMap`, at 150 ms a character with Shift and its key
back to back (`typeText()`'s shape; a visitor's normal speed). Measured on a rig
of this station's binary and golden through a sandbox daemon. This machine is
CPU-bound: the live station runs at **0.233 of real time** (99 % of a core),
rigs at 0.40 to 0.46, so a run counted at 0.95 of the live speed or better.

| Binary, setting | Result |
|---|---|
| live binary, as shipped until now | most of the line lost: `R c:!` |
| live binary, `MAME_CTL_KEY_EXCL=:key` | the overlap losses gone; shifted characters still lost |
| new binary, EXCL + lead 2 or 5 ms | shifted characters lost (2 runs each) |
| new binary, EXCL + lead 10 or 20 ms | exact (2 runs each) |

Two faults. The fixture's exclusive-scan tag was `:kbd_`, samcoupe's, copied
with a sibling fixture; this machine's key ports are `:key1` to `:key4`, so it
matched nothing and overlapping keys were lost. And Shift reached the keyboard
in the same instant as its key. The station ships `:key` and a 20 ms lead (the
threshold is 5 to 10 ms, as on the Macintosh's serial keyboard). The slow
reference also showed the `charMap` was wrong here: `"` arrived as `[`, `+` as
`^`, `*` as `‾`. It was samcoupe's map, entry for entry; it is re-derived below.

### The JIS map, re-derived (2026-10-05)

Measured with every US key bare and shifted typed at its US position at `Q>`
(コマンドモード) on a rig of this station's binary and golden, through a sandbox
daemon, and read off the frame:

| US key | bare | Shift | | US key | bare | Shift |
|---|---|---|---|---|---|---|
| `1`..`0` | digits | `! " # $ % & ´ ( )`, Shift+0 none | | `\` | `¥` (code 92) | `\|` |
| `-` | `-` | `=` | | `;` | `;` | `+` |
| `=` | `^` | `‾` (code 126) | | `'` | `:` | `*` |
| `[` | `@` | `` ` `` | | `` ` `` | ESC | ESC |
| `]` | `[` | `{` | | `,` `.` `/` | `,` `.` `/` | `< > ?` |

That is the Towns's JIS keyboard, and `keyboard.charMap` is now that table
(`"` is Shift+2, `@` the US `[` key, `+` Shift+`;`, and so on: 17 entries). Two
keys had no host key at all: MAME gives the Towns's ESC the token
`KEYCODE_TILDE` and its `] }` key `KEYCODE_BACKSLASH`, which `¥ |` had already
taken, so the keymap generator bound the PC's `` ` `` key to a second ESC and left
`] }` unreachable. `fmtowns.keymap` now binds 0x29 to `] }` (ESC stays on Esc),
and the map sends `]` and `}` there. `_` stays unreachable: the Towns's `_ ろ` key
has no MAME token, and every US key is in use; a visitor's `_` gives `=`.

`keyboard.physical` is on: the visitor's own keys and the on-screen keyboard go
through the map. Typed through the SPA's real key path (Shift held), every
printable ASCII character arrived as its own code but `_`; the Towns's font
draws 92 as `¥`, 126 as `‾` and 39 as `´`. Case is the visitor's (`abc XYZ`).
The Towns's CAP key is its own, so a visitor's Caps Lock inverts letter case
(`Hello World` arrived as `hELLO wORLD`, docs/TYPE-IN-EDITOR.md). At `Q>` the
shell reads `|` as a pipe. Evidence:
`/data/vms/streamhost/stations/fmtowns/evidence/physical-charmap-2026-10-05/`.

**Live since 2026-10-04** (final-patch binary, `:key`, 20 ms; savestate
signature `1ebe131a` unchanged, golden pixel-identical but for the guest's
wall clock). Through the real SPA: a double-click on コマンドモード, then
bare characters, so the SPA adds a synthetic Shift. `PRINT (A$! 1984 %OK` arrived
as `PRINT )A$! 1984 %OK`: every Shift landed, and `(` `)` fall on the JIS
layout (Shift+8 and Shift+9 there), the layout gap above. Restore to golden
brought back the desktop. Evidence:
`/data/vms/streamhost/stations/fmtowns/evidence/shift-lead-2026-10-04/`.
Rollback: `assets/fmtowns/mame-native/fmtowns.pre-shiftlead-20261004` and
`station.env.pre-shiftlead-20261004`.

## Pointer — 1:1 absolute (write route, guest's own cursor word)

`stream.pointer.transport` is `"abs"`, method `mame-guestram-abswrite`, since
2026-09-13. The underlying device is still the Towns mouse on `-pad2 mouse`,
an MSX-protocol mouse (`bus/msx/ctrl/mouse.cpp`) tagged
`:pad2:mouse:BUTTONS`/`MOUSE_X`/`MOUSE_Y` — genuinely RELATIVE at the ioport,
NOT the SGI Indy's `hle_ps2_mouse` the fleet ctlsock module hardcodes.
`mame-ctlsock-ptr-tags.patch` (with a type-based Mouse-X/Y binding fix layered
on top — pad2's fields are named `Mouse X 2`/`Mouse Y 2`, not the module's
hardcoded `Mouse X`/`Mouse Y`) binds the fields; ctlsock setup reads `btns=1
axes=1 movea=0 devxy=0 swap=0 sig=1ebe131a entries=3330` — `sig=`/`entries=`
unchanged from the pre-patch binary, so the golden `.sta` is not orphaned
(rule 6). `mame-ctlsock-btn-active-low.patch` is DELIBERATELY not applied and
`MAME_CTL_BTN_ACTIVE_LOW` must stay unset: MAME already applies the MSX
BUTTONS port's `IP_ACTIVE_LOW` itself, so setting the env inverts an
already-inverted polarity and turns every click into a no-op (measured with
`kh-fmtowns-padport-debug.patch`: `DOWN1` takes the guest-read byte from
`raw=f0` to `raw=e0`, bit 4 low = pressed, with the env UNSET).

**The open loop is dead here — no chunk size gives a constant gain.** Towns
OS's own mouse driver accelerates: px moved per count is a function of the
per-poll delta, not a constant (measured 4.36 px/count at a 20-count chunk,
6.11-6.12 at 50-count, 5.85 on Y at 40-count — see
`docs/lab/FMTOWNS-WAVE.md` §Pointer, "Pointer stream 2026-09-13 #4"). Any
`MAME_CTL_GAIN_X`/`MAME_CTL_GAIN_Y` fitted at one chunk size disagrees with
the next chunk size, so **these two knobs must NEVER be set on this
station** — the write route below bypasses the acceleration curve entirely.

**The cursor position is stated directly in Towns OS's own RAM, and it is
mirrored in THREE 16-bit little-endian words, 2 bytes apart, X-then-Y
(`order=hv`) — and the three are NOT interchangeable:**

| addr | holds | effect of poking it alone |
|---|---|---|
| `0x11623c` / `0x11623e` | **the authoritative position** | driver propagates it, repaints, OLD ARROW ERASED |
| `0x0a2034` / `0x0a2036` | a copy the driver rewrites every poll | poke is overwritten on the next poll — no effect |
| `0x116240` / `0x116242` | the **erase** rectangle the next poll restores before drawing | poke is overwritten AND the erase misfires |

Writing `0x11623c` **and** `0x116240` together looks right (both track) but
leaves the previous arrow on screen, because the poll sequence is "restore
the rect at `0x116240`, then draw at the new position" — clobbering the erase
address sends the erase to the new position instead of the old one. **The
shipped binding writes exactly one address: `pts=0x11623c`, nothing else.**

**Towns OS only redraws the cursor on a NON-ZERO poll delta.** A bare
`POKEW 0x11623c 400` / `POKEW 0x11623e 300` reads back 400,300 but repaints
**0** published pixels; the same poke followed by `MOVE 1 0` redraws the
arrow and leaves the word at exactly 401 — one poll's acceleration curve is
1.00 unit/count at n=1. So `mame-ctlsock-abs-ram-nudge.patch` writes the
position pre-biased by a 1-count nudge and then issues that single count, so
the driver's own increment lands on the commanded pixel and triggers the
repaint. Default `nudge=0` — macsys1 (the write route's origin station) is
byte-for-byte unchanged by this patch.

**The raster is letterboxed, non-integer scale.** The 640x480 Towns raster
draws into published `931x702+61+48` (931/640 = 1.4547, 702/480 = 1.4625 —
the non-integer scale is why the arrow sprite breaks into 1-2 px connected
components on the published surface and neither a blob picker nor a naive
exact template is a stable locator here).

```
MAME_CTL_ABS_RAM=cpu=maincpu,pts=0x11623c,order=hv,nudge=1
MAME_CTL_ABS_RECT=61,48,931,702
MAME_CTL_ABS_GEOM=640x480
```

**Proof** (rig `sandbox/fmtowns-ptr/rigE`, restored from the real golden
`.sta`, five targets x two laps, arrow re-parked at (512,140) between every
reading so each measurement is independent; guest word read back with
`PEEK 0x11623c`/`0x11623e`):

| target | lap 1 err | lap 2 err | guest word | expected |
|---|---|---|---|---|
| (80,70) | 0,3 | 0,3 | (13,15) | (13,15) |
| (960,70) | 0,0 | 0,0 | (618,15) | (618,15) |
| (80,720) | 0,0 | 0,0 | (13,459) | (13,459) |
| (960,720) | 0,0 | 0,0 | (618,459) | (618,459) |
| (512,384) | 0,0 | 0,0 | (310,229) | (310,229) |

The guest's own cursor word is EXACT on all ten (0 residual). The 3 px on
(80,70) is the LOCATOR, not the pointer — the arrow tip there sits on the
TownsMENU bar in the same colour, so the top rows of the sprite are absent
from the diff; identical both laps, which is what a locator artifact looks
like and what real pointer error does not. Changed-pixel count per target is
a flat 145-244 across both laps (erase + draw), with no accumulation.

Click/drag/window-activation were proven separately, on the pre-write-route
relative binding, and are unaffected by this change (same `BUTTONS` ioport,
same active-low fix): a plain click on a desktop icon draws NOTHING by
TownsMENU's own design (no hover/selection feedback); clicking inside an
inactive window's client area activates/raises it — proven 8/8 alternating
clicks between two windows (>31 000 changed px, `fb-react.py` masked diff,
100 ms hold already lands); drag proven too (a held button + `MOVE` steps
dragged a window 191x79 px). See `docs/lab/FMTOWNS-WAVE.md` §Pointer,
"Pointer stream 2026-09-13 #2" and "#5".

**Binary, golden and fixture move together** (AGENTS.md rule 6): the golden
is recaptured on the abs-ram(+nudge) binary. Rolling the pointer back means
putting all three back — see
`/data/vms/streamhost/stations/fmtowns/ROLLBACK.md`.
