# suse64 wave — SuSE Linux 6.4 i386 (2000), KDE 1.1.2 on XFree86 3.3.6, absolute pointer

Operator ask (2026-09-02): "a new record in how fast we can integrate a new
station … early SUSE Linux". Procedure: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0.
Scaffold sibling: `freedos` (cirrus + PS/2); runtime/pointer shape copied from
the concurrent `netbsd14` wave (x11warp over a loopback X forward, `/opt/qemu-beos`).
Coordination across the six concurrent waves: the "os station integrations
coordination" session allocated slot 180; landing is serialized through it.

## Allocation ledger

| Value | Allocation |
|---|---|
| id / stationDir / SH_STATION | `suse64` |
| slot / UDP / VMID | 180 / 54180 / 180 (kh-claimed by `smoke-rig.sh`, session `suse`) |
| X forward (host loopback → guest) | 127.0.0.1:6080 → 10.0.2.15:6000, `SH_X11WARP_DISPLAY=127.0.0.1:80` |
| render orders | as assigned by `stations-registry.py new --like freedos --slot 180` |
| QEMU | `/opt/qemu-beos/bin/qemu-system-x86_64`, `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 256 MB, 1 vCPU, `-vga cirrus`, one IDE qcow2 (4 GiB), `ne2k_pci` on SLIRP, no audio |
| Release | SuSE Linux 6.4 (2000-03-28 README; retail six-CD set), i386: kernel 2.2.14, XFree86 3.3.6 (+4.0), KDE 1.1.2, YaST1 |
| Media | archive.org item `suse-linux-6.4`, `suse-linux-6.4-cd1.iso` — **663 029 760 bytes**, sha256 `5a835e4bba03485f17f31d6b8204881a77c1206571b27e8300c889e8bf721a33`; staged `/data/assets-staging/suse64/` (labhost path) with `MANIFEST.sha256`. Only CD1 is used. |
| Smoke rig | `/data/vms/sandbox/suse/smoke/` (`launch-smoke.sh [d|c]`, `run-daemon.sh`), published at `/os/suse64` |
| Golden disk | staged to `/data/gallery-guests/SUSE64/suse64.qcow2`; the launcher copies it to the station dir on first start |

Measured on the smoke boot (framebuffer, 640x480 text): the 2.2.14 install kernel
sees `hda` (QEMU HARDDISK, 4096 MB), `hdc` (ATAPI CD), `fd0`, and loads the
47 140 KB linuxrc ramdisk in ~8 s under KVM.

## Streams (each `wt.sh new suse64-<stream> --from suse`, 4-minute stop except golden)

| Stream | Model | Owns |
|---|---|---|
| golden | Fable | the smoke rig: YaST1 install from CD1, `/etc/XF86Config` (SVGA on cirrus, 1024x768x16), console autologin → `startx` → KDE 1.1.2, `xhost +10.0.2.2`, bake `golden` with the station device set (no cdrom), one `loadvm` proof, stage the disk; facts reported to the coordinator who fills `station.env.fixture` + registry truth |
| build | sonnet-low | `scripts/build-guests/tiles/suse64.sh`, `check-assets.sh`, `ASSETS-MANIFEST.md`, `docs/catalog/os-media-catalog.md` |
| spa | Fable | `registry/posters/suse64.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` in the entry (the scaffold carries netbsd14's demoProgram as a placeholder — replace it) |
| docs | sonnet-low (after golden) | `docs/guests/suse64.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` |

## Timeline (measured after landing with session-timeline.py)

TODO(coordinator)
