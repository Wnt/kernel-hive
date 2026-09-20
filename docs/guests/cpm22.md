# cpm22 guest

Status: **production** (Tier 1, host-native MAME `kayproii`) — cpm22 wave, 2026-09-20.

## Identity and source

- Public ID / tile directory: `cpm22`
- Reserved slot / UDP port: `206` / `54206`
- Archetype: `mono-terminal`
- Machine: Kaypro II (Non-Linear Systems, 1982), MAME driver `kayproii`
  (`src/mame/kaypro/kaypro.cpp`), BIOS `149c` (81-149c.u47, board 81-110).
  CP/M 2.2 (GMv2.72) boot floppy + WordStar 3.3, TOSEC preservation images
  (`Kaypro_II_TOSEC_2012_04_23`, Internet Archive). See
  `scripts/build-guests/tiles/cpm22.sh` for the pinned URLs, byte sizes and
  SHA-256 of every staged file.

## Build and device set

- Builder: `scripts/build-guests/tiles/cpm22.sh` — stages the CP/M boot
  floppy (`.td0`) and WordStar floppy (`.imd`) as-is (MAME reads Teledisk/
  ImageDisk preservation images NATIVELY; a `dsktrans` raw conversion of the
  same boot disk produced a byte-correct-sized but LOGICALLY misordered
  image that never got past "Please place your diskette into Drive" —
  measured 2026-09-20, see the builder's header comment), plus the
  `kayproii` + `kaypro10kbd` ROM sets (BIOS + chargen + the keyboard's own
  Intel 8049 MCU dump, a separate MAME device romset this driver requires).
- Canonical output: `/data/vms/streamhost/assets/cpm22/mame-native/kayproii`
  (binary), `/data/vms/streamhost/assets/cpm22/media/{cpm22-boot.td0,wordstar33.imd}`,
  `/data/vms/streamhost/assets/cpm22/roms/`.
- Emulator: MAME 0.289 (fleet pin), host-native (drawshm frames, ctlsock
  keys), no QEMU/QMP, no guest OS, no exec channel. Device set: `-bios 149c
  -flop1 <cpm22-boot.td0> -flop2 <wordstar33.imd>`; no pointer, no audio, no
  network (the Kaypro II has no mouse port and this station ships no NIC).
- Ready framebuffer: boots straight to the CP/M `A>` prompt with the boot
  floppy's own STANDARD/PRINTER software directory listing already visible
  — no automation needed to reach a non-blank scene.

## Golden, input, and rollback

- Reset mode: `relaunch`, restoring the golden savestate captured at the
  `A>` prompt (`kayproii` ships `MACHINE_SUPPORTS_SAVE`).
- Keyboard proof: MEASURED 2026-09-20 on a stock MAME 0.276 system package
  (NOT the fleet-pinned 0.289 native binary) — a scripted `DIR\n` through
  MAME's natural-keyboard path re-ran the directory listing from the `A>`
  prompt cleanly. NOT yet proven on the fleet binary, from the real browser,
  or under sustained/rapid typing; the Kaypro II keyboard is HLE'd via an
  Intel 8049 MCU (`kaypro10kbd` device), not a CPU-scanned matrix the driver
  polls directly, so whether `MAME_CTL_KEY_EXCL` is needed is OPEN — measure
  before shipping the type-in demo (fleet MAME-keyboard rule).
- Pointer: N/A — keyboard-only exhibit, no mouse port on this machine.
- Cold-boot zero-input state: the CP/M `A>` prompt with the boot disk's
  directory listing, green phosphor text on black, 560x240 native MAME
  raster.
- Credentials reference only (never values): `guest/cpm22`
- Rollback plan: disable the registry entry (`enabled: false`) and stop the
  station; no persistent guest state to roll back (immutable floppy media,
  relaunch resets to the golden savestate).
