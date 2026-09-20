# msx2 wave — MSX2, host-native MAME, MSX-BASIC + MSX-DOS 2

Record wave 2026-09-20, issue #60, Lane A. Integration seed
(`docs/lab/integration-seeds/msx2.md`) proposed openMSX inside nspawn/Xvfb,
closest sibling `medley`. **Decision: MAME host-native instead** — AGENTS.md
rule 13 says new work lands host-native, and MAME's `nms8250` driver already
implements the seed's own exact machine choice (Philips NMS 8250) with no
source build, no kiosk bridge and no PoC-then-throwaway step; openMSX would
need compiling from source AND its own bring-up. This is not a close call
worth racing two theories on rig-clone — the frame either comes from a
five-minute `mame -listxml` probe (already done) or a from-scratch openMSX
build, and the box already has the lab's proven host-native MAME pattern
(`samcoupe`, `atari800xl`, `apple2e`) to scaffold from. `samcoupe` is the
sibling this station is scaffolded `--like`.

## Ledger (allocated by `wave.sh alloc msx2`, session `msx2-work`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| msx2 | msx2-work | 211 / 54211 / 211 | — | — (no network plane on an 8-bit micro) |

| Fact | Value | Measured by |
|---|---|---|
| Machine | Philips NMS 8250 (MSX2, Europe, 1987) | integration seed's own choice; `mame -listxml nms8250` |
| Driver | `nms8250` — `src/mame/msx/msx2.cpp` (MAME 0.264 distro binary confirms the driver exists and boots; 0.289 pinned build in progress) | spine, 2026-09-20 |
| Scene tuple | `pizzaBoxB,homeCrtD,none,none` | spine (scaffold refused a copied `amstradCpc` tuple already held by samcoupe) |
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Device set | ONE internal floppy drive (`-flop1`, WD2793 FDC, 3.5" DSDD), two cartridge slots left EMPTY (disk-based exhibit), no mouseport anywhere — keyboard-only | `-listslots`/`-listmedia nms8250` on the distro 0.264 binary, 2026-09-20 |
| BIOS ROM set | `nms8250.zip`, 4 members (mainrom/subrom/diskrom x2 bios variants), sha256 `42905515ecc08f11f5927697c091465207816f8849dc6fe104d277ba2dd77a42` | staged `/data/assets-staging/msx2/roms/`, from `archive.org/mame-0.264-roms-non-merged` |
| MSX-DOS 2 boot disk | `MSX-DOS 2 (English).dsk`, 368 640 B, sha256 `e00558f0fc420db00b5f7f72f6d38b3f53fd462da3e6169cd63120f43e4d5733` (matches MAME's own `msxdos2e` softlist entry, crc32 `9be0bfd1`, by size) | staged `/data/assets-staging/msx2/media/`, from `download.file-hunter.com` (the integration seed's own suggested mirror) |
| RAM | 128 KB (fixed, no `<ramoption>` in `-listxml` — memory-mapper RAM slot is always populated) | `mame -listxml nms8250` |

## Streams (this wave, single worker)

Run solo (no parallel streams) by one Opus worker under the record-wave
coordinator. Order: spine (wt.sh/wave.sh/media staging) → native (custom
MAME build) → golden/keyboard proof → docs/spa → land.

## Decision log

- **openMSX vs MAME**: MAME wins outright (see above). Not logged as a raced
  theory because there was no ambiguity to race — the seed's own target
  machine is already a MAME driver.
- **Rest scene**: OPEN. The seed leaves this a choice (BASIC `Ok` vs DOS2
  prompt). Real MSX hardware auto-boots a bootable floppy on power-on, so
  with the boot disk already in `-flop1` the machine likely lands on
  MSX-DOS 2 directly rather than needing a keypress from BASIC — to be
  confirmed on the smoke frame.
- **Checkpoint**: OPEN. `MACHINE_SUPPORTS_SAVE` on `msx/msx2.cpp` is
  unconfirmed on this build; `MAME_NATIVE_CHECKPOINT=0` until measured.

## Wall(s) hit

- The shared build box was under heavy contention from ~9 other simultaneous
  record-wave workers (vax43bsd sim, palmos MAME build, riscos3 push, etc.);
  the msx2 MAME subtarget build (cold ccache for `src/mame/msx/msx2.cpp`, a
  very large driver file covering ~100+ MSX machine variants) took
  substantially longer than the fleet's usual host-native builds as a
  result. A first build attempt was killed by the worker's own client-side
  timeout wrapper before it finished (wasted ~10 min of wall time, though
  ccache kept the compiled objects); the second attempt, run detached via
  `nohup`/`disown` so it survived the worker's own command timeouts, linked
  in a few minutes off the warm cache.
- `native_stage_roms`'s `stage-romset.py` initially reported 0/4 BIOS
  members installed even though the correct `nms8250.zip` was staged: the
  staging directory held the ZIP itself, not its extracted members, and
  `stage-romset.py` hashes only top-level files in that directory (it is
  not zip-aware). Fix: extract the zip's four members as loose files into
  `/data/assets-staging/msx2/roms/` alongside the zip.
- **Rest scene, resolved short of the seed's ideal**: with the MSX-DOS 2
  boot disk already mounted via `-flop1`, the machine still lands on
  MSX-BASIC's `Ok` prompt ("Disk BASIC version 1.0" banner) rather than
  auto-booting into MSX-DOS 2, even though real MSX hardware auto-boots a
  bootable floppy on power-on. Not investigated further under the wave's
  time budget — shipped honestly as OPEN rather than guessed at. The BASIC
  `Ok` prompt is itself one of the seed's two acceptable rest-scene options.
- Keyboard: MAME's natural-keyboard ctlsock verbs (`POST`, `CODE {ENTER}`)
  were proven on the framebuffer (`PRINT 1+1` typed, executed, fresh `Ok`
  returned) — real, working keyboard input. The production daemon does NOT
  use those verbs, though; it drives the raw per-field `KEY` verb through
  the generated `msx2.keymap` (88/102 fields matched by
  `scripts/dev/mame-keymap.py`), which is UNMEASURED against the real
  `SH_KEY_MIN_HOLD_MS`/`GAP_MS` pacing or a browser tap. OPEN for the next
  stream, same shape as the samcoupe `MAME_CTL_KEY_EXCL` lesson
  (AGENTS.md's keyboard-only-exhibit guidance).
- No golden savestate baked this wave (`MACHINE_SUPPORTS_SAVE` on
  `msx/msx2.cpp` unconfirmed); `resetMode=relaunch` cold-boots every time,
  which is slower but correct and provable without a savestate.

## Stop-rule status

Landed at the honest minimum this wave's time budget supports: a dark-launched,
enabled, host-native station with a real MSX-BASIC framebuffer, hash-verified
media, a passing build-time boot gate, and one proven keyboard interaction. Not
done: MSX-DOS 2 reachability, the production ctlsock `KEY`-path keyboard proof,
and a golden savestate/checkpoint. These are recorded as OPEN above rather than
guessed at or silently skipped.
