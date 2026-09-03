# debian22 guest — Debian GNU/Linux 2.2 "potato"

Status: **Tier 1**, host-native, KVM, air-gapped like `redstar2`. Integrated
2026-09-03 in a parallel wave ([`lab/DEBIAN22-WAVE.md`](../lab/DEBIAN22-WAVE.md)).

## What it is

Debian GNU/Linux 2.2 "potato", released 2000-08-14: kernel 2.2.17 on the CD (2.2.19 in later point releases), XFree86
3.3.6, GNOME 1.0. i386. Installed from the archived boot-floppies `dbootstrap`
installer, the same generation of Debian install experience as the contemporary
`bootos`/`pcgeos` FreeDOS-era stations are to DOS. The station boots straight
onto the GNOME 1.0 desktop, air-gapped — no network device, no exec channel —
the same isolation posture as `redstar2`.

## Media and provenance

Staged at `/data/assets-staging/debian22/`:

| file | size (bytes) | sha256 |
|---|---|---|
| `debian-2.2-i386-cd1.iso` | 659271680 | `2b1d2b18a14ea1f62302aeb98caf1a7b9191a87c3591a42d8bbf0fe5ef1abf1f` |
| `base2_2.tgz` | 15915492 | `2f53ecb6a1508be95d5351e468b0197e8dca2a58ecf24c8fc1e07765b9817585` |
| `linux-installer-kernel` (`linux`) | 1001341 | — |

`debian-2.2-i386-cd1.iso` is archive.org item `Debian-GNULinux-2.2-arch-i386-CD`,
file `…-1of3.iso` — the 2.2 r0 "Official i386 Binary-1" disc, rescue floppy
2.2.16, kernel-image 2.2.17pre6-1 on the boot disk. `base2_2.tgz` and the
installer kernel come from `archive.debian.org
dists/potato/main/disks-i386/current/`.

## Device set

`streamhost/stations/debian22/qemu-streamhost.sh`, deployed **verbatim**:

| property | value |
|---|---|
| machine | `pc-i440fx-11.0` |
| accel | KVM |
| CPU | `-cpu host` |
| RAM | 256 MB |
| vCPU | 1 |
| disk | IDE index 0, `disk.qcow2` (carries the `golden` vmstate) |
| CD | IDE index 2, CD1 stays attached |
| display | `-vga cirrus` |
| pointer | PS/2 mouse (relative, `SH_POINTER=rel`) — no tablet protocol in XFree86 3.3.6 |
| keyboard | PS/2 |
| flags | `-nodefaults`, no NIC, no USB, no audio |

Screen: 1024x768 16bpp on the Cirrus GD5446 via `XF86_SVGA` — XFree86 3.3.6
has no VESA server, so the era-correct Cirrus driver is the display path
(compare `redstar2`, whose later 2.6 kernel forced a `-vga std`/`vesa` swap;
potato's XFree86 3.3.6 stays on the Cirrus-native driver at install time).

## Install recipe (host-composed; the CD installer is not viable)

Measured 2026-09-03 by three waves independently: a Linux 2.2 kernel writes an
emulated IDE disk in 16-bit PIO under KVM, one VM exit per `outw`, ~27 KB/s.
dbootstrap's `mke2fs` on a 2 GiB disk had not finished after 13 minutes, and
cfdisk refuses the blank qcow2 ("Bad signature") in the first place. Under
`-accel tcg` the same `mke2fs` takes 47 s, but TCG would change the device set,
so the disk is composed on the host instead:
`scripts/build-guests/tiles/debian22.sh` (root on labhost).

1. `qemu-nbd` the 2 GiB qcow2; partition table made once with `fdisk` from the
   rescue shell (hda1 cyl 1–483 bootable Linux, hda2 cyl 484–520 swap; CHS
   520/128/63). `mke2fs -t ext2 -O none -I 128` — 2.2 rejects 256-byte inodes.
2. `base2_2.tgz` (the potato base system) untarred, then the Depends closure of
   `gnome-core gnome-panel gnome-terminal gmc gnome-session xserver-svga
   xbase-clients xfonts-base xfonts-75dpi xterm wmaker` from CD1's `Packages.gz`
   (`tiles/debian22/closure.py`, 62 .debs) unpacked with `dpkg-deb -x`, control
   files into `/var/lib/dpkg/info`, a `Status: install ok unpacked` stanza per
   package so the guest's dpkg agrees.
3. The eight X traps, each framebuffer-proven: `fonts.alias` assembled from
   `/etc/X11/fonts/<dir>/*.alias` + `mkfontdir` (the xfonts postinst never ran,
   so the `fixed` alias did not exist); `chmod -R a+rX` on the X tree (host umask
   left `fonts.dir`/`XF86Config` 0600 and X dies silently); `XF86_SVGA` setuid
   root (no Xwrapper on potato); `/usr/X11R6/lib` in `ld.so.conf` with `ldconfig`
   run at the END of rcS (at the top `/` is still read-only and the cache write
   fails silently: `libXmu.so.6: cannot open`); `/etc/hosts`; `/tmp/.X11-unix`
   recreated root-owned 1777 after bootmisc cleans `/tmp` (X aborts on a
   gallery-owned socket dir); `Chipset "clgd5446"`, `VideoRam 4096`,
   `Option "no_bitblt"` (without it xterm/gnome-terminal paint no text), 1024x768
   at depth 16 (`tiles/debian22/XF86Config`); `unix.o` insmod'd in rcS (AF_UNIX
   is a module in the 2.2.17 kernel-image).
4. `kernel-image-2.2.17` unpacked for its modules; `unconfigured.sh` (forces a
   reboot loop), modutils/kerneld/makedev init scripts, gdm/xdm/pcmcia/ppp/inetd
   links removed. Root and gallery accounts (passwords in the gitignored
   `registry/local.env`, key `guest/debian22`). `~/.xsession`: `xset s off;
   xset -dpms; wmaker & … gnome-terminal & exec gnome-session`.
5. Boot on the launcher device set with `-boot order=d`; at the CD's `boot:`
   prompt type `linux root=/dev/hda1` (no boot loader on the disk; the golden
   vmstate carries the running kernel). Log in root on tty1 and run
   `su - gallery -c /usr/bin/X11/startx >/root/x.log 2>&1 &` — init cannot
   start X (an init-spawned `startx` has no controlling tty and never spawns the
   server; proven, the `x1` respawn line was dropped). X paints in ~30 s,
   Window Maker + the GNOME panel in another ~1–2 min (libraries come through
   the PIO path). Click the terminal, `xset m 1 1; clear`, HMP `savevm golden`.

## Operator notes

- **Air-gapped**: no NIC, no `-netdev`, no network-class `-device`. Same
  isolation posture as `redstar2` — `operator.labctl.exec_kind: none`.
- **No exec channel** — drive the station with QMP keys/mouse and read the
  framebuffer only.
- **Reset**: `resetMode: loadvm`, checkpoint `golden`.
- **Credentials**: root and `gallery` passwords live in gitignored
  `registry/local.env` under key `guest/debian22` — set and reported there by
  the golden stream, never written in git.

## Checkpoint

`golden` baked 2026-09-03 06:33 on the smoke rig (`/data/vms/sandbox/debian22/smoke`)
against the exact launcher device set; VM_SIZE **46.5 MiB**, disk.qcow2 380 MB,
VM_CLOCK 3:16:29. Restore proof on a fresh launch with `-boot order=c -loadvm golden -S`
+ `cont`: desktop within 4 s; `cat /etc/debian_version; uname -sr` typed and echoed
(`2.2`, `Linux 2.2.17`); a 300-unit relative pointer move landed the arrow on the
terminal title bar; a second HMP `loadvm golden` returned the clean prompt.
Frames: `smoke/p1.png … p4.png` (PPM despite the name).

**OPEN:** (1) disk I/O at runtime is still 2.2 PIO — `hdparm` is not on CD1; the
redhat62 wave proved `hdparm -d1 /dev/hda` on the UP kernel gives PIIX DMA at
60+ MB/s, so the follow-up is to add hdparm (archive.debian.org potato/admin) to
the compose and rebake. (2) No cold-boot path: the disk has no boot loader and X
is started by hand; a recapture needs the five-line bake above, or a
`mingetty --autologin` + `.profile` `exec startx` route as netbsd14/slackware use.
(3) Pointer is relative; an absolute route (in-guest X pointer write as amix) is
a follow-up.
