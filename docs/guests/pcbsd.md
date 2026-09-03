# pcbsd guest — PC-BSD 1.5.1 "Edison"

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-03 in a parallel
wave ([`lab/PCBSD-WAVE.md`](../lab/PCBSD-WAVE.md)). The media is sourced,
hashed and staged; the disk is composed by an assisted (GUI) install; the
golden and its bake are the golden stream's to prove and record below.

## What it is

PC-BSD 1.5.1 "Edison" (23 April 2008) was the last PC-BSD release before
iXsystems took over the project for the 7.x "Fibonacci" line (September
2008) — desktop FreeBSD, aimed at users who wanted BSD's stability without a
command-line install. It layers KDE 3.5.8 and a graphical installer on top of
**FreeBSD 6.3-RELEASE**, running X.org 7.3 on i386.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `pcbsd`
- Display name: **PC-BSD 1.5.1 "Edison"**
- Reserved slot / UDP port / VMID label: `179` / `54179` / `179`
- Upstream: archive.org item `pcbsd-1.5.1-x-86-cd-1`, file
  `PCBSD1.5.1-x86-CD1.iso`, **688930816 bytes**, SHA-256
  `69aa17171e0afe45735c3bb16a398319fa82b3f30a3e1aa3a5d6f25ac4bee0a3`
  (recorded in `/data/assets-staging/pcbsd/MANIFEST.sha256`, labhost path).
  CD1 alone installs the base system plus KDE; CD2 was optional PBIs and was
  not fetched.

### Media and build

| property | value |
|---|---|
| `PCBSD1.5.1-x86-CD1.iso` | 688930816 bytes, sha256 above |
| Builder | `scripts/build-guests/tiles/pcbsd.sh` — fetches CD1 from archive.org,
  verifies the sha256, stages `pcbsd.iso`, creates an empty `pcbsd.qcow2`
  (8G) and prints the assisted-install instructions. `automation: assisted`
  — the install itself is a GUI wizard and is not scripted. |
| Builder output | `/data/gallery-guests/PCBSD/pcbsd.iso` (pinned CD1) +
  `pcbsd.qcow2` (installed, pristine, no golden yet) |
| Runtime path | `/data/vms/streamhost/stations/pcbsd/disk.qcow2` — the ONLY
  block device at runtime; no cdrom is attached once installed |

## Device set

`pc-i440fx-11.0`, KVM, `-cpu host`, 1024 MB RAM, 1 vCPU, `-vga std`, IDE disk
at index 0 (install: IDE cdrom too, removed after install), AC97 audio on a
dbus audiodev, the pc machine's PS/2 mouse and keyboard, and an `e1000` SLIRP NIC
whose only job is the loopback forward `127.0.0.1:6079 -> 10.0.2.15:6000` for the
x11warp pointer. No USB (a usb-tablet was tried during install and is inert in
FreeBSD 6.3 X). Screen is 1024x768 (X.org 7.3's vesa driver on the Bochs VGA
device `-vga std` exposes).

## Accounts

`root` / `kernelhive`; user `visitor` / `kernelhive`, KDM autologin
(credentialsRef `guest/pcbsd`).

## Input

Pointer MOTION is **absolute through the guest's own X server** (`x11warp`,
phase 2 of the wave): the daemon connects to `SH_X11WARP_DISPLAY=127.0.0.1:79`,
which the launcher forwards to the guest's X on `10.0.2.15:6000`, and moves the
pointer with `XWarpPointer` + `XQueryPointer` readback. For that the golden
carries `xhost +10.0.2.2` (never `xhost +`), KDM starts X without
`-nolisten tcp` (`kdmrc` `[X-:*-Core] ServerArgsLocal=`), and — the PC-BSD-specific
trap — `/etc/pf.conf` carries `pass in quick on em0 proto tcp from 10.0.2.2 to any
port 6000`, because PC-BSD ships pf enabled and it resets inbound :6000 otherwise. Buttons and keys ride the PS/2 path over D-Bus. Nothing else may
move this pointer (single injector), and the sink sends no relative motion, so
drags are warp sequences (see `docs/lab/INPUT-DEBUGGING.md`). History: phase 1
shipped relative PS/2 because a usb-tablet never moves the X pointer on FreeBSD
6.3 (PS/2 moves land with X acceleration, ≈3.5 px per unit under KDE). Konsole is
the focused keyboard surface at golden.

## Reset

`loadvm golden` on `disk.qcow2` — the disk is the only block device, so the
checkpoint travels with it.

## Checkpoint

Re-baked 2026-09-03 (phase 2, x11warp) on a sandbox clone with the station
launcher's device set (no cdrom, e1000 SLIRP NIC with the :6079 forward):
`savevm golden` on `disk.qcow2` — VM_SIZE **296 MiB**, VM_CLOCK 0:12:55; one
`loadvm golden` restore proven pixel-identical, and the X TCP display still answers
`XQueryPointer` = (450,680) after the restore. (Phase 1 golden, relative PS/2, no
NIC: 388 MiB.)
Fixture: KDE 3.5.8 desktop, user `visitor` autologged in via KDM
(`AutoLoginEnable=true` in `/usr/local/share/config/kdm/kdmrc`), **Konsole focused
with an empty `%` prompt** (keyboard surface, window at 176..846 x 108..608),
pointer parked at (450,680) on clear desktop, KTip and Konsole tips off,
`~/.kde/Autostart/noblank.sh` runs `xset s off -dpms`, `kdesktoprc` ScreenSaver
disabled. Power-on to first desktop: ~5 min including the one-time Display
Settings wizard (vesa 1024x768x24 autodetected; its "Apply" test fails, "Skip"
keeps the working default). Pointer: **relative PS/2 only** — a usb-tablet was tried and FreeBSD 6.3's X
never moves on it, so it is not in the device set; X acceleration
makes 1 unit ≈ 3.5 px under KDE (≈2 px in the installer). Timezone was left at the
installer default (America/Los_Angeles); NTP and usage statistics unchecked.
