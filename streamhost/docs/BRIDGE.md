# The "emulator bridge" pattern — one captured Linux guest, many retro machines

This is the reusable recipe for putting a machine that streamhost/QEMU can't run
natively (a Commodore 64, an Atari ST, an Apple //e, an Amiga 500, …) into the
gallery: run a **software emulator of that machine full-screen inside a captured
x86 Linux guest**, and let streamhost capture the Linux guest's framebuffer +
audio exactly like every other tile. The retro machine is "bridged" through a
minimal Linux kiosk.

**28 emulator bridge tiles are live today** — the roster is the `tiles` map in
`registry/bridge-suites.json`, which is also the ledger for the bookworm→trixie
migration below. The four originals (`c64`/VICE, `atarist`/hatari,
`apple2`/LinApple, `amiga`/FS-UAE) each run in a permanent 3 GiB qcap scope.
`openvms` uses a related graphical bridge pattern and is NOT on this base:
Linux is only the captured X server, while OpenVMS supplies the window manager
and clients.

The **C64 + GEOS** tile (`/data/vms/streamhost/tiles/c64/`) is the reference
implementation; this doc is written so a fan-out agent can clone it for the
other machines by only swapping the emulator, the media, and one launch script.

For heavier graphical emulators, the guaranteed pointer gate and measured
latency budget are in [GRAPHICAL-BRIDGE.md](GRAPHICAL-BRIDGE.md).

## OpenVMS graphical X bridge

The OpenVMS DECwindows tile is the first two-QEMU bridge. A 768 MiB Debian
bridge runs lean Xorg with standard VGA, QEMU D-Bus display, and usb-tablet.
It has no Linux window manager or display manager; its Xinit client only
disables blanking, paints the root, and sleeps. OpenVMS runs independently as
the X client and supplies `DECW$MWM`, DECterm, FileView, Clock, and Calculator.

The networks are deliberately independent. The bridge QEMU forwards
`tcp:127.0.0.1:6610-:6000`; OpenVMS reaches that loopback listener through its
own SLIRP gateway as `10.0.2.2:6610`. This needs no tap, socket LAN, or relay.
Xorg's `-ac` is acceptable only behind the host-loopback NAT boundary.

The bridge image is reproducible:

```sh
scripts/build-guests/stages/openvms-decwindows-bridge.sh
```

The launcher gates on the bridge listener before restoring OpenVMS from
`leanx-preconnect`. This snapshot is before `SET DISPLAY`, so all connections
are created fresh. Never reset this tile with warm `loadvm`: VMState revives
dead X sockets and stale SLIRP state. `SH_RESET_MODE=restart` maps visitor
reset to a cold `streamhost@openvms` service restart, which rebuilds both QEMU
processes and replays the fixture. See `docs/guests/openvms.md`.

---

## 1. The shared base image (build ONCE, freeze, never touch)

`/data/vms/bridge/bridge-base.qcow2` — a lean Debian 12 (bookworm) x86_64 guest.
Built deterministically by `scripts/build-guests/lib/bridge-base.sh` from a **Debian
genericcloud qcow2 + a cloud-init NoCloud seed ISO** (reproducible on an NVMe
rebuild).

**Two bases now coexist.** The host is Debian 13 (trixie) since 2026-07-15; the
guest base is not, and cannot be migrated in one shot because 28 overlays back
onto it. `bridge-base.sh --suite bookworm|trixie` builds either — the bookworm
one at the path above (frozen, path sacred), the trixie one at
`/data/vms/bridge/bridge-base-trixie.qcow2`. Which suite a tile is on is
declared per tile in `registry/bridge-suites.json` and resolved by
`scripts/build-guests/lib/bridge-suite.sh`. Read
[`docs/lab/BRIDGE-TRIXIE-MIGRATION.md`](../../docs/lab/BRIDGE-TRIXIE-MIGRATION.md)
before touching either base or any bridge builder.

The base contains, ready to use:

- **Five emulators** — this is the emulator set the BASE ships, **not** the tile
  roster (28 tiles draw on it, and several install their own emulator into their
  overlay). Baked in so no base rebuild is needed to add one of these machines:
  | machine        | emulator binary | source                                   |
  |----------------|-----------------|------------------------------------------|
  | Commodore 64   | `x64sc`         | VICE 3.9, **built from source** (SDL2 UI)|
  | Atari ST       | `hatari`        | Debian apt (`hatari`)                    |
  | Apple //e      | `linapple`      | source (github linappleii/linapple)      |
  | Amiga 500      | `fs-uae`        | Debian apt (`fs-uae`) — overlay-installed on the live `amiga` kiosk first, now baked into the current `bridge-base.sh` |
  | Amstrad CPC    | `cap32`         | source (github ColinPitrat/caprice32) — **available in the base image, not deployed** as a tile |
- **A bare-X kiosk** (no window manager, no display manager): autologin on tty1 →
  `startx` → `~/.xinitrc` → a single per-tile launcher `/etc/bridge/launch.sh`
  full-screen.
- **Firmware/media** in `/opt/bridge/media/` (`GEOS.D64`, `etos1024k.img`, …),
  provenance in `/opt/bridge/media/LICENSES`.
- **ALSA default routed to the QEMU AC97 card** (`/etc/asound.conf`) so emulator
  audio (SID, YM2149, …) reaches QEMU's dbus audiodev → streamhost.

Because the base is the **read-only qcow2 backing** for every bridge tile, it is
FROZEN after the build — an overlay names its backing file by path and depends
on it block-for-block, so editing or rebuilding it corrupts all 28 at once. The
bookworm base has been frozen since 2026-07-15 and
`bridge-base.sh --suite bookworm` refuses to rebuild it without
`--i-know-this-breaks-every-overlay`. The trixie base is not frozen only because
nothing backs onto it yet; it freezes the moment the first overlay does.

Add packages by baking them into the per-tile overlay, or — for the trixie base,
while it is still empty — by rebuilding it. Migrating a tile between suites is a
per-tile rebuild + golden re-bake + framebuffer acceptance + ledger flip; the
procedure, the per-tile verdicts and the wave order are in
[`docs/lab/BRIDGE-TRIXIE-MIGRATION.md`](../../docs/lab/BRIDGE-TRIXIE-MIGRATION.md).

### Three non-obvious base-build gotchas (all handled in `bridge-base.sh`)

1. **The genericcloud `cloud` kernel has no e1000 driver.** The streamhost tile
   device set uses an `e1000` NIC; the trimmed cloud kernel is virtio-only. The
   base therefore installs `linux-image-amd64` (full generic kernel) which
   carries both drivers. Provision over **virtio-net** (cloud kernel can drive
   that); the frozen base boots fine under the e1000 tile device set.
2. **SLIRP DHCP is flaky for this image's networkd** (wait-online hangs, no
   lease). Use a **deterministic STATIC IP** matching SLIRP's fixed addressing
   (`10.0.2.15/24`, gw `10.0.2.2`, dns `10.0.2.3`) and mask
   `systemd-networkd-wait-online`. Identical for the virtio provisioning NIC and
   the e1000 tile NIC (both enumerate `en*`).
3. **VICE is NOT in Debian 12** (removed over ROM/DFSG licensing) — `apt install
   vice` fails on bookworm. It is BACK in **trixie/contrib** (`vice 3.9+dfsg-1`,
   ships `/usr/bin/x64sc`), but that package is the GTK3 UI build and the kiosk
   needs the SDL2 fullscreen build with no window manager — so `x64sc` is built
   from source (SDL2) on both suites. Its `./configure` aborts
   without `libcurl4-openssl-dev`; `cap32` needs `libfreetype-dev`; LinApple's
   Makefile is at the repo **root**, not `src/`.

---

## 2. The kiosk / xinitrc pattern

Autologin → X → one full-screen SDL app, no WM:

- `/etc/systemd/system/getty@tty1.service.d/autologin.conf` autologins user
  `bridge` on tty1.
- `~/.bash_profile`: on tty1 with no `$DISPLAY`, `exec startx`.
- `~/.xinitrc`: disables screensaver/DPMS (`xset s off -dpms s noblank`), forces a
  deterministic resolution (`xrandr --output <out> --mode 1024x768`, best-effort),
  then `exec /etc/bridge/launch.sh`. **No window manager is started** — the single
  SDL emulator owns the whole root window.
- `/etc/X11/xorg.conf.d/10-bridge.conf`: `modesetting` driver with
  `Option "AccelMethod" "none"` (host has no GPU — software shadow fb, no GL) and
  DPMS/blanking off.
- `/etc/X11/Xwrapper.config`: `allowed_users=anybody` + `needs_root_rights=yes`
  so `startx` works from the autologin tty and can KMS-modeset.

To land a specific machine you overlay **only** `/etc/bridge/launch.sh`.

---

## 3. The per-tile overlay recipe (what a fan-out agent copies)

For a new machine `M` (namespacing assigned per tile: dir, VMID, UDP, ssh
hostfwd, SPA web port — never collide with an existing tile):

### 3a. Thin overlay (NOT a full copy — /data is tight)
```
qemu-img create -f qcow2 -b /data/vms/bridge/bridge-base.qcow2 -F qcow2 \
  /data/vms/streamhost/tiles/<M>/overlay.qcow2
```

### 3b. Boot the overlay once (tile device set, NO -loadvm) and write the launcher
Over ssh (gallery key `/data/vms/bridge/bridge_key`, host->guest :22 on the tile's
hostfwd port), write `/etc/bridge/launch.sh` with the emulator + media + flags for
`M`, e.g. the VERIFIED C64 launcher:
```bash
#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software   # GPU-less host: force SDL software renderer (no GL)
export SDL_VIDEODRIVER=x11
exec x64sc -mouse -controlport1device 1351 \
  -sounddev alsa -drive8truedrive -autostart-handle-tde -VICIIdsize \
  -autostart /opt/bridge/media/GEOS-1351.D64
```
Then restart X (`systemctl reset-failed getty@tty1; systemctl restart getty@tty1`)
so it lands straight on the machine's desktop unattended.

**VICE 3.9 SDL2 flag gotchas (hard-won — many "obvious" flags don't exist):**
- `-drive8truedrive` (per-drive) is how you enable TRUE DRIVE emulation — REQUIRED
  or the GEOS deskTop hangs. There is NO global `-truedrive` in 3.9.
- `-autostart-handle-tde` keeps true-drive ON during autostart (else GEOS breaks).
- `-mouse -controlport1device 1351` enables VICE mouse input and attaches a
  proportional 1351 to C64 control port 1. The per-tile build makes
  `GEOS-1351.D64` by removing the boot disk's `JOYSTICK` input driver, leaving
  `COMM 1351` active.
- `-sdl2` and `-fullscreen` are INVALID flags. `-VICIIfull` (SDL real-fullscreen
  mode-switch) renders BLACK in the captured std-VGA framebuffer — use a double-size
  WINDOW (`-VICIIdsize`) on the bare-X root, which the framebuffer captures correctly.
- If VICE can't open its sound device it pops a MODAL "Sound: initialization failed"
  dialog and blocks — so the tile device set MUST include the AC97 card, and
  `/etc/asound.conf` must route the ALSA default to it (hw:0,0).
- x64sc SEGFAULTS in its early logger if stdout is NOT a terminal — so launch.sh must
  NOT redirect stdout to a file (the kiosk runs it on tty1, a terminal — fine).

Per-machine swaps for the other machines:
- **Atari ST / EmuTOS**: `hatari --tos /opt/bridge/media/etos1024k.img --fullscreen`
- **Apple //e / GEOS**: `linapple -f` with the ProDOS GEOS disk configured in
  `~/.linapple/linapple.conf` (LinApple bundles the //e ROM).
- **Amiga 500 / Workbench**: `fs-uae` with a per-tile config — the deployed
  `amiga` tile; see `scripts/build-guests/tiles/amiga.sh` for the exact launcher.
- **Amstrad CPC**: `cap32 -O fullscreen=true <disk.dsk>` (cap32 bundles CPC
  ROMs). *Available in the base image, not deployed as a gallery tile.*

### 3c. The tile device set (MUST be byte-identical at golden-bake and boot)
```
qemu-system-x86_64 -name streamhost-<M> -enable-kvm -m 1536 -smp 2 -cpu host -rtc base=localtime \
  -drive file=<overlay.qcow2>,if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:<sshport>-:22 -device e1000,netdev=n0 \
  [-loadvm golden]                      # only when the golden snapshot is present
  -qmp unix:<dir>/qmp.sock,server=on,wait=off -pidfile <dir>/qemu.pid
```
Keep `-m 1536` identical between bake and boot. The `-netdev ...hostfwd` is a
host-side SLIRP property (NOT part of the VM-state snapshot), so changing the port
is safe; adding/removing any `-device` is NOT (breaks `-loadvm golden`).

**C64/VICE pointer exception:** VICE 3.9 SDL2 consumes relative host motion.
The C64 launcher therefore uses `-machine pc-i440fx-11.0,vmport=off`, keeps
`-usb` but omits `-device usb-tablet`, and emits `--pointer rel`. Browser samples
are still absolute video coordinates; streamhost converts them to bounded PS/2
deltas. Without `vmport=off`, QEMU's implicit VMware absolute mouse becomes the
active handler and silently absorbs REL events. The other bridge tiles retain
the usb-tablet/absolute device set above.

### 3d. Golden bake (INTERNAL qcow2 snapshot via HMP-over-QMP)
When the framebuffer shows the machine's desktop AND audio is verified non-silent:
```
python3 /root/qmp_hmp.py <dir>/qmp.sock 'savevm golden'      # bake
python3 /root/qmp_hmp.py <dir>/qmp.sock 'loadvm golden'      # verify restore
python3 /root/qmp_hmp.py <dir>/qmp.sock 'info snapshots'     # list
```
The tile launcher then auto-boots straight into the fixture: it runs `qemu-img
snapshot -l overlay.qcow2 | grep -qw golden && LOADVM="-loadvm golden"` (same
pattern as the `alpine` tile). The golden snapshot lives INSIDE `overlay.qcow2`
(RAM + device state), so the overlay must never be deleted/recreated after bake.

### 3d-bis. `coldboot` — the disk-only checkpoint before the bake

`golden` is the *only* snapshot most overlays carry, which means the builder is
the sole recipe for re-creating an exhibit and it has no backstop. `coldboot`
(`scripts/build-guests/lib/bridge-coldboot`) is the missing checkpoint: the disk
as the builder left it, taken with the VM **stopped** via `qemu-img snapshot -c`,
which stores **no VM RAM**.

Measured 2026-08-10: a `coldboot` costs **131 KB** on a fresh overlay and **65 KB**
on one carrying 1 GiB of data (0 MiB extra on disk, 0.06–0.40 s), against
**424–1442 MiB** for the `savevm` goldens across the live tiles. It is
metadata-proportional, not RAM-proportional, so it is effectively free
fleet-wide.

```
bridge-coldboot snapshot <overlay>          # take it, after provisioning, before driving
bridge-coldboot revert   <overlay>          # re-bake restart point: boot, drive, bake
bridge-coldboot mutate   <overlay> -- <cmd> # OFFLINE disk edit, VM not running
bridge-coldboot status   <overlay>
```

**`mutate` drops any existing `golden`, unconditionally.** That is the whole
point rather than a side effect: the tile boots `-loadvm golden`, and `loadvm`
restores the snapshot's DISK state as well as its RAM, so an offline mutation
that left a golden in place would be silently discarded at every boot while
every log and screenshot looked healthy.

Two hard-won constraints it encodes, both measured on this box:

- **`pve-qemu-kvm` does not enforce the qcow2 image lock.** `qemu-img snapshot -c`
  succeeds against an image a running VM holds open. So "qemu-img will stop me"
  is false here; the helper checks `/proc/<pid>/fd` for holders instead.
- **Only `ext2/3/4`, `vfat`, `exfat`, `ntfs` are writable**, probed at run time.
  The kernel will mount Haiku BFS, Solaris UFS and Amiga AFFS read-only or with
  unverified write paths, and a partial write to one of those corrupts a golden
  that took hours to bake. Per-tile verdicts:
  [`docs/lab/OFFLINE-MUTATION-MATRIX.md`](../../docs/lab/OFFLINE-MUTATION-MATRIX.md).

### 3e. Emit the streamhost tile + start the daemon
Use the existing emitter for `tile.env`, then hand-patch `qemu-streamhost.sh` to
the exact device set above (the emitter defaults `--disk` to `if=virtio`; bridge
tiles need `if=ide,format=qcow2` + the conditional `-loadvm golden`, so the
launcher is customized — see `c64/qemu-streamhost.sh`):
```
/data/vms/streamhost/scripts/streamhost-tile.sh \
  --tile <M> --vmid <ID> --udp <UDP> --pointer abs \
  --audio on --audio-dev ac97 --input-dev usb \
  --mem 1536 --smp 2 --cpu host --vga std --fps 60
# then customize qemu-streamhost.sh: ide overlay drive, e1000 hostfwd, conditional -loadvm golden
bash /data/vms/streamhost/tiles/<M>/qemu-streamhost.sh    # launch QEMU
systemctl start streamhost@<M>                            # attach daemon
```

For C64, use `--pointer rel` and the tablet-free/`vmport=off` exception above.

### 3f. Verify (acceptance gate — real framebuffer, no disk/log inference)
- QMP `screendump` → PPM → PNG → **look at it**: the machine's actual desktop, not
  a boot screen / black frame.
- Prove audio non-silent: run the emulator briefly with a wav sink
  (VICE: `-sounddev wav -soundarg /tmp/x.wav`) and measure the wav RMS/peak on the
  box; assert above a silence floor.

---

## 4. Files of the reference C64 tile
- `scripts/build-guests/lib/bridge-base.sh` — builds the shared base (this doc §1).
- `scripts/build-guests/tiles/c64.sh` — overlay + kiosk `launch.sh` + golden + verify.
- `docs/guests/c64.md` — the C64-specific findings + live status.
- `/data/vms/streamhost/tiles/c64/` — `overlay.qcow2`, `qemu-streamhost.sh`,
  `tile.env`, `qmp.sock`, `qemu.pid`.

---

## 5. Capture-path reality on bridge tiles: copy path, not shm (2026-07-12)

All bridge kiosks run 32bpp KMS (bochs-drm), so QEMU's `-vga std` scanout
surface is **guest-VRAM-backed** and not memfd-shareable → QEMU silently uses
the v1 **copy path** (full ~1024x768 frames at ~30 Hz ≈ 60-110 MB/s of `Update`
method calls) even though streamhost advertises `Unix.Map`. Two consequences,
both root-caused and fixed in `capture.rs` (branch `shm-attach-fix`):

- **First attach to a daemon-less QEMU** replays a stale pre-guest-init 640x480
  placeholder `ScanoutMap` (a console with no listener never refreshes its
  surface). streamhost now invalidates that map on the first v1 `Scanout`
  ("copy path authoritative") instead of encoding dead pixels forever.
- **QEMU's copy path has no flow control**: if the listener drains slower than
  production, the GDBusWorker output queue grows unboundedly in QEMU anon heap
  until the guest's cgroup cap OOM-kills it (fast at first attach, slow under
  sustained interaction — both observed). streamhost's v1 handlers now use the
  zvariant borrowed-bytes fast path (drains >110 MB/s at ~5% of one core), and
  a guest-RSS guard (`SH_QEMU_RSS_GUARD_MB`, default 2048) recycles the
  listener connection — QEMU frees its entire queued backlog on disconnect —
  as a hard bound for any future producer>consumer regression.

Future option (per-OS phase): run the kiosk X server at 16bpp — QEMU then
allocates a memfd-shareable conversion surface and the tiles get true shm
(`UpdateMap`) capture with near-zero socket traffic.
