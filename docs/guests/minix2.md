# minix2 guest

Minix 2.0.4 (Prentice-Hall, 2001), Andrew Tanenbaum's teaching Unix, booted
straight to a root shell on its own `/usr/src` — the exhibit is the kernel
source tree itself, not an application.

## Identity and source

- Public ID / tile directory / SH_STATION: `minix2`
- Slot / UDP port / VMID: `201` / `54201` / `201`
- Sibling scaffolded from `freedos`
- Media: the woodhull pre-installed "Minix 2.0.4 on Bochs 2.1.1" package
  `mx204bx01.zip` (7,179,269 bytes) from
  `https://minix1.woodhull.com/pub/demos-2.0/BochsImage/mx204bx01.zip`; its
  `minix204/minix.img` (52,428,800 bytes) is converted to qcow2 as the
  station disk.
- Provenance: the official 2.0.4 install set is staged alongside, for
  reference only — `i386/ROOT.MNX` (491,520 B, sha256
  `f7fcafb3c32d95b136fb43302605eb95e4231e5daa73244fac456ab013cbe9c8`),
  `i386/USR.MNX` (737,280 B, sha256
  `c5a9b0e8cd6afe8322bf14d2a00dea193668dfb0b329d057f5b97ecb7f7ea465`), plus
  `USR.TAZ`/`SYS.TAZ`/`CMD.TAZ`/`FIX.TAZ`. The wave lead independently
  fetched the same set from
  `http://download.minix3.org/previous-versions/Intel-2.0.4/`, verified it
  against that directory's own `md5list`, and the `ROOT.MNX`/`USR.MNX` came
  out byte-identical (same sha256) to both the woodhull copies and the ones
  inside the Bochs package — three origins agree.

## Device set

`qemu-system-x86_64`, `pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0`, `-cpu host`
under KVM (fleet QEMU 11.0.2, `pve-qemu-kvm 11.0.2-1`), 32 MiB RAM, 1 vCPU,
`-vga std`, `-boot c`. No NIC, no floppy. The PC speaker (Minix console bell)
is routed through the shared `snd0` dbus audiodev; the guest has no sound
card.

The disk is the one device-set fact that matters: it is attached as
`-drive file=...,format=qcow2,if=none,id=hd0` plus
`-device ide-hd,drive=hd0,bus=ide.0,unit=0,cyls=200,heads=16,secs=32`. The
explicit CHS `200/16/32` is **mandatory** — the source image is a 50 MB flat
raw disk whose own partition table was written with that geometry, and a
mismatched CHS makes the guest see a corrupt partition map.

## Pointer and input

None — text console only, no pointer method. Keyboard runs the fleet pacing
floor of 40 ms send / 40 ms flush with no dropped characters measured.

## Boot path

Cold boot lands on `Minix boot monitor 2.19`, which **waits for a keypress**:
`=` starts Minix. (`n` would start Networked Minix — not used, there is no
NIC.) Banner:

```
Minix 2.0.4 Copyright 2001 Prentice-Hall, Inc.
Executing in 32-bit protected mode
at-d0: QEMU HARDDISK
Memory size = 32328K  MINIX = 291K  RAM disk = 0K  Available = 32037K
```

then `/dev/c0d0p2 is read-write mounted on /usr`, multiuser startup, `Minix
Release 2 Version 0.4`, and a login prompt. Login is `root` with **no
password**.

The image shipped with hostname `bochs-minix.local.net`; the wave lead
changed `/etc/hostname.file` to `minix` before the bake, so the fixture reads
`Minix minix 2 0.4 i686`.

## The exhibit

`/usr/src` is the whole Minix 2.0.4 kernel source tree: `LICENSE`, `Makefile`,
`boot`, `commands`, `etc`, `fs`, `inet`, `kernel`, `lib`, `mm`, `tmp`,
`tools`. Demo: `ls /usr/src/kernel`, `cat /usr/src/kernel/proc.c | head`.

## Retronet

OPEN, not joined this wave. Minix 2 does have an inet server and an NE2000
driver, but there is no period browser or IM client for it, so there is
nothing worth reaching over a tap yet — no `--retronet`, and per AGENTS.md
rule 15 no `rn-tapnet.sh` is committed for this station.

## Reset

`loadvm golden` — see `streamhost/stations/minix2/qemu-streamhost.sh`.

## Wall hit and abandoned (floppy install path)

Booting the *official* `ROOT.MNX` floppy image (padded to 1,474,560 bytes)
with `-fda`/`-fdb` under KVM loads the kernel and reaches "RAM disk loaded",
but the RAM-disk copy then throws `Unrecoverable disk error on device 2/0` on
one block in every 18 (the last sector of each track) from block 269
onward — looks like an 18-sectors-per-track boundary bug in the floppy path
under KVM. The pre-installed hard-disk image (above) made this install route
unnecessary, so it was **not raced to a root cause** and remains open for
anyone who later needs the from-floppy install path rather than the
pre-installed image.

## Checkpoint

Baked 2026-09-13 on the sandbox rig `/data/vms/sandbox/minix2/smoke/rig.sh`
(`qemu-img snapshot`, HMP `savevm golden`, 1.62 MiB vmstate). resetMode:
`loadvm`.

Fixture: a logged-in root `#` shell with `uname -a` and `ls /usr/src` already
on screen —

```
Minix minix 2 0.4 i686
LICENSE  boot  etc  inet  lib  tmp
Makefile commands fs  kernel mm  tools
```

Restore proof (framebuffer): typed `echo KEYBOARD PROOF minix2 2026-09-13`,
saw it echo and print — this doubles as the keyboard proof — then
`loadvm golden`; the framebuffer returned to the exact fixture above with the
typed lines gone. Frames:
`/data/vms/sandbox/minix2/smoke/f09-keyproof.png` and
`/data/vms/sandbox/minix2/smoke/f10-restore.png`.

Unproven: pointer (none exists — text console), retronet (not joined).
