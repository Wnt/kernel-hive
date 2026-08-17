#!/usr/bin/env bash
# Launch the Track A golden SAFELY.
#
# MAME opens -hard1 READ-WRITE and the rig runs as root, so chmod 444 does NOT
# protect the golden -- a plain launch silently mutates it (observed: md5 and
# file size both changed after a single verification boot; `chattr +i` blocks
# MAME entirely with "Operation not permitted"). ZFS block cloning gives a
# 2.24 GB copy-on-write clone in ~0.13 s, so every launch gets its own writable
# clone and the golden is never opened.
set -euo pipefail
D="${IRIX_APPS_DIR:-/data/vms/sandbox/irix-apps}"
GOLDEN="${IRIX_GOLDEN_APPS:-$D/irix65-apps.chd}"
RUN="$D/run.chd"
rm -f "$RUN"
cp --reflink=always "$GOLDEN" "$RUN"
IRIX_APPS_CHD="$RUN" exec bash "$D/irix-apps-launch.sh" "$@"
