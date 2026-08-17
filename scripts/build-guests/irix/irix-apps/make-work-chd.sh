#!/usr/bin/env bash
# Build a WRITABLE, GROWN working copy of the pristine IRIX golden CHD.
#
# The golden /data/vms/sandbox/irix-mame/irix65.chd is chmod 444 and is only
# ever read. This produces /data/vms/sandbox/irix-apps/work.chd with the root
# XFS grown from 1.87 GiB to WORK_GB, ready for the Track A app/demo installs.
#
# Host-side only: no MAME is started anywhere in this script.
set -euo pipefail

GOLDEN="${IRIX_GOLDEN:-/data/vms/sandbox/irix-mame/irix65.chd}"
WORK="${IRIX_APPS_DIR:-/data/vms/sandbox/irix-apps}"
TOOLS="${IRIX_APPS_TOOLS:-$WORK}"
# 128 cyls x 16 heads x SECS sectors x 512 B. 6000 -> 6.29 GB total.
SECS="${IRIX_WORK_SECS:-6000}"

raw="$WORK/probe/work.raw"
out="$WORK/work.chd"
mnt="$WORK/probe/growmnt"

[ -r "$GOLDEN" ] || {
  echo "golden not readable: $GOLDEN" >&2
  exit 1
}
mode=$(stat -c %a "$GOLDEN")
[ "$mode" = 444 ] || {
  echo "REFUSING: golden $GOLDEN has mode $mode; it must stay chmod 444" >&2
  exit 1
}

mkdir -p "$WORK/probe" "$mnt"
rm -f "$raw" "$out"

echo "== extracting golden -> raw (read-only source)"
nice -n 19 chdman extractraw -i "$GOLDEN" -o "$raw" -f

first=$(python3 "$TOOLS/probe-chd.py" "$raw" | awk '/type=10 xfs/{print $2}' | sed 's/first=//')
[ -n "$first" ] || {
  echo "could not find the xfs partition offset" >&2
  exit 1
}

echo "== growing raw to 128x16x$SECS sectors"
truncate -s $((128 * 16 * SECS * 512)) "$raw"
python3 "$TOOLS/sgi-relabel.py" "$raw" "$SECS"

# The filesystem itself is grown IN-GUEST ("xfs_growfs /" as root in IRIX):
# IRIX replays its own XFS log, which Linux cannot ("dirty log written in
# incompatible format"). Forcing it host-side needs "xfs_repair -L", which
# discards the journal and dumps ~20 live inodes into lost+found -- avoid.
# IRIX_HOST_GROWFS=1 opts into that fallback anyway (verified to work).
if [ "${IRIX_HOST_GROWFS:-0}" = 1 ]; then
  echo "== host-side xfs_repair -L + xfs_growfs (offset $((first * 512)))"
  loop=$(losetup -f --show -o $((first * 512)) "$raw")
  trap 'umount "$mnt" 2>/dev/null || true; losetup -d "$loop" 2>/dev/null || true' EXIT
  xfs_repair -L "$loop"
  mount -t xfs "$loop" "$mnt"
  xfs_growfs "$mnt"
  df -h "$mnt"
  umount "$mnt"
  losetup -d "$loop"
  trap - EXIT
else
  echo "== skipping host-side growfs; run 'xfs_growfs /' in IRIX after first boot"
fi

echo "== verifying label + free space"
python3 "$TOOLS/probe-chd.py" "$raw"

echo "== packing raw -> work.chd"
nice -n 19 chdman createhd -i "$raw" -o "$out" -ss 512 -chs "128,16,$SECS" -c none -f
chdman info -i "$out"
rm -f "$raw"
echo "WORK CHD READY: $out"
