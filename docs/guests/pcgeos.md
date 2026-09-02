# pcgeos guest — PC/GEOS Ensemble, GeoWorks in 640 KB

Status: **LIVE** (Tier 1, host-native, KVM), integrated 2026-09-02 in a parallel
wave ([`lab/PCGEOS-WAVE.md`](../lab/PCGEOS-WAVE.md)). The media is sourced,
hashed and staged; the disk is composed by a builder; the golden and its bake
are the golden stream's to prove and record below.

## What it is

PC/GEOS Ensemble is GeoWorks's preemptive-multitasking, object-oriented
graphical desktop for DOS — first shipped in 1990 as **GeoWorks Ensemble**,
sold on through **NewDeal Office** and **Breadbox Ensemble**, and open-sourced
in 2018 by Breadbox/blueway.Softworks under **Apache-2.0**
(<https://github.com/bluewaysw/pcgeos>). It is the GUI that ran a full desktop,
word processor and paint program in **640 KB on a 286**, and made Windows 3.0
look slow doing it. This station runs the bluewaysw CI build of that
open-sourced codebase, not an archival GeoWorks release.

## Identity and source

- Public ID / `stationDir` / `SH_STATION`: `pcgeos`
- Display name: **PC/GEOS Ensemble**
- Reserved slot / UDP port / VMID label: `175` / `54175` / `175`
- Archetype: `beige-ibm-pc`; era year **1993** (`museum.year`), lineage
  `GeoWorks Ensemble → NewDeal Office → Breadbox Ensemble → PC/GEOS (open
  source 2018)`
- Upstream: <https://github.com/bluewaysw/pcgeos>, release tag `CI-latest`
  (a moving tag — the builder pins the SHA-256 of the asset, not the tag),
  asset `pcgeos-ensemble_nc.zip`
- License class: **free/open**, Apache-2.0
- No login, no credentials. `credentialsRef: guest/pcgeos` exists only because
  the schema requires one.

### Media

| property | value |
|---|---|
| `pcgeos-ensemble_nc.zip` | CI-latest asset, **10 932 546 bytes**, 743 files, 22.2 MB unpacked; unzips to `ensemble/` with `loader.exe`, `geos.ini`, `system/` — every name fits 8.3 |
| SHA-256 | recorded in `/data/assets-staging/pcgeos/MANIFEST.sha256` |
| Base OS | the fleet FreeDOS 1.3 disk, `/data/gallery-guests/FreeDOS/freedos.qcow2` (512 MiB FAT16 LBA partition at byte offset 32256) |
| Builder | `scripts/build-guests/tiles/pcgeos.sh` (`build.rows` key `pcgeos`, class `fast`, `automation: full`, `~2m`) |
| Builder output | `/data/gallery-guests/PCGEOS/pcgeos.qcow2` — FreeDOS 1.3 disk + `C:\ENSEMBLE`, autoexec runs `loader.exe`; pristine, no golden |
| Runtime path | `/data/vms/streamhost/stations/pcgeos/disk.qcow2` — the ONLY block device |

## Composition recipe

- Reset mode and fixture: TODO
- Run `scripts/lib/golden-verify.sh pcgeos --bake` on a namespaced clone, then
  rerun without `--bake` before promotion.
- Pointer/click/drag/wheel/keyboard proof: TODO
- Cold-boot zero-input state and optional clip: TODO
- Credentials reference only (never values): `guest/pcgeos`
- Rollback plan: TODO

## Checkpoint

- Snapshot name: `golden`, saved via QMP `human-monitor-command` `savevm golden`.
- Carrier disk: `disk.qcow2` is the ONLY block device — staged at
  `/data/vms/streamhost/stations/pcgeos/disk.qcow2` (399,572,992 bytes / 381 MiB
  on disk; 512 MiB virtual). `qemu-img snapshot -l` reports the `golden` tag at
  `VM_SIZE 3.48 MiB`.
- Boot time: cold boot (no `-loadvm`) reaches the full PC/GEOS desktop
  (Computer/Documents/World icons on the orange "Meadows" wallpaper, taskbar at
  the bottom) in ~31 s under KVM (QMP `VM_CLOCK` read `0000:00:30.870` at the
  moment `savevm` ran, after a settle wait past the desktop paint).
- Restore proven: 2026-09-02, one `loadvm` cycle on a sandbox clone
  (`/data/vms/sandbox/pcgeos-golden/`) — quit QEMU after `savevm`, relaunched the
  same launcher (picks up `-loadvm golden -S` automatically once the tag
  exists), sent QMP `cont`, screendumped. The restored frame is byte-identical
  in size (263,816 bytes PNG) to the pre-`savevm` cold-boot frame and shows the
  same settled desktop. One restore only, per the operator's no-proof-gate rule
  (a restoring golden is enough).
- Coldboot-record arm: `pcgeos` case in `scripts/coldboot/bootrec-tiles.conf`
  (`BR_BOOT_KIND=vmstate`, canvas 800x600 @30fps, audio on, `BR_DISKS=disk.qcow2`).
