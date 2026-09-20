# msx2 guest

Status: **record wave 2026-09-20** (issue #60), host-native MAME station.

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
different distribution channel. Staged on labhost at
`/data/assets-staging/msx2/{roms,media}/`, not yet copied into
`/data/vms/streamhost/assets/msx2/`.

## Build and device set

- Builder: `scripts/build-guests/tiles/msx2.sh` (media staging only — the
  disk image needs no composing, unlike samcoupe's `hive.mgt`)
- Native build stanza: `scripts/build-guests/emulators/native.d/msx2.sh`
- Device set (confirmed via `-listslots`/`-listmedia nms8250` on the 0.289
  build): ONE internal floppy drive (`-flop1`, WD2793 FDC, 3.5" DSDD), two
  EMPTY cartridge slots (disk-based exhibit, no cartridge ROM), no
  mouseport anywhere in the tree — keyboard-only exhibit
  (`stream.pointer.transport: none`).
- Ready framebuffer: TODO — smoke-stream proof pending (build still
  compiling as of this commit; see MSX2-WAVE.md).

## Golden, input, and rollback

- Reset mode: `relaunch` (checkpoint/`MAME_NATIVE_CHECKPOINT` verdict OPEN —
  `MACHINE_SUPPORTS_SAVE` on `msx/msx2.cpp` not yet confirmed on this build)
- Fixture (rest scene): TODO — the integration seed proposes either the
  MSX-BASIC `Ok` prompt or the MSX-DOS 2 prompt; pick whichever the smoke
  stream proves is the natural post-boot resting state with the boot disk
  in `-flop1` (real hardware auto-boots a bootable floppy into MSX-DOS 2 on
  power-on, so the MSX-DOS 2 prompt may be the reachable default rather
  than a one-keypress-away option).
- Pointer/click/drag/wheel: N/A — keyboard-only exhibit
- Keyboard proof: OPEN — see `docs/guests/msx2.md` (this file) and
  `docs/lab/MSX2-WAVE.md`
- Credentials reference only (never values): `guest/msx2`
- Rollback plan: revert the four scaffolded/edited files
  (`registry/stations/msx2.json`, `registry/posters/msx2.md`,
  `streamhost/stations/msx2/*`, `scripts/build-guests/emulators/native.d/msx2.sh`)
  and drop `msx2` from `stations-manifest.sh`/the SPA lineup; no live
  station or golden to retire (first landing).
