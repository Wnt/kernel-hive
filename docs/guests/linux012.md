# linux012 guest

Linux 0.12 (January 1992), the fourth month of the kernel and the one that
mattered: it added demand paging to disk and, in its release notes, quietly
switched the licence to the GNU copyleft. Boots straight to a root shell —
the exhibit is the kernel itself, four months old.

## Identity and source

- Public ID / tile directory / SH_STATION: `linux012`
- Slot / UDP port / VMID: `205` / `54205` / `205`
- Media: `bootimage-0.12-20040306` (150016 bytes, sha256
  `1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425`) and
  `rootimage-0.12-20040306` (1474560 bytes, sha256
  `4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713`), both
  from `https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images/`.
  NOT the `Linux-0.12/images/` path on the same mirror — that directory holds
  only the `.Z` originals, not these prebuilt images.
- Builder: `scripts/build-guests/tiles/linux012.sh`. Pads the boot floppy to
  1474560 bytes (measured requirement: a short raw image leaves QEMU's track
  wrap indeterminate and the boot chain never passes the SVGA prompt),
  patches the boot sector, composes the IDE disks, and publishes
  `boot.qcow2` / `hda.qcow2` / `hdb.qcow2`.

## Device set

`qemu-system-i386`, `pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, KVM (fleet
QEMU 11.0.2, `pve-qemu-kvm 11.0.2-1`), 16 MiB RAM, 1 vCPU (0.12 is
uniprocessor and caps at 16 MB), `-vga std`, `-boot a`. No `-cpu` is passed —
QEMU's i386/KVM default is what the golden was baked against. No NIC, no
pointer device. The PC speaker (`kernel/chr_drv/console.c`'s `sysbeep`) is
routed through the shared `snd0` dbus audiodev; it is the only audio source
this guest has.

The disk set is the one device-set fact that matters, and it is frozen with
the golden (AGENTS.md rule 6):

- **Boot is from the floppy, root is from IDE.** `boot.qcow2` is attached
  `if=floppy,index=0` and carries the original 1992 kernel with its
  boot-sector ROOT_DEV word retargeted (below). `hda.qcow2` carries the
  original minix root filesystem, moved onto an IDE partition, plus a swap
  partition.
- **Two IDE disks, always.** `hd.c`'s `hd_out()` calls `controller_ready()`
  *before* it writes the drive-select register, so it polls the status port
  of whichever device the BIOS left selected. With a master only, the
  absent slave's status port reads 0x00 and 0.12 dies on
  `Kernel panic: HD controller not ready`. `hdb.qcow2` is blank apart from an
  MBR `0x55AA` signature (`hd.c` also requires this, or it panics
  `Bad partition table`) and exists only to answer that poll — it must not
  be removed.
- **Explicit CHS 64/16/32** on both disks — `hd.c` does its own CHS division
  from the BIOS drive table, so the geometry is pinned rather than left to
  QEMU's size-based guess, which a future `qemu-img` could change.

## Pointer and input

None — text console only, and this is not "not wired up yet": Linux 0.12 has
no mouse driver of any kind. Keyboard runs the fleet pacing floor of 40 ms
send / 40 ms flush; every typed character echoes immediately at the
`[/usr/root]#` prompt.

## The boot-sector edits (offsets verified against the real image)

The 0.12 boot sector ends: offset 506-507 = SWAP_DEV (shipped as `02 03` =
0x0302 = `/dev/hd2`), 508-509 = ROOT_DEV (shipped as `00 00`), 510-511 =
`55 aa`. The builder writes ROOT_DEV = 0x0301 (`/dev/hd1`, disk 0 partition
1). With ROOT_DEV = 0, `bootsect.S` would instead auto-detect from the BIOS
sector count (18 sectors → 0x021c = fd0, 1.44M; floppy minors in 0.12:
`drive = minor & 3`, `type = minor >> 2`, type 7 = 1.44M).

## Why the root filesystem is not on a floppy

Symptom: after `Insert root floppy and press ENTER` the guest never
proceeds. That prompt is `mount_root()` in `fs/super.c`, **not** `rd_load()`
— the string sits at byte offset 66212 in the boot image, immediately before
`Unable to mount root` (66247) and `Unable to read root i-node` (66268),
which are `mount_root`'s two panics. The 0.12 Makefile ships
`RAMDISK = #-DRAMDISK=512`, commented out, so `rd_load()` returns
immediately and there is no ramdisk stage at all — the kernel mounts
ROOT_DEV directly.

Retargeting ROOT_DEV to fd1 (0x021d), with the root image in drive B from
launch so no medium swap happens at all, still hangs — so the media-swap
mechanics were never the bug. `info irq` showed IRQ6 firing exactly 43 times
and then stopping, on every floppy configuration tried; `info registers` at
the hang showed EIP 0x682b, EAX 0x1d, CPL 3 — `sys_pause` (syscall 29), task
0 idling while init is blocked asleep. 0.12's `floppy.c` retries in silence
and has no I/O timeout anywhere, so a controller it cannot drive is an
unbreakable hang rather than an error.

Identical result across seven distinct configurations: both drives,
`-M isapc -cpu 486` and the default machine, TCG and KVM, with and without
`-global isa-fdc.fdtypeA=144`/`fdtypeB=144` (five of these by a previous
session, documented in `docs/lab/LINUX012-WAVE.md`; the ROOT_DEV-to-fd1 and
fdtype runs by this session).

Routing the root filesystem through `hd.c` instead reaches a shell in
seconds. This is not a modern shortcut: it is steps 4-7 of Linus's own
`RELNOTES-0.12` install procedure — "use mkfs ... copy over the root
filesystem to the harddisk ... change the bootdisk to understand which
partition it should use as a root".

## Disk layout

`hda.qcow2`, 16 MiB, CHS pinned 64/16/32 on both disks:

- MBR partition 1: start LBA 2048, 2880 sectors, type 0x81 — the original
  1.44 MB minix root filesystem, verbatim. Becomes `/dev/hd1`.
- MBR partition 2: start LBA 8192, 8192 sectors, type 0x82 — swap. Becomes
  `/dev/hd2`, which is what SWAP_DEV in the 1992 boot sector already pointed
  at.

The swap signature page is synthesised by the builder in the format
`mm/swap.c`'s `init_swapping()` validates: a 4096-byte bitmap page at the
head of the partition, bit 0 clear, bits 1..swap_size-1 set, everything
above clear, and the ASCII `SWAP-SPACE` at bytes 4086-4095.
`swap_size = (nr_sects >> 1) >> 2 = 1024`. Result, printed on every boot:
`Swap device ok: 1023 pages (4190208 bytes) swap-space` — 0.12's headline
feature, the first Linux with demand paging to disk, is genuinely live in
this exhibit.

## Boot path

Cold boot lands on:

```
Loading.......................
Press <RETURN> to see SVGA-modes available or any other key to continue.
```

and **waits for a keypress** — that is the 1992 boot chain, not a fault.
`scripts/coldboot/linux012-bootrec-arm.sh` is calibrated against it. After a
keypress:

```
8 virtual consoles
4 pty's
Partition tables ok.
Swap device ok: 1023 pages (4190208 bytes) swap-space
6/1440 free blocks
408/480 free inodes
3369 buffers = 3449856 bytes buffer space
Free mem: 12582912 bytes
  Ok.
[/usr/root]#
```

## The exhibit

Root has no password: `cat /etc/passwd` shows
`root::0:0::/root:/bin/bash`. Userland, measured by listing it in the guest:

- `/` → `bin dev etc root tmp usr`
- `/bin` → `mkswap sh vi`
- `/usr/bin` → `basename cat chgrp chmod chown cmp cp dd df file grep head ln
  ls mkdir mkfifo more mv paste rm rmdir sed stty tail touch uniq`
- `/etc` → `group magic mtab passwd profile rc termcap update`

`uname` is not present in this root filesystem (`uname: command not found`)
— do not use it as a probe. `df` runs but prints only a header with no rows.
The root filesystem has only `6/1440` free blocks — a genuine period
constraint (it is a 1.44 MB root floppy image, not damage), and a visitor
cannot write much.

Demo: `ls /`, `cat /etc/passwd`, `ls /usr/bin`.

## Retronet

Not applicable, not "not done yet": Linux had no networking stack of any
kind until 0.96b (mid-1992), so this station has no NIC and no tap script.

## Reset

`loadvm golden` — see `streamhost/stations/linux012/qemu-streamhost.sh`.

## Checkpoint

resetMode: `loadvm`, snapshot `golden`. Fixture: the root shell with the
boot banner still above it — the banner is a one-shot and scrolls away, so
the golden captures the scene deliberately right after boot, not after it
has scrolled off.

Baked 2026-09-20 on `/data/vms/sandbox/linux012-race/riggolden` with the
SAME device set as the launcher (kernel floppy + both IDE disks, CHS
64/16/32, `-m 16 -smp 1`, `pcspk-audiodev=snd0`, KVM). The vmstate lands in
`boot.qcow2`; all three qcow2s carry the `golden` tag, and the launcher
tests for it on `hda.qcow2`.

Fixture scene: `race/golden/a2-scene.png` — the full kernel banner
(including `Swap device ok: 1023 pages`) with `cat /etc/passwd` run once
below it, which also scrolls the SeaBIOS/iPXE lines off the top.

- restore proof: `race/golden/b2-restore.png` — a typed
  `echo KEYBOARD PROOF linux012 2026-09-20` line vanished and the fixture
  scene came back.
- keyboard proof: `race/golden/b1-keyproof.png` — that whole line typed at
  the fleet floor 40/40 and echoed back by the shell with no dropped
  characters.

Unproven: pointer (none exists — text console, no mouse driver), retronet
(does not exist for this kernel).
