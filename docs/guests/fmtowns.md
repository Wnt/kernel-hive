# fmtowns — Fujitsu FM TOWNS, Towns OS V2.1 L51 (TownsMENU)

Status: **fmtowns wave in flight** (2026-09-13) — see
[`docs/lab/FMTOWNS-WAVE.md`](../lab/FMTOWNS-WAVE.md) for the ledger, the race
and what is proven. This file is the station's operating manual; every number
in it is measured or marked OPEN.

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

- Reset = relaunch restoring the golden save state (`MAME_NATIVE_CHECKPOINT=1`;
  the driver registers 109 `save_item`s). Restore proof: OPEN until the wave
  doc's §Proofs names the frames.
- Keyboard: ctlsock `KEY` path, fleet floor 80/80 ms + `MAME_CTL_KEY_EXCL=:kbd_`
  copied from samcoupe; proof OPEN.
- Pointer: the Towns mouse is an MSX-protocol mouse on the second pad port;
  transport OPEN (relative device — see the wave doc §Still open).
- Credentials: none (`guest/fmtowns` is a placeholder reference).
- Rollback: the station is new; `listing.state: hidden` until the proofs land.
