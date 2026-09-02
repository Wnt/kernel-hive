# Debian GNU/Linux 2.2 "potato" integration wave — 2026-09-03

Speed-record attempt #3 (bootOS 45 min, pcgeos 6/14/18): integrate **Debian
GNU/Linux 2.2 "potato"** (i386, released 2000-08-14; kernel 2.2.19, XFree86
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

## Timeline (measured after landing with `scripts/dev/session-timeline.py`)

TODO(coordinator)

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

### golden2, +15 min extension (23:37–23:53): X up at 1024x768, `golden` saved, NOT proven

- Two more host-unpack traps, framebuffer-proven: host `umask 077` left `fonts.dir`
  and `XF86Config` mode 0600 (`chmod -R a+rX /usr/X11R6/lib/X11 /etc/X11`), and
  `fonts.alias` is assembled by the xfonts postinst — without it the server dies with
  "could not open default font 'fixed'" (`x5.png`); fix: `cat /etc/X11/fonts/$d/*.alias
  > /usr/X11R6/lib/X11/fonts/$d/fonts.alias; mkfontdir` for misc and 75dpi.
- After that `startx` switched modes in ~10 s: 1024x768, stipple root, one xterm
  (`x8.png`). The xterm paints NO text (`y0c.png`) — BitBLT path; `Option "no_bitblt"`
  was not yet in the guest's XF86Config; wmaker never appeared; Ctrl-Alt-Backspace and
  Ctrl-Alt-F1 through QMP had no visible effect (server starved on PIO, or not taking input).
- `savevm golden` on that state: VM_SIZE 31.7 MiB, disk 366 MB — restore NOT proven,
  desktop NOT shippable as is. Nothing staged into the station dir. Not folded into
  `build-tree.sh` yet: ld.so.conf, /etc/hosts, chmod 644/a+rX, fonts.alias, no_bitblt,
  setuid XF86_SVGA (or Xwrapper).
