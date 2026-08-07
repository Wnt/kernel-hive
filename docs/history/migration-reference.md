> **Historical snapshot.** This document describes the system as it stood around 2026-07-14. It is kept for historical context and is not a description of the current system.

# Pre-migration reference — the known-good `pve-dryrun` box (captured 2026-07-14)

> **HISTORICAL PRE-WIPE SNAPSHOT.** This records the retired SATA-system state,
> not the current `labhost` host. Keep old names and paths here for rollback/audit.

Snapshot of the live SATA-SSD box **before** the NVMe rebuild, so the new box can be
diffed against a known-good baseline and rolled back to intelligently. Read-only
capture; nothing here is a secret.

## Identity / network
- Hostname: **`pve-dryrun.lan`**, IP **192.0.2.10/24**, gateway 192.0.2.1
- Bridge **`vmbr0`** ← port **`eno2`**, MAC **`02:00:00:00:00:01`** (the only NIC up; eno1/3/4 + eno5-8np0-3 all DOWN)
- BMC (IPMI/Redfish): **192.0.2.13** — credential was rotated 2026-07-15 and is
  recorded in gitignored `docs/gallery-credentials.md` under `## BMC`

## Platform (the rebuild targets the SAME major line — latest stable is still here)
- **PVE 9.2.2**, kernel **7.0.2-6-pve**, **QEMU 11.0.0** (`pve-qemu-kvm_11.0.0-3`, locally fast-poll-patched)
- QEMU machine default resolves to **`pc-i440fx-11.0`** → this is the `--pin-machine` target (`pc-i440fx-11.0` / `pc-q35-11.0`); emit with `SH_PIN_MACHINE=1` on the new box
- Boot: **UEFI** (grub-on-ESP, NOT proxmox-boot-tool). Root: **ext4 on `/dev/mapper/pve-root`** (LVM vg `pve` on the SSD)

## Storage (`/etc/pve/storage.cfg`)
- `local` (dir /var/lib/vz) · `local-lvm` (lvmthin pve/data) · **`data`** (zfspool → /data, sparse) · `isos` (dir /data/isos) · `data-tmpl` (dir /data/template)
- Pool **`data`** — single vdev on the SSD, 118 G logical used / ~16 G free (86%→ was the migration trigger). Datasets: `gallery-guests` 45 G, `vms` 54.9 G, `isos` 735 M, `subvol-950-disk-0` 6.7 G (CT950), `subvol-110-disk-0` 3.3 G (CT110, retired). **NOTE: pool name `data` + VG name `pve` collided with the fresh install. The VG was renamed live to `pve_poc` immediately before poweroff; the pool was imported by GUID readonly.**

## Workloads (raw-QEMU tiles are NOT PVE-managed)
- 28 streamhost tiles = raw `qemu-system-x86_64` under `streamhost@<tile>` units (all rebuilt on the new box; nothing transferred)
- **CT 950** `osgallery-dev` — RUNNING, 192.0.2.11, 4c/8G, rootfs `data:subvol-950-disk-0` 24 G, MAC 02:00:00:00:00:03. The dev seat; carries the gitignored secrets + Claude memory. Restored early (Phase 4) or recreated via `scripts/provision/provision-dev-ct.sh`.
- **CT 110** `osgallery` — STOPPED, onboot=0 (legacy neko, retired; dies with the SSD)
- **VM 925** (macOS) — destroyed 2026-07-14 (SPA tile is now a showcase poster)

## Rebuild inputs already staged / vendored
- **Provisioning kit**: `scripts/provision/` — `isoserver.py` (BMC-compatible Range server), `boot.ipxe.tmpl`, `pve-answer.toml.tmpl`, Redfish-flow README
- **Fast-poll pve-qemu**: recipe `scripts/provision/build-pve-qemu-fastpoll.sh`; the current patched .deb is at box `/data/vms/qemu-fastpoll-build/pve-qemu/pve-qemu-kvm_11.0.0-3_amd64.deb` (reference only — rebuild against newest pve-qemu on the new box, then `apt-mark hold`)
- **Assets bundle**: box `/data/assets-staging/` (2.5 G, 14 files, `MANIFEST.sha256` + README) — the licensed/abandonware inputs; **copy this off the box before wipe** (`scripts/build-guests/check-assets.sh --root <dir>` verifies it)
- **Emit parity** green (`scripts/dev/verify-emit.sh`), **11 builders proven**, golden-bake helpers vendored — see `docs/lab/REPRO-GAP-CLOSURE.md`

## Target hardware (to be fitted before Phase 1)
Kingston **DC2000B 240 G** (onboard M.2, PLP) → PVE ext4+LVM · WD **SN7100 1 TB** (via Delock 90047 in the x8 slot) → ZFS pool `data`. Replace the dead CMOS battery (CR2032) while the case is open. Full BOM + rationale: `docs/lab/Supermicro-storage-upgrade.md`.
