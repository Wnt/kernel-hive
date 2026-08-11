# ReactOS gallery station — merge notes (:8106)

> **Historical (neko-era) wiring below.** ReactOS runs today as the streamhost station
> **`reactos`** — see its stanza in `streamhost/stations-manifest.sh`
> (`streamhost@reactos`). The compose project, `scripts/docker-compose.reactos.yml`
> and the `gallery-integrate-all.sh` manifest row below are neko-era, deleted in the
> 2026-07 restructure — git history. The version pin, build script and QEMU profile
> still apply.

**Status: LIVE + GUI-confirmed.** Station running at http://192.0.2.12:8106/ as its own compose project `osgallery-reactos`; listed on the :8080 index. Framebuffer verified via neko screenshot API — the ReactOS 0.4.14 blue desktop / LiveCD wizard renders live (see `scratchpad/reactos-tile-8106*.jpg`, `data/gallery-guests/ReactOS/reactos-desktop.png`).

**OS:** ReactOS **0.4.14** (build `0.4.14-release-125-g5b02d38`, reports NT 5.2 / Build 3790). Open-source (GPLv2 / LGPLv2.1 / BSD components — NOT abandonware; official ReactOS SourceForge release). Binary/driver-compatible Windows NT 5 (2000/XP-era) clone. Boots the **live CD** to a Windows-2000-style desktop (Start menu, taskbar, ReactOS Explorer). Era ~mid-2000s.

### ⚠️ VERSION PIN — use 0.4.14, NOT 0.4.15
The current stable **0.4.15** live CD **deterministically hangs in early kernel init on this host's QEMU 11.0.0** — frozen at ntoskrnl `EIP=0x8046e408` with a black 720x400 screen. Reproduced identically across **every** `-cpu` (qemu32/qemu64/pentium3/host), **TCG and KVM**, `acpi=on/off`, and `std`/`cirrus` VGA. It is a ReactOS-0.4.15-vs-QEMU-11 kernel regression, not a config knob. **0.4.14 boots cleanly to the GUI.** Re-test newer releases before bumping.

**Build script:** `scripts/build-guests/tiles/reactos.sh` (bash -n clean). Fetches the official 0.4.14 live zip, unpacks the ISO to `/data/gallery-guests/ReactOS/ReactOS.iso`, and framebuffer-verifies the desktop via headless QEMU screendump (auto-clicks through the LiveCD wizard for the proof shot). Idempotent (`--force` to refetch). Re-runnable on the real NVMe.

**Guest image:** `/data/gallery-guests/ReactOS/ReactOS.iso` (~251 MB live CD). Pure live boot — no HDD, no install-to-disk (saves pool space).

## Emulator / QEMU profile (validated on host, QEMU 11.0.0)

```
# LIVE station profile (KVM, 2026-07-04 perf flip):
qemu-system-x86_64 -machine pc -enable-kvm -cpu host -m 512 -smp 1 \
  -cdrom ReactOS.iso -boot d -vga std \
  -audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000 \
  -device AC97,audiodev=snd -rtc base=localtime
# TCG fallback (if KVM ever unavailable): drop -enable-kvm, use -cpu qemu64.
```

- Verified to the full desktop under **BOTH plain TCG and KVM** with 0.4.14.
- **PERF (2026-07-04) — flipped TCG → KVM.** `perf-baseline-report.md` §4 classifies ReactOS as **KVM-SAFE** (NT-like kernel tolerates hardware accel). The station now sets `ACCEL=kvm` (launch-qemu.sh emits `-enable-kvm`) with `-cpu host` for native CPUID. Verified after the flip: cmdline shows `-enable-kvm -cpu host`, qemu launched with **no** kvm-init error (a bare `-enable-kvm` aborts if KVM is unavailable), the guest reached the LiveCD wizard in ≈90 s (vs 2–4 min cold TCG), the wizard renders cleanly, and an xdotool `mousemove` on X:99 moves the guest cursor (≈98% neko-frame byte-delta → input→photon confirmed live). The gallery-wide **audio-buffer hardening** (`out.buffer-length=100000,out.latency=50000`) is applied automatically by the rebuilt `neko-qemu` image on recreate. Prior stance ("uses plain TCG to avoid contention") is superseded.
- **`-cpu host`** under KVM (was `-cpu qemu64` under TCG; `qemu32/qemu64` also boot 0.4.14 if KVM is ever unavailable and you fall back to TCG).
- **PS/2 kbd+mouse only** *(neko-era guidance — superseded)* — a boot-time `-device usb-tablet` could stall ReactOS 0.4.x USB enumeration on that setup; the live **streamhost** station runs `usb-tablet` (absolute pointer) without issue — see `streamhost/stations-manifest.sh`.
- `-smp 1` — ReactOS SMP is fragile; single core is safest.
- Cold TCG boot to the wizard/desktop is slow (~2–4 min); neko streams it fine once up.
- **First screen = the "ReactOS LiveCD" language wizard** (normal LiveCD behaviour, not a fault). Two clicks — `Next` → `Run ReactOS Live CD` — land on the desktop (My Computer, Command Prompt, Recycle Bin, Read Me, Start button, tray clock).

## neko-qemu station env (neko-era) — was deployed as isolated compose project `osgallery-reactos`

File on labhost was `/opt/osgallery/docker-compose.reactos.yml` (mirrored the TempleOS/SailfishOS isolation pattern — never touched the concurrently-edited `docker-compose.gallery-guests.yml`). Was brought up with:
`docker compose -p osgallery-reactos -f docker-compose.reactos.yml up -d`

```yaml
services:
  reactos:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8106:8080","53340-53359:53340-53359/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53340-53359"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "ReactOS"
      ACCEL: "kvm"
      QEMU_MEM: "512"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc"
      QEMU_VGA: "std"
      QEMU_SOUND: "-device AC97,audiodev=snd"
      GUEST_CDROM: "/guests/ReactOS/ReactOS.iso"
      GUEST_BOOT: "d"
      QEMU_EXTRA: "-cpu host"
```

The canonical repo copy of this file was `scripts/docker-compose.reactos.yml` (mirroring the `scripts/docker-compose.haiku.yml` pattern — both neko-era, deleted). `ACCEL: "kvm"` + `QEMU_EXTRA: "-cpu host"` are the 2026-07-04 perf flip.

**Port block:** labhost `8106`, EPR `53340-53359` (53320-53339 was taken by a sibling agent — picked the next free block).

## Canonical manifest row for gallery-integrate-all.sh (historical — the merge never happened; neko-era, deleted)

```
ReactOS | 8106 | 53340-53359 | live-cd | ACCEL=kvm QEMU_MEM=512 QEMU_SMP=1 QEMU_VGA=std \
  GUEST_CDROM=/guests/ReactOS/ReactOS.iso GUEST_BOOT=d QEMU_EXTRA="-cpu host"
```

Index entry (already added to `gallery/index.html` + `gallery-guests.html` OSES array):

```
{"label":"ReactOS","url":"http://192.0.2.12:8106/?usr=guest&pwd=neko"}
```

## UI integration metadata

- **archetypeHint:** beige-tower-crt (mid-2000s Windows-2000-era PC — beige/putty tower + CRT).
- **year:** ReactOS 0.4.14 build 20241013; presents a ~2000-era NT5 desktop → place in the Windows 2000/XP lineage cluster.
- **lineage:** Windows NT / ReactOS (independent open-source reimplementation of NT 5.x; reports itself as "NT 5.2 Build 3790 SP2").
- **iconic apps/era:** ReactOS desktop + Explorer, Command Prompt, Notepad/WordPad, the ReactOS Application Manager, Winefile — the whole "free Windows 2000" experience.
