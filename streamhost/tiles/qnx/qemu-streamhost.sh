#!/bin/bash
# Launch tile 'qnx' (VMID 112) QEMU with the streamhost display wiring.
# A create-if-missing scratch qcow2 stores the LiveCD's `golden` RAM snapshot.
# Cold first launch omits -loadvm; run golden-bake.sh once. Later launches load
# the curated 1024x768 Photon desktop directly from `golden`. QNX 6.5 uses the
# built-in PS/2 mouse through SH_POINTER=rel; do not add usb-tablet (its Y axis
# is ignored by Photon even when hot-enumeration succeeds).
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
set -e
BASE=/data/vms/streamhost/tiles/qnx
STATE="$BASE/golden.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$STATE" ] || qemu-img create -q -f qcow2 "$STATE" 2G
LOADVM=""
qemu-img snapshot -l "$STATE" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-qnx \
  -enable-kvm -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -drive file="$STATE",if=ide,index=0,media=disk,format=qcow2,cache=writeback \
  -cdrom /data/gallery-guests/QNX/QNX650Live.iso -boot d \
  -vga cirrus \
  -display dbus,p2p=on,audiodev=snd0 \
  $LOADVM \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -monitor tcp:127.0.0.1:7112,server,nowait \
  -qmp unix:/data/vms/streamhost/tiles/qnx/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/tiles/qnx/qemu.pid \
  >"/data/vms/streamhost/tiles/qnx/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/tiles/qnx/qmp.sock" ] && [ -f "/data/vms/streamhost/tiles/qnx/qemu.pid" ] && break
  sleep 0.5
done
echo "tile qnx qemu pid=$(cat "$BASE/qemu.pid" 2>/dev/null) qmp=$BASE/qmp.sock udp=54112 loadvm='${LOADVM:-<none: cold boot>}'"
