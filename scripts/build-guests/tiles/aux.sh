#!/bin/bash
# aux — A/UX 3.0.1 on qemu-system-m68k q800. INSTALL PHASE: the recipe is being
# proven by hand on the dark-launched station (docs/guests/aux.md, "Install
# recipe"); this builder is filled in once the golden exists. Until then it only
# stages the media and refuses to pretend.
set -euo pipefail

OS_ID="aux"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
# shellcheck source=scripts/build-guests/lib/media-cache.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/media-cache.sh"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# archive.org `apple-aux-3.0.1` (same bits as Macintosh Garden's set) and
# `apple-aux-3.1-update`; md5 pins are the publisher's, sha256 pinned once staged.
CD_URL='https://archive.org/download/apple-aux-3.0.1/Apple%20AUX%203.0.1/AUX_3.0.1_Install.iso'
CD_MD5=dd3edefa2095821878a8b6dee7dc7940
UPD_URL='https://archive.org/download/apple-aux-3.1-update/Apple%20AUX%203.1%20%28Update%29/AUX_3.1_Update.iso'
UPD_MD5=f7723b5613a80f3806f500cc23512a0a

mkdir -p "$WORK"
media_cache_require "md5:$CD_MD5" "$WORK/AUX_3.0.1_Install.iso" "aux-301-cd" "$CD_URL" || die "A/UX 3.0.1 CD unavailable"
media_cache_require "md5:$UPD_MD5" "$WORK/AUX_3.1_Update.iso" "aux-31-update" "$UPD_URL" || die "A/UX 3.1 update unavailable"
log "media staged in $WORK"
die "install phase: the golden is being produced by hand on the station (docs/guests/aux.md); no automated bake yet"
