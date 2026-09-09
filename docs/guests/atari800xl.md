# Atari 800XL (Atari, 1983) — MyPicoDos boot menu station (:54186)

**Guest:** a **host-native** MAME 0.289 station — the daemon runs the emulator
directly on the host (drawshm frames, ctlsock keys, FIFO audio), no bridge VM,
no guest OS, no QMP. MAME's **`a800xlp`** driver
(`src/mame/atari/atari400.cpp`) emulates an **Atari 800XL (PAL)** — the
`a130xe` (130XE) and NTSC `a800xl` share the same driver but the 130XE is
`MACHINE_NOT_WORKING` in 0.289, and PAL was the ledger's pick. See
**`docs/guests/apple2e.md`** and **`docs/guests/samcoupe.md`** for the shape
siblings (the same one-key boot-menu recipe on other `MAME` driver families).
Published surface: 1024×768 (MAME aspect-corrects the native raster).

**The Machine:** the disk drive is a real Atari peripheral, not a floppy
controller card — MAME's emulated **1050** (`a1050`, the driver's own default
SIO device) holds the boot disk. The disk's own boot code is **MyPicoDos
4.06N** (HiassofT), a third-party DOS-replacement boot loader whose splash
screen doubles as a file menu: every file on the disk is listed, the
highlight bar moves with the joystick port, and RETURN loads the highlighted
file. There is no separate "launcher" program — the boot sector IS the menu.

**Build scripts:** `scripts/build-guests/emulators/native.d/atari800xl.sh`
builds the host-native `a800xlp` MAME binary (device set, ROM staging, boot
gate, the `mame-irix-skip-warnings.patch` carry-over — see §Traps);
`scripts/build-guests/tiles/atari800xl.sh` composes the two boot disks
(`hive.atr`, `hive2.atr`) with `dir2atr`/`MyPicoDosCode`-based tooling.

**Station dir (host, staged):** `/data/vms/streamhost/stations/atari800xl/` —
`ctl.sock`, `atari800xl.keymap`, `station.env.fixture`,
`sta/a800xlp/golden.sta` (the savestate reset restores).

## License / provenance
- **MAME `a800xlp`** — emulation driver in `src/mame/atari/atari400.cpp`,
  GPLv2 licensed, flagged `MACHINE_IMPERFECT_GRAPHICS` (a "known problems"
  panel on every cold boot — see §Traps) and carrying **no**
  `MACHINE_SUPPORTS_SAVE` flag, unlike `apple2e`/`samcoupe`; the checkpoint
  restore was proven by measurement rather than trusted from the driver info
  (see §Checkpoint).
- **ROMs** — `co61598b.rom` (XL OS rev 2, 16 KB) sha1
  `ae4f523ba08b6fd59f3cae515a2b2410bbd98f55`; `co60302a.rom` (Atari BASIC
  rev C, 8 KB) sha1 `7ad88dd99ff4a6ee66f6d162074db6f8bef7a9b6`; the `a1050`
  sub-device's own firmware, `1050-revl.rom` (default BIOS "l") sha1
  `8b540906049864a18bdc4eff6c0a2160eac8ce39` plus the revh/revj/revk/wstr5
  variants. Staged at `/data/assets-staging/atari800xl/roms/`
  (MANIFEST.sha256, `.staged`), from the archive.org `MAME_0.224_ROMs_merged`
  set.

## Device set
- `-ctrl1 joy` — a CX40 joystick on port 1, driven from the keyboard's arrow
  keys (already MAME's own default assignment for the joystick fields; the
  keymap pins them explicitly) plus a fire key (Left Alt, overridden — its
  default `KEYCODE_LCONTROL` collided with the keyboard's own Ctrl field).
- The `a1050` disk drive is the driver's **default** SIO device and is
  **never named on the command line** — see §Traps: this narrow MAME build
  silently drops the `-flop1..4` media options the instant `-sio` appears at
  all, even naming its own default.
- Cartridge slot empty — built-in Atari BASIC is reached through the disk
  menu, not a cartridge (see §The menu).

## Boot media (media stream)
`hive.atr` — MyDOS-formatted, standard **single density** (720 × 128-byte
sectors, 90 KB ceiling), 92 176 bytes, sha256
`27fde3fd2c4b0fccc4e5a4769170370d7b9e7c4a097e7fba1c8775f92ca71638`, boot code
MyPicoDos 4.06N. `hive2.atr` — same format, 92 176 bytes, sha256
`2d68e38b3211038927b4af16587ecd5c3c22459800da00e2135cf78403ad6b4e`, no boot
code (a plain D2: data drive, `-flop2`). Both installed at
`/data/vms/streamhost/assets/atari800xl/media/`.

Titles on `hive.atr`, all proven on the framebuffer from the menu:

| Content | Source | Notes |
|---|---|---|
| The Last Word 3.2 | Jonathan Halliday, freeware | 80-column word processor; default menu highlight |
| River Raid | Activision, 1984 | |
| Star Raiders | Atari, 1979 | |
| Atari BASIC | (built in, `XBASIC.XEX` return stub) | See §Open — does not currently reach a READY prompt |

Not reachable from the menu: **Dropzone** (Archer Maclean, 1984) ships on
`hive2.atr` (D2:) but the on-screen `1-8 = D1:-D8:` drive-select legend does
not actually switch drives (measured: identical frame after the `2` key,
RETURN still loads D1:'s default) and does not fit on D1: alongside the other
four titles (95 178 B > the 90 KB single-density ceiling) — see §Open.
**Boulder Dash** was dropped, not replaced: the shipped `BOULDER.XEX`
(fandal's dump) resets the whole machine on load rather than running (see
§Traps), and the one alternative source tried was a boot-loader image with no
DOS directory to lift a clean file from.

Exact source hashes and the full manifest are in
`scripts/build-guests/tiles/atari800xl.sh` and `docs/lab/ASSETS-MANIFEST.md`.

## The menu (MyPicoDos 4.06N, boots directly off `hive.atr`)
The disk's own boot sector IS the menu — there is no separate launcher
program. On cold boot the machine loads straight into MyPicoDos's file
listing, highlight on the first entry (alphabetical order: `LASTWORD.XEX`
sorts first). Files are in disk order:

| Menu entry | Down-presses from the top | What it is | From the menu to its first screen |
|---|---|---|---|
| `LASTWORD.XEX` | 0 (default highlight) | The Last Word 3.2 — 80-column word processor | RETURN → splash "The Last Word / Version 3.2 / By Jonathan Halliday" at ~7 s |
| `LW.CFG` | 1 | The Last Word's own config file, not a program | do not select — listed because MyPicoDos lists every file (cosmetic, see §Open) |
| `RIVRRAID.XEX` | 2 | River Raid (Activision, 1984) | RETURN → attract mode, scrolling river, score/bridge HUD |
| `STARRAID.XEX` | 3 | Star Raiders (Atari, 1979) | RETURN → the STAR RAIDERS title screen (starfield + cruiser) at ~7 s |
| `XBASIC.XEX` | 4 | exit to Atari BASIC | RETURN → **does not reach BASIC**, returns to the menu — see §Open |
| `DROPZONE.XEX` | — (on `hive2.atr`, D2:, not reachable) | Dropzone (Archer Maclean, 1984) | ships on disk but no menu path reaches it — see §Open |

## §Keyboard
8 keyboard matrix ioports (`keyboard.0`..`7`) plus a console port
(Start/Select/Option/Reset) and a fake port; joystick fields live under
`:ctrl1:joy:JOY` (P1 Up/Down/Left/Right/Button 1).

Menu navigation is the joystick, not a keyboard chord: the station's PC arrow
keys are already MAME's default assignment for the joystick fields, so **no
override is needed** to move the MyPicoDos highlight bar — `P1 Down`/`P1 Up`
move it one entry per press (measured, moved BOULDER.XEX → DROPZONE.XEX and
back). On real hardware the same navigation is Ctrl+`-`/`=`/`+`/`*`, but
those chords are not the transport this station uses. RETURN loads the
highlighted file. Left Alt is joystick fire (Button 1). F1/F2/F3 map to
Start/Select/Option. Right Ctrl is the Atari (inverse-video) key. Backspace
is BackS/Delete. Reset re-boots `D1:` and lands back on the menu — there is
no way to get stuck.

MEASURED: the generated keymap's 64/82 fields matched against source plus the
override rows above.

## §Checkpoint
Captured on a sandbox rig (never the station dir): cold boot with
`-flop1 hive.atr -flop2 hive2.atr` attached (no `-sio` on the command line —
see §Traps), wait for the directory listing to settle, then `SAVEST golden`.
Current golden (quiet-sio stream, 2026-09-08, see "Quiet SIO" below): path
`sta/a800xlp/golden.sta`, **31 830 bytes**, sha256
`ccbe6260f7c55409f7abcfa31b01951ccce0c212e0c1cbc717999ad829d00509`, capture
cost 122 ms. Staged into the station dir at the same path, same bytes (copy
verified by sha256), dirs chmod 755, file chmod 644.

**Restore proven, not assumed**: `a800xlp` carries no `MACHINE_SUPPORTS_SAVE`
flag in its driver info — the shared launcher's checkpoint restore is not
guaranteed by the driver the way it is on `apple2e`/`samcoupe`. Measured
anyway (golden stream): a fresh process relaunched with `-state golden`
produced a pixel-identical frame (`PIL.ImageChops.difference` bbox `None`,
matching sha256 prefix on both sides) 1.29 s after launch. `MAME_NATIVE_CHECKPOINT=1`
ships on that measurement. Cold boot to the same settled menu, for
comparison, takes ≈19–21 s.

The golden state is the settled **menu only** — LASTWORD, RIVRRAID and
STARRAID are all proven to load past it fresh; XBASIC and Dropzone do not
work from the menu (see §Open).

**Quiet SIO** (quiet-sio stream, 2026-09-08): the golden also carries
`SOUNDR=0` (Atari OS zero page, `$0041`) — the XL OS's SIO routine drives
the speaker on every SIO frame while `SOUNDR` is non-zero (power-on default
3), which turns a MyPicoDos load into a "beep concert" (dozens of beeps over
the ~15 s load). Authentic 800XL behaviour, silenced here by operator
choice: `streamhost/stations/atari800xl/quiet-sio.lua` is a one-shot MAME
Lua `-autoboot_script` that pokes the byte before `SAVEST` — the ctlsock
protocol has no memory-write verb, checked before adding a script (see
`docs/lab/ATARI800XL-WAVE.md` "Quiet SIO" for the full method, the
`-autoboot_delay`+`-state golden` timing trap hit while proving the
read-back, and the reversal path). Proven: fresh `-state golden` restore
reads `$0041 == 0`; the same restore's `SHOT` is byte-identical to the
pre-poke settled-menu PNG (sha256
`e775b58d332c2e5f69f951319563009d9776e27d550d9cc007a73b4468e01c46` on both
sides); RETURN on the default highlight (`LASTWORD.XEX`) from that restore
still reaches The Last Word's splash — the load still works, just silently.
Reversible: recapture the golden on a plain cold boot (no `quiet-sio.lua`)
to bring the authentic SIO noise back.

## §Media
See the media table above; sourcing/hash details live in
`scripts/build-guests/tiles/atari800xl.sh` and `docs/lab/ASSETS-MANIFEST.md`.
Single density (90 KB/drive) is the hard ceiling — MAME's emulated 1050
(`src/devices/bus/a800/atari1050.cpp`) implements only single and double
(MFM) density; **enhanced density is not modeled at all**, which is why the
disks are single density rather than the higher-capacity format a real 1050
also supports (see §Traps).

## §Traps
Worth knowing before touching the driver, the disk composer, or the boot
code again:

1. **Naming `-sio a1050` on the command line — even though it is only the
   driver's own default — makes this narrow MAME build silently drop the
   `-flop1..4` media options entirely** (`-flop1` then errors as "unknown
   option"). Omitting `-sio` keeps the same a1050 drive attached (it is the
   default either way) and keeps `-flop1` working. `NATIVE_MAME_ARGS` carries
   only `-ctrl1 joy`.
2. **`MACHINE_IMPERFECT_GRAPHICS` puts up a "known problems" panel on every
   cold boot**, and `ui.ini`'s `skip_warnings` option does **nothing** in
   stock MAME 0.289 — `display_startup_screens()` never consults
   `options().skip_warnings()`. Without a fix the panel is a stuck screen: no
   ctlsock command responds (even PING times out) until a key is pressed,
   and a keypress does not dismiss it — the boot gate's "non-black frame"
   check would pass on the panel itself, not the exhibit. Fixed by carrying
   `mame-irix-skip-warnings.patch` (mpf2's own fix for the same upstream gap)
   in `NATIVE_EXTRA_PATCHES`.
3. **A double-density or enhanced-density ATR does not boot reliably here.**
   Double-density hangs on a blank blue screen forever. Enhanced density
   (1040 × 128 B) boots to a *correct-looking* menu — the boot sectors and
   low directory sectors happen to read fine — but every file load beyond
   the directory silently fails: MyPicoDos redraws the unchanged menu
   instead of running the program, which reads exactly like the "RETURN
   doesn't load" symptom below and cost three streams before it was
   separated out. Build single density (`dir2atr`'s default) instead.
- **`BOULDER.XEX` (fandal's dump) resets the whole machine on load, not an
  aborted load.** RETURN on that entry reproduces a byte-identical frame
  sequence to a cold boot, frame hash for frame hash — confirmed with the
  Atari BASIC ROM disabled too (console OPTION held from power-on), so a
  paged-in BASIC ROM is not the cause. It sat on the menu's default
  highlight, which is why four earlier streams and three race runners all
  concluded the whole menu was broken before the bad title was isolated.
  Dropped from the shipped disk for that reason.
- With no disk in `-flop1` at all, the XL OS retries the SIO boot sector
  forever ("BOOT ERROR" loop) — real hardware behaviour for a powered,
  diskless drive, not a station bug.
- **`-autoboot_delay N` (N ≥ 1) combined with `-state golden` never fires
  the autoboot script.** MAME's autoboot timer is re-armed only off
  `MACHINE_NOTIFY_RESET` (`reset()` in `mame.cpp`), and a state-loaded boot
  never reaches the N-second mark relative to that notifier the way a cold
  boot does. `-autoboot_delay 0` DOES fire, but early enough that a memory
  read at that point can return garbage (measured: `255` instead of the
  real value) — wrap any post-restore Lua read in
  `emu.register_periodic(...)` and act a few ticks in instead. Bakes
  (writes before `SAVEST`) are unaffected: they run from a cold boot with a
  real delay, where the trap does not apply. See
  `docs/lab/ATARI800XL-WAVE.md` "Quiet SIO" for the full account.

## §Open
- **`XBASIC.XEX` does not reach a BASIC READY prompt.** The 18-byte stub
  clears the BASIC ROM back in, zeroes `BOOT?`/`COLDST`, and jumps to
  `WARMSV` — but the OS warm start still routes back through `DOSINI`, which
  MyPicoDos owns, so the machine lands back on the MyPicoDos menu instead of
  BASIC. Three fixes were tried and rejected: neutralising `DOSINI` alone (no
  change); `JMP $A000` direct into the BASIC ROM, which escapes MyPicoDos but
  draws a garbage screen (BASIC's entry point assumes the OS already reset
  the screen editor); neutralising `DOSINI` and redirecting `DOSVEC`, which
  hangs permanently on the blue pre-boot screen. The shipped disk keeps the
  original safe stub (clean return to the menu, no hang) over the hang. Next
  theory: disassemble the boot sectors MyPicoDos itself writes onto
  `hive.atr` to find the real hook.
- **Dropzone (D2:) is unreachable.** It ships on `hive2.atr` but no proven
  key sequence switches MyPicoDos to D2:, and it does not fit on D1: with the
  other four titles. Next stream: find the real drive-select mechanism, or
  drop Dropzone and free the second drive image entirely.
- **`LW.CFG` is a cosmetic wart.** MyPicoDos lists every file on the disk,
  including The Last Word's own config file — it does nothing if selected,
  but it is a menu entry a visitor could press.
- **The `=`/`+` key mapping (and joystick chord equivalents) is not
  framebuffer-proven** — the fleet-wide US-scancode-to-Atari-charMap
  derivation used elsewhere in the museum has not been verified against a
  live frame on this station.
- **Pointer:** the driver has no honest pointer path for this machine class;
  the station ships keyboard(+joystick)-only, `stream.pointer.transport:
  "none"`, as `apple2e`/`samcoupe` do for the same reason.

## Build status (2026-09-08)
- Slot 186, UDP 54186, VMID 186; scene tuple `c64A,homeCrtC,none,none`;
  host-native from day one (Rule 13) — no bridge kiosk was built for this
  station.
- Keyboard/joystick: verified on the live rig over the real ctlsock/keymap
  path, three of the four D1: titles proven to their first screen from a
  fresh golden restore (LASTWORD, RIVRRAID, STARRAID); XBASIC and Dropzone
  remain open.
- Pointer: none — keyboard/joystick-only station.
- Checkpoint: golden savestate captured at the settled menu, restore proven
  pixel-identical in 1.29 s despite the driver carrying no
  `MACHINE_SUPPORTS_SAVE` flag.
