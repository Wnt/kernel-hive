#!/bin/bash
# Launch tile 'kolibrios' (VMID 97) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE (resetMode=loadvm): the KolibriOS LiveCD has NO writable disk,
# so a scratch qcow2 (state.qcow2, virtio, never booted by the guest) is attached
# SOLELY to hold the live 'golden' savevm snapshot. Runs WITHOUT -snapshot so the
# snapshot persists. When the 'golden' snapshot exists we boot straight into it with
# -loadvm golden (device models here are IDENTICAL to qemu-setup.sh, only display/
# audio backends differ, which are NOT part of vmstate). NEVER delete state.qcow2.
set -e
BASE=/data/vms/streamhost/stations/kolibrios
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"

# Auto-load the golden fixture snapshot if present in the scratch state disk.
LOADVM=()
if qemu-img snapshot -l "$BASE/state.qcow2" 2>/dev/null | grep -qw golden; then
  LOADVM=(-loadvm golden -S)
fi

# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-kolibrios \
  -enable-kvm -m 256 -smp 2 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/KolibriOS/kolibri.iso -boot d \
  -vga std \
  -usb -device usb-tablet \
  -drive file="$BASE/state.qcow2",if=virtio,format=qcow2 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  "${LOADVM[@]}" \
  -qmp unix:"$BASE/qmp.sock",server=on,wait=off \
  -pidfile "$BASE/qemu.pid" \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile kolibrios qemu pid=$(cat "$BASE/qemu.pid" 2>/dev/null) qmp=$BASE/qmp.sock udp=54097 loadvm=${LOADVM[*]:-none}"
