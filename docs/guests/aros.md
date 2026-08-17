# AmigaOS (AROS) gallery station — notes for the orchestrator

> **Historical (neko-era) wiring below.** The CT-110 neko station (:8110, its compose
> project and the `gallery-integrate-all.sh` manifest row) is superseded: AROS runs
> today as the streamhost station **`aros`** — see its stanza in
> `streamhost/stations-manifest.sh` and the `streamhost@aros` unit.
> `gallery-integrate-all.sh` / `exotic-guests-add.sh` are neko-era, deleted in the
> 2026-07 restructure — git history. The build script, licensing and in-guest
> behaviour notes still apply.
>
> **Renamed 2026-08-10:** the daemon side was `amigaos` (`SH_STATION`, station dir,
> `streamhost@amigaos`) until it was renamed to match the registry id `aros`.
> Dated records below, labhost backup dirs, and the `amigaos.sh` build key still
> carry the old name; they are not wrong, they are older than the rename.

**Status: LIVE + framebuffer-verified.** Station at **http://192.0.2.12:8110/**
(neko streams a QEMU x86 VM running AROS). Added to the :8080 index as
"AROS (AmigaOS-compatible)". Guest desktop confirmed via neko `shot.jpg` AND a
headless QEMU screendump (the Wanderer/Workbench desktop with RAM Disk / AROS
Live CD / InstallAROS icons + AROS logo).

## What it is / licensing
- **AmigaOS represented by AROS** (AROS Research Operating System) — an
  open-source, from-scratch re-implementation of the AmigaOS 3.1 APIs.
- Image = the official **pc-i386** (x86, 32-bit) **boot ISO** nightly
  (`AROS-YYYYMMDD-pc-i386-boot-iso.zip`). Runs **QEMU x86-native** and boots
  straight to the Amiga-style **Wanderer** Workbench desktop — **NO copyrighted
  Kickstart ROM needed**. Pure live CD, no HDD, no install step, no keypress
  automation (GRUB auto-boots; it self-lands on the desktop in ~40-60s cold TCG).
- **Licence: APL** (AROS Public License, an MPL derivative) — FREE / OPEN and
  freely redistributable. The upstream `LICENSE` + `ACKNOWLEDGEMENTS` are copied
  next to the ISO in the guest dir.
- **Alternative (NOT used):** classic 68k AmigaOS 3.x via FS-UAE / vAmiga needs a
  copyrighted Amiga Kickstart ROM. Deliberately not required — the free AROS path
  is faithful to the Workbench look. If a future "real" AmigaOS station is wanted,
  that would be the private-home-lab-collection path (source a Kickstart
  ROM + a Workbench ADF — copyrighted media, free to use in this private collection;
  just don't re-distribute those binaries via the GitHub repo), same stance as the
  Win9x/XP/macOS stations.

## Reproducible build
- Script: `scripts/build-guests/tiles/amigaos.sh` (bash -n clean).
  - Resolves the LATEST `pc-i386-boot-iso` nightly from the AROS SourceForge
    listing (date-stamped dirs get pruned upstream), pinned fallback `20260701`.
  - Downloads + unzips → installs `aros-pc-i386.iso` to the guest dir; copies
    LICENSE/ACKNOWLEDGEMENTS; framebuffer-verifies the boot (headless QEMU +
    monitor screendump, asserts a real non-blank desktop). Idempotent
    (`--force` to refetch, `--no-verify` to skip the boot check).
- Guest dir on host: `/data/gallery-guests/AmigaOS/`
  - `aros-pc-i386.iso` (~391 MB logical), `LICENSE`, `ACKNOWLEDGEMENTS`,
    `aros-desktop.png` (proof screenshot).

## Canonical manifest row (historical — for `gallery-integrate-all.sh`, neko-era, deleted)
Fields mirror the `exotic-guests-add.sh` (neko-era, deleted) `TILES` schema
(`svc|label|port|eprlo|mem|smp|machine|vga|sound|guest|extra`):

```
amigaos|AROS (AmigaOS-compatible)|8110|53400|512|1|pc|std|-device AC97,audiodev=snd|GUEST_CDROM=/guests/AmigaOS/aros-pc-i386.iso GUEST_BOOT=d|-enable-kvm -cpu host
```
(KVM adopted 2026-07-04 via the perf test-then-adopt rollout — see Ops notes. Was
`-cpu qemu64` (TCG); revert to that if a future AROS nightly regresses under KVM.)

Index card (OSES array entry in gallery/index.html — already applied):
```
{"label":"AROS (AmigaOS-compatible)","url":"http://192.0.2.12:8110/?usr=guest&pwd=neko"}
```

## Live station (own compose project, isolated like sailfish/templeos)
Deployed as `docker-compose.amigaos.yml` in CT 110, project `osgallery-amigaos`:

```yaml
services:
  amigaos:
    image: neko-qemu:latest
    restart: unless-stopped
    shm_size: 1gb
    ports: ["8110:8080","53400-53419:53400-53419/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    devices: ["/dev/kvm:/dev/kvm"]
    environment:
      NEKO_SCREEN: "1024x768@30"   # match AROS's native vesa=1024x768 (GRUB default=4)
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_EPR: "53400-53419"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "192.0.2.12"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "AROS (AmigaOS-compatible)"
      QEMU_MEM: "512"
      QEMU_SMP: "1"
      QEMU_MACHINE: "pc"
      QEMU_VGA: "std"
      GUEST_CDROM: "/guests/AmigaOS/aros-pc-i386.iso"
      GUEST_BOOT: "d"
      QEMU_EXTRA: "-enable-kvm -cpu host"   # KVM adopted (was "-cpu qemu64" TCG)
```

Bring up: `cd /opt/osgallery && docker compose -p osgallery-amigaos -f docker-compose.amigaos.yml up -d`

Equivalent raw QEMU (validated on host, QEMU 11.0.0, KVM):
```
qemu-system-x86_64 -machine pc -enable-kvm -cpu host -m 512 \
  -cdrom aros-pc-i386.iso -boot d -vga std \
  -usb -device usb-tablet,id=tab0 \
  -audiodev pa,id=snd -device AC97,audiodev=snd -rtc base=localtime
```

## Port / EPR allocation
- HTTP station: **8110**  (existing stations occupy 8081-8107; 8110 was free)
- neko EPR (WebRTC UDP): **53400-53419** (a fresh block above templeos 53300-53319
  / haiku 53320-53339, to avoid collision with sibling builders).

## Ops notes / gotchas
- **KVM ADOPTED (2026-07-04 perf rollout, test-then-adopt PASSED).** Flipped
  `QEMU_EXTRA` from `-cpu qemu64` (TCG) to `-enable-kvm -cpu host` and verified on
  the LIVE station: Wanderer/Workbench desktop renders on a fresh boot; **input reaches
  the guest** (right-mouse-button pops the full Workbench menu — Backdrop/Execute/
  Shell/AROS/About/Quit/Shut down — and retracts on release); KVM engaged host-side
  (`/dev/kvm` + `anon_inode:kvm-vm` + `kvm-vcpu:0` fds open in the qemu process);
  idle vCPU ~0% (guest HLTs cleanly). Container stable, no crash-loop, healthy.
  **Revert path if a future AROS nightly regresses under KVM:** set `QEMU_EXTRA`
  back to `-cpu qemu64` and recreate — TCG remains the always-safe fallback.
- **ABSOLUTE POINTER ADOPTED (2026-07-15, clone-first + framebuffer-verified).**
  The earlier `usb-tablet` probe stopped after QEMU enumeration. That result was
  real but incomplete: AROS's startup loads Poseidon classes yet does not add the
  PCI USB host controller. On a namespaced clone, `AddUSBHardware pciusb.device 0`
  immediately detected “QEMU USB Tablet”, bound it to the current `hid.class`
  (4.5, 2026-07-01), and changed QMP `query-mice` from PS/2/current/relative to
  QEMU HID Tablet/current/absolute. The candidate device set is
  `-usb -device usb-tablet,id=tab0`; `SH_POINTER=abs` makes streamhost inject QMP
  absolute coordinates.
- **Persistence and proof.** `streamhost/stations/aros/golden-bake.sh` performs
  the AROS binding before `savevm golden`; the launcher conditionally uses
  `-loadvm golden`, because this live CD has nowhere else to persist Poseidon's
  controller state. The checkpoint and launcher must retain exactly the same tablet
  device. On `/data/vms/sandbox/aros-abs-codex-20260715T2328Z`, QMP inputs
  `(3277,3277)`, `(29490,3277)`, `(3277,29490)`, `(29490,29490)`, and
  `(16384,16384)` visibly landed at the four inset framebuffer corners and centre.
  An absolute-positioned right click opened Wanderer's full menu. After killing
  the clone strictly by its pidfile and relaunching with `-loadvm golden`, the HID
  tablet was still current/absolute and corner/centre motion still changed the
  real 1024x768 framebuffer.
- **LIVE PROMOTION (2026-07-15/16 UTC).** Backed up the PS/2 checkpoint, launcher,
  and env to `/data/vms/streamhost/backups/amigaos-pre-abs-20260716T0237Z`, then
  recaptured and emitted the registry-backed candidate. The live process has
  `-usb -device usb-tablet,id=tab0 -loadvm golden`; streamhost logs
  `pointer=abs`; `labctl` reports `amigaos abs ... golden=yes`. After an explicit
  `labctl reset amigaos`, `query-mice` reported PS/2 current=false and QEMU HID
  Tablet current=true/absolute=true. Real 1024x768 framebuffer captures visibly
  placed the arrow at all four inset corners and centre, and an absolute-positioned
  right click opened the Wanderer menu. The final live qcow2 check was clean.
- **Rollback.** Stop `streamhost@aros`, restore the backed-up
  `golden-scratch.qcow2`, launcher, and `station.env`, regenerate `tiles.json`, then
  restart the service. The old matched set is PS/2-only plus `SH_POINTER=rel`;
  never load a tablet-captured snapshot with that old launcher.
- **Audio buffer knob is already gallery-wide** (baked into launch-qemu.sh:
  `-audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000`); no per-station
  audio edit is owed by AROS. AC97 support in AROS remains best-effort (silence OK).
- **Framing / RESOLUTION (RESOLVED 2026-07-06):** AROS's GRUB `boot/grub/grub.cfg`
  has `set default=4` → the *"AROS (true colour VESA graphics: 1024x768)"* entry
  (`vesa=1024x768`), so the guest ALWAYS paints a native 1024x768 4:3 Wanderer
  desktop. The station previously captured at the gallery-default `640x480`, which — with
  launch-qemu.sh's no-scale `-display gtk` — cropped the desktop to its top-left
  640x480 quadrant (it LOOKED full because a crop of a corner-anchored desktop still
  shows the title bar + icons). Fix: pin `NEKO_SCREEN=1024x768@30` so the whole
  1024x768 framebuffer is captured pixel-exact. Verified full-frame + crisp via neko
  `shot.jpg` (complete "aros" wallpaper, full-width title bar with the window-arrange
  gadget at top-right, all three icons). No ISO remaster needed — the mode was already
  the GRUB default. Was baked into `gallery-integrate-all.sh` `FIXED_SCREEN[amigaos]`
  (neko-era, deleted); streamhost captures the guest framebuffer at its native
  geometry, so no canvas pin is needed anymore.
  (Higher modes exist as GRUB entries 5 = 1280x1024; 1024x768 is the task target and
  the safe default, so we stay there.)
- Sound: AC97 wired to PulseAudio via launch-qemu.sh default; AROS AC97 support is
  best-effort (silence is harmless).
- Archetype for the UI: an **Amiga wedge** (e.g. Amiga 500/1200 wedge-with-CRT).
  No existing UI archetype fits perfectly; the beige-tower-crt is the closest
  stand-in, but a dedicated Amiga wedge model is ideal.

DELTAS (repo/doc fixes for an easier next rebuild):
- [applied] `streamhost/stations/aros/golden-bake.sh` — the previous probe attached `usb-tablet` but never added AROS's PCI USB hardware to Poseidon — run `AddUSBHardware pciusb.device 0`, require QEMU HID Tablet current/absolute, and capture four-corner/centre framebuffer proofs before savevm — `docs/guests/aros.md`
- [applied] `streamhost/stations/aros/golden-bake.sh` — the first absolute-pointer capture compared the restored post-binding Shell against a pre-binding reference frame (`reset_delta=0.004215`) — refresh `bake-golden.ppm` after the Poseidon bind and absolute-motion proof so loadvm verification compares like-for-like framebuffer state — `docs/guests/aros.md`
- [applied] `streamhost/stations/aros/qemu-streamhost.sh` + `registry/stations/aros.json` — the diskless LiveCD cannot persist Poseidon's controller binding across a cold boot — keep `-usb -device usb-tablet,id=tab0` in the matched device set, auto-load the `golden` snapshot, and emit `SH_POINTER=abs` — `docs/guests/aros.md`
- [proposed] `scripts/gen_tiles_json.py` — its checkpoint probe is QMP-only, so running `labctl gen` while the station is stopped records `golden_snapshot=null` even when `qemu-img snapshot -l` shows `golden` — add a declared snapshot-store fallback or require regeneration after QEMU starts (the promotion reran it after start and recorded `golden=true`) — `docs/guests/aros.md`
