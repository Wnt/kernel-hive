#!/usr/bin/env bash
# Build the reproducible lean-X bridge overlay used by the OpenVMS DECwindows
# tile. The frozen bridge-base backing file is never modified.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$HERE/../../.." && pwd)"
BRIDGE_BASE="${BRIDGE_BASE:-/data/vms/bridge/bridge-base.qcow2}"
BRIDGE_KEY="${BRIDGE_KEY:-/data/vms/bridge/bridge_key}"
OUT_BRIDGE="${OUT_BRIDGE:-/data/gallery-guests/OpenVMS/openvms-decwindows-bridge.qcow2}"
WORK="${WORK:-/data/vms/build-openvms-decwindows-bridge}"
SSH_PORT="${BRIDGE_BUILD_SSH_PORT:-59283}"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
LOG="$WORK/qemu.log"
FORCE=0
KEEP_RUNNING=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --keep-running)
      KEEP_RUNNING=1
      shift
      ;;
    -h | --help)
      sed -n '2,35p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:openvms-decwindows-bridge] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

kill_build_qemu() {
  local pid=""
  [ -s "$PIDFILE" ] || return 0
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$pid" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 1 40); do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.25
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
      fi
      ;;
  esac
  rm -f -- "$PIDFILE" "$QMP"
}

cleanup() {
  [ "$KEEP_RUNNING" -eq 1 ] || kill_build_qemu
}
trap cleanup EXIT

for tool in qemu-img qemu-system-x86_64 ssh scp; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
for required in "$BRIDGE_BASE" "$BRIDGE_KEY"; do
  [ -s "$required" ] || die "missing required input: $required"
done
for source in \
  "$REPO_ROOT/streamhost/tiles/openvms/bridge-launch.sh" \
  "$REPO_ROOT/streamhost/tiles/openvms/bridge-xserverrc"; do
  [ -s "$source" ] || die "missing tracked bridge source: $source"
done

if [ -s "$OUT_BRIDGE" ] && [ "$FORCE" -eq 0 ]; then
  qemu-img check -q "$OUT_BRIDGE" || die "existing bridge image failed qemu-img check"
  log "output already exists and is valid; pass --force to rebuild: $OUT_BRIDGE"
  exit 0
fi
ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$SSH_PORT$" &&
  die "build SSH port is already in use: $SSH_PORT"

mkdir -p "$WORK" "$(dirname -- "$OUT_BRIDGE")"
kill_build_qemu
rm -f -- "$OUT_BRIDGE"
qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OUT_BRIDGE" >/dev/null

log "booting a private provisioning QEMU on 127.0.0.1:$SSH_PORT"
qemu-system-x86_64 \
  -name build-openvms-decwindows-bridge \
  -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 768 -smp 1 \
  -rtc base=localtime \
  -drive file="$OUT_BRIDGE",if=ide,format=qcow2 -boot c \
  -vga std -display none \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
  -device e1000,netdev=n0 \
  -qmp unix:"$QMP",server=on,wait=off \
  -pidfile "$PIDFILE" >"$LOG" 2>&1 &

SSH=(
  ssh -i "$BRIDGE_KEY" -p "$SSH_PORT"
  -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  bridge@127.0.0.1
)
SCP=(
  scp -i "$BRIDGE_KEY" -P "$SSH_PORT"
  -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
)
for _ in $(seq 1 120); do
  "${SSH[@]}" true >/dev/null 2>&1 && break
  sleep 1
done
"${SSH[@]}" true >/dev/null 2>&1 || die "bridge SSH did not become ready"

log "installing the pinned lean Xorg runtime and kiosk files"
"${SSH[@]}" \
  "sudo env DEBIAN_FRONTEND=noninteractive apt-get update -o Acquire::Retries=3 >/tmp/openvms-decw-apt.log 2>&1 &&
   sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xserver-xorg-core xinit x11-xserver-utils >>/tmp/openvms-decw-apt.log 2>&1"
"${SCP[@]}" \
  "$REPO_ROOT/streamhost/tiles/openvms/bridge-launch.sh" \
  bridge@127.0.0.1:/tmp/openvms-decwindows-launch.sh >/dev/null
"${SCP[@]}" \
  "$REPO_ROOT/streamhost/tiles/openvms/bridge-xserverrc" \
  bridge@127.0.0.1:/tmp/openvms-decwindows-xserverrc >/dev/null
"${SSH[@]}" \
  "sudo install -o root -g root -m 0755 /tmp/openvms-decwindows-launch.sh /etc/bridge/launch.sh &&
   install -m 0755 /tmp/openvms-decwindows-xserverrc /home/bridge/.xserverrc &&
   sudo systemctl disable --now display-manager.service 2>/dev/null || true;
   sudo systemctl reset-failed getty@tty1;
   sudo systemctl restart getty@tty1"

for _ in $(seq 1 60); do
  "${SSH[@]}" "ss -ltn | grep -q ':6000 '" >/dev/null 2>&1 && break
  sleep 1
done
"${SSH[@]}" "ss -ltn | grep -q ':6000 '" >/dev/null 2>&1 ||
  die "provisioned Xorg did not listen on TCP 6000"
"${SSH[@]}" "pgrep -x Xorg >/dev/null; ! pgrep -x 'lightdm|gdm3|sddm|openbox|xfwm4' >/dev/null"

log "shutting down and checking the completed bridge overlay"
"${SSH[@]}" "sudo poweroff" >/dev/null 2>&1 || true
for _ in $(seq 1 80); do
  [ -s "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
  sleep 0.25
done
kill_build_qemu
qemu-img check -q "$OUT_BRIDGE" || die "completed bridge image failed qemu-img check"
log "done: $OUT_BRIDGE"
