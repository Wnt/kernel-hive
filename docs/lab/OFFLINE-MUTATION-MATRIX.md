# Offline disk mutation: what we can safely write into, per tile

Measured on the box 2026-08-10 with `scripts/dev/tile-fs-probe.sh`, which is
**read-only**: `qemu-nbd --read-only` plus `blkid -p` on the block device.
Nothing is mounted and nothing is written, so it is safe to run against live
tiles. Re-run it after any tile rebuild — this table is a snapshot, the script
is the source of truth.

## Why the middle column exists

"Can Linux write into this guest's disk" has **three** answers, and the middle
one is the dangerous one. The kernel will happily mount Haiku BFS, Solaris UFS,
Amiga AFFS and QNX4/6 — read-only, or with a write path that is unverified and
barely maintained. **A partial or buggy write to an exotic filesystem is worse
than no write at all**: it corrupts a golden that took hours to bake, and the
damage surfaces later, at a visitor reset, as an exhibit that will not boot.

So `scripts/build-guests/lib/bridge-coldboot mutate` uses a **positive
allowlist, probed at run time**, not this table: `ext2 ext3 ext4 vfat msdos
exfat ntfs`. Anything else is refused with the detected filesystem named. The
table tells you what to expect; the helper enforces it whether or not the table
is current.

## Verdicts

`MOUNTABLE-RW` — offline mutation works today.
`MOUNTABLE-RO` — the host can read it; writing is refused.
`NOT-SUPPORTED` — no host path into the filesystem at all.

### MOUNTABLE-RW (44 tiles)

| Filesystem | Tiles | Notes |
|---|---|---|
| ext4 (Debian bridge kiosk) | `alto` `amiga` `amstradcpc` `apple2` `armeval` `atarist` `bbcmicro` `c128` `c64` `cbm2` `cbm8032` `daybreak` `decos` `dragon32` `gt40` `indyr4400` `kc854` `mpf2` `nextstep` `oricatmos` `pdp11` `pet2001` `plus4` `sinclairql` `star` `vic20` `zx81` `zxspectrum` | **The most reliable case.** Every bridge overlay is the same Debian ext4 root (p1) + BIOS-boot (p14) + ESP (p15). The emulated machine's own media (`.d64`, `.adf`, disk packs) and the MAME binaries live as ordinary FILES inside that ext4 — which is exactly what makes offline mutation useful here. |
| ext4 / ext3 (native Linux guests) | `android` `postmarketos` `redstar2` `redstar3` | |
| FAT (DOS/Win9x era) | `freedos` `msdoswin1` `ninefront` `nt351` `os2warp` `win311` `win95` `win98se` | **The highest-value case.** These have no `labctl exec` channel and often no network; today a file gets in via the SLIRP one-shot HTTP trick or by typing at the framebuffer. Offline mutation is the only clean route. `mtools` is also installed if a mount is undesirable. |
| NTFS | `nt4` `win2000` `winxp` `win11` | Via `ntfs-3g`. The kernel's own `ntfs` driver is read-only and silently so, which is why the helper names `ntfs-3g` explicitly. **`win11` also carries a BitLocker partition** — treat writes there as unsafe regardless of this verdict. |

### MOUNTABLE-RO (2 tiles)

| Tile | Filesystem | Why not RW |
|---|---|---|
| `haiku` | BeFS | The kernel's `befs` driver is read-only by design. |
| `solaris` | UFS (7 partitions) | The kernel's `ufs` driver is read-only unless built with `CONFIG_UFS_FS_WRITE`, which is off here — and Solaris UFS write support is not something to trust a 2.1 GiB golden to. `solaris` already has a real exec channel (warpd, `labctl exec`), so it needs this least. |

### NOT-SUPPORTED (11 tiles)

| Tiles | Why |
|---|---|
| `alpine` `aros` `helenos` `kolibrios` `qnx` `reactos` `templeos` `tinycore` | **Boot a live ISO.** The tile's qcow2 is a small scratch/state file, not the OS. Writing into it reaches nothing the guest reads at boot; the medium that matters is an ISO, read-only by construction. Changing what these run means rebuilding the ISO, not mutating a disk. |
| `irix` | MAME `.chd` container — not a block image, no host path into it at all. |
| `serenityos` | No filesystem signature on its qcow2. |
| `openvms` | **Read this one carefully.** The probe reports `ext4` for `openvms`, and that is the *bridge* Debian guest (`openvms-decwindows-bridge.qcow2`), which genuinely is MOUNTABLE-RW. The **OpenVMS system disk itself** (`openvms-community.qcow2`) is ODS-5: probed directly, only its EFI partition (`X86_EFI`, vfat) has a Linux-readable signature, and the two `X86_OPENVMS_SYSDISK_*` partitions have none. The OpenVMS volume is NOT mutable from the host. |

Not probed: `sailfishos` and `toaruos` have no disk image on the box.

## libguestfs is NOT installed — and it is the recommended next step

`guestfish`, `virt-filesystems`, `virt-ls` and `virt-copy-in` are **absent** on
the box. `libguestfs-tools 1:1.54.1-2+deb13u1` is available in trixie and would
be a genuine improvement for this work:

- it supports far more filesystems than the host kernel exposes (including
  read-only inspection of several in the NOT-SUPPORTED list);
- it needs **no `/dev/nbd` device and no root mount**, which keeps this whole
  class of tooling away from the mount-propagation bug that unmounted the host's
  `/dev/pts` on 2026-08-10;
- `virt-copy-in` is a single safe call for the common "drop a file into the
  guest" case.

It was not installed here because installing host packages was outside this
task's remit. **Recommend installing it and re-running the probe** — the
verdicts above are what the *kernel* can do, and are therefore a floor.

## The other guard that matters more than the filesystem

`pve-qemu-kvm` **does not enforce the qcow2 image lock.** Measured 2026-08-10:
with a `qemu-nbd` server holding an image open read-write, `qemu-img snapshot -c`
returned exit 0 and took the snapshot anyway, even with `file.locking=on` named
explicitly. Upstream QEMU refuses. So "qemu-img will stop me if the VM is
running" is **false on this box**, and any tool that relies on it will silently
corrupt a live tile.

`bridge-coldboot` therefore checks `/proc/<pid>/fd` for holders of the exact
image file and refuses if any exist. Never work around that with `-U` /
`--force-share`.
