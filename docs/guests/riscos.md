# RISC OS 5 gallery station (:8111) — integration notes

Written as a **merge hand-off** so the orchestrator could reconcile the shared
files (`gallery-integrate-all.sh` — neko-era, deleted in the 2026-07 restructure —
git history; and the `:8080` index) without me hand-editing them. Reproducible
build: `scripts/build-guests/tiles/riscos.sh` (bash -n clean).

> **Restructure note:** the reconciliation below never ran — the neko compose plane
> was superseded by streamhost. RISC OS (RPCEmu, a plain X app — not a QEMU guest)
> is NOT in the streamhost station manifest (`streamhost/stations-manifest.sh`), so the
> neko-era wiring documented here remains this station's record; verify its current
> serving state on labhost before relying on it.

Status: **LIVE + VERIFIED (2026-07-04).** The RISC OS 5 desktop (pinboard + icon
bar) is confirmed rendering via the neko v3 screenshot API, from a from-scratch
`--force` rebuild. Wired into the :8080 index. Proof screenshot:
`/opt/osgallery/gallery-guests/RISCOS/riscos-desktop.jpg` (in CT 110).

**EPR/udp port block: `53380-53399`** (NOT the original 53320-53339, which
collides with Haiku). By the time this went live the neighbouring blocks were:
Haiku 53320-53339, reactos 53340-53359, msdoswin1 53360-53379, amigaos
53400-53419 — so 53380-53399 is the free gap. `:8111` tcp is the web port.

---

## TL;DR — what this station is

- **This is an EMULATOR station, not a QEMU station.** RISC OS is **ARM**, so there is
  no QEMU/KVM. neko streams the X window of **RPCEmu** — Sarah Walker / Peter
  Howkins' Acorn **RiscPC / A7000** emulator (a userspace ARMv4 emulator with an
  **amd64 JIT recompiler**) — running fullscreen inside the container.
- **OS**: **RISC OS 5.30** from **RISC OS Open Ltd (ROOL)** — the modern
  **shared-source / freely-available** RISC OS 5 line. Boots the **IOMD 5.30
  softload ROM** (4 MiB) + the ROOL **HardDisc4** disc. **It does NOT self-land
  on the desktop** — it stops at the RISC OS supervisor `*` prompt. Reaching the
  desktop (**pinboard + icon bar**) is automated in two hands-off steps, see
  "Boot behaviour" below.
- **Machine model**: RPCEmu `RPC610` (Risc PC, StrongARM-class), **128 MB** RAM,
  **2 MB** VRAM, sound on, `cpu_idle=1` (host-friendly).
- **Era / archetype**: Acorn **RiscPC** (beige two-slice desktop, 1994).

---

## Licensing (clean free/open path — no abandonware)

- **RISC OS 5** — freely available **shared-source** from ROOL. The IOMD ROM and
  HardDisc4 disc are distributed by ROOL expressly for real hardware **and
  RPCEmu**. Fetched directly from `riscosopen.org`. This is NOT the proprietary
  Acorn RISC OS 3.x ROM (that one would be abandonware) — we use the open RO5.
- **RPCEmu** — **GPLv2** (source from `marutan.net`), built from source here.
- => The whole station is free/open; nothing needs the home-lab-museum abandonware
  stance.

---

## Upstream sources (validated 2026-07-04)

| artifact | URL | notes |
|----------|-----|-------|
| RPCEmu 0.9.5 source (GPLv2) | `http://www.marutan.net/rpcemu/cgi/download.php?sFName=0.9.5/rpcemu-0.9.5.tar.gz` | Qt5; amd64 recompiler via `CONFIG+=dynarec` |
| RISC OS 5.30 IOMD softload ROM | `https://www.riscosopen.org/zipfiles/platform/riscpc/IOMD-Soft.5.30.zip` | ROM at `soft/!Boot/Resources/SoftLoad/riscos` (exactly 4 MiB) |
| HardDisc4 5.30 disc | `https://www.riscosopen.org/zipfiles/platform/common/HardDisc4.5.30.zip` | unzip into RPCEmu `hostfs/` (strip top `HardDisc4/`) |

Guest data staged at `/data/gallery-guests/RISCOS/` (bind-mounted read-only into
CTID 110 at `/guests/RISCOS`):
```
roms/riscos    # 4 MiB IOMD 5.30 softload ROM (RPCEmu concatenates roms/*)
hostfs/        # ROOL HardDisc4 (the RISC OS !Boot + Apps + Utilities)
rpc.cfg        # RPCEmu machine config (RPC610, 128 MB, sound on, cpu_idle)
cmos.ram       # RPCEmu NVRAM seed
```

---

## The image: `neko-rpcemu:latest`

`neko:base` (Debian **trixie/13**) + Qt5 + RPCEmu 0.9.5 built from source. Built
by `scripts/build-guests/tiles/riscos.sh` (Dockerfile is emitted inline). Key points:

- Trixie ships **Qt5** still: `qtbase5-dev qtmultimedia5-dev qtchooser qt5-qmake
  libqt5multimedia5-plugins` all resolve. Build = `qtchooser -run-tool=qmake
  -qt=5 CONFIG+=dynarec && make`. On amd64 the recompiler pulls `codegen_amd64.c`
  → fast JIT. The plain interpreter is also built as a fallback binary.
- Binaries land in `/opt/rpcemu/` (`.pro` has `DESTDIR = ../..`):
  `rpcemu-recompiler` (preferred) + `rpcemu-interpreter` (fallback).
- **RPCEmu finds its data in the CWD** (`datadir` defaults to `"./"` in
  `src/rpc-machdep.c`). So the launch script cds into a **writable per-boot dir**
  `/tmp/rpcemu-data` seeded from the read-only `/guests/RISCOS` (copies rom +
  hostfs + rpc.cfg + cmos.ram; symlinks the image's `poduleroms/` + `netroms/`).
  hostfs must be writable (RISC OS writes to `!Boot/Choices`), hence the copy.
- neko:base has **no window manager**; RPCEmu opens an undecorated Qt window
  (titled `RPCEmu - MIPS: …`). `launch-rpcemu.sh` uses `xdotool` to nudge it to
  `0,0` **and** to auto-issue `Desktop` (see "Boot behaviour").
- Supervisord auto-includes `/etc/neko/supervisord/*.conf`; the image drops
  `rpcemu.conf` (priority 500) that runs `launch-rpcemu.sh` as the neko user.
- **Guest data must be world-readable.** The container runs as the non-root
  `neko` user; the HardDisc4 zip preserves restrictive perms (ROM `0600`, hostfs
  `0700`, root-owned), so without a `chmod -R a+rX` on the staged tree the copy
  in `launch-rpcemu.sh` fails and RPCEmu dies with *"Could not load ROM files
  from directory 'roms'"*. `stage_guest()` now does that chmod.

---

## Boot behaviour (why the desktop needs two nudges)

Out of the box RPCEmu's stock `cmos.ram` boots from **ADFS** (no disc present),
so RISC OS drops to the supervisor `*` prompt and never runs the HardDisc4
`!Boot`. Fixes, both automated:

1. **Pre-configured `cmos.ram` (HostFS boot).** The seed `cmos.ram` carries
   `Configure FileSystem HostFS` + `Configure Boot` (captured once by running
   those `*Configure` commands on this exact ROM and letting RPCEmu persist the
   NVRAM; embedded as base64 in `riscos.sh`). With it, power-on selects HostFS
   and runs the ROOL HardDisc4 `!Boot` (mounts the disc, sets `Boot$Dir`, loads
   ResourceFS apps — giving the proper icon bar with **HostFS** + **Apps**).
2. **Auto-issued `Desktop`.** This ROOL HardDisc4 `!Boot` `RMEnsure`s
   `UtilityModule` / `SharedCLibrary` versions that this IOMD 5.30 softload ROM
   does **not** satisfy, so `!Boot` aborts before its own final `Desktop`,
   leaving RISC OS at the `*` prompt. `launch-rpcemu.sh` therefore focuses the
   RPCEmu window and types `Desktop⏎` a few spaced times (RISC OS type-ahead
   buffers keystrokes, so one lands at the prompt; extras after the desktop is up
   are harmless). This brings up the WIMP: pinboard + icon bar.

Net result: a stable RISC OS 5 desktop with the icon bar (`:0` CD, **HostFS**,
`:0` floppy, **Apps**, display, Acorn task-switcher) and the bundled `!Apps`.

---

## Exact compose service (isolated project — concurrency-safe)

Live station runs as its OWN compose project `osgallery-riscos` so it never touches
the sibling-edited `docker-compose.gallery-guests.yml` (same pattern as
SailfishOS/TempleOS). File in CT 110: `/opt/osgallery/docker-compose.riscos.yml`:

```yaml
services:
  riscos:
    image: neko-rpcemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8111:8080","53380-53399:53380-53399/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53380-53399"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "RISC OS 5"
```

Bring up (never touches other stations):
```sh
cd /opt/osgallery
docker compose -p osgallery-riscos -f docker-compose.riscos.yml up -d
```

- **No `/dev/kvm`** — RPCEmu is pure userspace ARM emulation. (This station is the
  first non-QEMU, non-RDP streamer in the gallery: a plain X app under neko.)
- **Port `8111`** (tcp web), **EPR `53380-53399/udp`** — a fixed, collision-free
  block. The original 53320-53339 was reassigned to **Haiku**; and 53360-53379
  was later taken by **msdoswin1**, so RISC OS uses the 53380-53399 gap between
  msdoswin1 (…379) and amigaos (53400…). Verify free before reuse:
  `docker ps --format '{{.Ports}}' | grep 5338` should be empty.

## Row for `gallery-integrate-all.sh` (historical — neko-era, deleted; never merged)

This station does not fit the QEMU-oriented `GUESTS=()` schema (it has no ISO/disk
and a different image). Two clean options for reconciliation:

1. **Keep the standalone compose project** (recommended; self-contained, mirrors
   SailfishOS/TempleOS). Nothing to merge.
2. If the generator is extended to support emulator stations, model it as an
   `image=neko-rpcemu` row with `FIXED_PORT[riscos]=8111` and no KVM/ISO fields.

## launch-qemu.sh change required: **NONE**

RPCEmu does not use `launch-qemu.sh` at all — it has its own
`launch-rpcemu.sh` baked into `neko-rpcemu:latest`. Nothing to reconcile in the
shared `osgallery/neko-qemu/launch-qemu.sh`.

## `:8080` index row — **ADDED** (verified rendering)

Inserted into the `OSES` array in `/opt/osgallery/gallery/index.html` (served by
`osgallery-gallery-1` on :8080). Note the served file escapes the `&` as `\&`:

```
{"label":"RISC OS 5","url":"http://192.0.2.12:8111/?usr=guest&pwd=neko"}
```

---

## Verification (framebuffer truth)

**This is neko v3** (`nurdism/m1k1o server dev`), so the old basic-auth
screenshot API is gone (returns 401). Method: `POST /api/login`
(`{"username":"admin","password":"admin"}`) → bearer token, then
`GET /api/room/screen/shot.jpg` with `Authorization: Bearer <token>` against
`http://127.0.0.1:8111/` after RPCEmu cold-boots + the auto-`Desktop` fires, then
a colour-variety assertion (ImageMagick `identify -format %k` > 200, else size
> 20 KB). `verify_tile()` in `riscos.sh` guards the login curl with `|| tok=""`
so the cold-boot 401s don't trip `set -e` and abort the run.

Proof image saved to `<GUEST_DIR>/riscos-desktop.jpg`
(= `/opt/osgallery/gallery-guests/RISCOS/riscos-desktop.jpg` in CT 110) by the
build script's verify step.

<!-- VERIFY-RESULT -->
**VERIFY-RESULT (2026-07-04): PASS.** Confirmed by SEEING the RISC OS 5 desktop —
grey pinboard + bottom icon bar (`:0`, HostFS, `:0`, Apps, display, Acorn
task-switcher) — captured from a from-scratch `--force` rebuild via the neko v3
screenshot API. `:8111` returns HTTP 200; RPCEmu recompiler running, 0 fatal
errors. Live station: `http://192.0.2.12:8111/?usr=guest&pwd=neko`.

---

## Curated metadata (for the UI placard)

- **Name**: RISC OS 5 (RISC OS Open)
- **Year**: lineage 1987 (Arthur → RISC OS); this build RISC OS **5.30** (2024,
  ROOL). Emulated machine: Acorn **Risc PC** (1994).
- **Lineage**: Acorn Computers → RISC OS → RISC OS Open (shared-source).
- **Arch**: ARM (ARMv4/StrongARM-class, emulated by RPCEmu on amd64).
- **One-liner**: The Acorn desktop OS — cooperative multitasking, the iconic
  bottom **icon bar**, fully-antialiased **outline fonts**, and `!Apps` that live
  as directories. Ran on the ARM chips Acorn invented.
- **Iconic era software**: `!Draw`, `!Paint`, `!Edit`, `!Maestro`, Impression,
  ArtWorks, `!Zap`; the `!Boot` structure; the three-button mouse; StrongARM Risc
  PC.
- **Archetype**: `beige-tower-crt` is the closest existing UI model, but the
  **ideal** is a dedicated **Acorn Risc PC** model — the beige two-/three-"slice"
  stackable case with the badge, paired with an Acorn AKF CRT.
