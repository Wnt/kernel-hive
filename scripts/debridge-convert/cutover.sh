#!/bin/bash
# cutover.sh <station> — LIVE swap of one MAME bridge kiosk to host-native.
# Run ON THE BOX from the repo mirror (/data/kernel-hive), AFTER
# build-mame-native.sh <station> has produced binary+roms and the station's
# registry entry carries the runtime.x11 shape (registry-to-native.py).
#
# What it does, in order:
#   1. emit the station kit (station.env / x11-runtime.sh / aux) from the
#      registry's own emitArgs into a scratch dir
#   2. stop streamhost@<station> — the kiosk QEMU dies with the unit cgroup
#   3. canary the station's daemon pool to the campaign artifact
#      (previous -> old current, so rollback stays one symlink away)
#   4. install the kit; shelve the kiosk launcher and overlay as
#      *.debridged-bak (the operator's one-move rollback)
#   5. start the unit — ExecStartPre sees SH_STATION_RUNTIME=x11 and launches
#      host-native MAME — and print the smoke facts
#
# Golden savestates are NOT baked here: scenes with typed content (armeval)
# curate theirs first; untouched-power-on stations just SAVEST after this.
set -euo pipefail

TILE="${1:?usage: cutover.sh <station>}"
REPO=/data/kernel-hive
B="/data/vms/streamhost/stations/$TILE"
POOL="/usr/local/lib/streamhost/stations/$TILE"
NEW=streamhost-cb701260035a06aacf2ceef2d83f7df829ab4775
SCRATCH=/tmp/emit-668c8ea1

[ -x "/usr/local/lib/streamhost/$NEW" ] || {
  echo "campaign daemon artifact missing: $NEW" >&2
  exit 1
}

mapfile -t ARGS < <(
  python3 - "$REPO/registry/stations/$TILE.json" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1]))
for a in doc["runtime"]["x11"]["emitArgs"]:
    print(a.replace("$T", "streamhost/stations"))
PY
)

cd "$REPO"
streamhost/scripts/streamhost-station.sh "${ARGS[@]}" --out-root "$SCRATCH"

systemctl stop "streamhost@$TILE" || true

OLD="$(readlink "$POOL/current")"
case "$OLD" in
  *cb701260*) ;; # already canaried (a re-run)
  *)
    ln -sfn "$OLD" "$POOL/previous"
    ln -sfn "../../$NEW" "$POOL/current"
    ;;
esac

for f in "$SCRATCH/$TILE"/*; do
  install -m 644 "$f" "$B/$(basename "$f")"
done
chmod 755 "$B/x11-runtime.sh"
[ -f "$B/qemu-streamhost.sh" ] && mv "$B/qemu-streamhost.sh" "$B/qemu-streamhost.sh.debridged-bak"
[ -f "$B/overlay.qcow2" ] && mv "$B/overlay.qcow2" "$B/overlay.qcow2.debridged-bak"

systemctl start "streamhost@$TILE"
sleep 8
echo "unit: $(systemctl is-active "streamhost@$TILE")"
echo "pool: current -> $(readlink "$POOL/current")"
if [ -f "$B/qemu.pid" ] && kill -0 "$(cat "$B/qemu.pid")" 2>/dev/null; then
  echo "WARNING: old kiosk QEMU still alive ($(cat "$B/qemu.pid"))"
else
  echo "kiosk qemu: gone"
fi
journalctl -u "streamhost@$TILE" -n 40 --no-pager | grep -im2 "keymap\|capture=shm" || true
python3 - "$B/fb.shm" <<'PY' || echo "fb.shm not readable yet"
import collections
import struct
import sys

b = open(sys.argv[1], "rb").read()
_m, _v, w, h, stride, _bpp = struct.unpack_from("<6I", b, 0)
px = struct.unpack_from("<%dI" % (w * 4), b, 64 + (h // 2) * stride)
print("midrow:", ["%08x:%d" % kv for kv in collections.Counter(px).most_common(3)])
PY
echo "cutover $TILE: done (rollback: ROLLBACK.md + *.debridged-bak + pool previous)"
