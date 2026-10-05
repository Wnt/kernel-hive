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
- Keyboard: `SH_KEY_MIN_HOLD_MS`/`GAP` = 80/80 ms, modifier lead 10 ms,
  `MAME_CTL_KEY_EXCL=:KEYS`, and a German charMap that also applies to a
  visitor's own keys — see "Keyboard" below. The 2026-09-20 `DIR` proof
  (no EXCL) was a single slow command and did not show the overlap problem.
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

## Fresh media per start (2026-10-05)

The station mounts per-start COPIES of immutable templates
(`MAME_NATIVE_DISK_TEMPLATE`, mode 444, never handed to MAME): MAME opens its
media read-write, and before this a visitor's saved file landed in the shared
asset and outlived Restore. A start copies `cpm22-boot.td0` and
`wordstar33.imd` to `stations/cpm22/media/`. Restore stays the in-process
`LOADST golden`, but LOADST restores CPU, RAM and device registers, not media
(a floppy's track data lives in the drive's memory, a hard disk is the file),
so the Restore path pauses MAME, has the launcher's companion `media-hook.sh`
(emitted as an aux file, a Lua hook entering through `-pluginspath`) unload,
re-copy and reload every image, then LOADSTs and resumes. Without the armed
hook a Restore takes the service restart, which copies fresh media at its
start: never a plain LOADST. Mechanism:
`streamhost/stations/mame-native/x11-runtime.sh` and `media-hook.sh`.

**The case only a reload catches.** MAME cannot save TD0, so writes to A: stay
in the drive's memory and the file never changes: no hash check could see
them. On the rig `SAVE 1 KHA.COM` was listed; after a plain `LOADST golden`
DIR hid it (the BIOS's restored sector cache), but a warm boot (^C) brought
`KHA.COM` back from MAME's memory. After the media Restore the same ^C + DIR
shows no KHA.COM. Restore 313 ms, golden frame pixel-identical. Live: the
gallery Restore answered in 520 ms, in-process. The `:` key does not reach
this machine through the keymap (`B:` cannot be typed), a keyboard-map matter.

Evidence:
`/data/vms/streamhost/stations/cpm22/evidence/media-reset-2026-10-05/` (rig
frames and live frames). Rollback: `station.env.pre-mediareset-20261005` and
`x11-runtime.sh.pre-mediareset-20261005` in the station dir.

## Keyboard: a German CP/M on a US keyboard (2026-10-04)

The boot disk is **KAYPRO CP/M 2.2 (GMv2.72)**, a German BIOS. MAME's
Kaypro keyboard is a US one, and the BIOS reinterprets its keys the way a
DIN keyboard is labelled. Measured key by key at `A>` (every US key bare and
with Shift, slow, one rig pass — `evidence/shift-lead-2026-10-04/physical-charmap/keytable*`):

| US key | bare | Shift | | US key | bare | Shift |
|---|---|---|---|---|---|---|
| `1`..`0` | digits | `! " (none) $ % & / ( ) =` | | `]` | `+` | `*` |
| `-` | (none) | `?` | | `\` | `'` | `~` |
| `=` | (none) | (none) | | `,` | `,` | `;` |
| `[` `;` `'` | (none) | (none) | | `.` | `.` | `:` |
| `` ` `` | ESC | ESC | | `/` | `-` | `_` |

Y and Z are swapped (QWERTZ); every other letter is where a US keyboard
has it. "(none)" means nothing reaches the CCP's line editor: the keymap
has a row for the key and MAME delivers it, so this is the BIOS, not a
missing binding.

So the station carries `keyboard.charMap` (guest character -> the US key
that makes it) and `SH_KEY_MAP` (the same map for labctl), and
`keyboard.physical: true` applies the map to the **visitor's own keys**
too (`spa/src/three/physicalCharMap.ts`): a US visitor typing `"` sends
Shift+2, `+` sends the bare `]` key, `y` sends the Z key. cpm22 was the first
station with `physical` set; every station whose layout differs from a US PC
has it since 2026-10-05 ([`../TYPE-IN-EDITOR.md`](../TYPE-IN-EDITOR.md)).

**Unreachable on this disk:** ``# @ [ \ ] ^ ` { | } < >``. No key produces
them. A visitor who types one gets whatever the US key makes here: `@` gives
`"`, `]` gives `+`, `\` gives `'`. cpm22 has no type-in editor, so there is
no `typeIn.unreachable` to declare them; this list is the record.

**Exclusive scan.** The keyboard is an i8048 MCU device, but it still scans
a matrix, and two keys down together arrive in scan order, not press order.
Live typing before this fix came out as `PRINTA"B* *C`. A paired burst (each
key pressed while the previous one is still down) of "the quick brown fox
jumps over the layz dog 1234567890" (sent at US positions, hence `layz`) came back as `th equic kbrwo nfo xujpm
svoert ehl ayz odg 1243567890` without EXCL, and exact in 2/2 runs with
`MAME_CTL_KEY_EXCL=:KEYS` (it matches `:kbd:kayproii:KEYS0`..`KEYS11`).

