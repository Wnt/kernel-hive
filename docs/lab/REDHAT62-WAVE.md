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
