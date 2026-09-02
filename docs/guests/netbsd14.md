# netbsd14 guest — NetBSD 1.4.1 i386, XFree86 3.3 desktop

Status: **integrated 2026-09-02** in a parallel wave
([`lab/NETBSD14-WAVE.md`](../lab/NETBSD14-WAVE.md)). The media is sourced,
hashed and staged; the install and golden bake are the golden stream's to
prove and record below.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `netbsd14`
- Archetype: `beige-ibm-pc`
- Release: NetBSD 1.4.1 i386, released 1999-08-26 — GENERIC kernel,
  `pccons` console (not wscons), XFree86 3.3.3.1 (`XF86_SVGA` on Cirrus).
- Reserved slot / UDP port / VMID: `176` / `54176` / `176`
- Upstream: `archive.netbsd.org/pub/NetBSD-archive/NetBSD-1.4.1/i386/` —
  `installation/floppy/boot.fs` (1 474 560 B) + 13 binary sets under
  `binary/sets/` (`base comp etc games kern man misc text xbase xcomp
  xcontrib xfont xserver`, 62 106 331 B total), all MD5-verified against the
  archive.
- License class: **free/open**, BSD-family license.
- No login prompt on the ready scene; no credentials to carry.

### Media

| property | value |
|---|---|
| Boot floppy | `boot.fs`, 1 474 560 B |
| Binary sets | 13 sets, 62 106 331 B total, MD5-verified against the archive |
| Install CD | `sets.iso`, composed with `genisoimage -R -J`, tree
  `i386/binary/sets/`, attached as the IDE CD-ROM (device `cd0`, sysinst
  dir `/i386/binary/sets`) |
| Staged at | `/data/assets-staging/netbsd14/`, `MANIFEST.sha256` |

## Install log

Installed via `sysinst` from the `boot.fs` floppy, sets supplied on `cd0`
from `sets.iso`. Measured on the smoke boot (framebuffer, 720x400 text):
kernel probes `wd0` (IDE), `cd0`, `ne2` (RTL8029), `pc0` (pccons), `com0`,
`fdc0`; sysinst main menu appears ~25 s after power-on. No `pms0` line was
seen on the INSTALL kernel — whether the PS/2 mouse is present on GENERIC is
for the golden stream to confirm; fallback is a `-chardev msmouse` serial
mouse on `com0` with XFree86 protocol `Microsoft`.

Guest network is static: `10.0.2.15/24`, gateway `10.0.2.2`, and
`/etc/hosts` names `10.0.2.2 slirphost`.

Session start: `/etc/rc.local` runs `/etc/kh-xsession` under `xinit` —
`xhost +10.0.2.2`, an xterm over the origin, xclock, xcalc, and a window
manager. <!-- TODO(golden): wm --> (ctwm if present, twm otherwise).

## Device set

- QEMU: `/opt/qemu-beos/bin/qemu-system-x86_64`, machine
  `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 128 MB RAM, 1 vCPU,
  `-vga cirrus`.
- Storage: one IDE `qcow2` (`disk.qcow2`) — the only block device, and it
  carries the golden vmstate.
- NIC: `ne2k_pci` on SLIRP, with a host loopback forward `6076 →
  10.0.2.15:6000` for the X pointer route (below).
- No audio device.
- **No exec channel.** `operator.labctl.exec_kind` is `null`: drive the
  station with `labctl key`/`type`/`shot` and read the framebuffer.

## The pointer is absolute, through the guest's X server

Like `sunos414`, this guest has no absolute input device and XFree86 draws
no hardware cursor, so the museum reaches into the guest's own X server
instead of a device:

- **Actuator**: `XWarpPointer` moves the pointer to an absolute root
  coordinate; XFree86 repaints immediately.
- **Sensor**: `XQueryPointer` reads back the guest's own idea of where the
  pointer is — a measurement, not an assertion, which is what earns
  `absolute: true`.

`SH_INPUT_BACKEND=x11warp`, `SH_X11WARP_DISPLAY=127.0.0.1:76`, reaching the
guest's X server over the loopback forward `127.0.0.1:6076 →
10.0.2.15:6000`. Buttons and keys ride the daemon's normal D-Bus PS/2 path;
only pointer motion takes the X route. The golden carries the `xhost +
10.0.2.2` grant baked into `kh-xsession`, and the launcher runs an X
handshake CHECK on start (`x11warp-bootstrap.log`: `ok`, or `STALE GOLDEN`
if the grant or the display is gone — recapture with `checkpoint-guard
recapture netbsd14`, see below).

## Checkpoint

<!-- TODO(golden): VM_SIZE, VM_CLOCK, bake date, restore proof -->

## Operating

- Drive the station with `labctl key <tile>`, `labctl type <tile> "text"`,
  and `labctl shot <tile>` — there is no exec channel.
- Reset: `loadvm golden` (via the station launcher, not hand-rolled QMP).
- Recapture the golden only through
  `ssh lab 'checkpoint-guard recapture netbsd14'` — never hand-roll a
  `savevm` (see [`../lab/checkpoint-guard.md`](../lab/checkpoint-guard.md)).
  Any launcher or `kh-xsession` change (window manager, `xhost` grant,
  geometry) needs a recapture before it reaches the ready scene.

## Known limits

- **No exec channel.** Everything is QMP keys/mouse plus the framebuffer,
  same as several of the fleet's other small stations.
- **PS/2 mouse presence unconfirmed on GENERIC** — the INSTALL kernel log
  showed no `pms0` line; the golden stream verifies this and the serial
  `msmouse` fallback is documented above in case it is absent. This does not
  affect the pointer route above, which never touches PS/2 motion.
- **Window manager not yet confirmed** — see the `<!-- TODO(golden): wm -->`
  marker in the install log above.
- **Network** is SLIRP-only; no retronet tap on this station.
