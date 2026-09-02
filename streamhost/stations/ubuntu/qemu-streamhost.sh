#!/bin/bash
# Launch station 'ubuntu' (VMID 183): Ubuntu 4.10 Warty Warthog LIVE CD under
# KVM. The CD is the OS; ubuntu.qcow2 is an otherwise empty 1G disk that only
# carries the 'golden' vmstate. ISO + qcow2 + this device set are ONE combination.
# Device set measured 2026-09-03: acpi=off and NO audio device — AC97 with ACPI
# on hangs the 2.6.8 live boot at the usplash bar. -nodefaults: zero guest NICs.
set -euo pipefail
T=/data/vms/streamhost/stations/ubuntu
DISK=/data/gallery-guests/Ubuntu/ubuntu.qcow2
ISO=/data/gallery-guests/Ubuntu/warty-release-live-i386.iso
if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  echo "ubuntu: required qcow2 snapshot 'golden' is missing" >&2
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
  -name streamhost-ubuntu \
  -nodefaults \
  -enable-kvm -machine pc-i440fx-11.0,acpi=off -cpu host \
  -m 512 -smp 1 -rtc base=localtime \
  -drive file="$DISK",format=qcow2,if=ide,index=0 \
  -drive file="$ISO",format=raw,if=ide,index=2,media=cdrom,readonly=on \
  -boot order=d -loadvm golden -S \
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
echo "tile ubuntu qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54183 (air-gapped live CD; -loadvm golden)"
