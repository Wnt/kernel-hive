#!/bin/bash
# NSPTR-flatten-accel clone launcher. Namespaced dir/qmp/pidfile/hostfwd.
set -euo pipefail
D=/data/vms/sandbox/NSPTR-flatten-accel
SSH_PORT=5948
# shellcheck source=/dev/null  # box-only HARD guard, installed at /usr/local/bin
source /usr/local/bin/clone-guard
clone_guard_assert_path "$D" || exit 1
clone_guard_assert_qmp "$D/qmp.sock" || exit 1
if [ -f "$D/qemu.pid" ]; then clone-guard kill-pidfile "$D/qemu.pid" || true; fi
sleep 1
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/overlay.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086
nohup qemu-system-x86_64 -name nsptr-flatten-accel \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off -m 1536 -smp 4 -cpu host \
  -rtc base=localtime \
  -drive file="$D/overlay.qcow2",if=ide,format=qcow2 -boot c \
  -vga std -display none \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:"$D/qmp.sock",server=on,wait=off -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 60); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
[ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] || {
  echo "no qmp/pid"
  exit 1
}
echo "started pid=$(cat "$D/qemu.pid") loadvm='${LOADVM:-cold}'"
