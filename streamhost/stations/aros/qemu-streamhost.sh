#!/bin/bash
# Launch tile 'aros' (VMID 110) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
set -e
BASE=/data/vms/streamhost/stations/aros
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"

# AROS only binds the QEMU tablet after pciusb.device is added to Poseidon. The
# golden fixture contains that one-time in-guest binding, so load it whenever it
# is present. The device tree must stay byte-for-byte compatible with the bake.
LOADVM=()
if qemu-img snapshot -l "$BASE/golden-scratch.qcow2" 2>/dev/null | grep -qw golden; then
  LOADVM=(-loadvm golden -S)
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-aros \
  -enable-kvm -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/AmigaOS/aros-pc-i386.iso -boot d \
  -drive file="$BASE/golden-scratch.qcow2",format=qcow2,if=ide,index=0,media=disk \
  -vga std \
  -usb -device usb-tablet,id=tab0 \
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
echo "tile aros qemu pid=$(cat "$BASE/qemu.pid" 2>/dev/null) qmp=$BASE/qmp.sock udp=54110 loadvm=${LOADVM[*]:-none}"
