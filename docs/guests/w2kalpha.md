# w2kalpha — Windows 2000 RC2 (build 2128) for Alpha AXP on es40

**Status: live streamhost tile** (registered 2026-08-11). The second non-QEMU
x11-runtime tile after [`irix`](irix.md): the es40 AlphaServer ES40 emulator
runs Windows 2000 RC2 for Alpha **headless** (no window, no X server),
publishes its framebuffer to shared memory (`SH_CAPTURE=shm`) and takes input
on a mamectl/1 unix socket (`SH_INPUT_BACKEND=mamesock`).

Working-session history and the optimization record live in
[`docs/lab/research/w2kalpha-HANDOFF.md`](../lab/research/w2kalpha-HANDOFF.md)
(entry point), `alpha-nt-add.md` §10 (A/B results log, the 24h-mission 2×
record), and `es40-tuning-research.md`.

## Media and acceptance

- **OS**: Microsoft Windows 2000 Professional, **build 2128 (RC2), Alpha AXP**
  — September 1999, the last Windows ever built for Alpha (the port was
  cancelled with Compaq's August 1999 exit from NT-on-Alpha; RC2 never
  shipped). Preserved beta media, operator-supplied ISO staged as
  `/data/vms/streamhost/assets/w2kalpha/w2k.iso`. Not in Git, never commit it.
- **Emulator**: es40 (AlphaServer ES40 emulator), **fork `Wnt/es40`**, local
  box checkout `/data/vms/soltest/ALPHA-nt/es40src`. The production binary is
  the fork build staged as `assets/w2kalpha/es40` with its shared-lib tree
  under `assets/w2kalpha/root/` (the tile does not depend on any scratch area).
- **Acceptance state**: autologged-on 1280×1024 desktop; the framebuffer is
  the only proof (shm frame, never the serial log).

## Fork features the tile depends on (all in `Wnt/es40` main)

| commit | what |
|---|---|
| `66c5b2f` | shm framebuffer export (`src/gui/shmfb.h`, `ES40_SHM_PATH`) — headless capture, pixel-exact |
| `849039a`+`6986997` | mamectl/1 input socket (`src/gui/ctlsock.h`, `ES40_CTL_SOCK`) — keys + open-loop abs pointer |
| `0e22e9f` | JIT deliverability-gated int kicks + chain-granular IRQ drain + compile-on-2nd-encounter — **2.37×** interactive throughput (Computer Management launch 24.4 s → 10.3 s, n=8) |
| `6a525d1` | media-mailbox lock-free poll (−24.7% boot) |
| `ab75e70`,`d73e4dc` | savestate fix + `ES40_RESTORE` (NOT used by the tile — see reset) |

Build: `cd es40src/src && make -j6` (ccache). One fork commit added a virtual
to `CDisk` — always clean-rebuild across it (stale objects are vtable-broken).

## Device set (`assets/w2kalpha/es40.cfg`)

tsunami system, `ev68cb` CPU at 800M, `memory.bits = 29` (512 MB), pinned
`time = "1999-11-01"` + `arc_year_compat` (W2K RC2 expects a 1999-plausible
ARC clock), `ali` southbridge with `vga_console`, `ali_pmu`, `sym53c810` SCSI
(disk0.0 = writable `img/nt.img`, disk0.4 = `w2k.iso` cdrom), `s3` VGA
(Trio64 ROM `rom/86c764x1.bin`), two TCP serial ports **21964/21965** (es40
listens; the tile's `pumps.py` connects and drains — es40 blocks on startup
until BOTH have a client). SRM/flash/dpr ROMs under `rom/`. `mouse.absolute =
true`. No `ali_usb` (W2K polls it hot — upstream es40 issues #114/#169).
**`dec21143` NIC at `pci0.4`** (pcap backend on the host-only veth
`w2kalpha-g`) — added 2026-08-11 for the guest telnet exec channel (see
[Telnet exec channel](#telnet-exec-channel)); the guest end is a private
`172.31.64.0/30` veth that `x11-runtime.sh` brings up, **never bridged to the
LAN**, so the exhibit is still air-gapped from anything off-box.

Changing the device set does not invalidate the golden (it is a plain disk
image, not a savestate) but DOES orphan any baked `.axp` savestates.

## Golden

`assets/w2kalpha/nt.img` (4 GiB, sym53c810 disk image), lineage
`/data/vms/soltest/ALPHA-nt/milestones/m5-1280/` — clean 1280×1024 autologon
snapshot, taken before the dev rig's working disk was corrupted (the golden is
a separate clean copy; the rig is retired). The launcher never opens it for
write: every launch reflink-copies it.

**Active Desktop Recovery wart — FIXED 2026-08-11.** The golden used to
intermittently cold-boot into "Active Desktop Recovery" (an IE error page over
the desktop). The current golden (re-baked 2026-08-11) has "Show Web Content"
unchecked in `desk.cpl` and a plain wallpaper, so the recovery page no longer
appears — verified clean on 4/4 cold boots. The pre-x86prog golden is preserved
on the box as `assets/w2kalpha/nt.img.bak-prex86prog-20260811` for rollback (and
`es40.cfg.bak-nonic` is the device set before the NIC was added).

### What else the 2026-08-11 re-bake baked in

- **FX!32 / x86 translation populated.** Several x86 Win32 apps were run once so
  FX!32 profiled and cached them to native Alpha code; **`x86prog`** (System
  Properties → Advanced → Performance → "x86 Program Optimization", or run
  `x86prog`) now lists them at 100%: **Winamp 2.5e** (`Winamp.exe`, installed to
  `C:\Program Files\Winamp` with the MP3 + Disk Writer plugins), the Winamp
  installer, and Solitaire / FreeCell / Minesweeper / Calculator / Notepad
  (x86 copies under `C:\Apps`). Winamp 2.5e was installed on a throwaway x86
  win2000 clone and the program folder copied in offline — its own installer
  will not complete on the Alpha (see the interactive-x86 note below).
- **Guest static IP + Telnet Server auto-start** for the exec channel below.

**dxdiag is the clearest architecture view.** `dxdiag` (DirectX Diagnostic Tool)
System page reports the processor outright as **"Alpha 21264 Model A - Pass 2"**
— far more legible than System Properties' `DEC-221264` string. It is the new
gallery hero (`spa/public/posters/w2kalpha/dxdiag.webp`), with `x86prog.webp`
alongside it.

## Runtime (tile dir `/data/vms/streamhost/tiles/w2kalpha/`)

`x11-runtime.sh` (tracked: `streamhost/tiles/w2kalpha/x11-runtime.sh`) —
kill-by-pidfile, fresh `work/` + reflink golden copy, then headless es40
(`SDL_VIDEODRIVER=dummy`, `ES40_SHM_PATH`, `ES40_CTL_SOCK`) + `pumps.py` on
the serial pair. **The es40 pid lives in `mame.pid`** — that is the shared
x11-runtime contract name (`ensure-tile-x11.sh` liveness = pid alive AND shm
non-empty; `stop-tile-x11.sh` tears down the same pidfiles), not a claim that
es40 is MAME. `pumps.py` self-exits on any serial-socket EOF/error so a stale
pump can never hold the ports.

- **Reset = `relaunch`** (cold boot ~80 s): service restart → fresh reflink →
  pristine desktop. `ES40_RESTORE` instant-resume is deliberately NOT used: a
  restored guest partial-paints new dialogs (post-restore repaint fragility);
  the prime suspect is wall-clock RPCC/interval-timer baselines not being
  re-anchored in `CAlphaCPU::RestoreState` — fix that, re-verify, and the
  tile can move to instant-resume reset.
- **Idle auto-pause is OFF** (`SH_IDLE_PAUSE_SECS=0`) for the same clock-
  discontinuity reason — SIGSTOP/SIGCONT would hand the guest a wall-clock
  jump. Copy irix's SIGSTOP stanza only after the RPCC re-anchor fix.
- Scratch clones: namespace EVERYTHING (dir, shm, socket, and the two serial
  ports — the production tile owns 21964/21965 via es40's listen bind).

## Input

- **Keyboard: PASS** (framebuffer-proven: Start menu, Run dialog, full
  `desk.cpl` control-panel drive over the socket, 2026-08-11). Key fields are
  Bochs-style names (`ctlsock.h` `field_to_bxkey`): `Left Win`, `Left Ctrl`,
  `Tab`, `Enter`, `Space`, `Cursor *`, `F1`..`F12`, …
- **Pointer: open-loop absolute, NOT yet pixel-exact** (`reset.mouse`
  UNVERIFIED). The guest still runs default Windows pointer acceleration, so
  injected motion overshoots (observed: MOVEA 522,141 pinned the cursor to the
  top-left corner). The golden-polish pass (acceleration → None) is what makes
  MOVEA land 1:1; keyboard is the reliable drive channel until then.
- Client for hand-driving: `/data/vms/soltest/ALPHA-nt/uibench/ctltest.py
  <ctl.sock> <script>` (`K`/`TYPE`/`MOVEA`/`DOWN1`/`SLEEP` verbs);
  screenshots via `uibench/shmread.py <fb.shm> <out.png>`. **ctltest only types
  letters, digits and a few punctuation chars** — for `=`, `%`, `"` etc. drive
  the guest over the telnet channel instead.

## Telnet exec channel

`labctl exec w2kalpha "<cmd>"` runs a command in the guest and returns its
**captured stdout + exit code** — the same contract as the ssh/warpd/serial
tiles. Wiring (all live 2026-08-11):

- **Transport:** the `dec21143` NIC (`pci0.4`, pcap backend) on the host-only
  veth `w2kalpha-h`/`w2kalpha-g` that `x11-runtime.sh` brings up. The guest holds
  a **static IP `172.31.64.2/30`** (baked into the golden); the host answers on
  `172.31.64.1`. Nothing bridges to the LAN — reachable only from the box.
- **Guest side (baked):** the W2K **Telnet Server** is set to auto-start, with
  **NTLM off** so a plain login works, and the Administrator password is blank.
- **Helper:** `streamhost/guest-agents/w2kalpha/w2ktelnetexec.py` → box
  `/root/w2ktelnetexec.py`. It refuses telnet option negotiation, logs in
  (prompt-driven), wraps the command in `errorlevel`-bearing sentinels, and
  renders the W2K VT100 *console* stream (absolute cursor moves) back to plain
  text. `labctl`'s `exec_kind: telnet_e` routes to it.
- **Known limitation:** `dir /b "<quoted path with spaces>"` returns empty (a
  W2K console quirk for that exact form); every other command form — quoted
  paths, spaces, `%VARS%`, `if exist`, 8.3 short paths — works. Also the server
  is single-threaded, so keep exec calls sequential.

**Interactive-session x86 does NOT work — telnet-session x86 does.** x86 apps
(FX!32) launch fine from the *telnet* (network-logon) session but fail with "The
system cannot find the path specified" from the *interactive* auto-logon console
session — reproducible across a clean reboot, identical PATH, same Administrator
user. So x86 GUI apps cannot be shown on the framebuffer; they are run once over
telnet to register them in FX!32, and `x86prog` (a native Alpha app) displays
the list on the console. Root cause unresolved (leading theory: the FX!32 server
services x86 launches on a window station the interactive session can't reach).

## Verification (the release gate that was run)

1. Framebuffer: `shmread.py` frame is a 1280×1024 desktop (not black, not the
   ARC/AlphaBIOS screen) after ~80 s.
2. Input: keyboard verbs over `ctl.sock` visibly drive the guest (dialogs
   open/close in the framebuffer).
3. Reset: `systemctl restart streamhost@w2kalpha` cold-boots a pristine
   desktop from a fresh reflink copy.

## Rollback

- Tile off: `systemctl stop streamhost@w2kalpha` (ExecStop kills by pidfile).
- Binary: control builds preserved on the box (`es40.O2/O3/pgo/lto` beside the
  staged binary); the fork's commits are individually revertable (each was
  A/B-verified in isolation).
- Registry: set `enabled: false`, regenerate, republish the runtime manifests
  (three documents: `serve/tiles.json`, `webroot/gallery-manifest.json`,
  `serve/golden-manifest.json`).

## Remaining work (tracked in w2kalpha-HANDOFF.md)

golden polish + re-capture (Active Desktop off, wallpaper None/BMP, 1:1
mouse) → then flip `reset.mouse` after a MOVEA/DOWN1 proof; post-restore
RPCC re-anchor → instant-resume reset; guest telnet channel (needs emulated
NIC); guest de-bloat; PGO final rebuild (+10% measured).
