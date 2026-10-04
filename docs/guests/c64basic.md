# Commodore 64 at BASIC V2 (PAL) — gallery station notes (udp/54226)

**Guest:** none. **VICE 3.10.0 `x64sc`** runs on labhost itself, headless, and
emulates a **PAL Commodore 64 breadbin** (`-model c64`: 6569 VIC-II, 6581
SID) sitting at its power-on **BASIC V2 `READY.`** prompt. It is the museum's
second C64: [`c64`](c64.md) boots the GEOS deskTop and stays that way; this one
exists so the [type-in code editor](../TYPE-IN-EDITOR.md) has a C64 to type
into.

| | |
|---|---|
| Registry | `registry/stations/c64basic.json` — slot 226, udp 54226, VMID label 226, `SH_X11_DISPLAY :126` (bookkeeping; there is no X) |
| Station dir | `/data/vms/streamhost/stations/c64basic/` — `sta/golden.vsf`, `station.env`, `x11-runtime.sh`, `fb.shm`, `ctl.sock`, `audio.fifo` |
| Binary | `/data/vms/streamhost/assets/c64basic/vice-native/bin/x64sc`, sha256 `265d8c76…bf1c213c` |
| Launcher | the shared `streamhost/stations/vice-native/x11-runtime.sh` |
| Builder | `scripts/build-guests/tiles/c64basic.sh` (`stage`, `bake`, `all`) |
| Engine docs | [`lab/research/vice-daemon-plane.md`](../lab/research/vice-daemon-plane.md), [`lab/DEBRIDGE-HANDOVER.md`](../lab/DEBRIDGE-HANDOVER.md) |

## Media and license — none to stage

No disk, no cartridge, no ROM to fetch. VICE (GPLv2) carries the C64 KERNAL,
BASIC and character ROMs in its source tree, so the pin on the ROMs is the pin
on the fork commit. There is no `ASSETS-MANIFEST.md` row and no
`check-assets.sh` entry.

## One binary, two stations

`c64basic` runs **the c64 station's x64sc, byte for byte**: `tiles/c64basic.sh
stage` copies `bin/x64sc` (+ `petcat`) and the `common`, `DRIVES` and `C64`
data trees from `/data/vms/streamhost/assets/c64/vice-native/`, and refuses
unless the sha256 matches. That build is the fork
`github.com/Wnt/vice` `kernel-hive/integrated` @ `d518f3db` (the pin in
`build-vice-native.sh`), the same one vic20 and c128 run.

It is a **copy in this station's own asset dir**, never a shared path. The
shared launcher's `reap_previous` kills every process whose
`/proc/<pid>/exe` lives under the station's asset dir, and the daemon's
freezer matches `SH_IDLE_PAUSE_PROC_MATCH=assets/c64basic/vice-native`. With
one path for both stations, a reset of either would kill the other, and a
standby SIGSTOP could freeze the wrong emulator.

## Device set

`VICE_NATIVE_ARGS=-model c64 -VICIIdsize`, plus the launcher's own
`-sounddev fifo` and the restore block. That is the whole machine:

- **`-model c64`** — the 1982 breadbin. x64sc's default is the later C64C
  (8565 VIC-II), which the cold-boot log names (`MOS8565`, 63 cycles × 312
  lines); the exhibit is the original.
- **`-VICIIdsize`** — double size with normal borders: a **768×544** surface,
  measured off the mapping (1 671 232 B = 64 + 768·544·4), the same surface
  `c64` publishes.
- **No drive flags and no disk.** Drive 8 is VICE's default 1541 with nothing
  in it, so `LOAD"$",8` answers like a real empty drive.

The checkpoint belongs to this binary and these args together (AGENTS.md rule
6). Change either and rebake.

## Golden

- **Scene:** the untouched cold boot — `**** COMMODORE 64 BASIC V2 ****`,
  `64K RAM SYSTEM  38911 BASIC BYTES FREE`, `READY.`, cursor. Nothing typed.
- **Reset:** `SH_RESET_MODE=relaunch`. The launcher restarts x64sc and replays
  `undump sta/golden.vsf` through `-moncommands` + `-initbreak ready`, with
  `VICE_SHM_HOLD_RESTORE=1` so a reset is a cut, not a visible boot.
- **How it was captured:** `tiles/c64basic.sh bake`, on 2026-10-04. It starts
  the staged binary with the fixture's args in a namespaced rig
  (`/data/vms/sandbox/<session>/bake`, killed through `clone-guard`), waits
  on the framebuffer for READY (`fb-wait.py --change --settle 2`: 5.2 s), and
  takes `SAVEST` over vicectl. Then it restores the file in a **fresh**
  process the launcher's way and compares the two frames: 768×544 both, 280 px
  differ, which is the blinking cursor cell (256 px at double size). Only then
  is it renamed into `sta/golden.vsf`; an existing golden is replaced only with
  `--force` and kept as `golden.vsf.prev`.
- **Combination:** `golden.vsf` sha256 `1c4207e5…1e3d7113` (193 261 B) + x64sc
  `265d8c76…bf1c213c` + `-model c64 -VICIIdsize`.
- **checkpoint-guard does not cover this station.** It refuses every
  `SH_RESET_MODE=relaunch` runtime ([`checkpoint-guard.md`](../lab/checkpoint-guard.md)
  "Runtimes refused"), so the builder's bake is this station's guard: write
  under a temp name, prove the restore, rename.

## Keyboard

Host-native `vicectl`, the same path as every VICE station: browser key edges
→ `InputRouter` → `vice_sock.rs` → the module, paced at **60/60 with EXCL**
(`SH_KEY_MIN_HOLD_MS/_GAP_MS` → `VICE_CTL_KEY_HOLD/_GAP`). VICE resolves
keysyms through `C64/gtk3_sym.vkm` and the shared US keysym table, so there is
no per-station keymap.

**Measured, not inherited (2026-10-04).** A 10-line, 406-character stress
listing with 44 characters that are shifted on a US keyboard but unshifted on
a Commodore (25 `:`, 14 `*`, 4 `+`, one `@`) was typed as a rollover burst at
6 keys/s on rigs of this binary restored from this golden, and read back byte
for byte from a `SAVEST` snapshot tokenised with `petcat -w2`:

| Path | hold/gap | corrupted lines |
|---|---|---|
| Shift_L + the shifted keysym (what the daemon forwards) | 60/60 | 12 of 60 |
| Shift_L + the shifted keysym | 100/100 | 10 of 30 |
| the keysym alone, no Shift edge (control) | 60/60 | **0 of 30** |

Every corrupted line is VICE's **torn Shift latch**
([TYPE-IN-EDITOR.md](../TYPE-IN-EDITOR.md#shifted-characters-the-modifier-lead)):
a `*` lost or a `:` arriving as `[`, plus one `@` and one `+` at 100/100.
Nothing without a Shift edge was lost at 60/60, and slowing to 100/100 did not
lower the rate, so the pace is not the cause and the station keeps 60/60. The
C64 rate, about 1 such character in 20, is the highest in the VICE family
(vic20, c128 and cbm8032 tore about 1 in 50).

**Fixed 2026-10-04: Shift is staged, `SH_KEY_MOD_LEAD_MS=40`, two frames.**
The station runs an x64sc built at fork `a1cb4b5c8d`, whose `vicectl` puts the
Shift level a key needs in front of the key and holds the press for two frames
(PAL, 19 656 cycles a frame, so 40 ms), so a `:` typed with Shift held never
touches the emulated SHIFT. Measured through the real daemon at the editor's
pace (`NEW`, then the listing at `perCharMs` 170 with the 260/600 ms settles)
on rigs of the station's golden, read back from a `SAVEST` snapshot: the
14-line CBM stress listing tore 20 lines in 3 passes on the old binary
and none on the new one, and the three examples below came out 9 of 9
byte-exact. The golden restores pixel-identical under the new
binary. The `c64` (GEOS) station got the same binary as its own copy. Live
since 2026-10-04: the real editor typed Quick Draw on the live station, RUN
turned the screen red, LIST was exact (line 40's `+` included), and Restore to
golden brought READY back (`live-smoke-*.png`). Evidence:
`/data/vms/streamhost/stations/c64basic/evidence/shift-lead-2026-10-04/`.

- **`keyboard.letterCase: upper-only`** and **`typeIn.case: unshifted`**: a
  shifted letter in the power-on character set is a PETSCII graphics glyph.
- **`typeIn.unreachable: "{}"`**: VICE's C64 keymap has no braces, and typed
  braces vanish (`evidence/rig-unreachable-braces.png`). `|`, `~`, `_`, `` ` `` and `\`
  do arrive, as the PETSCII glyphs on those codes (`\` is `£`).
- **`maxLineChars: 80`** — the C64 screen editor's logical line is two 40-column rows.
- **`perCharMs: 170`** for both the editor and the demo listing, ≥ 120 ms
  hold+gap.
- **On-screen keyboard:** the `c64` family (RUN/STOP = Esc, RESTORE = PageUp,
  C= = Tab).

## Examples and manuals

`registry/examples/c64basic/` — three original listings, each ≤ 15 lines and
≤ 500 characters. They were written to keep `:` and `*` few while the Shift
defect was open; with the lead they need not, but they stay as they are:

| File | Title | What it shows |
|---|---|---|
| `draw.bas` | Diamond Rings | 1 000 POKEs: solid blocks into screen memory at 1024, a colour by distance from the centre into colour RAM at 55296 (which keeps only the low nibble, so the value wraps through all sixteen colours). About 26 s at BASIC speed. |
| `input.bas` | Border Colours | `INPUT` a number 0–15, `POKE 53280` sets the border, the name comes from `DATA`. |
| `game.bas` | Quick Draw | Reaction test on the jiffy clock: the background turns red after a random 1–4 s, the time to a key is printed, an early key is a false start. |

Manuals (both fetched and checked on 2026-10-04): the *Commodore 64 User's
Guide* (176 pages) and the *Commodore 64 Programmer's Reference Guide* (first
edition, eleventh printing, 1984, 508 pages), both at zimmers.net.

## Verification (2026-10-04, live)

The type-in steps went through the **real editor** on the live station
(`scripts/e2e/typein-editor-probe.mjs`, signed in at the public origin). The
keys after a run went through the real SPA keyboard (a Playwright session on
`/os/c64basic`). Every frame is the station's own framebuffer (`labctl shot`).
They are in `/data/vms/streamhost/stations/c64basic/evidence/`:

| Frames | Shows |
|---|---|
| `golden-captured.png`, `golden-restored-fresh-process.png` | the bake: the captured READY, and the same scene restored in a fresh x64sc |
| `live-station-up.png`, `gallery-grid.png` | station-up's shot; the tile in the public grid beside the GEOS `c64` (clicking it streams 768×544) |
| `editor-open-draw.png` | ☰ → Code editor open: "Commodore BASIC · Commodore 64 BASIC", the examples menu, both manuals linked |
| `draw-typed.png`, `draw-run.png`, `draw-list.png` | Diamond Rings typed (the editor's `NEW` first), the finished rings, then a key and `LIST`: all 15 lines exact |
| `input-typed.png`, `input-run-2.png`, `input-run-7.png`, `input-list.png` | Border Colours: `2` gives a red border and "THE BORDER IS RED", `7` gives yellow; `-1` restores the light-blue border; `LIST` exact |
| `game-typed.png`, `game-list.png`, `game-run-red.png`, `game-run-result.png`, `game-run-falsestart.png` | Quick Draw: `LIST` exact, the screen turns red, a key gives "YOU TOOK 3.14 SECONDS", and after Y a key pressed at once gives "TOO SOON - FALSE START!" |
| `game-typed-defect-line40.png`, `game-run-syntax-error-line40.png` | the first Quick Draw attempt: the known shifted-punctuation defect turned the second `+` of line 40 into the shifted-`+` graphics glyph, and RUN stopped with `?SYNTAX ERROR IN 40`. Re-typed through the editor; clean on the second pass |
| `restore-before.png`, `restore-after.png` | a dirtied screen, then `POST /restore/c64basic` (what Restore to golden sends): HTTP 200 in 1.3 s, and the clean READY on the framebuffer 2.2 s later |

Editor pace, all in: 227, 210 and 208 ms/char for the three listings (269,
378 and 402 characters), at `perCharMs` 170 plus the 260/600 ms line and ENTER
settles. The daemon counted `dropped=0 overflow=0` and no ack timeouts across
the session (`accepted=3438` at the end).

The probe's own `--restore` shot came back showing the pre-reset screen. It
fires as soon as the stream reconnects, and the relaunch publishes the
restored frame about 2 s later (`VICE_SHM_HOLD_RESTORE` keeps the last frame
until then). A later shot showed the clean READY, so the timed restore above
is the evidence.

## Pointer

None. `--pointer none --input-backend vicesock`, `stream.pointer.present:
false`. At the BASIC prompt a C64 has no pointing device; the scene assembly
has no mouse either.

## Cold boot

Zero input is genuine: x64sc reaches READY in about two seconds with nothing
typed. There is no boot clip, so `spa.bootVideo` is unset, and
`scripts/coldboot/c64basic-bootrec-arm.sh` is still the scaffold's draft, as on
the other converted VICE stations.

## Rollback

The station touches nothing outside its own two directories. To withdraw it:
`systemctl stop streamhost@c64basic`, set `enabled: false` in the registry,
regenerate and republish the runtime manifests. To rebake:
`scripts/build-guests/tiles/c64basic.sh bake --force` under `labrun`; the old
golden is kept as `sta/golden.vsf.prev`.
