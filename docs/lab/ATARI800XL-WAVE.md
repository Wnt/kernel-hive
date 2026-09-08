# atari800xl wave — Atari 800XL, host-native MAME, a boot menu of the software people ran on it

Operator ask (2026-09-08): add the SAM Coupé and "the most versatile and legendary
of the Atari 8-bits", each with applications and games reachable the way the
apple2e station does it (a one-key boot menu; `docs/lab/APPLE2E-WAVE.md`).
This brief is the Atari 800XL's. Rule 13: host-native on the MAME path from
day one (`stations/mame-native/x11-runtime.sh`, drawshm frames, ctlsock keys,
FIFO audio); `apple2e` is the shape sibling (its registry entry is what this
one is derived from), `mpf2`/`zxspectrum` the keyboard-only precedents.

## Ledger (allocated by `wave.sh alloc atari800xl`, session `atari800xl`)

| Station | Session | Slot / UDP / VMID | X-warp | retronet |
|---|---|---|---|---|
| atari800xl | atari800xl | 186 / 54186 / 186 | — | — (no network plane on an 8-bit micro) |

| Fact | Value | Measured by |
|---|---|---|
| Display bookkeeping (inert, `runtime.x11.display`) | `:74` | spine |
| Scene tuple | `c64A,homeCrtC,none,none` | spine (scaffold refused every tuple already in the lineup) |
| MAME pin | `mame0289` (fleet pin, `build-mame-native.sh`) | spine |
| Driver | `a800xlp` — src/mame/atari/atari400.cpp (MACHINE_IMPERFECT_GRAPHICS; no MACHINE_SUPPORTS_SAVE flag — the golden stream MUST prove SAVEST/LOADST or ship MAME_NATIVE_CHECKPOINT=0 with a cold boot to the menu) | spine |
| Device set (target) | a800xlp (Atari 800XL PAL — a130xe is MACHINE_NOT_WORKING in 0.289, a800xl NTSC is the same driver), a1050 disk drive (`-flop1..4` .atr/.xfd) — a800xlp's own DEFAULT sio slot, left OFF the command line, see below — -ctrl1 joy (CX40 joystick on port 1, driven from the keyboard's arrow keys + a fire key through keymap override rows), cartslot empty (built-in BASIC) | spine from stock MAME 0.276 `-listslots/-listmedia` on labhost; **CONFIRMED on 0.289 by native stream** — MEASURED: passing `-sio a1050` explicitly on the command line (even though it names the default) makes this narrow build silently drop the `-flop1..4` media options entirely (`-flop1` then errors as "unknown option"); OMITTING `-sio` keeps the same a1050 drive attached (it is the default) and keeps `-flop1` working — `NATIVE_MAME_ARGS=(-ctrl1 joy)` only. With no disk in `-flop1` the XL OS retries the boot sector forever ("BOOT ERROR" loop), real hardware behaviour for a powered-but-diskless drive, not a bug; with the media stream's `hive.atr` present the native stream's rig booted straight to MyPicoDOS 4.06's file menu (BOULDER.XEX, DROPZONE.XEX, LASTWORD.XEX, RIVRRAID.XEX, STARRAID.XEX, XBASIC.XEX) |
| ROMs | co61598b.rom (XL OS rev 2, 16 KB) sha1 ae4f523ba08b6fd59f3cae515a2b2410bbd98f55; co60302a.rom (Atari BASIC rev C, 8 KB) sha1 7ad88dd99ff4a6ee66f6d162074db6f8bef7a9b6; atari1050 sub-device firmware 1050-revl.rom (default BIOS "l") sha1 8b540906049864a18bdc4eff6c0a2160eac8ce39 plus revh/revj/revk/wstr5 variants — all staged at `/data/assets-staging/atari800xl/roms/` (MANIFEST.sha256, `.staged`), from archive.org `MAME_0.224_ROMs_merged` | spine; atari1050 set added by native stream (2026-09-08, first "NOT FOUND" gate run) |
| Keyboard ioports | 8 matrix ports keyboard.0..7 (Return, Break on Backspace, Atari key on RCONTROL, Tab, Escape, BackS/Delete, < Clear, > Insert, Lowr/Caps, Shift, Ctrl) + console port (Start/Select/Option/Reset) + fake; joystick fields live under :ctrl1:joy:JOY (P1 Up/Down/Left/Right/Button 1) — dump with KEYDUMP --tags ':' | spine from source; **CONFIRMED by native stream's KEYDUMP** — the arrow keys already carry the joystick's default MAME assignment (KEYCODE_UP/DOWN/LEFT/RIGHT), no override needed to bind them, though the keymap pins them explicitly; Left Alt (0x38) overridden to Button 1 (its default KEYCODE_LCONTROL collided with the keyboard's own Ctrl field) |
| Published surface | 1024x768 (MAME aspect-corrects the native raster) | **CONFIRMED** by native stream's drawshm gate |
| Warning panel | MACHINE_IMPERFECT_GRAPHICS shows a "known problems" panel ("Completely unemulated features: disk / Imperfectly emulated features: graphics — Press any key to continue") on every cold boot. **MEASURED: ui.ini's `skip_warnings` option alone does NOTHING upstream** (`options().skip_warnings()` is never consulted in stock 0.289's `display_startup_screens`) — the mpf2-style `mame-irix-skip-warnings.patch` is REQUIRED to make it take effect; without it the panel is a stuck screen (no ctlsock command responds until a key is pressed, and a keypress does not dismiss it — the boot gate's non-black check would silently pass on the panel, not the exhibit). `atari800xl.sh` carries the patch and `MAME_NATIVE_SKIP_WARNINGS=1` | native stream, 2026-09-08 |
| Media | `hive.atr` — **MyDOS format, standard ENHANCED density (1040 x 128-byte sectors), 133 136 B**, sha256 `171a10ce1198d15da524730d3b07476d30dd7b4d1c183fb994b4e1050dda5aa5`, boot code **MyPicoDos 4.06N** (HiassofT; the `N` build has high-speed SIO off, see Walls). Built by `scripts/build-guests/tiles/atari800xl.sh`, installed at `/data/vms/streamhost/assets/atari800xl/media/hive.atr`. **NOT 16 MB and not double density** — an Atari 1050 is SD/ED only, so 130 KB on `-flop1` is the ceiling; a bigger library needs `-flop2` | media stream (measured 2026-09-08) |
| Titles SHIPPED | Boulder Dash (1984) `BOULDER.XEX`, Dropzone (1984) `DROPZONE.XEX`, River Raid (1984, Activision) `RIVRRAID.XEX`, Star Raiders (1979, Atari) `STARRAID.XEX`, **The Last Word 3.2** (Jonathan Halliday, freeware 80-column word processor) `LASTWORD.XEX` + `LW.CFG`, and `XBASIC.XEX` (ours, 18 bytes) for Atari BASIC. **DROPPED: M.U.L.E.** (no clean single-file XEX found in the time box), **Yoomp!** and **Rescue on Fractalus!** — both are distributed only as their own bootable ATRs, and MyPicoDos cannot launch a disk image from inside a disk | media stream 2026-09-08 |
| Stock MAME for quick media boots | `/usr/games/mame` 0.276 on labhost has this driver (`-listroms` matched); ROMs in the staging dir above | spine |

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| native | `atari800xl-native` | `scripts/build-guests/emulators/native.d/atari800xl.sh`, the built binary under `/data/vms/streamhost/assets/atari800xl/mame-native/`, `streamhost/stations/atari800xl/atari800xl.keymap` (generated + override rows), `station.env.fixture` (MAME_NATIVE_*, pacing), registry `runtime`/`stream`/`emulator` truth | sonnet |
| media | `atari800xl-media` | `scripts/build-guests/tiles/atari800xl.sh` (fetch, SHA-256, compose the boot disk with the menu), `/data/assets-staging/atari800xl/media/`, the composed disk under `/data/vms/streamhost/assets/atari800xl/media/`, `check-assets.sh` / `ASSETS-MANIFEST.md` / `os-media-catalog.md` rows | opus |
| golden (after native + media) | `atari800xl-golden` | golden savestate at the menu on a sandbox rig, restore proof, keyboard proof of the whole visitor path, `MAME_NATIVE_CHECKPOINT` decision, registry `reset` truth, staged station dir | sonnet |
| spa (after media reports the title list) | `atari800xl-spa` | `registry/posters/atari800xl.md`, hero + frames, `museum`/`spa`/`demoProgram`, `keyboardProfiles.ts`, `machineIdentity.ts` tints | opus (museum voice) |
| docs (after golden) | `atari800xl-docs` | `docs/guests/atari800xl.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` index | sonnet-low |

One owner per file. A stream that needs another's fact reads this ledger or
waits for the report. Facts flow one way: the stream that measures corrects
the ledger in its own commit and says so.

## The selector (what "a boot menu" means on this machine)

The XL boots the first disk on SIO (D1:). MyPicoDOS's boot menu lists every file and loads it on a keypress (number/letter + Return, or highlight + Return); BASIC is reachable by the [B]/reset path the media stream documents. Reset = relaunch lands on the menu again.

## Walls hit

- **A double-density ATR does not boot under `-sio a1050`.** `dir2atr -d` (256-byte
  sectors) is the obvious way to fit more titles; the result hangs on a blank blue
  screen forever, because a real Atari 1050 is a single/enhanced density drive and
  MAME emulates that faithfully. Build with `-E` (standard ED, 1040 x 128 B) and the
  same directory boots to the menu in ~28 emulated seconds. Cost: ~15 min.
- **`-autoboot_command` reaches Atari BASIC but not MyPicoDos.** MAME's natural
  keyboard drives this driver through the OS key path: posting `PRINT 40+2\n` at the
  BASIC `READY` prompt works perfectly (`proof/nk/`), but the same mechanism is
  unreliable once MyPicoDos owns the machine — a RETURN lands sometimes
  (`proof/t_sel/`, the file list clears and a load starts) and is swallowed other
  times at the same delay. **`ioport_field:set_value()` from `-autoboot_script` Lua
  does nothing at all** on this driver (probed with `h  H`, which would visibly
  toggle MyPicoDos's high-speed-SIO indicator): the field names resolve, the notifier
  runs, the guest never sees the key. The golden stream drives keys through the
  station's own ctlsock/keymap plane, which is a real matrix path, and should not hit
  this at all.
- **MyPicoDos's high-speed SIO fallback looks like a crash.** With the plain
  `MyPicoDos406` boot code, a RETURN on the menu started a load and then dropped back
  to the menu with the high-speed-SIO indicator forced from `AUTO` to `OFF` — that is
  MyPicoDos retrying after a SIO error, not a bad XEX. The shipped disk therefore uses
  **`MyPicoDos406N`**, the variant with high-speed SIO off from the start.

- **native stream (2026-09-08)**: the built binary's rig sat on a black frame
  with every ctlsock command (even PING) timing out. Cause: the
  MACHINE_IMPERFECT_GRAPHICS "known problems" panel was up, and
  `ui.ini`'s `skip_warnings` setting has no effect in stock MAME 0.289 —
  `display_startup_screens()` never checks `options().skip_warnings()`.
  Fixed by adding `mame-irix-skip-warnings.patch` (mpf2's own fix for the
  same upstream gap) to `NATIVE_EXTRA_PATCHES`.
- **native stream (2026-09-08)**: with no disk in `-flop1` the machine
  never reaches BASIC — the XL OS retries the SIO boot sector forever
  ("BOOT ERROR" loop). This is real hardware behaviour (a powered disk
  drive with no disk in it), not a bug; with the media stream's
  `hive.atr` present it boots straight to the MyPicoDOS menu instead.
  BASIC READY was proven reachable separately with no disk attached at
  all.
- **native stream (2026-09-08)**: passing `-sio a1050` explicitly on the
  command line — even though it only names the driver's own default —
  makes this narrow build silently drop the `-flop1..4` media options;
  `-flop1 hive.atr` then errors as "unknown option". Fix: never pass
  `-sio` on this station (the a1050 stays attached as the default either
  way); `NATIVE_MAME_ARGS`/`MAME_NATIVE_ARGS` carry only `-ctrl1 joy` (+
  `-flop1` in the fixture).

## Menu

The disk boots straight into MyPicoDos 4.06N, whose boot screen IS the menu. It
lists every file on `D1:`; the highlight starts on the first entry and **RETURN
loads the highlighted file**. Navigation is the four arrow keys (on an Atari
these are Ctrl+`-` / Ctrl+`=` / Ctrl+`+` / Ctrl+`*`; the station's keymap must
map a PC arrow key to that combination or the visitor cannot move the bar).
Reset re-boots `D1:` and lands back on this menu, so there is no way to get
stuck. Entries are in disk order:

| Menu entry | Down-presses from the top | What it is | From the menu to its first screen |
|---|---|---|---|
| `BOULDER.XEX` | 0 (default highlight) | Boulder Dash (First Star, 1984) | RETURN → ~15 s of SIO load → title screen; **fire (joystick 1 button)** starts the cave |
| `DROPZONE.XEX` | 1 | Dropzone (Archer Maclean, 1984) | RETURN → title screen; fire starts |
| `LASTWORD.XEX` | 2 | The Last Word 3.2 — 80-column word processor (Jonathan Halliday, freeware) | RETURN → the editor opens on an empty document, ready to type. Reads `LW.CFG` off the same disk |
| `LW.CFG` | 3 | The Last Word's config file, not a program | do not select it — it is listed because MyPicoDos lists every file. **Cosmetic wart, OPEN** |
| `RIVRRAID.XEX` | 4 | River Raid (Activision, 1984) | RETURN → title screen; fire starts the run |
| `STARRAID.XEX` | 5 | Star Raiders (Atari, 1979) | RETURN → mission-select screen; press **1**–**4** to pick a mission level |
| `XBASIC.XEX` | 6 | exit to **Atari BASIC** | RETURN → `READY` on the blue BASIC screen |

**The BASIC route** is `XBASIC.XEX`, 18 bytes of 6502 written by the builder: it
clears bit 1 of PORTB (`$D301`) so the Atari BASIC ROM pages back in over the RAM
MyPicoDos was using, zeroes BOOT? (`$09`) and COLDST (`$0244`) so the OS stops
believing a DOS is resident, then jumps to WARMSV (`$E474`). Warm start runs the
BASIC "cartridge" without re-reading the disk. `JMP $E477` (COLDSV) was tried
first and is **wrong** — a cold start re-boots `D1:` and you land straight back on
the menu. Typing `DOS` at the BASIC prompt does *not* return to the menu (there is
no resident DOS); press **Reset** for that.

## Proofs

- **DONE** — the MyPicoDos menu after a cold boot, stock MAME 0.276 `a800xlp`,
  `-sio a1050 -flop1 hive.atr`, no keys: `/data/vms/sandbox/atari800xl-media/proof/s45/a800xlp/0000.png`
  (and the builder's own boot gate frame, `/data/vms/build-atari800xl-media/gate/shots/a800xlp/0000.png`,
  which the build refuses to install without).
- **DONE** — MAME natural keyboard reaching the machine at all, `PRINT 40+2` → `42`
  at the Atari BASIC prompt: `/data/vms/sandbox/atari800xl-media/proof/nk/a800xlp/0000.png`.
- **PARTIAL** — a RETURN on the menu starting a load (the file list clears):
  `/data/vms/sandbox/atari800xl-media/proof/t_sel/a800xlp/0000.png`.
- **OPEN** — a title's own first screen after its menu key. Blocked on MAME's
  natural keyboard being unreliable inside MyPicoDos and Lua `set_value` being inert
  (see Walls). **The golden stream should take this**: it drives keys through the
  station's ctlsock keymap, a real matrix path, and it needs to press these keys
  anyway to park the golden. If a title turns out not to load, the menu is unchanged —
  drop the file from the builder's compose step and rebuild.
- `labctl shot` / `type` on the live station after landing

## OPEN items

- **`keyboard.charMap` is DERIVED, not framebuffer-verified (spa stream).** The
  Atari's `- = + *` sit on host scancodes 0x1a/0x1b/0x28/0x2b, which a US host
  labels `[` `]` `'` `\` — so typed text (and the `demoProgram`) needs a
  translation or every `=` arrives as `>`. The map in `registry/stations/atari800xl.json`
  (`keyboard.charMap` + the matching `SH_KEY_MAP` in `runtime.stationEnv`) is read
  straight off the generated keymap plus the US scancode table; the golden stream
  should prove one `=` and one `+` on the framebuffer. The same derivation is what
  the OSK's CTRL-chord cursor keys rest on.
- **BREAK has no keymap row** — the driver exposes it, the generated keymap does
  not carry it, so the on-screen keyboard deliberately omits it (a dead key is
  silent through the whole pipeline).
- Pointer: the driver has a mouse device, but the station ships keyboard-only
  (`stream.pointer.transport: none`), as apple2e does — a relative-only mouse
  has no honest absolute contract yet.

## Measured timeline

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/atari800xl` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed | | |

## Teardown

(filled at landing)
