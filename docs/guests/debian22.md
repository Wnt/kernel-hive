# debian22 guest — Debian GNU/Linux 2.2 "potato"

Status: **Tier 1**, host-native, KVM, air-gapped like `redstar2`. Integrated
2026-09-03 in a parallel wave ([`lab/DEBIAN22-WAVE.md`](../lab/DEBIAN22-WAVE.md)).

## What it is

Debian GNU/Linux 2.2 "potato", released 2000-08-14: kernel 2.2.19, XFree86
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

## Install recipe

1. Boot CD1 to the `boot:` prompt, Enter into boot-floppies 2.2.16.
2. `dbootstrap`: language/keyboard, partition the single IDE disk, format,
   install the base system from `base2_2.tgz` (or CD packages), configure
   the bootloader (LILO) on the MBR.
3. First-boot configuration (`base-config`): timezone, root password, one
   `gallery` user, package selection including `gnome-desktop` (task) and
   `xserver-xfree86`.
4. `XF86Config` for `XF86_SVGA`: `Driver "cirrus"`, 1024x768 at 16bpp,
   PS/2 `Protocol "PS/2"` mouse section, no VESA fallback (3.3.6 has none).
5. `/etc/inittab` edited so the default console runlevel auto-logs `gallery`
   in and starts X straight into the GNOME 1.0 desktop — no `xdm`/`gdm`
   chooser, matching `redstar2`'s KDM auto-login approach but via inittab
   rather than a display manager, since potato predates a configured `gdm`
   greeter on this fixture.

Fallback if GNOME 1.0 does not fit the bring-up window: X + Window Maker.

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

TODO(golden): spliced from the golden stream's report at integration
