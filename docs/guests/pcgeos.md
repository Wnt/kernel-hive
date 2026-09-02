# pcgeos guest

Status: **scaffold only** (Tier 1, disabled candidate; not in the lineup).

## Identity and source

- Public ID / tile directory: `pcgeos`
- Reserved slot / UDP port: `175` / `54175`
- Archetype: `beige-ibm-pc`
- Stable release, architecture, source/license class, URL, size, and SHA-256: TODO

## Build and device set

- Builder: `scripts/build-guests/tiles/pcgeos.sh`
- Canonical output: TODO
- QEMU binary, machine, accelerator, CPU, RAM, display, storage, NIC, audio, and input: TODO
- Ready framebuffer and bounded automation path: TODO

## Golden, input, and rollback

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
