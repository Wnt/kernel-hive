# suse64 guest — SuSE Linux 6.4, KDE 1.1.2 on kernel 2.2

Status: **integrated 2026-09-02** in a parallel wave
([`lab/SUSE64-WAVE.md`](../lab/SUSE64-WAVE.md)). Media is sourced and hashed;
the disk is built by `scripts/build-guests/tiles/suse64.sh`; the golden and its
bake are the golden stream's to prove and record below.

## What it is

SuSE Linux 6.4 (March 2000) is the last of SuSE's 6.x line, the German-language
Slackware-derived distribution sold as a six-CD retail box with a 444-page
manual. It carries kernel 2.2.14, XFree86 3.3.6 (with 4.0 supplied alongside),
KDE 1.1.2 as the default desktop, GNOME 1.0.x, StarOffice 5.1 and Netscape
Communicator 4.7, installed and administered through SuSE's own **YaST** — text
mode (YaST1) plus, new in this generation, a graphical front end (YaST2) that
runs the first install.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `suse64`
- Display name: **SuSE Linux 6.4**
- Reserved slot / UDP port / VMID label: `180` / `54180` / `180`
- Archetype: `beige-tower-crt`; era year **2000** (`museum.era_year`), lineage
  `SuSE Linux (Slackware-derived, Nuremberg 1992) → SUSE Linux → openSUSE /
  SUSE Linux Enterprise`
- Arch: i386
- Media: archive.org item `suse-linux-6.4`, `suse-linux-6.4-cd1.iso` —
  663 029 760 bytes, sha256
  `5a835e4bba03485f17f31d6b8204881a77c1206571b27e8300c889e8bf721a33`; staged at
  `/data/assets-staging/suse64/` (labhost path) with `MANIFEST.sha256`. Only
  CD1 is used — the install and the default "Default" package set both fit on
  it.
- Credentials: user `gallery`/`gallery`, root password `gallery`
  (`credentialsRef: guest/suse64` — values live in the credential store, never
  in this repo).

## Build and device set

- Builder: `scripts/build-guests/tiles/suse64.sh` (`build.rows` key `suse64`,
  class `heavy`, `~20-30m`, `automation: vision`)
- Canonical output: `suse64.qcow2` (CD1 YaST2 install + KDE 1.1.2 golden),
  staged to `/data/gallery-guests/SUSE64/suse64.qcow2`; the launcher copies it
  to the station dir on first start
- Runtime path: `/data/vms/streamhost/stations/suse64/disk.qcow2` — the ONLY
  block device
- QEMU: `/opt/qemu-beos/bin/qemu-system-x86_64` (QEMU 11.0.2, the same build
  the `beos`/`pcgeos` stations run), `pc-i440fx-11.0,acpi=off`, KVM (the install ran under TCG, see "The wall" in the wave doc; the kernel boots with `noapic`), `-cpu
  host`, 256 MB RAM, 1 vCPU, `-vga cirrus`, one IDE qcow2 (4 GiB), `ne2k_pci`
  on SLIRP with a loopback X forward `127.0.0.1:6080 -> 10.0.2.15:6000`
  carrying the pointer's X connection, no audio device
- Pointer: **absolute**, `x11warp` — motion goes through the guest's own X
  server over that loopback forward (`SH_INPUT_BACKEND=x11warp`,
  `SH_X11WARP_DISPLAY=127.0.0.1:80`); buttons and keys ride PS/2. Single
  injector: nothing else may move this pointer.
- Reset: `loadvm golden`

## Install, measured on the golden stream

CD1 boots straight into the graphical **YaST2** installer at 640x480 under
KVM; the 2.2.14 install kernel sees `hda` (QEMU HARDDISK, 4096 MB), `hdc`
(ATAPI CD) and `fd0`. YaST2 is keyboard-driven throughout — Alt-N for Next,
Alt-Y for Yes/install — the relative mouse does nothing useful inside it.
Auto partitioning of the whole 4 GiB `hda` gives `hda1` `/boot` ext2, `hda2`
swap, `hda3` `/` ext2. The **"Default"** package selection (655 MB, includes
X11 and KDE — "Minimal" excludes X) is what this station installs. LILO is
written to the MBR.

**Trap:** `mke2fs` of the 4 GiB ext2 root took ~17 minutes, because the 2.2
kernel drives the IDE disk in 512-byte PIO writes on a single vCPU under this
device set. A rebuild should create the disk smaller — 1.5–2 GiB — to avoid
paying that cost again.

## Golden, input, and rollback

- Reset mode: `loadvm golden`, snapshot tag `golden`
- Fixture: a KDE 1.1.2 desktop at 1024x768x16 (XFree86 3.3.6 SVGA on Cirrus),
  reached by console autologin into `startx`, with `kpanel` and a `konsole`
  open — see the Checkpoint section below for the bake that produces it
- Pointer/click/drag/wheel/keyboard proof: TODO(golden) — to be recorded when
  the golden stream proves the x11warp path against the baked snapshot
- Cold-boot zero-input state and optional clip: TODO(golden)
- Credentials reference only (never values): `guest/suse64`
- Rollback plan: `git revert` the landing commit and drop the `suse64` row
  from the registry; the golden disk and its staged copy under
  `/data/gallery-guests/SUSE64/` are the only host-side artifacts, and neither
  is shared with another station

## Checkpoint

The install (YaST2, package set, disk layout, LILO, `mke2fs` timing) above is
proven on the golden stream's smoke boot. The desktop configuration below is
the plan the golden bake follows; it becomes fact once that bake completes and
the coordinator fills in the placeholder line.

`/etc/XF86Config` runs the XFree86 3.3.6 SVGA server on the Cirrus card at
1024x768x16, with the mouse on PS/2 (`/dev/psaux`). `tty1` autologs in as root
(`mingetty --autologin root`) and `.bash_profile` runs `exec startx`.
`.xinitrc` is:

```
xset s off -dpms
xhost +10.0.2.2
konsole &
exec startkde
```

`xhost +10.0.2.2` is what lets the x11warp pointer reach the guest's X server
from the host side of the loopback forward on every restore.

TODO(golden): VM_SIZE, VM_CLOCK, bake date, X server line

## Host-native capture path

**Tier 1**, direct-QEMU, KVM-accelerated with `noapic` (the install itself ran under TCG: the 2.2 IDE PIO wall makes a KVM install 20x slower). The guest's VGA framebuffer is
captured straight off QEMU's dbus display and input goes straight in through
QMP plus the x11warp loopback — no kiosk, bridge or second VM in the path.

## Known gaps / next

- **Golden bake not yet recorded here.** The measured facts above cover the
  install; the desktop configuration, the bake itself and its restore proof
  are the golden stream's, to be filled in against the `TODO(golden)` line.
- **No exec channel.** As with several of the fleet's small stations, there is
  no ssh/serial path in — everything is QMP keys/mouse plus the x11warp
  pointer and the framebuffer.
- **Network beyond the X forward not evaluated.** `ne2k_pci` is present on
  SLIRP for the pointer's loopback X connection; joining retronet is a
  follow-up, not part of this wave.
