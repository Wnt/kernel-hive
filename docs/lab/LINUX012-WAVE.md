# linux012 wave notes — Linux 0.12 (issue #54)

Station: `linux012` · slot/udp/vmid 205 · scaffolded `--like minix2`.
**RESOLVED and LIVE 2026-09-20.** The root-floppy wall was real; the fix is to
stop using the floppy for the root filesystem.

## Media — measured, pinned

The seed doc (`docs/lab/integration-seeds/linux012.md`) pointed at
`Linux-0.12/images/` for the raw `-20040306` repackaged floppies. That path
only has the `.Z`-compressed originals. The raw repackaged pair lives one
directory up, at the `Linux.old/images/` root:

| file | bytes | sha256 |
|---|---|---|
| `bootimage-0.12-20040306` | 150016 | `1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425` |
| `rootimage-0.12-20040306` | 1474560 | `4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713` |

`scripts/build-guests/tiles/linux012.sh` fetches, hashes and composes both into
`boot.qcow2` / `disk.qcow2` / `disk2.qcow2`.

## The two walls, and what actually caused each

### Wall 1 — `Loading.........` never finishes (SOLVED earlier)

EIP frozen bit-identical at `9020:0132`, which disassembles to
`IN AL,0x60 / CMP AL,0x82 / JB back` — the Linux 0.12 keyboard-flush loop.
**Fix: zero-pad the boot image to a full 1474560-byte floppy** plus a few
distinct `send-key` events. A short raw image leaves QEMU's track wrap in an
indeterminate state. The builder does the padding.

### Wall 2 — `Insert root floppy and press ENTER` (SOLVED 2026-09-20)

**The prompt is `mount_root()` in `fs/super.c`, not `rd_load()`.** Two cheap
static facts settled what five device-set/keying experiments could not:

1. The string sits at byte offset 66212 in the boot image, immediately before
   `Unable to mount root` (66247) and `Unable to read root i-node` (66268) —
   mount_root's own two panics.
2. The 0.12 Makefile ships `RAMDISK = #-DRAMDISK=512`, commented out. So
   `rd_load()` returns on its first line and there is **no ramdisk stage at
   all**: the kernel mounts `ROOT_DEV` directly and then reads it.

`ROOT_DEV` is the word at boot-sector offset 508, shipped as `00 00`;
`bootsect.S` then auto-detects it from the BIOS sector count (18 → `0x021c` =
fd0, 1.44M). So the kernel was always going to read the root filesystem through
`kernel/blk_drv/floppy.c`.

**And floppy.c cannot drive QEMU's `isa-fdc`.** Measured, not inferred:

- `info irq` shows IRQ6 firing exactly **43 times** and then stopping. The
  controller is interrupting; the driver is retrying in silence and giving up
  without ever reporting an error, because **floppy.c has no I/O timeout
  anywhere**. A controller it cannot drive is an unbreakable hang.
- `info registers` at the hang: `EIP=0x682b EAX=0x1d CPL=3` — `sys_pause`
  (syscall 29), i.e. task 0 idling while init is blocked asleep on the read.
- Identical IRQ6 count and identical frame across **seven** configurations:
  dual-drive + `ret`; single-drive + QMP `eject`/`blockdev-change-medium`;
  legacy HMP `change floppy0`; `-global isa-fdc.fdtypeA=144`; `fdtypeA+fdtypeB`;
  `-M isapc -cpu 486`; TCG and `-enable-kvm`. Retargeting `ROOT_DEV` to **fd1**
  (`0x021d`), with the root image in drive B from launch so no medium swap
  happens at all, hangs the same way — which rules the swap mechanics out
  entirely.

**Fix: put the root filesystem on an IDE partition and set `ROOT_DEV = 0x0301`
(`/dev/hd1`).** `hd.c` is a path QEMU drives correctly, and the prompt never
appears at all, because `mount_root()` only prints it when `MAJOR(ROOT_DEV)==2`.

This is not a modern liberty. `RELNOTES-0.12` step 7 is *"Change the bootdisk to
understand which partition it should use as a root filesystem. [...] it's still
the word at offset 508 into the image"* — the builder writes exactly that word,
exactly where `rdev` wrote it. The swap word at offset 506 is documented in the
same file and the 1992 image already had it set to `/dev/hd2`.

### Wall 3 — `Kernel panic: HD controller not ready` (SOLVED, same session)

`hd.c`'s `hd_out()` calls `controller_ready()` **before** it writes the
drive-select register, so it polls the status port of whichever device the BIOS
left selected. With an IDE master only, the absent slave's status reads `0x00`
and 0.12 panics.

**Fix: always attach a second IDE disk.** One variable, two frames:

| | frame | result |
|---|---|---|
| master only | `race/D-ide-lba2048/fb1.png` | `Kernel panic: HD controller not ready` |
| master + blank slave | `race/G-ide-slave/fb1.png` | `[/usr/root]#` root shell |

`disk2.qcow2` is blank apart from an MBR `0x55AA` signature — which `hd.c` also
requires, or it panics `Bad partition table`. **Do not remove it.**

## What ships

`disk.qcow2`, 16 MiB, CHS pinned 64/16/32 (0.12's `hd.c` does its own CHS
division from the BIOS drive table, so the geometry must not be left to QEMU's
size-based guess):

- partition 1 — LBA 2048, 2880 sectors, type 0x81: the original 1.44 MB minix
  root filesystem, verbatim. `/dev/hd1`.
- partition 2 — LBA 8192, 8192 sectors, type 0x82: swap, with a bitmap page
  synthesised in the format `mm/swap.c`'s `init_swapping()` validates (bit 0
  clear, bits 1..1023 set, `SWAP-SPACE` at bytes 4086-4095). Every boot prints
  `Swap device ok: 1023 pages (4190208 bytes) swap-space`, so 0.12's headline
  feature — the first Linux with demand paging — is genuinely running.

Device set, frozen with the golden: `qemu-system-i386 -enable-kvm -m 16 -smp 1`,
`pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, `-boot a`, `-vga std`, kernel
floppy + two IDE disks, no NIC, no pointer. Linux 0.12 has no mouse driver and
no networking stack of any kind (the first was 0.96b, mid-1992), so retronet and
a pointer surface are **not applicable**, not deferred.

## Proofs (framebuffer, per rule 9)

All under `/data/vms/sandbox/linux012-race/race/`:

| proof | frame |
|---|---|
| root shell reached | `G-ide-slave/fb1.png` |
| interactive (`ls /`, `ls /bin`, `ls /usr/bin`, `cat /etc/passwd`) | `G-ide-slave/usrbin.png`, `H-final-kvm/demo.png` |
| final device set + swap line, under KVM | `H-final-kvm/fb1.png` |
| golden fixture scene | `golden/a2-scene.png` |
| keyboard, fleet floor 40/40, full line round-tripped | `golden/b1-keyproof.png` |
| `loadvm golden` restore (typed line gone, fixture back) | `golden/b2-restore.png` |

And on the LIVE station after landing, which is the proof that counts (the rig
proves the guest, the station proves the launcher, the golden and the daemon
together):

| proof | frame |
|---|---|
| golden restored by the real launcher at first start | `linux012-race/live-check.png` |
| live input — `ls /etc` typed through `labctl` and answered | `linux012-race/live-typed.png` |
| live `labctl reset` — the typed line gone, fixture back | `linux012-race/live-reset.png` |

## Userland (measured in the guest)

`/` → `bin dev etc root tmp usr` · `/bin` → `mkswap sh vi` · `/usr/bin` →
`basename cat chgrp chmod chown cmp cp dd df file grep head ln ls mkdir mkfifo
more mv paste rm rmdir sed stty tail touch uniq` · `/etc` → `group magic mtab
passwd profile rc termcap update`.

Traps for anyone writing a probe: **`uname` is not present** in this root
filesystem (`uname: command not found`) — do not use it. `df` runs but prints a
header with no rows. `cat /etc/passwd` is the good non-destructive probe, and
shows `root::0:0::/root:/bin/bash` — root has no password. The root filesystem
has only `6/1440` free blocks; that is the genuine 1.44 MB root floppy, not
damage, but a visitor cannot write much.

## Method note

The previous session bisected wall 2 serially against rule 14 and reached
"genuine QEMU-fdc gap, needs a Linux historian". It was right that the wall was
real and right to refuse to force a landing. What broke it was not more flag
guessing but **reading the guest's own source** (`linux-0.12.tar.gz`, extracted
under the sandbox) and two `grep`s over the boot image — the `strings` offsets
that proved the prompt was `mount_root`, and the Makefile line that proved there
was no ramdisk. `info irq` then turned "it hangs" into "IRQ6 fires 43 times and
the driver has no timeout", which is a fact rather than a theory. Cost: about
four minutes, against hours of device-set permutations.
