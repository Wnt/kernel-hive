#!/bin/bash
# golden-verify.sh <tileDir> [--bake]
#
# Clone-only proof for a vmstate golden.  It never opens a production QMP socket,
# never launches against a live writable disk, and routes teardown through
# clone-guard.  Per-tile disk/port/ready metadata comes from bootrec-tiles.conf.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
COLD_DIR="$HERE/../coldboot"
# shellcheck source=/dev/null
source "$COLD_DIR/bootrec-lib.sh"
# shellcheck source=/dev/null
source "$COLD_DIR/bootrec-tiles.conf"

usage() {
  echo "usage: $0 <tileDir> [--bake]" >&2
  exit 2
}

TILE="${1:-}"
MODE="${2:-}"
[ -n "$TILE" ] || usage
case "$MODE" in '' | --bake) ;; *) usage ;; esac
BAKE=0
[ "$MODE" = "--bake" ] && BAKE=1
[[ "$TILE" =~ ^[a-z0-9][a-z0-9-]*$ ]] || br_die "invalid tileDir '$TILE'"

bootrec_load_tile "$TILE"
[ "$BR_BOOT_KIND" = "vmstate" ] ||
  br_die "$TILE uses reset kind '$BR_BOOT_KIND'; golden-verify requires vmstate/loadvm"

TILE_DIR="$BOOTREC_TILES_ROOT/$TILE"
LAUNCHER="$TILE_DIR/qemu-streamhost.sh"
NAMESPACE="golden-verify-${TILE}-$$"
CLONE_DIR="$BOOTREC_CLONE_ROOT/$NAMESPACE"
CLONE_LAUNCHER="$CLONE_DIR/qemu-streamhost.sh"
CLONE_QMP="$CLONE_DIR/qmp.sock"
CLONE_PID="$CLONE_DIR/qemu.pid"
LABQMP=(python3 "$HERE/labqmp.py" "$CLONE_QMP")
IDLE_SECONDS="${GOLDEN_VERIFY_IDLE_SECONDS:-5}"
RESTORE_SECONDS="${GOLDEN_VERIFY_RESTORE_SECONDS:-2}"
SSIM_MIN="${GOLDEN_VERIFY_SSIM_MIN:-0.999}"
DIRTY_TEXT="${GOLDEN_VERIFY_DIRTY_TEXT:-golden-verify-dirty}"

log() { printf '[golden-verify:%s] %s\n' "$TILE" "$*" >&2; }

cleanup() {
  local rc=$?
  if [ -d "$CLONE_DIR" ]; then
    br_kill_pidfile "$CLONE_PID"
    clone_guard_assert_clone_path "$CLONE_DIR" "golden-verify clone" >/dev/null
    rm -rf --one-file-system "$CLONE_DIR"
  fi
  log "clone namespace torn down: $CLONE_DIR (rc=$rc)"
  exit "$rc"
}
trap cleanup EXIT INT TERM

copy_clone() {
  [ -f "$LAUNCHER" ] || br_die "launcher not found: $LAUNCHER"
  clone_guard_assert_clone_path "$CLONE_DIR" "golden-verify clone" >/dev/null
  mkdir -p "$CLONE_DIR"

  local disk spec src dst
  for disk in $BR_DISKS; do
    [ -f "$TILE_DIR/$disk" ] || br_die "configured disk not found: $TILE_DIR/$disk"
    log "cloning $disk (reflink when supported)"
    cp --reflink=auto -f "$TILE_DIR/$disk" "$CLONE_DIR/$disk"
  done
  for spec in "${BR_EXTERNAL_DISKS[@]}"; do
    src="${spec%%|*}"
    dst="${spec#*|}"
    [ -f "$src" ] || br_die "configured external disk not found: $src"
    log "cloning external disk $src -> $dst"
    cp --reflink=auto -f "$src" "$CLONE_DIR/$dst"
  done

  sed -e "s#${TILE_DIR}#${CLONE_DIR}#g" \
    -e "s/-name streamhost-${TILE}/-name ${NAMESPACE}/" \
    "$LAUNCHER" >"$CLONE_LAUNCHER"
  for spec in "${BR_EXTERNAL_DISKS[@]}"; do
    src="${spec%%|*}"
    dst="${spec#*|}"
    sed -i "s#${src}#${CLONE_DIR}/${dst}#g" "$CLONE_LAUNCHER"
  done
  if [ -n "$BR_HOSTFWD_ORIG" ] && [ -n "$BR_HOSTFWD_CLONE" ]; then
    sed -i "s/hostfwd=tcp:127.0.0.1:${BR_HOSTFWD_ORIG}-/hostfwd=tcp:127.0.0.1:${BR_HOSTFWD_CLONE}-/g" "$CLONE_LAUNCHER"
  fi
  local ports from to
  for ports in "${BR_PORT_REWRITES[@]}"; do
    from="${ports%%:*}"
    to="${ports#*:}"
    sed -i "s#127.0.0.1:${from}#127.0.0.1:${to}#g" "$CLONE_LAUNCHER"
  done
  chmod +x "$CLONE_LAUNCHER"
  clone_guard_check_launcher "$CLONE_LAUNCHER"
}

launch() {
  local script="$1"
  clone_guard_assert_clone_qmp "$CLONE_QMP" >/dev/null
  br_kill_pidfile "$CLONE_PID"
  rm -f "$CLONE_QMP" "$CLONE_PID"
  log "launching clone process: $(basename "$script")"
  bash "$script" >>"$CLONE_DIR/launch.log" 2>&1 ||
    br_die "clone launcher failed (see $CLONE_DIR/launch.log)"
  br_wait_qmp "$CLONE_QMP" 120 || br_die "clone QMP did not become ready"
}

qdrv() {
  clone_guard_assert_clone_qmp "$CLONE_QMP" >/dev/null
  "${LABQMP[@]}" "$@"
}

capture_pair() {
  local prefix="$1"
  qdrv shot "$CLONE_DIR/${prefix}-1.ppm" >/dev/null
  sleep "$IDLE_SECONDS"
  qdrv shot "$CLONE_DIR/${prefix}-2.ppm" >/dev/null
  cmp -s "$CLONE_DIR/${prefix}-1.ppm" "$CLONE_DIR/${prefix}-2.ppm" ||
    br_die "idle determinism failed: ${prefix}-1.ppm != ${prefix}-2.ppm"
  log "idle deterministic: $prefix (byte-identical, ${IDLE_SECONDS}s apart)"
}

assert_restored() {
  local actual="$1" label="$2" ssim
  if cmp -s "$CLONE_DIR/reference.ppm" "$actual"; then
    log "$label: byte-identical to pre-dirty reference"
    return
  fi
  ssim="$(br_ssim "$CLONE_DIR/reference.ppm" "$actual")"
  [ -n "$ssim" ] || ssim=0
  log "$label: SSIM=$ssim (need >= $SSIM_MIN)"
  python3 - "$ssim" "$SSIM_MIN" <<'PY' ||
import sys
raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY
    br_die "$label differs from the pre-dirty reference (SSIM $ssim)"
}

copy_clone

if [ "$BAKE" -eq 1 ]; then
  log "fresh-launching clone for bake"
  launch "$CLONE_LAUNCHER"
  if qdrv querysnap | grep -qw golden; then
    # Existing-golden rebake: the launcher normally resumed the ready fixture.
    # Load explicitly as well so launchers which cold-start are handled uniformly.
    qdrv loadvm golden >/dev/null
    sleep "$RESTORE_SECONDS"
    log "ready: existing golden loaded as the rebake seed"
  else
    # First-ever bake: no tag exists for the launcher to resume, so reach the
    # OS-specific persisted fixture through the coldboot driver/detector.
    if [ -n "$BR_BOOT_DRIVER" ]; then
      log "running ready-state driver: $BR_BOOT_DRIVER"
      "$COLD_DIR/$BR_BOOT_DRIVER" "$CLONE_QMP" "$CLONE_DIR"
    fi
    log "waiting for configured first-bake ready state"
    "$COLD_DIR/detect-interactive.sh" "$TILE" "$CLONE_QMP" "$CLONE_DIR/detect"
  fi
else
  log "verifying existing golden in a fresh clone process"
  launch "$CLONE_LAUNCHER"
  qdrv querysnap | grep -qw golden || br_die "clone disk has no 'golden' snapshot"
  qdrv loadvm golden >/dev/null
  sleep "$RESTORE_SECONDS"
  log "ready: existing golden loaded"
fi

capture_pair ready
cp "$CLONE_DIR/ready-1.ppm" "$CLONE_DIR/reference.ppm"

if [ "$BAKE" -eq 1 ]; then
  log "baking savevm golden on the clone disk"
  qdrv delvm golden >/dev/null 2>&1 || true
  qdrv savevm golden >/dev/null
  qdrv querysnap | grep -qw golden || br_die "savevm golden did not create a snapshot"
fi

log "dirtying guest through QMP keyboard input"
qdrv type "$DIRTY_TEXT" >/dev/null
sleep 1
qdrv shot "$CLONE_DIR/dirty.ppm" >/dev/null
if cmp -s "$CLONE_DIR/reference.ppm" "$CLONE_DIR/dirty.ppm"; then
  qdrv key tab sleep 0.3 key esc >/dev/null
  qdrv shot "$CLONE_DIR/dirty.ppm" >/dev/null
fi
cmp -s "$CLONE_DIR/reference.ppm" "$CLONE_DIR/dirty.ppm" &&
  br_die "dirty action produced no framebuffer change; set GOLDEN_VERIFY_DIRTY_TEXT for this fixture"
log "dirty framebuffer differs from reference"

qdrv loadvm golden >/dev/null
sleep "$RESTORE_SECONDS"
qdrv shot "$CLONE_DIR/restored.ppm" >/dev/null
assert_restored "$CLONE_DIR/restored.ppm" "same-process loadvm"

log "stopping clone through clone-guard before fresh-process proof"
br_kill_pidfile "$CLONE_PID"
launch "$CLONE_LAUNCHER"
qdrv loadvm golden >/dev/null
sleep "$RESTORE_SECONDS"
capture_pair fresh
assert_restored "$CLONE_DIR/fresh-1.ppm" "fresh-process loadvm"

log "PASS: ready + deterministic + dirty/loadvm restore + fresh-process restore"
