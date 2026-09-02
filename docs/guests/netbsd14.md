# netbsd14 guest — NetBSD 1.4.1 i386, XFree86 3.3 desktop

Status: **integrated 2026-09-02** in a parallel wave
([`lab/NETBSD14-WAVE.md`](../lab/NETBSD14-WAVE.md)). The media is sourced,
hashed and staged; the install and golden bake are the golden stream's to
prove and record below.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `netbsd14`
- Archetype: `beige-ibm-pc`
- Release: NetBSD 1.4.1 i386, released 1999-08-26 — custom `KHMIN` kernel
  (GENERIC minus the ISA devices the emulated PC lacks; GENERIC hangs in
  autoconf after `lpt0` on QEMU and 1.4.1 has no userconf), wscons console
  (`wsdisplay0 at vga1`), XFree86 3.3.3.1 (`XF86_SVGA` on the Cirrus GD5446,
  1024x768, depth 8, `Option "no_bitblt"`).
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
`fdc0`; sysinst main menu appears ~25 s after power-on. The INSTALL kernel is
pccons; the installed kernels are wscons. The PS/2 mouse is `opms0 at pckbc0`
(`/dev/pms0`, XFree86 protocol `PS/2`) — the serial-mouse fallback was never
needed. After sysinst the kernel and the X setup are applied from the INSTALL
floppy's ramdisk shell (mount `wd0a` AND `wd0e`, chroot, `build-kernel.sh
KHMIN`, `apply-x.sh` — [`../../scripts/build-guests/tiles/netbsd14/README.md`](../../scripts/build-guests/tiles/netbsd14/README.md)).
Under `KHMIN` the PCI NE2000 is `ne0`, not GENERIC's `ne2`, so both
`/etc/ifconfig.ne0` and `/etc/ifconfig.ne2` are written; `/etc/nsswitch.conf`
is `hosts: files` and `/etc/resolv.conf` names SLIRP's `10.0.2.3`, because the
X server resolves every TCP client and a resolver timeout stalls the handshake.

Guest network is static: `10.0.2.15/24`, gateway `10.0.2.2`, and
`/etc/hosts` names `10.0.2.2 slirphost`.

Session start: `/etc/rc.local` runs `/etc/kh-xsession` under `xinit` —
`xhost +10.0.2.2`, an xterm over the origin, xclock, xcalc, and a window
manager — **twm** (the 1.4.1 X sets ship no ctwm).

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

`golden` in `disk.qcow2` (the only block device), baked 2026-09-03 02:54:27
with the station launcher under `/opt/qemu-beos`: VM_SIZE 38.6 MiB, VM_CLOCK
0000:01:01.205. Cold boot to the settled desktop: 49 s. Restore proven the same
minute: `loadvm golden -S` + `cont` shows the desktop after 3.2 s and the X
connection-setup handshake on `127.0.0.1:6076` answers `1` in 0.5 s
(`x11warp-bootstrap.log`: `x11warp ok: the golden carries the X access state`).
The ready scene: SteelBlue root, xterm `NetBSD 1.4.1` 80x28 at the origin with
a root prompt, Calculator at (640,80), xclock top-right, X cursor parked at
the screen centre (512,384) — outside the xterm, so the daemon's first warp to
the origin is what gives the xterm the keyboard.

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
- **Custom kernel.** `/netbsd` is `KHMIN`; a GENERIC kernel on this disk hangs
  after `lpt0`. The ruled-out causes and the race that found the route are in
  [`../lab/NETBSD14-WAVE.md`](../lab/NETBSD14-WAVE.md).
- **Relative pointer motion is unusable** (the guest's `opms` Y axis pins the
  pointer to the bottom edge under QEMU relative packets) — irrelevant to the
  station, whose motion is `x11warp`, but do not debug with `qmp-type --mouse`.
- **Network** is SLIRP-only; no retronet tap on this station.
