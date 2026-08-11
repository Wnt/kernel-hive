#!/usr/bin/env bash
# =============================================================================
# preserve-guest-images.sh — THE FAST PATH.
#
# Copy the hours-of-work built guest OS images from THIS dry-run box to the real
# NVMe box so the production install COPIES the installed guests instead of
# rebuilding them. Two payloads, two mechanisms:
#
#   A) Kernel Hive guest images  ->  ZFS dataset  $POOL/gallery-guests  (+ child
#      $POOL/gallery-guests/postmarketOS). Copied with `zfs send | zfs recv` —
#      the fast, exact, checksummed way to move a whole dataset between pools of
#      the same name. (rsync fallback provided for a non-ZFS target.)
#
#   B) Explicitly selected VM disks (zvols). Copied zvol-by-zvol with `zfs send |
#      zfs recv`, plus each VM's `qm config` so the VM re-registers verbatim on
#      the target and keeps the same dataset references.
#
# WHY send/recv, not rebuild: the retro/exotic/mobile guests each took a long
# interactive build (DOS/Win9x installs, driver fixes, Solaris JumpStart, Android
# SetupWizard, pmOS UEFI). Several have ONLY on-box helper scripts (no repo-side
# reproducer) — see the "on-box-only" list in MASTER-REPRODUCE.md — so for those,
# copying the image is the ONLY reproduction path.
#
# SAFE: source side is READ-ONLY except for creating (and cleaning up) snapshots.
# It never modifies running VMs/CTs. Runs from your Mac; it SSHes to both boxes.
#
# Usage:
#   preserve-guest-images.sh [--gallery] [--vms "900 920 ..."] [--all]
#                            [--dry-run] [--rsync-gallery]
#   Env:
#     SRC=root@192.0.2.10      source (this dry-run box)
#     DST=root@<newbox>           destination (real NVMe box)   [REQUIRED unless --dry-run]
#     SSH_KEY=/path/to/lab_key    identity for BOTH hosts (assumed shared)
#     POOL=data                   pool name on BOTH boxes (send/recv keeps names)
#     SNAP=migrate-YYYYmmdd       snapshot tag (default: migrate-$(date +%s))
#
# Examples:
#   # copy just the gallery guests (safe first move):
#   SSH_KEY=~/lab_key DST=root@192.0.2.50 preserve-guest-images.sh --gallery
#   # copy gallery + an explicitly selected VM:
#   SSH_KEY=~/lab_key DST=root@192.0.2.50 preserve-guest-images.sh --gallery --vms 940
#   # everything currently live (the gallery dataset; no managed VMs are live):
#   SSH_KEY=~/lab_key DST=root@192.0.2.50 preserve-guest-images.sh --all
# =============================================================================
set -euo pipefail

SRC="${SRC:-root@192.0.2.10}"
DST="${DST:-}"
SSH_KEY="${SSH_KEY:-}"
POOL="${POOL:-data}"
SNAP="${SNAP:-migrate-$(date +%s)}"

DO_GALLERY=0
VMS=""
DRYRUN=0
RSYNC_GALLERY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gallery)
      DO_GALLERY=1
      shift
      ;;
    --vms)
      VMS="$2"
      shift 2
      ;;
    --all)
      DO_GALLERY=1
      VMS=""
      shift
      ;;
    --rsync-gallery)
      RSYNC_GALLERY=1
      DO_GALLERY=1
      shift
      ;;
    --dry-run)
      DRYRUN=1
      shift
      ;;
    -h | --help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done
[ "$DO_GALLERY" = 1 ] || [ -n "$VMS" ] || {
  echo "nothing selected: pass --gallery and/or --vms / --all"
  exit 2
}

KEYOPT=()
[ -n "$SSH_KEY" ] && KEYOPT=(-i "$SSH_KEY")
SSHO=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null)
# shellcheck disable=SC2029 # src/dst are generic ssh command-forwarding wrappers; callers control quoting/expansion of the remote command themselves
src() { ssh "${KEYOPT[@]}" "${SSHO[@]}" "$SRC" "$@"; }
# shellcheck disable=SC2029 # see src() above
dst() { ssh "${KEYOPT[@]}" "${SSHO[@]}" "$DST" "$@"; }

log() { printf '\033[1;32m### %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*" >&2; }
die() {
  printf '\033[1;31mFATAL: %s\033[0m\n' "$*" >&2
  exit 1
}

if [ "$DRYRUN" = 0 ]; then
  [ -n "$DST" ] || die "set DST=root@<newbox> (or use --dry-run to preview)."
  src true || die "cannot ssh to SRC ($SRC)"
  dst true || die "cannot ssh to DST ($DST)"
  dst "zpool list $POOL" >/dev/null 2>&1 || die "pool '$POOL' not found on DST — run pve-zfs-pool.sh there first."
fi

# The end-to-end pipe: `SRC: zfs send ... | DST: zfs recv ...`. We drive it from
# the Mac by nesting: ssh SRC 'zfs send ... | ssh DST zfs recv ...'. For that inner
# hop SRC must be able to reach DST; if it can't (isolated LANs), flip PIPE_VIA_MAC=1
# to stream through the Mac instead (SRC | mac | DST) at the cost of Mac bandwidth.
PIPE_VIA_MAC="${PIPE_VIA_MAC:-0}"

send_recv() { # send_recv <source-dataset> <dest-dataset> [--recursive]
  local sds="$1" dds="$2" rec=""
  [ "${3:-}" = "--recursive" ] && rec="-R"
  log "snapshot ${sds}@${SNAP}"
  if [ "$DRYRUN" = 1 ]; then
    echo "  (dry-run) zfs snapshot ${rec:+-r }${sds}@${SNAP}"
    echo "  (dry-run) zfs send ${rec} ${sds}@${SNAP} | zfs recv -F ${dds}"
    return 0
  fi
  src "zfs snapshot ${rec:+-r }'${sds}@${SNAP}'"
  log "send ${sds}@${SNAP}  ->  ${DST}:${dds}"
  if [ "$PIPE_VIA_MAC" = 1 ]; then
    src "zfs send ${rec} '${sds}@${SNAP}'" | dst "zfs recv -F '${dds}'"
  else
    # inner hop SRC->DST; pass the key material by agent-forwarding-free approach:
    # we rely on SRC already having a route+key to DST, OR fall back to via-Mac.
    src "zfs send ${rec} '${sds}@${SNAP}' | ssh ${SSHO[*]} ${DST} zfs recv -F '${dds}'" ||
      {
        warn "direct SRC->DST hop failed; retrying via Mac"
        src "zfs send ${rec} '${sds}@${SNAP}'" | dst "zfs recv -F '${dds}'"
      }
  fi
  # tidy the source snapshot (leave the dest one for future incrementals if wanted).
  src "zfs destroy ${rec:+-r }'${sds}@${SNAP}'" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A) gallery guests dataset  (data/gallery-guests, incl. child postmarketOS)
# ---------------------------------------------------------------------------
if [ "$DO_GALLERY" = 1 ]; then
  if [ "$RSYNC_GALLERY" = 1 ]; then
    # rsync path: for a NON-ZFS target, or to merge into an existing dataset without
    # clobbering. Copies the file tree (qcow2/img/iso + helper scripts + proofs).
    log "rsync /data/gallery-guests  ->  ${DST}:/data/gallery-guests  (file-level)"
    if [ "$DRYRUN" = 1 ]; then
      echo "  (dry-run) rsync -aHAX --info=progress2 SRC:/data/gallery-guests/ DST:/data/gallery-guests/"
    else
      # stream SRC->DST directly if possible, else via the Mac.
      src "rsync -aHAX --numeric-ids -e 'ssh ${SSHO[*]}' /data/gallery-guests/ ${DST}:/data/gallery-guests/" ||
        die "rsync SRC->DST failed (isolated LANs? run rsync twice through the Mac, or use the zfs path)."
    fi
  else
    # zfs send/recv the whole subtree. -R carries the child dataset
    # data/gallery-guests/postmarketOS and all properties (compression=zstd, etc).
    send_recv "$POOL/gallery-guests" "$POOL/gallery-guests" --recursive
  fi
  log "gallery guests preserved. On DST they mount at /data/gallery-guests (bind-mount into the gallery LXC next)."
fi

# ---------------------------------------------------------------------------
# B) VM disks (zvols) + their qm configs
# ---------------------------------------------------------------------------
# For each VMID: send every $POOL/vm-<id>-disk-* zvol, then copy the .conf so the
# VM re-registers on the target. IMPORTANT: send/recv preserves the exact zvol
# names, so the copied config (which references data:vm-<id>-disk-N) is valid as-is.
#
# NOTE on running VMs: a zvol of a RUNNING VM is crash-consistent (like pulling the
# plug). Win11/NTFS + macOS/APFS both journal, so this is normally fine, but for a
# guaranteed-clean copy do `qm shutdown <id>` on SRC first (this script does NOT, to
# honour "do not touch running VMs" — pass PRESHUTDOWN=1 to opt in).
PRESHUTDOWN="${PRESHUTDOWN:-0}"

for vmid in $VMS; do
  log "=== VM $vmid ==="
  if [ "$DRYRUN" = 1 ]; then
    echo "  (dry-run) would copy qm config $vmid and all ${POOL}/vm-${vmid}-disk-* zvols"
    continue
  fi
  src "qm status $vmid" >/dev/null 2>&1 || {
    warn "VM $vmid not on SRC — skipping"
    continue
  }

  if [ "$PRESHUTDOWN" = 1 ]; then
    log "PRESHUTDOWN=1 -> qm shutdown $vmid (clean, then restart after)"
    WASRUN=0
    src "qm status $vmid | grep -q running" && WASRUN=1
    [ "$WASRUN" = 1 ] && { src "qm shutdown $vmid --timeout 120" || src "qm stop $vmid"; }
  fi

  # 1) copy the config verbatim (strip nothing — dataset names match post-recv).
  log "copy /etc/pve/qemu-server/${vmid}.conf -> DST"
  CONF="$(src "cat /etc/pve/qemu-server/${vmid}.conf")"
  # write it on DST (VM must not already exist there)
  if dst "test -f /etc/pve/qemu-server/${vmid}.conf"; then
    warn "VM $vmid already configured on DST — leaving its config; will still (re)send disks."
  else
    printf '%s\n' "$CONF" | dst "cat > /etc/pve/qemu-server/${vmid}.conf"
  fi

  # 2) send every zvol backing this VM
  for zv in $(src "zfs list -H -o name | grep -E '^${POOL}/vm-${vmid}-disk-'"); do
    send_recv "$zv" "$zv"
  done

  [ "${PRESHUTDOWN:-0}" = 1 ] && [ "${WASRUN:-0}" = 1 ] && {
    log "restart VM $vmid on SRC"
    src "qm start $vmid" || true
  }
  log "VM $vmid preserved. On DST: qm start $vmid (detach install ISOs first if any)."
done

# ---------------------------------------------------------------------------
# guidance
# ---------------------------------------------------------------------------
cat <<EOF

------------------------------------------------------------------------------
PRESERVE COMPLETE${DRYRUN:+ (dry-run — nothing copied)}.
What landed on ${DST:-<DST>}:
  gallery images : ${POOL}/gallery-guests (+ .../postmarketOS)  -> /data/gallery-guests
  VM disks       : ${POOL}/vm-<id>-disk-*  for VMIDs: ${VMS:-<none>}
  VM configs     : /etc/pve/qemu-server/<id>.conf  (dataset refs unchanged, valid as-is)

Next on the real box, in order (see MASTER-REPRODUCE.md):
  1. VMs:      qm set <id> --delete ide2,sata0,sata1 2>/dev/null; qm start <id>
               (Win11 900 boots straight to desktop; RDP tile then bridges to it.)
  2. Gallery:  wire the streamhost tiles (streamhost/stations-manifest.sh emit
               invocations + streamhost/bring-up-all.sh; see MASTER-REPRODUCE.md).

INCREMENTALS: this used snapshot @${SNAP}. To ship only the delta later, keep the
dest snapshot and run: zfs send -i @${SNAP} DATASET@NEWSNAP | ssh ${DST:-DST} zfs recv
------------------------------------------------------------------------------
EOF
