# redhat62 guest

Red Hat Linux 6.2 "Zoot" (April 2000), kernel 2.2.14, GNOME 1.0.55 under
Enlightenment 0.16 on XFree86 3.3.6.

## Identity and source

- Public ID / tile directory / SH_STATION: `redhat62`
- Slot / UDP port: `181` / `54181`
- Media: `zoot-i386.iso`, 671881216 bytes, sha256
  `dc8a1c86cc3389768af207101ecdc8f44e61bc8a5044cfb5fe0efb67eeaa9860`, from
  `https://archive.org/download/redhat-6.2_release/zoot-i386.iso`; staged at
  `/data/assets-staging/redhat62/` (labhost path)

## Device set

`redhat62-kickstart-cirrus-slirp`: `qemu-system-x86_64`, `pc-i440fx-11.0`,
`-cpu host`, 256 MB RAM, 1 vCPU, `-vga cirrus` (Cirrus GD5446), one IDE hard
disk (qcow2, 4 GiB), one NIC (`ne2k_pci` on user-mode SLIRP, no default route
beyond the loopback X forward — no retronet tap on this station yet).

## Install route

Unattended kickstart, no manual steps but one: the installer boots with
`text ks=floppy ide=nodma` off a 1.44 M FAT floppy image built with
`mformat -C -f 1440 -i ks.img ::` and `mcopy -i ks.img ks.cfg ::ks.cfg`,
reading `scripts/build-guests/assets/redhat62/ks.cfg`. On a blank disk
anaconda still shows one interactive prompt, "Bad Partition Table →
Initialize" — Enter accepts it. The kickstart partitions with a 1800 MB `/`
and 128 MB swap, installs Base + X Window System + GNOME + KDE + Games +
Graphics Manipulation + Multimedia Support + Mail/WWW/News Tools plus
`XFree86-SVGA`, and its `%post` section:

- creates the `gallery` account (`useradd gallery`, password `gallery` via
  `passwd --stdin`)
- sets `/etc/sysconfig/desktop` to `GNOME`
- writes `/etc/X0.hosts` = `10.0.2.2` and appends `10.0.2.2 slirphost` to
  `/etc/hosts`
- symlinks `/etc/X11/X` to `XF86_SVGA` and writes a full `/etc/X11/XF86Config`
  for the Cirrus GD5446 at 1024x768, depth 16 (with an 8-bit fallback mode),
  PS/2 pointer with 3-button emulation
- flips the default runlevel to 5 and replaces the `x:5:respawn:` line in
  `/etc/inittab` with `su - gallery -c "/usr/X11R6/bin/startx"`, so X respawns
  automatically as the unprivileged gallery user rather than through a
  display manager

## The kernel 2.2.14 IDE PIO wall (measured)

This kernel writes the emulated IDE disk in 512-byte PIO — under KVM that
measures at roughly 53 writes/s (~27 KB/s), one KVM exit per 16-bit `outw` to
port `0x1f0`, ~28 us each (measured with `perf kvm stat` and HMP
`info blockstats`). A tmpfs-backed disk image, `kernel-irqchip=off`,
`-cpu pentium3`, and the `ide0=dma` boot option each made no material
difference to that rate. Under `-accel tcg` the same guest does roughly
1100 writes/s (~550 KB/s) — about 20x faster, because TCG does not pay a KVM
vmexit per port I/O. **The kickstart install therefore ran under TCG.**
The production station runs **KVM**: on the installed uniprocessor kernel,
`hdparm -d1` engages PIIX bus-master DMA and the PIO path is never taken — see
Checkpoint below.

## Pointer and input

x11warp, as on `sunos414` and `amix`: the daemon reaches into the guest's own
X server over the loopback SLIRP hostfwd `127.0.0.1:6081` → `10.0.2.15:6000`
(`SH_X11WARP_DISPLAY=127.0.0.1:81`), moving the pointer with `XWarpPointer`
and reading it back with `XQueryPointer`. Access is granted only by the
golden's `/etc/X0.hosts` entry (`10.0.2.2`) — never `xhost +`. Buttons and
keys go over PS/2 via QEMU, not through the X connection.

## Reset

`loadvm golden` via HMP, never an in-guest channel — see
`streamhost/stations/redhat62/qemu-streamhost.sh`, which refuses to launch if
the qcow2 is missing the internal `golden` snapshot.

## Accounts

- `root` / `redhat62` (kickstart `rootpw`)
- `gallery` / `gallery` (kickstart `%post` — the account the framebuffer runs
  as)

These are private-gallery credentials only, per `ks.cfg`; they are never
exposed to visitors.

## Checkpoint

Baked 2026-09-03 03:18:53Z by the golden stream, under **KVM, `-cpu host`** —
the production launcher's device set. `qemu-img snapshot -l`: ID 1 `golden`,
**VM_SIZE 86.4 MiB, VM_CLOCK 0000:03:39.425**. Disk
`/data/gallery-guests/RedHat62/redhat62.qcow2` (683 MB apparent).

Scene: GNOME 1.0.55 + Enlightenment at 1024x768x16 as `gallery`, the GNOME Help
Browser on "Red Hat Online Help" and gmc on `/home/gallery` (GNOME restored its
saved session). Restore proof: kill, relaunch with `-loadvm golden`, `cont` →
desktop back in 3 s on the framebuffer. x11warp: the X11 handshake from labhost
to `127.0.0.1:6081` answers success with only `/etc/X0.hosts = 10.0.2.2`;
`XWarpPointer` to (100,100), (900,700) and (300,650) each read back exactly by
`XQueryPointer`, cursor seen at every target. Keystrokes reached an X window and
every VT login. Cold power-on → settled desktop: 93 s under KVM.

**Why KVM after all.** The PIO wall above belongs to the **SMP kernel**: anaconda
saw QEMU's MP tables and installed `kernel-smp` as LILO's default `linux` label
even at `-smp 1`, and that kernel loops on `hda: lost interrupt` through the
IO-APIC (forever under TCG, ~30 s stalls under KVM). The uniprocessor kernel
`linux-up` (2.2.14-5.0), now the LILO default in the golden, boots with zero lost
interrupts, and `hdparm -d1 /dev/hda` in `rc.local` engages PIIX DMA:
`using_dma = 1`, `hdparm -t` 62.75 and 69.57 MB/s, `info blockstats` shows 64 MB
in ~1000 ops. `noapic` (suse64's fix for the SMP kernel) was not needed.

Unproven: PS/2 mouse *clicks* were not exercised; `xset s off` in `~/.Xclients`
is on disk but the screensaver was never observed to be off; `%post` running
`/sbin/lilo` assumes anaconda writes `lilo.conf` before `%post` (builder must
confirm on a fresh run).

## Open items

- No retronet join yet (no NIC path beyond the loopback X forward).
- No `demoProgram` defined.
- Mouse clicks and the screensaver-off state are unproven (see Checkpoint).
