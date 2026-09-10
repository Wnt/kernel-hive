#!/bin/bash
# fetch-assets.sh — stage the large IRIX disk asset the indyr4400 station needs
# at runtime. It is NOT committed to the repo (a 6.3 GB IRIX 6.5 disk image, and
# the repo is PUBLIC); this script documents, derives and verifies it, the same
# way streamhost/stations/irix/fetch-assets.sh does for the MAME station's CHD.
#
# WHAT THE ASSET IS
#   /data/gallery-guests/IrisIndy/irix65-r4400-disk.raw
#     A 6,291,456,000-byte raw SGI disk carrying the gallery's own IRIX 6.5.22
#     install, held IMMUTABLE and opened read-only. It is DERIVED from this
#     lab's existing irix-station golden (irix65-apps.chd) with
#     `chdman extracthd`, so there is no third-party download and no new licence
#     question: it is the same preservation-class media the irix station already
#     runs, in a container Iris can open.
#
# WHY THIS IS A PLAIN FILE NOW, AND NOT THE ext4 WRAPPER IT USED TO BE
#   The bridge era wrapped this raw disk in a read-only ext4 image for one
#   reason: the asset was attached to a QEMU KIOSK as a second virtio drive, and
#   Iris sizes a disk with `File::metadata().len()` — which is 0 for a block
#   device — so it could not be pointed at /dev/vdb and needed a regular file
#   inside a mountable filesystem. HOST-NATIVE there is no guest and no block
#   device: Iris opens the file directly, bound read-only into its container at
#   this same path. The wrapper is retired with the kiosk that needed it, and
#   this script converts the old one in place if that is what it finds.
#
#   The asset is never dirtied: the launcher symlinks it into the container's
#   writable work dir and runs Iris with `overlay = true`, so every guest write
#   lands in work/disk.raw.overlay and is thrown away on the next launch.
#
# Run ON the box (root). Idempotent, and read-only with respect to the live irix
# station: it only ever READS a copy of that station's CHD, never the station.
#
# usage: fetch-assets.sh [--convert]   (--convert rebuilds the raw from the
#        legacy ext4 wrapper if the wrapper is present and the raw is not)
set -euo pipefail

ASSET_DIR="${IRISINDY_ASSETS:-/data/gallery-guests/IrisIndy}"
ASSET="${ASSET_DIR}/irix65-r4400-disk.raw"
LEGACY="${ASSET_DIR}/irix65-r4400-disk.ext4"
# Measured sha256 of the raw SGI disk. Under the old ext4 wrapper this was the
# hash of the file INSIDE the image (the container's own hash is not
# reproducible — mkfs stamps a random UUID); the raw asset IS that file, so the
# number is unchanged and the two eras verify against the same constant.
SHA256="b8214c34a2983ce9f2b0781ef56a7a71971da2e3dbcb87cc7f1f990f822b1c61"
SIZE=6291456000
SRC_CHD="${IRISINDY_SRC_CHD:-/data/vms/streamhost/assets/irix/irix65-apps.chd}"
CONVERT=0
[ "${1:-}" = "--convert" ] && CONVERT=1

echo "== indyr4400 station asset check =="

if [ ! -f "$ASSET" ] && [ -f "$LEGACY" ] && [ "$CONVERT" -eq 1 ]; then
  echo "  .... unwrapping the legacy ext4 asset into a plain raw disk"
  M="$(mktemp -d)"
  mount -o loop,ro "$LEGACY" "$M"
  cp --sparse=always "$M/disk.raw" "$ASSET.part"
  umount "$M"
  rmdir "$M"
  mv "$ASSET.part" "$ASSET"
fi

if [ ! -f "$ASSET" ]; then
  cat >&2 <<EOF
  MISS IRIX 6.5 disk asset: $ASSET

If the legacy ext4 wrapper is still present, unwrap it:
  $0 --convert

Otherwise rebuild it (needs ~7 GB free and chdman from the mame-tools package):
  # Work on a COPY of the irix station's golden CHD. Never open the live one.
  install -d -m 0755 "$ASSET_DIR"
  W=\$(mktemp -d /data/vms/sandbox/irisindy-asset-XXXX)
  cp "$SRC_CHD" "\$W/disk.chd"
  chdman extracthd -i "\$W/disk.chd" -o "$ASSET"
  rm -rf "\$W"
EOF
  exit 1
fi

echo "  OK   asset present: $ASSET ($(du -h --apparent-size "$ASSET" | cut -f1) apparent, $(du -h "$ASSET" | cut -f1) allocated)"

# Skip with IRISINDY_SKIP_HASH=1 when a caller only needs the presence check
# (hashing 6.3 GB takes ~30 s).
if [ "${IRISINDY_SKIP_HASH:-0}" != "1" ]; then
  sz="$(stat -c %s "$ASSET")"
  [ "$sz" = "$SIZE" ] || {
    echo "  FAIL disk size $sz != $SIZE" >&2
    exit 1
  }
  got="$(sha256sum "$ASSET" | cut -d' ' -f1)"
  [ "$got" = "$SHA256" ] || {
    echo "  FAIL disk sha256 $got != $SHA256" >&2
    exit 1
  }
  echo "  OK   disk verified ($SIZE bytes, sha256 ${SHA256:0:16}...)"
fi

# The asset is the exhibit's only copy of the IRIX install and the container
# binds it read-only, but root ignores mode bits — make that structural.
chmod 444 "$ASSET" 2>/dev/null || true
chattr +i "$ASSET" 2>/dev/null || true
lsattr "$ASSET" 2>/dev/null || true

echo "== indyr4400 station assets present =="
