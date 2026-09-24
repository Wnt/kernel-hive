# Nokia Series 80 (Symbian OS) — candidate research

**Status: research complete for the first wave, 2026-09-24 — no rig, no station,
nothing committed but this document.** Media is staged on labhost under
`/data/assets-staging/symbian-s80/` (hashes below; the bits themselves are
museum-private and never enter the repo). The question this document answers:
*which route puts a Nokia Communicator running Symbian OS Series 80 — the real
firmware, with its built-in Web browser, Documents and Sheet — into the gallery
as a fully featured station, and what are the walls on each route?* Hardest
problems first; every claim carries its source. A bring-up wave starts from the
plan at the end, not from this document's history.

## Operator decisions that shape this (2026-09-24)

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
pushed to the fork `https://github.com/Wnt/EKA2L1`. Leftovers, per F1: Documents
and Sheet each burn one core at settle (theory: the window group `SetTextCursor`
0x2f handler is missing, so the caret-blink call loops); the build-139 GC table
still has no handlers for 14/15/16/20/43 (brush ops, `DrawLineTo`, `MapColors`
— Opera's toolbar spams both of the latter); the S80 keymap has no letters
bound; Desk's lower-left icon area is unpainted (state/skin, unconfirmed); the
7.0s socket table + `RConnection` (Y's finding, §H3) is still untouched, so
Opera cannot get online yet.

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
  itself runs in a win11 rig clone as a live oracle (agent X1). (Agents C, H.)

### H3 — The network plane

- **EKA2L1** reimplements ESock: guest TCP/UDP become host sockets from the
  emulator process (changelog 0.0.9; 2026 EKA1 work `a8f33265` adds the
  `hosts:` DNS override map in `config.yml`, `eee48639` a "host-backed connection
  through native CommsDB records on EKA1"). **The 7.0s ESock opcode numbers
  equal EKA2L1's existing pre-reform table, op for op** (agent R1, from the
  SDK's `ESOCK` client library cross-checked against Symbian^3's public
  `SOCKMES.H`), including RConnection 0x3F–0x54; the only gate is
  `is_oldarch()` (`< epoc81a`), which decodes 7.0s with the 6.1 table (6.1 →
  7.0s adds four no-length send/receive ops, so everything from `Connect`
  moves **+4**, plus the new RConnection/sub-connection ops). `RConnection::Start`
  additionally fails on 7.0s because EKA2L1 reads the access point from a
  CenRep store (key `0xCCCCCC00`) that exists only on EKA2. **Opera** is
  "Opera 6.0 for Symbian OS" (build 543 on the 9300, 556 on 9300i/9500),
  fetching through Symbian's HTTP framework on Opera's own `RConnection`;
  settings live in `C:\System\Data\Opera\Opera.ini`; the access-point dialog
  appears only when CommDB `ConnectionPreferences` `DialogPref` = "Ask before
  connecting" — otherwise Opera connects with no prompt; after `Start`, Opera
  reads `IAP\IAPService` and `IAP\IAPServiceType` to open the CommDB Proxies
  view (EKA2L1 answers both `KErrNotFound` today); Opera makes no socket call
  at start-up — the path is open Web → type URL. The connection dialogs a
  user sees on the device are EikSrv notifier plug-ins (`connnotifiers.dll`
  via `agentdialog.dll`), which EKA2L1's HLE ESock never reaches. So Opera
  cannot get online until the fork routes epoc7 off the old table and answers
  the CommDB settings above — the second table after the window server's. In
  flight: agent N2's CenRep-free EKA1 `start()` fallback (fork branch
  `s80-commdb`, answers `IAPService=1`/`LANService`) and agent N1's predicate +
  socket ops + page-load proof. There is **no NIC to tap**: joining the
  retronet means a network namespace with a veth onto `vmbr-rn` and the `hosts:`
  map; Opera has **no proxy keys** in `Opera.ini` (proxy is per access point in
  CommDB), and with retronet's wildcard DNS and vhosts no proxy is needed.
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
- **EKA2L1**: it never loads the ROM's EKTRAN/EKDATA; its scancode→keycode
  path is a fixed table with no modifiers (`epoc::map_scancode_to_keycode`,
  `services/src/window/common.cpp:234`), so Shift/Ctrl/Chr do nothing today —
  letters are unbound in the default bindings, digits type. The ROM ships
  `ekdata.dll` + 15 per-language `ekdata.NN.dll`, whose format and translation
  algorithm are public EPL source (`k32keys.h`, `ky_tran.cpp`); the window
  server loads `EKDATA` then `EKDATA.NN` from HAL `EKeyboardIndex`; Chr-hold
  accent cycling is an in-guest FEP (`Cycling_fep.fep`). **Plan (agent K1):**
  port the EPL `Convert()` and modifier machine host-side over the ROM's own
  tables. **Keymap contract v1:** F1–F4 = command buttons, F5–F12 =
  application keys (Desk, Telephone, Messaging, Web, Contacts, Documents,
  Calendar, My own), Menu, F13 = joystick centre, F14–F17 = joystick,
  `ISO_Level3_Shift` = Chr, printable characters as themselves. **Capture
  bug:** EKA2L1 never delivers captured keys (`io.cpp:198` indexes capture
  requests by a key code that is always 0; `CaptureLongKey` unhandled) —
  fixed by agent B1. (Agent R1.)
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

- **Who owns what** (ROM, verified in the bytes; agent R1). The application
  keys are handled by the ROM's EikSrv UI part (`eiksrvui.dll`, a generic
  App0+i handler); `SysAp` (UID `0x101F6E33`) captures the Desk key
  (`0xF852`) and the My-own key (`0xF859`); `Startup.app` captures those two
  plus Menu during its first-boot language wizard (skipped once
  `C:\System\SharedData\10000865.ini` has `LanguageSelectionDone=1`). S80's
  EikSrv client opcodes: 1 LaunchTaskList, 2 CycleTasks, 3/4
  AddToStack/RemoveFromStack, 7 SetStatusPaneLayout.
- **What EKA2L1 does today.** It replaces EikSrv with an HLE stub
  `EikAppUiServer` that handles none of this and, because its opcode
  remapping does not cover S80's low numbers, misroutes S80 ops 5/6/13 to
  the wrong handlers.
- **The chosen architecture** (agent B1, implementing). The ROM's import
  tables show Starter, SysAp and Startup.app all reaching the DOS server,
  whose `Nokia.dsy` needs the CMT-over-ISA phone link (absent in EKA2L1;
  Nokia's own SDK swapped in `ExampleDSY` for the same reason) — while
  EikSrv and Desk do not import it. So the station runs the ROM's **real
  EikSrv + Desk with no Starter/SysAp**, and the emulator supplies only the
  Desk/My-own key behaviour host-side. The window server starts the shell
  from `wsini`'s `STARTUP`/`SHELLCMD`, unhandled on our branch today; EKA1's
  `server_create` has no duplicate-name check, so a native EikSrv would
  coexist with the HLE stub unless the stub is skipped for S80.
- **The Documents/Sheet/Web idle-CPU loop** (agent W2, in flight). F1's
  leftover "one core burned at settle" is a redraw loop on a zero-area
  window: the region code admits a 0-width rect and `intersect` never
  subtracts it, so the client redraws 150–900 times/s and the redraw store
  grows without bound. Fix: the region ignores zero-area rects, invalidation
  is clipped, and empty redraw segments are dropped.

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
author on a 9300 boot); zixing131/EKA2L1-WEB (AGPL-3.0, not a fork): a
`native_phone_boot` mode that boots a real S60v3 ROM shell natively, plus a
window-server patch that delivers a captured key to **one** owner by
priority and modifier mask (our base delivers to the focused app *and*
every capturer), removes captures on cancel/owner death, completes
`ClearHotKeys`, and returns `KErrNotSupported` for the custom-text-cursor
ops (EikSrv otherwise hangs at startup) — GPLv3 §13 permits combining,
provenance to be cited; ToolAssisted-run/chimera-core-eka2l1 (non-fork): a
real EKA1 LDD channel on device open, a null device-driver factory
accepting every request, a window-group use-after-free fix when an app
outlives its launcher, and a deterministic savestate-capable headless
build. **Designs and facts:** menghuan13251/EKA2L1 exposes host network
interfaces as IAPs and answers RConnection settings (2024 base, a design
to port, not to cherry-pick); razvang-dev/Nokia-N-Gage-SDK-Toolchain is a
Linux toolchain for EKA1 ARM binaries (gcc `2.9-psion-98r2`, `petran`,
`rcomp`, `makesis`); PuTTY for S80v2 (MIT, `s2putty`) is a socket test app;
shinovon/symbian-tls gives TLS 1.2 to the 9300/9500; yeatse's `ios-next`
core is byte-identical to upstream master (nothing to pick).

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

## Integration plan (draft — finalised after the fix spike and the fork decision)

TODO — sibling, ledger row, first-bake device set, files, proofs, per the winning
route.

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
5. ESock 7.0s table + `RConnection` (N1/N2 in flight).
6. Shell/app keys (B1).
7. Keymap (K1).
8. Idle CPU loop (W2).
9. Which app each of the six middle application keys opens (lead:
   `Z:\System\Data\eiksrvui.rsc`).
10. Starter's per-item flag semantics (no public source).
11. Opera's behaviour on connection failure.
12. Decoding EKDATA (K1's job).

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
(`Y2-yeatse-triage.md`, triaging yeatse's `ios-next` branch — in flight). On
Fable 5.1: X1 (`X1-sdk-oracle.md`, in flight — Nokia's Series 80 DP2.0 SDK
emulator booted to the real Desk in a win11 rig clone; the coordinator viewed
the frame `X1/x1-05-desk.png`; the emulator's C: drive, start lists and boot
log are copied out under `X1/files/`, 58 behaviour frames under `X1/frames/`).
X2 (Opus 5.5) was stopped with no output. `warm` (Sonnet, `warm-build.md`).
The doc folds were Sonnet passes (facts dictated by the coordinator from the
reports); the coordinator wrote §Operator decisions 5–6 from the operator's
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
