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
| Media | **REBUILT, golden4 stream 2026-09-08 — Boulder Dash dropped, XBASIC.XEX reverted to the safe 18-byte version.** `hive.atr` — MyDOS format, standard SINGLE density (720 x 128-byte sectors), 92 176 B, sha256 `27fde3fd2c4b0fccc4e5a4769170370d7b9e7c4a097e7fba1c8775f92ca71638`, boot code **MyPicoDos 4.06N** (HiassofT; the `N` build has high-speed SIO off, see Walls). `hive2.atr` — same format, 92 176 B, sha256 `2d68e38b3211038927b4af16587ecd5c3c22459800da00e2135cf78403ad6b4e` (unchanged — Dropzone was never re-touched), no boot code (plain D2: data drive, `-flop2`, **UNUSED** — see Walls, D2: switching does not select it). Both built by `scripts/build-guests/tiles/atari800xl.sh`, installed at `/data/vms/streamhost/assets/atari800xl/media/{hive.atr,hive2.atr}`. Single density (90 KB/drive ceiling) — MAME's emulated 1050 (`src/devices/bus/a800/atari1050.cpp`) does not implement enhanced density | golden4 stream (measured 2026-09-08) |
| Titles SHIPPED | On D1: (`hive.atr`, 4 titles, all PROVEN on frames) — River Raid (1984, Activision) `RIVRRAID.XEX`, Star Raiders (1979, Atari) `STARRAID.XEX`, **The Last Word 3.2** (Jonathan Halliday, freeware 80-column word processor) `LASTWORD.XEX` + `LW.CFG` (default menu highlight — MyPicoDos sorts alphabetically, `LASTWORD.XEX` sorts first), and `XBASIC.XEX` (ours, 18 bytes) for Atari BASIC — STILL fails to reach a READY prompt, see Walls. **DROPPED: Boulder Dash** — fandal's `BOULDER.XEX` resets the machine on load; the one alternative tried (archive.org's First Star Software US "h Iron Software" dump) ships only a 16 000-byte boot-loader ATR with no DOS directory to lift a clean XEX from, so it was dropped rather than replaced. **UNUSED: Dropzone** `DROPZONE.XEX` sits on `hive2.atr` (D2:) but the D2: drive-select key does not switch drives (measured, see Walls) and Dropzone does not fit on D1: alongside the other four (59 667 B + 35 511 B = 95 178 B > 90 KB ceiling), so it ships on the disk but is not reachable from the menu — **OPEN**, next stream's to fix or drop for real. **DROPPED: M.U.L.E.**, **Yoomp!**, **Rescue on Fractalus!** — as before | golden4 stream 2026-09-08 |
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

- **THE "RETURN DOESN'T LOAD" WALL IS SOLVED (golden3 stream, 2026-09-08): it
  was never the loader, the density, or the key transport — it was ONE BAD
  TITLE, `BOULDER.XEX`, which happens to be the entry the highlight starts
  on.** Four streams and three race runners all pressed RETURN on the default
  highlight and only ever tested Boulder Dash. Moving the bar down first and
  then pressing RETURN loads the other titles correctly, on the SHIPPED
  single-density `hive.atr`, over the real ctlsock/keymap path
  (`:ctrl1:joy:JOY P1 Down` x N, then `:keyboard.1 Return`):
  - 1 down → `LASTWORD.XEX` → **The Last Word 3.2 splash then editor** —
    `proof/lastword_editor.png`
  - 3 downs → `RIVRRAID.XEX` → **River Raid attract mode, scrolling** —
    `proof/rivrraid_attract.png`
  - 4 downs → `STARRAID.XEX` → **Star Raiders title screen** —
    `proof/starraid_mission.png`
  Evidence that Boulder Dash specifically REBOOTS the machine (E1): after
  RETURN on entry 0 the SHOT sequence is **byte-identical, frame hash for
  frame hash, to a cold boot** — 842 B blank blue (`36c04d58`) for ~13 s, the
  402 B MyPicoDos boot frame (`634e1046`) at ~14 s, blue again, the 2090 B
  half-painted directory (`92f4090b`) at ~19.8 s, the settled 2980 B menu
  (`7ba7f15e`) at ~21 s. That is a full machine reset, not an aborted load and
  not "the menu redrawn". Reproduced with the Atari BASIC ROM disabled as well
  (console OPTION held down from power-on through the whole boot, keymap row
  `:console CONS.2: Option`) — identical reboot, so BASIC being paged in is
  not the cause. `ataricom BOULDER.XEX` shows one 17 344-byte block at
  `2900-6cbf` with `RUN 6c80`; the file loads and then resets the machine.
  **Boulder Dash must be dropped from (or replaced on) `hive.atr` before the
  station lands** — a broken title sitting on the default highlight is what
  made the whole station look broken to four streams in a row. NOT done in
  this stream: no media rebuild was attempted, so `hive.atr`, `hive2.atr` and
  the staged golden are byte-unchanged from the golden2 stream.
- **The boot code is NOT the variable (golden3, 2026-09-08).** RETURN on entry
  0 was raced across five MyPicoDos builds on the same file set and the same
  SD geometry — `MyPicoDos406` (highspeed SIO on), `406N` (shipped, HS off),
  `406B`, `405B`, `404B` (barebone: no highspeed SIO, no remote console) and
  `403` (standard speed only). **All five produced the identical reboot
  sequence with the identical frame hashes.** The AtariSIO README's
  "emulators react allergic to the highspeed SIO code" note is therefore NOT
  the mechanism here; the shipped `MyPicoDos406N` stays.
- **The file size / SIO read path is NOT the variable (golden3, 2026-09-08).**
  A disk carrying only the 18-byte `XBASIC.XEX` (built `-b MyPicoDos406N` and
  `-b MyPicoDos406B`) does NOT reboot on RETURN — it returns to the menu in
  ~8 s with no boot frames at all. So MyPicoDos reads and runs files off this
  emulated 1050 fine; the reboot is the loaded program's own doing.
- **`XBASIC.XEX` does not reach Atari BASIC — still OPEN, but now understood.**
  RETURN on `XBASIC.XEX` (5 downs, or alone on a disk) lands back on the
  **pixel-identical MyPicoDos menu** (2980 B / `7ba7f15e`) after ~8 s, with no
  reboot frames. The 18 bytes run; the OS warm start (`JMP $E474`) then hands
  control straight back through `DOSINI` ($0C/$0D), which MyPicoDos still owns,
  so MyPicoDos re-initialises and redraws its own menu. The fix is to
  neutralise `DOSINI` (point it at an RTS) as well as zeroing `BOOT?` ($09)
  before the warm start — NOT attempted inside this stream's time box.

- **A double-density ATR does not boot under `-sio a1050`.** `dir2atr -d` (256-byte
  sectors) is the obvious way to fit more titles; the result hangs on a blank blue
  screen forever, because a real Atari 1050 is a single/enhanced density drive and
  MAME emulates that faithfully. Build with `-E` (standard ED, 1040 x 128 B) and the
  same directory boots to the menu in ~28 emulated seconds. Cost: ~15 min.
- **Enhanced density boots to a correct menu but every XEX LOAD off it fails
  (golden-fix stream, 2026-09-08).** The wall above says a real 1050 is
  single/enhanced-density-capable and MAME "emulates that faithfully" — that
  claim was WRONG for the emulated 1050 specifically: MAME's
  `src/devices/bus/a800/atari1050.cpp` implements only single density (FM,
  720 x 128 B, 90 K) and double density (MFM, 256 B/sector); enhanced density
  is not modeled at all. An ED image's boot sectors and low-numbered
  directory sectors happen to read fine (so the menu draws correctly and the
  boot gate's "non-black frame" check passes), but every XEX beyond the
  directory fails partway through, and MyPicoDos silently redraws the menu
  instead of running the program — three independent race runners each
  reproduced this: any confirm input → blue "loading" screen ~20 s → menu
  back, pixel-identical (PIL bbox `None` against the pre-RETURN frame). Fix:
  build SINGLE density (`dir2atr`'s default, no `-d`/`-E`; `-S` pins it
  explicitly) — 90 K is the hard per-drive ceiling, so the 6-title library
  (77 011 B of payload) still fits on one drive with room to spare; only
  Dropzone (35 511 B, the largest single file) was moved to a second drive
  (`hive2.atr`, `-flop2`) by priority order, not because it didn't fit.
- **SUPERSEDED by the golden3 finding above (kept for the record).** **The single-density rebuild does NOT close the "RETURN doesn't commit a
  load" wall — that bug is separate from density (golden-fix stream,
  2026-09-08).** Re-testing RETURN on the SD disk, on the golden-fix
  stream's own sandbox rig (`atari800xl-golden2/rig2`, `-state golden`
  restored, real ctlsock/keymap path, `:keyboard.1 Return`), reproduces the
  EXACT same symptom the earlier ED-disk proof and the pre-existing
  "STILL OPEN" wall (below, under Proofs) already named: a frame-size
  transient (842 B blank blue → briefly 402 B "list clearing") followed by
  the unchanged menu (2980 B, pixel-identical to the pre-RETURN frame) at
  15-25 s, tried with a single tap, a longer 500 ms hold, and a second
  RETURN 2 s after the first. This DISPROVES the assumption (this stream's
  own brief included) that enhanced density fully explained the "confirm
  input → blue loading screen → menu back" symptom on THIS rig's real
  ctlsock/keymap key-transport path — the density bug and the RETURN-commit
  bug are two separate walls that happened to produce visually similar
  symptoms. The density fix is real and necessary (an ED disk cannot load
  ANY title, full stop) but not sufficient: per-title first-screen proofs
  are still blocked by the older, still-open RETURN wall. Not bisected
  further inside the time box — this is exactly what rule 14 says to race
  on `rig-clone.sh`, not chase serially past a deadline; the candidate
  theories already listed under Proofs (hold across a frame boundary,
  release the highlight key before RETURN, a second RETURN after the first
  swallow) are still untested in isolation and should be the race's
  theories.
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
loads the highlighted file**. On real hardware navigation is the four arrow
keys (Ctrl+`-` / Ctrl+`=` / Ctrl+`+` / Ctrl+`*`), but **MEASURED on the golden
stream's rig (2026-09-08): MyPicoDos ALSO reads the joystick port directly** —
the station's PC arrow keys, already mapped to `:ctrl1:joy:JOY P1 Up/Down` by
the keymap (no Ctrl chord needed, no override required), move the highlight
bar one entry per press (`KEY 1/0 :ctrl1:joy:JOY P1 Down` moved BOULDER.XEX →
DROPZONE.XEX; `P1 Up` moved it back). This is the input the on-screen keyboard
already offers, so the visitor CAN move the bar. Reset re-boots `D1:` and
lands back on this menu, so there is no way to get stuck. Entries are in disk
order:

**Disk layout changed 2026-09-08 (golden-fix stream): single density, two
drives.** D1: (`hive.atr`, boots) carries four titles + BASIC (Boulder Dash
dropped, golden4 stream). Dropzone sits on D2: (`hive2.atr`, `-flop2`, no
boot code) but is **UNREACHABLE**: golden4 measured the `2` key (the
on-screen `1 - 8 = D1: - D8:` legend's drive-select) — the frame after
pressing it is pixel-identical to the D1: menu, and a subsequent RETURN loads
`LASTWORD.XEX` (D1:'s own default), not Dropzone. MyPicoDos never switched
drives. Entries below are in `hive.atr`'s disk order (alphabetical — MyPicoDos
sorts); **every entry's first screen is now PROVEN except XBASIC**.

| Menu entry | Down-presses from the top | What it is | From the menu to its first screen |
|---|---|---|---|
| `LASTWORD.XEX` | 0 (default highlight) | The Last Word 3.2 — 80-column word processor (Jonathan Halliday, freeware) | RETURN → **PROVEN**: splash "The Last Word / Version 3.2 / By Jonathan Halliday" at ~7 s — `proof/lastword_default_highlight.png` (golden4, on the final Boulder-dropped disk) |
| `LW.CFG` | 1 | The Last Word's config file, not a program | do not select it — it is listed because MyPicoDos lists every file. **Cosmetic wart, OPEN** |
| `RIVRRAID.XEX` | 2 | River Raid (Activision, 1984) | RETURN → **PROVEN**: attract mode, scrolling river, "RIVER RAID(TM) by C..." banner, score/bridge HUD — `proof/rivrraid_attract.png` (golden4 re-proof on the final disk) |
| `STARRAID.XEX` | 3 | Star Raiders (Atari, 1979) | RETURN → **PROVEN**: the STAR RAIDERS title screen (starfield + cruiser) at ~7 s, static thereafter — `proof/starraid_mission.png` (golden4 re-proof on the final disk) |
| `XBASIC.XEX` | 4 | exit to **Atari BASIC** | RETURN → **STILL FAILS, OPEN** — three fixes tried by golden4 (DOSINI-only neutralise: no change, same menu back; direct `JMP $A000`: escapes MyPicoDos but draws a garbage screen; DOSINI+DOSVEC redirect through WARMSV: a permanent hang on the blue pre-boot screen, worse than either). Shipped disk carries the ORIGINAL 18-byte version (returns cleanly to the menu, does not hang) rather than the hang. See Walls |
| `DROPZONE.XEX` | — (D2:, not reachable) | Dropzone (Archer Maclean, 1984) | On `hive2.atr` — **CONFIRMED the D2: drive-select key does not switch drives** (golden4, measured: identical frame after `2`, RETURN still loads D1:'s default). Does not fit on D1: either (59 667 B of the other four + 35 511 B = 95 178 B > 90 KB). Ships on disk but is dead weight on the menu — next stream: find the real drive-select mechanism or drop it |

Proof frames from the golden3 stream live at
`/data/vms/sandbox/atari800xl-golden3/proof/`; golden4's re-proofs (final,
Boulder-dropped disk) live at `/data/vms/sandbox/atari800xl-golden4/proof/`
(captured on the shipped `hive.atr`/`hive2.atr`, real launch line, ctlsock
`KEY` through the station keymap).

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
- **DONE** — cold boot to the fully-populated MyPicoDos menu, golden stream's
  sandbox rig (`/data/vms/sandbox/atari800xl-golden/rig`), real launch line
  (no `-sio`, `-flop1 hive.atr -ctrl1 joy`): directory listing settles by
  mtime≈19s (`.../rig/menu_full.png`); a coarse poll of the same boot (file
  size jumping from 842 B "blank blue" to 2203/3097 B "menu drawn") lands the
  first drawn frame at ≈6.5s wall (`.../rig/coldboot_menu_early.png`) — the
  gap between "menu visible" and "directory fully painted" is MyPicoDos's own
  SIO directory read, not a station bug.
- **DONE** — `-state golden` restore, same rig, relaunch: ctl.sock ready in
  5 ms, SHOT taken 75 ms after launch (`.../rig/restored_menu.png`), **pixel-
  identical** to the pre-SAVEST frame (PIL `ImageChops.difference` bbox
  `None`).
- **DONE** — menu-highlight navigation, ctlsock KEY through the real keymap
  fields (`:ctrl1:joy:JOY P1 Down` / `P1 Up`): the bar visibly moves entry 0 →
  1 → 0 (`.../rig/after_down.png`, `.../rig/after_up.png`). See "## Menu"
  above — this closes the wave's "unknown, you measure it" navigation item.
- **DONE (golden3, 2026-09-08)** — three titles' own first screens from the
  shipped disk over the real ctlsock/keymap path: `proof/lastword_editor.png`,
  `proof/rivrraid_attract.png`, `proof/starraid_mission.png` (see Menu). The
  entry below is kept for the record; its conclusion was wrong because every
  attempt in it pressed RETURN on `BOULDER.XEX`, the one title that reboots.
- **SUPERSEDED** — a title's own first screen after RETURN on the highlighted
  entry. The golden stream drove RETURN twice through the real ctlsock/keymap
  matrix path (`:keyboard.1 Return`, 50 ms and 150 ms holds, `MAME_CTL_KEY_HOLD/GAP`
  at the fleet floor 40/40 ms) and both times hit exactly the wall the media
  stream already flagged: the frame briefly drops to the "list clearing" state
  (`t_sel`-shaped, file-size 402 B) then returns to the **unchanged** menu
  (PIL bbox `None` against the pre-RETURN frame) — MyPicoDos accepts the key
  (STAT counters increment, no ERR) but does not commit to a load. This is the
  SAME symptom the walls section already named as unresolved for MAME's
  natural-keyboard path; it reproduces on the real matrix path too, so the
  cause is not the input transport. **Not bisected further inside the 30-
  minute time box** (rule 14: this is exactly a "wall" that should be raced on
  `rig-clone.sh`, not chased serially by one agent past the deadline).
  Candidate next theories, un-raced: (a) RETURN needs to be held across more
  than one frame boundary of the ctlsock's paused/running pickup window: (b)
  MyPicoDos wants the highlight key released before RETURN is pressed, not
  overlapped; (c) a second RETURN after the first "swallow" succeeds (untested
  — the walls doc's own `t_sel` proof suggests intermittency, not a hard
  block). Until this closes, `BOULDER.XEX` / `DROPZONE.XEX` / `LASTWORD.XEX` /
  `RIVRRAID.XEX` / `STARRAID.XEX` / `XBASIC.XEX` first-screen proofs are all
  unproven on this rig; the menu itself, its navigation and its restore are.
- `labctl shot` / `type` on the live station after landing

## Checkpoint

**REBAKED 2026-09-08 (golden4 stream) on the Boulder-dropped disk pair** —
the earlier golden below was captured with Boulder Dash still on `hive.atr`
and is no longer installed.

- **Method**: `SAVEST golden` over ctlsock, at the fully-settled MyPicoDos menu
  (settled by i=11 polls, `-flop1 hive.atr -flop2 hive2.atr`), on
  `/data/vms/sandbox/atari800xl-golden4/bake`.
- **Path**: `bake/sta/a800xlp/golden.sta` (31 852 B, sha256
  `57c84b9d3e39f8c58c75b8ffe7b512b0d7edbb4d279ea2092cd7f07424eb7c48`), capture
  cost 126 ms. Staged into the station dir at
  `/data/vms/streamhost/stations/atari800xl/sta/a800xlp/golden.sta` (same
  bytes, same sha256 — copy verified), dirs chmod 755, file chmod 644.
- **Restore**: relaunch on a separate rig (`atari800xl-golden4/verify`) with
  `-state_directory sta -state golden`; ctl.sock+shm ready, SHOT taken 1.29 s
  after launch, **pixel-identical** to the pre-SAVEST frame (both 2877 B,
  sha256-prefix `c004fd11` on both sides). `atari400.cpp`/`a800xlp` carries no
  `MACHINE_SUPPORTS_SAVE` flag in its driver info, but the restore is
  measured, not assumed — `MAME_NATIVE_CHECKPOINT=1` remains the golden
  stream's decision, re-confirmed on this disk pair.
- **Media staged alongside it**: `hive.atr` sha256
  `27fde3fd2c4b0fccc4e5a4769170370d7b9e7c4a097e7fba1c8775f92ca71638`, `hive2.atr`
  sha256 `2d68e38b3211038927b4af16587ecd5c3c22459800da00e2135cf78403ad6b4e`
  (unchanged), both at `/data/vms/streamhost/assets/atari800xl/media/`.
- **Caveat**: the golden state is the settled MENU only — LASTWORD/RIVRRAID/
  STARRAID all proven to load past it fresh in this stream (see Menu table);
  XBASIC and Dropzone still do not work from the menu, see OPEN.

## OPEN items (golden4 stream, 2026-09-08 — current)

- **XBASIC.XEX still does not reach a BASIC READY prompt.** Three fixes
  tried, in order: (1) neutralise DOSINI ($0C/$0D) alone with an RTS stub —
  measured no change, identical menu frame back (WARMSV's post-DOSINI
  fallback still lands on MyPicoDos, not DOSINI itself); (2) `JMP $A000`
  direct into the BASIC ROM, skipping OS warmstart entirely — escapes
  MyPicoDos (different, stable frame) but draws a garbage screen, because
  BASIC's ROM entry assumes the OS already reset the screen editor/display
  list; (3) neutralise DOSINI AND redirect DOSVEC to $A000, then still go
  through WARMSV for its screen reinit — measured WORSE, a permanent hang on
  the blue pre-boot screen. Shipped disk keeps the original 18-byte version
  (clean return to menu, no hang). Next theory, un-raced: read MyPicoDos's
  own resident code (`atarisio/tools/MyPicoDosCode.cpp` — this is the
  build-tool's *encoder*, not disassembled 6502 source, so the real target is
  disassembling the boot sectors MyPicoDos writes onto `hive.atr` itself) to
  find the actual hook, which is neither plain DOSINI nor a stale
  cart-header check.
- **Dropzone (D2:) is unreachable.** The `2` key (on-screen `1-8 = D1:-D8:`
  legend) does not switch drives — measured identical frame, RETURN still
  loads D1:'s default. Does not fit on D1: with the other four titles either
  (95 178 B > 90 KB). Ships on `hive2.atr` but is not on any menu a visitor
  can reach. Next stream: find the real drive-select key/sequence (maybe a
  different keyboard row, maybe SHIFT+digit, maybe arrow-key column
  navigation instead of a direct digit) or drop Dropzone for good and free
  the second drive image entirely.
- **Boulder Dash is dropped, not replaced.** One alternative source tried
  (archive.org's Iron Software crack, 16 000 B) was a boot-loader ATR with no
  DOS directory to extract an XEX from. A real fix needs either a clean
  single-file XEX dump from a different source, or hand-converting a
  boot-loader ATR's load segments into an XEX (feasible — the ATR's boot
  sectors declare their own load address/length — but out of this stream's
  time box).

## OPEN items (superseded — golden3 and earlier)

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
- **CLOSED (golden3, 2026-09-08) — RETURN works; `BOULDER.XEX` is a bad title.**
  See "## Walls hit". Remaining work this stream did NOT do, in priority order:
  (1) rebuild `hive.atr` without Boulder Dash (or with a working replacement)
  so the default highlight is a title that runs, and rebake the golden;
  (2) fix `XBASIC.XEX` to neutralise `DOSINI` before the warm start so Atari
  BASIC is actually reachable, then prove `PRINT 1+2` → `3` and `PRINT 2=2` →
  `1` (the `=` charMap proof is still unmade);
  (3) prove the D2: drive-select key to reach `DROPZONE.XEX`.
  The stale entry below is kept only for the record:
- **SUPERSEDED — Title-load RETURN is unreliable inside MyPicoDos on the real ctlsock/keymap
  path — CONFIRMED still open after the density fix (golden-fix stream,
  2026-09-08).** See "## Walls hit" and "## Proofs". Blocks ALL per-title
  first-screen proofs (Boulder Dash, Star Raiders, River Raid, The Last Word,
  XBASIC) and the BASIC-prompt typing proof (`PRINT 1+2` → `3`, `PRINT 2=2` →
  `1`) that depend on reaching `XBASIC.XEX`, and blocks proving the D2:
  switch to reach Dropzone. The golden-fix stream's brief assumed enhanced
  density fully explained the symptom; re-testing RETURN on the rebuilt
  single-density disk reproduced the identical "blue loading screen → menu
  returns unchanged" symptom, which disproves that assumption — this is a
  second, independent bug in the RETURN-key path, not a density artifact.
  **Not a media/density fix — needs its own stream.** Next stream: race the
  candidate theories already listed under Proofs (RETURN held across a frame
  boundary, the highlight key released before RETURN, a second RETURN after
  the first swallow — none tested in isolation yet, only combined and both
  still failed) on `rig-clone.sh`, first framebuffer proof wins, per rule 14.

## Measured timeline

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/atari800xl` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed | | |

## Teardown

(filled at landing)
