#!/usr/bin/env bash
# =============================================================================
# pve-zfs-pool.sh — create the production ZFS bulk pool + datasets + PVE storages
# on the real NVMe box, per the locked target design ("Drive 2 — WD
# Black SN7100 → bulk/reconstructible tier").
#
# Idempotent: safe to re-run. It will NOT destroy an existing pool (guard below);
# dataset/storage/ARC steps are all create-if-missing.
#
# Run ON the Proxmox host as root, e.g.:
#     ./pve-zfs-pool.sh                       # defaults (pool=data, dev=/dev/nvme1n1)
#     DEV=/dev/disk/by-id/nvme-... ./pve-zfs-pool.sh          # STRONGLY prefer by-id
#     COMPRESSION=zstd ARC_MAX_GIB=16 ./pve-zfs-pool.sh       # override tunables
#
# WHY these values:
#   ashift=12        the SN7100 reports a 32K block; 12 is correct, the warning is
#                    cosmetic — do NOT use ashift=15.
#   compression      lz4 pool-wide (cuts physical writes on the DRAM-less, no-PLP
#                    drive at ~0 CPU). The dry-run box used zstd to *squeeze* a tiny
#                    83.5G pool; for the 1TB prod drive lz4 is the architecture pick.
#                    Static, highly-compressible datasets (isos, gallery-guests,
#                    backups) get zstd for ratio — set per-dataset below.
#   atime=off xattr=sa dnodesize=auto     standard PVE-on-ZFS hygiene.
#   autotrim=off + weekly `zpool trim`    smoother under emulator write churn.
#   zfs_arc_max=16G  so ARC doesn't fight VM RAM during bursts (the dry-run box had
#                    a WRONG inherited 4G cap — set this INTENTIONALLY).
#   Always zvols, never qcow2-on-ZFS (double-CoW). VM disks land as data/vm-*-disk-*.
# =============================================================================
set -euo pipefail

# ---- parameters (override via environment) ----------------------------------
POOL="${POOL:-data}"
# PREFER a stable /dev/disk/by-id/... path for DEV so the pool survives device
# renumbering. /dev/nvme1n1 is the dry-run default (nvme0=Kingston OS, nvme1=WD bulk).
DEV="${DEV:-/dev/nvme1n1}"
ASHIFT="${ASHIFT:-12}"
COMPRESSION="${COMPRESSION:-lz4}"                  # pool default (prod). Use zstd to squeeze a tiny pool.
GALLERY_COMPRESSION="${GALLERY_COMPRESSION:-zstd}" # static OS images compress well
ARC_MAX_GIB="${ARC_MAX_GIB:-16}"
FORCE="${FORCE:-0}" # set 1 to pass `zpool create -f` (wipes DEV!)

# PVE storage ids to register (match the dry-run box: zfspool 'data' + dir 'isos').
ZFS_STORE="${ZFS_STORE:-$POOL}" # zfspool storage id (holds zvols + CT rootfs)
ISO_STORE="${ISO_STORE:-isos}"  # dir storage id (holds ISOs / templates / dumps)

log() { printf '\033[1;32m### %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2
  exit 1
}

command -v zpool >/dev/null || die "zpool not found — run on the Proxmox host."

# ---- 1. create the pool (guarded) -------------------------------------------
if zpool list "$POOL" >/dev/null 2>&1; then
  warn "pool '$POOL' already exists — skipping create (props/datasets still ensured)."
else
  [ -e "$DEV" ] || die "device $DEV not found. Pass DEV=/dev/disk/by-id/nvme-<...> (preferred)."
  log "create pool '$POOL' on $DEV (ashift=$ASHIFT)"
  CREATE_FLAGS=(-o "ashift=$ASHIFT")
  [ "$FORCE" = 1 ] && CREATE_FLAGS+=(-f)
  # single-vdev, no redundancy — by design (no extra drives, no RAID; recovery = cloud).
  zpool create "${CREATE_FLAGS[@]}" "$POOL" "$DEV"
fi

# ---- 2. pool-wide dataset properties ----------------------------------------
log "set pool-wide props (compression=$COMPRESSION, atime=off, xattr=sa, dnodesize=auto)"
zfs set compression="$COMPRESSION" atime=off xattr=sa dnodesize=auto "$POOL"
# autotrim off; prefer a scheduled weekly trim (added below as a systemd timer if absent).
zpool set autotrim=off "$POOL" 2>/dev/null || true

# ---- 3. datasets (per architecture table) -----------------------------------
# helper: create dataset if missing, then apply properties
ds() { # ds <name> <prop=val> ...
  local name="$1"
  shift
  zfs list "$name" >/dev/null 2>&1 || {
    log "create dataset $name"
    zfs create -p "$name"
  }
  [ $# -gt 0 ] && zfs set "$@" "$name"
}

# VM/CT block storage root (zvols land here as $POOL/vm-*; CT rootfs as $POOL/subvol-*).
ds "$POOL/vms" sync=standard
# ISOs / templates: big sequential files -> 1M recordsize + zstd-1.
ds "$POOL/isos" recordsize=1M compression=zstd-1 mountpoint=/data/isos
# restic / local backup staging: 1M + zstd-3.
ds "$POOL/backups" recordsize=1M compression=zstd-3
# k3s PVCs (app state).
ds "$POOL/pvcs" recordsize=128K sync=standard
ds "$POOL/pvcs/scratch" sync=disabled # CI build artifacts (reconstructible)
# Kernel Hive guest images (retro/exotic/mobile qcow2/img/iso). Static, compressible,
# reconstructible -> zstd. This is the dataset preserve-guest-images.sh lands into.
ds "$POOL/gallery-guests" compression="$GALLERY_COMPRESSION" recordsize=128K mountpoint=/data/gallery-guests

log "datasets:"
zfs list -o name,used,avail,compression,mountpoint | grep -E "^$POOL"

# ---- 4. cap the ARC at ${ARC_MAX_GIB} GiB -----------------------------------
ARC_BYTES=$((ARC_MAX_GIB * 1024 * 1024 * 1024))
log "cap ARC at ${ARC_MAX_GIB} GiB (${ARC_BYTES} bytes) — persistent + live"
printf 'options zfs zfs_arc_max=%s\n' "$ARC_BYTES" >/etc/modprobe.d/zfs.conf
# apply live (works while pool is imported; the modprobe.d line makes it survive reboot).
echo "$ARC_BYTES" >/sys/module/zfs/parameters/zfs_arc_max 2>/dev/null ||
  warn "could not set zfs_arc_max live (will apply on next boot via modprobe.d)."
update-initramfs -u >/dev/null 2>&1 || true

# ---- 5. weekly trim timer (no autotrim; batch trim is gentler) --------------
if ! systemctl list-timers 2>/dev/null | grep -q "zfs-trim-${POOL}"; then
  log "install weekly 'zpool trim $POOL' systemd timer"
  cat >"/etc/systemd/system/zfs-trim-${POOL}.service" <<EOF
[Unit]
Description=Weekly TRIM of ZFS pool $POOL
[Service]
Type=oneshot
ExecStart=/sbin/zpool trim $POOL
EOF
  cat >"/etc/systemd/system/zfs-trim-${POOL}.timer" <<EOF
[Unit]
Description=Weekly TRIM of ZFS pool $POOL
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "zfs-trim-${POOL}.timer" >/dev/null 2>&1 || true
fi

# ---- 6. register PVE storages -----------------------------------------------
# zfspool storage: holds VM zvols (images) + LXC rootfs (rootdir). This is the
# storage id you pass to the VM builders (STORAGE=$ZFS_STORE).
if command -v pvesm >/dev/null; then
  if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$ZFS_STORE"; then
    log "pvesm add zfspool $ZFS_STORE (pool=$POOL, content=images,rootdir)"
    pvesm add zfspool "$ZFS_STORE" --pool "$POOL" --content images,rootdir --sparse 1
  else
    log "pvesm storage '$ZFS_STORE' already present"
  fi
  # dir storage for ISOs / templates / dumps on the mounted dataset.
  if ! pvesm status 2>/dev/null | awk '{print $1}' | grep -qx "$ISO_STORE"; then
    log "pvesm add dir $ISO_STORE (path=/data/isos, content=iso,vztmpl,backup)"
    mkdir -p /data/isos/template/iso /data/isos/template/cache /data/isos/dump
    pvesm add dir "$ISO_STORE" --path /data/isos --content iso,vztmpl,backup
  else
    log "pvesm storage '$ISO_STORE' already present"
  fi
  pvesm status
else
  warn "pvesm not found — skipping PVE storage registration (not a PVE host?)"
fi

log "DONE. Pool '$POOL' ready."
log "Restore prebuilt guests with preserve-guest-images.sh, then bring up the streamhost tiles."
