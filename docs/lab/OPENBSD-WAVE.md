# openbsd wave — OpenBSD 7.9 amd64 (2026), fvwm desktop from base, absolute pointer

Operator ask (2026-09-03): "a new record in how fast we can integrate a new
station … OpenBSD with FVWM with some easily discoverable apps as the golden
scene". Procedure: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0. Sibling: `alpine`
(device set). Coordinator session: this wave ran beside netbsd14 (176),
freebsd411 (178), pcbsd (179); landings serialised through the coordination session.

## Allocation ledger (claimed by kh-claim under KH_SESSION=openbsd)

| Value | Assigned |
|---|---|
| id / stationDir / SH_STATION | `openbsd` |
| slot / UDP / VMID | 177 / 54177 / 177 |
| loopback HTTP (install only) | 127.0.0.1:8079 (`kh-claim port 8079`), released with the smoke rig |
| render orders | as assigned by `stations-registry.py new --like alpine --slot 177` |
| QEMU | host `qemu-system-x86_64` (pve 11.0.2), `pc-i440fx-11.0`, KVM, `-cpu host`, 1024 MB, **1 vCPU** (2 lose keyboard interrupts, see below), `-vga none -device VGA,edid=on,xres=1024,yres=768`, one virtio qcow2 (4 GiB), `virtio-net-pci` on SLIRP, `-usb -device usb-tablet`, AC97 |
| Release | OpenBSD 7.9 amd64 (released 2026-05; kernel `GENERIC.MP #449`, built Wed May 6 2026) |
| Media | mirror `https://ftp.spline.inf.fu-berlin.de/pub/OpenBSD/7.9/amd64/` (cdn.openbsd.org ran at 0.8 MB/s from labhost, fu-berlin at 59 MB/s): `cd79.iso` 11 829 248 B, `bsd` 32 976 428, `bsd.mp` 33 107 757, `bsd.rd` 4 848 172, `base79.tgz` 535 342 217, `man79.tgz` 8 608 220, `xbase79.tgz` 48 983 459, `xfont79.tgz` 23 575 522, `xserv79.tgz` 12 098 678, `xshare79.tgz` 4 672 246, `SHA256`, `SHA256.sig`; every file matches the release `SHA256` (sha256sum on labhost) and the installer signify-verifies them against `SHA256.sig`; staged in `/data/assets-staging/openbsd79/` |
| Install | UNATTENDED: `cd79.iso` boots bsd.rd; at the `(I)nstall … (A)utoinstall` prompt type `a`, at `Response file location?` type `http://10.0.2.2:8079/install.conf`; sets over HTTP from the same loopback server (`python3 -m http.server 8079 --bind 127.0.0.1` on labhost, 10.0.2.2 from the guest), `Set name(s) = -comp* -game* +site* done`, `site79.tgz` carries the whole desktop config; `Exit to … = halt` (QEMU stays up at the halt screen — kill by pidfile, relaunch `-boot c`) |
| Guest config (site79.tgz) | `/install.site` (ttys ttyC0 -> `/root/kh-autologin`, `xenodm_flags=NO smtpd_flags=NO ntpd_flags=NO`), `/root/kh-autologin` (`login -f root` — OpenBSD getty has no autologin capability), `/root/.profile` (`exec startx` on ttyC0), `/root/.xinitrc` (xset s off -dpms; xterm 80x24+16+40, xclock -16+16, xeyes -16+150, xcalc -16-16; exec fvwm), `/root/.fvwmrc` (= `.fvwm2rc`; RootMenu on buttons 1/3, WindowList on 2), `/etc/X11/xorg.conf.d/10-kh-tablet.conf` (below) |
| root password | `kernelhive` (no user account, sshd off) |
| Smoke rig | `/data/vms/sandbox/openbsd/smoke/` (`launch-smoke.sh [d|c]`, `run-daemon.sh`, `site/`, `www/`), published at `/os/openbsd` |

## Measured on the smoke rig (framebuffer)

- bsd.rd installer prompt ~16 s after power-on; the whole autoinstall (sets over
  loopback HTTP, base79.tgz in 15 s, kernel relink) ~2.5 min; first boot to
  `login:` ~50 s (rc.firsttime: ssh keys, fw_update, syspatch probe); later boots
  to the fvwm desktop ~35 s.
- With plain `-vga std` the Xorg **vesa** driver takes the EDID preferred mode
  **1920x1200**; `-vga none -device VGA,edid=on,xres=1024,yres=768` pins 1024x768.
- **Pointer wall (rule 14 theory list):** `usb-tablet` attaches as `ums0` →
  `wsmouse1` (`mouse1.type=touch-panel`). Xorg's wscons autoconfig adds it twice
  — `/dev/wsmouse1` directly and again through the `/dev/wsmouse` mux — and the
  mux has no calibration range, so 0..32767 clamps to the bottom-right corner
  (fvwm menu posted at the corner for every target). Fix = one InputClass file:
  `Option "Ignore" "true"` for `/dev/wsmouse[0-9]*` + `MinX/MaxX/MinY/MaxY`
  0..32767 for `/dev/wsmouse`. Not needed: x11warp, a serial mouse, vmmouse.
- `qmp-type.py` at `--gap 0.05` drops characters on the wscons console; keep
  the default 0.12. `\"` inside typed text arrives as a literal backslash —
  ship config files in the tarball, never type them.
- `login -f root` from `/etc/ttys` works as the console autologin; `kill -HUP 1`
  makes init re-read ttys without a reboot.

## Golden and the two late findings (2026-09-03)

- `savevm golden` on the smoke rig with the station device set: VM_SIZE 911 MiB,
  VM_CLOCK 0001:00:08; `loadvm golden` after a pointer move + click restored a
  pixel-identical frame (PIL diff bbox None). Disk staged to
  `/data/vms/streamhost/stations/openbsd/disk.qcow2` and (same bytes) to
  `/data/gallery-guests/OPENBSD/openbsd.qcow2`.
- **Resolution:** `-device VGA,edid=on,xres=1024,yres=768` did NOT pin Xorg's
  vesa driver (it took 1920x1200); `20-kh-screen.conf` (Monitor PreferredMode +
  Screen Modes "1024x768") does. Both stay.
- **HMP `mouse_move` is relative** and goes to the PS/2 mouse; every "pointer
  wall" frame before the QMP `input-send-event` abs probe was the wrong device.
  With the InputClass the tablet is 1:1 (centre pixel exact, corners within the
  menu title). `smoke/absprobe.py` is the probe.
- **Keyboard under X — SOLVED by a race (rule 14):** with `-smp 2` keys sent
  over QMP `input-send-event` at 40/40 … 200/200 arrived partially ("abcdef" →
  a b f) and lost releases left the kernel's raw-mode autorepeat flooding
  (`xset r off` changed nothing, so not X's repeat); the wscons text console typed
  cleanly; a `usb-kbd` clone lost keys the same way. Theories raced on
  `rig-clone.sh` clones: `-machine pc-i440fx-11.0,acpi=off` and `-smp 1` BOTH
  typed the 40-char line complete at 40/40 → keyboard-interrupt delivery on the
  2-vCPU IOAPIC config, not pacing. Shipped `-smp 1` (ACPI power-off kept),
  fixture pacing at the 40/40 floor, golden re-baked on that device set.
- `system_reset` leaves FFS dirty: single-user needs `fsck -y` before
  `mount -uw /`; DHCP is not up in single-user (`ifconfig vio0 10.0.2.15/24 up;
  route add default 10.0.2.2`).

## Streams (each `wt.sh new openbsd-<stream> --from openbsd`, 4-minute stop)

| Stream | Model | Owns |
|---|---|---|
| golden (coordinator) | Fable | the smoke rig: bake `golden` with the station launcher, one `loadvm` proof, stage `disk.qcow2` into the station dir, `station.env.fixture` pointer facts |
| build | sonnet-low | `scripts/build-guests/tiles/openbsd.sh` (pins above; the site tarball + install.conf + the two QMP prompts), `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` |
| spa | Fable | `registry/posters/openbsd.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts` |
| docs | sonnet-low | `docs/guests/openbsd.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` |

## Timeline (measured after landing with session-timeline.py)

TODO(coordinator)
