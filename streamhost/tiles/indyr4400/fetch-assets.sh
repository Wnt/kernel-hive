#!/bin/bash
# fetch-assets.sh — stage the large IRIX disk asset the indyr4400 tile needs at
# runtime. It is NOT committed to the repo (a 6.3 GB IRIX 6.5 disk image, and
# the repo is PUBLIC); this script documents, derives and verifies it, the same
# way streamhost/tiles/irix/fetch-assets.sh does for the MAME tile's CHD.
#
# WHAT THE ASSET IS
#   /data/gallery-guests/IrisIndy/irix65-r4400-disk.ext4
#     A read-only ext4 filesystem image whose single file is `disk.raw`, a
#     6,291,456,000-byte raw SGI disk carrying the gallery's own IRIX 6.5.22
#     install. It is DERIVED from this lab's existing irix-tile golden
#     (irix65-apps.chd) with `chdman extracthd`, so there is no third-party
#     download and no new licence question: it is the same preservation-class
#     media the irix tile already runs, in a container Iris can open.
#
# WHY A FILESYSTEM IMAGE AND NOT THE BARE RAW DISK
#   The tile attaches this asset to the bridge guest as a SECOND, READ-ONLY
#   virtio drive so the 6.3 GB never enters the tile's qcow2 overlay. Iris sizes
#   a disk with `File::metadata().len()`, which is 0 for a block device, so it
#   cannot be pointed at /dev/vda directly — it needs a regular FILE. Wrapping
#   the raw disk in a read-only ext4 the guest mounts gives Iris exactly that,
#   and keeps the asset immutable. Iris then runs with `overlay = true`, so its
#   copy-on-write file lands on the guest's own writable disk (inside the tile
#   overlay, and therefore inside the `golden` snapshot).
#
# Run ON the box (root). Idempotent, read-only with respect to the live irix
# tile: it only ever READS a copy of that tile's CHD, never the tile itself.
set -euo pipefail

ASSET_DIR="${IRISINDY_ASSETS:-/data/gallery-guests/IrisIndy}"
ASSET="${ASSET_DIR}/irix65-r4400-disk.ext4"
# Measured sha256 of the raw SGI disk INSIDE the image. The ext4 container's own
# hash is not reproducible (mkfs stamps a random UUID), so this is the check
# that actually means something.
INNER_SHA256="b8214c34a2983ce9f2b0781ef56a7a71971da2e3dbcb87cc7f1f990f822b1c61"
INNER_SIZE=6291456000
SRC_CHD="${IRISINDY_SRC_CHD:-/data/vms/streamhost/assets/irix/irix65-apps.chd}"

echo "== indyr4400 tile asset check =="

if [ ! -f "$ASSET" ]; then
  cat >&2 <<EOF
  MISS IRIX 6.5 disk asset: $ASSET

Rebuild recipe (needs ~7 GB free and chdman from the mame-tools package):
  # 1. Work on a COPY of the irix tile's golden CHD. Never open the live one.
  install -d -m 0755 "$ASSET_DIR"
  W=\$(mktemp -d /data/vms/soltest/irisindy-asset-XXXX)
  cp "$SRC_CHD" "\$W/disk.chd"
  chdman extracthd -i "\$W/disk.chd" -o "\$W/disk.raw"
  # 2. Wrap it in a read-only ext4 the bridge guest can mount.
  truncate -s 6500M "$ASSET"
  mkfs.ext4 -q -F -m 0 -N 32 -L IRISINDY "$ASSET"
  M=\$(mktemp -d); mount -o loop "$ASSET" "\$M"
  cp --sparse=always "\$W/disk.raw" "\$M/disk.raw"
  sync; umount "\$M"; rmdir "\$M"; rm -rf "\$W"
EOF
  exit 1
fi

echo "  OK   asset present: $ASSET ($(du -h --apparent-size "$ASSET" | cut -f1) apparent, $(du -h "$ASSET" | cut -f1) allocated)"

# Verify the inner disk, not the container. Skip with IRISINDY_SKIP_HASH=1 when
# a caller only needs the presence check (hashing 6.3 GB takes ~30 s).
if [ "${IRISINDY_SKIP_HASH:-0}" != "1" ]; then
  M=$(mktemp -d)
  mount -o loop,ro "$ASSET" "$M"
  sz=$(stat -c %s "$M/disk.raw")
  got=$(sha256sum "$M/disk.raw" | cut -d' ' -f1)
  umount "$M"
  rmdir "$M"
  [ "$sz" = "$INNER_SIZE" ] || {
    echo "  FAIL inner disk.raw size $sz != $INNER_SIZE" >&2
    exit 1
  }
  [ "$got" = "$INNER_SHA256" ] || {
    echo "  FAIL inner disk.raw sha256 $got != $INNER_SHA256" >&2
    exit 1
  }
  echo "  OK   inner disk.raw verified ($INNER_SIZE bytes, sha256 ${INNER_SHA256:0:16}...)"
fi

# The asset is the exhibit's only copy of the IRIX install and the tile mounts
# it read-only, but root ignores mode bits — make that structural.
chmod 444 "$ASSET" 2>/dev/null || true
chattr +i "$ASSET" 2>/dev/null || true
lsattr "$ASSET" 2>/dev/null || true

echo "== indyr4400 tile assets present =="
