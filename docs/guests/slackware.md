# slackware guest — Slackware 3.4, the fvwm95 desktop

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-03 in a
speed-record wave ([`lab/SLACKWARE-WAVE.md`](../lab/SLACKWARE-WAVE.md)).

## What it is

Slackware 3.4 (October 1997): Linux **2.0.30**, XFree86 **3.3.1**, and the
**fvwm95** window manager — the release that made a Unix workstation look like
Windows 95. Slackware is the distribution that still ships from the same
maintainer today; this station is the 1997 release, not a retro rebuild.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `slackware`
- Display name: **Slackware 3.4** (`museum.displayName`)
- Reserved slot / UDP port / VMID label: `184` / `54184` / `184`
- Archetype: `putty-lcd`; era year **1997** (`museum.year`), lineage
  `Slackware Linux (SLS lineage, Linux 2.0.30)`
- Upstream: `https://mirrors.slackware.com/slackware/slackware-3.4/`
  (mirrorbrain redirector — fetch with `curl -L`); an immutable 1997-10-05
  release
- No login prompt: root, empty password, autostarts to the desktop.
  `credentialsRef: guest/slackware` exists only because the schema requires
  one.

## Composition recipe

The root filesystem is composed **host-side, with no interactive setup and no
floppy-based installer** — `scripts/build-guests/tiles/slackware/compose.sh`,
proven to run on labhost as root in ~12 s. Slackware's `.tgz` packages are
plain tarballs relative to `/`, and each package's `install/doinst.sh` is
written to run with cwd = the install root using **relative paths**, so the
script runs safely under the host's own `sh` with `ldconfig`/`depmod`/`chroot`
neutered to no-ops — no chroot, no interactive prompts, no floppy dance the
1997 installer would otherwise demand.

65 packages across five series: `a` (base system, ADD+REC, minus `gpm` — it
would grab the mouse away from X — plus scsi/pcmcia/loadlin/umsprogs/ibcs2/
scsimods excluded), `ap` (manpgs, sudo, joe, bc, diff, sc, zsh, ash, jpeg, mc,
vim), `x` (fvwm, fvwmicns, the x331 XFree86 3.3.1 binaries/config/docs/fonts/
lib/man/svga/vg16/fscl set, xlock, xpm), `xap` (fvwm95, libgr, xv, xfm,
xpaint, xgames), `y` (bsdgames).

Two traps found composing it this way:

- **The soname-link trap.** libc5-era Slackware leaves the shared-library
  soname symlinks (`libc.so.5`, `ld-linux.so.1`, …) for `ldconfig` to create
  at install time — and `ldconfig` is neutered here. Without them init cannot
  even load a dynamically linked binary, and the kernel sits silent after
  "VFS: Mounted root" with no further output. `compose.sh` derives each
  library's SONAME with `readelf -d` (falling back to a filename pattern) and
  symlinks it by hand across `lib`, `usr/lib`, `usr/X11R6/lib`,
  `usr/i486-linux-libc5/lib` and `usr/lib/X11`.
- **`var/adm` is a symlink**, so package records land in `var/log/packages`,
  not the path a casual `install/doinst.sh` reader would expect.

Disk: 400 MiB raw, one bootable partition at sector 63,
`mke2fs -E revision=0,offset=32256 -d` — **rev-0 ext2**, because kernel 2.0
mounts nothing newer — then converted to qcow2 with `qemu-img convert`.

## Device set

`streamhost/stations/slackware/qemu-streamhost.sh` is deployed **verbatim**.
QEMU **11.0.2** (host `pve-qemu-kvm` 11.0.2-1).

```
qemu-system-x86_64 -name streamhost-slackware \
  -enable-kvm -m 32 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot d \
  [-loadvm golden -S] \
  -vga cirrus \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device sb16,audiodev=snd0 \
  -chardev msmouse,id=ms0 -serial chardev:ms0 \
  -drive file=$BASE/disk.qcow2,format=qcow2,if=ide \
  -drive file=$BASE/grub-boot.iso,format=raw,if=ide,index=2,media=cdrom,readonly=on \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off -pidfile $BASE/qemu.pid
```

- **Boot loader.** The stock 1997 LILO on the `bare.i` boot floppy wedges at
  "LI" under SeaBIOS (KVM: `KVM internal error. Suberror: 1`; TCG: same "LI"
  hang), and QEMU's own `-kernel` loader hangs this zImage before
  "Uncompressing Linux". What works: a **GRUB2 rescue ISO**
  (`grub-mkrescue`, `linux16 /zImage root=/dev/hda1 ro`), attached read-only
  as the secondary-master CD, `-boot d`. The kernel boots under KVM
  `-cpu host` and under TCG `-cpu pentium2`; the station ships KVM. The ISO
  is therefore part of the device set — the `golden` vmstate was baked with
  it attached and it must stay attached to restore.
- **`-vga cirrus`** (CL-GD5446, `Chipset "clgd5446"`, VideoRam 4096) at
  1024x768x16. XFree86 3.3.1's `XF86_SVGA` driver did not paint text at all
  until `Option "no_bitblt"` was added (raced 4 configs on clones: depth 8
  accel ✗, depth 16 noaccel ✗ — X never came up, depth 16 no_bitblt ✓, depth
  8 noaccel ✓) — BitBLT emulation on the Cirrus driver drops xterm text.
  `Option "sw_cursor"` is set alongside it. Shared root cause with the
  netbsd14 wave (same symptom, same fix).
- **`disk.qcow2` is the only writable block device** and carries the
  `golden` vmstate; `grub-boot.iso` is read-only.
- **32 MB RAM, 1 vCPU, KVM, `-cpu host`.** Kernel 2.0 is happiest under
  64 MB; the station runs comfortably under half that.
- **Audio**: `sb16` plus the PC speaker (`pcspk-audiodev=snd0`), both routed
  into the dbus audiodev — the desktop only beeps.
- **No exec channel.** `bare.i` has no NIC driver, so `operator.labctl.qmp`
  and the framebuffer are the only path in; `exec_kind` is `null`.

## Host-native capture path

**Tier 1**, direct-QEMU, KVM-accelerated. The guest's VGA framebuffer is
captured straight off QEMU's dbus display and input goes straight in through
QMP — no kiosk, bridge or second VM in the path.

## Ready scene

`museum.notes` / `reset.fixture`: the fvwm95 desktop at 1024x768x16, root
logged in — `xterm` titled "darkstar" with a `bash#` prompt top-left,
`xclock` top-right, the FvwmButtons dock bottom-right, Start button and
taskbar bottom. `/root/.xinitrc` sets `xset s off`/`-dpms`/`m 1 1`, paints the
background, launches `xterm` and `xclock`, then execs `fvwm95-2`; `.fvwm2rc95`
is copied from `/var/X11R6/lib/fvwm95-2/system.fvwm2rc95` (without it fvwm95
runs with a bare builtin look, not the Windows-95-style desktop). `rc.local`
runs `startx` on every boot, so a **cold boot lands on the same desktop** —
root has an empty password in both `passwd` and `shadow`.

## Pointer

**Absolute, through the guest's own X server (x11warp).** XFree86 3.3.1 knows no
absolute input device QEMU can offer, so the streamhost daemon connects to the
guest X server over TCP and moves the pointer with `XWarpPointer`, reading it back
with `XQueryPointer` (`SH_INPUT_BACKEND=x11warp`, `SH_X11WARP_DISPLAY=127.0.0.1:84`,
`method: x11-warp-absolute`). The plumbing composed into the root filesystem:

- the `tcpip` package (n6) for `ifconfig`/`route`; `/etc/rc.d/rc.inet1` sets the
  slirp address 10.0.2.15/24 with 10.0.2.2 as gateway; `rc.inet2` is emptied so
  nothing but X listens;
- `/etc/rc.d/rc.modules` loads `ne` (`io=0x300`) — the kernel's own NE2000 driver
  as a module, matching QEMU's `ne2k_isa` defaults (io 0x300, irq 9);
- the launcher's `-netdev user,…,hostfwd=tcp:127.0.0.1:6084-10.0.2.15:6000` and
  `xhost +10.0.2.2` in `.xinitrc` (XFree86 3.3 listens on TCP by default).

Buttons and the relative fallback still travel the Microsoft serial mouse on
`ttyS0` (QEMU `msmouse`; measured 2 px per unit). Proof tool:
`scripts/build-guests/tiles/slackware/xwarp.py` — raw core protocol, because
xdotool segfaults against an XFree86 3.3 server and labhost has no python-xlib.

## Checkpoint

Baked 2026-09-03 by the golden stream on a sandbox clone of the pristine composed
disk with the exact station launcher (KVM, `-cpu host`, 32 MB, i440fx, cirrus,
msmouse serial, IDE disk + GRUB2 ISO): cold boot settles on the desktop 32 s after
power-on; `savevm golden` at VM_CLOCK 0000:00:42.223, VM_SIZE 16.7 MiB, stored in
`disk.qcow2` (the ISO is attached read-only and is part of the device set).

- **Restore proof**: relaunch → `-loadvm golden -S` → `cont` → the desktop frame,
  not a cold boot (`/data/vms/sandbox/slackware-golden/bake/fb-restore1.png`).
- **Keyboard proof**: `uname -a` typed into the xterm echoes
  `Linux darkstar 2.0.30 #3 Tue Jun 24 03:49:52 CDT 1997 i686 unknown`.
- **Reset is the restore**: `loadvm golden` after typing → the output is gone and
  the clock is back at bake time (`fb-reset.png`).
- **Pointer (phase 2, 2026-09-03)**: golden re-baked with the NE2000 device set
  (VM_CLOCK 0000:00:55, pointer parked at 1020,760). `xwarp.py 127.0.0.1:84
  100 700 900 100` reads back exact and the cursor is visible at both targets on
  the framebuffer, before and after `loadvm golden`; golden and restore frames
  differ by zero pixels (`/data/vms/sandbox/slackware/abs/fb-*.png`).

## Known gaps

- ~~Absolute pointer~~ — done in phase 2 (x11warp), see *Pointer* above. The
  `bare.i` kernel's NE2000 module was enough; no kernel swap was needed.
- **No exec channel.** `bare.i` has no NIC driver; everything is QMP
  keys/mouse plus the framebuffer, same as several of the fleet's other
  small, driver-light stations.
- **a.out libs make `readelf` fail** under `set -o pipefail` in
  `compose.sh` — worked around, not fixed generally.
