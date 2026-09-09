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
| Device set (target) | samcoupe, BIOS v3.1 (rom31.z5), -drive1 floppy (3.5" DD, `-flop1` .mgt/.dsk), -drive2 floppy (`-flop2`), mouseport left empty (keyboard-only, see OPEN) | spine from stock MAME 0.276 `-listslots/-listmedia` on labhost; **CONFIRMED on 0.289 by the native stream (2026-09-08)** — `-listslots` shows the same drive1/drive2=floppy default, mouseport=mouse present but left unattached |
| ROMs | rom31.z5 (v3.1, default BIOS) sha1 c86601633fb61a8c517f7657aad9af4e6870f2ee; the other 14 z5 variants are optional BIOS choices — staged at `/data/assets-staging/samcoupe/roms/` (MANIFEST.sha256, `.staged`), from archive.org `MAME_0.224_ROMs_merged` | spine; native stream's `-listxml samcoupe` on the built 0.289 binary shows ONE machine (samcoupe) with all 15 ROM sets in the maincpu region — no sub-device ROMs, unlike apple2e — all 15 installed, 0 NOT FOUND |
| Keyboard ioports | 9 matrix ports kbd_0..kbd_8 (CTRL on LALT, SYMBOL on LCONTROL, EDIT on RALT, F0 on keypad 0, cursor keys real), joy_0/joy_1 = Sinclair-style 6-7-8-9-0 keys, so games needing a joystick are driven from the keyboard | spine from source; **native stream KEYDUMPed the live rig (2026-09-08): 69 fields dumped, 71/71 matched** (70 by the default-assignment/name matcher, F0 at `:kbd_5` via a 1-row `--override` since KEYCODE_0PAD's default token collides with the numeric keypad's own KEYCODE_0_PAD row) |
| Published surface | 1024x768 (MAME aspect-corrects the native raster) | native stream re-measured: `-video shm` publishes exactly 64+1024x768x4 bytes; boot-gate floor set to 223000 (half the measured 446518 lit pixels on the power-on colour-bar/copyright screen) |
| Media | `hive.mgt` — 800K MGT, **819 200 bytes**, sha256 `818b61d2cec6863920fbc15dd3e215e542dc342b0080affaf7106a32f3a140f1` (rebuilt by the `menu-release` stream, 2026-09-08, for the held-key `B` fix — was `dcf956311b7865962ba8cb80b04009fc796f3b887010e45adb9178cdf684a9e8` after the golden-fix stream's STOP→GOTO fix, and `bcec34e98a8f5391d6bef666319fa2e55bac164a56a9096eac08905a988e3c6e` before that), 29 files, 104 of 1560 data sectors free. Installed at `/data/vms/streamhost/assets/samcoupe/media/hive.mgt`; mount as `-flop1`. SAMDOS 2.0 is the DOS (first directory entry, which is what the ROM's `BOOT` loads) | media stream, MEASURED 2026-09-08; hash updated by golden-fix, then by menu-release |
| Titles SHIPPED | Manic Miner (Revelation, 1992), Mr. Pac (Revelation, 1992), Splat! (Incentive/Revelation, SAM conversion by Colin Jordan), The Secretary 1992 (A. N. Stevens — the application), and SAM BASIC. All five proven on the framebuffer from the menu | media stream, MEASURED 2026-09-08 |
| Stock MAME for quick media boots | `/usr/games/mame` 0.276 on labhost has this driver (`-listroms` matched); ROMs in the staging dir above | spine |

## Streams

| Stream | Branch | Owns | Model |
|---|---|---|---|
| native | `samcoupe-native` | `scripts/build-guests/emulators/native.d/samcoupe.sh`, the built binary under `/data/vms/streamhost/assets/samcoupe/mame-native/`, `streamhost/stations/samcoupe/samcoupe.keymap` (generated + override rows), `station.env.fixture` (MAME_NATIVE_*, pacing), registry `runtime`/`stream`/`emulator` truth | sonnet |
| media | `samcoupe-media` | `scripts/build-guests/tiles/samcoupe.sh` (fetch, SHA-256, compose the boot disk with the menu), `/data/assets-staging/samcoupe/media/`, the composed disk under `/data/vms/streamhost/assets/samcoupe/media/`, `check-assets.sh` / `ASSETS-MANIFEST.md` / `os-media-catalog.md` rows | opus |
| golden (after native + media) | `samcoupe-golden` | golden savestate at the menu on a sandbox rig, restore proof, keyboard proof of the whole visitor path, `MAME_NATIVE_CHECKPOINT` decision, registry `reset` truth, staged station dir | sonnet |
| golden-fix (after golden's OPEN item) | `samcoupe-golden2` | the `B` (SAM BASIC) editor-view bug: `auto.bas` menu fix, `hive.mgt` rebuild, golden savestate recapture, full 2/3/4/B keyboard proof | sonnet |
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
| `B` | **SAM BASIC** | — | `B` (or `b`) lands on a clean `0 OK, 9000:2` command line — the menu's B branch now `GOTO`s a trailing line (`9000 CLS : PRINT "SAM BASIC  Type RUN to return to the menu"`) that the program falls off the end of, instead of executing `STOP` (which used to drop the guest into the BASIC program-EDIT view instead of the command line — see the golden stream's 2026-09-08 fix below). A new line 85 (`IF INKEY$<>"" THEN GO TO 85`, `menu-release` stream, 2026-09-08) makes the menu wait for the key's release before acting, so a held `B` no longer leaks into the command line as `bNEW` (see §Walls / the release-wait fix below). Proven on the real `ctlsock` KEY path and from a real browser tap: `PRINT 1+2` → `3`, `RUN` returns to the menu. |

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

**native** — one, resolved by the golden stream's capture strategy:

- The power-on copyright screen (colour bars + "MILES GORDON TECHNOLOGY PLC
  (C) 1990 SAM Coupé 512K") does NOT auto-dismiss on its own, and with a
  floppy attached (`-flop1 hive.mgt`) it does NOT auto-boot either: a key
  (Enter) is needed to drop to the SAM BASIC command line, and from there
  `BOOT` + Enter is what loads the disk (F9 alone just dismisses to BASIC,
  same as Enter — it is not a boot shortcut on this driver). Native stream
  proved this on a live rig 2026-09-08; **resolved by the golden stream**: the
  golden savestate is captured WITH THE MENU ALREADY UP, so the fleet's
  `-state golden` restore skips the banner/BOOT keying entirely — a visitor
  never sees it.

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

**menu-release** — one, resolved:

- *A held key is read twice: once by the menu's `INKEY$` loop, again by the
  BASIC editor a scan frame later.* Line 80 (`LET k$=INKEY$ : IF k$="" THEN
  GOTO 80`) takes the key the instant it is pressed and the program exits
  within milliseconds (`GOTO 9000` falls off the end), landing at the SAM
  BASIC command line. The SAM ROM's keyboard scan runs every 20 ms frame; a
  ctlsock `labctl` press is only held 40 ms, but a browser keystroke through
  the daemon is held ≥40 ms (`SH_KEY_MIN_HOLD_MS`) plus the browser's own
  down/up gap, comfortably outliving one scan frame — so the same still-held
  `B` that selected SAM BASIC on line 130 was ALSO seen by the fresh command
  line's editor, typing `b` onto it (`bNEW` when the visitor then typed the
  demo program's first line, `NEW`). Fixed by a new line 85, `IF INKEY$<>""
  THEN GO TO 85`, right after the line-80 read: the menu now spins until the
  key is physically released before falling through to the `IF k$=...`
  dispatch. This also stops a held `1`–`4` from leaking into the game/app
  that loads.

## Proofs

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

**golden stream, DONE 2026-09-08** — MAME 0.289 host-native, real `ctlsock`
`KEY` presses through the generated `samcoupe.keymap` (the actual fleet input
path, NOT the Lua `-autoboot_command`/`emu.keypost` harness media used), under
`/data/vms/sandbox/samcoupe-golden/rig/png/`:

| Proof | Shows |
|---|---|
| `png/a-poweron.png` | cold-boot MGT copyright screen (colour bars), lit=446518 — matches the boot-gate floor fact above |
| `png/d-hivemenu.png` | the menu after Enter (dismiss banner) + typed `BOOT`+Enter — pixel source for the golden savestate |
| `png/e-restored.png` | a FRESH process relaunched with `-state golden` — PIL `ImageChops.difference` bbox against `d-hivemenu.png` is `None` (pixel-identical) |
| `png/f-key1-title.png` | `1` pressed at fleet 40/40 ms pacing → Manic Miner's title screen ("Game One / The story so far…"), no dropped/duplicated characters |
| `png/g3-lowercase-b.png`, `png/g4-after-extra-enter.png`, `png/h4-print-final.png` | `B`/`b` pressed the same way: CLS runs, but the guest lands in the BASIC **program-EDIT view** (arrow cursor on program line 10 of `auto.bas`), not the `0 OK` prompt media's harness saw — FIXED by the `golden-fix` stream below |

**golden-fix stream, DONE 2026-09-08** — same real `ctlsock` `KEY` path, under
`/data/vms/sandbox/samcoupe-golden2/rig/png/`. Fix: `auto.bas` line 130 now
`GOTO 9000` instead of `CLS : STOP`, with a trailing `9000 CLS : PRINT "SAM
BASIC  Type RUN to return to the menu"` that the program falls off the end
of — a program that ends normally (not via `STOP`) reports `0 OK` at the
command line instead of opening the BASIC editor. `hive.mgt` rebuilt (same
`mgtfs.py` compose + MAME typing pass), sha256
`dcf956311b7865962ba8cb80b04009fc796f3b887010e45adb9178cdf684a9e8`, 819 200 B.
Golden savestate recaptured at the (unchanged-looking) menu screen, sha256
`3fa0e14b77749aa1cce662cc1b6ee396f61f302d5d13519f750732390ff74b9e`, 11 921
bytes; restore proven pixel-identical (PIL diff bbox `None`), 1.6 s.

| Proof | Shows |
|---|---|
| `png/d-hivemenu.png` | the rebuilt menu after Enter+`BOOT`+Enter — pixel source for the recaptured golden savestate |
| `png/e-restored.png` | a FRESH process relaunched with `-state golden` — PIL diff bbox `None` against `d-hivemenu.png` |
| `png/key2-mrpac.png` | `2` from a fresh restore → Mr Pac title screen ("ESI IS PROUD TO PRESENT…") |
| `png/key3-splat.png` | `3` from a fresh restore → Splat! title screen (Incentive Software / Revelation) |
| `png/key4-secretary.png` | `4` from a fresh restore → The Secretary's title screen (A. N. Stevens © 1992) |
| `png/keyB-0ok.png` | `B` from a fresh restore → clean `0 OK, 9000:2` command line, no editor |
| `png/keyB-print123.png` | `PRINT 1+2` typed + Enter from that command line → `3` printed, `0 OK, 0:1` |
| `png/keyB-run-menu.png` | `RUN` typed + Enter → back at the "KERNEL HIVE - SAM COUPE" menu |

Measured timings (process-start clock, `date +%s.%N` around each step, sandbox
rig, never the station dir):

| Step | Time |
|---|---|
| cold boot → banner (colour-bar screen) | immediate (< 1 s to first frame) |
| Enter (dismiss banner) → frame dumped | 2.5 s (includes a 1.5 s settle sleep) |
| typed `BOOT`+Enter (18 key edges, burst 582 ms) → menu settled | 5.3 s after typing |
| **cold boot → menu settled, end to end** | **9.0 s** (T0 process start → T3 settled dump) |
| SAVEST at the menu | 13 ms ack, 11 871 bytes |
| fresh relaunch with `-state golden` → menu settled | 4.7 s (includes a 1 s pre-poll sleep; restore itself well under that) |
| `1` pressed (fleet 40/40 ms pacing) → Manic Miner title | ~25 s (matches the ledger's estimate) |

**menu-release stream, DONE 2026-09-08** — same real `ctlsock` `KEY` path,
under `/data/vms/sandbox/samcoupe-menu-release/rig/`, then the SAME check
from a real browser (Playwright, headed Chrome on CT950 `DISPLAY=:1`,
`/root/e2e/samcoupe-demo.mjs`):

| Proof | Shows |
|---|---|
| `rig/gold-menu.png` | fresh cold boot → Enter + typed `BOOT`+Enter → menu settled — pixel source for the recaptured golden |
| `rig/held-b.png` | `B` held 300 ms (matching a browser tap's hold time) → clean `0 OK, 9000:2`, **no stray `b`** |
| `rig/held-1-early.png`, `rig/key1-title.png` | `1` held 300 ms → Manic Miner loads and reaches its title screen, **no leaked `1`** |
| `rig/restored.png` | a FRESH process relaunched with `-state golden` — PIL diff bbox `None` against `gold-menu.png` |
| `rig/demo-01-after-b.png` (browser) | a real `page.keyboard` tap of `b` (~100 ms down/up) in the deployed SPA → clean `0 OK, 9000:2`, no stray `b` — confirms the fix on the visitor's actual input path, not just ctlsock |

Golden recaptured at the menu (same pixel source as the golden-fix stream's —
the menu frame itself is unchanged, only what a held key does afterward
differs): `SAVEST golden`, 11 ms, **11 922 bytes**, sha256
`884936e02f23c9a8c20d80e7ff503c48ae94951f41297f07caacb7a6cf0d0b55`. Staged to
`/data/vms/streamhost/stations/samcoupe/sta/samcoupe/golden.sta`; live
station reset via `labctl reset samcoupe` and reshot at the menu, clean.

Browser check also confirmed the deployed bundle was current
(`index-COVo6ODo.js`, matching `/data/vms/streamhost/serve/webroot/index.html`
at test time) and that the daemon's `input-router` `mamesock` counters
(`accepted` climbed ~460 during the run, `dropped=3 overflow=3` — both
**unchanged** from the pre-test baseline) show no new drops on the real
input path. The SPA's own "Type in a demo program" action (clicked via the
stage's ☰ Controls menu) was also exercised in the same session — **see
§OPEN**: its playback stalled on this run (a scattered/frozen frame, not the
expected concentric circles + `SAM COUPE 1989`), which is a finding to hand
to the `spa`/typist owner, not a regression from this stream's `auto.bas`
change — the `B`-press fix itself is proven on both ctlsock and the browser.

## Checkpoint

Captured on a sandbox rig (namespaced `/data/vms/sandbox/samcoupe-golden/rig/`,
never the station dir), 2026-09-08: cold boot the `mame-native` binary with the
media stream's `hive.mgt` attached (`-drive1 floppy -drive2 floppy -flop1
hive.mgt -state_directory $RIG/sta`, no `-state` yet), Enter to dismiss the MGT
copyright banner, type `BOOT`+Enter over `ctlsock` (18 key edges, 582 ms
burst), wait for the framebuffer to settle on the "KERNEL HIVE - SAM COUPE"
menu (`png/d-hivemenu.png`), then `ctlclient.py … SAVEST golden` (13 ms,
11 871 bytes → `$RIG/sta/samcoupe/golden.sta`, MAME's own nested layout — see
`x11-runtime.sh` line ~159). Restore proof: kill that process (env-checked
against its own `MAME_CTL_SOCK`), relaunch fresh with `-state golden` added to
the same argv, wait for settle (4.7 s including a 1 s pre-poll sleep),
`png/e-restored.png` diffs `None` (`PIL.ImageChops.difference` bbox) against
the baked frame.

Staged into the **future** station dir (not live — nothing runs there yet):
`/data/vms/streamhost/stations/samcoupe/sta/samcoupe/golden.sta`, 11 871
bytes, sha256 `987e84bc94c606645f5254787458f6d8ee6cd236bb9c4a5a79d311a1bfe14cae`.
`MAME_NATIVE_CHECKPOINT=1` in the fixture: the relaunch restore is proven
frame-identical, so a visitor's reset skips the banner/BOOT keying entirely.

**Recaptured by the `golden-fix` stream, 2026-09-08** (`/data/vms/sandbox/samcoupe-golden2/rig/`),
after the media disk was rebuilt with the `B` fix (menu selector table above):
same cold-boot → Enter → typed `BOOT`+Enter sequence, same
`png/d-hivemenu.png` pixel source (the menu frame itself is unchanged — only
what pressing `B` later does differs), `SAVEST golden` (11 ms, 11 921 bytes),
restore proof: fresh relaunch with `-state golden`, PIL diff bbox `None`
against the baked frame, 1.6 s. Staged over the same future station-dir path:
`/data/vms/streamhost/stations/samcoupe/sta/samcoupe/golden.sta`, now 11 921
bytes, sha256 `3fa0e14b77749aa1cce662cc1b6ee396f61f302d5d13519f750732390ff74b9e`.
`MAME_NATIVE_CHECKPOINT` stays `1`.

**Recaptured by the `menu-release` stream, 2026-09-08** (`/data/vms/sandbox/samcoupe-menu-release/rig/`),
after the media disk was rebuilt with the held-key-release wait (`auto.bas`
line 85, above): same cold-boot → Enter → typed `BOOT`+Enter sequence, same
menu pixel source (unchanged — only what a HELD key does afterward differs),
`SAVEST golden` (11 ms, 11 922 bytes), restore proof: fresh relaunch with
`-state golden`, PIL diff bbox `None` against the baked frame. Staged over
the SAME live station-dir path (this station is now LIVE, not future):
`/data/vms/streamhost/stations/samcoupe/sta/samcoupe/golden.sta`, now
**11 922 bytes**, sha256
`884936e02f23c9a8c20d80e7ff503c48ae94951f41297f07caacb7a6cf0d0b55`. The live
station was reset (`labctl reset samcoupe`, in-process LOADST) and reshot at
the menu — clean. `MAME_NATIVE_CHECKPOINT` stays `1`.

## OPEN items

- Pointer: the driver has a mouse device, but the station ships keyboard-only
  (`stream.pointer.transport: none`), as apple2e does — a relative-only mouse
  has no honest absolute contract yet.
- **`B` (SAM BASIC) keyboard path — FIXED by the `golden-fix` stream,
  2026-09-08**: the `STOP` statement was the cause (MAME samcoupe's BASIC
  opens the program-EDIT view on `STOP`, not the command line). `auto.bas`
  line 130 now `GOTO 9000`, with a trailing `9000 CLS : PRINT "SAM BASIC
  Type RUN to return to the menu"` that the program falls off the end of —
  ending a program normally reports `0 OK` at the command line instead.
  Proven on the real `ctlsock` `KEY` path from a fresh golden restore: `B` →
  `0 OK, 9000:2`, `PRINT 1+2` → `3`, `RUN` → back at the menu
  (`png/keyB-0ok.png`, `png/keyB-print123.png`, `png/keyB-run-menu.png`
  under `/data/vms/sandbox/samcoupe-golden2/rig/`). `2`/`3`/`4` were also
  each proven from a fresh restore to their title screens
  (`png/key2-mrpac.png`, `png/key3-splat.png`, `png/key4-secretary.png`) —
  all five menu entries are now verified end-to-end on the real input path.
- **A HELD `B` still leaked into the command line — FIXED by the
  `menu-release` stream, 2026-09-08**: the golden-fix above solved what a
  clean tap did (landed on `0 OK` instead of the editor); it did not solve a
  key still being DOWN when the menu program ended, which the ROM's next
  20 ms keyboard-scan frame read a second time straight into the fresh
  command line (`bNEW` when the visitor's browser tap outlived that frame,
  breaking the SPA's "Type in a demo program" flow, whose first line is
  `NEW`). `auto.bas` line 85 (`IF INKEY$<>"" THEN GO TO 85`) now blocks
  until the key is physically released. Proven on ctlsock (300 ms hold,
  `B` and `1`) and from a real browser tap — see the Proofs section above.
- **The SPA's demo-typing playback stalled on one real-browser run
  (menu-release stream, 2026-09-08)** — after clicking "Type in a demo
  program" from the stage's ☰ Controls menu, the guest frame showed a
  scattered/frozen partial line rather than the expected `NEW` → 8-line
  listing → `RUN` → concentric circles + `SAM COUPE 1989`, and did not
  progress across a further 20 s wait. The daemon's own `input-router`
  `mamesock` counters showed `dropped=3 overflow=3` **unchanged** across the
  run (only `accepted` climbed), so this does not look like the mamesock
  queue-overflow bug the coordinator flagged as already fixed in
  `index-COVo6ODo.js` — the bundle loaded WAS current. Not investigated
  further (out of this stream's ownership — `spa`/`museum`/`demoProgram`
  belongs to the `spa` stream); the live station was reset to a clean menu
  afterward. Worth a follow-up run with the daemon's per-station journal
  open live to see what the typist actually sent.

## Measured timeline

| Milestone | Wall clock | Minute |
|---|---|---|
| `wave.sh alloc` / ledger committed | | |
| `/os/samcoupe` viewable (smoke-rig.sh) | | |
| streams merged | | |
| landed | | |

## Teardown

(filled at landing)
