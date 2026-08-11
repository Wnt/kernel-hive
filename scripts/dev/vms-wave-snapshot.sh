#!/usr/bin/env bash
# vms-wave-snapshot.sh — a cheap FLEET-WIDE safety net for migration waves:
# a ZFS snapshot of `data/vms` taken before a wave starts.
#
# WHAT THIS IS NOT: this is NOT a per-station checkpoint, and it must never be used
# as one. `/data/vms` is a SINGLE dataset holding every station — there are no
# per-station datasets. So a snapshot here is fleet-wide and, crucially, **rollback
# is all-or-nothing: you cannot roll one station back without taking the other 36
# with it**, including any work another agent landed in the meantime.
#
# The per-station checkpoint is the qcow2 internal `coldboot` snapshot
# (lib/bridge-coldboot): self-contained, travels with the overlay file, reverts
# one station. And `golden` stays a qcow2 internal snapshot too, because it needs
# the RAM state to restore a running desktop in seconds — ZFS can only ever
# checkpoint the disk. Neither of those moves to ZFS.
#
# What this IS good for: the decos rollback on 2026-08-10, where a wave-1
# migration failed on a builder bug and the recovery was manual. A snapshot
# taken before the wave costs nothing until blocks diverge and makes that a
# non-event.
#
# Usage:
#   vms-wave-snapshot.sh take <label>     # snapshot data/vms@pre-wave-<label>
#   vms-wave-snapshot.sh list             # every pre-wave snapshot + space used
#   vms-wave-snapshot.sh destroy <label>  # delete one (explicit; never automatic)
#   vms-wave-snapshot.sh rollback <label> # PRINTS the procedure; does NOT run it
set -euo pipefail

DATASET="${VMS_DATASET:-data/vms}"
PREFIX="pre-wave-"

die() {
  echo "[wave-snapshot] ERROR: $*" >&2
  exit 1
}
usage() {
  sed -n '/^# Usage:/,$p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

CMD="${1:-}"
shift || true
case "$CMD" in -h | --help | '') usage 0 ;; esac

case "$CMD" in
  take)
    LABEL="${1:?a label is required, e.g. wave2-mame}"
    case "$LABEL" in *[!A-Za-z0-9._-]*) die "label '$LABEL' has characters outside A-Za-z0-9._-" ;; esac
    SNAP="${DATASET}@${PREFIX}${LABEL}"
    # Fail loudly rather than adopting: an existing snapshot with this name is
    # somebody else's claim on the label, and silently reusing it would mean two
    # waves believing they can roll back to their own starting point.
    zfs list -t snapshot -H -o name "$SNAP" >/dev/null 2>&1 &&
      die "$SNAP already exists — pick a different label (it is NOT yours to reuse)"
    zfs snapshot "$SNAP"
    echo "[wave-snapshot] took $SNAP"
    echo "[wave-snapshot] it costs ~0 until blocks diverge; destroy it once the wave is accepted:"
    echo "                  $(basename "$0") destroy $LABEL"
    ;;
  list)
    printf '%-44s %10s %s\n' SNAPSHOT USED CREATED
    zfs list -t snapshot -H -o name,used,creation -s creation "$DATASET" 2>/dev/null |
      grep -F "@${PREFIX}" |
      while IFS=$'\t' read -r n u c; do printf '%-44s %10s %s\n' "$n" "$u" "$c"; done
    ;;
  destroy)
    LABEL="${1:?a label is required}"
    SNAP="${DATASET}@${PREFIX}${LABEL}"
    zfs list -t snapshot -H -o name "$SNAP" >/dev/null 2>&1 || die "no such snapshot: $SNAP"
    zfs destroy "$SNAP"
    echo "[wave-snapshot] destroyed $SNAP"
    ;;
  rollback)
    LABEL="${1:?a label is required}"
    SNAP="${DATASET}@${PREFIX}${LABEL}"
    zfs list -t snapshot -H -o name "$SNAP" >/dev/null 2>&1 || die "no such snapshot: $SNAP"
    # Deliberately NOT executed. `zfs rollback` on this dataset reverts EVERY
    # station, discards every snapshot taken after it, and does so while services
    # hold the files open. Someone reaching for this mid-incident, under time
    # pressure, is exactly who needs to read the consequence before typing it.
    cat <<EOF
REFUSING to roll back automatically. Read this first.

  $SNAP covers the WHOLE $DATASET dataset — every tile, not just the one you
  are thinking about. Rolling it back:
    * reverts all ~37 tiles to their state when the snapshot was taken,
      discarding any work anyone else landed since;
    * destroys every ZFS snapshot of $DATASET taken AFTER it;
    * corrupts any tile whose QEMU is running at the time, because the files
      change underneath open file descriptors.

  If that is genuinely what you want:
    1. stop every tile:        systemctl stop 'streamhost@*'
    2. confirm nothing holds the dataset open (no qemu under /data/vms)
    3. zfs rollback -r $SNAP
    4. bring the fleet back:   streamhost/bring-up-all.sh

  To undo ONE tile instead, that is a per-tile qcow2 operation, not this:
    scripts/build-guests/lib/bridge-coldboot revert <overlay> --allow-tile
EOF
    exit 3
    ;;
  *) die "unknown subcommand '$CMD' (see: $(basename "$0") --help)" ;;
esac
