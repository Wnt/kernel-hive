# SAM Coupé (MGT, 1989) — SAM BASIC boot menu station (:54187)

**Guest:** a **host-native** MAME 0.289 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys, FIFO audio), no bridge VM,
no guest OS, no QMP. MAME's **`samcoupe`** driver
(`src/mame/samcoupe/samcoupe.cpp`) emulates a **SAM Coupé 512K** (Miles
Gordon Technology, 1989), a ZX Spectrum-compatible with far more machine
behind the compatibility layer — a Z80B @ 6 MHz, 512 KB RAM, and its own
disk-based DOS. See **`docs/guests/apple2e.md`** for the shape sibling (same
one-key boot-menu recipe on a different `MAME` driver family) and
`docs/guests/mpf2.md` / `docs/guests/zxspectrum.md` (if present) for the
keyboard-only precedents this station follows. Published surface: 1024×768
(MAME aspect-corrects the native raster).

**The Machine:** SAMDOS 2.0 boots off a single 800K floppy image and
auto-runs the first file whose name begins with `auto` — the SAM's own
version of `AUTOEXEC.BAT`. That file is a SAM BASIC menu program, `SAVE`d
with `LINE 1` so it starts itself the moment SAMDOS finds it. The menu offers
three period games, one period application, and a drop to a live SAM BASIC
prompt.

**Build scripts:** `scripts/build-guests/emulators/native.d/samcoupe.sh`
builds the host-native `samcoupe` MAME binary (device set, ROM staging, boot
gate); `scripts/build-guests/tiles/samcoupe.sh` composes the boot floppy
(`hive.mgt`) via `scripts/build-guests/lib/mgtfs.py`, which writes a SAMDOS
filesystem by copying whole files (with their 9-byte SAM headers) out of
source disks — no Linux tool writes a SAMDOS filesystem directly.

**Station dir (host, staged):** `/data/vms/streamhost/stations/samcoupe/` —
`ctl.sock`, `samcoupe.keymap`, `station.env.fixture`,
`sta/samcoupe/golden.sta` (the savestate reset restores).

## License / provenance
- **MAME `samcoupe`** — emulation driver in `src/mame/samcoupe/samcoupe.cpp`,
  GPLv2 licensed, `MACHINE_SUPPORTS_SAVE` (the shared launcher's checkpoint
  restore applies unmodified, as on `apple2e`).
- **ROM** — `rom31.z5`, BIOS v3.1, the driver's default, sha1
  `c86601633fb61a8c517f7657aad9af4e6870f2ee`. `-listxml samcoupe` on the built
  0.289 binary shows ONE machine with all 15 available ROM sets in the maincpu
  region and no sub-device ROMs (unlike `apple2e`'s Disk II / Mouse Card
  sub-CPUs) — all 15 installed, 0 NOT FOUND. The other 14 z5 variants are
  optional BIOS choices, staged at `/data/assets-staging/samcoupe/roms/`
  (MANIFEST.sha256, `.staged`) from the archive.org `MAME_0.224_ROMs_merged`
  set; only v3.1 is used.

## Device set
- `-drive1 floppy`, `-drive2 floppy` — the driver's own default; drive 1
  carries the boot disk (`-flop1 hive.mgt`), drive 2 is unattached.
- Mouseport present in the driver but left unattached — see §Open (no
  pointer).

## Boot media (media stream)
`hive.mgt` — an 800K MGT container, **819 200 bytes**, sha256
`dcf956311b7865962ba8cb80b04009fc796f3b887010e45adb9178cdf684a9e8` (rebuilt by
the golden-fix stream for the `B`-menu fix; the pre-fix disk was
`bcec34e98a8f5391d6bef666319fa2e55bac164a56a9096eac08905a988e3c6e`), 29 files,
104 of 1560 data sectors free. Installed at
`/data/vms/streamhost/assets/samcoupe/media/hive.mgt`, mounted as `-flop1`.
SAMDOS 2.0 is the first directory entry, which is what the ROM's `BOOT`
command loads.

Titles on the disk, all proven on the framebuffer from the menu (media stream,
2026-09-08):

| Content | Source | Notes |
|---|---|---|
| Manic Miner | Revelation, 1992 | 3-part loader (`bank0`/`bank1`/`M SCREEN`) |
| Mr. Pac | Revelation, 1992 | Pac-Man clone |
| Splat! | Incentive Software; SAM conversion by Colin Jordan | |
| The Secretary | A. N. Stevens, 1992 | Word processor, the one application on the disk |
| SAM BASIC | (built in) | Command-line prompt |

Not on the disk, and why: The Secretary's two on-disk manuals (`E_Manual`,
`Sec_Man`, 218 sectors) do not fit and nobody reads a disk manual at an
exhibit; Snake Mania and Craft! from the same 5-in-1 pack were dropped for
space. `flash`/`flash1`/`flash2` from the SAMDOS 2.0 disk were tried and
rejected as the fifth entry — despite the name it is a tape-backup utility
("Backup to Tape?"), not the Flash! art package.

Exact source hashes and the full manifest are in
`scripts/build-guests/tiles/samcoupe.sh` and `docs/lab/ASSETS-MANIFEST.md`.

## The menu (`scripts/build-guests/assets/samcoupe/auto.bas`, composed by `mgtfs.py`)
A SAM BASIC program (auto-run by SAMDOS because its filename begins with
`auto`), the SAM's version of the FreeDOS station's `MENU.BAT`: `CLS`, a
boxed list in `MODE 3` (so the listing does not wrap and fill the screen),
and an `INKEY$` loop with no `PAUSE` — a key is taken the instant it is
pressed, no dismissal keypress needed first.

| Key | Launches | Files it loads | From the menu to first playable/usable screen |
|---|---|---|---|
| `1` | Manic Miner | `MANIC M` (BASIC loader) → `bank0`, `bank1`, `M SCREEN` | ~25 s disk load to the title screen; `1`/`2`/`3` choose the game, RETURN starts it |
| `2` | Mr. Pac | `MR PAC` (BASIC loader) → `MR PAC 1` | ~20 s to the title screen; SPACE (or fire) to play, `F8` toggles music/FX |
| `3` | Splat! | `SPLATRUN` (BASIC loader) → `ALLCODE`, `LOADSCRN` | ~20 s to the instructions screen; any key reaches the game |
| `4` | The Secretary | `SECRUN` (renamed loader — see below) → `Secretary`, its `*.Sec`/`*.Key` data, `MDOS22` | ~20 s to The Secretary's own menu with LOAD THE SECRETARY highlighted; ENTER opens the editor |
| `B` | SAM BASIC | — | lands on `0 OK, 9000:2`; `RUN` returns to the menu |

Two renames on the disk, both load-bearing:

- The Secretary's launcher ships as `Auto.Sec` on its own source disk. Copied
  unchanged it would begin with `auto` and **SAMDOS would boot The Secretary
  instead of the menu** — `mgtfs.py` renames it to `SECRUN` on the way in.
- The rename carries no `.`: MAME's natural keyboard has no period mapping on
  this driver and `emu.keypost` stalls mid-string on one, so the menu source
  contains no full stops anywhere either.

**Getting to the menu from a cold machine** (what the golden savestate skips
for a visitor — see §Checkpoint): the SAM powers on to the Miles Gordon
Technology copyright banner, which **eats the first keypress** and does not
auto-dismiss; press any key (Enter), then type `BOOT` + ENTER — `F9` alone
just dismisses to BASIC, it is not a boot shortcut on this driver.

## §Keyboard
9 matrix ioports (`kbd_0`..`kbd_8`). `CNTRL` is mapped to **Left Alt**,
`SYMBOL` to **Left Ctrl**, `EDIT` to **Right Alt**, `F0` to keypad `0`
(needs a 1-row `--override` in the keymap generator — `KEYCODE_0PAD`'s
default token collides with the numeric keypad's own `KEYCODE_0_PAD` row).
Cursor keys are real; games needing a joystick are driven from the
Sinclair-style `5`/`6`/`7`/`8`/`0` keys (`joy_0`/`joy_1` ioports), same
convention as `zxspectrum`.

MEASURED on a live rig 2026-09-08 (native stream): a `KEYDUMP` of the live rig
matched 71/71 fields against source (69 dumped, 70 by the default
name/assignment matcher, F0 via the override above).

MEASURED on a live rig 2026-09-08 (golden + golden-fix streams): the fleet
default **`SH_KEY_MIN_HOLD_MS=40`**, **`SH_KEY_MIN_GAP_MS=40`** drives the
whole visitor path — the menu selector on keys `1`/`2`/`3`/`4`/`B` and the SAM
BASIC command line (`PRINT 1+2` → `3`, `RUN` → back to the menu) — over the
real `ctlsock` `KEY` path (the generated `samcoupe.keymap`, not a Lua
autotype harness), with no dropped or duplicated character. Rollover/overlap
is not stress-tested.

## §Checkpoint
Captured on a sandbox rig (never the station dir), `MAME_NATIVE_CHECKPOINT=1`
(`samcoupe` has `MACHINE_SUPPORTS_SAVE`, so the shared launcher's checkpoint
restore needs no per-station patching): cold boot with `hive.mgt` attached,
Enter to dismiss the MGT copyright banner, type `BOOT`+Enter over `ctlsock`
(18 key edges, 582 ms burst), wait for the framebuffer to settle on the
"KERNEL HIVE - SAM COUPE" menu, then `SAVEST golden`. The golden savestate is
captured **with the menu already on screen**, so the fleet's restore skips
the banner/BOOT keying entirely — a visitor never sees it (this is why the
menu-entry sequence above is documented for completeness, not because a
visitor ever types it).

Recaptured by the `golden-fix` stream, 2026-09-08, after the media disk was
rebuilt for the `B`-menu fix (same sequence, unchanged pixel source): staged
at `/data/vms/streamhost/stations/samcoupe/sta/samcoupe/golden.sta`,
**11 921 bytes**, sha256
`3fa0e14b77749aa1cce662cc1b6ee396f61f302d5d13519f750732390ff74b9e`. Restore
proof: a FRESH process relaunched with `-state golden` diffs `None`
(`PIL.ImageChops.difference` bbox) against the baked menu frame, in **1.6 s**.
Cold boot → menu settled end to end measured at 9.0 s on the same rig, for
comparison.

## §Media
See the media table above; sourcing/hash details live in
`scripts/build-guests/tiles/samcoupe.sh` and `docs/lab/ASSETS-MANIFEST.md`.
The composer (`mgtfs.py`) writes the menu via a Lua-typed autoboot script,
one line per `emu.wait(6)`, in `MODE 3` — a single unpaced
`-autoboot_command` string was tried first and mangled every ENTER into one
line (see §Traps).

## §Traps
Four walls hit and fixed by the media stream, worth knowing before touching
the disk composer again:

1. **No Linux tool writes a SAMDOS filesystem.** SimCoupé ships none,
   `samdisk` copies raw sectors, `pyz80` assembles rather than files.
   `mgtfs.py` composes a fresh image by copying whole files (entry + 9-byte
   SAM header) out of source disks, allocating sequentially from track 4 so
   the sector address map is exact by construction.
2. **The sector order is a property of the CONTAINER, not the machine.**
   `.mgt`/`.dsk` are track-major with sides interleaved; `.sad` is
   side-major. Nothing in the image says which; guessing wrong truncates
   every file to one sector. `mgtfs.load()` detects it by walking the chains
   both ways.
3. **The directory is tracks 0–3 of side 0, which is NOT the first 20 KB of
   an MGT image.** Slots 0–19 are at offset 0; slot 20 jumps to 10240.
   Reading linearly shows the first 20 files and then side 1's file data
   misread as entries — indistinguishable at a glance from stale directory
   junk, so it survived a first review. The first composed disk lost eight
   files to this, and SAMDOS overwrote them by putting the newly-`SAVE`d
   `auto` in slot 20.
4. **The boot banner eats the first key, and MAME's natural keyboard outruns
   SAM BASIC's line editor.** Typing the whole menu as one
   `-autoboot_command` string yields a single mangled line with every ENTER
   lost; without a leading newline `BOOT` arrives as `OOT` and no DOS loads;
   and `SAVE` silently goes to **tape** ("Start tape and then press a key")
   while still reporting `0 OK`. Fixed by pacing one line per `emu.wait(6)`
   from a Lua autoboot script.

A fifth trap, hit and fixed by the golden-fix stream on the real input path
(not the media stream's Lua harness): **`STOP` opens the BASIC editor, not
the command line.** MAME's `samcoupe` BASIC interpreter treats a `STOP`
statement as "open the program-EDIT view", not "return to `0 OK`" — so the
first `auto.bas` (line 130: `CLS : STOP`) landed a visitor pressing `B` in
the arrow-cursor program editor on line 10 of its own source, not a usable
prompt. Fixed by ending the program **normally** instead: line 130 is now
`GOTO 9000`, with `9000 CLS : PRINT "SAM BASIC  Type RUN to return to the
menu"` that the program falls off the end of. A program that ends without a
`STOP` reports `0 OK` at the command line. Proven on the real `ctlsock` `KEY`
path from a fresh golden restore (golden-fix stream, 2026-09-08).

Also worth knowing: SAMDOS's `flash`/`flash1`/`flash2` utilities are a
**tape** backup tool ("Backup to Tape?"), not the Flash! art package the name
suggests — tried and rejected as a menu entry for that reason.

## §Open
- **Pointer:** the driver has a mouse device, but the station ships
  keyboard-only (`stream.pointer.transport: "none"`), as `apple2e` does — a
  relative-only mouse has no honest absolute contract yet and was not
  attempted this wave.
- **Lemmings / Prince of Persia** were considered for the menu but are
  extended-format disks (multi-disk or non-MGT-container) — not attempted;
  the shipped titles are the ones that fit the single-`.mgt` recipe cleanly.
- **Mr. Pac has no poster frame** captured for the SPA gallery — the other
  four titles + the menu do.
- **`demoProgram` is not framebuffer-proven** — the SPA stream wired
  `museum`/`spa`/`demoProgram` metadata from the media stream's title list,
  but no stream in this wave captured a demo-mode framebuffer sequence to
  confirm it plays back correctly end to end.

## Build status (2026-09-08)
- Staged (not yet live at the time of this doc): VMID 187, UDP 54187, slot
  187; scene tuple `amstradCpc,homeCrtD,none,none`; host-native from day one
  (Rule 13) — no bridge kiosk was built for this station.
- Keyboard: verified on the live rig, fleet-floor 40/40 ms pacing, all five
  menu entries (`1`/`2`/`3`/`4`/`B`) proven from a fresh golden restore to
  their title/usable screens, no dropped or duplicated characters.
- Pointer: OPEN, ships keyboard-only, `pointer.transport: "none"`.
- Checkpoint: golden savestate captured at the menu, restore proven
  pixel-identical in 1.6 s.
