#!/bin/bash
# Launch an isolated Win95 graphics-driver experiment under the production KVM
# machine profile. The caller must name an inactive source image explicitly;
# this helper never defaults to, stops, or writes the live tile.
set -euo pipefail

usage() {
  echo "usage: SOURCE_DISK=/path/to/inactive.qcow2 $0 <tag> <std|cirrus> <hostfwd-port>" >&2
  echo "       LOAD_GOLDEN=1 may be used only when the clone keeps -vga std." >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
TAG=$1
VGA=$2
PORT=$3
[[ "$TAG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || usage
[[ "$VGA" == std || "$VGA" == cirrus ]] || usage
[[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1024 && "$PORT" -le 65535 ]] || usage
[[ -n "${SOURCE_DISK:-}" && -f "$SOURCE_DISK" ]] || usage
[[ "${LOAD_GOLDEN:-0}" == 0 || "${LOAD_GOLDEN:-0}" == 1 ]] || usage
if [[ "$VGA" != std && "${LOAD_GOLDEN:-0}" == 1 ]]; then
  echo "refusing: a std-VGA saved state is device-incompatible with -vga $VGA" >&2
  exit 2
fi

D="/data/vms/soltest/win95-paint-tearing-${TAG}"
DISK="$D/disk.qcow2"
mkdir -p "$D/evidence"
if [[ ! -f "$DISK" ]]; then
  nice -n15 cp --reflink=auto "$SOURCE_DISK" "$DISK"
  sha256sum "$SOURCE_DISK" "$DISK" >"$D/source-copy.sha256"
fi

# This is the only termination path. Never use a name-based pkill.
if [[ -s "$D/qemu.pid" ]]; then
  oldpid=$(cat "$D/qemu.pid")
  kill "$oldpid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$oldpid" 2>/dev/null || break
    sleep 0.25
  done
fi
rm -f "$D/qmp.sock" "$D/qemu.pid"

loadvm=()
if [[ "${LOAD_GOLDEN:-0}" == 1 ]]; then
  qemu-img snapshot -l "$DISK" | grep -qw golden || {
    echo "refusing: LOAD_GOLDEN=1 but clone has no golden snapshot" >&2
    exit 2
  }
  loadvm=(-loadvm golden)
fi

nohup nice -n15 qemu-system-x86_64 \
  -name "soltest-win95-paint-${TAG}" \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,usb=off,kernel-irqchip=off,accel=kvm \
  -cpu pentium,-apic -rtc base=localtime -boot c \
  -vga "$VGA" -display none \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -drive file="$DISK",format=qcow2,if=ide \
  -netdev user,id=n0,hostfwd="tcp:127.0.0.1:${PORT}-:7777" \
  -device pcnet,netdev=n0 \
  "${loadvm[@]}" \
  -qmp "unix:$D/qmp.sock,server=on,wait=off" \
  -pidfile "$D/qemu.pid" >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 80); do
  [[ -S "$D/qmp.sock" && -s "$D/qemu.pid" ]] && break
  sleep 0.25
done
[[ -S "$D/qmp.sock" && -s "$D/qemu.pid" ]] || {
  echo "QEMU did not create its namespaced QMP socket/pidfile" >&2
  exit 1
}
echo "dir=$D pid=$(cat "$D/qemu.pid") qmp=$D/qmp.sock vga=$VGA hostfwd=$PORT load_golden=${LOAD_GOLDEN:-0}"
