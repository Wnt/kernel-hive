#!/bin/bash
# DRAFT ONLY: stage pinned EKA2L1 runtime + Nokia S60 firmware package.
set -euo pipefail
WORK="${WORK:-/data/vms/build-symbians60}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/symbians60}"
EKA_SOURCE="${EKA_SOURCE:-}"
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
mkdir -p "$WORK" "$ASSETS/eka2l1" "$ASSETS/firmware"
[ -n "$EKA_SOURCE" ] || { echo "set EKA_SOURCE to pinned EKA2L1 Linux artifact/source tree" >&2; exit 2; }
[ -n "$FIRMWARE_DIR" ] || { echo "set FIRMWARE_DIR to complete Nokia firmware/VPL directory" >&2; exit 2; }
case "$EKA_SOURCE" in
  http://*|https://*) curl -fL --retry 3 -o "$WORK/eka2l1.archive" "$EKA_SOURCE" ;;
  *) cp -a "$EKA_SOURCE" "$WORK/eka2l1.source" ;;
esac
cp -a "$FIRMWARE_DIR/." "$ASSETS/firmware/"
find "$ASSETS/firmware" -type f -print0 | sort -z | xargs -0 sha256sum >"$ASSETS/firmware/MANIFEST.sha256"
cat >&2 <<'EOF'
LAB STEP:
  run EKA2L1 once under Xvfb;
  File -> Install Device -> Firmware/VPL;
  select the staged Nokia 5320 VPL and an English-capable variant;
  after boot, identify EKA2L1's device-data directory and copy it to assets/symbians60/device-seed;
  production reset clones device-seed to a writable work directory.
EOF
