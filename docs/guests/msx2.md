# msx2 guest

Status: **LIVE** (record wave 2026-09-20, issue #60), host-native MAME station.

## Identity and source

- Public ID / tile directory: `msx2`
- Reserved slot / UDP port: `211` / `54211`
- Archetype: `beige-tower-crt` (temporary — a home-computer assembly can
  replace it later, per the integration seed)
- Machine: **Philips NMS 8250** (MSX2, Europe, 1987), MAME driver `nms8250`
  in `src/mame/msx/msx2.cpp`
- Emulator: MAME 0.289 (fleet pin), built host-native by
  `scripts/build-guests/emulators/build-mame-native.sh msx2`
  (stanza `scripts/build-guests/emulators/native.d/msx2.sh`)
- Chosen over openMSX (the integration seed's original proposal) per
  AGENTS.md rule 13: MAME already ships the seed's exact target machine
  (`nms8250`) and needs no source build/kiosk PoC — see
  `docs/lab/MSX2-WAVE.md` for the decision record.

## Media

| Asset | Source | Size | SHA-256 |
|---|---|---|---|
| `nms8250.zip` (BIOS/mainrom/subrom/diskrom, 4 members) | `archive.org/download/mame-0.264-roms-non-merged/…/nms8250.zip` | 63 457 B | `42905515ecc08f11f5927697c091465207816f8849dc6fe104d277ba2dd77a42` |
| `MSX-DOS 2 (English).zip` → `MSX-DOS 2 (English).dsk` | `download.file-hunter.com/System Disks/Cartridges/ASCII/MSX-DOS2/` (the integration seed's own suggested mirror) | zip 63 118 B / disk 368 640 B | zip `561a6be5e433b516bdcbe96178b21801cb2fe22b8fa9ba53bef6e31386d5fa9b`; disk `e00558f0fc420db00b5f7f72f6d38b3f53fd462da3e6169cd63120f43e4d5733` |

Disk size (368 640 B) matches MAME's own `msx2_flop` software-list entry for
`msxdos2e`/`msxdos2j` (`mdos22de.dsk`, crc32 `9be0bfd1`) — the same bits, a
different distribution channel. Staged and installed at
`/data/vms/streamhost/assets/msx2/{mame-native/roms,media}/` on labhost.

The MAME binary itself: 87 354 072 bytes, sha256
`1db15ebe2e49d4034ca897caa6bfc00fe9e96e234e9716647a77a77c5a13877d`, staged at
`/data/vms/streamhost/assets/msx2/mame-native/msx2`.

## Build and device set

- Builder: `scripts/build-guests/tiles/msx2.sh` (media staging only — the
  disk image needs no composing, unlike samcoupe's `hive.mgt`)
- Native build stanza: `scripts/build-guests/emulators/native.d/msx2.sh`
- Device set (confirmed via `-listslots`/`-listmedia nms8250` on the 0.289
  build): ONE internal floppy drive (`-flop1`, WD2793 FDC, 3.5" DSDD), two
  EMPTY cartridge slots (disk-based exhibit, no cartridge ROM), no
  mouseport anywhere in the tree — keyboard-only exhibit
  (`stream.pointer.transport: none`).
- Ready framebuffer: PROVEN. Cold boot with the MSX-DOS 2 (English) disk in
  `-flop1` reaches "MSX BASIC version 2.1 / Copyright 1986 by Microsoft /
  Disk BASIC version 1.0 / Ok" on a solid blue SCREEN 0 field — the shipped
  rest scene.

## Golden, input, and rollback

- Reset mode: `relaunch` (checkpoint/`MAME_NATIVE_CHECKPOINT=0` — the
  `msx/msx2.cpp` driver's `MACHINE_SUPPORTS_SAVE` status is unconfirmed on
  this build; cold boot every reset, OPEN for a future stream to measure).
- Fixture (rest scene): MSX-BASIC's `Ok` prompt with the MSX-DOS 2 boot disk
  present but NOT auto-booted. Real MSX hardware auto-boots a bootable
  floppy on power-on; this build's `nms8250` diskrom does not, and the
  cause was not chased further (see "MSX-DOS 2 — out of scope" below).
- Pointer/click/drag/wheel: N/A — keyboard-only exhibit.
- **Keyboard proof: PROVEN on the production path**, 2026-09-20 (landing
  stream, dark-launch rig, real browser). Config: `SH_INPUT_BACKEND=mamesock`,
  `SH_MAMESOCK_KEYMAP=msx2.keymap` (`scripts/dev/mame-keymap.py`, 88/102
  fields matched from KEYDUMP), `SH_KEY_MIN_HOLD_MS`/`GAP_MS=40/40` (fleet
  floor), `MAME_CTL_KEY_EXCL=:KEY` — the MSX2 8255 PPI keyboard matrix IS
  host-CPU-scanned, like the SAM Coupé's (the samcoupe lesson, AGENTS.md),
  so this was set from the start rather than bisected after a drop. A real
  Chromium tab (`playwright`, headless) opened `/os/msx2`, typed
  `PRINT 1+1` character-by-character, pressed Enter: the line landed
  byte-perfect, executed, printed `2`, and returned a fresh `Ok` prompt.
  Daemon counters over the run: `mamesock accepted=35 dropped=0 overflow=0
  unmapped=0`. MAME's own natural-keyboard ctlsock verbs (`POST`/`CODE`)
  were proven earlier in the smoke stream but are **not** the production
  input path — this measurement supersedes that one.
- **MSX-DOS 2 — out of scope (operator decision).** The station ships as
  MSX-BASIC 2.1 with the MSX-DOS 2 disk present but not reachable: the
  machine's built-in disk ROM speaks MSX-DOS 1 (the "Disk BASIC version
  1.0" line in the banner is that ROM identifying itself), and a real
  MSX-DOS 2 command line needs its own cartridge ROM (MAME's own
  `msxdos2e` software-list entry implies a cartridge+disk pair) that this
  wave never staged. Chasing that ROM was explicitly ruled out of scope for
  this run; a future stream can add the cartridge and re-arm the DOS2 path
  without touching anything else here.
- Credentials reference only (never values): `guest/msx2`
- Rollback plan: `scripts/dev/station-land.sh` records the pre-land box
  state; reverting the registry row (`registry/stations/msx2.json`), the
  poster (`registry/posters/msx2.md`), `streamhost/stations/msx2/*` and
  `scripts/build-guests/emulators/native.d/msx2.sh` and dropping `msx2`
  from `stations-manifest.sh`/the SPA lineup removes the station; no golden
  to retire (`resetMode=relaunch`, no checkpoint baked).
