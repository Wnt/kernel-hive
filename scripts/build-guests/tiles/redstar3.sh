#!/usr/bin/env bash
# Rebuild Red Star OS 3.0 Desktop from its preservation ISO without ever
# presenting a network interface to the guest.  The graphical installer is
# driven by bounded, screenshot-confirmed machine-vision states.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VISION_DIR=${VISION_DIR:-$SCRIPT_DIR/../../install-vision}
VISION_PY=${VISION_PY:-$VISION_DIR/.venv/bin/python}
DRIVER=$VISION_DIR/redstar3.py
FLOW=$VISION_DIR/redstar3.flow.yaml
TEMPLATES=$VISION_DIR/templates/redstar3

DATE_TAG=${DATE_TAG:-$(date +%Y%m%d)}
WORK_DIR=${WORK_DIR:-/data/vms/sandbox/redstar3-build-$DATE_TAG}
STAGE_DIR=${STAGE_DIR:-/data/assets-staging/redstar3}
ISO_NAME=redstar_desktop3.0_sign.iso
ISO=$STAGE_DIR/$ISO_NAME
ISO_SHA256=895ad0e01ae0d35a65e9ac42dd34d0a1d685d6dfa331ce5b4f24bbc753439be3
DISK=$WORK_DIR/redstar3.qcow2
HELPER=$WORK_DIR/redstar3-offline-helper.ext2
EVIDENCE=$WORK_DIR/evidence-compliant
FINAL_DIR=${FINAL_DIR:-/data/gallery-guests/RedStar3}
FINAL=$FINAL_DIR/redstar3.qcow2
PID_FILE=$WORK_DIR/qemu.pid
QMP=$WORK_DIR/qmp.sock
MON=$WORK_DIR/monitor.sock
LOCK=$WORK_DIR/build.lock
INSTALL_MARK=$WORK_DIR/install.complete
HELPER_MARK=$WORK_DIR/offline-helper.complete
QEMU=${QEMU:-qemu-system-x86_64}
FORCE=${FORCE:-0}
CLONE_GUARD=${CLONE_GUARD:-/usr/local/bin/clone-guard}

[ -r "$CLONE_GUARD" ] || {
  echo "[redstar3 FATAL] clone guard missing: $CLONE_GUARD" >&2
  exit 1
}
# shellcheck disable=SC1090,SC1091
source "$CLONE_GUARD"

log() { printf '[redstar3 %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
  printf '[redstar3 FATAL] %s\n' "$*" >&2
  exit 1
}
alive() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }
qmp_hmp() {
  clone_guard_assert_clone_qmp "$QMP" || return
  "$VISION_PY" - "$VISION_DIR" "$QMP" "$*" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from qmp import QMPClient
with QMPClient(sys.argv[2]) as q:
    out=q.hmp(sys.argv[3])
    if out: print(out)
PY
}

stop_vm() {
  if [ -S "$QMP" ]; then
    clone_guard_assert_clone_qmp "$QMP" || return
    qmp_hmp quit >/dev/null 2>&1 || true
  fi
  clone_guard_kill_pidfile "$PID_FILE"
  rm -f "$PID_FILE" "$QMP" "$MON"
}
trap stop_vm EXIT

boot() {
  local mode=$1
  local -a drives extra
  drives=(-drive "file=$DISK,format=qcow2,if=ide,index=0,media=disk")
  case "$mode" in
    install)
      drives+=(-drive "file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on")
      extra=(-boot d)
      ;;
    rescue)
      drives+=(-drive "file=$HELPER,format=raw,if=ide,index=1,media=disk" -drive "file=$ISO,format=raw,if=ide,index=2,media=cdrom,readonly=on")
      extra=(-boot d)
      ;;
    disk)
      drives+=(-drive if=ide,index=2,media=cdrom)
      extra=(-boot c)
      ;;
    golden)
      drives+=(-drive if=ide,index=2,media=cdrom)
      extra=(-boot c -loadvm golden)
      ;;
    *) die "unknown boot mode: $mode" ;;
  esac
  stop_vm
  # -nodefaults is present in every phase.  The complete command contains no
  # -nic, -netdev, network device, or hostfwd argument.
  "$QEMU" -nodefaults -enable-kvm -machine pc-i440fx-11.0 \
    -cpu Nehalem,kvm=off -m 1024 -smp 1 -rtc base=localtime \
    "${drives[@]}" "${extra[@]}" -vga cirrus -usb -device usb-tablet \
    -display none -qmp "unix:$QMP,server=on,wait=off" \
    -monitor "unix:$MON,server=on,wait=off" -pidfile "$PID_FILE" -daemonize
  for _ in $(seq 1 60); do
    [ -S "$QMP" ] && alive && return 0
    sleep 0.5
  done
  die "QMP socket did not appear for $mode phase"
}

preflight() {
  for tool in "$QEMU" qemu-img mke2fs sha256sum flock; do command -v "$tool" >/dev/null || die "missing $tool"; done
  [ -c /dev/kvm ] || die "/dev/kvm unavailable"
  [ -x "$VISION_PY" ] || die "vision venv missing: run scripts/install-vision/install.sh"
  if [ ! -x "$VISION_DIR/install-vision" ] || [ ! -f "$FLOW" ] || [ ! -f "$DRIVER" ] || [ ! -d "$TEMPLATES" ]; then
    die "vision flow/driver/templates missing"
  fi
  [ -f "$ISO" ] || die "stage $ISO first (private preservation media)"
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null || die "ISO checksum mismatch"
  clone_guard_assert_clone_path "$WORK_DIR" "work directory" || die "work directory is not clone-namespaced"
  clone_guard_assert_clone_qmp "$QMP" || die "QMP socket is not clone-namespaced"
  mkdir -p "$WORK_DIR" "$EVIDENCE" "$FINAL_DIR"
}

preflight
exec 9>"$LOCK"
flock -n 9 || die "another redstar3 build owns $LOCK"

if [ "$FORCE" = 1 ]; then
  stop_vm
  rm -f "$DISK" "$HELPER"
  rm -f "$INSTALL_MARK" "$HELPER_MARK"
  rm -rf "$EVIDENCE"
  mkdir -p "$EVIDENCE"
fi

if [ ! -f "$DISK" ]; then
  log "creating blank 16 GiB namespaced disk"
  qemu-img create -f qcow2 "$DISK" 16G >/dev/null
  boot install
  log "driving graphical installer with screenshot-confirmed states"
  IFS= read -r -s password
  [ -n "$password" ] || die "supply the guest password on stdin"
  REDSTAR3_PASSWORD="$password" "$VISION_DIR/install-vision" run "$FLOW" \
    --qmp "$QMP" --work-dir "$EVIDENCE/install"
  password=
  stop_vm
  touch "$INSTALL_MARK"
fi

[ -f "$INSTALL_MARK" ] || die "disk exists without a completed installer marker; rerun with FORCE=1"

if [ ! -f "$HELPER_MARK" ]; then
  helper_tree=$WORK_DIR/helper-tree
  rm -rf "$helper_tree"
  mkdir -p "$helper_tree"
  cp "$SCRIPT_DIR/../stages/redstar3-offline-apply.sh" "$helper_tree/apply.sh"
  truncate -s 16M "$HELPER"
  mke2fs -q -t ext2 -F -d "$helper_tree" "$HELPER"
  rm -rf "$helper_tree"
  boot rescue
  "$VISION_PY" "$DRIVER" rescue --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
  stop_vm
  touch "$HELPER_MARK"
fi

log "booting final device set to stable logged-in desktop"
boot disk
"$VISION_PY" "$DRIVER" curate --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
"$VISION_PY" "$DRIVER" park --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
qmp_hmp 'delvm golden' >/dev/null 2>&1 || true
qmp_hmp 'savevm golden' >/dev/null
qmp_hmp 'info snapshots' | grep -Eq '[[:space:]]golden[[:space:]]' || die "golden snapshot tag missing"
"$VISION_PY" "$DRIVER" proof --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
qmp_hmp 'loadvm golden' >/dev/null
"$VISION_PY" "$DRIVER" proof --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
stop_vm

log "fresh process proof with exact final device set and -loadvm golden"
boot golden
"$VISION_PY" "$DRIVER" proof --qmp "$QMP" --templates "$TEMPLATES" --evidence "$EVIDENCE"
stop_vm

if [ -f "$FINAL" ]; then cp --reflink=auto "$FINAL" "$FINAL.bak-pre-redstar3"; fi
tmp=$FINAL.tmp.$$
cp --reflink=auto "$DISK" "$tmp"
mv -f "$tmp" "$FINAL"
qemu-img snapshot -l "$FINAL" | grep -Eq '[[:space:]]golden[[:space:]]' || die "promoted golden tag missing"
log "complete: $FINAL"
