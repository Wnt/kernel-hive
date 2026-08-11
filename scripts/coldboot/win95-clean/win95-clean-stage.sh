#!/bin/bash
# Stage the PREPPED clean disk for record-boot.sh via a BOOTREC_TILES_ROOT override.
# The staged launcher is the LIVE launcher with ONLY D= redirected to the staged dir,
# so record-boot's clone rewrite (sed $TILE_DIR -> $CLONE_DIR) redirects everything
# into the clone (and never the live station).
set -euo pipefail
LIVE_DIR=/data/vms/streamhost/stations/win95
PREP=/data/vms/soltest/win95-clean-prep
STAGEROOT=/data/vms/soltest/win95-clean-stage
SDIR="$STAGEROOT/win95"

rm -rf "$STAGEROOT"
mkdir -p "$SDIR"

echo "== staged launcher: copy live, redirect D= only =="
sed "s#^D=${LIVE_DIR}#D=${SDIR}#" "$LIVE_DIR/qemu-streamhost.sh" >"$SDIR/qemu-streamhost.sh"
chmod +x "$SDIR/qemu-streamhost.sh"
echo "-- D= line + device set --"
grep -nE '^D=|-drive|-device|-machine|-cpu|-vga|-audiodev|hostfwd|LOADVM' "$SDIR/qemu-streamhost.sh"
grep -q "^D=${SDIR}\$" "$SDIR/qemu-streamhost.sh" && echo "  D= redirected OK" || {
  echo "  FAIL: D= not redirected"
  exit 1
}
# make sure NO live station path leaks into the staged launcher
if grep -q "${LIVE_DIR}" "$SDIR/qemu-streamhost.sh"; then
  echo "  FAIL: live tile path still present"
  exit 1
fi
echo "  no live tile path leak OK"

echo "== copy PREPPED clean disk into staged dir =="
cp --reflink=auto -f "$PREP/win95-golden.qcow2" "$SDIR/win95-golden.qcow2"
ls -la "$SDIR/win95-golden.qcow2"
qemu-img snapshot -l "$SDIR/win95-golden.qcow2"

echo "== clean-desktop Tier-2 reference (boot-ref-desktop.png) =="
ffmpeg -hide_banner -y -i /root/boot-ref-desktop-clean.ppm "$SDIR/boot-ref-desktop.png" >/dev/null 2>&1
ls -la "$SDIR/boot-ref-desktop.png"
echo "== staged dir =="
ls -la "$SDIR"
