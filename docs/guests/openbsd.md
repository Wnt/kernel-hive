# openbsd guest — OpenBSD 7.9, fvwm from base Xenocara

Status: **LIVE** (Tier 1, host-native, KVM), integrated in a parallel wave
([`lab/OPENBSD-WAVE.md`](../lab/OPENBSD-WAVE.md)). The golden bake and its
`loadvm` proof are the golden stream's to record below.

## What it is

OpenBSD 7.9 amd64 (released 2026-05, kernel `GENERIC.MP #449`), the
security-first BSD descended from 4.4BSD-Lite via NetBSD 1.0 — Theo de Raadt
forked OpenBSD 1.2 off NetBSD in 1996, and the project has since given the
world OpenSSH, pf and LibreSSL. This station boots straight to a base-install
X desktop: Xenocara (OpenBSD's own X.Org tree) running the vesa server at
1024x768, fvwm 2.2.5 as the window manager, with xterm, xclock, xeyes and
xcalc up on login — no packages installed, everything from the base sets.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `openbsd`
- Reserved slot / UDP port / VMID label: `177` / `54177` / `177`
- Archetype: `putty-lcd`; era year **2026** (`museum.year`), lineage
  `4.4BSD-Lite → NetBSD 1.0 → OpenBSD 1.2 (1996, Theo de Raadt) → 7.9 (2026)`
- License class: **free/open**, BSD
- Credentials reference only (never values): `guest/openbsd` — root password
  `kernelhive`, no user account, **no sshd** (no exec channel at all).

### Media and pins

Mirror `https://ftp.spline.inf.fu-berlin.de/pub/OpenBSD/7.9/amd64/` (chosen
over `cdn.openbsd.org`, which ran at 0.8 MB/s from labhost vs. 59 MB/s here):

| file | size (bytes) |
|---|---|
| `cd79.iso` | 11 829 248 |
| `bsd` | 32 976 428 |
| `bsd.mp` | 33 107 757 |
| `bsd.rd` | 4 848 172 |
| `base79.tgz` | 535 342 217 |
| `man79.tgz` | 8 608 220 |
| `xbase79.tgz` | 48 983 459 |
| `xfont79.tgz` | 23 575 522 |
| `xserv79.tgz` | 12 098 678 |
| `xshare79.tgz` | 4 672 246 |

Every file matches the release `SHA256` (verified with `sha256sum` on
labhost), and the installer itself signify-verifies the set against
`SHA256.sig`. Staged in `/data/assets-staging/openbsd79/`.

## Install procedure (unattended autoinstall over loopback HTTP)

`cd79.iso` boots `bsd.rd`; at the `(I)nstall … (A)utoinstall` prompt, type
`a`; at `Response file location?`, type `http://10.0.2.2:8079/install.conf`
(`10.0.2.2` is the guest's view of the host under SLIRP). The response file
is served from a plain `python3 -m http.server 8079 --bind 127.0.0.1` on
labhost — loopback-only, install-time only, released with the smoke rig
(`kh-claim port 8079`). The response file sets
`Set name(s) = -comp* -game* +site*` so every base/x set is fetched except
comp and games, plus `site79.tgz` (below) which carries the whole desktop
config as an install-time set. `Exit to … = halt` — QEMU stays up at the
halt screen rather than rebooting on its own; the launcher kills it by
pidfile and relaunches with `-boot c`.

Builder: `scripts/build-guests/tiles/openbsd.sh`.

## Guest config laid down by site79.tgz

- `/install.site` — sets `ttyC0` in `/etc/ttys` to run `/root/kh-autologin`
  instead of `getty`, and disables `xenodm_flags`, `smtpd_flags`,
  `ntpd_flags` (`=NO`).
- `/root/kh-autologin` — `login -f root`; OpenBSD's getty has no built-in
  autologin capability, so this script stands in for it.
- `/root/.profile` — `exec startx` on `ttyC0`.
- `/root/.xinitrc` — `xset s off -dpms` (screen saver and DPMS off), then
  `xterm` at `80x24+16+40`, `xclock -16+16`, `xeyes -16+150`, `xcalc -16-16`,
  `exec fvwm`.
- `/root/.fvwmrc` (= `.fvwm2rc`) — RootMenu bound to buttons 1 and 3, the
  WindowList to button 2.
- `/etc/X11/xorg.conf.d/10-kh-tablet.conf` — the pointer-wall fix, see below.

Config files ship inside the tarball rather than being typed in at install
time: `qmp-type.py` renders `"` as a literal backslash on the wscons
console, which would corrupt any file typed live.

## Device set

`streamhost/stations/openbsd/qemu-streamhost.sh`, QEMU **11.0.2** (host
`pve-qemu-kvm` 11.0.2-1), machine `pc-i440fx-11.0`, KVM, `-cpu host`,
1024 MB RAM, 2 vCPU:

```
qemu-system-x86_64 -name streamhost-openbsd \
  -enable-kvm -m 1024 -smp 1 (two vCPUs lose keyboard interrupts under X; measured 2026-09-03) \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -drive file=$BASE/disk.qcow2,format=qcow2,if=virtio \
  -vga none -device VGA,edid=on,xres=1024,yres=768 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  [-loadvm golden -S] \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off -pidfile $BASE/qemu.pid
```

- **`-vga none -device VGA,edid=on,xres=1024,yres=768`.** With plain
  `-vga std` the Xorg **vesa** driver picks up the EDID's preferred mode,
  which for this virtual monitor is **1920x1200** — far larger than the
  museum's tile. Advertising an EDID that prefers 1024x768 instead pins
  Xorg to that resolution with no guest-side config.
- **`disk.qcow2` is the only block device**, virtio, and carries the
  `golden` vmstate — `savevm`/`loadvm` capture RAM and disk together, so a
  visitor's edits never carry to the next session.
- **`usb-tablet`** for absolute pointer input — see *Pointer wall* below for
  why it needs an extra Xorg config to actually behave that way.
- **AC97** audio into the dbus audiodev.
- **`virtio-net-pci`** on user-mode (SLIRP) networking — install-time only
  (the loopback HTTP set server); the running station has no exec channel.
- **No exec channel.** `operator.labctl.exec_kind` is `null`, `console` is
  `fb`: sshd is off, so the station is driven entirely by QMP keys/mouse and
  proven by reading the framebuffer.

## The pointer wall and its fix

`usb-tablet` attaches inside the guest as `ums0`, which wscons exposes as
`wsmouse1`. Xorg's wscons autoconfig then double-registers it: once as
`/dev/wsmouse1` directly, and again through the `/dev/wsmouse` mux device —
but the mux device carries no calibration range, so its raw 0..32767 axis
clamps every event to the bottom-right corner. The visible symptom was the
fvwm popup menu posting in the same corner regardless of where the tablet
event targeted.

Fix, shipped as `/etc/X11/xorg.conf.d/10-kh-tablet.conf` inside
`site79.tgz` — one InputClass file:

- `Option "Ignore" "true"` for `/dev/wsmouse[0-9]*` (the raw per-device
  nodes, uncalibrated and now ignored).
- `MinX`/`MaxX`/`MinY`/`MaxY` `0`/`32767` for `/dev/wsmouse` (the mux
  device Xorg actually reads), which restores 1:1 absolute mapping.

Not needed to reach this fix, and ruled out along the way: x11 pointer
warping, a serial mouse, `vmmouse`.

## Resolution pin

See the device-set EDID note above — `-device VGA,edid=on,xres=1024,yres=768`
is what keeps the vesa driver off its native 1920x1200 preferred mode.

## Checkpoint

Golden baked by the coordinator; `loadvm` restores RAM + disk together (see
`streamhost/stations/openbsd/station.env.fixture` for the runtime pointer
facts). golden baked 2026-09-03 03:08 on the smoke rig with the station device set: VM_SIZE 911 MiB, VM_CLOCK 0001:00:08; one loadvm restore proven pixel-identical (framebuffer diff empty): record the measured `VM_SIZE` / `VM_CLOCK` from the
coordinator's bake and `loadvm` proof here once landed.

- Snapshot name: `golden`, saved via QMP `human-monitor-command` `savevm golden`.
- Carrier disk: `disk.qcow2` — the ONLY block device — staged at
  `/data/vms/streamhost/stations/openbsd/disk.qcow2`.
- Restore proven: golden baked 2026-09-03 03:08 on the smoke rig with the station device set: VM_SIZE 911 MiB, VM_CLOCK 0001:00:08; one loadvm restore proven pixel-identical (framebuffer diff empty) — one `loadvm` cycle on a sandbox clone, per
  the operator's no-proof-gate rule (a restoring golden is enough).

## Credentials

`root` / `kernelhive`. No user account, no sshd — this is a console-only
autologin box; the password exists for the record, not for any driving path.

## Operating notes

`labctl`: no exec channel — drive via QMP keys and mouse, and read the
framebuffer for proof (rule 9: the framebuffer is the only proof a guest
reacted). fvwm is focus-follows-mouse, so keystrokes go to whatever window
the pointer sits over — move the pointer into the xterm before typing.
Left- or right-click the desktop background for the fvwm RootMenu,
middle-click for the WindowList.

## Rollback

Delete the station's `disk.qcow2` (the only block device, carrying the
golden vmstate) and re-copy from the builder's pristine output:
`/data/gallery-guests/OPENBSD/openbsd.qcow2`.
