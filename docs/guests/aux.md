# aux — A/UX 3.0.1 (Quadra 800, m68k)

**Status:** INSTALL PHASE, dark-launched (`listing.state=hidden`), streaming at
`/os/aux` on udp/54145. Same emulated machine and binary as
[`macos753`](macos753.md): `qemu-system-m68k -M q800` from `/opt/qemu-m68k`
(kernel-hive fork, 11.0.2), TCG only, dbus display at 1152x870x8, ADB
relative pointer. Read that doc first — everything about the machine, the
qcow2 PRAM, the mandatory audiodev and `savevm` on q800 is proven there and
not repeated here.

The exhibit slot: Apple's own System V Unix with the Macintosh Finder as its
shell — the one station where a proprietary GUI and a real Unix share a
desktop. Candidate note: [`research/candidate-aux.md`](../lab/research/candidate-aux.md).

## Media (agent-sourced, never committed)

| Artifact | Source | md5 |
|---|---|---|
| `AUX_3.0.1_Install.iso` (426 MB) | archive.org `apple-aux-3.0.1` (same bits as `aux-3.0.1-install`, and as Macintosh Garden's `AUX_3.0.1_Install.toast_image`) | `dd3edefa2095821878a8b6dee7dc7940` |
| `Bootdisk.img` (1.4 MB, DiskCopy 4.2 "Installation Boot Disk") | archive.org `apple-aux-3.0.1` | `34338bb68a25700fbdc21d25a99c6a51` |
| `AUX_3.1_Update.iso` (19 MB) | archive.org `apple-aux-3.1-update` | `f7723b5613a80f3806f500cc23512a0a` |
| `800.ROM` (Quadra 800) | shared with macos753, `/data/vms/streamhost/assets/macos753/800.ROM` | sha256 `05ad753f…6b09ca` |

3.1.1 — the last release and the version the VOM reference runs — is not
archived on any reachable hub (archive.org, Macintosh Garden, Macintosh
Repository all stop at 3.0.1 + the 3.1 updater); the target is therefore
**3.0.1, then the 3.1 update**.

## Install recipe (what has been proven so far)

**The CD is not ROM-bootable, and the floppy is not usable.** The ISO's HFS
volume (`A/UX CDInstall`, blocks 96–41055) has its boot-block header zeroed
(signature `0000`, no entry branch, no version) and block 0's Driver
Descriptor Map lists **zero drivers**, so the Quadra ROM never loads a driver
from it and shows the blinking floppy. Patching the boot-block header (`LK`,
`bra +0x86`, `0x4418`) and adding a DDM entry for the `Apple_Driver`
partition at block 64 did **not** help — that partition entry carries no
`pmBootAddr`/`pmBootEntry`/checksum, so the ROM rejects the driver. On real
hardware the answer was the Installation Boot Disk; under QEMU the q800
`swim-drive` exists but the ROM does not boot from it (still the blinking
floppy with the raw 1440K image attached).

**What works: a helper Mac OS disk.** A copy of macos753's System 7.5.3 disk
(`qemu-img convert -U` — the live station holds a write lock, so a backing
file is refused) at SCSI 5, PRAM boot device 5, target disk at SCSI 6, CD at
SCSI 3. Mac OS mounts the CD's HFS partition in the Finder; it contains
`A/UX Startup`, `Apple HD SC Setup` (v3.0.1 A/UX), `bin/`, `System Folder`,
`MacInstallFiles`.

Steps, all driven through QMP with `adb_pointer.py` (select icon by clicking
its **label**, then Cmd-O; a click on the icon art often does not select):

1. `Apple HD SC Setup` → `Next` to SCSI Device 6 → `Initialize` → `Init` →
   volume name `MacPartition` (the A/UX convention). On a **128 MB** image the
   verify+init took ~4 min. Quit **restarts the machine**.
2. Host-side: grow the qcow2 to 1000 MB and extend the Apple Partition Map
   (`sbBlkCount`, the `Apple_Free` entry) so HD SC Setup's *Partition…* sees the
   room — the same trick as macos753, applied **before** the A/UX partitioning
   so HD SC Setup itself writes the A/UX slices (their block-zero-blocks are
   not something to hand-craft).
3. `Partition…` → A/UX layout (root&usr, swap, MacPartition), then
   `A/UX Startup` from the CD to boot the installer kernel from the CD's
   `UNIX Root&Usr slice 0` and install.

Steps 2–3 are in progress; see the install log below.

## Install log

- 2026-08-18 ~09:00Z: rig up, `/os/aux` streaming (overlay). Blinking floppy
  from CD; boot-block/DDM patches and floppy attempts fail (above).
- ~09:20Z: helper System 7.5.3 disk boots; CD mounts; HD SC Setup initialises
  SCSI 6 (128 MB) as `MacPartition`.

## Device set (station launcher, `streamhost/stations/aux/qemu-streamhost.sh`)

Identical to macos753's, plus `-serial unix:$D/serial.sock` (A/UX can run a
getty on the modem port — the future `labctl exec` channel) and, **install
phase only**, the helper disk at SCSI 5 and the CD at SCSI 3. The checkpoint
will be baked without helper and CD.

## Pointer / keyboard

`dbus-rel`, scale 1.0 **unmeasured**. Mac OS "Very Slow" tracking is 0.36
px/unit on the same hardware; A/UX's Finder and X11 apply their own factors —
measure with `adb_pointer.py gain` on the installed desktop before listing.

## Blockers / open

- Partition growth trick unproven for A/UX slices (step 2).
- Whether `A/UX Startup` runs from System 7.5.3 (32-bit addressing is ON in
  the helper) — the real path booted a 7.0.1-based floppy.
- Save-state on q800 is proven (macos753); whether A/UX's kernel survives
  `loadvm` (timer/SCSI state) is not.

## Rollback

Additive: new stationDir, new slot 145, no shared files. Withdraw the
overlay with `darklaunch-station.py withdraw aux`; disable the row and
regenerate.
