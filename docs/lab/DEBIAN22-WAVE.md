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
  (`-display none`, no 4 ms dbus refresh) and `tcg` (no KVM, `-cpu pentium3`,
  cf. beos which is TCG-only) were still running at the budget cut — see
  `/data/vms/sandbox/debian22-golden/progress.md` and
  `/data/vms/sandbox/debian22-golden/shots/race-*/m*/cur.png`. At this rate
  kernel+base+X+GNOME (~300 MB) is hours, not minutes: **the interactive
  install cannot meet the 10-minute bar on this device set** — the
  `debian22-compose` route (populate the ext2 on the host, boot only to bake)
  is the one that fits the budget.
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

## Timeline (measured after landing with `scripts/dev/session-timeline.py`)

TODO(coordinator)
