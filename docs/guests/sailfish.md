# Sailfish OS GUI under plain QEMU — bochs-drm KMS injection (Option B)

**Status: SOLVED and verified on-box 2026-07-04.** The real Lipstick (Wayland)
touch GUI now renders under plain QEMU (`-vga std`), no VirtualBox. Reproducible
build: `scripts/build-guests/tiles/sailfishos-gui.sh`. This is a **merge hand-off** for
the orchestrator — it does NOT edit any shared script.

> **Current state:** the live gallery runs this as the streamhost tile
> **`sailfishos`** — see its stanza in `streamhost/tiles-manifest.sh` (disk
> `/data/gallery-guests/SailfishOS/sailfishos-gui.qcow2`, `streamhost@sailfishos`).
> The neko-era material below is historical: `gallery-integrate-all.sh` and the
> losing VirtualBox Option-A driver `scripts/build-guests/sailfishos-vbox.sh` are
> neko-era, deleted in the 2026-07 restructure — git history. The Option-B KMS
> recipe and `sailfishos.sh`/`sailfishos-gui.sh` remain the live build path.

Companion: Appendix A below (the original text-console tile notes, formerly
`scripts/sailfish-tile-notes.md` [deleted — git history]).

---

## TL;DR

The console-only tile failed because Lipstick's `eglfs_kms` needs `/dev/dri` and
the stock 32-bit emulator kernel (`5.0.21-1.4.5.jolla`) has **no** QEMU-drivable
DRM/KMS driver. Option B builds a matching **`bochs-drm.ko`** from Jolla's own
kernel source, force-loads it into a COPY of the image, frees the framebuffer
BAR, and unmasks Lipstick. Result: `/dev/dri/card0` appears, Lipstick composites
in software (llvmpipe/`kms_swrast`) via `eglfs_kms`, and the USB-tablet +
keyboard reach the UI. **The neko+QEMU tile args are identical to every other
tile** — the fix is entirely inside the image.

Verified evidence (test VM, VMID band 82x):
- `/dev/dri/card0` present; `dmesg`: `Found bochs VGA, ID 0xb0c5` →
  `Initialized bochs-drm 1.0.0 ... on minor 0`.
- `lipstick` (PID 486) holds **`/dev/dri/card0`** + **`/dev/input/event3`
  (QEMU USB Tablet)** + **event4 (USB Keyboard)** open, and maps
  `/usr/lib/dri/kms_swrast_dri.so` + `libqeglfs-kms-integration.so`.
- Framebuffer screendump: Sailfish lock screen (ambience wallpaper + live
  clock). A QMP absolute-touch swipe produces a UI response (top-edge peek).
- Golden image, live :8104 tile, VM 900/925 all untouched; pool FREE ~27 G.

---

## 1. Kernel-source acquisition (the old blocker — now solved)

The on-device module tree points at the build dir
`/home/abuild/rpmbuild/BUILD/kernel-adaptation-pc-5.0.21+git12` (dangling
symlink; no headers/`Module.symvers`/compiler in the image). The matching source
is on GitHub:

- Repo: **`github.com/sailfishos/kernel-adaptation-pc`** (full kernel tree, 589 tags)
- Exact tag: **`sailfish/5.0.21+git12`** (matches the build-dir name exactly)
- Tarball: `https://codeload.github.com/sailfishos/kernel-adaptation-pc/tar.gz/refs/tags/sailfish/5.0.21+git12`
  (~148 MB gz → ~1.2 GB tree; top dir `kernel-adaptation-pc-sailfish-5.0.21-git12`)

`releases.sailfishos.org/sources/` only publishes up to 4.0.1.48, so **no 5.x
Module.symvers is available there** — but it turns out we don't need it (below).

The guest's own **`/boot/config-5.0.21-1.4.5.jolla`** is the config used for the
build (copied straight out of the image). Relevant switches:

    CONFIG_MODVERSIONS=y          # normally requires matching symbol CRCs...
    CONFIG_MODULE_FORCE_LOAD=y    # ...but force-load is enabled
    CONFIG_MODULE_SIG (not set)   # and modules are unsigned
    CONFIG_DRM=y, CONFIG_DRM_KMS_HELPER=y, CONFIG_DRM_KMS_FB_HELPER=y  # builtin
    CONFIG_DRM_TTM=m              # ttm.ko present in image (bochs dep)
    CONFIG_GCC_VERSION=130400     # kernel built with gcc 13.4

Because **`CONFIG_MODULE_FORCE_LOAD=y`** and **`CONFIG_MODULE_SIG` is off**, the
missing `Module.symvers` is a non-issue: build the module unversioned and load
with `modprobe --force-vermagic`. Since it is built from the **same source +
same config**, all DRM/TTM struct layouts are identical to the running kernel
(layouts come from headers/config, not the compiler), so force-loading this leaf
driver is safe.

## 2. Module build (i386, out-of-tree)

Host: Proxmox/Debian x86_64. Deps: `gcc-12 gcc-12-multilib flex bison
libelf-dev libssl-dev` (gcc-12 is friendlier to 5.0-era code than gcc-14).

    cp /boot/config-5.0.21-1.4.5.jolla  $KSRC/.config
    ./scripts/config --module DRM_BOCHS
    make ARCH=i386 CC=gcc-12 HOSTCC=gcc-12 olddefconfig
    make ARCH=i386 CC=gcc-12 HOSTCC=gcc-12 -j$(nproc) modules_prepare
    make ARCH=i386 CC=gcc-12 HOSTCC=gcc-12 -j$(nproc) M=drivers/gpu/drm/bochs modules
    # -> drivers/gpu/drm/bochs/bochs-drm.ko  (931 KB, ELF 32-bit i386)
    #    modinfo: alias pci:v00001234d00001111...  (== QEMU stdvga / -vga std)
    #             vermagic 5.0.21 SMP preempt mod_unload modversions 686

("Symbol version dump ./Module.symvers is missing" warning is expected and fine.)

## 3. Injection into a COPY (never the golden)

1. `install -D bochs-drm.ko /lib/modules/5.0.21-1.4.5.jolla/extra/` ; `depmod -b`
   (records the `bochs-drm → ttm` dependency).
2. Early force-load unit `bochs-drm.service`, wanted by `sysinit.target`:
   `ExecStart=-/sbin/modprobe ttm` then
   `ExecStart=/sbin/modprobe --force-vermagic bochs_drm`.
   NOTE: modprobe lives at **`/sbin/modprobe`** (not `/usr/sbin`) — a wrong path
   yields systemd status `203/EXEC`.
3. **Drop `video=vesafb:mtrr:3 vga=792`** from the extlinux `append`. This is the
   critical bit: vesafb reserves the stdvga BAR, so otherwise bochs-drm probe
   fails with `BAR 0: can't reserve [mem 0xfd000000-...]` →
   `*ERROR* Cannot request framebuffer` → `probe ... failed with error -16`.
   Keep `console=tty0 console=ttyS0,115200n8` for the fb console.
4. **Unmask lipstick** (`rm /etc/systemd/user/lipstick.service` → the console
   tile symlinks it to `/dev/null`).
5. Rewrite `/var/lib/environment/compositor/60-emul-wayland-ui.conf`:
   keep `LIBGL_ALWAYS_SOFTWARE=1 EGL_PLATFORM=drm QT_QPA_PLATFORM=eglfs`, add
   `QT_QPA_EGLFS_INTEGRATION=eglfs_kms` and
   `QT_QPA_GENERIC_PLUGINS=evdevtouch,evdevmouse,evdevkeyboard`, and **drop
   `LIPSTICK_OPTIONS=-plugin VBoxTouch`** (VirtualBox-only). The whole software
   GL userspace (`kms_swrast_dri.so`, `libgbm`, `libEGL`, `libGLESv2`, the Qt
   eglfs-kms plugin) is already present in the stock image.

## 4. QEMU device args

**No change from the console tile.** `-vga std` presents PCI `1234:1111`, exactly
what `bochs-drm` binds. (`-device bochs-display` would also work but needs
`-vga none` and loses the early BIOS console — not worth it.) Full verify args:

    qemu-system-x86_64 -accel kvm -machine pc -cpu host -m 1536 -smp 2 \
      -drive file=sailfishos-gui.qcow2,format=qcow2,if=ide,snapshot=on \
      -vga std \
      -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
      -netdev user,id=n0 -device e1000,netdev=n0 -rtc base=localtime ...

## 5. Gallery integration (clean fit)

Same neko+QEMU tile as every other guest; only the **image path** and its baked
cmdline change. Manifest row (advanced tier) — identical to the console row in
Appendix A below except the disk path:

    GUEST_DISK=/guests/SailfishOS-gui/sailfishos-gui.qcow2

No launch-qemu.sh edit, no OVMF, no extra services, no neko-RDP. The orchestrator
can either (a) replace the console tile's image with the GUI image (drop-in), or
(b) add a second tile. `-snapshot` keeps the image pristine per session.

## 6. Loose ends / next polish (optional, non-blocking)

- **RESOLVED — no-PIN auto-unlock + LIVE :8104 deployment (2026-07-04).** See
  §8/§9 below. The tile now boots straight to the Lipstick home screen and touch
  reaches the UI on the live tile (launcher pulls up under an injected drag).
- The autologin tty1 getty from the console build can stay (Lipstick takes DRM
  master); optionally disable `getty@tty1` for a perfectly clean handover.
- Software rendering (llvmpipe) — smooth enough for a kiosk tile; expect modest
  CPU while animating. Runs fine alongside the other tiles (KVM, one vCPU-ish of
  llvmpipe work under load).

## 7. What this unlocks for OTHER guests

The generic recipe — *build a `bochs-drm.ko`/`qxl.ko`/`virtio-gpu.ko` against a
guest's own kernel source + config and force-load it to synthesize `/dev/dri`* —
applies to **any GL/KMS-only GUI stack trapped on a kernel with no
QEMU-emulatable DRM driver**: other embedded/mobile Linux images (postmarketOS
vendor kernels, Mer/Nemo, automotive/IVI builds, appliance distros) whose Wayland
compositor is `eglfs_kms`/GBM-only. Preconditions that made it work here and are
the checklist to reuse: (1) kernel source + config obtainable, (2)
`CONFIG_MODULE_FORCE_LOAD=y` **or** a real `Module.symvers` (so no full-kernel
rebuild), (3) `CONFIG_DRM=y` core builtin, (4) a software Mesa GBM path
(`kms_swrast`) in the guest userspace, (5) freeing the boot-fb BAR
(drop `vesafb`/`efifb`) so the KMS driver can probe.

## 8. No-PIN auto-unlock (lands on the Lipstick home, not the lockscreen)

The emulator image has **no device code** — `/usr/share/lipstick/devicelock/
devicelock_settings.conf` has `code_current_length=0`, `code_is_mandatory=false`,
`automatic_locking=0`. So the boot lockscreen (ambience wallpaper + big centred
clock) is **only the MCE touchscreen lock (tklock) swipe screen**, not a security
PIN. It is dismissed by asking MCE to set `tklock=unlocked`:

    dbus-send --system --type=method_call --dest=com.nokia.mce \
      /com/nokia/mce/request \
      com.nokia.mce.request.req_tklock_mode_change string:unlocked

`/etc/dbus-1/system.d/mce.conf` allows `req_tklock_mode_change` for the default
context, so no privilege tricks are needed. Baked into the image (now part of
`build-guests/tiles/sailfishos-gui.sh` `inject()` step 6):

- `/usr/bin/sailfish-kiosk-autounlock.sh` — self-healing loop: every 3 s, if
  tklock != unlocked, send `req_display_state_on` + `req_tklock_mode_change
  unlocked`. Cheap on an idle kiosk; self-heals if MCE ever re-locks.
- `/etc/systemd/system/sailfish-kiosk-autounlock.service` — `Type=simple`,
  `After=graphical.target`, **enabled via `graphical.target.wants`**.
  GOTCHA (hit + fixed): a unit `After=graphical.target` but wanted by
  `multi-user.target` never starts (`ConditionResult=no`) because graphical.target
  runs *after* multi-user.target — the pending start job is dropped. Must be
  wanted by the same target it is ordered after.
- `/etc/mce/61-kiosk-no-autolock.conf` — belt-and-suspenders: `tklock_autolock=0`,
  `tklock_blank_disable=1`, blank/dim timeouts 0 (neko streams the tile forever).

Verified on the live tile: ~95 s after container start the neko screenshot shows
the Lipstick **home** (wallpaper + small top-bar clock + bottom launcher handle),
no lockscreen, with zero manual intervention.

## 9. LIVE :8104 tile now runs the GUI image — compose change to MERGE

Done live on the host (2026-07-04). **Orchestrator: fold this into the canonical
manifest / `docker-compose.sailfishos.yml` so a fresh NVMe build is born this way.**

- Deployed GUI image (patched + no-PIN): host
  `/data/gallery-guests/SailfishOS/sailfishos-gui.qcow2`
  (= container `/guests/SailfishOS/sailfishos-gui.qcow2`). The golden
  `/data/gallery-guests/SailfishOS/sailfishos.qcow2` is **untouched** (the GUI
  image is a copy of the Option-B build output `sfos-gui-work.820/
  sailfishos-copy.qcow2`, then offline-patched with the no-PIN service).
- Compose file **`/opt/osgallery/docker-compose.sailfishos.yml`** in CT 110:
  only the one line changed —
      GUEST_DISK: "/guests/SailfishOS/sailfishos-gui.qcow2"   # was sailfishos.qcow2
  Backups left beside it: `docker-compose.sailfishos.yml.pre-gui.bak`.
  All other env is **identical** to the console tile (`QEMU_VGA=std`, the same
  `-vga std` + usb-xhci tablet/kbd + `-snapshot` QEMU_EXTRA). No launch-qemu.sh
  edit, no OVMF, no extra services.
- **Recreate ONLY this service** with the SAME compose project name it already
  uses (`osgallery-sailfish`, container `osgallery-sailfish-sailfishos-1`) — the
  directory-default project name `osgallery` collides on port 8104:
      cd /opt/osgallery && docker compose -p osgallery-sailfish \
        -f docker-compose.sailfishos.yml up -d --force-recreate sailfishos
- Live proofs (host `/data/gallery-guests/SailfishOS/`): `proof-live-8104-gui-home.jpg`
  (Lipstick home, auto-unlocked); `proof-live-8104-middrag.jpg` (launcher pulled
  up under an injected drag); `proof-live-8104-gui-home-final.jpg` (**the App Grid
  fully open with real app icons — Components, Settings — plus a Silica "Got it"
  tooltip**: unambiguous that injected touch reaches the live Lipstick UI).
  Tile Up/healthy, `http://192.0.2.12:8104` → 200.
- Neko screenshot API used for proofs (admin/admin):
  `POST /api/login {username,password}` → bearer token →
  `GET /api/room/screen/shot.jpg`.
- Input note: neko-qemu runs QEMU `-display gtk,full-screen=on,zoom-to-fit=on` on
  X `:99` (1280x720); the guest framebuffer renders **1:1 in the top-left
  ~639x505** (letterboxed, black elsewhere — a pre-existing neko-qemu display
  sizing trait, same as the console tile). Inject touch with `xdotool` on X `:99`
  and keep coordinates **inside** that box (y<505); Sailfish edge gestures must
  start at the guest's own bottom edge (~y=502), and pace the drag (~60 ms/step)
  or the recognizer treats the burst as noise.

---

<!-- APPENDIX A: merged from scripts/sailfish-tile-notes.md — the original text-console tile (superseded for GUI by the KMS recipe above) -->

# SailfishOS gallery tile (:8104) — integration notes

Verified live on the dry-run box 2026-07-04. Written as a **merge hand-off** so the
orchestrator could reconcile `gallery-integrate-all.sh` (neko-era, deleted;
concurrently edited by sibling agents at the time).

Reproducible image build: `scripts/build-guests/tiles/sailfishos.sh`.

---

## TL;DR — what this tile is

- **Image**: Sailfish OS 5.1.0.11 "Pispala", the official **Sailfish SDK emulator**
  disk. Format **qcow2**, virtual 8 GiB (~374 MiB used), **32-bit x86 (i686)**,
  kernel `5.0.21-1.4.5.jolla`. **MBR/BIOS** boot via extlinux/syslinux, single
  ext4 root `/dev/sda1`, `vesafb` 1024×768 (`vga=792`). **No UEFI, no OVMF.**
- **The Lipstick (Wayland/touch) GUI does NOT render under QEMU** — this is a hard
  structural limit of the stock VirtualBox emulator image, not a mis-config
  (full root-cause in the `sailfishos.sh` header + "Why no GUI" below).
- The tile therefore presents Sailfish as a **live, interactive text console**
  (autologin root shell, "Sailfish OS 5.1.0.11 (Pispala)" banner) on the
  framebuffer — like the Alpine / TinyCore / FreeDOS console tiles. **Verified**:
  neko keyboard input reaches the shell and commands execute (`id`, `uname`
  rendered on the framebuffer via the neko admin screenshot API).

---

## Exact manifest row to add to `gallery-integrate-all.sh` (historical — neko-era, deleted; never merged)

Add to the `GUESTS=( ... )` array (tier `advanced`, i.e. wired with
`--include-advanced` / `--only sailfishos`):

```
"qemu|sailfishos|Sailfish OS|1536|2|pc|std|-device AC97,audiodev=snd|GUEST_DISK=/guests/SailfishOS/sailfishos.qcow2 GUEST_FMT=qcow2 GUEST_IF=ide GUEST_BOOT=c|-enable-kvm -cpu host -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 -netdev user,id=n0 -device e1000,netdev=n0 -snapshot|advanced"
```

Field breakdown (pipe-delimited, same schema as the other rows):

| field | value |
|-------|-------|
| type | `qemu` |
| key | `sailfishos` |
| label | `Sailfish OS` |
| mem (MB) | `1536` |
| smp | `2` |
| machine | `pc` |
| vga | `std` |
| sound | `-device AC97,audiodev=snd` |
| guestenv | `GUEST_DISK=/guests/SailfishOS/sailfishos.qcow2 GUEST_FMT=qcow2 GUEST_IF=ide GUEST_BOOT=c` |
| extra | `-enable-kvm -cpu host -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 -netdev user,id=n0 -device e1000,netdev=n0 -snapshot` |
| tier | `advanced` |

And pin the published host port (EPR stays index-derived → collision-free):

```sh
declare -A FIXED_PORT=( [serenityos]=8102 [postmarketos]=8103 [sailfishos]=8104 )
```

Also update the stale comment near the manifest that currently says *"Sailfish is
intentionally ABSENT (renders black in plain QEMU)"* — it now renders a live
interactive **console** (the black-screen was lipstick's eglfs crash + no fb
getty; both fixed by `sailfishos.sh`).

- `usb-tablet` = absolute pointer (kept for parity with the other mobile tiles);
  `usb-kbd` → the tty1 autologin shell. `-snapshot` keeps the golden qcow2
  pristine (ephemeral per-session, correct for a kiosk).
- EPR for port 8104 in the running tile: **53280–53299** (free; next after
  postmarketOS 53240–53259 / serenityos 53260–53279). When wired through
  `gallery-integrate-all.sh` (neko-era, deleted) the EPR was index-derived
  instead — either was fine.

## launch-qemu.sh change required: **NONE**

This tile uses **only stock `launch-qemu.sh` env vars** (`GUEST_DISK/FMT/IF/BOOT`
+ `QEMU_VGA/MEM/SMP/MACHINE` + `QEMU_EXTRA`). **No OVMF** (BIOS/syslinux boot),
no writable-overlay, no autologin-typer. So `osgallery/neko-qemu/launch-qemu.sh`
does **not** need any edit for Sailfish — nothing to reconcile there.

## Hard dependency: the image must be the PATCHED qcow2

`scripts/build-guests/tiles/sailfishos.sh` produces
`/data/gallery-guests/SailfishOS/sailfishos.qcow2` with three QEMU-compat patches
baked in (idempotent, via `qemu-nbd`):

1. **extlinux kernel append** → adds a framebuffer console + quiets kernel/audit
   spam: `console=tty0 console=ttyS0,115200n8 … quiet loglevel=3 audit=0`
   (drops the VBox-oriented `splash` + cursor-hide). Without `console=tty0` the
   framebuffer stays black (kernel console was serial-only).
2. **autologin root getty on tty1** (framebuffer) + ttyS0 (serial/debug) → the fb
   shows an interactive Sailfish shell. Without it there is no fb getty at all.
3. **mask `lipstick.service`** (user unit → `/dev/null`) → stops the eglfs
   "Could not find DRM device" crash-loop (Restart=always) from burning CPU.

The staged image on the box already carries these patches. A fresh NVMe rebuild
just re-runs `sailfishos.sh` (point it at the emulator VDI via `SFOS_VDI=` or an
archive via `SFOS_EMULATOR_URL=`, or reuse an existing qcow2 with
`SFOS_SKIP_DOWNLOAD=1`).

---

## How the live tile is currently wired (concurrency-safe)

To avoid clobbering the sibling-edited `docker-compose.gallery-guests.yml`, the
live :8104 tile runs as an **isolated compose project**:

- File (in CT 110): `/opt/osgallery/docker-compose.sailfishos.yml` (service
  `sailfishos`, image `neko-qemu:latest`, port `8104:8080`, EPR `53280-53299`,
  volume `./gallery-guests:/guests:ro`, `/dev/kvm`).
- Brought up with a distinct project so it never touches other tiles:
  ```sh
  cd /opt/osgallery
  docker compose -p osgallery-sailfish -f docker-compose.sailfishos.yml up -d
  ```
- Status: `osgallery-sailfish-sailfishos-1` — **Up (healthy)**, `http://…:8104/`
  returns **HTTP 200**.

**Final reconciliation (orchestrator's choice):**
- Preferred: add the manifest row + FIXED_PORT line above, regenerate
  `docker-compose.gallery-guests.yml`, then retire the standalone project:
  `docker compose -p osgallery-sailfish -f docker-compose.sailfishos.yml down`.
- Or simply keep the standalone compose file as-is (it is self-contained and
  independent of the main stack).

---

## Why there is no touch GUI under QEMU (verified, not inferred)

- lipstick's only Qt platform plugin is **`eglfs`**; its only EGL device
  integrations are **`eglfs_kms` / `eglfs_kms_egldevice`** → both need a DRM/KMS
  device (`/dev/dri/cardN`). Run by hand it aborts (SIGABRT):
  `qt.qpa.eglfs.kms: Found the following video devices: ()  Could not find DRM device!`
- The kernel’s DRM/KMS drivers are **only** `vboxvideo` (VirtualBox), `i915`
  (real Intel HW), `gma500` (Poulsbo), `udl` (DisplayLink). Every
  QEMU-emulatable GPU driver is disabled in the kernel config
  (`# CONFIG_DRM_BOCHS/QXL/VIRTIO_GPU/CIRRUS_QEMU/VMWGFX/AST/MGAG200 is not set`).
  Under QEMU the guest gets only `vesafb` (`/dev/fb0`), **no `/dev/dri`** — so
  eglfs_kms has nothing to bind. (The emulator even hard-codes VirtualBox in
  `/var/lib/environment/compositor/60-emul-wayland-ui.conf`: `EGL_PLATFORM=drm`,
  `QT_QPA_PLATFORM=eglfs`, `LIPSTICK_OPTIONS=-plugin VBoxTouch`.)
- Qt here is **5.6.3**, which predates the Qt Quick software renderer (Qt 5.8) —
  there is **no `QT_QUICK_BACKEND=software` and no `linuxfb` plugin** installed,
  so there is no non-GL fallback for the QML shell.

**To get the real Lipstick GUI later** (either path):
1. Run this image under **VirtualBox** (vboxvideo provides the KMS device); or
2. Give the guest kernel a QEMU-drivable KMS driver — build & load **`bochs.ko`**
   for `-vga std` (or qxl/virtio-gpu). Blocked in-place today: no
   kernel-devel / kernel-source / `Module.symvers` / `vmlinux` / build-tree is
   on the device or in the Jolla repos, and `CONFIG_MODVERSIONS=y` (a hand-built
   module needs matching symbol CRCs). `CONFIG_MODULE_SIG` is off, so once a
   correctly-versioned `bochs.ko` exists it would load (and could be force-loaded
   with `modprobe --force-modversion` if built from the exact 5.0.21 source).
   With `/dev/dri/card0` present, drop the `VBoxTouch` plugin, let eglfs_kms use
   llvmpipe (`LIBGL_ALWAYS_SOFTWARE=1`, already set), and add evdev input for the
   usb-tablet → the touch shell should composite in software.

---

<!-- APPENDIX B: merged from scripts/sailfish-vbox-notes.md — the earlier VirtualBox/VRDE route (Option A, superseded by the bochs-drm KMS recipe above) -->

# Sailfish OS — real Lipstick touch GUI via VirtualBox + VRDE (Option A)

Status: **PROVEN on the dry-run box 2026-07-04.** The real Sailfish OS 5.1.0.11
"Pispala" **Lipstick (Wayland/eglfs) touch GUI renders** when the emulator image
runs under **VirtualBox** (its kernel has the `vboxvideo` DRM/KMS driver), and it
is reachable as a normal **RDP** endpoint via VirtualBox **VRDE** — which slots
straight into the gallery's existing **neko-RDP** tile pattern (the Windows 11
tile). This is the fix for the `:8104` tile being only a text console under QEMU.

Reproducible driver: `scripts/build-guests/sailfishos-vbox.sh`
(`prep | l1 | vbox | l2 | shot | nekotile | stop | all`) — the losing option,
neko-era, deleted in the 2026-07 restructure (git history); Option B (bochs-drm
KMS, above) won and is the live path. This appendix is kept as the record of the
nested-VirtualBox route.

Framebuffer proofs (on the box under `/data/sfvbox-810/`, copies pulled to the
session scratchpad):
- `proof-lipstick-gui.png` — **the Lipstick lock screen** (ambience wallpaper +
  live clock "13:49 / Saturday 4 Jul"), captured with `VBoxManage controlvm sfos
  screenshotpng`. This is the exact GUI that SIGABRTs under QEMU.
- `neko-sfos.jpg` — the **VBox framebuffer streamed over RDP through neko**
  (neko admin screenshot API), showing the guest enumerating the *VirtualBox USB
  Tablet* pointer and `[drm] Initialized vboxvideo`. End-to-end RDP path works.

---

## Why this works where QEMU cannot (one line)

VirtualBox presents a **VBoxVGA** adapter (PCI `80ee:beef`). The Sailfish kernel
(`5.0.21-1.4.5.jolla`) ships a DRM/KMS driver for exactly that adapter
(`vboxvideo`), so `/dev/dri/card0` exists → Qt 5.6 `eglfs_kms` binds → Lipstick
composites (software GL/llvmpipe, `LIBGL_ALWAYS_SOFTWARE=1` is preset in the
image). QEMU can present no vboxvideo-compatible GPU, so there is no `/dev/dri`
and eglfs aborts. See `sailfishos.sh` header / Appendix A below for the
full root cause.

---

## SAFETY / COEXISTENCE with the live KVM gallery (the critical question)

**VirtualBox is NOT installed on the Proxmox host and never touches host VT-x.**
It runs inside a **nested KVM VM**, so from L0's view the whole stack is just one
more ordinary KVM guest:

```
L0  Proxmox host (KVM, kvm_intel nested=Y)     <- VM 900/925 + LXC 110 gallery live here, UNTOUCHED
 └─ L1  Debian 12 VM   (VMID 810, raw qemu, -cpu host => nested vmx exposed)
      └─ VirtualBox 7.1.18  (vboxdrv built against the L1 kernel; uses NESTED VT-x inside L1)
           └─ L2  Sailfish emulator VM  (VBoxVGA -> vboxvideo -> Lipstick GUI)
                └─ VRDE :3389 -> L1 hostfwd :6189 -> neko-rdp tile (CT 110)
```

- The dangerous host-level VBox-vs-KVM VT-x fight is **structurally avoided**:
  VBox's `VMXON` happens in L1's virtual CPUs, which L0 KVM emulates as nested
  VMX. VMs 900/925 keep their own vCPUs and host VT-x root state. **Verified: 900
  and 925 stayed `running` throughout build, boot, reboot, and VRDE.**
- Requires host `kvm_intel nested=Y` (it is). The script hard-fails if not set.
- Cost is real but bounded: L1 was given 10 GiB RAM / 6 vCPU (host has 125 GiB /
  16 threads, ~58 GiB free). Nested + software-GL boot to Lipstick is **slow
  (~150 s)** — fine for a persistent kiosk VM, not for cold-start-per-session.
- Disk: whole stack ≈ 2.5 GiB on `data` (Debian 24 GiB thin ≈ 1.6 GiB used +
  Sailfish VDI ≈ 0.9 GiB). Pool stayed > 27 GiB free.

**Honest caveat — licensing, not stability:** VRDE's RDP server lives in the
**Oracle VirtualBox Extension Pack**, whose license (PUEL) is **Personal Use /
Educational only**. A private home-lab gallery is fine; a publicly-served or
"commercial" gallery would need to respect that. (VRDE without the ext pack =
no RDP server. A non-VBox capture path would mean scraping the Wayland
compositor, which Lipstick's fullscreen eglfs makes non-trivial.)

---

## Build recipe (what actually worked, incl. gotchas)

### 1. Prepare a COPY of the golden qcow2 for native VBox boot
`prep_disk()` (never touches `/data/gallery-guests/SailfishOS/`):
- **unmask** `lipstick.service` (the QEMU tile masked it to stop a crash-loop;
  VBox needs it running) — `rm /etc/systemd/user/lipstick.service`.
- **drop** the tty1 autologin getty override + `getty.target.wants` symlink the
  QEMU tile added, so Lipstick owns the display/VT normally.
- **restore native kernel append**: `ro root=/dev/sda1 console=tty0
  console=ttyS0,115200n8 rootfstype=ext4` (drop the forced `video=vesafb
  vga=792` so vboxvideo drives the display). Lipstick still modesets over the
  fbcon; leaving `console=tty0` just means kernel/audit text shows until Lipstick
  takes the CRTC (add back `quiet loglevel=3 audit=0` for a clean kiosk).

### 2. L1 Debian VM
Debian 12 **genericcloud** qcow2 + a NoCloud `seed.iso` (genisoimage) injecting a
throwaway ed25519 key for user `debian`. Booted with **raw qemu** (not a Proxmox
`qm` VM, to stay isolated + pidfile-controlled), `-cpu host` for nested vmx,
user-net `hostfwd 6112->22` and `6189->3389`. The prepared Sailfish qcow2 is
attached as a **2nd virtio disk** so we convert it in-guest (no big copy).

### 3. VirtualBox inside L1
Oracle apt repo → `virtualbox-7.1` (7.1.18). `sudo /sbin/vboxconfig` builds
`vboxdrv` against the L1 kernel (needs `linux-headers-$(uname -r)` +
build-essential; a kernel upgrade may pull a newer headers set — build for the
running kernel). VDI: `VBoxManage convertfromraw /dev/vdb sfos.vdi --format VDI`.

### 4. L2 Sailfish VBox VM
```
VBoxManage createvm  --name sfos --ostype Linux26 --register
VBoxManage modifyvm  sfos --memory 1024 --vram 128 --graphicscontroller vboxvga \
   --ioapic on --rtcuseutc off --mouse usbtablet --keyboard ps2 --audio-driver none --nic1 nat
VBoxManage storagectl   sfos --name IDE --add ide --controller PIIX4
VBoxManage storageattach sfos --storagectl IDE --port 0 --device 0 --type hdd --medium ~/sfos.vdi
VBoxManage modifyvm  sfos --vrde on --vrdeport 3389 --vrdeaddress 0.0.0.0 --vrdeauthtype null --vrdemulticon on
VBoxManage startvm   sfos --type headless
```
- `--ostype Linux26` (not `Linux_32`, which 7.1 rejects). `--graphicscontroller
  vboxvga` is essential — it is the adapter `vboxvideo` binds to.
- `--mouse usbtablet` → the guest enumerates a *VirtualBox USB Tablet* (absolute
  pointer), which is what the touch UI consumes. (`--mouse multitouch` also
  available if a gesture layer needs it; the image's `LIPSTICK_OPTIONS=-plugin
  VBoxTouch` maps VBox absolute input into the shell.)

### VRDE / Extension Pack gotchas (cost me three iterations)
- File name in 7.1 is **`Oracle_VirtualBox_Extension_Pack-<ver>.vbox-extpack`**
  (Oracle dropped the "VM"). The old name 404s.
- `--accept-license=<sha256-of-file>` does **not** match; VBox wants the
  *license-text* hash (it prints the right one on refusal — for 7.1.18 it is
  `eb31505e56e9b4d0fbca139104da41ac6f6b98f8e78968bdf01b1f3da3c4f9ae`). Simplest:
  `echo y | sudo VBoxManage extpack install --replace <file>`.
- After install, **restart VBoxSVC** or it keeps reporting `Extension Packs: 0`
  and the VM log says `VRDE: ... is not available` (VRDP silently absent, nothing
  listens on 3389). Killing VBoxSVC is safe here — L1 is a throwaway guest.
- VRDE must be enabled while the VM is **off**; runtime `controlvm vrde on` fails
  (`COMSETTER(Enabled)`), if the VM was started without it.
- Verified good state: `ss -tlnp` shows `LISTEN 0.0.0.0:3389 VBoxHeadless`, VM log
  shows `VRDE: [VRDE::INPUT]` (the RDP input channel).

---

## Gallery integration — neko-RDP tile (mirrors the Windows 11 tile)

The Win11 tile is `neko-rdp:latest` driven by `RDP_HOST/RDP_PORT/RDP_USER/
RDP_PASS/RDP_RES` + `NEKO_EPR/NEKO_NAT1TO1/NEKO_ICELITE`. Sailfish plugs into the
**same image and contract** — only the RDP target changes to the VRDE endpoint:

```sh
# prototyped on scratch port 8109 (EPR 53300-53319) in CT 110, isolated
# `docker run` — does NOT touch the live :8104 console tile or the main stack:
docker run -d --name osgallery-sfvbox-rdp \
  -e RDP_HOST=192.0.2.10 -e RDP_PORT=6189 -e RDP_USER= -e RDP_PASS= -e RDP_RES=1024x768 \
  -e NEKO_PASSWORD=neko -e NEKO_PASSWORD_ADMIN=admin \
  -e NEKO_EPR=53300-53319 -e NEKO_NAT1TO1=192.0.2.12 -e NEKO_ICELITE=true \
  -p 8109:8080 -p 53300-53319:53300-53319/udp neko-rdp:latest
```
- `RDP_HOST=192.0.2.10` (Proxmox host) `:6189` = the L1 hostfwd to VRDE 3389.
  For a permanent tile, give L1 its own bridged IP and point RDP_HOST there
  instead of relying on a user-net hostfwd.
- `RDP_USER=/RDP_PASS=` empty because VRDE runs `--vrdeauthtype null`.
- **Result:** xfreerdp3 completed the full RDP activation handshake (reached the
  MS-RDPBCGR *Font Map PDU*; the noisy `winpr_log_backtrace` around it is a
  benign warning — VBox VRDP sends a 0-byte Font Map PDU that FreeRDP grumbles
  about but accepts). neko streamed the live VBox framebuffer (`neko-sfos.jpg`).

**Integration verdict:** cleanest as a **neko-RDP tile** (same image as Win11),
NOT a neko+QEMU tile. But unlike Win11 (whose RDP server is a separate always-on
Windows box), Sailfish's RDP server is *inside a VBox VM inside a nested KVM VM*
— i.e. this tile carries an **extra L1 KVM VM per host** as a dependency, plus
the PUEL ext-pack. It is a heavier, two-hypervisor stack than any other tile.

---

## What was NOT fully automated (honesty)

- A scripted **end-to-end touch gesture** (swipe-to-unlock) through neko→RDP was
  not driven — neko v3 input is WebRTC-only and awkward to script via curl. What
  IS proven: the absolute-pointer device is enumerated in-guest, the VRDE INPUT
  channel is up, and the neko-rdp session (the same path the Win11 tile uses for
  full mouse+keyboard) is established and streaming. Input reaching the shell is
  therefore expected to work exactly as it does for Win11; a manual browser click
  on `:8109` is the last confirmation step.
- Boot to Lipstick is ~150 s under nested software-GL. For a kiosk, keep L1 + the
  L2 VM **persistent** (don't cold-start per viewer). `-snapshot`-style
  ephemerality would re-pay that cost each session.

## Teardown (pidfile-only, no pkill on host)
`sailfishos-vbox.sh stop` (neko-era, deleted) → `VBoxManage controlvm sfos poweroff` in L1, then
`system_powerdown` via the L1 qemu monitor socket, fallback `kill $(cat l1.pid)`.
Remove the scratch tile: `docker rm -f osgallery-sfvbox-rdp` in CT 110.
