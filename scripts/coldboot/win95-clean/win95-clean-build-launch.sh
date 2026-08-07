#!/bin/bash
# Build the prep-clone launcher (identical device set to LIVE, COLD boot, hostfwd 59791)
# and cold-boot the prepped disk. Kill only by pidfile.
set -euo pipefail
LIVE_DIR=/data/vms/streamhost/tiles/win95
PREP=/data/vms/soltest/win95-clean-prep
LAUNCH="$PREP/qemu-streamhost.sh"

# stop any stale clone by pidfile
[ -f "$PREP/qemu.pid" ] && kill "$(cat "$PREP/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$PREP/qmp.sock" "$PREP/qemu.pid"

# transform: redirect tile dir, rename, bump hostfwd, neutralise loadvm (cold boot)
sed -e "s#${LIVE_DIR}#${PREP}#g" \
  -e "s/-name streamhost-win95/-name streamhost-win95-cleanprep/" \
  -e "s/hostfwd=tcp:127.0.0.1:57791-/hostfwd=tcp:127.0.0.1:59791-/g" \
  -e 's/LOADVM="-loadvm golden"/LOADVM=""/' \
  "$LIVE_DIR/qemu-streamhost.sh" >"$LAUNCH"
chmod +x "$LAUNCH"

echo "== verify cold-boot + device set in the rewritten launcher =="
grep -nE 'LOADVM|hostfwd|-name|qmp.sock|qemu.pid|-drive|-device|-machine|-cpu|-vga|-audiodev' "$LAUNCH"
grep -q 'LOADVM=""' "$LAUNCH" && echo "  loadvm neutralised (cold boot) OK" || {
  echo "  FAIL: loadvm not neutralised"
  exit 1
}

echo "== cold-boot prep clone =="
bash "$LAUNCH"
sleep 1
echo "pid=$(cat "$PREP/qemu.pid" 2>/dev/null)  qmp=$PREP/qmp.sock"
