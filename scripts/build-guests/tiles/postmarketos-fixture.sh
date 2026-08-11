#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/postmarketos-fixture.sh — complete the raw postmarketOS builder
# output into the streamhost artifact: qcow2 disk + offline fixture provision +
# writable qcow2 OVMF varstore + internal `golden` savevm snapshot.
#
# Default one-command path:
#   scripts/build-guests/tiles/postmarketos-fixture.sh
#
# It first runs postmarketos.sh (download/decompress/framebuffer proof), then
# invokes the faithfully-vendored station helpers. The fixture provisioner converts
# pmos-phosh.img -> pmos-phosh.qcow2, sets PIN 147147, installs the phosh
# autostart fixture, and disables the tour. This wrapper then cold-boots the
# tracked streamhost launcher, unlocks phosh, lets GNOME Console settle, and
# saves `golden` into both writable qcow2 devices.
#
# Options:
#   --skip-build     reuse the canonical pmos-phosh.img
#   --prepare-only   stop after conversion/offline provisioning; print bake cmd
#   -h|--help
#
# Environment:
#   PMOS_NBD=/dev/nbdN       qemu-nbd device (default /dev/nbd0)
#   PMOS_BOOT_WAIT=120       seconds to wait for phosh lockscreen
#   PMOS_SETTLE_WAIT=30      seconds after PIN unlock before savevm
#   PMOS_FIXTURE_FORCE=1     back up and recreate existing qcow2/varstore
#   PMOS_SKIP_DOWNLOAD, PMOS_FORCE, PMOS_NO_VERIFY, ... pass to postmarketos.sh
#
# Run on a fresh/stopped station. This script refuses to disturb a live QEMU pid.
# It starts no streamhost service and stops its own QEMU through QMP/pidfile.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
RAW_BUILDER="$HERE/../stages/postmarketos.sh"
FIXTURE_DIR="$REPO_ROOT/streamhost/tiles/postmarketos"
PROVISION="$FIXTURE_DIR/golden-fixture-provision.sh"
LAUNCHER="$FIXTURE_DIR/qemu-streamhost.sh"

GUEST_DIR=/data/gallery-guests/postmarketOS
TILE_DIR=/data/vms/streamhost/tiles/postmarketos
RAW="$GUEST_DIR/pmos-phosh.img"
QCOW="$GUEST_DIR/pmos-phosh.qcow2"
VARS_SRC="${OVMF_VARS_SRC:-/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd}"
VARS_PRISTINE="$TILE_DIR/OVMF_VARS.fd.pristine"
VARS_QCOW="$TILE_DIR/OVMF_VARS.qcow2"
QMP="$TILE_DIR/qmp.sock"
PIDFILE="$TILE_DIR/qemu.pid"
NBD="${PMOS_NBD:-/dev/nbd0}"
BOOT_WAIT="${PMOS_BOOT_WAIT:-120}"
SETTLE_WAIT="${PMOS_SETTLE_WAIT:-30}"
PIN="${PMOS_PIN:-147147}"
SKIP_BUILD=0
PREPARE_ONLY=0

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --prepare-only)
      PREPARE_ONLY=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

log() { printf '[pmos-fixture %(%H:%M:%S)T] %s\n' -1 "$*"; }
die() {
  printf '[pmos-fixture ERROR] %s\n' "$*" >&2
  exit 1
}

for f in "$RAW_BUILDER" "$PROVISION" "$FIXTURE_DIR/golden-fixture.sh" "$LAUNCHER"; do
  [ -f "$f" ] || die "required repo file missing: $f"
done
for b in qemu-img python3 install; do command -v "$b" >/dev/null 2>&1 || die "missing tool: $b"; done
[ -r "$VARS_SRC" ] || die "OVMF vars template missing: $VARS_SRC"
mkdir -p "$GUEST_DIR" "$TILE_DIR"

if [ -s "$PIDFILE" ]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -z "$oldpid" ] || ! kill -0 "$oldpid" 2>/dev/null ||
    die "postmarketos QEMU is already running (pid $oldpid); stop it deliberately first"
fi

if [ "$SKIP_BUILD" = 0 ]; then
  log "stage 1: official raw image builder"
  bash "$RAW_BUILDER"
fi
[ -s "$RAW" ] || die "raw image missing: $RAW"

if [ -n "${PMOS_FIXTURE_FORCE:-}" ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  for f in "$QCOW" "$VARS_QCOW"; do
    if [ -e "$f" ]; then
      log "backup $f -> $f.bak-$stamp"
      mv "$f" "$f.bak-$stamp"
    fi
  done
fi

# The vendored provisioner deliberately consumes a pristine station-local raw
# varstore. Keep that historical contract while sourcing it canonically from
# the installed Proxmox firmware package.
if [ ! -s "$VARS_PRISTINE" ]; then
  install -m 0444 "$VARS_SRC" "$VARS_PRISTINE"
fi

log "stage 2: raw->qcow2 conversion + offline fixture provision (NBD=$NBD)"
NBD="$NBD" bash "$PROVISION"
[ -s "$QCOW" ] || die "fixture provision did not create $QCOW"
[ -s "$VARS_QCOW" ] || die "fixture provision did not create $VARS_QCOW"
qemu-img info "$QCOW" | grep -q "file format: qcow2" || die "not qcow2: $QCOW"
qemu-img info "$VARS_QCOW" | grep -q "file format: qcow2" || die "not qcow2: $VARS_QCOW"

if [ "$PREPARE_ONLY" = 1 ]; then
  cat <<EOF
[pmos-fixture] prepared disk + varstore. Complete the bake with:
  PMOS_SKIP_DOWNLOAD=1 $0 --skip-build
EOF
  exit 0
fi

qmp_raw() {
  python3 - "$QMP" "$1" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sys.argv[1])
f=s.makefile('rwb',buffering=0); f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    o=json.loads(f.readline())
    if 'return' in o or 'error' in o: break
f.write(sys.argv[2].encode()+b'\n')
while True:
    o=json.loads(f.readline())
    if 'return' in o:
        if o['return'] not in ({},''): print(o['return'])
        break
    if 'error' in o: raise SystemExit('QMP error: '+json.dumps(o['error']))
s.close()
PY
}

hmp() {
  local json
  json="$(
    python3 - "$1" <<'PY'
import json,sys
print(json.dumps({'execute':'human-monitor-command','arguments':{'command-line':sys.argv[1]}}))
PY
  )"
  qmp_raw "$json"
}

stop_own_qemu() {
  local pid=""
  [ -s "$PIDFILE" ] && pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -S "$QMP" ]; then qmp_raw '{"execute":"quit"}' >/dev/null 2>&1 || true; fi
  if [ -n "$pid" ]; then
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep .2
    done
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$QMP" "$PIDFILE"
}
trap stop_own_qemu EXIT INT TERM

# An idempotent rebuild may inherit the prior fixture snapshot. The tracked
# launcher automatically adds `-loadvm golden` whenever that tag exists, which
# would bypass the lockscreen and type the PIN into the already-open Console.
# Remove the old coordinated tags before the declared cold boot; stage 3 saves
# a fresh multi-device snapshot after provisioning and unlock.
for image in "$QCOW" "$VARS_QCOW"; do
  if qemu-img snapshot -l "$image" | awk '{print $2}' | grep -qx golden; then
    log "delete stale golden before cold boot: $image"
    qemu-img snapshot -d golden "$image"
  fi
done

log "stage 3: cold boot tracked tile device set (no golden exists yet)"
bash "$LAUNCHER"
for _ in $(seq 1 60); do
  [ -S "$QMP" ] && [ -s "$PIDFILE" ] && break
  sleep .5
done
[ -S "$QMP" ] || die "tile QMP socket did not appear"
log "wait ${BOOT_WAIT}s for UEFI + phosh lockscreen"
sleep "$BOOT_WAIT"
hmp 'sendkey ctrl' >/dev/null
sleep 1
for ((i = 0; i < ${#PIN}; i++)); do
  hmp "sendkey ${PIN:i:1}" >/dev/null
  sleep .2
done
hmp 'sendkey ret' >/dev/null
log "PIN submitted; wait ${SETTLE_WAIT}s for fixture autostart + GNOME Console"
sleep "$SETTLE_WAIT"

hmp 'delvm golden' >/dev/null 2>&1 || true
hmp 'savevm golden' >/dev/null
SNAPS="$(hmp 'info snapshots')"
grep -qw golden <<<"$SNAPS" || die "savevm golden did not land"
log "golden snapshot created"
stop_own_qemu
trap - EXIT INT TERM

qemu-img snapshot -l "$QCOW" | awk '{print $2}' | grep -qx golden || die "golden absent from $QCOW"
qemu-img snapshot -l "$VARS_QCOW" | awk '{print $2}' | grep -qx golden || die "golden absent from $VARS_QCOW"
qemu-img check "$QCOW"
log "DONE: $QCOW + $VARS_QCOW contain golden"
