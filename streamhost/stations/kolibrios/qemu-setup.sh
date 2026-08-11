#!/bin/bash
# SETUP launcher for tile 'kolibrios' golden-fixture build.
# Identical device models to production (qemu-streamhost.sh) EXCEPT:
#   - display: none (framebuffer captured via QMP screendump; not part of vmstate)
#   - audiodev: none  (AC97 device model kept; backend not part of vmstate)
#   - attaches the scratch state.qcow2 (virtio) that will HOLD the 'golden' snapshot
# Runs WITHOUT -snapshot so savevm can persist. Kill only by pidfile.
set -e
BASE="${TILE_DIR:-/data/vms/streamhost/stations/kolibrios}"
ISO="${KOLIBRI_ISO:-/data/gallery-guests/KolibriOS/kolibri.iso}"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
nohup qemu-system-x86_64 \
  -name streamhost-kolibrios \
  -enable-kvm -m 256 -smp 2 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom "$ISO" -boot d \
  -vga std \
  -usb -device usb-tablet \
  -display none \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -drive file="$BASE/state.qcow2",if=virtio,format=qcow2 \
  -qmp unix:"$BASE/qmp.sock",server=on,wait=off \
  -pidfile "$BASE/qemu.pid" \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "setup kolibrios qemu pid=$(cat "$BASE/qemu.pid" 2>/dev/null)"
