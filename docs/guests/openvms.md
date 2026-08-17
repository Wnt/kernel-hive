# OpenVMS x86-64 9.2 DECwindows

Status: DECwindows production recipe. Public ID `openvms`, slot 84, UDP
54084, binding order 37, bring-up order 33.

## Media and provenance

The OpenVMS guest is VSI OpenVMS x86-64 V9.2-3 from the 2026 Community
Package. The source archive is private lab media and is never committed or
served:

- `/data/gallery-guests/OpenVMS/community_2026.zip`
- SHA-256
  `ceae51ded68e96861e7211b30ef837e8d101eb5d3a3ddb78c13d5d7619ddfb83`
- builder: `scripts/build-guests/tiles/openvms.sh`
- output: `openvms-community.qcow2` plus snapshot-capable
  `OVMF_VARS.qcow2`

Credentials are referenced only as `guest/openvms`; their values do not belong
in Git, screenshots, serial logs, or build output.

The X server guest is an overlay on the pinned Debian bridge seed:

```sh
scripts/build-guests/lib/bridge-base.sh
scripts/build-guests/stages/openvms-decwindows-bridge.sh
```

The second builder installs only Xorg/Xinit and X11 utilities, installs the
tracked `bridge-launch.sh` and `bridge-xserverrc`, proves that TCP X11 listens,
and emits
`/data/gallery-guests/OpenVMS/openvms-decwindows-bridge.qcow2`. The backing
file `/data/vms/bridge/bridge-base.qcow2` remains frozen. The OpenVMS builder
invokes this bridge builder as its final stage, so the normal `build-all.sh`
OpenVMS row produces the complete three-disk station.

## Two-VM display architecture

One station is intentionally two independent QEMU processes:

1. The captured bridge is Debian, 768 MiB, one vCPU, standard VGA, QEMU D-Bus
   display, E1000, and `usb-tablet`. Its root client only disables blanking,
   paints a background, and sleeps. It runs no Linux window manager or display
   manager.
2. OpenVMS is the X client, using the proven vendor device set: q35, KVM,
   8 GiB, two vCPUs, OVMF, ICH9/AHCI DKA0, E1000, and COM1. Its VGA device is
   not captured.

The bridge starts Xorg as:

```sh
/usr/lib/xorg/Xorg -listen tcp -ac
```

QEMU exposes bridge TCP 6000 only as
`tcp:127.0.0.1:6610-:6000`. OpenVMS has a separate SLIRP network and reaches
the host loopback listener at `10.0.2.2:6610`. There is no tap, socket LAN, or
relay. `-ac` is safe only behind this host-loopback NAT boundary and must never
be exposed on a public address.

Streamhost captures the bridge's 1024x768 D-Bus scanout. Keyboard and
absolute coordinates enter that QEMU; the bridge's USB tablet gives identity
mapping with scale 1 and zero offsets.

## DECwindows fixture and pre-connect capture

`streamhost/stations/openvms/DECW_FIXTURE.COM` is copied into the OpenVMS system
disk during the clone-only capture. It creates display 610:

```text
SET DISPLAY/CREATE/NODE=10.0.2.2/TRANSPORT=TCPIP/SERVER=610/SCREEN=0
```

X11 adds 6000 to the server number, producing destination port 6610. The
procedure launches OpenVMS's `DECW$MWM`, `VUE$MASTER`, Calculator, Clock, and
a positioned DECterm. VUE supplies the visible FileView desktop.

The proven 2026 image contains the byte-identical procedure under its original
lab name, `LEANX_FIXTURE.COM`; `DECW_FIXTURE.COM` is the stable repository and
future-capture name.

The snapshot `leanx-preconnect` must be taken while:

- OpenVMS is booted and logged in;
- DECwindows base services are available;
- the tracked command procedure exists and is executing its initial `WAIT`;
- `SET DISPLAY` has not run and no live X socket exists.

A reproducible capture uses copies of both OpenVMS qcow2 files in a guarded
`/data/vms/sandbox/openvms-<unique>/` namespace:

1. Boot the exact OpenVMS device set from its existing logged-in checkpoint.
2. Create `SYS$LOGIN:DECW_FIXTURE.COM` from the tracked file without printing
   credentials or command history into host logs.
3. Start it in the foreground and pause in its initial wait.
4. Save `leanx-preconnect` across the system disk and writable OVMF varstore.
5. Fully stop that clone and verify the snapshot with a fresh QEMU process,
   never a warm `loadvm`.

Both qcow2 files are required because VMState spans the system disk and OVMF
varstore. The production launcher refuses to start if `leanx-preconnect` is
absent.

## Launch and reset

`streamhost/stations/openvms/qemu-streamhost.sh` is the production dual-VM
launcher. A pidfile-owned supervisor starts the bridge, gates on the private
X11 listener, restores a fresh OpenVMS QEMU from `leanx-preconnect`, and owns
both child QEMUs. Terminating the recorded supervisor reaps both children.
The captured bridge QMP socket remains the conventional station path
`qmp.sock`; OpenVMS control uses `openvms-qmp.sock`.

Warm `loadvm` is unusable after the desktop has connected: it restores dead
X sockets and stale SLIRP state. The only supported visitor reset is:

```sh
systemctl restart streamhost@openvms
```

`SH_RESET_MODE=restart` is emitted into `station.env`. `labctl gen` records that
observed mode and `labctl reset openvms` maps it to the same cold service
restart. The restart creates a fresh bridge Xorg process, a fresh OpenVMS
SLIRP process, restores the pre-connect snapshot, and replays every fixture
connection.

## Acceptance and rollback

Promotion is gated in a unique production-mirror clone before any live file is
changed. Framebuffer acceptance requires:

- DECterm at a DCL `$` prompt plus Clock, Calculator, and FileView;
- keyboard echo visible in DECterm;
- cursor-local changes at 20%, 50%, and 80% of both axes;
- a dirty marker removed by a cold restart, with all apps remapped;
- a browser-decoded UI frame matching the captured bridge QMP frame.

Save PPM and PNG evidence beneath the clone's `evidence/` directory. After a
green clone, back up the whole live station directory and
`registry/stations/openvms.json` to a timestamped rollback directory before
installing the three qcow2 artifacts and generated runtime files.

If any live framebuffer, keyboard, pointer, or reset check fails, stop only
`streamhost@openvms`, restore that backup, regenerate the registry and labctl
matrix, and restart the old service. No other station shares the disks, sockets,
ports, or processes.
