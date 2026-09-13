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
  the live rig). Proven: `Ctrl`+`Esc` (`:key3 Ctrl` + `:key1 ESC`) opens the
  guest's own タスクリスト (Task List) dialog; pressed again from there it opens
  a DIFFERENT dialog (サイドワークリスト), proving each keypress is read live,
  not a cached/looping frame. Fleet floor pacing (80/80 ms hold/gap) inherited
  from the samcoupe fixture; no dropped/duplicated characters observed in this
  station's limited test (no full sentence typed yet — the desktop has no
  reachable text field without a working pointer).
- Pointer: see §Pointer below — 1:1 absolute, write route, landed 2026-09-13.
- Credentials: none (`guest/fmtowns` is a placeholder reference).
- Rollback: `/os/fmtowns` is dark-launched and then landed via
  `scripts/dev/darklaunch-station.py` (`smoke-rig.sh` does not fit a
  MAME-native/shm-capture rig — see the wave doc's §Publish for why); the
  station is `listing.state`-free (listed) since 2026-09-13.

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
