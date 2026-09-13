# fmtowns — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Status: **native, keyboard, and golden restore proven on the framebuffer**
(2026-09-13); `/os/fmtowns` publish and the pointer are still open — see
[`docs/lab/FMTOWNS-WAVE.md`](../lab/FMTOWNS-WAVE.md) for the ledger, the race
and every proof frame. This file is the station's operating manual; every
number in it is measured or marked OPEN.

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
- Pointer: the Towns mouse is `-pad2 mouse`, an MSX-protocol mouse — genuinely
  RELATIVE (KEYDUMP shows `:pad2:mouse:MOUSE_X`/`MOUSE_Y` axis fields, no
  absolute port). The generic ctlsock `MOVEA`/`CLICK1` open-loop path produced
  no observable cursor movement in ~10 minutes of testing. **OPEN** — same
  wall as domainos's pointer (§Still open in the wave doc has the exact next
  command). `stream.pointer.transport` stays `none`, a deliberate ship
  decision, not an oversight.
- Credentials: none (`guest/fmtowns` is a placeholder reference).
- Rollback: `/os/fmtowns` is not yet published (`smoke-rig.sh` is QMP-shaped
  and does not fit a MAME-native/shm-capture rig — wave doc §Still open item
  2 has the exact next step); `listing.state: hidden` until that lands.
