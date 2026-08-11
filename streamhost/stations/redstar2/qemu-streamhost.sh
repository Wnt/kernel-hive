#!/usr/bin/env bash
# Red Star OS 2.0 — VMID/slot 120, UDP 54120.
#
# AIR-GAPPED GUEST: -nodefaults is mandatory and this launcher intentionally
# contains no NIC, netdev, host forwarding, or other guest network hardware.
# The qcow2 must carry the internal snapshot "golden"; launcher and disk are an
# atomic pair.  Reset is HMP `loadvm golden`, never an in-guest channel.
set -euo pipefail

T=/data/vms/streamhost/stations/redstar2
DISK=/data/gallery-guests/RedStar2/redstar2.qcow2

if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  echo "redstar2: required qcow2 snapshot 'golden' is missing" >&2
  exit 1
fi

if [ -f "$T/qemu.pid" ]; then
  pid=$(cat "$T/qemu.pid")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$T/qmp.sock" "$T/reset-hmp.sock" "$T/qemu.pid"

export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-redstar2 \
  -nodefaults \
  -enable-kvm -machine pc-i440fx-11.0 -cpu host \
  -m 1024 -smp 1 -rtc base=localtime \
  -drive file="$DISK",format=qcow2,if=ide,index=0 \
  -boot order=c -loadvm golden -S \
  -vga std \
  -usb -device usb-tablet \
  -display dbus,p2p=on \
  -qmp unix:"$T/qmp.sock",server=on,wait=off \
  -monitor unix:"$T/reset-hmp.sock",server,nowait \
  -pidfile "$T/qemu.pid" \
  >"$T/qemu.log" 2>&1 &

for _ in $(seq 1 80); do
  [ -S "$T/qmp.sock" ] && [ -f "$T/qemu.pid" ] && break
  sleep 0.25
done
[ -S "$T/qmp.sock" ] && [ -f "$T/qemu.pid" ]
echo "tile redstar2 qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54120 (air-gapped; -loadvm golden)"
