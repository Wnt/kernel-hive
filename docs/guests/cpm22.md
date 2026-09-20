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
  `kayproii` + `kayproiikbd` ROM sets (BIOS + chargen + the keyboard's own
  Intel i8048 MCU dump `kaypro_ii-ins8048.bin`, a separate MAME device
  romset this driver requires — CORRECTED 2026-09-20: an earlier stock
  MAME 0.276 smoke test used `kaypro10kbd`/`m5l8049.bin`, but the
  fleet-pinned 0.289 tree resolves this driver's keyboard through a
  DIFFERENT device; always trust `-listxml` on the binary that will
  actually run).
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
- Keyboard proof: MEASURED 2026-09-20 against the ACTUAL fleet-pinned 0.289
  native binary (sandbox rig) — `DIR` sent via `POST`+`CODE {ENTER}` re-ran
  the directory listing from the `A>` prompt cleanly, no dropped/duplicated
  characters, at `SH_KEY_MIN_HOLD_MS`/`GAP` = 80/80 ms and no
  `MAME_CTL_KEY_EXCL`; the Kaypro II keyboard is HLE'd via an Intel i8048
  MCU (`kayproiikbd` device), not a CPU-scanned matrix the driver polls
  directly. The real-browser proof (from the deployed station) is the
  authority on whether EXCL is needed under a production SPA burst.
- Golden savestate: `sta/kayproii/golden.sta`, 14338 bytes, sha256
  `bba86537a6a02963ddecdd908e6ed22cc02708852310a4716c1bff54f4ae4bd5` —
  captured at the settled `A>` prompt, restore-proven pixel-identical
  (`PIL.ImageChops.difference` bbox `None`) on a fresh process relaunch.
- Pointer: N/A — keyboard-only exhibit, no mouse port on this machine.
- Cold-boot zero-input state: the CP/M `A>` prompt with the boot disk's
  directory listing, green phosphor text on black, 560x240 native MAME
  raster.
- Credentials reference only (never values): `guest/cpm22`
- Rollback plan: disable the registry entry (`enabled: false`) and stop the
  station; no persistent guest state to roll back (immutable floppy media,
  relaunch resets to the golden savestate).
