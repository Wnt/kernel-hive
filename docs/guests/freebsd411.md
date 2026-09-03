# freebsd411 guest — FreeBSD 4.11-RELEASE i386, KDE 3.3.2 desktop

Status: **integrated 2026-09-02/03** in a parallel wave
([`lab/FREEBSD411-WAVE.md`](../lab/FREEBSD411-WAVE.md)). The media is sourced,
hashed and staged; the install, X/KDE setup and golden bake are the golden
stream's to prove and record.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `freebsd411`
- Archetype: `beige-ibm-pc`
- Release: FreeBSD 4.11-RELEASE, i386, January 2005 — the last release of the
  4.x line. GENERIC kernel, ACPI disabled by the machine (`acpi=off`).
- Reserved slot / UDP port / VMID: `178` / `54178` / `178`
- Upstream: `http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/i386/ISO-IMAGES/4.11/`
  (plain http — the https certificate on this host does not match), file
  `4.11-RELEASE-i386-disc1-kde.iso`.
- License class: **free/open**, BSD license.
- Credentials: `root` / `kernelhive` (`credentialsRef: guest/freebsd411`).

### Media

| property | value |
|---|---|
| ISO | `4.11-RELEASE-i386-disc1-kde.iso` |
| Size | 663 328 768 bytes |
| Publisher MD5 | `84921fe6b6b4bfd3f7011788985d34e2` (`CHECKSUM.MD5`, same archive dir) |
| SHA-256 | `45a6094b377b041194d582c12daa8e6c1809872acb502e9c4a0f7c7cf19e7fd7` |
| Contents | base system + XFree86 4.4.0 + KDE 3.3.2 packages, all on the one disc (why `disc1-kde`, not `disc1-gnome` or a miniinst disc) |
| Staged at | `/data/assets-staging/freebsd411/`, `MANIFEST.sha256` |

## Install log

Boots to the Kernel Configuration Menu → Enter (skip) → sysinstall main menu,
proven on the framebuffer at ~15 s after Enter, 720×400 text.

**The install trap (measured this wave):** sysinstall reads the emulated IDE
CD-ROM at roughly 67–77 KB/s under KVM, because FreeBSD 4.x drives ATAPI with
16-bit PIO and every `outw` is a KVM exit. The loader tunable
`hw.ata.atapi_dma=1` did **not** help — the bottleneck is PIO exits, not DMA
availability. The fix was to run the INSTALL itself under `-accel tcg` (PIO is
roughly 20x faster under TCG than trapped through KVM), then boot the
installed disk under KVM and bake the golden under the shipped KVM launcher.
Per rule 6, the golden, the binary and the device set are one combination —
the accel used for the install run is not part of that triple, only the accel
the golden was baked and is served under (KVM) is.

## Device set

- QEMU: `/opt/qemu-beos/bin/qemu-system-x86_64`, machine
  `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 256 MB RAM, 1 vCPU,
  `-vga std` (XFree86 `vesa`), `-rtc base=localtime`, `-display dbus,p2p=on`.
- Storage: one SCSI `qcow2` (`disk.qcow2`) on an emulated LSI 53c895a (`sym`) — the only block device, and it carries the golden vmstate. Not IDE: the 4.11 `ata` driver gets no bus-master DMA on QEMU's PIIX3 and 16-bit PIO under KVM is one exit per word.
- NIC: `ne2k_pci` on SLIRP, with a host loopback forward
  `6078 → 10.0.2.15:6000` for the X pointer route (below).
- No audio device.
- **No exec channel.** `operator.labctl.exec_kind` is `null`: drive the
  station with `labctl key`/`type`/`shot` and read the framebuffer.

## The pointer is absolute, through the guest's X server

Same route as `netbsd14` and `amix`: no absolute input device and no
hardware cursor from XFree86, so the museum reaches into the guest's own X
server instead of a device.

- Motion: `x11warp` into the guest XFree86 4.4.0 server,
  `SH_X11WARP_DISPLAY=127.0.0.1:78` over the loopback SLIRP forward
  `6078 → 10.0.2.15:6000`. The golden carries `xhost +10.0.2.2` (never
  `xhost +`) so the daemon's connection is allowed; if `startx`/`xinit` ever
  adds `-nolisten tcp` it must be removed, since XFree86 4.3 listens on TCP by
  default and this route depends on that.
- Buttons and keys ride PS/2 over D-Bus (`moused` on `/dev/psm0` →
  `/dev/sysmouse`), not through the X connection.
- Key pacing: fleet floor 40 ms hold / 40 ms gap; not bisected below the
  floor for this station.

## Checkpoint

- `resetMode: loadvm`, snapshot `golden`, carried by `disk.qcow2` — the
  station's only block device.
- Session: console autologin as root into `startkde` (or `kdm` autologin);
  the KDE first-run wizard (kpersonalizer) and Kandalf tips suppressed; a
  root Konsole open; Kicker panel visible.
- Fixture: FreeBSD 4.11 KDE 3.3.2 desktop (XFree86 4.4.0, vesa, 1024×768,
  depth 16) — Kicker panel with the K menu, a root Konsole open, Konqueror,
  Kate, KCalc and kdegames a click away.

- Snapshot `golden` on `disk.qcow2`: VM_SIZE 113 MiB, VM_CLOCK 0003:07:42.509, baked 2026-09-03 06:28:53 under the shipped KVM launcher; restore proven by framebuffer (`uname -a; xhost` typed into the Konsole after `-loadvm golden -S` + `cont`).
- Autologin route: `/etc/gettytab` `Al|Autologin:al=root:tc=Pc:`, `/etc/ttys` `ttyv0 "/usr/libexec/getty Al" cons25 on secure`, `/root/.login` runs `startx; logout` on ttyv0, `/root/.xinitrc` = `xset s off; xset -dpms; xhost +10.0.2.2; exec startkde`; `startx` patched to `listen_tcp=""` (4.4.0 ships `-nolisten tcp`). Cold boot to the desktop with no input: ~72 s.
- Quiet boot: `sendmail_enable="NONE"`, `blanktime="NO"`, `/etc/hosts` `10.0.2.15 freebsd411.local freebsd411`, static ed0 10.0.2.15/24; KDE: kpersonalizer FirstLogin=false, ktip RunOnStart=false, screensaver off, aRts off, Konsole in `~/.kde/Autostart`. Full file list: `docs/lab/FREEBSD411-WAVE.md` §Golden.

## Operating

For visitors: type into the open root Konsole — `uname -a`,
`ls /usr/local/bin | head`, `kcalc &`. The K menu holds Konqueror, Kate,
KCalc and the kdegames set. The pointer lands where you point (absolute).
Reset restores `disk.qcow2` to the golden checkpoint.

## Known limits

- No audio device declared.
- No exec channel — driven entirely through QMP keys/pointer and the
  framebuffer, same as `netbsd14`.
- Shares the X + KDE bring-up tail with the `pcbsd` wave (FreeBSD 6.3, KDE
  3.5.8, display `:79`) — the two waves coordinate on whoever solves a piece
  first.

## Retronet

`freebsd411` joined the retronet on **2026-09-03** through a **second, bridged
NIC** — `rtl8139` on tap `freebsd411rn0` on `vmbr-rn`, guest `rl0`, DHCP-reserved
**10.99.0.35**, DNS `10.99.0.2`, no default gateway. The station's original slirp
`ne2k_pci` is unchanged and now carries **only** the x11warp pointer forward
(`6078 → 10.0.2.15:6000`), because OSCAR cannot traverse slirp and the NE2000's
16-bit PIO is as slow under KVM as the IDE path this station already avoids.

- **Web plane — proven.** Konqueror 3.3.2 renders `http://search.retronet/` with
  no proxy configured: DHCP hands it the gateway as its resolver, every name
  resolves to `10.99.0.2`, and the gateway's `:80` origin serves the museum
  corpus by `Host`. Frame:
  `/data/vms/streamhost/stations/freebsd411/evidence/retronet-konqueror-search-retronet-20260903.png`.
- **Addressing — proven.** A cold boot of the new launcher set plus
  `ifconfig_rl0="DHCP"` in `/etc/rc.conf` takes the **reserved** address:
  `ifconfig rl0` → `inet 10.99.0.35 netmask 0xffffff00`.
- **ICQ plane — wired, not signed in.** Kopete 0.9.1 is installed
  (`kdenetwork-3.3.2` from the FreeBSD 4.11 package archive — it is **not** on the
  `disc1-kde` ISO), the gateway account UIN **17800** exists and is open, and its
  server-side SSI roster already carries **HiveBot**. The client's Add-Account
  wizard is filled but not finished, so no login has reached the gateway and the
  roster row stays `onboarded: false`.
- Containment is the fleet pattern: `streamhost/stations/freebsd411/rn-tapnet.sh`
  creates the persistent tap and the fail-closed `FREEBSD411RN-IN` chain (scoped
  to both the guest IP and its MAC) on every launcher start.

The new NIC is a **new device set**, so the golden must be re-baked by a cold
boot on the new launcher before this ships. Full detail, and the list of what is
still open: [`docs/lab/retronet/STATION-freebsd411.md`](../lab/retronet/STATION-freebsd411.md).
