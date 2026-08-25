#!/bin/bash
# nextstep-cutover.sh — the LIVE swap of the nextstep bridge kiosk to host-native.
#
# Run ON THE BOX, from a repo checkout that already carries the station's
# runtime.x11 registry shape (this is that checkout). Sibling of
# scripts/debridge-convert/cutover.sh, which the nine MAME kiosks used; this
# station needs two things that one does not:
#
#   * ASSETS. The emulator binary, the NeXT ROM and the guest disk are staged
#     under /data/vms/streamhost/assets/nextstep first. They are not in the repo
#     and never will be.
#   * A GOLDEN BAKED IN PLACE. A CRIU image records the ABSOLUTE PATH of every
#     open file and the network namespace BY NAME, so a golden baked on a
#     bring-up rig cannot be copied onto the station. The cutover therefore
#     lands on a COLD BOOT (~135 s, and a degraded relative pointer), and
#     nextstep-scene.py + nextstep-bake-golden.sh produce the golden here,
#     afterwards. Budget ~20 minutes of degraded exhibit for that.
#
# No daemon canary: nextstep already runs the same artifact irix and the
# de-bridged MAME stations do, and that binary already speaks shm + mamesock +
# fifo. If that ever stops being true, canary FIRST with
# scripts/dev/build-deploy.sh --canary nextstep.
#
#   nextstep-cutover.sh stage <src-assets-dir>   copy binary/ROM/disk into place
#   nextstep-cutover.sh swap                     emit + stop + install + start
set -euo pipefail

TILE=nextstep
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
B="/data/vms/streamhost/stations/$TILE"
A="/data/vms/streamhost/assets/$TILE"
SCRATCH="${SCRATCH:-/tmp/emit-$TILE-$$}"

say() { echo "cutover: $*"; }

stage() {
  local src="${1:?usage: nextstep-cutover.sh stage <src-assets-dir>}"
  mkdir -p "$A/state"
  chmod 755 "$A"
  install -m 755 "$src/previous" "$A/previous"
  install -m 644 "$src/Rev_2.5_v66.BIN" "$A/Rev_2.5_v66.BIN"
  # The COLD-BOOT disk: a cleanly halted NeXTSTEP carrying the tablet driver,
  # the rc.local hook, the trimmed inetd.conf, the retronet addressing, OmniWeb
  # and its Dock icon. Reflinked, so it costs nothing on this filesystem.
  rm -f "$A/NS33.dd"
  cp --reflink=auto "$src/NS33.dd" "$A/NS33.dd"
  chmod 644 "$A/NS33.dd"
  say "staged $(md5sum "$A/previous" | cut -c1-12) previous, ROM, NS33.dd into $A"
}

swap() {
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

  say "stopping the unit — the kiosk QEMU dies with its cgroup"
  systemctl stop "streamhost@$TILE" || true
  sleep 3

  for f in "$SCRATCH/$TILE"/*; do
    install -m 644 "$f" "$B/$(basename "$f")"
  done
  chmod 755 "$B/x11-runtime.sh" "$B/rn-tapnet.sh" "$B/ctl.py"
  # The operator's one-move rollback. Nothing is deleted, ever, without them.
  [ -f "$B/qemu-streamhost.sh" ] && mv "$B/qemu-streamhost.sh" "$B/qemu-streamhost.sh.debridged-bak"
  [ -f "$B/overlay.qcow2" ] && mv "$B/overlay.qcow2" "$B/overlay.qcow2.debridged-bak"
  rm -f "$B/qmp.sock" "$B/qemu.pid"

  # The labctl matrix is box-authored; merge THIS station's declared row in
  # additively rather than regenerating the whole file, which fails closed on
  # live stations that have no declaration yet.
  python3 - "$REPO/registry/generated/labctl-declarations.json" <<'PY'
import json
import sys

live = "/data/vms/streamhost/stations.json"
declared = json.load(open(sys.argv[1]))["tiles"]["nextstep"]
doc = json.load(open(live))
doc["tiles"]["nextstep"] = {**doc["tiles"]["nextstep"], **declared}
doc["tiles"]["nextstep"].pop("golden_snapshot", None)
doc["tiles"]["nextstep"]["reset_mode"] = "relaunch"
import os

tmp = live + ".tmp"
with open(tmp, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
# 0644, explicitly: this file is the fleet's labctl matrix and EVERY agent's
# generated-file drift check reads it. Written under systemd's 0077 umask it
# comes out 0600 root and turns that check into a Permission denied for
# everyone else -- a fleet-wide gate failure caused by one station's cutover.
os.chmod(tmp, 0o644)
os.replace(tmp, live)
print("labctl matrix: nextstep row updated")
PY

  systemctl start "streamhost@$TILE"
  sleep 10
  say "unit: $(systemctl is-active "streamhost@$TILE")"
  if [ -f "$B/qemu.pid" ] && kill -0 "$(cat "$B/qemu.pid")" 2>/dev/null; then
    say "WARNING: old kiosk QEMU still alive"
  else
    say "kiosk qemu: gone"
  fi
  say "rollback: $B/ROLLBACK.md + *.debridged-bak"
}

case "${1:-}" in
  stage)
    shift
    stage "$@"
    ;;
  swap) swap ;;
  *)
    sed -n '2,26p' "$0" >&2
    exit 2
    ;;
esac
