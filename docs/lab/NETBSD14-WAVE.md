# netbsd14 wave — NetBSD 1.4.1 i386 (1999), XFree86 3.3 desktop, absolute pointer

Operator ask (2026-09-02): "a new record in how fast we can integrate a new
station … NetBSD from 1995–1999 with graphical interface and absolute cursor".
Procedure: `docs/lab/ADD-NEW-OS-PLAYBOOK.md` §0. Sibling: `pcgeos` (device set),
`sunos414` (pointer route).

## Allocation ledger (claimed by smoke-rig under KH_SESSION=netbsd14)

| Value | Assigned |
|---|---|
| id / stationDir / SH_STATION | `netbsd14` |
| slot / UDP / VMID | 176 / 54176 / 176 |
| X forward (host loopback → guest) | 127.0.0.1:6076 → 10.0.2.15:6000, `SH_X11WARP_DISPLAY=127.0.0.1:76` |
| render orders | as assigned by `stations-registry.py new --like pcgeos` |
| QEMU | `/opt/qemu-beos/bin/qemu-system-x86_64`, `pc-i440fx-11.0,acpi=off`, KVM, `-cpu host`, 128 MB, 1 vCPU, `-vga cirrus`, one IDE qcow2, `ne2k_pci` on SLIRP |
| Release | NetBSD 1.4.1 (1999-08-26), i386, XFree86 3.3.3.1 (the X sets shipped with 1.4.1) |
| Media | `archive.netbsd.org/pub/NetBSD-archive/NetBSD-1.4.1/i386/`: `installation/floppy/boot.fs` (1 474 560 B) + `binary/sets/{base,comp,etc,games,kern,man,misc,text,xbase,xcomp,xcontrib,xfont,xserver}.tgz`; all 13 sets verify against the archive `MD5`; staged in `/data/assets-staging/netbsd14/` with `MANIFEST.sha256` |
| Install medium | sets composed into `sets.iso` (`genisoimage -R -J`, tree `i386/binary/sets/`, 61 026 304 B) attached as the IDE CD; sysinst "CD-ROM" source, device `cd0`, dir `/i386/binary/sets` |
| Smoke rig | `/data/vms/sandbox/netbsd14/smoke/` (`launch-smoke.sh [a|c]`, `run-daemon.sh`), published at `/os/netbsd14` |

Measured on the smoke boot (framebuffer, 720x400 text): kernel probes `wd0`
(IDE), `cd0`, `ne2` (RTL8029), `pc0` (**pccons**, not wscons), `com0`, `fdc0`;
sysinst main menu ~25 s after power-on. No `pms0` line was seen on the INSTALL
kernel — the golden stream verifies the PS/2 mouse on GENERIC (fallback:
`-chardev msmouse` serial mouse on `com0`, XFree86 protocol `Microsoft`).

## Streams (each `wt.sh new netbsd14-<stream> --from netbsd14`, 4-minute stop except golden)

| Stream | Model | Owns |
|---|---|---|
| golden | Fable | the smoke rig: sysinst install, XF86Config (cirrus), console autologin → `xinit` ctwm session, `xhost +10.0.2.2`, bake `golden` with the station launcher, one `loadvm` proof, stage `disk.qcow2` into the station dir, `station.env.fixture` checkpoint facts, `registry` runtime/reset truth |
| build | sonnet-low | `scripts/build-guests/tiles/netbsd14.sh`, `check-assets.sh`, `ASSETS-MANIFEST.md`, `os-media-catalog.md` |
| spa | Fable | `registry/posters/netbsd14.md`, hero + frames, `keyboardProfiles.ts`, `assembliesByTile.ts`, `machineIdentity.ts`, `museum`/`spa`/`demoProgram` |
| docs | sonnet-low (after golden) | `docs/guests/netbsd14.md`, `GUEST-TIERS.md`, release notes, `docs/README.md` |

## Timeline (measured after landing with session-timeline.py)

TODO(coordinator)
