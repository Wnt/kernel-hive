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

**The cause, verified in bytes (agent U, Opus).** gdb names the crash
`canvas_base::inquire_offset → dsa::~dsa → screen::deref_dsa_usage`: a
window-server command misdispatched. The S80 SDK's `WS32.DLL` reports
`TVersion(1,0,151)`; EKA2L1's `services/include/services/window/protocol.h`
(`legacy_opcodes()`, added 2026-09-23 by yeatse for UIQ 2.1 — upstream PR #731)
selects the legacy table only for `build <= WS_OLDARCH_VER || os_ == epoc70`,
so **Series 80 (`epoc7`) gets the modern table, which is piecewise off**: +1
from `Size` 0x0c through `Identifier` 0x57 (raw `Activate` 0x0d decodes as
`Size` — windows never activate, hence black frames; `SetName` 0x3d decodes as
`Name` — window groups keep generic names, which breaks `TApaTaskList::FindApp`
and SysAp's Desk lookup; `CaptureKey` 0x27 decodes as `SetNoBackgroundColor`),
−1 for `SetNonFading`/`FadeBehind`/`EnableScreenChangeEvents` (0x5c–0x5e),
aligned again from 0x64. S's "unimplemented window group opcode 0x24 / 0x4F /
0x57" are exactly S80's raw `EnableReceiptOfFocus`, `EnableModifierChangedEvents`
and `Identifier`. Session opcodes match; the GC (`gcop.def`) and FBSCLI tables
are not yet byte-checked. **The fix is a full S80 opcode table, ~1–1.5 days,
S80-specific** (upstream tests UIQ and S60, never S80). The rest of U's ranked
gap list: boot the shell properly (SysAp/`Startup.app`/prestarted apps or run
`Starter.exe` from ROM, 1–2 d), task-switch notifications (group-list/focus
events are stubbed, 2–3 d), Communicator keymap + modifiers (1–2 d), EikSrv
surface (2–5 d), four missing TrueType fonts in the dump, Documents/Sheet file
dialogs, Web's IAP picker (2–5 d), and the frontend items (headless/shm output,
input socket, install CLI, update-check off, 3–5 d). The Desk shell is an
ordinary `desk.app`; EKA2L1 replaces the system servers with HLE, launches apps
through the ROM's own `apprun.exe`, starts ROM servers it lacks on demand, and
already runs several apps at once with window-list/focus/bring-to-front — so a
Desk-with-switching experience is plausible once the table lands.
**A fix spike (Fable) is implementing that table on a fork branch as this is
written; its framebuffer result decides Route 1.**

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
  (identical in both SDKs) is single-computer, no redistribution, **no reverse
  engineering** — read the headers, never disassemble the emulator binaries.
  (Agents C, H.)

### H3 — The network plane

- **EKA2L1** reimplements ESock: guest TCP/UDP become host sockets from the
  emulator process (changelog 0.0.9; 2026 EKA1 work `a8f33265` adds the
  `hosts:` DNS override map in `config.yml`, `eee48639` a "host-backed connection
  through native CommsDB records on EKA1"). **But the same ABI class of bug as
  §H1 sits in the socket server** (agent Y, from the SDK's `ESOCK` client
  library): EKA2L1 decodes every Symbian 7.0s socket call with 6.1 numbers
  (Connect is 0x13 on 7.0s, EKA2L1 expects 0x0F; name lookup 0x29 vs 0x25),
  Opera's connection calls (0x3D–0x4F) are not handled at all and unknown
  requests are never answered, and the host-backed CommsDB path is mapped only
  for N-Gage's 6.1 (the 9300i log shows it skipped). So Opera cannot get online
  until the fork adds a 7.0s socket table plus RConnection support — the second
  table after the window server's. There is **no NIC to tap**: joining the
  retronet means a network namespace with a veth onto `vmbr-rn` and the `hosts:`
  map; Opera has **no proxy keys** in `Opera.ini` (proxy is per access point in
  CommDB) and always asks for an access point, and with retronet's wildcard DNS
  and vhosts no proxy is needed. First proof: a corpus page painted in Opera
  from inside the netns.
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
- **EKA2L1**: host keys pass through a keybind profile to guest scancodes; **an
  unbound host key is dropped and modifiers are always 0**
  (`window.cpp:1776`); the default profile maps F1/F2/Return/arrows and the S80
  "workaround" maps `device_3`→Enter, `'5'`→Space. A full QWERTY profile for a
  Communicator must be authored (`--keybindprofile`), and shifted/upper-case and
  Chr are unverified. Qt mouse events are forwarded as pointer events, inert on
  a no-touch device. (Agent A.)
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

## Routes

### Route 1 — EKA2L1 + real ROM, host-native in nspawn

The fast path to the real firmware's applications — **days, not weeks — if the
Symbian 7.0s ABI tables land** (§H1: window server; §H3: sockets). Facts: §H1,
§H3–H6. What it is *not*: a boot of the OS — the Desk shell, task switching and
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
1. Does EKA2L1 reach Desk / Word / Sheet / Opera with the 9500 ROM, at what CPU
   cost and boot time? (§H1 spike.)
2. Firmware version and language of the three dumps; why the 9300i dump ships
   `Dev9300.sis` (it would register as RAE-6 and collide with a 9300 install);
   the 9500 needs a hand-written device entry (naming recognises only
   `dev9300.sis`).
3. What is inside the 2005 InstallShield service packages (MCU/PPM/CNT names;
   which file is the ROM) — needed for a QEMU board's flash image.
4. A Communicator QWERTY keybind profile for EKA2L1 incl. Shift/Chr behaviour.
5. Whether the S80 v2 Opera passes the access-point UI on EKA2L1's host-backed
   CommsDB path (tested on N-Gage only).
6. The operator decision on `~@mount` (CRIU) for sub-2 s resets of nspawn
   stations — shared with vision/perq.
7. The 9210: SoC identity, a ROM source, EKA2L1 v1 entry.

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
K (CPU/SoC vs QEMU), L (9210 SoC). Fable: M (QEMU vs MAME decision), S (the
ROM spike). Earlier Sonnet passes — C (SDK sources), D (hardware emulation
survey), E (plane/apps), F (repo integration), G (Wine), H (SDK staging and
inventory) — were used for facts only; the four load-bearing repo citations in F
(amix llvmpipe, riscos Qt5, indyr4400 356%, perq CRIU) were re-verified against
the tree, and D's ground is re-covered by J/K. Mid-session the operator ruled
that Sonnet is for mechanical tasks only; two Sonnet research agents were
stopped and re-run on Opus/Fable.

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
