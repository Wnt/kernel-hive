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
dbus audiodev, `-usb -device usb-tablet` plus the pc machine's PS/2, `e1000`
user-mode net. Screen is 1024x768 (X.org 7.3's vesa driver on the Bochs VGA
device `-vga std` exposes).

## Accounts

`root` / `kernelhive`; user `visitor` / `kernelhive`, KDM autologin
(credentialsRef `guest/pcbsd`).

## Input

`usb-tablet` abs is the ledger's bet for the pointer transport — the golden
stream measures whether FreeBSD 6.3's `ums` + `moused` track it 1:1, and
corrects `stream.pointer` / `SH_POINTER` to `rel` if it must fall back.

## Reset

`loadvm golden` on `disk.qcow2` — the disk is the only block device, so the
checkpoint travels with it.

## Checkpoint

<!-- filled by the coordinator from the golden stream's report -->
