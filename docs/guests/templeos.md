# TempleOS gallery station — merge notes for `gallery-integrate-all.sh` (neko-era)

> **Historical (neko-era) wiring below.** TempleOS runs today as the streamhost station
> **`templeos`** — see its stanza in `streamhost/tiles-manifest.sh`
> (`streamhost@templeos`). `gallery-integrate-all.sh` is neko-era, deleted in the
> 2026-07 restructure — git history; the reconciliation pass below never ran. The
> ISO pin, build script and guest facts still apply.

## Absolute pointer — warpd HolyC serial agent (2026-07-13)

`SH_POINTER=warpd` (was `rel`). TempleOS has **no USB stack** (usb-tablet is
impossible) and only a **relative PS/2 mouse**, so the daemon's abs->rel homing
bridge could not track 1:1. Fixed with a tiny in-guest HolyC task — see
`streamhost/guest-agents/templeos/warpd.HC` + `README.md`:

- **Transport:** a COM1 serial chardev unix socket added to the launcher
  (`-chardev socket,id=ser0,path=$BASE/serial.sock,server=on,wait=off -serial
  chardev:ser0`); daemon `tile.env` gets `SH_WARPD_ADDR=unix:.../serial.sock`.
  `warpd.rs connect_agent` already speaks the `unix:` serial transport — no Rust
  change. Pure warpd (no `--warpd-buttons qemu`): the agent injects buttons itself.
- **Agent:** `WS()` polls the 16550 UART directly (`InU8(0x3FD)&1` data-ready,
  `InU8(0x3F8)` RBR — HolyC runs ring-0, so no serial driver) and parses the warpd
  `M/P/R/B` lines, writing motion to `ms.pos.x/ms.pos.y` and clicks to
  `ms.lb/ms.rb`. The TempleOS window manager samples those globals to raise real
  click messages (a synthetic `P/R` pulls down the File menu — framebuffer-verified).
- **Capture:** TempleOS is ISO/RAM-only, so the agent is defined + `Spawn()`ed at the
  `T:/Home>` REPL and captured in the **checkpoint RAM snapshot** (`state.qcow2`); every
  `loadvm golden` (the station reset) comes up with `WS` already running and
  reconnect-ready. Adding the serial device changed the device set => the old checkpoint
  was deleted and recaptured with the agent live. Backups:
  `state.qcow2.pre-warpd-*`, `qemu-streamhost.sh.pre-warpd-*`, `tile.env.pre-warpd-*`.
- **Verified (clone `/data/vms/soltest/templeos-c1` then live checkpoint):** `M 560 420`
  moves the cursor 1:1; `P 1 18 7`/`R 1 18 7` opens the File pull-down (a real click);
  the agent survives `savevm golden`->`loadvm golden` and still tracks over serial.

**Status: LIVE (neko-era).** Station `osgallery-templeos-templeos-1` was up (healthy) at
**http://192.0.2.12:8105/** and listed on the :8080 gallery index.
Deployed as its own isolated compose project (`osgallery-templeos`) — mirroring the
SailfishOS isolation pattern — so it never touched the concurrently-edited
`docker-compose.gallery-guests.yml`. The orchestrator was to fold the manifest row
below into `gallery-integrate-all.sh` (neko-era, deleted) during the reconciliation pass.

## What TempleOS is (drives the QEMU profile)
Terry A. Davis's public-domain **64-bit** x86 ring-0 single-address-space hobby OS
(2013-2017). 640x480 **16-colour** VGA, HolyC, RedSea FS, **NO networking, NO USB**.
The CD ISO boots **straight to the RedSea desktop** — no install needed. On boot the
`Once.HC` macro asks *"Install onto hard drive (y or n)?"*; that is harmless live-CD
chrome on top of the already-interactive desktop — the viewer presses `n`. Gallery
runs it **CD-only + ephemeral** (kiosk): no HDD, nothing to persist.

## Port / range allocation
| labhost port | EPR (udp)     | project              |
|-----------|---------------|----------------------|
| **8105**  | **53300-53319** | `osgallery-templeos` |

Next free block above SailfishOS (:8104 / 53280-53299). (Note: another agent's
**Haiku** station occupies :8107 / index card already present — leave a gap; do not reuse.)

## Manifest row for `gallery-integrate-all.sh` (historical — neko-era, deleted; never merged)
Add to the `GUESTS=(...)` array. Field order is
`type|key|label|mem|smp|machine|vga|sound|guestenv|extra|tier`:

```
"qemu|templeos|TempleOS|1024|1|pc|std|-device AC97,audiodev=snd|GUEST_CDROM=/guests/TempleOS/TempleOS.ISO GUEST_BOOT=d ACCEL=kvm|-cpu host|ready"
```

And pin the port (the integrator's `emit_qemu` honours `FIXED_PORT`, EPR stays
index-derived so it can't collide):

```bash
declare -A FIXED_PORT=( [serenityos]=8102 [postmarketos]=8103 [templeos]=8105 )
```

Notes on the fields:
- `smp=1` — TempleOS is only lightly SMP-aware; single core is simplest + fastest-stable.
- `sound=-device AC97,audiodev=snd` — matches the launch-qemu default; TempleOS ignores
  it (its audio is PC-speaker). Harmless; kept explicit for clarity.
- `extra=-cpu host`, `guestenv ...ACCEL=kvm` — **PERF FLIP TCG->KVM** (perf-baseline-
  report §4, kvm-safe set). `ACCEL=kvm` makes launch-qemu.sh emit `-enable-kvm`; `-cpu
  host` gives native CPUID. Despite the ring-0 identity-mapped design, naive KVM boots
  TempleOS cleanly to the RedSea desktop and accepts input — **framebuffer-verified**
  (see Verification). Result: HUD **CPU 98->10**, **FPS 6->29**, mouse->photon **~115ms
  (3/3 harness hits)** vs ~2852ms TCG. TempleOS is 64-bit → needs a 64-bit CPU. **Do NOT**
  add `usb-tablet` — no USB stack; the guest uses the PS/2 mouse (relative), which neko
  drives. REVERT to the prior working config on any regression: drop `ACCEL` + set
  `extra=-cpu qemu64` (TCG).

## Exact live compose service (authoritative — what is actually running)
`/opt/osgallery/docker-compose.templeos.yml` in CT 110 (own project `osgallery-templeos`):

```yaml
services:
  templeos:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8105:8080","53300-53319:53300-53319/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]          # USED — ACCEL=kvm engages hardware KVM
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53300-53319"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "TempleOS"
      QEMU_MEM: "1024"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc"
      QEMU_VGA: "std"
      GUEST_CDROM: "/guests/TempleOS/TempleOS.ISO"
      GUEST_BOOT: "d"
      ACCEL: "kvm"            # PERF FLIP: emits -enable-kvm
      QEMU_EXTRA: "-cpu host"
```

Bring up ONLY this service (never recreates other stations):
```bash
cd /opt/osgallery && docker compose -p osgallery-templeos -f docker-compose.templeos.yml up -d templeos
```

## Effective QEMU command line (as launched inside the container by launch-qemu.sh)
```
qemu-system-x86_64 -name TempleOS -m 1024 -smp 1 \
  -audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000 \
  -display gtk,full-screen=on,zoom-to-fit=on,grab-on-hover=off \
  -vga std -rtc base=localtime -machine pc -enable-kvm \
  -device AC97,audiodev=snd \
  -cdrom /guests/TempleOS/TempleOS.ISO -boot d \
  -cpu host
```
(`-enable-kvm` from `ACCEL=kvm`; the `out.buffer-length/out.latency` audio-buffer
hardening is applied gallery-wide by launch-qemu.sh — both confirmed on the live
cmdline, with `/dev/kvm` + `kvm-vm` + `kvm-vcpu:0` fds open in the host qemu.)

## Asset staging (labhost)
`/data/gallery-guests/TempleOS/` (bind-mounted read-only at `/guests` in CT 110):
- `TempleOS.ISO` — 17,350,656 bytes, **sha256 `5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26`** (TempleOS V5.03).
- `TempleOS.ISO.sha256` — the pin.
- `templeos-desktop.png` / `tos-standalone.png` / `tos-input-after-n.png` — proof shots.

Source: `https://templeos.org/Downloads/TempleOS.ISO` (canonical public-domain mirror;
archive.org's item was 503 at build time). Re-fetched + verified by
`scripts/build-guests/tiles/templeos.sh`.

## Gallery index (:8080)
Added a `TempleOS` card (`http://192.0.2.12:8105/?usr=guest&pwd=neko`) to
`/opt/osgallery/gallery/index.html` **and** `gallery-guests.html` via an idempotent,
flock-guarded single-entry insert (no whole-file rewrite) so concurrent station-adders
(e.g. Haiku:8107) were not clobbered. `gallery-integrate-all.sh` (neko-era, deleted)
regenerated this page from the manifest; the merge never happened — the neko index
plane was superseded by the streamhost UI before reconciliation.

## Verification evidence
- **Framebuffer (GUI render):** the live TempleOS V5.03 RedSea desktop streams in the
  browser station via neko WebRTC — blue/white 16-colour UI, two HolyC terminals, the
  "System Keys Quick Guide", top menu bar. (Also captured headless via QEMU screendump.)
- **Mouse:** a trusted click on the neko canvas showed *"You took the controls"* and
  moved the TempleOS caret/cursor (PS/2 mouse reaches the guest).
- **Keyboard:** answering the boot prompt echoed *"Install onto hard drive (y or n)? **NO**"*
  and advanced to *"Take Tour (y or n)?"* — keystrokes reach TempleOS and drive the boot
  macro (verified via QEMU HMP `sendkey n`, the same PS/2 device neko drives).

## PERF FLIP TCG->KVM verification (2026-07-04, kvm-safe-flip)
Applied `ACCEL=kvm` + `-cpu host` and `--force-recreate`d ONLY the `osgallery-templeos`
project. Backed up the prior compose to
`/opt/osgallery/docker-compose.templeos.yml.bak-kvmflip-20260704-174245` (revert source).
- **KVM engaged:** live cmdline carries `-enable-kvm -cpu host`; host qemu proc has
  `/dev/kvm`, `anon_inode:kvm-vm`, `anon_inode:kvm-vcpu:0` fds open (KVM actively in use).
- **Framebuffer (render):** neko admin `shot.jpg` shows the identical RedSea desktop
  (two HolyC terminals + System Keys guide) — HUD went **CPU98 / FPS:6 (TCG) -> CPU10 /
  FPS:29 (KVM)**.
- **Input (harness):** `gallery-input-probe.py` mouse-move probe (200,300<->600,200) =
  **3/3 hits, 0 misses, median 114.5ms** (min 95.6) input->photon. Non-destructive
  (pure cursor move); no guest-state change.
- **Audio-buffer knob:** gallery-wide `out.buffer-length=100000,out.latency=50000` present
  on the live cmdline (addresses TempleOS's underruns(1) from the baseline).
- **Outcome:** rendered + input confirmed under KVM; **not reverted**.

## Fresh builder and agent trial (2026-07-14)

`scripts/build-guests/tiles/templeos.sh --dir` was run against an empty
`/data/vms/soltest/repro-templeos-*` directory. The build took 61 seconds and
produced the pinned 17,350,656-byte ISO. QMP framebuffer captures were inspected
through boot and showed the real RedSea desktop.

The acceptance scene used the authoritative streamhost device set (`pc`, host
CPU under KVM, 1024 MiB, `std`, one vCPU, CD-ROM, and the COM1 Unix serial
transport). At `T:/Home>` the vendored `warpd.HC` task was defined and spawned,
then the clean single-terminal scene was captured as `golden`. Before the
snapshot, serial `M 560 420` moved the pointer to that framebuffer coordinate.
After quitting QEMU and starting a fresh process with `-loadvm golden`, a new
serial connection and `M 120 300` moved it to `(120,300)`, proving that the captured
agent task survived the process boundary.

The state qcow2 was 175,964,160 host bytes (2 GiB virtual; 34.7 MiB allocated).
Builder plus acceptance took 336 seconds. The 51 MiB trial directory was reported
with `du` and deleted.
