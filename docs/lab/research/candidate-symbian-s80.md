# Nokia Series 80 (Symbian OS) — candidate research

**Status: three research waves complete, 2026-09-24 to 2026-09-25.** The
first wave picked the route and fixed the window-server ABI wall; the second
proved the network socket stack end to end on the real ROM, made the
application keys switch between running apps, built a kiosk frontend with a
control socket, and scaffolded a real station; the third **closed the
network wall for good** — Opera fetches and renders a real host page on the
real ROM, and no network code beyond the second wave's was needed; the fix
was a window-server scheduling bug, not a network one — surveyed all 27
built-in apps (14 usable on the 9300, 15 on the 9300i), fixed the wall that
stopped a third app running alongside Desk, filled in Desk's main pane,
ported the ROM's own keyboard tables, and measured the station's fidelity
against a much larger real-device reference gallery. **`nokia9300` @
`49543e47`, pushed, not merged, dark-launched (hidden) at `/os/nokia9300`**
on the box; the operator has ruled it stays hidden until Desk is usable and
several or all built-in apps work. Media is staged on labhost under
`/data/assets-staging/symbian-s80/` (hashes below; the bits themselves are
museum-private and never enter the repo). The question this document
answers:
*which route puts a Nokia Communicator running Symbian OS Series 80 — the real
firmware, with its built-in Web browser, Documents and Sheet — into the gallery
as a fully featured station, and what are the walls on each route?* Hardest
problems first; every claim carries its source. A bring-up wave starts from the
plan at the end, not from this document's history.

## Operator decisions that shape this (2026-09-24 to 2026-09-25)

1. **The exhibit is the real Series 80 — real device firmware, built-in apps
   (the Opera-based Web browser, Documents, Sheet, Desk).** Running the Nokia SDK's
   Windows device emulator inside a kiosk-captured guest "is not enough".
2. **Adding a machine — CPU, SoC, board devices — to an emulator fork is
   approved**, as with `Wnt/qemu`, `Wnt/fs-uae`, `Wnt/previous`, `Wnt/iris` and the
   ES40 fork before. CPU/device specification research runs as part of this wave.
3. **The IM plane is not researched at this stage.** Hardest problems first; the
   ICQ/AIM client question is parked (§Featured-station plane records what is
   already known so nobody re-derives it).
4. **The target devices are the Nokia 9300 and 9300i.** Direction is chosen for
   them; the 9500 is a variant, the 9210 a later ambition. **Ready-made resources
   on related platforms are tested and made running first** — a known-good EKA1
   dump on EKA2L1 before the 9300 dump, QEMU's `sx1` (Siemens SX1, OMAP310,
   Symbian 6.1) before a `nokia9300` board — so a 9300 failure is attributable.
5. **The coordinating session coordinates only** (evening 2026-09-24): every
   build, spike, search and doc fold is delegated — mechanical work to Sonnet or
   Haiku, discovery and judgement to Opus 5.5 or Fable — and the coordinator
   relays facts between agents and commits what they cannot.
6. **Reverse-engineering the abandonware SDK and firmware for this
   interoperability work is approved, once and for all.** The operator's words:
   for abandonware in a private-collection museum "these kind of questions should
   not be even raised". The licence caveat recorded in §H2 is therefore
   historical, not a constraint. Two agents doing static disassembly were
   nevertheless stopped mid-task by the platform's own safety system; the wave
   re-routed to methods that reach the same facts — dynamic tracing of the real
   ROM client under the emulator (every logged request tied to a
   framebuffer-visible action), public EPL sources, prior work in forks, and
   Nokia's own SDK emulator run live in a Windows rig as an oracle for files and
   behaviour — and does not re-frame a stopped task to get around the stop.
7. **The station stays hidden until Desk is usable and several or all
   built-in apps work** (2026-09-25). The AGPL-licensed EKA2L1-WEB picks
   (§Prior work found) stay off the plain-GPL branches. Any SDK-derived
   material a station needs — the Series 80 UI's own TrueType fonts, the
   golden data dir's seed state — goes into the station's golden on
   labhost, never into the repo, same as the ROM and SDK media already
   staged (§H2).

## What the exhibit is

The **Nokia 9300 / 9300i Communicator (2004–2005)** — Symbian OS 7.0s with the
Series 80 v2 UI: a clamshell that opens into a 640x200 landscape screen and a
full QWERTY keyboard, four command buttons beside the screen that select the
on-screen command labels, the Desk view of application icons, and the business
suite (Web, Messaging, Documents, Sheet, Presentations, Calendar, Contacts) that
made "smartphone" mean a pocket office before the iPhone reset the word. The
**9500** is the same platform in the larger body, with WLAN; the ancestor
**Nokia 9210 (2001)** — Symbian OS 6.0, Series 80 v1 ("Crystal") — is the first
Symbian OS phone sold. Any of them fills the museum's "pre-iPhone smartphone"
gap named in [`docs/catalog/os-media-catalog.md`](../../catalog/os-media-catalog.md);
the operator's target is the 9300/9300i. There is **no touchscreen** on any
Series 80 device: the station is keyboard-driven, and the pointer question is
unlike every other station in the fleet.

Lineage neighbours already live: `palmos` (the stylus organiser the Communicator
competed with), `pcgeos` (the Nokia 9110's GEOS is a sibling of the PC/GEOS
station), `sailfishos` and `android` (what came after).

| Device | Nokia type | OS | UI | Application CPU | Screen |
|---|---|---|---|---|---|
| 9210 / 9210i (9290 = US) | RAE-3 / RAE-5 | Symbian OS 6.0 / 6.1 | Series 80 v1 "Crystal" | "ARM9-based RISC, 52 MHz" — SoC not yet identified (§Route 6) | 640x200, 4096 colours |
| 9300 (9300b = US) | RAE-6 (RA-4) | Symbian OS 7.0s | Series 80 v2 | TI OMAP 1510, ARM925T @ 150 MHz, 64 MiB RAM | 640x200 |
| 9300i | RA-8 | Symbian OS 7.0s | Series 80 v2 | same | 640x200 |
| 9500 | RA-2 ("Erin") | Symbian OS 7.0s | Series 80 v2 | same; first Nokia with WLAN | 640x200 |

Type codes verified against Wikipedia label photographs, service-manual titles,
the archive.org `Nokia_DCT4_firmwares` folder names and EKA2L1's device table
(agent B). All five run Symbian's **EKA1** kernel — EKA2 first shipped in
Symbian OS 8.1b (agent D).

## The hardest problems, in order

### H1 — Executing the firmware at all

Two emulators can, in principle, run Series 80 v2 code; nothing exists for the
hardware today.

- **EKA2L1** (github.com/EKA2L1/EKA2L1, GPL-3.0-or-later, C++17, Qt 6 frontend,
  dynarmic JIT) is a *high-level* emulator: it reimplements the kernel and
  system servers and runs the ROM's user-side binaries. Its **Series 80 v2
  support is real but experimental**: PRs #473 "S80 branch" (merged 2023-03-24)
  and #475 "S80 first experimental use" (2023-04-03), built around a Nokia 9300
  dump; commit `6e3f90b7` (2023-04-04) added RA-2 and RA-8 to
  `S80_DEVICES_FIRMCODE` (`src/emu/system/src/devices.cpp:150`). It gives those
  devices a 640x200 default screen (`window.cpp:1471`), the S80 256-colour
  palette, EKA1 page-table injection, `ekeyb`/video LDDs and a two-key remap. No
  S80-specific commit since 2023-04-06. The project's own tracking issue #382
  still leaves S80 unchecked; the "supports S80" wording in the lab catalogue
  came from the Emulation General wiki, not from the project. **It launches
  individual applications (`--run <caption|0xUID|path>`), it does not boot the OS
  to Desk, and there is no savestate.** The only public evidence of anything
  running is five games "In-Game" on Windows (community wiki, 2026-06-03); no
  productivity app is listed. **Series 80 v1 (9210) is not supported**: only
  version detection exists (`series80v10.sis` → `epocver::epoc6`, the S60v1
  class), RAE-3/RAE-5 are absent from the firmcode list. (Agent A, from the
  source at `39858137e`, 2026-09-23.)
- **Full-system emulation**: no emulator models any Communicator. MAME's
  `src/mame/nokia/` holds the MikroMikko, the d-box and a `nokia_3310` skeleton;
  its EPOC relatives `psion7.cpp` (SA-1100 netBook) and `psion5mx.cpp` are
  `MACHINE_NOT_WORKING`; MAME has no ARM925T, no OMAP and no C55x. QEMU has the
  OMAP1 family: ~8.6k lines in `hw/arm/omap1.c` and friends, the `ti925t` CPU,
  and the `sx1` board (Siemens SX1, OMAP310) — the last OMAP1 board standing
  after `cheetah`, `n800` and `n810` were removed in QEMU 9.2. **QEMU has only
  `omap310_mpu_init`**; the OMAP1510 remnants in the tree are dead code that
  upstream has been deleting since 2026-05 (including the `omap_mpuio_key()`
  keypad API), so a board is built on the lab fork's v11.0 base. (Agents D, K,
  M.) The CPU/SoC coverage matrix and the board map are in §Route 2.

**The spike (agent S, Fable, real 9300 / 9300i / 9500 ROMs on the dev box,
Xvfb + llvmpipe).** Device registration works with a hand-written `devices.yml`
(format from `devices.cpp`), lowercased Z trees, a Python RPK2 extractor for
the 9300's `SYM.RPKG`, one `XDG_DATA_HOME` per device (the 9300i ships
`Dev9300.sis` and would collide), and `hide-system-apps: false` (every ROM app
counts as a system app). The emulator then **enumerates all 23 built-in
Communicator apps** (Documents, Sheet, Web, Contacts, Messaging, …; Desk is not
registered as an app — it is launched by `Startup.app`). But **every `--run` of
Documents, Web or Desk segfaults the host ~1.5 s after the window opens
(exit 139, 4/4, before a single guest pixel)** and Sheet stays a black 640x200
letterbox at 0 FPS after `Unhandled FBScli opcode 0x6`; identical on all three
ROMs. The pipeline is not the cause: the same binary on the same Xvfb painted an
N-Gage Notepad (control). Where it works, cost is small: shell ready in ~1.5 s,
~1% of a core idle, 112–167 MB RSS. Traps: "Rescan devices" deletes hand-placed
trees; `eka2l1_qt` ignores SIGTERM. Frames: `S/run2-f02-1.4s.png` (the 9300's
app registry), `S/run4-f03-2.9s.png` (Sheet black), `S/run17-f03-3.6s.png`
(N-Gage control) in the session tmp dir.

**The cause, verified in bytes, and the fix landed (agent U's ABI diagnosis,
agent F1's fix spike, Fable, 2026-09-24).** The S80 SDK's `WS32.DLL` reports
`TVersion(1,0,151)`. F1 re-derived the table from the DLL bytes directly (a
COFF-import/PE-export walk of `WS32.DLL` and `FBSCLI.DLL`, not U's excerpt) and
found the S80 window opcode table is **+1 from `Size` 0x0c** (S80 has no
`AbsPosition` at 0x0c — exactly the build-139/6.1 shift EKA2L1's
`legacy_opcodes()` already applies) and **+2 from `GetDisplayMode` 0x61** (S80
also has no `SendAdvancedPointerEvent` at 0x62 — the shift EKA2L1's
`window_opcode()` already applies for build ≤ 151). U's "+1, then −1, then
realigned" excerpt was wrong in the upper range; the fix is a predicate
(`s80_opcodes()`, `os_ == epoc7 && build == 151`) joining the existing
`legacy_opcodes()` rule, not a new table. The **session opcode table matches
EKA2L1's modern enum exactly**. The **graphics-context table equals the
build-139 table** (`gcop.def` `u139`), already selected correctly for S80 —
`SetBrushOrigin`/`UseBrushPattern`/`DiscardBrushPattern` (14/15/16) are present
in the table but have no handler, which is what U's and S's "unimplemented
opcode 14/15/16" spam actually was. **FBSCLI was already translated** by
`fbscli::fetch()` for `< eka2`; S's `Unhandled FBScli opcode 0x6` was not a
table bug — `FontHeightInTwips` (opcode 6) was simply unimplemented, and the
never-completed call parked Sheet's guest thread forever. The crash itself
(`canvas_base::inquire_offset → dsa::~dsa → screen::deref_dsa_usage`) was a
`reinterpret_cast` of a client handle: a DSA handle's vtable landing in
`dsa::~dsa`, fixed by `dynamic_cast`-with-kind-check at five previously
unchecked `get_object()` casts (window/group/sprite/screen-device creation,
DSA request). Opera additionally panicked on an unanswered POSIX `PMstat`
(0x17) call — a `stat`-by-path handler fixed it.

**Result, on the real 9300 (RAE-6) firmware, 2026-09-24: Documents paints its
editor at 2.8 s and accepts typed digits (7 FPS); Sheet paints its A–H × 1–7
grid with cell cursor and formula bar; Desk paints the Communicator shell (Desk
icon, "Open / Write note / Note list" buttons) at 3.5 s and idles at 2 % CPU;
Web (Opera) paints its page area, address field and "Open Web address / Back /
Bookmarks / Exit" column at 5.4 s.** Four commits on branch `s80-epoc7-tables`,
pushed to the fork `https://github.com/Wnt/EKA2L1`. Leftovers, per F1, all since
resolved: "Documents and Sheet each burn one core at settle" was the same
zero-area-window redraw spin fixed below (§H7); the build-139 GC table's
missing brush-op handlers (14/15/16/20/43) are the cause of the black title
bars and status panes noted in the integration plan's fidelity section; the
S80 keymap now has a real, frame-proven translation (§H4, agent K1). **The
7.0s socket table + `RConnection` (§H3) landed the same evening**, and a later
wave closed the network wall for good: Opera fetches and renders a real host
page on the real ROM, with no further network code needed at all — see §H3.

### H2 — The bits — SOLVED for the 9500/9300, OPEN for the 9210

Everything below is on labhost, hash-verified; nothing is committed.

- **Ready-made EKA2L1 dumps** for the **9500 (RA-2), 9300i (RA-8) and 9300
  (RAE-6)** from the Dumbphone Repository (romphonix.org, offline; its MEGA mirror
  is live and linked from `archive.org/download/romphonix/readme.txt`; the EKA2L1
  category was added 2023-10-30, the 9300i/9500 dumps 2023-11-06 by gtrxAC).
  Each is a 7z: `9500.rom` 18,874,368 B + a `9500_Z/` tree (3,039 entries incl.
  `System/Install/Dev9500.sis`, `Series80v20.sis`); `9300i.rom` 18,874,368 B +
  `9300i_Z/` (ships `Dev9300.sis`); `9300.rom` 17,825,792 B + `SYM.RPKG`
  46,937,757 B (EKA2L1's own Z: package). Staged under
  `/data/assets-staging/symbian-s80/eka2l1-dumps/` as MEGA-encrypted blobs
  (`*.mega-enc`; one `openssl enc -d -aes-128-ctr` each — the keys live only in
  the session report, never here). The 7z headers were decoded remotely to prove
  the keys and produce full listings before any payload was fetched. (Agent B.)
  Firmware version and language of the dumps: unknown until read from the ROM.
- **Official Nokia service firmware for all five phones**, curl-fetchable from
  archive.org (`Nokia_DCT4_firmwares`, `nokia-phone-firmwares`, `nokia-9210-arch`):
  9500 `RA-2_v_45.1_CCS_emea.exe` 104,913,247 B and `RA2_522.7_1.0.exe`; 9300
  `RAE-6_5.1_CCS_emea.exe` 102,170,190 B and dp 6.0; 9300i
  `…RA-8_EMEA_2.1_ccs.exe` 49,079,138 B; 9210 `Rae3_mcu_v4.13.zip` 46,942,903 B
  (`RAE33004.130` 14,376,757 B + 21 language files); 9210i `RAE-5.zip`
  29,923,101 B (`RAE53006.000` 16,676,623 B + 21 language files). Staged under
  `/data/assets-staging/symbian-s80/firmware/<device>/` with sha256 in agent B's
  table. **EKA2L1 cannot load any of these**: its firmware installer takes only
  BB5-era VPL+FPSX; the 2005 packages are InstallShield self-extractors whose
  flash-file names are still unknown (`7z l -t#` shows the wrapper only); the
  9210 files are DCT4-era MCU images. **For the 9300/9500 the service package IS
  a ROM source** (agent J, verified on the bytes): the `*_dp_*` InstallShield
  packages unpack (`7z x -t#`, then `unshield`), and the APE core file
  `RAE6n4530.C01` (31.5 MB, header `001C22120404.53(00)`) is a Nokia record
  container whose record 1 is **raw deflate at offset 0x61** inflating to
  **16,973,824 B — a valid EKA1 XIP ROM**: `iRomBase 0x50000000`, `iRomSize
  0x01100000`, hardware variant `0x09080001`, kernel data `0x80000000`, **900
  files**; the RA-2 core matches (`001C27100404.44(01)`, 17,571,840 B, 919
  files). The same container holds a raw **ROFS** image (~19.7 MB on RA-2); the
  `.L<nnn>` files are **ROFS extensions** (`ROFx`, language/operator content)
  and the `.U<nnn>` file is a **FAT16** default C: (OEM id `EPOC`); the
  `RAE6_h56pr3.060` is the CMT (GSM processor) image. Z: on the device is
  core XIP ROM + ROFS core + ROFS variant. The newer `RA-8_*.exe` (9300i) and
  `RAE-6_APAC_7.0` wrappers did not open with 7z/unshield — the older `*_dp_*`
  packages do. J's extraction lives in the session tmp dir (`J/`). **No public
  tool converts the 9210's DCT4 MCU images** (`RAE33004.130`) to a ROM; a
  TRomHeader carve-out is plausible but untried.
- **The Nokia SDKs**, all from archive.org (`nokia_sdks_n_dev_tools`,
  `nokia_sdks_n_dev_tools3`; the mega.nz route the first pass found was never
  needed), staged under `/data/assets-staging/symbian-s80/sdk/`:
  `Nokia_9200_Communicator_Series_SDK_1_2_Installer.zip` 250,723,198 B
  (sha256 `78c7e202…c536db`, Series 80 v1, Symbian OS 6.0), `S80_DP_2_0_SDK.zip`
  131,052,274 B (`f07c5e3b…1b23fad`, Series 80 v2 C++ Edition, January 2005),
  `S80_DP_2_0_PP_SDK.zip` 154,099,386 B (`7c9dee30…7ed5e30c9`, Personal Profile
  Java edition). Their InstallShield cabs (`ISc(` signature — neither 7z nor
  cabextract opens them) were extracted with a statically built `unshield` 1.6.2
  left at `…/sdk/unshield-static`; trees at `…/sdk/extract-*`. **Both emulator
  ROMs carry the Opera browser as a real installed app** (`z/system/apps/opera/`
  + live `Opera.ini` state), plus CWORD (Documents), SHEET, AGENDA, Desk,
  Messaging; the 9210 SDK also has the original `web/WEB.APP`, `TERMINAL`,
  `INTERNET`. `epoc32/include/e32keys.h` and the two `epoc.ini` files (skin
  geometry as `VirtualKey EStdKeyDevice0-3 / EStdKeyApplication0-7 rect x,y w,h`)
  are the best public reference for the Communicator's key model. The EULA
  (identical in both SDKs) is single-computer, no redistribution, no reverse
  engineering; the operator ruled on 2026-09-24 that for this abandonware the
  question is not raised (§Operator decisions 6) — the SDK's WINS `WS32.DLL`
  was the byte-level oracle for F1's window-server table, and the SDK emulator
  itself runs live under a debugger in a win11 rig clone as a dynamic IPC
  oracle (agent X1): x32dbg logs every `RSessionBase::DoSendReceive` and
  `CreateSession` call with server name, opcode, the four IPC arguments and
  the calling DLL, resolved through a symbol map built from each DLL's COFF
  import/export library (§H7 has the boot-order and app-key findings this
  produced). (Agents C, H.)

### H3 — The network plane — CLOSED

- **The network wall is closed.** Opera 6.0, running the real 9300 ROM under
  EKA2L1, fetches a page from a host server on "Go to" and renders it —
  heading, body text, a coloured table, the page title in the title bar.
  **No new network code was needed to close it.** EKA2L1 reimplements ESock
  as host sockets; the 7.0s client opcode table bug
  (`socket_client_session::is_oldarch()` gating on the wrong firmware
  generation, so `RConnection::Open` parked forever) and the
  `RConnection::Start` EKA1 CommDB fallback (branches `s80-esock-70s`,
  `s80-commdb`) already made every ESock/CommDB call Opera or PuTTY issues
  return `KErrNone`. What was still missing turned out to be a
  **window-server scheduling bug, not a network bug**: a zero-area window's
  invalid rectangle could never be cleared, so the Web thread's redraw
  active object stayed permanently ready and starved every lower-priority
  active object in the same thread — including the HTTP framework's
  continuation after `Start`. Fixed by `s80-wserv-leftovers` (W2); the whole
  station fix is `s80-esock-70s` + `s80-wserv-leftovers`, nothing more. Two
  independent EKA1 clients confirm the mechanism is generic, not
  Opera-specific: a synthetic priority-100 spinner parks and releases the
  ROM's own HTTP framework on command, and PuTTY for Series 80 v2 was
  starved the identical way at an even lower priority. Full opcode table,
  IPC evidence, the proof toolchain, the PuTTY confirmation and an optional
  CommDB patch-DLL for a fidelity-grade Control panel:
  [`candidate-symbian-s80-network.md`](candidate-symbian-s80-network.md).
- **Still open: Opera's home page does not load at startup.** The visitor
  path today is "Open Web address" → "History list" → "Go to", which works
  end to end. The likely cause, in progress, is a ViewServer message-layout
  mismatch: the HLE parses a later-firmware 16-byte `ActivateView` layout
  while the ROM sends an 8-byte one (agent N7). Detail in the network
  document and in
  [`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md).
- **A QEMU board** inherits the opposite problem: the guest has no Ethernet.
  Series 80 v2's bearers (agent Y, checked in the SDK and the device firmware):
  data calls and GPRS through the baseband, WLAN (9300i/9500 only), and **USB
  "IP passthrough" (RNDIS)** — the USB driver's resource lists a "Nokia 9300i
  (RNDIS)" mode, the user guide documents the Cable setup, and a DHCP client is
  on the device; Bluetooth has no PAN (DUN makes the Communicator the modem),
  IrDA has no IrLAN, and the device firmware lacks the emulator-only Ethernet
  NIF, SLIP, `ntras` and the Hayes `MM.TSY` — so plain PPP over a UART is
  blocked. Ranked: **1. USB IP passthrough** — one new block (QEMU lists the
  OMAP USB function controller W2FC as unimplemented), the rest is documented
  protocol, retronet supplies DHCP and DNS; open risk: the "cable plugged"
  signal may come from the baseband over XBUS. **2. GPRS/data call through the
  fake baseband peer** — no new hardware (the peer must exist for boot anyway)
  but the most proprietary RE. First proof: the Connection manager showing IP
  passthrough with a retronet address, then the Opera page.
- **The lab side** exists and is proven: proxy-first corpus web on the gateway
  (`docs/lab/retronet/WEB-PROXY.md`), OSCAR at the gateway's port 5190 serving
  ICQ 2000b/2001b-era clients plus the Mirabilis v5 UDP door, no MSN, **no email
  server** ("parking lot" in `RETRONET-BRIEF.md`) — so the Communicator's
  strongest app, Messaging, has nothing to talk to until the lab stands one up.
  (Agent E.)

### H4 — Input: a keyboard-only device in a pointer-first museum

- The real key model (Series 80 v2): a full QWERTY, **four command buttons**
  beside the screen driving the on-screen command labels (`EStdKeyDevice0-3` in
  the SDK's `epoc.ini`), eight application keys (`EStdKeyApplication0-7`: Desk,
  Tel, Messaging, Web, Contacts, Documents, Calendar, My own), Menu, Chr, an
  arrow pad, Enter, Esc; no touch. The 9210 has the same shape with a different
  fascia (`9210Small.bmp`). (Agents E, H.)
- **EKA2L1**: it never loads the ROM's EKTRAN/EKDATA, and its
  scancode→keycode path was a fixed table with no modifiers
  (`epoc::map_scancode_to_keycode`, `services/src/window/common.cpp:234`),
  so Shift/Ctrl/Chr did nothing and letters were unbound in the default
  bindings — until this wave. The ROM ships `ekdata.dll` + 15 per-language
  `ekdata.NN.dll`, whose format and translation algorithm are public EPL
  source (`k32keys.h`, `ky_tran.cpp`); the window server loads `EKDATA`
  then `EKDATA.NN` from HAL `EKeyboardIndex`; Chr-hold accent cycling is an
  in-guest FEP (`Cycling_fep.fep`). **Proven (agent K1, branch
  `s80-keymap`, being pushed as of 2026-09-25 05:00 UTC):** a host-side
  port of the ROM's own EKTRAN/EKDATA tables and modifier machine,
  frame-proven for mixed case, digits, punctuation including € and Ä/ö,
  Chr-key accent cycling in the ROM's own order, "Insert character" on a
  held Chr, Enter, key repeat, the Menu key opening menus, and formula
  entry in Sheet. A stopgap bindings branch, `s80-bindings-stopgap`, is
  already proven and pushed for anyone who needs a working keymap before
  `s80-keymap` lands. **Keymap contract v1:** F1–F4 = command buttons,
  F5–F12 = application keys (Desk, Telephone, Messaging, Web, Contacts,
  Documents, Calendar, My own), Menu, F13 = joystick centre, F14–F17 =
  joystick, `ISO_Level3_Shift` = Chr, printable characters as themselves.
  **Capture bug:** EKA2L1 never delivers captured keys (`io.cpp:198`
  indexes capture requests by a key code that is always 0; `CaptureLongKey`
  unhandled) — fixed by agent B1. (Agent R1.)
- **The museum side is proven**: the SPA's shared on-screen keyboard
  (`spa/src/ui/keyboard/OnScreenKeyboard.tsx`, families in
  `keyboardProfiles.data.exotic.ts` — `armeval`'s LIST/RUN row, `alto`'s
  BRAVO/DRAW, `plus4`'s app-switch row) is exactly a "click a labelled soft key →
  keysym" mechanism; a `nokia9500` family with the four command buttons and the
  application keys is a same-shape addition. `SH_KEY_REMAP` (proven on `mpf2`)
  rewrites scancodes the PC keyboard cannot send. Keyboard-only pacing rules are
  in `ADD-NEW-OS-PLAYBOOK.md` §5.1. `stream.pointer.present` is read only by the
  admin `/fleet` table (`spa/src/ui/fleetColumns.tsx`), so a pointerless station
  needs the 3D desk prop, the first-input listener and the keyboard profile
  touched by hand. (Agents E, F — citations verified.)

### H5 — Reset

- **EKA2L1**: no savestate; no OS boot, so a reset is `kill` + restore a pristine
  `data/drives/{c,d}/` + relaunch `eka2l1_qt --device RA-2 --run <app>
  --fullscreen`. Time to a usable app is unmeasured (§H1 spike). CRIU is not an
  option in the nspawn sandbox this station must run in: the
  `--system-call-filter=~@mount` that contains a host application is what breaks
  CRIU's userns restore on `perq` (`docs/guests/perq.md`, criu 4.1.1,
  `namespaces.c:235`), and the operator-level fix (dropping `~@mount`) is still
  an open decision. (Agents A, F; memory `nspawn-criu-reset-blocked-by-seccomp`.)
- **QEMU board**: `savevm`/`loadvm` golden as on every Tier 1 station — with the
  cost that every new device model must implement vmstate before the first
  golden, and the museum rule that golden + binary + device set are one
  combination.

### H6 — Host-native integration and rendering

- **EKA2L1** is a Qt 6 + OpenGL desktop app (GLX core context 4.6→3.0,
  `#version 140` shaders; no bundled libGL — the host's Mesa). **It starts on the
  GPU-less dev box under Xvfb + llvmpipe**: `Created a GLX context with version
  4.5`, the device-install wizard rendered (agent A, screenshot
  `A-eka2l1-xvfb.png` in the session tmp dir). The AppImage needs
  `--appimage-extract` (no FUSE in CT950). Software GL under a sandboxed Xvfb,
  X11-root-captured, is live in production on `amix`
  (`streamhost/stations/amix/x11-runtime.sh:139`, `LIBGL_ALWAYS_SOFTWARE=1`);
  Qt's `xcb` platform plugin on top of it has no station precedent (RPCEmu/Qt5
  in `docs/guests/riscos.md` was built but never wired into a launcher). **The
  cost risk is measured elsewhere**: `indyr4400`'s llvmpipe-under-Xvfb theory ran
  an idle 4Dwm desktop at 356% of 4 vCPUs
  (`docs/lab/SESSION-HANDOVER-2026-08-10-trixie.md:297`) and the station shipped a
  native shm fork (`Wnt/iris`) instead. A 640x200 keyboard UI redraws far less,
  but measure before believing it. Every start also makes three update-check
  requests to api.github.com (`update_dialog.cpp:63`, `BUILD_FOR_USER`) — a fork
  build or a route-less netns removes that. The fork work a shipping station
  would need: a headless/shm framebuffer frontend (the `headless` WSI enum exists
  but is unwired), an input socket for scancodes, the S80 QWERTY keymap, a
  device-install CLI (install is GUI-only today). (Agents A, F.)
- **The sandbox shape is proven four times** (lisa, perq, medley, vision):
  systemd-nspawn with private PID/mount/net/IPC/UTS/user namespaces, read-only
  rootfs, X socket bound out, `resetMode=relaunch`, XTEST keys
  (`SH_INPUT_BACKEND=x11test`), `SH_CAPTURE=x11`. Scaffold `--like lisa`
  (one prebuilt Linux GUI binary, no headless mode). No nspawn station has a
  retronet interface yet — all four run `--private-network`. (Agent F.)
- **QEMU board**: standard Tier 1 integration (dbus fast-poll display,
  `gallery-hid`, QMP), a foreign-arch build like `macos753`/`aix432`
  (`qemu-system-ppc`) — here `--target-list=arm-softmmu` in the `Wnt/qemu`
  fork, pinned per station via `qemuBuild.forkCommit`, with the board as patch
  0009+ of `streamhost/qemu-patches/`.

### H7 — The shell: Desk, application keys, task switching

- **Who owns what** (ROM, verified in the bytes and independently confirmed
  live against Nokia's own SDK emulator; agents R1, B1, X1). The application
  keys are handled by the ROM's EikSrv UI part (`eiksrvui.dll`, a generic
  App0+i handler — confirmed by B1's own import cross-reference of the ROM
  binaries); `SysAp` (UID `0x101F6E33`) captures the Desk key (`0xF852`) and
  the My-own key (`0xF859`); `Startup.app` captures those two plus Menu
  during its first-boot language wizard — skipped once
  `C:\System\SharedData\10000865.ini` has `LanguageSelectionDone=1` (with
  that file missing altogether, as on an earlier C: state, the wizard could
  grab the application keys for itself instead). S80's EikSrv client
  opcodes: 1 LaunchTaskList, 2 CycleTasks, 3/4 AddToStack/RemoveFromStack,
  7 SetStatusPaneLayout. **Nokia's own Series 80 v2 SDK emulator, traced
  live under a debugger as a dynamic oracle** (agent X1; method in §H2),
  confirms the shape independently: a real boot creates 36 servers in a
  fixed order (File Server through Sdp — EikSrv is item 22,
  "HandleStartEikon", in Starter's own list), and an application key is
  handled by the Eikon server's own thread, which calls the AppList
  server's op 5 with the app's UID and then op 7; the new app's thread then
  opens its own `EikAppUiServer` session — the same shape B1's HLE gives it
  below. Full boot order and IPC traces:
  [`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md).
- **The application keys now switch apps, proven on the real ROM** (agent
  B1, fork branch **`s80-shell` @ `19308cbd0`**, three commits on F1's
  `s80-epoc7-tables`). Before this wave EKA2L1 replaced EikSrv with an HLE
  stub that owned none of these keys; a window-server handler now swallows
  scancodes 0xB4–0xBB on an S80 device — as the focused app never sees them
  on the real device either — and brings the bound app's window group to
  front, launching it first if it is not already running: Desk
  `0x101F8E4F`, Telephone `0x101F4D0B`, Messaging `0x100053B3`, Web
  `0x101F4DE8`, Contacts `0x100007ED`, Documents `0x10003A64`, Calendar
  `0x10003A5C`, My own `0x100007BA` (File manager, the ROM's factory
  default). Proven end to end: Desk → Documents → Desk → Web → Desk, each
  switch keeping the target app's own state (typed text stays in Documents
  across every switch away and back); three `apprun` processes (Desk,
  Documents, Opera) stayed alive together at 26 % CPU. The handler steps
  aside the moment any guest holds a real key capture on one of these
  scancodes, so a ROM Eikon server can take the buttons over with no
  further code change — using the capture-delivery fix already noted in
  §H4, now proven end to end by this switch, and independently the same
  shape as EKA2L1-WEB's key-capture rewrite (§Prior work found).
  `CaptureLongKey` (Menu held = task list) stays unhandled; it belongs with
  the ROM EikSrv thread once that boots, next.
- **The ROM's real Eikon server is the fidelity thread, and a fuller boot
  now reaches further into it.** `EKA2L1_ROM_EIKSRV=1` skips the HLE
  app-key handler, Notifier and ViewServer straight to the ROM's own
  `eiksrvs.exe`, which creates `EikAppUiServer`, `ViewServer`,
  `AlarmServer` and `AlarmAlertServer` — but Desk's guest area never paints
  behind it, and what its thread is waiting on was not identified from
  this shortcut alone. **The chosen architecture in the meantime**: the
  ROM's import tables show Starter, SysAp and `Startup.app` all reaching
  the DOS server, whose `Nokia.dsy` needs the CMT-over-ISA phone link
  (absent in EKA2L1; Nokia's own SDK swapped in an `ExampleDSY` for the
  same reason) — while EikSrv and Desk do not import it. So the station
  runs the ROM's **real EikSrv + Desk with no Starter/SysAp**, and the
  emulator supplies only the Desk/My-own key behaviour host-side, as
  above. EKA1's `server_create` has no duplicate-name check (confirmed
  still true by Y2's sweep, §Prior work found), so a native EikSrv would
  silently coexist with the HLE stub unless the stub is skipped for S80 —
  the guard to add before trusting a native boot. A separate effort now
  builds an HLE DOS server so the ROM's own `Starter.exe` chain can run
  instead of this shortcut, and reaches through `eiksrvs` before stalling
  on a new, concrete, named wall (agent B5, branch `s80-hle-dos`) — detail
  in [`candidate-symbian-s80-shell.md`](candidate-symbian-s80-shell.md).
- **Two walls stood here; both are now resolved.** A third app launched
  alongside Desk and one other used to never finish constructing its UI —
  it connected to every server, got its skin-server completions, and then
  issued nothing more. **RESOLVED** (agent B4, frame-proven): EKA1's
  `RMutex::CreateGlobal` silently succeeded on a duplicate name instead of
  returning `KErrAlreadyExists` (unlike semaphores, which already reject
  one), so every app that constructed its UI created and owned its own
  skin server instead of sharing the first one's. With two mutex fixes
  plus the redraw-spin fix below, **Desk, Documents and Web now run
  together, switch by application key, and keep each app's own state**
  (branch `s80-third-app`, pending push as of 2026-09-25 05:00 UTC). Desk's
  main content pane — Desk's own chrome (icon, CBA labels) was always
  fine, but the AppList server's contribution was missing — is
  **RESOLVED** too (agent B6, branch `s80-desk-content` @ `1d49e15a6`):
  Desk now shows its date header, wallpaper, focus bar, and the Clock and
  nokia.com icons, and opens a group (Personal: Telephone, Contacts,
  Messaging, Calendar). Both are detailed in the shell document. What is
  still missing from the shell plane: the ROM's real Eikon server paints
  no Desk of its own yet (above), `CaptureLongKey` (Menu held = task list)
  stays unhandled, and Opera's home page does not load at startup — traced
  to a ViewServer message-layout mismatch that may also explain the File
  manager, Notes and Sync walls in the app-coverage table below (agent N7,
  in progress).
- **The Documents/Sheet/Web idle-CPU loop is fixed, and independently
  reconfirmed three times over.** The "pending native-server receive"
  theory was ruled out (agent Y2, §Prior work found). The actual cause, per
  F1: a redraw loop on a zero-area window — the region code admitted a
  0-width rect and `intersect` never subtracted it, so the client redrew
  150–900 times/s and the redraw store grew without bound. The fix (branch
  `s80-wserv-leftovers`, commit `7e6564ac6`, agent W2) makes the region
  ignore zero-area rects, clips invalidation, and drops empty redraw
  segments. Three unrelated EKA1 clients each prove it independently: it is
  what finally let Opera's HTTP continuation run (§H3), what let PuTTY's
  connect flow run at all, and — together with the mutex fixes above —
  part of what lets a third app run alongside Desk without starving.

## Routes

**Recommendation (2026-09-24, after F1):** Route 1 — the EKA2L1 fork with the real 9300 firmware — is the route for the interactive station. The window-server opcode table was the wall; with it fixed, Documents, Sheet, Desk and Web all paint from the real ROM on the dev box, and the remaining work (keymap, shell/app keys, 7.0s socket server, kiosk frontend, station integration) is engineering in known code, days not weeks. Route 2 — the QEMU `nokia9300` board — stays the fidelity upgrade: the RAE-6 ROM already boots its EKA1 kernel to a running 64 Hz tick and UART3 output on the fork's board, but it stalls in kernel-extension start-up before the file server, and the phone-side (XBUS/ISI) and flash (mDOC) layers are still weeks of work.

### Route 1 — EKA2L1 + real ROM, host-native in nspawn

The fast path to the real firmware's applications — **days, not weeks — if the
Symbian 7.0s ABI tables land** (§H1: window server; §H3: sockets). Facts: §H1,
§H3–H7. What it is *not*: a boot of the OS — the Desk shell, task switching and
the system servers are EKA2L1's reimplementations, so fidelity is per-app and
bugs are HLE bugs (the fork inherits them; the upstream is active, 2,020 stars,
commits through 2026-09-23, GPL-3). Fork plan, in order (U's ranking): the S80
window-server table (+ GC/FBSCLI byte-check) → Documents paints; boot list
(SysAp, `Startup.app`, prestarted apps) → Desk with switching; Communicator
keymap + modifiers; the 7.0s socket table + RConnection → Opera on retronet;
the frontend items (shm output, input socket, install CLI, no update check)
→ a station. Cost model: a Qt/GL process per station under llvmpipe (~1% of a
core idle at the shell) until the shm frontend replaces Qt. The 9300 dump is
firmware 5.22 build 7 (2005-11-16), the 9300i's 6.27 (2006-07-19) — the 9300i
adds the WLAN stack, T9 and `Hci.dll` (agent X).

**Build facts (agent V, Opus).** Builds from source on CT950 (Ubuntu 24.04,
GCC 13, C++20, Qt 6.4.2 from the CI's own apt list minus `pulseaudio`);
configure takes 116 s; a cold build takes 1418 s under a 30–104 host load at
`-j5` then `-j10`, all ccache misses on a fresh tree. `mold` relinks the final
binary in 1.02 s versus 5.35 s for `bfd`. `--help` hangs after printing its
usage — the exit path never sets `init_event` in `thread.cpp`, a one-line
upstream fix. Configure re-clones `libuv` from GitHub every time unless
overridden. Two instances sharing the default data dir overwrite each other's
`scripts/` and `resources/` — stations need per-instance XDG dirs. The fork's
patch map: a headless branch belongs in `make_gl_context()`
(`drivers/src/graphics/context.cpp`), the frame grab goes in the
`set_display_hook` callback (`qt/src/thread.cpp:185-201`), input goes through
`winserv->queue_input_from_driver()`, and a device-install CLI should be
modelled on the Android frontend's `launcher::install_device()`.

**The Windows build brings nothing extra (agent Z1, Opus).** The upstream
Windows build, run in a `win11` rig clone (needs the VC++ runtime and Mesa
llvmpipe for a GL ≥ 3 context), fails **identically** on the 9300 dump:
Documents, Desk, Web and Clock crash 1–3 s after launch, Sheet stays a black
640×200 band at 0 FPS, and the log tails end on the same lines as the Linux
runs. So the fault was EKA2L1's S80 opcode tables, not anything Linux-specific
— confirmed before F1's fix landed.

**Prior work found (G1/G2, 2026-09-24).** No public repository boots a
Series 80 ROM to Desk or has an S80 window-server/socket/keymap/SysAp
implementation — 191 EKA2L1 forks, 11 non-fork copies and all 319 upstream
PRs were checked, plus the QEMU and MAME fork networks; no OMAP1510/9300/9210
board exists anywhere, and no Symbian 6.x/7.0s source is public (only the
Symbian^3 mirrors carry the opcode names). Our `s80-epoc7-tables` branch is
ahead of everything public. **Reusable now** (all apply cleanly onto our
branch; patches saved under the job's `tmp/G1` and `tmp/G2`): 4akloon's open
upstream PRs #724 (heap smash on redraws over 12,800 draw commands), #726
(`--install` then `--run`) and #727 (abort on window close with an app
running); yagarea's `qt-logging` branch (thread names, timestamps, a
5-second stall watchdog printing every thread's state — verified by its
author on a 9300 boot); zixing131/EKA2L1-WEB (AGPL-3.0, not a fork; Y2's
full triage below) boots a real S60v3 ROM shell natively and fixes the same
key-capture bug B1 later found and fixed independently for the app-key
switch (§H7); ToolAssisted-run/chimera-core-eka2l1 (non-fork): a
real EKA1 LDD channel on device open, a null device-driver factory
accepting every request, a window-group use-after-free fix when an app
outlives its launcher, and a deterministic savestate-capable headless
build. **Designs and facts:** menghuan13251/EKA2L1 exposes host network
interfaces as IAPs and answers RConnection settings (2024 base, a design
to port, not to cherry-pick); razvang-dev/Nokia-N-Gage-SDK-Toolchain is a
Linux toolchain for EKA1 ARM binaries (gcc `2.9-psion-98r2`, `petran`,
`rcomp`, `makesis`); PuTTY for S80v2 (MIT, `s2putty`) is a socket test app
still built for the 9300/9300i/9500 today (also confirmed live by H2's
homebrew sweep below); shinovon/symbian-tls gives TLS 1.2 to the
9300/9500.

**yeatse's `ios-next` and zixing131's EKA2L1-WEB, triaged in full (agent
Y2, 2026-09-24).** `ios-next`'s merge-base with upstream is `39858137e` —
our own branch's starting point — and every emulator-core directory
(`services`, `kernel`, `system`, `mem`, `loader`, `cpu`, `qt`, `drivers`,
`common`, `vfs`, …) is byte-identical between the two trees; its 530
commits are the *originals* of work yeatse has since upstreamed as
rewritten PR batches, so **there is nothing left to cherry-pick**. What the
branch does hold is 176 diagnosis notes, bucketed by topic, and
`UIQ_SYMBIAN70_PORTING.md` is the closest sibling of our own 7.0s work: the
same "build says 151, speaks the old table" ABI shift, EKA1 panels mapped
directly, and a scan-code recipe read from the ROM's own service-menu key
test. EKA2L1-WEB's "ROM phone boot mode" is the one real find: of its 13
core-touching commits, 10 apply cleanly (`git am -3`) onto
`s80-epoc7-tables`, and the one large commit that does not (`dc3344530`)
splits cleanly by subsystem — its **window-server slice is the key-capture
rewrite, plus `ClearHotKeys`, the custom-text-cursor completions and
`SetSystemFaded`**, independently the same fix B1 wrote for the app-key
switch (§H7). Built and run on a side branch (`s80-web-picks`,
`6b30f688e`): Documents paints and types identically to the unpatched
baseline, and an idle-CPU A/B **rules out** "pending native-server receive"
as the cause of the Documents busy loop (§H7) — W2's text-cursor theory
stands instead. The gap that matters for a real EikSrv boot: **EKA1's
`server_create` still has no duplicate-name check**
(`svc.cpp:4429` — the EKA2-only version was added upstream), so a native
EikSrv today would silently coexist with the HLE stub instead of failing
loudly, which B1's ROM-EikSrv thread (§H7) needs before it can be trusted.
**Licensing:** every line of EKA2L1-WEB is AGPL-3.0 (author "light");
GPLv3 §13 lets our GPL-3 fork combine it, but the combination then owes
AGPL §13's source offer to the museum's own visitors, since the station
streams the running binary to them. The picks are kept on their own
branch, `s80-web-picks`, off the GPL branches, pending an operator decision
between taking the branch (and adding a source-offer link on the station
page), re-implementing the roughly 150 lines by hand to stay plain GPL-3,
or asking the author to relicense.

### Route 2 — A `nokia9300` board in the QEMU fork (full-system)

The faithful route: the real kernel on emulated silicon, every built-in app as
shipped, `savevm` goldens eventually. Three agents scoped it from the TI
specification, the QEMU source and Nokia's own RAE-6/RA-2 service manuals
(schematics, spare-parts lists, baseband description); their reports are the
detail, this is the shape.

**Which emulator — QEMU (agent M, Fable).** `hw/arm/nokia9300.c` on the
`Wnt/qemu@kernel-hive` fork as the next allocated patch (README: "Next free:
0011"), a new `--target-list=arm-softmmu` tile build in the `macos753.sh`
pattern, pinned by `qemuBuild.forkCommit`. Reasons: the SoC exists and boots
Linux (`test_sx1.py`); `ti925t` is a tested JIT model where MAME's nearest is an
interpreter-only ARM920T subclass with a DRC its header calls unfinished and no
OMAP at all (MAME's SA-1110 precedent prices an OMAP1510 at 3–4k register-level
lines before the first pixel); 59 of 63 stations are QEMU-shaped. The strongest
counter-argument is real: **no OMAP1 device in QEMU has a `VMStateDescription`**
(`omap1.c`, lcdc, intc, dma, gpio, mmc, uart, sx1: zero), and the legacy blocks
are plain structs, not qdev — `savevm golden` would succeed and `loadvm` restore
CPU+RAM+flash while ~25 SoC blocks stay at power-on. So: first bake with
`resetMode: relaunch`, and the OMAP vmstate sweep (≈1–1.5k mechanical lines,
precedent fork commit `196124da52`) as its own patch (0012) before a `golden`.
Input: `gallery-hid` is a PCI device and OMAP1 has no PCI — give the board a
bus-less keypad device (the `kh-ramabs` `TYPE_DEVICE` pattern, patch 0007)
speaking `mamectl/1` KEY verbs with `ctlsock`'s hold/gap pacing and calling the
MPUIO keypad / an I2C keyboard peer, so `SH_INPUT_BACKEND=mamesock` and the
daemon work unchanged (the Iris/Previous precedent: "the fork speaks mamectl/1
and the station is env"). Capture: `-display dbus,p2p=on` + fast-poll works
unchanged on `omap_lcdc.c`'s console at a native 640x200. Flash must be
qcow2-backed for `savevm`. Maintainability: upstream removed every PXA2xx/OMAP2
board in 9.2 and holds OMAP1 at "Odd Fixes"; the per-station `forkCommit` pin
is the mitigation.

**CPU — `ti925t` fits (agent K, Opus).** ARMv4T + Thumb, 16K/8K caches, full
MMU, the TI CP15 registers; anything the real chip rejects QEMU rejects too.
Three small deviations, ≈20–40 lines: WFI is a no-op on this model (an idle
guest burns a host core), TI's older wait-for-interrupt encoding traps as
undefined, one TI configuration register resets to the wrong value.

**SoC — most blocks exist, partially (agent K).** From the OMAP5910 TRM/datasheet
(the documented twin; TI part `OMAP1510GZZG2R`, "HELEN1", confirmed on the
spare-parts list) against `omap1.c`: EXISTS — MPU timers, watchdog, 32 kHz OS
timer, DPLL, pin mux, GPIO (16 lines), RTC, PWL/PWT/LPG, TIPB bridges, MMC/SD,
uWire, I2C master, McBSP1-3, 192 KB SRAM, up to 64 MiB SDRAM; EXISTS-PARTIAL —
interrupt handlers (L2 FIQ not wired), clock/ULPD (XXXs), DMA (endianness
TODOs), **LCDC** (1 bpp unsupported; **a palette-offset bug at 12/16 bpp skips
512 header bytes instead of 32 — one line, and it would blank a 640x200 16-bpp
frame in the controller's default mode**), UARTs (plain 16550s, no OMAP
extensions/DMA — fine for a debug console), MPUIO keypad (5 rows × 8 columns —
enough for the 9300's **6 col × 5 row lid/CBA matrix**, see below), MMC (ignores
the MMC-only init command, so a card may not be seen); MISSING — UART TIPB
switch, USB function/host, camera, mailbox, DSP MMU, DSP memory window,
MCSI1/2, and the **C55x DSP itself** (nothing stands in for it; a fake mailbox
responder of 200–400 lines if boot waits on it — `dsp_image.dof` is in the ROM).
The ID registers return OMAP310 values; the RAE-6 bootstrap compares
`0xFFFED400` against **`0x1B47002F`** — one line. `sx1` sets
`ignore_memory_transaction_failures`, so unmapped blocks read 0 silently.
`omap_sx1.c` is 252 lines; the SoC delta is ≈1,000–2,500 lines.

**Board — the 9300 (RAE-6) baseline (agent J, Opus; SP/SCH/BB documents of
the RA-2 and RAE-6 service manuals, plus the ROM's own driver strings).**

| Part | What | Interface | QEMU |
|---|---|---|---|
| D4800 OMAP1510 "HELEN1" | ARM925T + C55x, 12 MHz crystal, 32 kHz from UEMEK | — | ADAPT (ID, clocks) |
| D5080 SDRAM 32M×16 | 64 MB | EMIFF | EXISTS |
| D5000 **mDOC 1 Gbit** (Mobile DiskOnChip G3, marking `TH58MBG04G1XG`) | loader, core ROM (compressed), ROFS, user disk C:; WLAN window shared on RA-2 | EMIFS **nCS0** (boot chip-select); BUSY → the OMAP **WAIT/FRDY** pin (Z6 corrects J's GPIO9), rises ≤ 1055 µs after reset release; **CS1–CS3 carry nothing on the 9300** | **NEW** register model (G3 documented; MAME has one) — but the saftl on-flash format is NDA → stub `DiskOnChip.dll` instead (see "The flash") |
| StUF (UPP + flash) | the **CMT** — GSM processor, "system master" | **XBUS** = OMAP **UART2** ↔ UPP, handshake lines **GPIO8 + ARMIO3** (Z6, from the RAE-6 schematic; `XbusDma.pdd`: `XLv2_UART2`, `Armio_Bit3`; `XbusProtocol.ldd`; ISA stack `Isa_if_driver.ldd`, `IsiMsg.dll`, …) | **NEW behavioural peer — the long pole** (design in "The phone side") |
| UEMEK | regulators, charger, SIM, **RTC**, LED PWM, **PURX = the OMAP reset** (delayed ~130 ms), sleep clock, **power key** | only PURX + 32 kHz are wires to the OMAP; everything else via CMT software over XBUS | replaced by the XBUS peer |
| Main display | **640x200 LTPS TFT, 64k colours** | OMAP LCDC 16-bit RGB565 + **uWire nCS3** control, GPIO13 reset | LCDC ADAPT; uWire panel slave NEW (init sequence in `VideoDriver.dll`) |
| Cover display | 128x128 64k (COG, "Lilly2", `CuiLcdpdd.pdd`) | uWire nCS0, 9-bit serial, GPIO12 reset | NEW small |
| Lid keypad + 4 CBA keys | 6 col × 5 row matrix (BB-2 Table 13 is the key map) | OMAP MPUIO keyboard interface | EXISTS — map only |
| **QWERTY keyboard** | **COP8TAB5HYQ** 8-bit MCU on the 9300's own schematic (`COP8TAC9HYQ8` is only the spare-part code; also reads the lid Hall switch) | **I2C + interrupt on ARMIO2**, reset on **GPIO14** (`EKeyb.dll`: `Armio_Bit2`, `KEYBOARD I2C`, `KEYBOARD INT`) | **NEW I2C slave, protocol unknown — RE `EKeyb.dll`** |
| Audio | TLV320AIC23B (I2C), LM4855 (SPI); PCM to the CMT over XABUS (UPP DSPSIO ↔ OMAP MCSI2) | I2C/SPI/MCSI2 | NEW stubs first; MCSI2 missing |
| BC02 Bluetooth, IrDA | | UART/serial | absent at first |
| 9300i: ST **STLC4370** WLAN; 9500: TI **TNETW1100B** WLAN + camera | | 9300i: SPI on **McBSP2** (shared with the amplifier), CS ARMIO6, IRQ ARMIO4 (Z6 corrects "uWire"); 9500: external memory bus | absent at first |
| Power/regulators | UEMEK (CMT side) enables the OMAP core/logic supplies; GPIO3 enables the USB 3.3 V regulator, GPIO15 the MMC 3.0 V regulator; MMC wired 1-bit; the phone starts on battery insertion, the power key only selects the mode; `ARM_BOOT` is an unconnected stub | wires | model as constants |

**Boot chain (verified on the firmware).** Reset fetches from `0x00000000` =
the mDOC IPL window on nCS0 → `Bootcode` → `Tertiary Loader` → inflate `APE
Core MCU SW` into SDRAM → EKA1 bootstrap. Partition names from the loader:
`Bootcode`, `Tertiary Loader`, `APE Core MCU SW`, `APE Var-1…16`, `APE Test MCU
SW`, `APE ROFS Core`, `APE ROFS Var`, `Startup Screen`, `Userdisk Info`,
`Userdisk Data`. The ROM is **NAND-shadowed, run from SDRAM at
`0x50000000`**, not XIP NOR. The bootstrap's 10-record memory map: CS0/mDOC
64 MB at `0x00000000`, SDRAM 64 MB at `0x10000000`, SRAM 192 KB at
`0x20000000`, peripherals at `0xFFF00000`, DSP-side windows at
`0xE1008000`/`0xE1017000`, CS2/CS3 entries even on the WLAN-less 9300
(meaning unknown). Peripheral constants in the bootstrap match the OMAP1 map
(WDT `0xFFFEC800`, L1/L2 IH `0xFFFECB00`/`0xFFFE0000`, CLKM `0xFFFECE00`,
DPLL1 `0xFFFECF00`, ULPD `0xFFFE0800`, GPIO `0xFFFCE000`, UART1/2/3
`0xFFFB0000`/`0800`/`9800`). The ROM's variant layer names TI's **Innovator
OMAP1510** board as its origin. **Shortcut for first light:** load the inflated
core ROM straight into SDRAM and enter its bootstrap, skipping IPL/Bootcode and
the mDOC — plausible "first pixels" before the media layer works, since Z:'s
core is the XIP image itself; the ROFS parts (apps, resources) need the mDOC or
a patched media driver.

**What the ROM itself says (agent X, Fable, parsed and disassembled).**
`9300.rom`: EKA1 XIP at linear `0x50000000`, 17 MiB, 912 files, hardware
variant `0x09080001`, kernel data `0x80000000–0x80400000`, `iDebugPort=3` —
**the debug console is UART3**; the variant DLL `ECust.dll` is TI's **Innovator
OMAP1510** code (strings `INNOVATOR`, `OMAP1510`, Innovator-FPGA interrupt
names), UART PDDs `Comm.Helen_2`/`BC02.Helen_1`, uWire `THelenuWire`, idle
`HelenIdle`; product code name **Avalon** (`EStartavalon.dll`), keyboard
**Erin**, cover LCD **Lilly2**. The bootstrap's opening sequence is known
instruction by instruction: ARM_SYSST read → WDT disable (`0xF5`/`0xA0`) →
mask L1/L2 IH → EMIFS CS0/CS2/CS3 config `0x1021`/`0x1139`/`0x11F1`,
EMIFF_SDRAM_CONFIG `0x249DE` with a 64 MiB size probe → ARM_CKCTL `0x0506`,
DPLL1 `0x2CB0` polled for LOCK (150 MHz) → FUNC_MUX table +
`COMP_MODE_CTRL_0=0xEAEF` → the `0x1B47002F` ID check → ULPD, ARMIO1 low,
GPIO3 high; peripherals live at linear `0x58000000` (= phys `0xFFF00000`).
XBUS: `Isa_api_protocol.ini` selects `xbusdma.pdd + xbusprotocol.ldd +
isa_if_driver.ldd;4` — **a 4-byte XBUS header precedes every ISI message**, the
link is UART2 + DMA + `Armio_Bit3`, and `IsaApi.dll` names the 36 Symbian-side
ISI object IDs (boot-critical: `SELFTEST_SERV`=1, `STARTUP_APPL`=7,
`DOS_SERV`=11, `LIGHT_APPL`=34) with a sync + checksum handshake before channel
opens. Storage: `MedDoc.pdd` → `DiskOnChip.dll` (TrueFFS, MBR-style partition
table); ESTART mounts `Composite`/`erofs`/`ELOCAL`, and RAM and MMC media
drivers are in the ROM for a patch route. `Dsp_image.dof` is referenced only by
`Bridgecfg.dll`/`Bal.dll`, never by a boot binary — the C55x can be absent.

**The phone side, resolved to a design (agent Z3, Opus).** The ISI message
layer is **published**: Nokia's own ISI headers ship under the Eclipse Public
License in the Symbian Foundation's `modemadaptation` package (archive.org;
1,330 files unpacked to the session tmp dir `Z3/ma/` with `Z3/unbundle.py`),
giving the header layout — media byte, receiver device, sender device,
resource, 16-bit length (counting everything after it), receiver object,
sender object, transaction ID, message ID (little-endian on the N900's internal
link) — plus the resource and message tables and the later generation's
startup-reason code. **Message IDs are stable from the 9300's 2002-era
generation (Gammu/gnokii) to the N900 (ofono)**: power/startup control 0x15,
phone info 0x1B, security 0x08, network 0x0A, subscriptions 0x10, battery
0x17, clock 0x19, lights 0x3A (which backs X's `LIGHT_APPL` reading); in the
power/startup family a response ID is request + 0x63. X's **4-byte XBUS header
is neither the ISI media/device bytes nor FBUS** (the ROM uses FBUS only for
the PC emulator); the closest published match is the N900 link's 32-bit
start-of-message word (command, length in 4-byte words, message number), and
the 9300 ROM pairs `ssi.pdd` with `xbus.ldd`, which points the same way. Still
needs the ROM: that header's exact contents, the sync + checksum handshake and
the two handshake GPIOs, the "auxiliary startup reason" message, and the
9300-generation Symbian-side object numbers (X's table). No open-source ISI
modem emulator or captured boot handshake exists anywhere. **Fake-CMT boot
order:** link sync + checksum → subscription and name registration → startup
reason ("normal") + "ready" → RTC, battery, power for the power/startup server
(object 11) → phone identity → graceful "no SIM"/"no service" → backlight
(object 34) → SELFTEST last unless the APE waits on it; every unknown request
gets the generic "not supported" reply and every message is logged as pcap for
Wireshark's ISI dissector.

**The flash, resolved to a plan (agent Z4, Opus).** The mDOC is a **Mobile
DiskOnChip G3**: `DiskOnChip.dll` checks chip IDs `0x0200`/`0xFDFF` (the G3
values in the M-Systems data sheet) and references exactly the register offsets
Linux's `docg3.h` reverse-engineered; it is TrueFFS "Symbian OS 6.2.0.0" (G4
needs ≥ 6.3.2). A 1 Gbit 3.3 V part points at the dual-die G3 (MD4331, two
64 MB dies) — the 115-ball package on Nokia's parts list and the `TH58…`
marking are still unexplained. The **register interface is documented well
enough to model** (the 160-page G3 data sheet, downloaded; `docg3.c` for the
flash command registers and BCH ECC), and **MAME already has a G3 device**
(`src/mame/tigertel/docg3.cpp`, BSD-3, one die, behind the non-working
Gizmondo driver) — the best base for a QEMU port. **The on-flash format is the
blocker**: the driver carries the `CNAND` signature of TrueFFS 6's proprietary
"saftl" layout; Linux documents only the older `ANAND`/`BNAND`, and the saftl
headers went out under NDA (linux-mtd, 2012) — so the ROFS and FAT16 files we
hold cannot be turned into a chip image without a real chip dump or a format
RE measured in weeks. Symbian side: `MedDoc.pdd` ("Media.DiskOnChip") attaches
to `DiskOnChip.dll` at run time; `EStartavalon.dll` mounts the composite
ROM + ROFS file system on Z: and then addresses local drives 5 and 6 (the
ROFS core and variant, unconfirmed); the mapping is hard-coded, there is no
`estart.txt`; the SDK has no kernel media-driver headers (`MedInt.pdd`, 2.7 KB,
is the smallest template). **Options, best first:** (1) **replace
`DiskOnChip.dll` in the ROM image with a stub** that forwards `MedDoc.pdd`'s
partition reads/writes to a small new QEMU device serving the ROFS core, the
ROFS variant and a writable FAT16 C: straight from the files already staged —
the work is RE of how MedDoc talks to TrueFFS (~10 KB of code), days,
medium-high confidence; (2) port MAME's G3 model and obtain a chip image from
a real 9300 or by letting TrueFFS format a blank chip inside the emulator;
(3) remap the drives to the MMC slot or a RAM drive by patching three binaries.
Open: whether the boot code verifies the ROM checksum (a patched ROM must pass
it); the third ID pair the driver accepts (`0x0400`/`0x0400`).

**The related-platform test (agent T, Opus): Siemens SX1 firmware on QEMU's
`sx1`.** The real SX1 Symbian 6.1 bootstrap *runs* (QEMU 8.2.2 from Debian
packages, firmware unpacked with `@sie-js/fw`) and hangs within 2 s polling a
GPIO "ready" input that nothing drives — the companion-chip handshake; the
original 2008 patch only ever claimed U-Boot and Linux. Also found: on 8.2.2,
32-bit writes to 16-bit OMAP1 registers land in the boot flash, CS3 is left
unmapped, and the flash reports width 4 with zero IDs where the firmware
expects 16-bit Intel parts. Lessons for `nokia9300`: real flash IDs/width,
correct 32→16-bit register access, the companion "ready" lines on GPIO and the
UART modem lines, all chip selects populated — before any firmware gets far.

**Symbian's own OMAP1510 platform code: not public** (SymbianSource mirrors
carry EKA2 BeagleBoard/OMAP3 adaptation only); Linux's Nokia 770 Retu/Tahvo
CBUS drivers **do not apply** — the OMAP in the 9300 has no CBUS. No prior RE of
Series 80 v2 firmware was found anywhere — until this wave.

**Homebrew and alternative-OS efforts: none on this device family, but a
usable precedent exists next door (agent H2, Opus).** Nobody has ever
booted Linux or any other OS on a 9210, 9300, 9300i, 9500 or the related
7710. The one attempt, Psion's Arlo loader on a 9210 in 2001, died
`KERN-EXEC 3` (built for the wrong EKA generation) and was never retried;
an earlier 2000 proposal to port Linux to Ericsson's own StrongARM/EPOC32
communicator died before it started, for lack of released hardware
documentation — the same wall this wave's schematic and service-manual
haul (§Board, above) is what actually clears. So Route 2 inherits no board
file, memory map or LCD init from anyone. The useful precedent is the
**Siemens SX1** (OMAP310, Symbian 6.1, its phone stack on a separate chip
reached over a UART — the same split as the 9300's CMT over XBUS): its
Linux port is GPL and in the mainline kernel, and two of its tricks
transfer directly. First, `ubootloader`'s `load_uboot.exe` is shipped a
second time as `\system\programs\starter.exe` on the MMC, so the ROM's own
boot chain — which runs `\System\Programs\Starter` on the 9300 too
(§H7) — launches it as the shell with **no ROM patch at all**; Psion's
Arlo does the same trick through `wsini.ini`. It is a cheap way to get a
fake-CMT test harness or a diagnostic shell onto the board without
touching Z:. Second, `linux-on-sx1`'s `ipc_dsy.h` documents the OMAP↔modem
power-up handshake as GPL-published message groups — a 6-byte header, a
ping/startup-reason exchange, an ACK that echoes group and command — which
corroborates agent Z3's ISI design for the CMT-over-XBUS peer from an
independent device family, even though the wire format itself is
Egold-specific, not Nokia ISI. Two Psion EKA1 emulators (WindEmu,
psionEmulators) document the exact class of boot wall Z2's `nokia9300`
board is stalled on: the ROM executing at physical 0 while expecting
`0x50000000`, a superpage carrying the hardware-variant ID, a kernel that
polls unimplemented registers and spins on busy flags, and a watchdog that
must be kicked or the board resets. **For Route 1**, the same sweep turned
up open-source Series 80 / UIQ homebrew whose *source* is readable and
whose binaries are real non-Opera test content on the 7.0s ROM: `s2putty`
(MIT, still built for 9300/9300i/9500, drives `RSocketServ`/
`RHostResolver`/`RSocket` off the ROM's own ESock — the same app named in
§Prior work found above), the 2005 ScummVM EPOC backend (GPL-2, shows the
S80 640×200 16-bit blit path), and Hannu Viitala's CDoom/C2Doom, EMame9210
and Frodo ports (GPL, SDL-on-EPOC).

**First light on the board (agent Z2, Fable).** The RAE-6 core ROM boots on
a new `-M nokia9300` machine in the fork (uncommitted, at
`/data/vms/sandbox/s80-qemu/qemu`; the diff is saved as `tmp/Z2-nokia9300.patch`,
12 files). Three blockers were found and fixed: the ROM is linked for physical
base `0x10600000`, not `0x10000000` (the bootstrap's literal pool is full of
`0x106xxxxx` addresses); two upstream OMAP1 model bugs — `omap_findclk`
aborting on clocks the pin-mux table names but never defines
(`mcbsp3.clkx`/`clk32k_out`), and `omap_intc` only lowering its output on a
`CONTROL.NEW_IRQ_AGR` write, which EKA1's tick handler never issues, producing
625,668 IRQs/min; plus the 1510 JTAG ID `0x1B47002F` and the LCDC
palette-offset fix. With those in: the MMU comes on, the 64 Hz `Timer32K` tick
runs, 249 executive SWIs execute, UART3 prints 25 bytes of debug output (mostly
blank lines), and the USB W2FC client controller initialises. In 60 s of
running it never touched UART2 (XBUS), the mDOC window or the LCDC — it stalls
in kernel-extension start-up before the file server. Suspects: the USB driver's
retry loop against a zero-reading stub, or an XBUS handshake poll on
GPIO8/ARMIO3. Idle `WFI` is a no-op on `ti925t`, so the guest burns a full host
core while stalled. Build: 5 min 26 s cold at `-j8`; the `ccache` masquerade
(`PATH=/usr/lib/ccache:$PATH`) works once it is on `PATH`.

**Ranked risks (J, K, M agree):**
1. **The CMT has to answer.** The APE is the "system slave"; reset, startup
   reason, RTC, battery, backlight, power key and "no network" all arrive over
   the XBUS + ISI link (`Custom.ldd`: "APE-CMT channel has not been opened",
   "Auxiliary startup reason has not been passed"). The message layer is now
   documented (Nokia's EPL ISI headers — see "The phone side, resolved to a
   design"); what remains RE is the 4-byte link header, the sync/checksum
   handshake and the startup-reason message — drivers in hand in the ROM.
2. **mDOC/TrueFFS** for the ROFS partitions and C: — resolved to a plan: stub
   `DiskOnChip.dll` and serve the partitions from a small QEMU device (see "The
   flash, resolved to a plan"); a full G3 model needs a chip image nobody can
   synthesise (saftl is NDA).
3. **DSP bridge at boot** — a fake C55x responder if a boot-time server waits
   on the mailbox.
4. **Small protocol REs**: COP8 keyboard, the two uWire panels, codec I2C.
5. **Trivial**: OMAP1510 IDs, LCDC one-liner, `ti925t` WFI fixes, the SDRAM
   load shortcut, the 6×5 key map.
6. **Museum plumbing**: OMAP vmstate before any `golden`; the bus-less
   `mamectl/1` keypad device; an audio codec device for `-audiodev dbus`.

Effort: weeks of fork work with the RE of (1) as the unknown; it removes every
HLE-maturity question of Route 1 and delivers the firmware exactly as shipped.

### Route 3 — The SDK's WINS emulator under Wine, in nspawn (fallback only)

The Series 80 SDKs contain the whole Symbian OS 7.0s / 6.0 Series 80 build
compiled for x86 (`epoc32/release/wins/udeb/epoc.exe`), skin included, with Opera,
Documents, Sheet and Desk present (§H2). Under Wine in an nspawn sandbox this
would be host-native and show the genuine Series 80 UI — but it is the
developer kit's debug build, not the device firmware, and the operator has ruled
the kiosk-captured form out; this route stays documented only as a fallback
that needs an explicit operator decision. Evidence for Wine is thin and old:
GnuPoc ran the 9210 SDK emulator under 2001–2009 Wine ("boots but fails to
progress beyond the Extras dialog"), EPOC R5's `wine EPOC.EXE -Me32-sys.ini`
works, nothing at all is recorded for Symbian 7.0s, and the one modern AppDB
entry (S60 5th Ed, a different kernel) fails on Wine stubs. Wine is installed on
neither CT950 nor labhost (Debian 13). Installers do not run under Wine — install
on Windows once, copy the `Epoc32\` tree. The C++ SDK's emulator networking
needs a promiscuous-mode Ethernet NIC (release notes; no "WinsockLayer" exists).
(Agents G, H.)

### Route 4 — The SDK emulator inside a KVM Windows guest — REJECTED

Nearly everything is proven verbatim (`--like winxp`: device set, `loadvm`
golden, auto-start at logon, retronet tap + guard chain) and it would be the
fastest thing on a screen — but it is the bridge shape the host-native rule
retires (a whole licensed Windows guest + second scanout per station, forever),
it spends the Windows-licensing carve-out on a non-Windows exhibit, and the
operator has said the SDK-in-a-kiosk is not the exhibit. Kept here so nobody
proposes it again. (Agents C, F.)

### Route 5 — A MAME machine

TODO(M).

### Route 6 — The 9210 (Series 80 v1)

No ROM dump exists anywhere public; EKA2L1 has no v1 device entry; the DCT4
flash files are staged but unconvertible with any known tool; the SoC is
unidentified. Realistic sources: dump an owned 9210 with SDumper (the wiki's
EKA1 dumper — untested on v1), or reverse the RAE-3 flash format.

TODO(L) — SoC identification and documentation status (agent L, Opus, running).

## Featured-station plane (what is known; IM parked)

- `museum.periodBrowser` is a hard schema requirement
  (`scripts/stations_registry/validate_schema.py`): "Opera (Nokia 9500 Web)" for
  v2, "WWW" for the 9210 (HTML 3.2 + SSL; 9210i HTML 4.01 + Flash 5).
- `retronet.planes` accepts only `"web"` and `"icq"`; there is no `im` or `demo`
  key — the type-in demo is prose plus a framebuffer proof. Web-plane proof is a
  period browser painting a corpus page end-to-end plus containment checks from
  inside the guest (`docs/lab/retronet/WEB-STATION-win311.md`).
- IM — parked by the operator. Known so far, to save a re-derivation: the Agile
  Messenger 3 announcement (AllAboutSymbian, 2004-08-30) names Series 60 only;
  IM+ for Series 80 has one low-quality citation and no located installer;
  Steve Litchfield's Communicator archive (rendered through a real browser; it is
  behind a Cloudflare JS challenge) lists **no IM client at all**; the 9500 runs
  MIDP 2.0, so a J2ME ICQ client (e.g. Jimm) is the untested fallback. (Agent E.)
- Email: Series 80's Messaging does POP3/IMAP4/SMTP on both generations; the
  retronet has no mail server. An email plane would be new lab infrastructure —
  and the single feature that would make the Communicator shine.
- **Exhibit list (agent C1), from the 14/27 (9300) and 15/27 (9300i) apps
  that reach a usable first screen at `s80-app-fixes` @ `e73d11d5f`:**
  expose now — Documents, Sheet, Calendar, Clock, Calculator, Control
  panel, Help, Images, RealPlayer, Web (Opera; browsing works end to end,
  §H3), Log, Device mgr., Data mover and Data transfer (the last two are
  informational screens), plus Presentations on the 9300i. Expose as soon
  as their owner lands: Contacts (high value), Messaging, Desk with its
  application grid, and Music player. Hide for now: Telephone and Modem
  (no modem to answer), Conn. manager (until a network plane reaches it),
  Sync, Voice rec., File manager and Notes (blank), Backup (black dialog),
  Presentations on the 9300.
- Type-in demo: CWORD/Documents (a typed sentence, framebuffer-proven);
  money-shot first screen: Desk.

## Media manifest (labhost, museum-private)

| What | Path under `/data/assets-staging/symbian-s80/` | Bytes | Hash / note |
|---|---|---|---|
| EKA2L1 dump 9500 [ROM + Z] | `eka2l1-dumps/Nokia_9500_Communicator_(S80v2)_[ROM_+_Z].7z.mega-enc` | 19,604,091 | sha256 of blob `d784fbee…aed92b4`; decrypt key in session report only |
| EKA2L1 dump 9300i [ROM + Z] | `eka2l1-dumps/Nokia_9300i_(S80v2)_[ROM_+_Z].7z.mega-enc` | 21,618,000 | `ad2b505e…a6951f2` |
| EKA2L1 dump 9300 [ROM + RPKG] | `eka2l1-dumps/Nokia_9300.7z.mega-enc` | 32,759,619 | `eb802531…fcaa5be7e6` |
| Nokia service firmware, 5 devices | `firmware/{9500-RA-2,9300-RAE-6,9300i-RA-8,9210-RAE-3,9210i-RAE-5}/` | 433 MB | per-file sha256 in agent B's table |
| Series 80 v1 SDK 1.2 (9210) | `sdk/Nokia_9200_Communicator_Series_SDK_1_2_Installer.zip` | 250,723,198 | `78c7e202…c536db`; extracted at `sdk/extract-9210installer/` |
| Series 80 DP 2.0 SDK, C++ | `sdk/S80_DP_2_0_SDK.zip` | 131,052,274 | `f07c5e3b…1b23fad`; extracted at `sdk/extract-s80dp20/` |
| Series 80 DP 2.0 SDK, Personal Profile | `sdk/S80_DP_2_0_PP_SDK.zip` | 154,099,386 | `7c9dee30…7ed5e30c9`; cab staged, not extracted |
| `unshield` 1.6.2 static | `sdk/unshield-static` | ~60 KB | the only tool that opens `ISc(` InstallShield cabs |

Also on the dev box (session tmp, disposable): EKA2L1 master `39858137e` AppImage
(94,472,696 B, sha256 `fc875900…6ac4ac75`) extracted, its source clone, and the
agent reports A–M this document is distilled from.

## Integration plan

**EKA2L1 builds and runs on labhost, station-shaped (agent D1, Opus).** The
fork builds inside a Debian trixie build root (Qt 6.8.2, GCC 14, `mold`, the
shared ccache — a cold build was 1842 s at `-j16` under `nice -n 19`; a
re-run after a re-pin hit the cache 100 %). The runtime root is a separate
trixie **minimal** root (114 packages, uid-shifted), built in the
**perq/medley nspawn shape**, not lisa's — labhost has no Qt 6 to bind in, so
lisa's host-`/usr` shape does not apply here. Documents paints and takes
XTEST-forwarded typing inside that hardened container (read-only root, its
own uid range, `lo` only). Builder script:
`scripts/build-guests/emulators/build-eka2l1.sh` on branch `eka2l1-builder`
(pushed, not merged), pinned by fork branch + commit. Station facts: the
emulator ignores SIGTERM (kill it with SIGKILL), so reset is relaunch from a
fresh copy of the data dir; the Qt window renders 900x600 at +0+0 on a
1024x768 Xvfb until the kiosk flags land; the data dir's `config.yml` ships
with trace logging and UPnP on, and both need tuning for the station.

**A station scaffold exists, dark-launched (agent D2, Opus).** Branch
**`nokia9300` @ `49543e47`** on origin (github.com/Wnt/kernel-hive, pushed,
not merged) scaffolds the station from `--like lisa`, then rewrites it for
this device's shape: `registry/stations/nokia9300.json` (display `:119`,
geometry 1280x400x24 — an exact 2× of the guest's native 640x200 —
`--pointer none`, keys-only x11test, `resetMode relaunch`, `listing.state
hidden`, `ui: mobile`, archetype `putty-lcd`, `museum.periodBrowser` =
"Opera 6.0 for Symbian OS, build 543" read straight from the ROM's own
about page, `era_year` 2005); an nspawn launcher and inner script (Xvfb
with a patched `-xkbdir`, EKA2L1 in a supervised relaunch loop); the
station's SPA keyboard family `nokia9300` (F1–F4 = the four CBA buttons,
F5–F12 = the eight application keys, Menu, F13–F17 = the joystick, Chr via
`Alt_R`→`ISO_Level3_Shift`); and a golden data dir built from F1's C: plus
`10000865.ini` (`LanguageSelectionDone=1`, §H7) plus B1's key bindings,
staged on the box at
`/data/assets-staging/symbian-s80/nokia9300-golden/xdg` — **never
committed**. `/os/nokia9300` is live and hidden on the box (darklaunch
overlay), and the application keys are proven on the station rig itself,
not only on a dev-box clone: F10 → Documents, F5 → Desk, F10 → Documents
again, each frame waited out and viewed. Two platform traps worth keeping
in mind for any other keyboard-only station: **Xvfb 21.1 ignores runtime
keymap changes** (`xmodmap`/`xkbcomp` both exit 0 and change nothing, on
both trixie 21.1.16 and Ubuntu 21.1.12) — worked around by starting Xvfb
with `-xkbdir` pointed at a patched copy of the XKB data instead of trying
to reconfigure a running server; and nspawn's SIGTERM trap has to kill the
**container's own init** (nspawn's direct child), not `systemd-nspawn`
itself, or the inner script's relaunch loop out-races the reaper and
orphans the container's mount namespace. Still open before a merge: D1's
builder branch landing, K1's keymap landing on the golden (a stopgap
binding set ships there today, §H4), B2's kiosk flags wired into
`NOKIA_EMU_ARGS`, and I1's integration branch reaching a build and push
(§Integration plan). The third-app and empty-Desk-pane walls that used to
block this are resolved (§H7).

**The frontend is a kiosk, with a control socket (agent B2, Opus).** Fork
branch **`s80-museum-frontend` @ `44fab244d`** adds `--kiosk` — a
frameless, exact-integer-scaled window with no menu bar, status bar, tray
icon or dialog (128,000 of 128,000 pixel blocks uniform at the default
2×) — and a Unix-socket control channel, `ekactl/1`, that a station's
daemon or a debugging session can drive directly: `switch <uid|caption>`
brings an app's window group to front in 104–283 ms, plus `launch`,
`list`, `screenshot` (byte-identical to the X root), `reset` (an
in-process Symbian reset — **not** a C: restore; the station's own
relaunch-from-golden stays the real reset) and `quit`. Alongside it:
`--help`/`--listdevices` now return in under a third of a second instead
of hanging forever (the pre-UI exit path was never setting `init_event`),
and SIGTERM now ends the process in 0.13 s instead of being swallowed.
Measured at idle: **1.4 % of a core with Desk open**; Documents idled at
**60 %**, confirmed at the time as the same busy loop W2 and Y2 were
chasing (§H7) — since fixed by W2's redraw-spin commit, not re-measured
here. Two walls found and handed off: Desk launched while Documents is
already running never starts (the busy loop starves it — start Desk
first, until W2 lands), and Opera opened directly with a URL reaches the
ESock wall exactly where §H3 said it was. Both the redraw-spin fix and
B4's mutex fixes (below) touch exactly this kind of concurrent-app
starvation, though this specific two-app case was not re-tested by this
fold; §H3's wall is now closed outright.

**Application coverage: 14 of 27 built-in apps usable on the 9300, 15 on
the 9300i (agent C1).** A full survey of every app both ROMs list — the
registry's 23 plus 4 the device shows but the registry hides (Desk,
Calendar, Notes, Log) — run one at a time under `--run <UID>`, each to a
settled frame. Branch `s80-app-fixes` @ `e73d11d5f` (based on W2's
`s80-wserv-leftovers`, merges cleanly with its newer `a1ebfc046`) fixed: a
JIT TLB bug that crashed the whole host on Control panel (a zeroed
page-table entry matched page 0); Messaging's `RWsSession::Set/
GetBackgroundColor`, which was blocking its command-buffer flush; an HLE
`AlarmAlertServer`, without which Clock and Calendar both failed with
"Unable to find the specified object"; seven EKA1 locale exec calls
(day/month names, date suffix, AM/PM); an ETel op (14,
`SetExtendedErrorGranularity`); and the pixel-height bug behind every
undersized list/table font (the client sends pixel heights, the server
was dividing by 15 as if they were twips). Up from 9 apps at F1's
baseline. **9300i note:** F1's window-server predicate holds with no
build-number difference — every 9300i frame matches the 9300's except
Clock's home city and Presentations, which paints on the 9300i and takes
FBS shared-chunk access violations on the 9300 only. **Walls still open,
by cause:** a case-sensitive server-name lookup blocks Contacts and
Telephone (`randsvr` vs `RANDSVR`); skin bitmaps loading as 0×0 blacken
dialog bodies in Messaging, Backup and Modem (the same gap behind the
title bars and status panes below); Sync panics with a stray signal after
a ViewServer op, a regression from an earlier pass; Music player is stuck
on its title screen pending an AppList op (§H7); File manager and Notes
sit idle with one async view-server op pending and no synchronous request
outstanding — the same shape N7's ViewServer message-layout mismatch
describes (shell document) and a plausible shared cause; Voice rec. fails
on missing `SharedDataServer` keys. **Machine UID:** the guest reads
`EMachineUid` from its own `hal.dll`: `0x101F8DDB` on the 9300 and 9500,
`0x1020E048` on the 9300i.

**The Series 80 UI's own TrueType fonts are missing from both ROM dumps
(agent C1; operator decision).** Both firmware dumps' `Z:\System\Fonts`
lack the four faces the UI actually uses (the 9300 RPKG's own
`Z:\missing.txt` names them: `Swabbiu.ttf`, `Swabru.ttf`, `Swariu.ttf`,
`Swarru.ttf`); without them the UI fell back to a narrow serif face, which
was most of what made the station look wrong before the font-selection
fixes below. The Series 80 DP2.0 SDK's own Z drive carries the same four
files, confirmed pixel-identical to the real device's CBA text. **The
operator ruled these go into the station's golden data dir on labhost,
never into the repo** — the same rule as the ROM and SDK media above.

**An integration branch merges the wave (agent I1, branch
`s80-integration`).** Every `s80-*` branch pushed to the fork by this wave
is merged locally onto it already; a build, a fresh proof pass and the
push itself are what is left, as of 2026-09-25 05:00 UTC.

**Fidelity against the real device, ranked and re-checked (agent R2).** A
much larger reference gallery than the earlier pass — the official Nokia
9300 User Guide's own screens, 36 pixel-exact 640×200 captures from a real
Nokia 9500 review (the same Series 80 v2 UI), the Series 80 UI Style
Guide, and the SDK emulator's own frames cropped 1:1 (a pixel oracle: its
CBA text matches the real device to the pixel) — staged in the job
directory, never the repo; only the Wikimedia Commons device photos in it
are licence-clean for a poster. Ranked by visible impact:
1. **The wrong font face was used everywhere — fixed since.** Every string
   drew about half size with 1-px strokes; the device's CBA face is bold,
   13-px cap height, 3-px strokes, and underlines its default command.
   Fixed by W2's font-selection commit `a1ebfc046` plus C1's pixel-height
   fix (`1b9a42b15`, above).
2. **Three skinned regions still paint black — in progress:** the title
   bar, Desk's status pane and the narrow status strip in application
   views. Traced to the ROM's own `skinapptitle.mbm`/`skinstatuspane.mbm`/
   `skinstatuspanewide.mbm` loading their zero-size bitmap entries as
   nothing, plus unhandled GC brush ops (14/15/16, `SetBrushOrigin`/
   `UseBrushPattern`/`DiscardBrushPattern`) — the same gap behind
   Messaging, Backup and Modem's black dialog bodies above. The status
   pane's own contents (profile, clock, signal/battery indicators) are
   additionally the ROM's own Eikon-server path (§H7).
3. **Desk's main pane was empty — fixed since.** See B6's AppList work,
   §H7 and above.
4. **Opera sat stuck on "Connecting…" with a blank page — the network
   half is fixed, the home-page half is in progress.** §H3 closes the
   network wall; the local home page still does not load at startup
   (agent N7).
5. **"Insert object" looked clipped in Documents — closed, and it was
   never a station bug.** At the dev window's non-integer 1.3766× Qt
   scale, right-aligned CBA labels drift a few pixels right and touch the
   edge; in the station's own exact-2× frames every label already ends at
   the device's own 4-px margin. A frontend rule (never a non-integer
   scale) keeps this from recurring; the station was never affected.

**Already right, so nothing to fix:** pane geometry, the palette, the Desk
icon and the skin bitmaps that do paint (CBA background, left panel), CBA
label text and positions including the 9300's third label "Note list"
(the SDK and the 2004 9500 lack it — a firmware difference, not a bug),
the app-key and CBA-key order, and exact-integer 2× station framing.
Lower-priority gaps not yet chased: the default command's underline and
dimmed-command colour, a missing scroll bar and a row-pitch difference in
Sheet (recheck once the font fix above is on a frame), and the CBA
buttons' alignment to their label slots in the kiosk chrome.

**Build and iteration rules for every fork in this wave (operator, 2026-09-24):**
at least 8 parallel jobs (`ninja -j10` on the dev box, `-j16` under `nice -n 19`
on labhost), a compiler cache on every configure (`ccache` is installed on both
machines; labhost's shared cache is the default via `box-ccache-conf.sh` and
was hitting 94.7 % during this wave; CMake: `-DCMAKE_C_COMPILER_LAUNCHER=ccache
-DCMAKE_CXX_COMPILER_LAUNCHER=ccache`; QEMU: `--cc='ccache gcc'`), `mold` for
linking where the build allows (`-fuse-ld=mold`; present on both machines),
Release/RelWithDebInfo without LTO for spike builds, incremental `ninja` in one
build dir (never reconfigure to change a launcher mid-build — it forces a full
rebuild), and edits kept out of tree-wide headers so a cycle recompiles a
handful of objects. Measured: a clean EKA2L1 Release build on the dev box
(Qt 6, dynarmic, ffmpeg) is ~1,536 ninja targets.

**A 5-hour usage-limit pause hit all sixteen agents in this wave's third
pass at once; resuming each one by message, with its context and worktree
intact, recovered the whole wave in minutes rather than losing it.**

## Open questions and dead ends

**Open**
1. Firmware version and language of the three dumps; why the 9300i dump ships
   `Dev9300.sis` (it would register as RAE-6 and collide with a 9300 install);
   the 9500 needs a hand-written device entry (naming recognises only
   `dev9300.sis`).
2. What is inside the 2005 InstallShield service packages (MCU/PPM/CNT names;
   which file is the ROM) — needed for a QEMU board's flash image.
3. The operator decision on `~@mount` (CRIU) for sub-2 s resets of nspawn
   stations — shared with vision/perq.
4. The 9210: SoC identity, a ROM source, EKA2L1 v1 entry.
5. Opera's home page does not load at startup — traced to a ViewServer
   message-layout mismatch, fix in progress (agent N7, §H3, §H7). The
   network wall itself is closed (§H3). `RThread::ExitCategory` (0xC0003F)
   is still unimplemented but blocks nothing found so far.
6. Shell: the ROM's real Eikon server still does not paint its own Desk —
   a fuller boot chain now reaches through `eiksrvs` before stalling on an
   unimplemented PhoneServer call (agent B5, §H7) — and `CaptureLongKey`
   (Menu-hold task list) stays unhandled. The third-app wall and the empty
   Desk pane are both resolved (agents B4, B6, §H7).
7. App-coverage walls with no owner yet: Contacts/Telephone's
   case-sensitive server lookup, Sync's regression, File manager/Notes
   sitting idle on one pending view-server op (plausibly the same N7 gap
   above), and Voice rec.'s missing SharedData keys — full table in
   §Integration plan.
8. Starter's per-item flag semantics (no public source).
9. Opera's behaviour on a real connection *failure* — today's fallback
   always succeeds silently; the SDK-emulator oracle shows a
   "Connecting… → silent fail → re-prompt" cycle with no error dialog
   (X1), untested on EKA2L1 itself.
10. The AGPL licensing decision on EKA2L1-WEB's picks (§Prior work found):
    the operator has ruled the picks stay on their own branch, off the
    GPL branches. Re-implementing the small picks by hand to stay plain
    GPL-3, or asking the author to relicense, remain open only if those
    fixes are ever wanted on the GPL side.

**Resolved this wave:** the network wall (§H3); the S80 keymap, now a
frame-proven port of the ROM's own EKTRAN/EKDATA tables on branch
`s80-keymap` (agent K1, §H4); the idle-CPU redraw loop (agent W2, proven
three times over by three unrelated EKA1 clients, §H7); the third-app wall
and Desk's empty main pane (agents B4, B6, §H7).

**Dead ends (do not repeat)**
- romphonix.org is offline (port 80 times out, 443 refused, from CT950 and
  labhost); Wayback has the directory listing but no `.7z` captures; the files.dog
  mirror predates the EKA2L1 category. Use the MEGA mirror.
- `7z l` on the Nokia InstallShield `.exe` fails without `-t#`; neither 7z nor
  cabextract opens `ISc(` cabs — use `unshield`.
- EKA2L1's `--listapp` prints nothing; `--help` does not exit; device install has
  no CLI; the AppImage needs `--appimage-extract` (no FUSE in CT950).
- WineHQ AppDB is behind Anubis, gnupoc.sourceforge.net and
  stevelitchfield.com behind Cloudflare JS challenges — WebFetch/curl fail,
  Playwright Chrome renders them.
- The Symbian SIS collection on archive.org (`symbiansis`) is Series 60 only.
- Agile Messenger is Series 60 only; "WinsockLayer" is not a thing in these SDKs.

## Provenance (which model ran what — AGENTS.md rule 12)

Coordinator: Fable 5.1. Discovery/verdict agents on Opus: A (EKA2L1 source
verdict + Xvfb run), B (firmware sourcing + MEGA header decode), J (board map),
K (CPU/SoC vs QEMU), L (9210 SoC), V (`V-eka2l1-build.md`, build proof), Z1
(`Z1-eka2l1-windows.md`, Windows/win11 clone cross-check). Fable: M (QEMU vs
MAME decision), S (the ROM spike), F1 (`F1-s80-wserv-fix.md`, the window-server
fix spike), Z2 (`Z2-nokia9300-first-light.md`, the `nokia9300` board first
light). Earlier Sonnet passes — C (SDK sources), D (hardware emulation
survey), E (plane/apps), F (repo integration), G (Wine), H (SDK staging and
inventory) — were used for facts only; the four load-bearing repo citations in F
(amix llvmpipe, riscos Qt5, indyr4400 356%, perq CRIU) were re-verified against
the tree, and D's ground is re-covered by J/K. Mid-session the operator ruled
that Sonnet is for mechanical tasks only; two Sonnet research agents were
stopped and re-run on Opus/Fable. Fork: `https://github.com/Wnt/EKA2L1`
(branch `s80-epoc7-tables`, F1's window-server fix).

Later the same session, on Opus 5.5: R1 (`R1-intel.md`, targeted intel for
ESock/Opera/shell/keymap), G1 (`G1-github-prior-work.md`, identifier-search
prior-work sweep), G2 (`G2-fork-sweep.md`, fork-network sweep), D1
(`D1-labhost-build.md`, the labhost build and container proof), and Y2
(`Y2-yeatse-triage.md` — complete: nothing to pick from yeatse's `ios-next`;
10 of 13 EKA2L1-WEB core commits picked to a side branch, built and run with
no regression). On Fable 5.1: X1 (`X1-sdk-oracle.md` — Nokia's Series 80
DP2.0 SDK emulator booted to the real Desk in a win11 rig clone and traced
live under x32dbg as a dynamic IPC oracle; the coordinator viewed the frame
`X1/x1-05-desk.png`; the emulator's C: drive, start lists and boot log are
copied out under `X1/files/`, 58 behaviour frames under `X1/frames/`, IPC
traces under `X1/traces/`). X2 (Opus 5.5) was stopped with no output. `warm`
(Sonnet, `warm-build.md`).

Later still, the same evening: on Fable 5.1, B1 (`B1-shell.md`, the S80
application-key switch and the ROM-EikSrv spike) and N1 (`N1-esock-70s.md`,
the 7.0s ESock opcode table and the `is_oldarch()` predicate fix). On
Opus 5.5: N2 (`N2-commdb-opera.md`, the `RConnection`/CommDB fallback and
Opera's connection path), B2 (`B2-museum-frontend.md`, the kiosk frontend
and the `ekactl/1` control socket), D2 (`D2-station-scaffold.md`, the
`nokia9300` station branch and its dark launch) and H2
(`H2-homebrew-altos.md`, the homebrew/alt-OS sweep).

A third wave, 2026-09-24 21:00 UTC to 2026-09-25 04:50 UTC across a 5-hour
usage-limit pause that stopped all sixteen of its agents at once (resuming
each by message, with context and worktree intact, recovered the wave in
minutes): on **Claude Opus 5.5**, N3 (`N3-putty.md`, the PuTTY-for-S80v2
socket proof), N4 (`N4-commdb-patchdll.md`, the guest CommDB patch DLL), N5
(`N5-socktest.md` + `N5/toolchain.md`, the Linux-hosted toolchain and the
end-to-end socket proof on branch `s80-esock-70s` @ `92f600bf5`), N6
(`N6-opera.md`, closing the network wall — Opera renders a real page), R2
(`R2-reference-assessment.md`, the full real-device reference gallery and
ranked fidelity gaps) and C1 (`C1-app-coverage.md`, the 27-app survey). On
**Claude Fable 5.1**, X1 continued `X1-sdk-oracle.md` from the earlier wave
(re-confirmed its teardown after the pause; no new SDK-oracle work this
wave). Facts from B4 (the third-app mutex fix), B5 (the ROM boot chain,
branch `s80-hle-dos`), B6 (Desk's main pane, branch `s80-desk-content`), K1
(the real keymap, branch `s80-keymap`), N7 (the Opera home-page ViewServer
mismatch) and I1 (the `s80-integration` merge branch) reached this document
through the coordinator with no written report seen by this fold; which
model ran each is not recorded here — a resumer should ask the coordinator
directly rather than assume, and should treat anything dated
2026-09-25 05:00 UTC as in flight, not yet independently verified against a
report.

The doc folds were Sonnet passes (facts dictated by the coordinator from the
reports); the coordinator wrote §Operator decisions 5–7 from the operator's
own messages.

## Sources

- EKA2L1: https://github.com/EKA2L1/EKA2L1 (PRs #473, #475; issue #382; commit
  `6e3f90b7`; wiki "Dumping the ROM and ROFS"; quickstart
  https://eka2l1.github.io/quickstart/basic/installdevice/); community wiki
  https://eka2l1.miraheze.org/wiki/S80
- Dumbphone Repository readme/changelog: https://archive.org/download/romphonix/
- Nokia firmware: https://archive.org/details/Nokia_DCT4_firmwares,
  https://archive.org/details/nokia-9210-arch, `nokia-phone-firmwares`
- SDKs: https://archive.org/details/nokia_sdks_n_dev_tools,
  https://archive.org/details/nokia_sdks_n_dev_tools3,
  https://archive.org/details/nokia-9210sdk; index
  https://github.com/mrRosset/Symbian-Archive
- Devices: https://en.wikipedia.org/wiki/Nokia_9500_Communicator,
  https://en.wikipedia.org/wiki/Nokia_9300, https://en.wikipedia.org/wiki/Nokia_9210_Communicator,
  https://en.wikipedia.org/wiki/Series_80_(software_platform),
  https://lpcwiki.miraheze.org/wiki/Nokia_9500_Communicator; user guides
  https://archive.org/details/manuallib-id-2586523 (9300/9500),
  https://ia903204.us.archive.org/1/items/manualsbase-id-61122/61122.pdf (9210)
- QEMU: https://qemu.readthedocs.io/en/master/system/arm/sx1.html;
  `docs/about/removed-features.rst` (cheetah, n800/n810 removed in 9.2)
- MAME: https://github.com/mamedev/mame/tree/master/src/mame/nokia,
  `src/mame/psion/psion7.cpp`, `psion5mx.cpp`
- Wine: https://gnupoc.sourceforge.net/, https://www.martin.st/symbian/,
  https://gist.github.com/tuxology/3bc4f18d1152c67871b2
- Series 80 software: https://stevelitchfield.com/commarchive.html,
  https://my9210.bs0dd.net/, https://allaboutsymbian.com/news/item/Updated_Agile_Messenger_3_now_available.php
- Prior-work forks (§Prior work found): yeatse's `ios-next`
  https://github.com/yeatse/EKA2L1 (branch `ios-next`); EKA2L1-WEB
  https://github.com/zixing131/EKA2L1-WEB (AGPL-3.0); s2putty
  https://github.com/shinovon/s2putty
- Homebrew and alt-OS precedent (§Route 2): SX1 Linux port
  https://github.com/vovan888/linux-on-sx1, mainline board file
  `arch/arm/mach-omap1/board-sx1.c`; Arlo (SourceForge `linux-7110`
  project, "Arlo Source"); WindEmu blog
  https://wuffs.org/blog/building-a-psion-emulator; PsiLinux/Arlo-9210
  thread https://marc.info/?l=linux-arm&m=97583966203880&w=2
