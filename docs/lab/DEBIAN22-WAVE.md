# Debian GNU/Linux 2.2 "potato" integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, pcgeos 6/14/18): integrate **Debian
GNU/Linux 2.2 "potato"** (i386, released 2000-08-14; kernel 2.2.17 on the CD (2.2.19 in later point releases), XFree86
3.3.6, GNOME 1.0) as a fully featured Tier-1 host-native station, air-gapped
like redstar2. Branch `debian22` is the ledger; every stream branches from it.
Six other station waves run concurrently (slots 176–181, see the coordinator
memory) — this wave joins their landing queue; **no main push without "go"**.

## Proven in the spine (coordinator, alone, minutes 0–8)

- Media on the box: `/data/assets-staging/debian22/`
  - `debian-2.2-i386-cd1.iso` **659271680 bytes**, sha256
    `2b1d2b18a14ea1f62302aeb98caf1a7b9191a87c3591a42d8bbf0fe5ef1abf1f`
    (archive.org item `Debian-GNULinux-2.2-arch-i386-CD`, file `…-1of3.iso`;
    it is the 2.2 r0 "Official i386 Binary-1" disc, rescue floppy 2.2.16,
    kernel-image 2.2.17pre6-1 on the boot disk)
  - `base2_2.tgz` **15915492 bytes**, sha256
    `2f53ecb6a1508be95d5351e468b0197e8dca2a58ecf24c8fc1e07765b9817585`
    (archive.debian.org `dists/potato/main/disks-i386/current/`)
  - `linux-installer-kernel` **1001341 bytes** (same dir, file `linux`)
- Smoke boot on the device set below: BIOS boots the CD to the `boot:`
  prompt; Enter → boot-floppies 2.2.16 dbootstrap "Release Notes" dialog in
  ~20 s under KVM. Frames: `/data/vms/sandbox/debian22/smoke/frame.png`
  (boot prompt), `frame2.png` (installer). Both are PPM despite the name.
- Dark-launched at `/os/debian22` (rig `/data/vms/sandbox/debian22/smoke/`,
  `run-daemon.sh` restarts the hand-run daemon after every guest relaunch).
  The rig's `disk.qcow2` is an EMPTY 2 GiB qcow2 — nothing installed yet.

## Measured by `debian22-golden` (Fable, 2026-09-02 23:12–23:42, 30-minute budget)

- **cfdisk refuses the empty qcow2** ("FATAL ERROR: Bad signature on partition
  table"): the "Partition a Hard Disk" menu item is a dead end on a blank disk.
  Partition from the tty2 shell (`alt-f2`, Enter) with `fdisk /dev/hda` instead;
  dbootstrap then sees the table. Layout used: **hda1 = cylinders 1–483
  (1947 MB, type 83, bootable), hda2 = 484–520 (149 MB, type 82)**; the
  kernel sees the 2 GiB disk as **CHS 520/128/63**.
- Swap init and mke2fs (ext2, 4 KiB blocks, "no 2.0 compat") go through
  dbootstrap as planned.
- **WALL: guest disk writes run at ~50–80 KB/s.** `mke2fs` on hda1 took
  ~5.5 min for the 15 inode tables and was still "Writing superblocks" 6 min
  later; the qcow2 grows ~2 MB/min. No `lost interrupt` on tty4. The host is
  not the cause (`dd oflag=dsync` 6.7 MB/s on the same ZFS dataset). Raced
  theories (`rig-clone.sh new debian22 <theory>`, each driven to a raw
  `mke2fs /dev/hda1` from tty2): `nodma` (`ide0=nodma`) and `p2cpu`
  (`-cpu pentium2`) were NOT faster (same ~2 MB/min growth); `nodisp`
  (`-display none`) was killed by the coordinator for load before it proved
  anything; **`tcg` (no KVM, `-cpu pentium3`) is the winner: a full
  `mke2fs /dev/hda1` finished in 47 s** (02:26:40 → 02:27:27 on the guest
  clock, frame `shots/race-tcg/m4/cur.png`; its qcow2 grew 21 MB in the same
  60 s in which the KVM rig grew 3 MB) while the KVM rig was still inside the
  same mke2fs after 13 min. So the wall is **KVM + the 2.2.17 boot-floppy
  kernel's 512-byte IDE PIO writes** (suse64 measured the same), not the
  disk, the CPU model, DMA or the display. Untested KVM-preserving theories:
  `-machine kernel-irqchip=off`/`split`, `-cpu host,-x2apic`, a 2.2.19
  kernel-image. Frames: `/data/vms/sandbox/debian22-golden/shots/`
  (control `s*/cur.png`, races `race-*/`). At this rate
  kernel+base+X+GNOME (~300 MB) is hours, not minutes: **the interactive
  install cannot meet the 10-minute bar on this device set** — the
  `debian22-compose` route (populate the ext2 on the host, boot only to bake)
  is the one that fits the budget.
- X was never reached here; whoever builds the disk writes the XF86Config from
  the proven siblings, not from the plan above: Device `Chipset "clgd5446"`,
  `VideoRam 4096`, **`Option "no_bitblt"`** (slackware wave: without it xterm
  text does not paint on XF86_SVGA + GD5446 — the BitBLT path; depth 8 and 16
  both proven with it); Monitor HorizSync 30-64, VertRefresh 50-90, Modeline
  "1024x768" 65 1024 1032 1176 1344 768 771 777 806 -hsync -vsync; Pointer
  PS/2 `/dev/psaux`. Full file: netbsd14's
  `scripts/build-guests/tiles/netbsd14/XF86Config`.
- Nothing installed, no golden baked, no station-dir staging. The rig
  (`/data/vms/sandbox/debian22/smoke/`, now with a `launch-smoke.sh` in the
  rig-clone convention) is left running mid-dbootstrap so the operator can
  see it at `/os/debian22`.

## Allocation ledger (claimed on labhost by session `debian22`)

| Thing | Value |
|---|---|
| id / stationDir / SH_STATION | `debian22` |
| slot / UDP / VMID label | **182 / 54182 / 182** (176–181 belong to the six concurrent waves) |
| render orders | as assigned by the scaffold in `registry/stations/debian22.json` (do not renumber) |
| upstream | archive.org `Debian-GNULinux-2.2-arch-i386-CD` CD1 (hash above); archive.debian.org potato for anything else |
| builder output | `/data/gallery-guests/Debian22/debian22.qcow2` (pristine install, no golden) + `/data/gallery-guests/Debian22/debian-2.2-i386-cd1.iso` |
| station dir | `/data/vms/streamhost/stations/debian22/` — `disk.qcow2` carries the `golden` vmstate; CD1 stays attached |
| device set | `streamhost/stations/debian22/qemu-streamhost.sh` VERBATIM: `pc-i440fx-11.0`, KVM, `-cpu host`, 256 MB, 1 vCPU, IDE disk index 0, IDE CD index 2, `-vga cirrus`, PS/2 mouse+keyboard, `-nodefaults`, no NIC, no USB, no audio |
| screen | 1024x768 16 bpp on Cirrus GD5446 via `XF86_SVGA` (XFree86 3.3.6 has no VESA server) |
| pointer | PS/2 relative (`SH_POINTER=rel`); absolute is a follow-up (no tablet protocol in 3.3.6) |
| desktop | GNOME 1.0 (task `gnome-desktop`); fallback if it will not fit the 4-minute stop: X + Window Maker |
| login | auto-login as `gallery` straight onto the desktop (no gdm chooser in the fixture) |
| credentials | gitignored `registry/local.env` key `guest/debian22` — golden stream sets root + gallery passwords and reports them THERE, never in git |

## Streams (each: `scripts/dev/wt.sh new <name> --from debian22`, commit on its branch, push, report)

| Stream | Owns (one owner per file) |
|---|---|
| `debian22-golden` | the install on a sandbox clone with the exact launcher device set; X + desktop + auto-login; bake `golden`; one `loadvm` proof; stage `disk.qcow2` into the station dir; `scripts/coldboot/bootrec-tiles.conf` arm (replace `scripts/coldboot/debian22-bootrec-arm.sh`); truth in `station.env.fixture` comments, registry `runtime`/`reset`/`operator.actionMap`; measured facts back into this ledger |
| `debian22-compose` | racing theory: compose the same system WITHOUT the interactive installer (base2_2.tgz onto ext2 + CD packages); if it wins, hands the disk to golden's bake step |
| `debian22-build` | `scripts/build-guests/tiles/debian22.sh`, `scripts/build-guests/check-assets.sh`, `docs/lab/ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` row |
| `debian22-spa` | `registry/posters/debian22.md`, hero + frames under `spa/public/posters/debian22/`, `spa/src/ui/keyboard/keyboardProfiles.ts`, `spa/src/scene/assembliesByTile.ts`, `spa/src/scene/machineIdentity.ts`, registry `museum`/`spa`/`demoProgram` — the only stream that edits visitor-facing prose |
| `debian22-docs` (after golden reports) | `docs/guests/debian22.md`, `docs/GUEST-TIERS.md`, release-notes JSON, `docs/README.md` index |

## Reserved to the coordinator

Merging to `main`, the main push (after "go" from the wave coordinator),
`scripts/dev/box-deploy.sh --apply`, `scripts/dev/smoke-rig.sh debian22 --down`,
`scripts/dev/station-up.sh debian22`, the SPA build/deploy, and the final
framebuffer acceptance.

## Landing (coordinator)

Neither golden stream produced a golden inside its budget: the GNOME stream
raced the CD installer's `mke2fs` wall (TCG won, KVM never finished), the wmaker
stream pivoted to a host-composed tree and got X up but hit the font-alias and
BitBLT traps at its stop. The coordinator merged both recipes into one compose
script with every proven trap fixed (`scripts/build-guests/tiles/debian22.sh`),
rebuilt twice (second time adding Window Maker), started X by hand and baked
`golden` (VM_SIZE 46.5 MiB) at 06:33; keyboard, pointer and loadvm proven on
the launcher line at 06:34 (`smoke/p2–p4.png`). A three-hour usage-limit pause
(03:24–06:24) sits inside the wall clock; the rig survived it.

## Phase 2: absolute pointer (coordinator, 07:20–07:50)

Operator: pointer-based graphical OSes need absolute positioning. Route x11warp
as redhat62/suse64: ne2k_pci on SLIRP with one loopback hostfwd
(127.0.0.1:6082 -> 10.0.2.15:6000), `/etc/X0.hosts` = 10.0.2.2. Rebaked on the
sandbox rig with the new launcher (rule 4), and since it was a rebake anyway:
hdparm 3.6-1 from archive.debian.org (`hdparm -d1` -> 66.67 MB/s), and the
inittab autologin fixed (no shell redirection on the init line; `/etc/X11/Xserver`
= Anybody) so the disk cold-boots into the desktop by itself. Proof on the
restore: warps to (100,100)/(900,700) read back exactly and visible, keys reach
the terminal, loadvm returns the clean prompt. Golden VM_SIZE 44.9 MiB.

## Phase 3: retronet web + ICQ (Opus subagent, 4 passes, ~3 h wall)

One Opus subagent on its own rig: tap `debian22rn0`/`DEBIAN22RN-IN`, rtl8139 as the
second NIC (deterministic eth1 under 2.2.17), slirp `restrict=on`, GnomeICU 0.90b
signed in on the v5 door, Netscape 4.77 rendering search.retronet, golden 61.9 MiB
restore-proven. What cost the passes: the closure's `MISSING netscape-base-4`
(contrib) read past on pass one; `libstdc++2.9-glibc2.1` (oldlibs, depended on by
nothing) needed by `navigator-smotif.real`; a recompose that destroyed the previous
proven golden before the new one existed (rule: bake the moment the scene is
landable, rebake over it later). HiveBot stays OPEN (v5 client, client-local list).

## Timeline (box clock; operator message 02:01)

| Milestone | Time | Elapsed |
|---|---|---|
| media staged + CD smoke-booted | 02:05 | 4 min |
| `/os/debian22` viewable (installer on the framebuffer) | 02:06 | 5 min |
| ledger pushed, 5 streams launched | 02:12 | 11 min |
| docs/spa/build streams merged | 02:16–02:20 | 19 min |
| CD-install wall proven (TCG vs KVM race) | 02:28 | 27 min |
| host-composed GNOME desktop on the framebuffer (no WM) | 03:15 | 74 min |
| usage-limit pause | 03:24–06:24 | — |
| golden baked + restore-proven | 06:34 | 93 min active |


## golden2 race result (lightest desktop, private rig) — NO golden at the 25-minute stop

Rig `/data/vms/sandbox/debian22-golden2/rig/` (disk `disk.qcow2`, QEMU left running,
root shell on tty1, no vmstate). Progress log `../progress.md`; frames `rig/*.png`.
Measured facts (Claude Fable, 23:12–23:37):

- **In-guest install is not viable under wave load**: host load 44 on 16 cores, swap
  full; the guest got ~23 % of a core and `mke2fs` inside dbootstrap wrote inode
  tables at ~140 KB/s (7/15 groups in 4 min, frames `f18`–`f22`). Two waves measured
  the underlying 2.2 IDE PIO wall at ~27 KB/s each way (one KVM exit per 16-bit word).
- **cfdisk refuses a blank qcow2** ("Bad signature on partition table", frame `f8`):
  partition from tty2 with `echo -e "n\np\n1\n\n+1900M\na\n1\nn\np\n2\n\n\nt\n2\n82\nw" | fdisk /dev/hda`
  (the rescue shell has no `printf`), answer **No** to dbootstrap's "wipe and re-run cfdisk".
- **Host-side tree build works and takes ~20 s** — `/data/vms/sandbox/debian22-golden2/build-tree.sh`
  (qemu-nbd → `mke2fs -t ext2 -O none -I 128` → `base2_2.tgz` → `dpkg-deb -x` of
  xfree86-common, xlib6g, xpm4g, xserver-common, xserver-svga, xbase-clients,
  xfonts-base/75dpi, xterm, wmaker 0.61.1-4 + libwraster1, libproplist0, libungif3g,
  libjpeg62, libpng2, libtiff3g, zlib1g, libncurses5, cpp, kernel-image-2.2.17 →
  `mkfontdir` → fstab/passwd/inittab/XF86Config). Boot it from the CD prompt with
  `linux root=/dev/hda1` — no LILO needed for a vmstate golden. Traps hit, each
  framebuffer-proven: kernel 2.2 rejects 256-byte inodes (`-I 128`, frame `g1`);
  `/sbin/unconfigured.sh` forces a reboot loop (rm it, `g3`/`g5`); AF_UNIX is a module
  (`insmod /lib/modules/2.2.17/misc/unix.o` in rcS, `g7`); `/usr/X11R6/lib` missing from
  `ld.so.conf` (+`ldconfig`, `h4`); `/tmp/.X11-unix` ownership (`h7`); XF86_SVGA must run
  as root — Xwrapper or setuid (`h9`); setuid server reads
  `/usr/X11R6/lib/X11/XF86Config`, not `/etc/X11` (`i1`, unresolved at the stop).
- Kernel/DMA: `kernel-image-2.2.17-ide` is on CD1 (`base/`); not tried — `hdparm` numbers
  not measured.
- Installed on the rig: base 2.2 r0, kernel 2.2.17 (CD rescue kernel), XFree86 3.3.6-10
  svga, Window Maker 0.61.1, xterm; X never came up, resolution/VM_SIZE unmeasured.
