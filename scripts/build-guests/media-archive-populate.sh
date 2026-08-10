#!/usr/bin/env bash
# media-archive-populate.sh — seed /data/media-archive from what is ALREADY on
# the box. Run it on the lab box (`ssh lab`), it needs /data.
#
# The point of this pass is not tidiness, it is survival: several of these blobs
# exist in exactly ONE place today, inside a guest image or a tile directory,
# with an upstream that is already gone or is a single unmirrored third-party
# host. Anything it cannot reach is listed at the end and written to
# NOT-POPULATED.md — that list is the most valuable output of the run, because
# it is the set of things this lab would lose today.
#
# READ-ONLY with respect to everything it reads. The two bridge bases in
# particular are inspected through `qemu-nbd --read-only` + `debugfs` (which
# opens read-only and needs no mount at all), never mounted, never written.
#
# Usage: media-archive-populate.sh [--dry-run]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/media-cache.sh
. "$HERE/lib/media-cache.sh"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

BOOKWORM_BASE=/data/vms/bridge/bridge-base.qcow2
TRIXIE_BASE=/data/vms/bridge/bridge-base-trixie.qcow2
GAPS=()
NBD=""

log() { echo "[populate] $*"; }
note_gap() {
  GAPS+=("$1")
  echo "[populate] GAP: $1" >&2
}

cleanup() {
  [ -n "$NBD" ] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
  NBD=""
}
trap cleanup EXIT

# claim_nbd_ro <image> — atomic claim (a busy device makes --connect fail), and
# --read-only so a shared read with a sibling agent is safe.
claim_nbd_ro() {
  local img="$1" i
  for i in $(seq 0 15); do
    [ -b "/dev/nbd$i" ] || continue
    if qemu-nbd --read-only --connect="/dev/nbd$i" --format=qcow2 -- "$img" 2>/dev/null; then
      NBD="/dev/nbd$i"
      return 0
    fi
  done
  return 1
}

put() { # put <file> <label> <note> [url]
  [ "$DRY" = 1 ] && {
    echo "[populate] would archive: $2 ($1)"
    return 0
  }
  media_cache_put "$@" >/dev/null
}

# ---- 1. media INSIDE the two bridge bases -----------------------------------
# Nothing checks these today, and they are the amiga/c64/atarist tiles' actual
# firmware. Extracted with debugfs `dump`, which opens the filesystem read-only
# — no mount, so no mount-propagation risk (the /dev/pts incident's lesson).
harvest_base_media() {
  local base="$1" tag="$2" part tmp f
  [ -f "$base" ] || {
    note_gap "base image absent: $base"
    return
  }
  claim_nbd_ro "$base" || {
    note_gap "could not attach $base read-only"
    return
  }
  sleep 1
  part="$(find /dev -maxdepth 1 -name "$(basename "$NBD")p*" | sort | head -1)"
  [ -n "$part" ] || part="$NBD"
  tmp="$(mktemp -d)"
  for f in GEOS.D64 etos1024k.img LICENSES amiga/kick13.rom amiga/workbench13.adf; do
    mkdir -p "$tmp/$(dirname "$f")"
    if debugfs -R "dump /opt/bridge/media/$f $tmp/$f" "$part" >/dev/null 2>&1 && [ -s "$tmp/$f" ]; then
      put "$tmp/$f" "bridge-base/$f" "extracted read-only from $tag base"
    else
      note_gap "$tag base: /opt/bridge/media/$f not extractable"
    fi
  done
  rm -rf "$tmp"
  cleanup
}

log "harvesting media from the bookworm base (read-only)"
harvest_base_media "$BOOKWORM_BASE" bookworm
log "harvesting media from the trixie base (read-only)"
harvest_base_media "$TRIXIE_BASE" trixie

# ---- 2. host-staged asset trees ---------------------------------------------
# /data/vms/streamhost/assets (11 G, the seven MAME-ish tiles), the staging
# bundle, and the repo's own tracked assets.
for root in /data/vms/streamhost/assets /data/assets-staging "$HERE/assets"; do
  [ -d "$root" ] || {
    note_gap "asset root missing: $root"
    continue
  }
  log "archiving $root"
  while IFS= read -r f; do
    case "$(basename "$f")" in MANIFEST.sha256 | SHA256SUMS | README.txt | *.md) continue ;; esac
    put "$f" "${f#/}" "staged on box under $root"
  done < <(find "$root" -type f -size +0 2>/dev/null)
done

# ---- 3. the two priority blobs that exist in only one place -----------------
# atarist's curated application zips: they live ONLY in the tile's assets dir,
# appear in NO manifest, and one of their sources needs a two-step PHP cookie
# handshake that will not survive the site changing.
ATARIST_APPS=/data/vms/streamhost/tiles/atarist/assets/atarist-apps
if [ -d "$ATARIST_APPS" ]; then
  log "archiving atarist application zips (single-copy, unmanifested)"
  while IFS= read -r f; do put "$f" "atarist-apps/$(basename "$f")" "single copy on box; source needs a PHP cookie handshake"; done \
    < <(find "$ATARIST_APPS" -type f -size +0 2>/dev/null)
else
  note_gap "atarist app zips not found at $ATARIST_APPS"
fi

# c128's CP/M .d64 exists ONLY inside the c128 tile overlay. Pull it out
# read-only the same way as the base media.
C128_OVERLAY=/data/vms/streamhost/tiles/c128/overlay.qcow2
if [ -f "$C128_OVERLAY" ]; then
  if find /proc/[0-9]*/fd -lname "$C128_OVERLAY" 2>/dev/null | grep -q .; then
    note_gap "c128 CP/M .d64: overlay is OPEN by a running tile; re-run when c128 is stopped (read-only extraction from a live qcow2 can read torn metadata)"
  elif claim_nbd_ro "$C128_OVERLAY"; then
    sleep 1
    part="$(find /dev -maxdepth 1 -name "$(basename "$NBD")p*" | sort | head -1)"
    tmp="$(mktemp -d)"
    found=0
    while IFS= read -r guestpath; do
      base="$(basename "$guestpath")"
      if debugfs -R "dump $guestpath $tmp/$base" "$part" >/dev/null 2>&1 && [ -s "$tmp/$base" ]; then
        put "$tmp/$base" "c128/$base" "extracted read-only from the c128 overlay; zimmers.net is the only source"
        found=1
      fi
    done < <(debugfs -R "ls -l /opt/bridge/media" "$part" 2>/dev/null |
      awk '{print $NF}' | grep -i '\.d64$' | sed 's|^|/opt/bridge/media/|')
    [ "$found" = 1 ] || note_gap "c128 CP/M .d64 not found under /opt/bridge/media in the overlay"
    rm -rf "$tmp"
    cleanup
  else
    note_gap "could not attach the c128 overlay read-only"
  fi
else
  note_gap "c128 overlay not found at $C128_OVERLAY"
fi

# ---- report -----------------------------------------------------------------
echo
log "archive now holds $(find "$MEDIA_ARCHIVE_ROOT/blobs" -type f 2>/dev/null | wc -l) blobs, $(du -sh "$MEDIA_ARCHIVE_ROOT" 2>/dev/null | cut -f1)"
if [ ${#GAPS[@]} -gt 0 ] && [ "$DRY" = 0 ]; then
  {
    echo "# Media this lab could NOT archive"
    echo
    echo "Generated by media-archive-populate.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
    echo "This is the set of inputs that exist in one place or not at all."
    echo
    printf -- '- %s\n' "${GAPS[@]}"
  } >"$MEDIA_ARCHIVE_ROOT/NOT-POPULATED.md"
  log "wrote $MEDIA_ARCHIVE_ROOT/NOT-POPULATED.md (${#GAPS[@]} gaps)"
fi
