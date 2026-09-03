# redhat62 wave — Red Hat Linux 6.2 "Zoot" (2026-09-03)

Speedrun add of an early Red Hat Linux with a graphical desktop, run as one of
six concurrent station waves (coordinator session allocates slots; landing on
main is serialized through it). Procedure: `ADD-NEW-OS-PLAYBOOK.md` §0.

## Allocation ledger (claimed by smoke-rig.sh under KH_SESSION=redhat62)

| Value | Allocation |
|---|---|
| id / stationDir / SH_STATION | `redhat62` |
| slot / UDP / VMID label | 181 / 54181 / 181 |
| x11warp loopback forward | host `127.0.0.1:6081` → guest `10.0.2.15:6000`, `SH_X11WARP_DISPLAY=127.0.0.1:81` |
| sibling | `redstar2` (QEMU x86 Linux desktop, IDE qcow2, `loadvm golden`) |
| device set | `redhat62-kickstart-cirrus-slirp`: `pc-i440fx-11.0`, `-cpu host`, 256 MB, 1 vCPU, `-vga cirrus`, hda qcow2 4 GiB, `ne2k_pci` on SLIRP with the loopback X forward |
| media | `zoot-i386.iso` 671881216 B, sha256 `dc8a1c86cc3389768af207101ecdc8f44e61bc8a5044cfb5fe0efb67eeaa9860`, from `https://archive.org/download/redhat-6.2_release/zoot-i386.iso`; staged at `/data/assets-staging/redhat62/` (labhost path) |
| install | unattended kickstart: `scripts/build-guests/assets/redhat62/ks.cfg` on a 1.44 M FAT floppy (`mformat -C -f 1440 -i ks.img ::; mcopy -i ks.img ks.cfg ::ks.cfg`), boot line `text ks=floppy ide=nodma`; the only prompt is "Bad Partition Table → Initialize" on a blank disk (Enter) |
| desktop | GNOME 1.0.55 + Enlightenment (`/etc/sysconfig/desktop=GNOME`), XFree86 3.3.6 `XF86_SVGA` on cirrus, 1024x768x16; runlevel 5 with the `x:5:respawn` line replaced by `su - gallery -c startx` |
| pointer | x11warp (as sunos414/amix): `/etc/X0.hosts` = `10.0.2.2`, `/etc/hosts` names `slirphost`; buttons/keys PS/2 via QEMU |
| accounts | root `redhat62`, gallery `gallery` (private gallery; ks.cfg is the source) |
| smoke rig | `/data/vms/sandbox/redhat62/smoke/` (disk.qcow2, qmp.sock, hmp.sock, ks.img), published at `/os/redhat62` |
| station disk | `/data/gallery-guests/RedHat62/redhat62.qcow2` (golden inside) |

## Streams (each `wt.sh new redhat62-<stream> --from redhat62`, 4-minute stop)

| Stream | Model | Owns |
|---|---|---|
| golden | Fable | finish the kickstart install on the smoke rig, first X desktop, scene, `savevm golden`, restore proof, stage disk to the station path; `station.env.fixture` comment facts; `scripts/coldboot/redhat62-bootrec-arm.sh` |
| build | sonnet-low | `scripts/build-guests/tiles/redhat62.sh` (pinned fetch, sha256, ks floppy, unattended install, golden), `ASSETS-MANIFEST.md`, `os-media-catalog.md` rows |
| spa | Fable | `registry/posters/redhat62.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` |
| docs | sonnet-low (after golden) | `docs/guests/redhat62.md`, `GUEST-TIERS.md`, release-notes JSON, `docs/README.md` |

Shared fleet files: append own rows only, never reorder neighbours.

## Timeline (measured after landing with session-timeline.py)

- 02:00 operator message (box clock) · 02:01 ISO staged · 02:04 installer booted in the sandbox · 02:08 `/os/redhat62` published (smoke rig) · TODO(coordinator)

## Golden stream findings (2026-09-03, Fable; every item framebuffer-proven on the smoke rig)

- **ACCEL = KVM, `-cpu host`.** The PIO wall in the ledger is real but it is the
  *SMP* kernel's: anaconda sees QEMU's MP tables and installs `kernel-smp` as
  LILO's default label `linux` even at `-smp 1`. That kernel routes IDE IRQ14
  through the IO-APIC and loops on `hda: lost interrupt` — forever under TCG,
  ~30 s stalls per burst under KVM (a forced fsck of the 4 GiB disk was at 20 %
  after 8 min). The UP kernel `linux-up` (2.2.14-5.0) boots cleanly under both:
  `dmesg | grep -c "lost interrupt"` = 0. With `hdparm -d1 /dev/hda` (rc.local)
  KVM reports `using_dma = 1 (on)` and `hdparm -t` 62.75–69.57 MB/s (two runs);
  `info blockstats` went 64 MB in ~1000 ops during the test (DMA-sized) against
  the ~870 B/op average of the PIO boot. Cold boot power-on → settled desktop:
  **93 s** under KVM. `linux noapic` (suse64's cure) was not needed and not tried.
- **`sed -i` does not exist in RH 6.2** (GNU sed 3.02): both ks.cfg inittab edits
  silently did nothing — the disk came up `id:3` with `x:5:respawn:/etc/X11/prefdm`.
  `%post` now uses `perl -pi -e`. The other `%post` lines (X0.hosts, hosts,
  gallery user, XF86Config, /etc/X11/X) did land.
- **Xwrapper refuses an inittab `su - gallery`:** "Authentication failed — cannot
  start X server. Perhaps you do not have console ownership?" — `/etc/pam.d/xserver`
  uses `pam_console`. Replaced with `pam_permit`; the respawn then started X on
  the next cycle (the failing cycle was 16 s under TCG).
- **XF86Config:** `Chipset "clgd5446"` + `Option "no_bitblt"` in the Device section,
  depth 16 at 1024x768 — text paints in every window (GNOME Help Browser, gmc).
- **x11warp:** handshake from labhost to 127.0.0.1:6081 answers byte 0 = `\x01`
  with `/etc/X0.hosts` = `10.0.2.2` alone (no `xhost +`). Raw-protocol
  `XWarpPointer` to (100,100) and (900,700) read back exactly via `XQueryPointer`,
  cursor seen at each target (`smoke/xwarp.py`, kept in the sandbox).
- **Keyboard:** typed text reached an X window (it landed in the Help Browser's
  location field while X was coming up) and every VT login worked; `ctrl-alt-f2`
  / `chvt 7` switch VTs from QMP.
- **Golden:** `savevm golden` at 03:18:53 UTC, VM_SIZE 86.4 MiB, VM_CLOCK
  0000:03:39.425, scene = Help Browser on "Red Hat Online Help" + gmc on
  /home/gallery (GNOME restored the session it saved at the clean `shutdown -h`).
  Restore-proven: `launch-smoke.sh --loadvm` + HMP `cont` → desktop in 3 s, warp
  (300,650) visible. Staged: `/data/gallery-guests/RedHat62/redhat62.qcow2`
  (683 MB apparent, snapshot ID 1 golden). Hero frame:
  `/data/vms/sandbox/redhat62/smoke/frame-desktop.png`.
- **Installer:** finished at ~23 min of package time under TCG; the ks `%post`
  ran; anaconda's VT2 (`ctrl-alt-f2`) is a root shell over `/mnt/sysimage` — the
  cheapest place to patch the installed tree before the first boot (no chown,
  no clear; `!` history-expands even in double quotes).
- **Unproven / open:** clicks (buttons over PS/2) were not exercised; `xset s off`
  in `~/.Xclients` is in the ks.cfg and the disk but the screensaver was never
  observed either way (the golden is idle-paused between visitors); `%post`
  running `/sbin/lilo` assumes anaconda writes lilo.conf *before* `%post` — the
  build stream must confirm on a fresh kickstart run. The
  `sandbox/redhat62/race/*` rigs (tcg, kvmup, dma, …) are stopped, disks kept.
