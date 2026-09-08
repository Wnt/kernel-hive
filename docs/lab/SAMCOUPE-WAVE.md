# samcoupe wave — SAM Coupé, host-native MAME, a boot menu of the software people ran on it

Operator ask (2026-09-08): add the SAM Coupé and "the most versatile and legendary
of the Atari 8-bits", each with applications and games reachable the way the
apple2e station does it (a one-key boot menu; `docs/lab/APPLE2E-WAVE.md`).
This brief is the SAM Coupé's. Rule 13: host-native on the MAME path from
day one (`stations/mame-native/x11-runtime.sh`, drawshm frames, ctlsock keys,
FIFO audio); `apple2e` is the shape sibling (its registry entry is what this
one is derived from), `mpf2`/`zxspectrum` the keyboard-only precedents.

## Ledger (allocated by `wave.sh alloc samcoupe`, session `samcoupe`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| samcoupe | samcoupe | 187 / 54187 / 187 | — | — (no network plane on an 8-bit micro) |

| Fact | Value | Measured by |
|---|---|---|
| Display bookkeeping (inert, `runtime.x11.display`) | `:75` | spine |
| Scene tuple | `amstradCpc,homeCrtD,none,none` | spine (scaffold refused every tuple already in the lineup) |
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Driver | `samcoupe` — src/mame/samcoupe/samcoupe.cpp (MACHINE_SUPPORTS_SAVE) | spine |
| Device set (target) | samcoupe, BIOS v3.1 (rom31.z5), -drive1 floppy (3.5" DD, `-flop1` .mgt/.dsk), -drive2 floppy (`-flop2`), mouseport left empty (keyboard-only, see OPEN) | spine from stock MAME 0.276 `-listslots/-listmedia` on labhost; **native stream confirms on 0.289** |
| ROMs | rom31.z5 (v3.1, default BIOS) sha1 c86601633fb61a8c517f7657aad9af4e6870f2ee; the other 14 z5 variants are optional BIOS choices — staged at `/data/assets-staging/samcoupe/roms/` (MANIFEST.sha256, `.staged`), from archive.org `MAME_0.224_ROMs_merged` | spine |
| Keyboard ioports | 9 matrix ports kbd_0..kbd_8 (CTRL on LALT, SYMBOL on LCONTROL, EDIT on RALT, F0 on keypad 0, cursor keys real), joy_0/joy_1 = Sinclair-style 6-7-8-9-0 keys, so games needing a joystick are driven from the keyboard | spine from source; native stream dumps the real tags with KEYDUMP |
| Published surface | 1024x768 (MAME aspect-corrects the native raster) | native stream re-measures |
| Media | `hive.mgt` — 800K MGT, **819 200 bytes**, sha256 `bcec34e98a8f5391d6bef666319fa2e55bac164a56a9096eac08905a988e3c6e`, 29 files, 104 of 1560 data sectors free. Installed at `/data/vms/streamhost/assets/samcoupe/media/hive.mgt`; mount as `-flop1`. SAMDOS 2.0 is the DOS (first directory entry, which is what the ROM's `BOOT` loads) | media stream, MEASURED 2026-09-08 |
| Titles SHIPPED | Manic Miner (Revelation, 1992), Mr. Pac (Revelation, 1992), Splat! (Incentive/Revelation, SAM conversion by Colin Jordan), The Secretary 1992 (A. N. Stevens — the application), and SAM BASIC. All five proven on the framebuffer from the menu | media stream, MEASURED 2026-09-08 |
| Stock MAME for quick media boots | `/usr/games/mame` 0.276 on labhost has this driver (`-listroms` matched); ROMs in the staging dir above | spine |

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| native | `samcoupe-native` | `scripts/build-guests/emulators/native.d/samcoupe.sh`, the built binary under `/data/vms/streamhost/assets/samcoupe/mame-native/`, `streamhost/stations/samcoupe/samcoupe.keymap` (generated + override rows), `station.env.fixture` (MAME_NATIVE_*, pacing), registry `runtime`/`stream`/`emulator` truth | sonnet |
| media | `samcoupe-media` | `scripts/build-guests/tiles/samcoupe.sh` (fetch, SHA-256, compose the boot disk with the menu), `/data/assets-staging/samcoupe/media/`, the composed disk under `/data/vms/streamhost/assets/samcoupe/media/`, `check-assets.sh` / `ASSETS-MANIFEST.md` / `os-media-catalog.md` rows | opus |
| golden (after native + media) | `samcoupe-golden` | golden savestate at the menu on a sandbox rig, restore proof, keyboard proof of the whole visitor path, `MAME_NATIVE_CHECKPOINT` decision, registry `reset` truth, staged station dir | sonnet |
| spa (after media reports the title list) | `samcoupe-spa` | `registry/posters/samcoupe.md`, hero + frames, `museum`/`spa`/`demoProgram`, `keyboardProfiles.ts`, `machineIdentity.ts` tints | opus (museum voice) |
| docs (after golden) | `samcoupe-docs` | `docs/guests/samcoupe.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` index | sonnet-low |

One owner per file. A stream that needs another's fact reads this ledger or
waits for the report. Facts flow one way: the stream that measures corrects
the ledger in its own commit and says so.

## The selector (what "a boot menu" means on this machine)

SAMDOS boots the disk (F9 / BOOT) and auto-LOADs the first file when it is a BASIC program named auto*; that program is the menu: CLS, boxed list, `PAUSE 0`/INKEY$, per choice LOAD "name" (a CODE file with an autostart or a BASIC loader). Titles that are whole bootable disks go in drive 2 only if nothing else works; prefer file-based copies on the one disk.

## Menu

`hive.mgt` boots SAMDOS 2.0, which auto-runs the first file whose name begins
with `auto` — our SAM BASIC menu, `SAVE`d with `LINE 1` so it starts itself.
The menu is a `PAUSE`-free `INKEY$` loop, so a key is taken the moment it is
pressed and no key is needed to dismiss anything first.

**Getting to the menu from a cold machine**: the SAM powers on to the Miles
Gordon Technology banner, which **eats the first keypress**; press any key,
then type `BOOT` + ENTER. (The golden stream should capture the savestate with
the menu already on screen, so a visitor never types this.)

| Key | Launches | Files it loads | Keys from the menu to its first playable/usable screen |
|---|---|---|---|
| `1` | **Manic Miner** (Revelation, 1992) | `MANIC M` (BASIC loader) → `bank0`, `bank1`, `M SCREEN` | `1`, then ~25 s of disk load to the title screen ("Game One / The story so far…"). At the title: `1`/`2`/`3` choose the game, **RETURN** starts it. |
| `2` | **Mr. Pac** (Revelation, 1992) | `MR PAC` (BASIC loader) → `MR PAC 1` | `2`, then ~20 s to the title screen. At the title: **SPACE** (or fire) to play; `F8` toggles music/FX. |
| `3` | **Splat!** (Incentive; SAM conversion by Colin Jordan) | `SPLATRUN` (BASIC loader) → `ALLCODE`, `LOADSCRN` | `3`, then ~20 s to the instructions screen (The Idea / Objectives / Avoid / Bonus). Press a key from there to reach the game. |
| `4` | **The Secretary** (A. N. Stevens, 1992) — word processor | `SECRUN` (BASIC loader, renamed; see below) → `Secretary` + its `*.Sec` / `*.Key` data files, `MDOS22` | `4`, then ~20 s to The Secretary's own menu, with **LOAD THE SECRETARY** already highlighted — ENTER opens the editor. The other rows are instructions, UDG keys, printer codes, disk commands and quit. |
| `B` | **SAM BASIC** | — | `B` (or `b`) drops straight to the `0 OK` prompt via `CLS : STOP` (the guest reports `16 STOP statement, 130:3`, which is the menu ending cleanly, not a fault). `RUN` returns to the menu. |

Two names on the disk are not the names on their source disks, and both
matter to anyone editing the menu:

- The Secretary's launcher is `Auto.Sec` on its own disk. Copied unchanged it
  would begin with `auto`, and **SAMDOS would boot The Secretary instead of
  the menu** — so `mgtfs.py` renames it to `SECRUN` on the way in.
- The new name carries no `.` on purpose: MAME's natural keyboard has no
  period mapping on this driver, and `emu.keypost` stalls mid-string on one.
  That is why the menu source contains no full stops anywhere.

Not on the disk, and why: The Secretary's two on-disk manuals (`E_Manual`,
`Sec_Man` — 218 sectors) do not fit and nobody reads a disk manual at an
exhibit; Snake Mania and Craft! from the same 5-in-1 pack were dropped for
space. `flash`/`flash1`/`flash2` on the SAMDOS 2.0 disk were tried as the
application and rejected — despite the name it is a tape-backup utility
("Backup to Tape?"), not the Flash! art package.

## Walls hit

**media** — four, all now fixed and all cheap to re-hit:

1. *There is no Linux tool that writes a SAMDOS filesystem.* SimCoupé ships
   none, `samdisk` copies raw sectors, `pyz80` assembles rather than files.
   `scripts/build-guests/lib/mgtfs.py` is the answer: it composes a fresh
   image by copying whole files (entry + 9-byte SAM header) out of source
   disks, allocating sequentially from track 4 so the sector address map is
   exact by construction.
2. *The sector order is a property of the CONTAINER, not the machine.*
   `.mgt`/`.dsk` are track-major with the sides interleaved; `.sad` is
   side-major. Nothing in the image says which, and guessing wrong truncates
   every file to one sector. `mgtfs.load()` detects it by walking the chains
   both ways.
3. *The directory is tracks 0–3 of side 0, which is NOT the first 20 KB of an
   MGT image.* Slots 0–19 are at offset 0, slot 20 jumps to 10240. Reading the
   directory linearly shows the first 20 files and then side 1's file data
   misread as entries — which looks exactly like stale junk past the end of a
   directory, so it survived a first review. The composed disk lost eight
   files to it, and SAMDOS put the newly SAVEd `auto` in slot 20 on top of
   them.
4. *MAME's natural keyboard is faster than SAM BASIC's line editor, and the
   boot banner eats the first key.* Typing the menu as one `-autoboot_command`
   string yields a single mangled line with every ENTER lost; and without a
   leading newline `BOOT` arrives as `OOT`, no DOS loads, and `SAVE` silently
   goes to **tape** ("Start tape and then press a key") while still reporting
   `0 OK`. The builder paces one line per `emu.wait(6)` from a Lua autoboot
   script, in `MODE 3` so the listing does not wrap and fill the screen.

## Proofs

- framebuffer of the menu after a cold boot, and after a relaunch restore
- one title launched from the menu by keys, on the framebuffer

**media stream, DONE 2026-09-08** — stock MAME 0.276 on labhost, headless
(`SDL_VIDEODRIVER=dummy -video soft -window -seconds_to_run`, frames via a Lua
`manager.machine.video:snapshot()`), under `/data/vms/sandbox/samcoupe-media/mame/`:

| Proof | Shows |
|---|---|
| `proof/01-menu-cold-boot.png` | the menu after a cold boot + `BOOT` — five entries and the `PRESS 1-4 OR B` prompt |
| `proof/key-1.png` | Manic Miner title screen |
| `proof/key-2.png` | Mr. Pac title screen |
| `proof/key-3.png` | Splat! instructions screen |
| `proof/key-4.png` | The Secretary's menu, LOAD THE SECRETARY highlighted |
| `proof/key-b.png` | SAM BASIC (`16 STOP statement, 130:3`) |

The golden stream still owns the restore-side proof.
- `labctl shot` / `type` on the live station after landing

## OPEN items

- Pointer: the driver has a mouse device, but the station ships keyboard-only
  (`stream.pointer.transport: none`), as apple2e does — a relative-only mouse
  has no honest absolute contract yet.

## Measured timeline

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/samcoupe` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed | | |

## Teardown

(filled at landing)
