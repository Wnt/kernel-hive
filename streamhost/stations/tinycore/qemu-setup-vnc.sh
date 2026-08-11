#!/bin/bash
# PATH FIX (2026-07-14): /data/isos/TinyCore.iso is canonical; this box helper
# formerly referenced the retired /data/vms/spikeA/iso/TinyCore.iso location.
# SETUP-ONLY launcher for BAKING the tinycore golden fixture (used by golden-bake.sh).
# Same device models as qemu-streamhost.sh (vga std, AC97, usb-tablet, pc/host, 768M,
# virtio state.qcow2) so a savevm here is loadable by the production dbus launcher.
# Only the DISPLAY backend differs (vnc for reliable QMP input during setup) and the
# audio backend is 'none'. tinyX is relative-only and ignores the usb-tablet, so the
# pointer is driven over QMP via the legacy PS/2 relative path (drive.py mouse_move),
# which needs an active graphic console -- vnc provides one; dbus-p2p with no peer
# does not. Boots the LiveCD onto state.qcow2 with NO -snapshot.
set -e
BASE=/data/vms/streamhost/stations/tinycore
STATE="$BASE/state.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$STATE" ] || qemu-img create -q -f qcow2 "$STATE" 3G
nohup qemu-system-x86_64 \
  -name streamhost-tinycore \
  -enable-kvm -m 768 -smp 2 \
  -machine pc -cpu host \
  -rtc base=localtime \
  -drive file="$STATE",if=virtio,format=qcow2 -cdrom /data/isos/TinyCore.iso -boot d \
  -vga std \
  -display vnc=127.0.0.1:1 \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "setup qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) vnc=127.0.0.1:1"
