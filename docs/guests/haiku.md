# Haiku gallery tile (:8107) — integration notes

> **Historical (neko-era) wiring below.** Haiku runs today as the streamhost tile
> **`haiku`** — see its stanza in `streamhost/tiles-manifest.sh` (`streamhost@haiku`;
> in-guest shell via `labctl exec haiku "<cmd>"`, ssh port 5807). The merge hand-off
> below targeted `gallery-integrate-all.sh` and `docker-compose.haiku.yml`, both
> neko-era, deleted in the 2026-07 restructure — git history. The image build and
> guest facts still apply.

Verified live on the dry-run box 2026-07-04. Written as a **merge hand-off** so the
orchestrator could reconcile `gallery-integrate-all.sh` (neko-era, deleted;
concurrently edited by sibling agents at the time).

Reproducible image build: `scripts/build-guests/haiku.sh` (bash -n clean).

---

## TL;DR — what this tile is

- **OS**: **Haiku R1/beta5** (released 2024-09-13), the open-source **MIT-licensed
  BeOS-compatible** OS — the free, maintained successor to BeOS. Presented as
  **"Haiku (BeOS-compatible)"**.
- **Image**: the official **`haiku-r1beta5-x86_64-anyboot.iso`** (1.41 GB;
  SHA256 `22ae312a38e98083718b6984186e753d15806bd6ea44542144fdcef42c4dcb69`).
  "anyboot" = one hybrid image that is simultaneously a BIOS El-Torito CD, an EFI
  image, and a raw USB stick. **Booted as a pure live CD** (`-cdrom -boot d`) — it
  lands on the **live Haiku desktop**; NO installer, NO disk, NO OVMF.
  *(Superseded: the live tile now boots a persistent installed disk,
  `tiles/haiku/haiku-persist.qcow2` with an internal `golden` snapshot —
  see the tile launcher / `scripts/serve/golden-manifest.json`.)*
- **GUI CONFIRMED rendering** (framebuffer truth, not logs): the iconic BeOS
  **yellow window tab** ("Welcome to Haiku!") + language/keymap picker +
  Install/Try-Haiku buttons over the blue Haiku desktop. Verified two ways:
  1. headless QEMU `screendump` in `haiku.sh` (`/data/gallery-guests/Haiku/haiku-desktop.png`),
  2. the **live neko stream** at `:8107` via the neko admin screenshot API
     (`GET /api/room/screen/shot.jpg`, **Bearer** token from `POST /api/login`).
- **KVM-accelerated** (modern x86_64 guest) → boots to desktop in ~30–45 s.
- License: **free/open (MIT)** — the preferred faithful path for a BeOS tile; no
  abandonware needed (real BeOS R5 exists on WinWorld but Haiku is the legally-clean,
  visually-identical, maintained successor).

---

## Exact manifest row for `gallery-integrate-all.sh` (historical — neko-era, deleted)

Same pipe-delimited schema as the other rows (tier `advanced` / exotic):

```
"qemu|haiku|Haiku (BeOS-compatible)|2048|2|pc|std|-device intel-hda -device hda-duplex,audiodev=snd|GUEST_CDROM=/guests/Haiku/haiku.iso GUEST_BOOT=d|-enable-kvm -cpu host -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -netdev user,id=n0 -device e1000,netdev=n0|advanced"
```

| field | value |
|-------|-------|
| type | `qemu` |
| key | `haiku` |
| label | `Haiku (BeOS-compatible)` |
| mem (MB) | `2048` (1024 min) |
| smp | `2` |
| machine | `pc` |
| vga | `std` (Bochs VBE — Haiku app_server likes it) |
| sound | `-device intel-hda -device hda-duplex,audiodev=snd` |
| guestenv | `GUEST_CDROM=/guests/Haiku/haiku.iso GUEST_BOOT=d` |
| extra | `-enable-kvm -cpu host -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -netdev user,id=n0 -device e1000,netdev=n0` |
| tier | `advanced` |

And pin the published host port (EPR stays index-derived → collision-free):

```sh
declare -A FIXED_PORT=( [sailfishos]=8104 [templeos]=8105 [haiku]=8107 )
```

- `usb-tablet` on an xHCI controller = absolute pointer; Haiku has a full USB HID
  stack so the neko cursor tracks 1:1 (no PS/2 drift).
- `e1000` NIC gives the live session working networking (HaikuDepot etc.).

## launch-qemu.sh change required: **NONE**

Uses only stock `launch-qemu.sh` env vars (`GUEST_CDROM/BOOT`, `QEMU_VGA/MEM/SMP/
MACHINE/SOUND/EXTRA`). No OVMF (BIOS El-Torito boot), no overlay, no autologin
typer. Nothing to reconcile in `osgallery/neko-qemu/launch-qemu.sh`.

---

## How the live tile was wired in the neko era (concurrency-safe, isolated project)

To avoid clobbering the sibling-edited `docker-compose.gallery-guests.yml`, the neko-era
:8107 tile ran as its **own** compose project (same pattern as Sailfish/TempleOS):

- File in CT 110: `/opt/osgallery/docker-compose.haiku.yml` (service `haiku`,
  image `neko-qemu:latest`, port `8107:8080`, **EPR `53320-53339`** — next free
  block after templeos `53300-53319`, volume `./gallery-guests:/guests:ro`,
  `/dev/kvm`, `NEKO_SESSION_IMPLICIT_HOSTING=true` so opening the tile grants
  immediate remote control).
- Was brought up isolated:
  ```sh
  cd /opt/osgallery
  docker compose -p osgallery-haiku -f docker-compose.haiku.yml up -d
  ```
- Status: `osgallery-haiku-haiku-1` — **Up (healthy)**; `http://192.0.2.12:8107/`
  returns **HTTP 200**.
- Added to the `:8080` index (`/opt/osgallery/gallery/index.html`) as
  `Haiku (BeOS-compatible)` → `http://192.0.2.12:8107/?usr=guest&pwd=neko`
  (idempotent insert; only touched the OSES array).

The repo copy of that compose file (`scripts/docker-compose.haiku.yml`) is likewise
neko-era, deleted — reproduce it from the "manifest row" above via git history if a
rollback experiment ever needs it.

**Final reconciliation** never happened as planned — the whole neko compose plane was
superseded by the streamhost tile before it (see the banner at the top).

---

## Known cosmetic (non-blocking) + tuning ideas

- **Letterboxing**: the neko canvas is `1280x720` but Haiku's early live-desktop
  VESA mode paints a smaller region, so the neko frame shows the desktop with black
  margins. The desktop is fully live and interactive — this is cosmetic only.
  To fill the frame later: set the guest screen res to match `NEKO_SCREEN` (Haiku
  → Screen preflet, or a VESA `vga=` mode), or drop `NEKO_SCREEN` to `1024x768@30`
  to better match Haiku's default live mode.
- **Landing screen**: the tile lands on the "Welcome to Haiku!" first-boot dialog
  (yellow tab + Install/Try). Clicking **Try Haiku** dismisses it to the full
  Deskbar + Tracker desktop. An optional auto-click (neko host control → click the
  "Try Haiku" button, ~x=903,y=581 at 1280×720) would land straight on the bare
  Deskbar for a cleaner museum shot; left manual to avoid input-automation fragility.
- **`--arch x86_gcc2h`** builds the 32-bit gcc2-hybrid ISO instead (the "classic"
  BeOS build) if the SPA wants the most period-accurate variant; boot path identical.

## Reproduce from scratch (fresh NVMe)

```sh
scripts/build-guests/haiku.sh              # fetch + SHA256-verify + headless GUI proof
#   --arch x86_gcc2h   32-bit classic build
#   --force            re-download
#   --no-verify        skip the boot check
# → /data/gallery-guests/Haiku/haiku.iso  (+ haiku-desktop.png proof)
# then wire it as the streamhost tile: the `haiku` stanza in
# streamhost/tiles-manifest.sh emits the tile files; bring-up-all.sh boots it and
# starts streamhost@haiku. (Neko-era: docker-compose.haiku.yml — deleted.)
```
