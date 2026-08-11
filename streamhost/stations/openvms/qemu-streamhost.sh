#!/usr/bin/env bash
# OpenVMS DECwindows: a lean Debian Xorg bridge captured by streamhost and an
# independent OpenVMS X client restored from the pre-connect snapshot.
set -euo pipefail

D="${OPENVMS_TILE_ROOT:-/data/vms/streamhost/tiles/openvms}"
BRIDGE_DISK="$D/openvms-decwindows-bridge.qcow2"
VMS_DISK="$D/openvms-community.qcow2"
VMS_VARS="$D/OVMF_VARS.qcow2"
OVMF_CODE="${OPENVMS_OVMF_CODE:-/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd}"
X11_PORT="${OPENVMS_X11_PORT:-6610}"
BRIDGE_SSH_PORT="${OPENVMS_BRIDGE_SSH_PORT:-59284}"
BRIDGE_KEY="${OPENVMS_BRIDGE_KEY:-/data/vms/bridge/bridge_key}"
BRIDGE_NAME="${OPENVMS_BRIDGE_NAME:-streamhost-openvms-decwindows-bridge-vmid-84}"
VMS_NAME="${OPENVMS_VMS_NAME:-streamhost-openvms-client-vmid-284}"
SUPERVISOR_PID="$D/qemu.pid"
BRIDGE_PID="$D/bridge-qemu.pid"
VMS_PID="$D/openvms-qemu.pid"
BRIDGE_QMP="$D/qmp.sock"
VMS_QMP="$D/openvms-qmp.sock"
SERIAL="$D/serial.sock"
STACK_LOG="$D/qemu.log"
CLONE_GUARD_LOADED=0

case "$(realpath -m -- "$D")" in
  /data/vms/soltest/vmsgui-promote-?*)
    # shellcheck disable=SC1091
    source /usr/local/bin/clone-guard
    clone_guard_assert_clone_path "$D" "OpenVMS DECwindows clone root"
    CLONE_GUARD_LOADED=1
    ;;
esac

kill_pidfile() {
  local pidfile="$1" pid=""
  [ -s "$pidfile" ] || return 0
  if [ "$CLONE_GUARD_LOADED" -eq 1 ]; then
    clone_guard_kill_pidfile "$pidfile"
    return
  fi
  pid="$(cat "$pidfile" 2>/dev/null || true)"
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
  rm -f -- "$pidfile"
}

wait_socket() {
  local socket="$1" label="$2"
  for _ in $(seq 1 80); do
    [ -S "$socket" ] && return 0
    sleep 0.25
  done
  echo "openvms DECwindows: $label socket did not appear: $socket" >&2
  return 1
}

supervise() {
  # shellcheck disable=SC2317 # invoked asynchronously by trap below
  cleanup() {
    trap - EXIT INT TERM
    kill_pidfile "$VMS_PID"
    kill_pidfile "$BRIDGE_PID"
    rm -f -- "$BRIDGE_QMP" "$VMS_QMP" "$SERIAL"
  }
  trap cleanup EXIT INT TERM

  rm -f -- "$BRIDGE_QMP" "$VMS_QMP" "$SERIAL" "$BRIDGE_PID" "$VMS_PID"
  export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
  qemu-system-x86_64 \
    -name "$BRIDGE_NAME" \
    -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 768 -smp 1 \
    -rtc base=localtime \
    -drive file="$BRIDGE_DISK",if=ide,format=qcow2 -boot c \
    -vga std -display dbus,p2p=on \
    -usb -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$BRIDGE_SSH_PORT"-:22,hostfwd=tcp:127.0.0.1:"$X11_PORT"-:6000 \
    -device e1000,netdev=n0 \
    -qmp unix:"$BRIDGE_QMP",server=on,wait=off \
    -pidfile "$BRIDGE_PID" &
  wait_socket "$BRIDGE_QMP" "bridge QMP"

  # Check inside the bridge. Merely connecting to the hostfwd is not a valid
  # readiness gate: SLIRP can accept before guest Xorg is listening.
  local ssh_args=(
    ssh -i "$BRIDGE_KEY" -p "$BRIDGE_SSH_PORT"
    -o BatchMode=yes -o ConnectTimeout=3
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    bridge@127.0.0.1
  )
  for _ in $(seq 1 120); do
    if "${ssh_args[@]}" "ss -ltn | grep -q ':6000 '" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  "${ssh_args[@]}" "ss -ltn | grep -q ':6000 '" 2>/dev/null || {
    echo "openvms DECwindows: bridge Xorg did not listen through port $X11_PORT" >&2
    return 1
  }

  qemu-system-x86_64 \
    -name "$VMS_NAME" \
    -enable-kvm -machine pc-q35-11.0 -cpu host -m 8192 -smp 2 \
    -drive if=pflash,unit=0,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,unit=1,format=qcow2,file="$VMS_VARS" \
    -device VGA -display none \
    -boot order=c,menu=off \
    -drive if=none,id=osdisk,format=qcow2,file="$VMS_DISK" \
    -device ide-hd,drive=osdisk,bus=ide.0,bootindex=1 \
    -netdev user,id=n0 \
    -device e1000,netdev=n0 \
    -chardev socket,id=ser0,path="$SERIAL",server=on,wait=off \
    -serial chardev:ser0 \
    -loadvm leanx-preconnect \
    -qmp unix:"$VMS_QMP",server=on,wait=off \
    -pidfile "$VMS_PID" &
  wait_socket "$VMS_QMP" "OpenVMS QMP"

  # Exit the whole stack if either QEMU exits. The EXIT trap reaps its peer.
  while kill -0 "$(cat "$BRIDGE_PID")" 2>/dev/null &&
    kill -0 "$(cat "$VMS_PID")" 2>/dev/null; do
    sleep 1
  done
  echo "openvms DECwindows: one QEMU exited; stopping the stack" >&2
  return 1
}

if [ "${1:-}" = "--supervise" ]; then
  supervise
  exit $?
fi

for required in "$BRIDGE_DISK" "$VMS_DISK" "$VMS_VARS" "$OVMF_CODE" "$BRIDGE_KEY"; do
  [ -s "$required" ] || {
    echo "openvms DECwindows: missing required file: $required" >&2
    exit 1
  }
done
qemu-img snapshot -l "$VMS_VARS" 2>/dev/null |
  awk '{print $2}' | grep -qx leanx-preconnect || {
  echo "openvms DECwindows: missing pre-connect snapshot: leanx-preconnect" >&2
  exit 1
}

kill_pidfile "$SUPERVISOR_PID"
kill_pidfile "$VMS_PID"
kill_pidfile "$BRIDGE_PID"
rm -f -- "$BRIDGE_QMP" "$VMS_QMP" "$SERIAL"

nohup "$0" --supervise >"$STACK_LOG" 2>&1 &
printf '%s\n' "$!" >"$SUPERVISOR_PID"
for _ in $(seq 1 160); do
  if kill -0 "$(cat "$SUPERVISOR_PID")" 2>/dev/null &&
    [ -S "$BRIDGE_QMP" ] && [ -S "$VMS_QMP" ]; then
    printf 'tile openvms stack supervisor=%s bridge-qmp=%s openvms-qmp=%s udp=54084\n' \
      "$(cat "$SUPERVISOR_PID")" "$BRIDGE_QMP" "$VMS_QMP"
    exit 0
  fi
  sleep 0.25
done
echo "openvms DECwindows: dual-VM stack did not become ready" >&2
exit 1
