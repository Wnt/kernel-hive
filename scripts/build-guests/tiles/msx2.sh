#!/bin/bash
# =============================================================================
# build-guests/tiles/msx2.sh — stage the msx2 station's MSX-DOS 2 boot disk.
#
# Unlike samcoupe's hive.mgt (composed on the host from source disks with
# lib/mgtfs.py) or atari800xl's hive.atr, this station's media needs NO
# composing: MSX-DOS 2 (English) is distributed as a complete, ready-to-boot
# 368640-byte 3.5" disk image, so this builder only fetches, hash-verifies
# and stages it (plus the nms8250 BIOS romset MAME needs to run the
# machine at all) — the same shape as the ROM-only stations (dragon32.sh,
# zx81.sh) rather than a disk composer.
#
# HOST-NATIVE: no chroot, no bridge base, no QEMU. The emulator plane is
# scripts/build-guests/emulators/build-mame-native.sh msx2 (a separate step,
# not run by this script) — this file touches media only.
#
# Usage: msx2.sh [--force]
# =============================================================================
set -euo pipefail

TILE=msx2
STAGING=/data/assets-staging/msx2
ASSETS=/data/vms/streamhost/assets/msx2
ROMS_ZIP="$STAGING/roms/nms8250.zip"
ROMS_ZIP_URL="https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/nms8250.zip"
ROMS_ZIP_SHA256=42905515ecc08f11f5927697c091465207816f8849dc6fe104d277ba2dd77a42

DISK_ZIP="$STAGING/media/msxdos2-english.zip"
DISK_ZIP_URL="https://download.file-hunter.com/System%20Disks/Cartridges/ASCII/MSX-DOS2/MSX-DOS%202%20(English).zip"
DISK_ZIP_SHA256=561a6be5e433b516bdcbe96178b21801cb2fe22b8fa9ba53bef6e31386d5fa9b3
DISK_MEMBER="MSX-DOS 2 (English).dsk"
DISK_SHA256=e00558f0fc420db00b5f7f72f6d38b3f53fd462da3e6169cd63120f43e4d5733
DISK_SIZE=368640

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { printf '[msx2 %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() {
  echo "[msx2] ERROR: $*" >&2
  exit 1
}

fetch_verify() {
  local dest="$1" url="$2" sha="$3"
  if [ "$FORCE" -eq 1 ] || [ ! -s "$dest" ] || [ "$(sha256sum "$dest" | awk '{print $1}')" != "$sha" ]; then
    log "fetching $(basename "$dest")"
    mkdir -p "$(dirname "$dest")"
    curl -sL -A "Mozilla/5.0" -o "$dest.tmp" "$url" || die "could not fetch $url"
    mv "$dest.tmp" "$dest"
  fi
  [ "$(sha256sum "$dest" | awk '{print $1}')" = "$sha" ] ||
    die "$(basename "$dest") sha256 mismatch (expected $sha)"
}

fetch_verify "$ROMS_ZIP" "$ROMS_ZIP_URL" "$ROMS_ZIP_SHA256"
fetch_verify "$DISK_ZIP" "$DISK_ZIP_URL" "$DISK_ZIP_SHA256"
log "roms + disk zip staged and hash-verified"

mkdir -p "$ASSETS/media"
unzip -p "$DISK_ZIP" "$DISK_MEMBER" >"$ASSETS/media/msxdos2-english.dsk.tmp"
[ "$(stat -c %s "$ASSETS/media/msxdos2-english.dsk.tmp")" -eq "$DISK_SIZE" ] ||
  die "extracted disk is not $DISK_SIZE bytes"
[ "$(sha256sum "$ASSETS/media/msxdos2-english.dsk.tmp" | awk '{print $1}')" = "$DISK_SHA256" ] ||
  die "extracted disk sha256 mismatch (expected $DISK_SHA256)"
mv "$ASSETS/media/msxdos2-english.dsk.tmp" "$ASSETS/media/msxdos2-english.dsk"
log "MSX-DOS 2 (English).dsk staged at $ASSETS/media/msxdos2-english.dsk ($DISK_SIZE B, hash-verified)"

log "romset ($ROMS_ZIP) is staged for build-mame-native.sh's native_stage_roms"
log "PASS: msx2 media staged; run build-mame-native.sh msx2 to build/prove the emulator"
