# OS/2 Warp 4 gallery station — notes for the orchestrator

**Station:** IBM OS/2 Warp 4 (1996, "Merlin") — Workplace Shell desktop
**Port:** http://192.0.2.12:**8108**/?usr=guest&pwd=neko
**Build script:** `scripts/build-guests/tiles/os2warp.sh` (from-scratch, reproducible, `bash -n` clean)
**Checkpoint image (labhost):** `/data/gallery-guests/OS2Warp/os2.qcow2` → in container `/guests/OS2Warp/os2.qcow2`
**Proof screenshot:** `/data/gallery-guests/OS2Warp/os2-warp4-desktop.png`
**Status:** LIVE + framebuffer-verified. Now **Warp 4.52 (MCP2) at 1024×768×64k**
on `-vga std` via IBM GENGRADD (2026-07-27) — see "SOLVED" at the end of this doc;
the 640×480 sections below are historical.

> **Historical (neko-era) wiring below.** OS/2 runs today as the streamhost station
> **`os2warp`** — see its stanza in `streamhost/stations-manifest.sh`
> (`streamhost@os2warp`). The neko compose/:8108 wiring and the
> `gallery-integrate-all.sh` manifest row below are neko-era; that integrator was
> deleted in the 2026-07 restructure — git history. Build script, licensing and
> guest quirks still apply.

---

## Licensing (copyrighted media — free in this private collection)

IBM OS/2 Warp 4 is copyrighted IBM media (no free/open license). Sourced
from the Internet Archive (item `os2warp4_20240227`), it is **free to use in this
private, LAN-only home-lab collection**, same stance already applied to the Win
9x/XP/2000 and macOS stations. The only rule: don't re-distribute the copyrighted
binary media via the GitHub repo; and never expose the station to the public Internet.
The **modern, legally-licensed** OS/2 path is **ArcaOS by Arca Noae (paid)** — use
that for any real/commercial OS/2 work. No faithful free/open OS/2 exists.

---

## Live station — isolated compose service (already applied)

Deployed as its **own** compose project `osgallery-os2warp` from
`/opt/osgallery/docker-compose.os2warp.yml` **inside CT 110** (mirrors the
TempleOS / SailfishOS isolation pattern), so it never touches the concurrently
edited `docker-compose.gallery-guests.yml`. Bring up / recreate ONLY this station:

```bash
# inside CT 110 (pct exec 110 -- ...)
cd /opt/osgallery
docker compose -p osgallery-os2warp -f docker-compose.os2warp.yml up -d
```

### Compose service (verbatim)

```yaml
services:
  os2warp:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8108:8080","53900-53919:53900-53919/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]     # present for parity; OS/2 runs TCG, not KVM
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53900-53919"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "IBM OS/2 Warp 4"
      QEMU_MEM: "128"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc,acpi=off,usb=off"
      QEMU_VGA: "cirrus"
      QEMU_SOUND: "-device sb16,audiodev=snd"
      GUEST_DISK: "/guests/OS2Warp/os2.qcow2"
      GUEST_FMT: "qcow2"
      GUEST_IF: "ide"
      GUEST_BOOT: "c"
      QEMU_EXTRA: "-cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot"
```

> **Port note:** UDP EPR block is **53900-53919** (not the next-sequential block).
> Sibling builders were rapidly claiming 53320-53419 during this build, so a high
> block was chosen to avoid the collision frontier. HTTP is **8108** as assigned.

### Canonical manifest row (historical — the reconciliation never ran; `gallery-integrate-all.sh` is neko-era, deleted)

```
os2warp | IBM OS/2 Warp 4 | 8108 | 53900-53919 | qcow2 | /guests/OS2Warp/os2.qcow2 |
  MACHINE=pc,acpi=off,usb=off MEM=128 SMP=1 VGA=cirrus SOUND="-device sb16,audiodev=snd"
  IF=ide BOOT=c EXTRA="-cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot"
```

### Gallery index

Added to BOTH `/opt/osgallery/gallery/index.html` and `.../gallery-guests.html`
`OSES[]` arrays (idempotent insert before the array terminator):
`{"label":"IBM OS/2 Warp 4","url":"http://192.0.2.12:8108/?usr=guest&pwd=neko"}`

---

## Equivalent raw QEMU command (validated on host, QEMU 11.0.0)

```bash
qemu-system-x86_64 -machine pc,acpi=off,usb=off -cpu pentium -m 128 -smp 1 \
  -hda os2.qcow2 -boot c -vga cirrus -rtc base=localtime \
  -device sb16,audiodev=snd \
  -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot
```

## OS/2-under-QEMU pitfalls captured into the profile (all verified)

- **TCG ONLY.** OS/2 will **not** boot under KVM / hardware virtualisation. The
  station leaves `/dev/kvm` mapped for parity but QEMU runs pure TCG for this guest.
- **`acpi=off,usb=off`.** OS/2 Warp 4 predates ACPI (leaving it on wedges boot);
  it has **no USB stack**, so `usb-tablet` gives no cursor → **PS/2 mouse only**
  (relative pointer; the gallery's neko input maps to it fine).
- **`-cpu pentium` + `-smp 1`.** The image ships a uniprocessor kernel.
- **(HISTORICAL) `-vga cirrus` — OS/2 ran its BASE VGA driver, not a Cirrus one.**
  *Superseded: the station now runs `-vga std` at 1024×768 — see "SOLVED" below.*
  QEMU emulates Cirrus *hardware*, yet the guest's active PM display driver is the
  generic **base VGA** (`BVHVGA` in `CONFIG.SYS`, `SET VIDEO_DEVICES=VIO_VGA`),
  locked to **640×480×16 colours** (the System→Screen notebook lists only
  `640 x 480 x 16`; screendumps are 4-bit). `std`/`qxl` give a black screen because
  OS/2 has no driver for those either. Earlier revisions of this doc claimed a
  "Cirrus 640×480×8" driver — that is INCORRECT; the resolution CANNOT be raised on
  this checkpoint, see the 2026-07-27 investigation below.
- **IDE disk.** qcow2 as primary IDE master; mounted read-only + `-snapshot` so
  every visitor session is ephemeral.

---

## How the seed image is prepared (what os2warp.sh automates)

The archive qcow2 is a **pre-installed** Warp 4.0 captured **mid-first-boot**, so a
naive boot lands on the *IBM Software Registration* wizard over a stray
`REQ0815: cannot get connection ID` network error. `os2warp.sh` makes it
museum-clean, fully unattended:

1. **Download** pristine qcow2 (archive.org, cached-by-size).
2. **Tame first-boot** — headless boot + framebuffer-gated monitor keystrokes:
   dismiss the REQ0815 error → cancel registration (Tab→Cancel→confirm) → close
   the leftover WIN-OS/2 setup window → **clean Workplace Shell shutdown** (right-
   click desktop → Shut down…) so the past-first-boot state is flushed to disk.
3. **Disable the LAN nag** — the image's C: is FAT16, so via `qemu-nbd` we REM the
   three NetWare Requester daemons (`DDAEMON`/`SPDAEMON`/`NWDAEMON`) in
   `C:\CONFIG.SYS` (they try+fail to attach to a NetWare tree each boot, re-popping
   REQ0815). Original preserved on-image as `C:\CONFIG.NWO`.
4. **Verify** — a fresh `-snapshot` boot must reach the **bluish** WPS desktop
   (asserted distinct from the gray registration wizard); saves the proof PNG.

Re-runnable/idempotent: rebuild the seed with `--force`; the pristine download
is cached. If the automated tamer ever mis-times on a very slow host, the manual
fallback is the identical 6-step keystroke path documented in the script body.

## Curated metadata (for the UI placard)

- **Name/version:** IBM OS/2 Warp 4 ("Merlin"), 1996
- **Lineage:** IBM OS/2 (1987, orig. joint IBM–Microsoft) → OS/2 2.x (1992, 32-bit)
  → Warp 3 (1994) → **Warp 4 (1996)** → Warp 4.5x/eComStation → **ArcaOS** (2016+).
- **One-liner:** IBM's ambitious 32-bit, preemptively-multitasking PC OS with the
  object-oriented **Workplace Shell** desktop; famous for the elephant mascot,
  Netscape/WebExplorer, VoiceType speech, and running DOS/Win3.1 apps in WIN-OS/2.
- **Iconic era software on-image:** Workplace Shell, WebExplorer, "Get Netscape
  Navigator", WIN-OS/2 (Windows 3.1 subsystem), MMOS2 multimedia, Java-for-OS/2.
- **Archetype hint:** mid-90s beige business PC — beige desktop/tower + CRT
  (beige-tower-crt), the "corporate workstation that wasn't Windows".

---

## Perf rollout — KVM test-then-adopt result (2026-07-04)

The perf plan classified :8108 as **test-then-adopt** (try KVM, revert if it does
not fully boot + accept input). **Empirically re-tested and REVERTED to TCG.**

- **Change tested:** added `-enable-kvm` to `QEMU_EXTRA` (kept `-cpu pentium`,
  `pc,acpi=off,usb=off`, Cirrus), `--force-recreate`.
- **Result:** QEMU stayed up (no crash-loop) but the guest **hung at the MBR
  handoff** — framebuffer frozen at SeaBIOS `Booting from Hard Disk...` for 60 s+
  (byte-identical neko screenshots); the OS/2 kernel never loaded. Classic OS/2
  triple-fault under hardware virtualisation.
- **Reverted:** restored the TCG compose (`docker-compose.os2warp.yml`) from a
  pre-test backup + recreated. Verified: WPS desktop renders (neko shot ~141 KB,
  matching baseline; clock ticking) and input reaches the guest — harness
  `gallery-input-probe.py` mouse probe = **5 hits / 0 misses** (framebuffer
  changes on every injected cursor move). **`reverted=true`.**
- **Conclusion:** the "TCG ONLY" pitfall above is confirmed by measurement, not
  just lore. Do **not** flip this station to KVM.
- **Audio-buffer knob (gallery-wide):** applied automatically at the image layer —
  the current `neko-qemu:latest` `launch-qemu.sh` emits
  `-audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000` by default, so a
  plain recreate now carries the 100 ms buffer / 50 ms latency hardening with **no
  compose change**. No usb-tablet / resolution tuning applies (OS/2 is PS/2-only,
  Cirrus 640×480 — hardware-locked per the pitfalls above).

---

## Absolute pointer — in-guest warpd agent (2026-07-16, full mouse)

The gallery streamhost station now runs `SH_POINTER=warpd` for **absolute cursor
tracking** (the PS/2 homing-rel bridge drifted badly under OS/2 PM pointer
acceleration). The in-guest agent sources live under `streamhost/guest-agents/os2/`
built with **OpenWatcom 1.9** (`wcl386 -bt=os2 -l=os2v2_pm -fe=WARPD.EXE`; V2's
runtime crashes on Warp 4 GA), delivered to `C:\WARPD.EXE` and autostarted from
`STARTUP.CMD` (`'start C:\WARPD.EXE'` — must be REXX-quoted).

**What made the long-"move-only-in-theory" agent actually work** (verified 1:1 by
framebuffer screendump — cursor jumps precisely to each commanded `M x y`):

1. **DCB fix (the blocker).** COM.SYS opens COM1 in a blocking read-timeout mode
   (`fbTimeout` ~0xd2) where `DosRead` never returns our short newline commands.
   The agent now issues `DosDevIOCtl(IOCTL_ASYNC, ASYNC_SETDCBINFO, …)` forcing
   `MODE_NOWAIT_READ_TIMEOUT` and dropping DSR/CTS handshaking (QEMU's socket
   chardev asserts no modem lines). Without this, zero bytes ever reach the agent.
2. **PM message queue.** `WinCreateMsgQueue` after `WinInitialize` — required before
   the thread may drive `WinSetPointerPos`.

**Transport (device-set-safe).** A unix-socket serial chardev bound to the machine's
**default `serial0`** (`-chardev socket,id=ser0,… -serial chardev:ser0`) — adds no
new `-device`, so `loadvm golden` still matches. `SH_WARPD_ADDR=unix:…/serial.sock`.

**Checkpoint / boot.** The checkpoint is recaptured with `WARPD.EXE` already
running; the launcher gained the standard `-loadvm golden` conditional (os2warp was
the only station lacking it) and the disk carries **no `-snapshot`**, so every start
restores the clean desktop + live agent and the OS/2 "register" nag never reappears.

**Full button/drag fix.** The original agent collapsed every `P` into an immediate
posted down+up pair, ignored `R`, never delivered held-button motion, and passed
desktop coordinates to windows that require client coordinates. That could select
some controls but could not resize a frame, reliably open menus, or drive Mahjongg.
It also bypassed PM's input queue, so two posted clicks never became a native
double-click.

Every absolute move now calls both `WinSetPointerPos` and `MouSetPtrPos`. The
second call synchronizes OS/2's native mouse subsystem with the visible PM pointer.
Production therefore uses `SH_WARPD_BUTTONS=qemu`: real PS/2 down/up events get PM
capture, border tracking, menu, game, and double-click semantics at the exact
warped position. `SH_WARPD_BUTTON_DELAY_MS=80` orders the asynchronous serial warp
before the PS/2 button. `SH_WARPD_WHEEL=agent` keeps wheel 4/5 on the separate
agent path. The agent's fallback `P/R/C/D/U` path was fixed as well:
separate down/up state, capture-aware held motion, desktop-to-client mapping, and
explicit `WM_BUTTONxDBLCLK` detection.

The clone framebuffer proof opened both **Game** and **View**, selected a Mahjongg
tile, and resized the Mahjongg window by dragging its bottom border. The wheel
mapping is also corrected: protocol 4/5 sends `WM_VSCROLL` with
`SB_LINEUP`/`SB_LINEDOWN` instead of collapsing both directions to PM button 3.

**Latest-wins move coalescing (2026-07-26).** Under `-accel tcg` a starved guest
applies moves (`WinSetPointerPos` + `MouSetPtrPos` + capture posts) slower than the
daemon's paced ~33 fresh positions/s, so the OLD per-`M` `DosRead` loop let an
unbounded backlog pile up in the COM RX buffer and the cursor rubber-banded ever
farther behind. The agent now mirrors the Win9x/Win311 serial agents (and the
daemon's own per-window coalescing in `warpd.rs`): within each `DosRead` drain it
PENDs only the newest `M` and applies it once via `flush_move()`; any
button/wheel/drag verb (`P/R/B/C/D/U/W`) flushes the pending move first so click and
drag ordering/position stay correct; the final pended position is applied once the
port is drained. Verified on a `/data/vms/soltest` clone under an 8% CPU throttle
(reproducing encoder starvation): with the OLD agent a 167/s feed backlogged
9.2 s (T=1) → 26 s (T=3) — settle grows with feed length; with the coalescing agent
the same feed settled in ~0.1–0.5 s flat, and a pace=30 18 s hover on the recaptured
live checkpoint settled in **21 ms** with no growth. This let the temporary
`SH_WARPD_PACE_MS=50` stopgap revert to `SH_WARPD_PACE_MS=30`. Agent source
`streamhost/guest-agents/os2/warpd_os2.c`, rebuilt with OpenWatcom 1.9
(`wcl386 -bt=os2 -l=os2v2_pm -fe=WARPD.EXE`); checkpoint recaptured 2026-07-26, rollback
backup `/data/gallery-guests/OS2Warp/os2.qcow2.pre-coa.bak`.

**Rollback.** The pre-full-mouse checkpoint is
`/data/gallery-guests/OS2Warp/os2.qcow2.pre-mouse-20260716T2352Z`
(SHA-256 `4a6385ee84e2b672a086fc438dc12289dfda68639f3dcfb2b347ba6e2c266cdc`).
Stop only `streamhost@os2warp`, stop its QEMU by the station pidfile, restore that
file over `os2.qcow2`, restore the prior agent-button registry/env values, run
the registry generator plus `labctl gen`, and restart only the OS/2 service.

---

## Resolution + wheel recapture investigation (2026-07-27)

Attempted to (a) raise resolution toward 1280×1024 and (b) re-verify / fold in the
"long-pending mouse-WHEEL fix". Investigated entirely on a `/data/vms/soltest`
clone (byte copy of the live checkpoint, identical device set, `loadvm golden`), with
every step framebuffer-verified. **Live checkpoint, service, and all backups were
left untouched — no recapture was performed, because nothing needed to change.**

### Wheel — already fixed; NO change needed (debt is stale)

The "wheel bug" tracked in memory ("os2 wheel → middle-click, pending re-bake")
was **already resolved** by the `WM_VSCROLL` rework that is in the current source
AND captured into the live checkpoint. The live wheel path is: browser wheel → daemon
`realtime_input.rs` emits `B 4 x y` (up) / `B 5 x y` (down) → agent `pt_wheel()`
posts `WM_VSCROLL` `SB_LINEUP`/`SB_LINEDOWN` to the window under the pointer.
Framebuffer proof on the checkpoint clone (exact verbs the daemon sends):

- **EPM / System Editor** (MLE-style edit window): wheel-up scrolls up
  (rows 36–45 → 32–43), wheel-down scrolls back down. **Works, both directions.**
- **WPS folder container** (Drive C, Tree view, WC_CONTAINER): wheel-down scrolls
  the tree (Desktop/OS2/PSFONTS scroll off the top). **Works.**
- No spurious middle-click is produced (verbs 4/5 route to `pt_wheel`, never
  `pt_button`), confirming the original false-`WM_BUTTON3` bug is gone.
- **Known minor gap:** a PM `WC_LISTBOX` (e.g. the DSPINSTL driver list) does NOT
  wheel-scroll — its scrollbar is not driven by a `WM_VSCROLL` posted to the
  listbox window. Listboxes are a rare museum interaction; the dominant scrollable
  widgets (editors, folders) work. The agent was **left unchanged** (zero
  regression risk to the working coalescing + wheel + button agent; the
  latest-wins hover coalescing is trivially preserved). If a future run wants the
  listbox case, `pt_wheel` would need to walk to the listbox owner / use `LM_*`,
  and must re-verify EPM + container still scroll.

### Resolution — BLOCKED at 640×480×16 (fell back; could not raise)

The goal (1280×1024, fallback 1024×768) is **not achievable on this checkpoint**, and
the blocker is earlier than the task anticipated ("cirrus corrupts above
1024×768"): OS/2 cannot even bring up *any* SVGA mode on QEMU's Cirrus.

- The System→Screen notebook lists **only `640 x 480 x 16`** — the guest runs the
  **base VGA** driver (`BVHVGA`), not an SVGA/Cirrus driver.
- The generic OS/2 SVGA display-driver DLLs *are* on disk (`IBMDEV32.DLL`,
  `VIDEOPMI.DLL`, `BVHSVGA.DLL`, `VIDEOCFG.DLL`, `SVGA.EXE`) but the chipset mode
  table `\OS2\SVGADATA.PMI` is **absent**, so the SVGA driver cannot be activated.
- `SVGA ON` / `SVGA ON INIT` — run windowed AND in a full-screen OS/2 session —
  produce **no output and no PMI**; `SVGA STATUS` is empty. OS/2's `SVGA.EXE`
  **cannot detect/identify QEMU's emulated Cirrus GD5446**.
- Selective Install (`DSPINSTL`) → Primary Display → "Cirrus Logic
  5426/5428/5430/5434" (`CL54X.DSC`, the family incl. the GD5446) fails with
  **"SVGA Installation Error — Unable to determine hardware configuration"** (same
  detection failure).
- The chipset-specific Cirrus driver binaries (`CL54XA/B/M`) are **not on disk**
  (only `CL54X.DSC`); they live on the Warp 4 install CD's `OS2IMAGE\DISP_1/2`,
  which is **not present** (the station is built from a pre-installed archive.org
  qcow2 with no `OS2IMAGE`, and the source archive item has no ISO). But this is
  moot — even with the binaries, the chip-detection step still fails.

**Conclusion:** stay at 640×480×16. Any future attempt needs a display path that
does NOT rely on OS/2 auto-detecting QEMU's Cirrus, e.g. a hand-crafted/sourced
Cirrus `SVGADATA.PMI`, the SciTech SNAP driver, or the Warp 4.5x Panorama VESA
driver — each higher-risk and out of scope here, and each still gated by whether
QEMU's TCG Cirrus renders the mode cleanly (the pre-existing "unreliable above
~1024×768" caveat).

### fps

`registry/tiles/os2warp.json` `.stream.fps` was left at **60** (unchanged): the
planned 60→30 drop was justified only by the (non-occurring) resolution jump's
extra encode load, so it carries no independent motivation here.

---

## Hi-res via `-vga std` + generic-VESA GRADD — BLOCKED (2026-07-27b)

Follow-up to the resolution investigation above: a 7-angle study recommended
switching `-vga cirrus` → `-vga std` (Bochs DISPI/VBE, packed-linear, software PM
cursor) and installing a **generic-VESA** display driver that does not depend on
OS/2 auto-identifying the chipset. Investigated end-to-end on `/data/vms/soltest`
clones (byte copies of the live checkpoint, device set cirrus→std, cold-boot,
framebuffer-verified). **The live checkpoint, launcher, service, and all backups were
left untouched — os2warp stays at `-vga cirrus` 640×480×16.** The live checkpoint
SHA-256 was `1736a0cf…` before and after; the launcher line is still `-vga cirrus`.

### What `-vga std` gives us (the good news)

On a std clone the guest boots cleanly: **base VGA 640×480 comes up**, the WPS
desktop builds normally, and the in-guest **warpd** serial agent tracks the PM
pointer 1:1 (software cursor is captured in the scanout). So the *transport* half
of the plan works — std is streamhost-friendly. The blocker is purely the OS/2
display **driver** half.

### Per-candidate results (all four FAIL on QEMU's `-vga std` Bochs VBE)

1. **IBM `SVGA.EXE` / BVHSVGA auto-PMI (cheap probe)** — FAIL. On a std clone,
   `SVGA ON` / `SVGA ON INIT` (windowed *and* full-screen) print nothing, write
   **no** `\OS2\SVGADATA.PMI`, and `SVGA STATUS` is empty. `SVGA.EXE` cannot
   identify QEMU's Bochs adapter (no matching chipset BIOS signature) — the exact
   cirrus failure repeats on std.
2. **SciTech SNAP 3.1.8 (`SDDGRADD`, the lead)** — FAIL. Full path completed:
   `os2_snap.iso` fetched from archive.org, **Warp 4 FixPak 15 applied**
   unattended (`fservice /r:` with a custom `:FLAGS REPLACE_PROTECTED
   REPLACE_NEWER` response file — syslevel went `XRU4000` → `XRUM015`, kernel
   `14.062_W4`), then `SNAP_OS2.EXE` installed cleanly ("unsupported PCI display
   device … will still display high-res modes using the built-in VESA BIOS" — the
   expected notice). But on the first boot into the driver OS/2 **traps**:
   `SDDPMI.DLL` + `VIDEOPMI.DLL`, exception **`c0000005`** (access violation) at
   display init. The SDD engine's VESA-BIOS thunk faults on QEMU's Bochs VBE
   (which lacks the VBE 2.0/3.0 protected-mode interface SDD reaches for) — the
   display never comes up.
3. **IBM `GENGRADD` (in-box generic-VESA GRADD) + FP15** — FAIL, *same* trap. The
   only `GENGRADD.DLL` available post-FP15 on this image is SNAP's 2006 SDD-based
   build (needs `SDDHELP$`); swapping `SET C1=SDDGRADD` → `SET C1=GENGRADD`
   reproduces the identical `VIDEOPMI.DLL`/`SDDPMI.DLL` `c0000005`. GENGRADD and
   SNAP share the SDD/VIDEOPMI engine, so they fail together.
4. **Panorama VESA (free eCS)** — FAIL / unsourceable. The free generic Panorama
   VESA driver is now **commercial** (Arca Noae subscription / ArcaOS-bundled);
   the only freely-downloadable Panorama builds (os2.guru `panorama-2005/2006`)
   are **ATI-Radeon-specific** (`r200grad.dll`, matches only ATI PCI IDs) and will
   not bind QEMU's std VGA. Panorama's generic VESA PMI component *is* extractable
   (`genpmi.dll` — a real VBE2/VESA PMI whose `SVGADATA.PMI` is just
   `#includecode "genpmi.dll"`, exactly the "sourced generic PMI" this doc's
   earlier conclusion called for), but it **requires kernel 14.096+**; installed
   on FP15's 14.062 kernel it hard-**traps 000e** (page fault, `SINGLEQ$`,
   "system is stopped"). FP15 is the last "Merlin" fixpak, so the era-correct base
   cannot reach the kernel Panorama needs.

### Root cause & recommendation

The wall is fundamental to **Warp 4 GA + FP15 on QEMU `-vga std`**: the
era-appropriate generic-VESA drivers (SciTech SDD family = SNAP/GENGRADD) crash on
QEMU's Bochs VBE via `VIDEOPMI`, and the one VM-safe generic-VESA driver
(Panorama) is both commercially gated *and* needs a newer kernel (14.096+) than
any free Warp 4 fixpak provides. No in-image path raises the resolution.

**Recommended next step (user decision — NOT executed, per guardrails):** swap the
exhibit's seed image to **ArcaOS 5.1 / eComStation** (or Warp 4.52 MCP with a
14.1xx kernel). Those ship the modern **Panorama VESA** driver, boot on QEMU
`-vga std`, and do 1280×1024/1024×768 out of the box — but this **changes the
exhibit's OS identity** (Warp 4 "Merlin" → ArcaOS/eCS) and so is deliberately left
as a go/no-go for the maintainer. Until then os2warp remains **640×480×16 on
`-vga cirrus`**, fully interactive with warpd 1:1 + the live coalescing agent.

Reusable artifacts left on labhost: `/data/vms/soltest/os2-isos/os2_snap.iso`
(SNAP 3.1.8 + WP4FP15), and the unattended-FixPak recipe (`fservice
/r:<response>` with `REPLACE_NEWER`, source dir holding `\FIX`, `csfcdromdir`
env). Note the guest keyboard is **UK layout** (backslash = the 102nd/`less`
qcode, not `backslash`) — matters for any QMP send-key path driving it.

## Warp 4.52 (MCP2 / Convenience Pack 2) in-place upgrade — DONE, all apps preserved; hi-res STILL blocked (2026-07-27c)

Executed the previous section's recommendation ("Warp 4.52 MCP with a 14.1xx
kernel"): an **in-place UPDATE** of the GA image to Warp 4.52 CP2 on a
`/data/vms/soltest` clone, preserving the curated apps/games. **Result: the
upgrade works and keeps everything, but hi-res is still blocked** because the only
freely-available CP2 ISO ships kernel **14.089** (not the 14.1xx hoped for; still
< Panorama's 14.096) and the VESA-PMI trap is fundamental to QEMU `-vga std`
regardless of kernel. **The live checkpoint, launcher, service and backups were left
untouched — os2warp stays at `-vga cirrus` 640×480×16.** GA checkpoint backed up first
to `/data/gallery-guests/OS2Warp/os2.qcow2.GA-PRESERVE-<ts>` (checkpoint
intact); all work on a reflink clone. Framebuffer-verified every step.

### ISO / provenance

WinWorld "OS/2 Warp 4.52 (14.089_W4) (CP 2 Refresh)" →
`/data/vms/soltest/os2-isos/mcp2-refresh-{boot,install}-en.iso` (ISO vol
`WARP_4_CP2`). The MCP2 **client** installer is built on the WSeB/Aurora codebase,
so its banners say *"Installing OS/2 Warp Server for e-business"* and it runs
`CHKINST.EXE` — normal, not the wrong media. Installed base level is
`XR04503` / product `5639A6101` (`ver /r` → "Version 4.50, Revision 14.089").

### The in-place-UPDATE recipe (preserves C: apps + non-\OS2 files)

Launcher: `-vga std -m 256 -cpu pentium -machine pc-i440fx-11.0,acpi=off,usb=off`
TCG; disk = `qemu-img snapshot -a golden` copy of `os2.qcow2`; both ISOs as IDE
cdrom `index=1,2`. **Offline (nbd, FAT16) disk prep — the three gotchas that a
bare "update over existing" hits:**

1. **LAN Distance blocks CHKINST.** CHKINST hard-refuses "LAN DISTANCE on drive C"
   as incompatible-must-remove. Its marker is `C:\WAL\SYSLEVEL.LDR`
   (`…IBM LAN Distance Remote`). `rm -rf C:\WAL`.
2. **"Base Product Level is not Valid".** CHKINST rejects the classic GA base
   (`XRU4000`/`5639A6100`) for an over-install and tells you it "must be removed if
   you do not format". Rename `C:\OS2\INSTALL\SYSLEVEL.OS2` → the WSeB-derived
   installer then does a **fresh-but-NO-FORMAT** install into C:, overwriting `\OS2`
   while preserving every non-`\OS2` file (`\GAMES\DOOM`, `\NSC`, `STARTUP.CMD`,
   `WARPD.EXE`). (Insurance: copy `\OS2\APPS` + `\TCPIP\BIN\EXPLORE.EXE` to
   `C:\GALLERY` first — but MCP2 re-ships the games/EPM/WebExplorer anyway.)
3. Installer path: Welcome → Accept **Volume C** → **Do NOT format** → keep FAT
   (non-HPFS warning: continue) → continue past TRUEMODE / OS2-Tutorial / Coaches /
   VoiceType "will be removed / not migrated" notices → feature select (defaults:
   **Tools and Games + OS/2 DOS Support + Multimedia** all checked) → services
   (defaults: **TCP/IP + Netscape Communicator**; File-and-Print-Sharing needs a
   User ID/Password — set one, e.g. `WARP`/`password`) → Install.

**Boot sequencing:** after the phase-1 file copy the VM reboots; the launcher must
flip `-boot d` → `-boot c` so phase-2 (the graphical System-Configuration) continues
from C:. Left on `-boot d` it re-boots the CD into a Welcome loop.

**Post-install fixups (networking install fails, error 1608 → dangling drivers):**
- `REM` the missing-file lines in CONFIG.SYS (`…\SOCKETSK.SYS`, `AFINETK.SYS`,
  `VDOSTCP.VDD`, `VDOSCTL.EXE`, `NWCONFIG`) — else SYS1718 "press Enter" prompts on
  every boot. **CRITICAL: CONFIG.SYS must stay CRLF** — writing LF-only from Linux
  makes OS/2 mis-parse every line → `SYS02068` "unable to operate your hard disk".
- Force plain VGA to dodge the VESA-PMI trap (see below): `SET
  VIDEO_DEVICES=VIO_VGA` / `SET VIO_VGA=DEVICE(BVHVGA)` / `VSVGA.SYS`→`VVGA.SYS` /
  `SET C1=VGAGRADD`.

Boots clean to the 4.52 WPS at **640×480×16**, C: still FAT, ~1.5 GB free.

### Apps/games preserved — verified running on 4.52

All curated content survives. Base games/tools **re-installed fresh by MCP2**
(Klondike/OS2Chess/Mahjongg/EPM/WebExplorer — newer builds); **DOOM**
(`\GAMES\DOOM`) and **Netscape Navigator** (`\NSC`) preserved bit-for-bit by the
no-format install; MCP2 also adds **Netscape Communicator 4.61**. `C:\STARTUP.CMD`
(re-creates the 6 custom desktop objects + `start C:\WARPD.EXE`) survived, and the
old GA desktop is kept as a **"Previous Desktop"** folder. Framebuffer-verified
**Klondike Solitaire** (PM window, full deal) and **DOOM** (full-screen, live HUD)
both launch and run on the upgraded 4.52. warpd 1:1 works (STARTUP.CMD auto-starts
it). Note: this reinstall set **US keyboard** (chosen in the installer), unlike the
GA image's UK layout noted above.

### Hi-res on 4.52 — same wall as the prior section

`-vga std` still has **no working VESA PMI**, so every PMI-based driver traps
`c0000005` at display init — reproduced on 14.089: **GENGRADD** → `GENPMI.DLL`;
**SNAP 3.1.8** (installs cleanly, "unsupported PCI … will use built-in VESA BIOS")
→ `SDDPMI.DLL` + `VIDEOPMI.DLL`. Kernel is **14.089**, still 7 builds below
Panorama's **14.096** floor, and free Panorama is ATI-only. So "Warp 4.52 MCP" only
unlocks hi-res if the kernel is **≥14.096** (a later fixpak/kernel than this CP2
ISO ships) **plus** a licensed generic-VESA **Panorama** — or a seed swap to
**ArcaOS 5.x / eComStation**. Unchanged recommendation, now confirmed against a real
4.52 base.

### Reusable artifacts

Working, VGA-clean **4.52 build preserved** at
`/data/vms/soltest/os2-452-upgrade/install.qcow2` (`CONFIG.VGAOK` = known-good VGA,
`CONFIG.SNAP` = the SNAP/SDDGRADD variant, `CONFIG.PRE452FIX` = as MCP2 left it).
Helper scripts in that dir: `run-install.sh` (clone launcher, `$1`=boot dev),
`mrel.py` (relative-PS/2 dead-reckoning click helper for pre-warpd install
screens), `warpc.py` (drives the in-guest warpd over the serial socket: `M x y`
move, `C x y` click, `D/U`).

> **Superseded 2026-07-27d.** The "needs a 14.096+ kernel + licensed Panorama (or
> ArcaOS)" conclusion above was **wrong about the root cause** and is closed by the
> next section: the station is LIVE at **1024×768×64k** on this very 4.52 build with
> stock QEMU, stock IBM GENGRADD, and no licence purchase.

---

## SOLVED — 1024×768×64k via IBM GENGRADD + `vgamem_mb=2` (2026-07-27d, LIVE)

Four rounds of investigation blamed a missing **VBE Protected Mode Interface**
(fn `4F0Ah`) in QEMU's SeaVGABIOS. That hypothesis was **false**, and disproving it
is what unlocked the fix. Issue
[#15](https://github.com/Wnt/kernel-hive/issues/15).

### Root cause — a 64-entry buffer overrun driven by the BIOS mode count

**No OS/2 driver in the chain ever calls `4F0Ah`.** Disassembly of the shipped
binaries settles it: `GENPMI.DLL`, `VIDEOPMI.DLL`, `GENGRADD.DLL` and `IBMGPMI.DLL`
contain **zero** `4F0A` immediates, and SciTech's own OS/2 platform layer
*deliberately fails* the call before it reaches the BIOS (`src/pm/os2/pm.c`:
*"Due to bugs in the mini-VDM in OS/2, the 0x4F0A protected mode interface
functions will not work … so we fail this function here"*, in the BSD-licensed
[scitech-mgl](https://github.com/kendallb/scitech-mgl) release). SeaVGABIOS also
returns a *clean* "unsupported" (`AX=0x0100`) for `4F0Ah`, and legitimately so —
the function is **optional in VBE 3.0**, which SeaVGABIOS reports.

What GENPMI actually does is enumerate modes over the OS/2 **mini-VDM** (real-mode
`INT 10h` `4F00`/`4F01`) into two fixed-size stack buffers, **neither bounds-checked**:

- `GetAdapterInfo` copies the raw VESA mode-number list with a terminator-only loop
  into `InitPMI`'s `ebp-0xb0` frame slot (~64 words).
- `FillModeTable` stages 64 × 76-byte entries (`0x1300 / 0x4c = 64` exactly) and
  loops until the BIOS terminator, so entry 65 lands on the saved registers and
  return address.

The mode count is therefore the whole ballgame:

| BIOS | modes advertised | GENPMI capacity | result |
|---|---|---|---|
| VirtualBox VBE (`vbetables-gen.c`, 1600×1200 modes `#if 0`'d out) | **36** | 64 | works — the long-standing "GENGRADD is fine on VBox" folklore |
| SeaVGABIOS `-vga std`, **default `vgamem_mb=16`** | **93** | 64 | **overflow → `c0000005`** |
| SeaVGABIOS `-vga std`, **`vgamem_mb=2`** | **46** | 64 | **works** |

SeaVGABIOS prunes its mode table by VRAM only, so **shrinking the adapter's memory
shrinks the mode list**. 2 MB still advertises 1024×768×64k and 1280×1024×256 —
far more than the exhibit needs — while landing comfortably under the 64-entry
ceiling.

### The fix — one QEMU flag plus a guest-side driver restore

**Host side (the entire QEMU change):**

```
-vga std -global VGA.vgamem_mb=2
```

No patched QEMU, no custom VGA BIOS ROM, no `romfile=`, no quilt patch, no binary
patching of IBM's DLLs, and no licence purchase. The `pve/00xx` SeaVGABIOS-PMI
patch that issue #15 proposed as the lead path would have been **dead code**.

**Guest side.** The 4.52 build's IBM GRADD DLLs had been overwritten by the earlier
failed SciTech SNAP install, so they must be restored from the MCP2 CD (in-guest
`UNPACK2`, drive `E:`) and SNAP's PMI stub moved aside:

| bundle | provides |
|---|---|
| `E:\OS2IMAGE\DISP_1\VGA` | `GENPMI.DLL`, `VIDEOPMI.DLL`, `IBMGPMI.DLL`, `BVHSVGA.DLL`, `BVHVGA.DLL`, `DISPLAY.DLL` |
| `E:\OS2IMAGE\DISK_4\GRADD` | `GENGRADD.DLL`, `VGAGRADD.DLL`, `GRE2VMAN.DLL` |
| `E:\OS2IMAGE\DISK_4\BUNDLE /N:VMAN.DLL` | `VMAN.DLL` |
| `E:\OS2IMAGE\DISK_1\BUNDLE /N:GRADD.SYS` | `GRADD.SYS` |
| `E:\OS2IMAGE\DISK_3\BUNDLE /N:SBFILTER.DLL` | `SBFILTER.DLL` |

Then `\OS2\SVGADATA.PMI` — which SNAP left as a one-line `#includecode
"sddpmi.dll"` stub — must be renamed. Leaving it in place makes `BVHSVGA` load the
SNAP engine, and the boot dies at **"Unable to open SDDHELP$ helper device driver! /
Fatal error in driver"** *before* the display driver is ever reached. IBM's
GENGRADD needs no PMI file at all. `CONFIG.SYS` (CRLF!) then reads:

```
SET VIDEO_DEVICES=VIO_VGA
SET VIO_VGA=DEVICE(BVHVGA)
DEVICE=C:\OS2\MDOS\VVGA.SYS
SET C1=GENGRADD,SBFILTER,VGAGRADD
```

Resolution is picked in **System Setup → System → Screen** (the list now runs from
640×400×256 up to 1600×1200×256) and applied on the next reboot. **1024×768×65536**
is what shipped.

**Tooling:** `scripts/dev/os2-gengradd-hires.sh` (`prep` / `run` / `shot`) scripts
the offline disk surgery and the clone launcher; run it on labhost against a
`/data/vms/soltest` clone.

### Acceptance (all framebuffer-verified on the clone, then live)

- `labctl shot` → crisp readable WPS text at **1024×768**, software PM cursor
  present in the screendump.
- Settle: 5 consecutive screendumps differ only in the ~70 bytes of the WarpCenter
  clock digits — no tearing, no partial repaints.
- warpd 1:1 absolute pointer lands on target, and a **held-button window drag**
  (dragging a confirmation dialog clear of its parent) tracks correctly.
- Capture gate: `[capture] ScanoutMap 1024x768 stride=4096 off=0 fmt=0x20020888` —
  packed 32bpp, exactly what streamhost's dbus capture needs.
- Apps preserved and running on the hi-res build: **DOOM** (full-screen DOS
  session, live HUD) and the WPS games/tools from the 4.52 upgrade.
- `savevm golden` → fresh `-loadvm golden` restores the 1024×768 desktop with
  warpd live; `labctl reset os2warp` verified against the live station.

### Live cutover (done)

- Checkpoint: the 4.52 apps-preserved build recaptured at 1024×768 →
  `/data/gallery-guests/OS2Warp/os2.qcow2`.
- Launcher `tiles/os2warp/qemu-streamhost.sh`: `-vga cirrus` → `-vga std -global
  VGA.vgamem_mb=2`, `-m 128` → `-m 256`. Everything else — TCG, `-cpu pentium`,
  `acpi=off,usb=off`, sb16, pcnet, the COM1 warpd chardev — is unchanged.
- `registry/tiles/os2warp.json` retargeted (`deviceSetId` `os2warp-std-1024x768`,
  memory 256, fps **60 → 30** to match every other hi-res station at 2.56× the pixels)
  and regenerated; `labctl gen` re-run.
- Startup-folder cleanup: the three broken MCP2 startup objects (TCP/IP Startup,
  Network Messaging, MFS Setup — all pointing at binaries the failed networking
  install never delivered) were deleted, and the dangling `NWCONFIG`/`IBMEANDI`
  `DEVICE=` lines REMmed, so the boot no longer stops on SYS1718/SYS1201 prompts.

**Rollback.** The Warp 4 GA 640×480 checkpoint is kept at
`/data/gallery-guests/OS2Warp/os2.qcow2.GA-640x480-20260727T183735Z` (and
`os2.qcow2.GA-replaced`), with the pre-change launcher at
`tiles/os2warp/qemu-streamhost.sh.cirrus-640-bak` on labhost. To revert: stop
`streamhost@os2warp`, kill its QEMU by pidfile, restore both files, revert the
registry entry + `labctl gen`, restart the service.

### Desktop shortcut regression and repair (2026-07-27, LIVE)

The first hi-res checkpoint retained the application binaries but lost their visible
WPS desktop objects. The matched reference was
`/data/gallery-guests/OS2Warp/os2.qcow2.GA-PRESERVE-20260727T132806Z`; its
640×480 framebuffer showed the original gallery layout. The secondary
`os2-452-mcp2-apps-preserved.qcow2` snapshot had a bare desktop and was not the
layout to reproduce.

The missing inventory was:

| desktop title | WPS object target | reference location |
|---|---|---|
| Klondike Solitaire | `C:\OS2\APPS\KLONDIKE.EXE` | top row |
| OS/2 Chess | `C:\OS2\APPS\OS2CHESS.EXE` | top row |
| Mahjongg | `C:\OS2\APPS\MAHJONGG.EXE` | top row |
| DOOM (shareware) | `C:\OS2\CMD.EXE /C C:\GAMES\DOOM\DOOMFS.CMD`, startup directory `C:\GAMES\DOOM` | top row |
| System Editor (EPM) | `C:\OS2\APPS\EPM.EXE` | top row |
| OS/2 Window | windowable-VIO `C:\OS2\CMD.EXE` | top row |
| WebExplorer | shadow of `<TCPIP_WEB>` (`C:\TCPIP\BIN\EXPLORE.EXE`) | lower left |
| Get Netscape Navigator | shadow of the preserved WPUrl object `<URL_GETNETSCAPE>` | lower left |

All executable targets were present on the hi-res disk; no binaries were copied
from a reference image. The underlying cause was subtler than a missing
`STARTUP.CMD`: MCP2 preserved the six `<GAL_*>` object IDs in a non-desktop WPS
profile location. The old `SysCreateObject(..., "U")` calls therefore returned
success while updating hidden objects instead of putting them back in
`<WP_DESKTOP>`.

The reproducible source is
`scripts/build-guests/assets/os2warp/create-desktop-objects.cmd`. It is a complete
CRLF `C:\STARTUP.CMD`: start `WARPD.EXE`, wait 60 seconds for WPS to settle,
destroy each gallery-owned object ID, and recreate it in `<WP_DESKTOP>` with
`SysCreateObject` and the `U` flag. The browser entries are gallery-owned
`WPShadow` objects, so the original system-owned launch data and icons stay
authoritative. Both `scripts/build-guests/tiles/os2warp.sh` and
`scripts/dev/os2-gengradd-hires.sh prep` install this same source; future seed
builds and hi-res recaptures therefore use one inventory.

Clone verification ran under
`/data/vms/soltest/os2warp-shortcuts-20260727T193043Z-167630/` with the exact
`os2warp-std-1024x768` guest device set. Framebuffers proved the restored
desktop, live DOOM gameplay, an EPM window, and held-button EPM window dragging.
After replacing the clone's internal `golden`, two stopped-QEMU screendumps after
a fresh `-loadvm golden` were byte-identical.

The promoted pre-change backup is
`/data/gallery-guests/OS2Warp/os2.qcow2.shortcuts-bak-20260727T200829Z`.
The live UI rendered the 1024×768 desktop with all shortcuts, and a UI-driven
EPM open/drag was independently visible in a QMP framebuffer. Finally,
`labctl reset os2warp` restored the clean shortcut-bearing desktop; two direct
stopped-QEMU post-reset screendumps were byte-identical.

### Dead ends, so nobody re-runs them

- **Legacy LGPL vgabios via `-device VGA,romfile=`** (the pre-2012 QEMU ROM that
  *does* implement `4F0Ah`, extracted from the qemu-1.1.2 tarball) — loads and runs
  fine (`Plex86/Bochs VGABios` confirmed in the guest's shadowed C000 segment), and
  **changes nothing**: SNAP still traps `SDDPMI.DLL`/`VIDEOPMI.DLL`, GENGRADD still
  traps. Direct proof that `4F0Ah` is not the blocker.
- **Kernel 14.104a** (Scott Garfinkle's last free "testcase" build,
  `w420050811.zip` from os2site — so the "free 14.096+ kernels ship only with
  ArcaOS/eCS" claim is itself false) — installs, but **traps `000e` at early boot**
  on this QEMU/TCG configuration. Not needed anyway.
- **eCo's free `genpmi.dll` + generic `SVGADATA.PMI`** from `panorama-20051228.zip`
  — untestable past the kernel trap above, and moot now.
- **Arca Noae Panorama** (US$49/yr drivers subscription) and an **ArcaOS/eCS seed
  swap** — both unnecessary; the exhibit keeps its OS/2 Warp identity and its apps.
