# aux — A/UX 3.0.1 (Quadra 800, m68k)

**Status:** INSTALLED and LISTED 2026-08-18 — A/UX 3.0.1 boots from its own disk
to the Finder as root; `golden` checkpoint baked (loadvm proven framebuffer-
identical); station on udp/54145. Same emulated machine and binary as
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

## Install recipe (proven so far — 2026-08-18)

**The CD is not ROM-bootable, and the floppy is not usable.** The ISO's HFS
volume (`A/UX CDInstall`, blocks 96–41055) has its boot-block header zeroed
(signature `0000`, no entry branch, no version) and block 0's Driver
Descriptor Map lists **zero drivers**, so the Quadra ROM never loads a driver
from it and shows the blinking floppy. Patching the boot-block header (`LK`,
`bra +0x86`, `0x4418`) and adding a DDM entry for the `Apple_Driver`
partition at block 64 did **not** help (the entry has no
`pmBootAddr`/`pmBootEntry`/checksum; note the A/UX HD SC Setup itself writes
DDM `(64, 11, 1)` for the same driver — untested with 11). On real hardware
the answer was the Installation Boot Disk; under QEMU the q800 `swim-drive`
exists but the ROM does not boot from it (still the blinking floppy with the
raw 1440K image attached). The floppy's contents (`strings`) show it is just
an "A/UX Installer Startup" — A/UX Startup with an `installer#` prompt and
the CD's `bin:` in its path — so nothing on it is needed once A/UX Startup
runs from elsewhere.

**Two more traps, both cost an hour:**

- **`A/UX Startup` will not run under System 7.5.3** ("Standalone program
  space is too small (=5546420) … the system heap is too big"). It needs the
  minimal System that ships on the CD's HFS volume — so the helper only serves
  to partition the disk and copy that System Folder + `A/UX Startup` onto
  `MacPartition`; the machine then boots from `MacPartition` (SCSI 0).
- **A/UX Startup's standalone SCSI reader hangs on a `scsi-cd`, and on a
  read-only `scsi-hd`.** `ls (3,0,0)/` and `launch` both hang forever (no
  I/O, 110 % CPU) with the ISO as `-device scsi-cd` or as
  `scsi-hd,…,read-only=on`; the SCSI 0 disk reads fine. Presenting the ISO as
  a **writable `scsi-hd` through a qcow2 overlay**
  (`qemu-img create -f qcow2 -b AUX_3.0.1_Install.iso -F raw cd-overlay.qcow2`)
  makes `ls (3,0,0)/` list the CD's Unix root instantly. Recreate the overlay
  after any unclean kill — the CD root is UFS and fsck otherwise asks
  `SALVAGE?` for every cylinder group.

**What works** (helper System 7.5.3 disk = `qemu-img convert -U` copy of
macos753's golden disk — the live station holds a write lock, so a backing
file is refused; at SCSI 5, PRAM boot device 5; A/UX target at **SCSI 0**;
CD overlay at SCSI 3). Driven through QMP with `adb_pointer.py` — click the
icon **label** then Cmd-O (clicks on icon art often do not select), and
**move the mouse before clicking after typing**: Mac OS hides the cursor
while you type and the closed-loop tracker then aims blind.

1. Helper Finder: open the CD, `Apple HD SC Setup` (v3.0.1 A/UX) → `Next` to
   SCSI Device 0 → `Initialize` → `Init` → name `MacPartition`. Do this on a
   **128 MB** image (~4 min incl. the surface verify); Quit restarts the Mac.
2. Host-side: grow the qcow2 to 1000 MB and extend the Apple Partition Map
   (`sbBlkCount`, the `Apple_Free` entry's block count + data count) so
   HD SC Setup's *Partition…* sees the room — the macos753 trick, applied
   **before** the A/UX partitioning so HD SC Setup itself writes the A/UX
   slices and their block-zero-blocks.
3. `Partition…` → *Custom* → click the gray area → `UNIX Root&Usr slice 0`,
   900000 K → OK → *Continue* on the "file system will not be created under
   Mac OS" warning → click the remaining gray → `UNIX Swap slice 1`, the rest
   (~104469.5 K). Done. Quit.
4. In the CD window Cmd-A, drag everything into the `MacPartition` window
   (218 items, ~1 min). Special → Shut Down (QEMU exits). Relaunch booting
   SCSI 0: the CD's minimal System comes up (the startup-item alias to the CD
   fails harmlessly — this System has no CD-ROM extension).
5. Open `A/UX Startup` on MacPartition → `startup#`. `launch -v (3,0,0)/unix`
   says "Board id 54 not found in slot 9 … does not match the boards present";
   **`launch -v (3,0,0)/newunix`** (autoconfig kernel) boots A/UX 3.0.1 from
   the CD's root slice straight to the A/UX Finder (root, no login).
6. `/mac/bin/CommandShell` → `localhost.root #`. The CD's **slice 6**
   ("Free UNIX slice 6", `c3d0s6`, 145 MB) is the **pristine A/UX 3.0.1
   root+usr** (RELEASE_ID 3.0.1, `ARCHIVES/` of optional packages, `syschk`),
   its `/etc/fstab` naming `/dev/dsk/c0d0s0`. There is no separate installer
   program on this CD; the install is a copy:
   `newfs -v /dev/rdsk/c0d0s0 other` (device type from `/etc/disktab`;
   921.6 MB UFS), `mount /dev/dsk/c3d0s6 /mnt; mkdir /mnt2; mount
   /dev/dsk/c0d0s0 /mnt2; cd /mnt; find . -print | cpio -pdmu /mnt2`.
7. `sync; umount` both, kill QEMU (a guest `reboot`/Restart HANGS the q800 —
   known from macos753; kill and relaunch instead). Boot SCSI 0: the copied
   root's `/mac/sys/Startup System Folder` + `A/UX Startup` are on
   MacPartition and **auto-launch**; A/UX's own first-boot **Easy Install**
   ("The system files on MacPartition will be overwritten…" → OK) writes the
   Startup files, the desktop pattern, Core A/UX docs, then "installation
   completed" → the Easy Install dialog. *Choose Software…* lists MacX / X11
   Server / X clients / Games / QuickTime / networking / man pages etc. but
   its `Install` button is DISABLED: the Installer reads "Available free
   space: Zero K" on this 900 MB UFS (some 16-bit statfs assumption), so the
   optional packages are NOT installed yet (`/ARCHIVES/*` are on the disk —
   install from the shell later). Quit → Restart hangs QEMU → kill/relaunch.
8. Next boot: autoconfig "kernel has been automatically reconfigured …
   Reboot" (it relaunches in place, no hardware reset) → A/UX Finder as root.
   Standalone boot (disk only, no CD/helper) reaches the Finder in ~2.5 min.
9. Scene + `savevm golden` (vmstate lands in the PRAM qcow2, like macos753);
   dirty → `loadvm golden` → identical framebuffer md5. `shutdown -y -g0 -i0`
   loops on "callrpc: Port mapper failure" (no network) — sync and kill
   instead; the Startup's autorecovery fsck cleans the root on the next boot.

## Install log

- 2026-08-18 ~09:00Z: rig up, `/os/aux` streaming (overlay). Blinking floppy
  from CD; boot-block/DDM patches and floppy attempts fail (above).
- ~09:20Z: helper System 7.5.3 disk boots; CD mounts; HD SC Setup initialises
  the target (128 MB) as `MacPartition`; grown to 1000 MB host-side; A/UX
  slices laid out (root&usr 900000 K, swap the rest).
- ~09:50Z: A/UX Startup refuses under 7.5.3; CD System + Startup copied to
  MacPartition; boot from it; `launch` hangs (scsi-cd) — 40 min lost.
- ~10:35Z: writable overlay fixes it; `launch -v (3,0,0)/newunix` boots A/UX
  3.0.1 to the Finder; kernel console on camera. Disk moved to SCSI 0.
- ~11:10Z: `newfs` root; cpio of slice 6 (5 min guest time).
- ~11:40Z: first boot from disk → Easy Install finishes MacPartition; kernel
  autoconfig; A/UX Finder from disk. ~13:05Z: golden baked, loadvm proven,
  station files installed, listed.

## Device set (station launcher, `streamhost/stations/aux/qemu-streamhost.sh`)

macos753's device set with the A/UX disk at **SCSI 0** (`c0d0s0` root, `c0d0s1`
swap, MacPartition boot), plus `-serial unix:$D/serial.sock` (A/UX can run a
getty on the modem port — the future `labctl exec` channel) and, **install
phase only**, the helper disk at SCSI 5 and the CD as a writable `scsi-hd`
overlay at SCSI 3. The checkpoint will be baked without helper and CD.

## Pointer / keyboard

`dbus-rel`, scale 1.0 **unmeasured**. Mac OS "Very Slow" tracking is 0.36
px/unit on the same hardware; A/UX's Finder and X11 apply their own factors —
measure with `adb_pointer.py gain` on the installed desktop before listing.

## Open

- Optional packages (X11 Server, MacX, X clients, Games, QuickTime, man
  pages, networking): on disk under `/ARCHIVES`, not installed — the Easy
  Install GUI refuses on the free-space bug; install from the CommandShell.
- A/UX 3.1 update (`AUX_3.1_Update.iso`, archived) not applied.
- Pointer scale unmeasured (A/UX Toolbox acceleration); the A/UX Finder
  drops fast button presses (hold ~0.3 s) — operator eyeball through the
  browser. Keyboard proof = typing in the CommandShell.
- No exec channel (no getty on the serial line yet).

## Rollback

Additive: new stationDir, new slot 145, no shared files. Withdraw the
overlay with `darklaunch-station.py withdraw aux`; disable the row and
regenerate.
