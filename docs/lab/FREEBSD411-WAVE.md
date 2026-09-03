# freebsd411 wave — FreeBSD 4.11 + KDE 3.3.2 as a live station

Coordinator: session `job-a41b2067` (Claude Fable 5.1). Operator's ask, 2026-09-02:
"a new record in how fast we can integrate a new station … FreeBSD 4.x with a
graphical interface with easily discoverable basic apps preloaded". The
procedure is [`ADD-NEW-OS-PLAYBOOK.md` §0](ADD-NEW-OS-PLAYBOOK.md); this doc is
the ledger every stream branches from. Landing is serialized through the
"os station integrations coordination" session (message "ready to land
freebsd411" before any push to main; wait for "go").

## Allocation (claimed via smoke-rig.sh / kh-claim under KH_SESSION=freebsd411)

| Value | freebsd411 | Hands-off neighbours |
|---|---|---|
| slot / UDP / VMID | **178 / 54178 / 178** | 174 bootos, 175 pcgeos (live); 176 netbsd14, 177 openbsd, 179 pcbsd (in flight) |
| X11 warp forward | loopback **6078 → 10.0.2.15:6000**, `SH_X11WARP_DISPLAY=127.0.0.1:78` | :76 netbsd14, :79 pcbsd |
| render orders | as the scaffold assigned (`stations-registry.py new --like netbsd14 --slot 178`); duplicates vs other waves are fixed in OUR entry at landing | — |
| station dir | `/data/vms/streamhost/stations/freebsd411` | — |
| smoke rig | `/data/vms/sandbox/freebsd411/smoke` (qmp.sock, disk.qcow2 4G, `/os/freebsd411` dark-launched) | — |
| guest output | `/data/gallery-guests/FREEBSD411/freebsd411.qcow2` | — |

## Measured facts (never copy from a README)

| Fact | Value |
|---|---|
| Media | `4.11-RELEASE-i386-disc1-kde.iso` from `http://ftp-archive.freebsd.org/pub/FreeBSD-Archive/old-releases/i386/ISO-IMAGES/4.11/` (https fails: certificate name mismatch) |
| Size | **663 328 768 bytes** (`stat -c %s`, labhost `/data/assets-staging/freebsd411/`) |
| Publisher MD5 | `84921fe6b6b4bfd3f7011788985d34e2` (`CHECKSUM.MD5` in the same dir) |
| SHA-256 | in `/data/assets-staging/freebsd411/MANIFEST.sha256` (labhost mount; NOT visible under the same path in CT950 — read it over `ssh lab`) |
| Contents | base + XFree86 **4.4.0** + KDE 3.3.2 packages on ONE disc (that is why this variant, not `disc1-gnome` or `miniinst`); the KDE meta on the disc is `kde-lite-3.3.2` (there is no `kde-3.3.2`) |
| Device set | `/opt/qemu-beos/bin/qemu-system-x86_64`, `-enable-kvm -m 256 -smp 1 -machine pc-i440fx-11.0,acpi=off -cpu host -rtc base=localtime -boot c -vga std -display dbus,p2p=on`, **one SCSI qcow2 disk** `-device lsi53c895a,id=scsi0 -drive file=disk.qcow2,format=qcow2,if=none,id=hd0 -device scsi-hd,bus=scsi0.0,drive=hd0`, `-netdev user,id=n0,hostfwd=tcp:127.0.0.1:6078-10.0.2.15:6000 -device ne2k_pci,netdev=n0`. NOT IDE: see §Golden |
| Disk I/O under KVM | IDE: `atapci0: Busmastering DMA not supported`, `ad0 … BIOSPIO` — 4.11's ata driver gets no bus-master DMA on QEMU's PIIX3, and 16-bit PIO under KVM is one exit per word: cirrus/ATAPI-PIO install read 67 KB/s, `hw.ata.atapi_dma=1` 162 KB/s, SCSI CD + IDE disk 144 KB/s. SCSI disk on lsi53c895a (`sym0`, "3.300MB/s transfers, Tagged Queueing"): KDE boots to desktop in 74 s. The INSTALL ran under `-accel tcg,thread=single -cpu pentium3` (PIO is cheap without exits: newfs 2.9 MB/s, bin+X dists in ~2 min, whole install ~25 min) and the installed disk was moved to the KVM set |
| Smoke proof | Kernel Configuration Menu → Enter → sysinstall main menu, 720×400 text frame, ~15 s after Enter (frames in the smoke rig's `shots/`) |

## Design decisions (pre-decided; a stream that measures otherwise corrects THIS table in its commit)

- **Reset = `loadvm golden`** on `disk.qcow2`, the only block device (the netbsd14 route).
- **Pointer = x11warp absolute** into the guest XFree86 4.3 server: the golden must
  carry `xhost +10.0.2.2` (never `xhost +`) and the X server must listen on TCP
  (XFree86 4.4.0's `startx` sets `listen_tcp="-nolisten tcp"` at line 50 — measured; the golden blanks it).
  Buttons + keys ride PS/2 over D-Bus. `moused` on `/dev/psm0` → `/dev/sysmouse`.
- **Display**: `-vga std` + XFree86 4.4.0 `vesa`, 1024×768, depth 16 — worked first try (the cirrus route was never needed).
- **Session**: console autologin as root into `startkde` (or `kdm` autologin); KDE
  first-run wizard (kpersonalizer) and Kandalf tips suppressed; Konsole open; panel visible.
- **Kernel**: GENERIC 4.11 booted with ACPI disabled by the machine (`acpi=off`); if the
  installed system's boot differs from the smoke boot, STOP and race it (rule 14, `rig-clone.sh`).
- **Key pacing**: fleet floor 40/40; no bisect.
- **Audio**: none declared.

## Streams (each: `scripts/dev/wt.sh new freebsd411-<stream> --from freebsd411`, 4-minute stop is aspirational — the install itself is the long pole)

| Stream | Model | Owns | Notes |
|---|---|---|---|
| `golden` | Fable/Opus | the smoke rig install (sysinstall → KDE), X config, autologin, `xhost`, bake `golden`, one `loadvm` restore proof, stage disk into the station dir, `scripts/coldboot/freebsd411-bootrec-arm.sh`, `station.env.fixture` checkpoint facts, `registry` runtime/reset truth | Shares the X+KDE tail with the pcbsd wave (FreeBSD 6.3 + KDE 3.5, display :79) — whoever solves a piece first messages the other |
| `build` | sonnet-low | `scripts/build-guests/tiles/freebsd411.sh`, `scripts/build-guests/check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` rows | Pins the URL, MD5, SHA-256, size above; assisted install documented in the header |
| `spa` | Fable | `registry/posters/freebsd411.md`, hero `spa/public/posters/freebsd411/desktop.webp` (replace the sysinstall placeholder with the KDE desktop once golden has it), `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` prose | Only stream that edits visitor-facing prose |
| `docs` | sonnet-low, after golden reports | `docs/guests/freebsd411.md`, `docs/lab/GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index | §Checkpoint from golden's report |

Push recipe for every stream (feature branch, no gate):

```
cd /data/vms/sandbox/freebsd411-<stream>/repo
git add -A && git commit -m "freebsd411 <stream>: …"
SKIP_GATE=1 GIT_SSH_COMMAND="ssh -i /home/wnt/.ssh/id_github -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20" git push origin HEAD:freebsd411-<stream>
```

## Golden — what worked (golden stream, 2026-09-03; the pcbsd wave copies this tail)

Install (sysinstall, from the disc1-kde ISO as `-cdrom`, `-boot d`), run on a rig-clone under
`-accel tcg,thread=single -cpu pentium3` because KVM PIO crawls (table above): Standard →
fdisk `a` `q` → boot manager **Standard** → disklabel `a` `q` (auto: / 128M, swap 496M,
/var 256M, /tmp 256M, /usr 2959M) → distributions **X-User** (not All: no sources), ports
**No** → media CD/DVD → commit. ~12 min to the "Congratulations" dialog. Post-install:
ethernet **Yes** on `ed0`, IPv6 No, DHCP Yes yields nothing under the installer, so the
form is filled **statically** (host `freebsd411`, gateway `10.0.2.2`, DNS `10.0.2.3`,
`10.0.2.15/255.255.255.0` — the netmask field auto-fills, clear it before typing);
gateway/inetd/anon-ftp/NFS server/NFS client/security profile/console/timezone/Linux: **No**;
mouse **Yes** → Enable (moused on `/dev/psm0`, `/dev/sysmouse`) → Exit; X configurator
**No**; packages **Yes** → All → `kde-lite-3.3.2` (pulls kdebase, kdelibs, kdeartwork,
kdeadmin, kdemultimedia, kdepim, kdeutils, kdeaccessibility) + `kdegames-3.3.2` +
`kdegraphics-3.3.2_1` → Install (~8 min); users **No**; root password `kernelhive`;
config menu **No**; Exit Install → reboot → kill the clone once it is back on the CD menu.

Then the disk moved to the KVM rig with the shipping set and, at the console as root:

```
# /etc/rc.conf (append)              # /etc/hosts (append)
sendmail_enable="NONE"               10.0.2.15 freebsd411.local freebsd411
blanktime="NO"
# /etc/fstab: sed -i '' 's|/dev/ad0|/dev/da0|g'   (the shipping disk is SCSI, see above)
# /etc/gettytab (append)             # /etc/ttys
Al|Autologin:al=root:tc=Pc:          ttyv0 "/usr/libexec/getty Al" cons25 on secure
# /root/.login (append; root's shell is csh)
if ( `tty` == /dev/ttyv0 ) then
  startx; logout
endif
# /root/.xinitrc
xset s off
xset -dpms
xhost +10.0.2.2
exec startkde
# /usr/X11R6/bin/startx line 50:  listen_tcp=""     (was "-nolisten tcp")
```

`/etc/XF86Config` (47 lines): ServerLayout `kh` with Screen0 + Mouse0 (CorePointer) +
Keyboard0 (CoreKeyboard); Files: misc, 75dpi, 100dpi, Type1 font paths; Module: dbe,
extmod, freetype, type1; InputDevice Keyboard0 Driver "keyboard"; InputDevice Mouse0
Driver "mouse", Protocol "auto", Device "/dev/sysmouse"; Monitor HorizSync 30-80,
VertRefresh 50-90; Device Card0 Driver "vesa"; Screen0 DefaultDepth 16, Display Depth 16
Modes "1024x768".

KDE suppression, in `/root/.kde/share/config/`: `kpersonalizerrc` `[General] FirstLogin=false`;
`ktiprc` `[TipOfDay] RunOnStart=false`; `kdesktoprc` `[ScreenSaver] Enabled=false`;
`kcmartsrc` `[Arts] StartServer=false` (no sound device). Konsole at login:
`/root/.kde/Autostart/konsole.desktop` (`[Desktop Entry] Type=Application Exec=konsole
Name=Konsole`). Sendmail must be NONE or every cold boot stalls twice for 60 s on the
unqualified host name.

## Timeline (measured after landing with `scripts/dev/session-timeline.py`)

TODO(coordinator).
