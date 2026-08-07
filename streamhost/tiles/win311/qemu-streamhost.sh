#!/bin/bash
# Launch tile 'win311' (VMID 90) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE MODE: boots the persistent golden qcow2 disks (NO -snapshot) so
# QMP savevm/loadvm can create/restore the live "golden" reset point.
# resetMode=loadvm  (see GOLDEN.md). Disks are standalone qcow2 (no backing dep).
set -e
D=/data/vms/streamhost/tiles/win311
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$D/win311-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-i386 \
  -name streamhost-win311 \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  \
  -drive file=$D/win311-golden.qcow2,format=qcow2,if=ide -drive file=$D/games-golden.qcow2,format=qcow2,if=ide,index=1 -nic user,ipv6=off,model=ne2k_pci \
  -chardev socket,id=ser0,path=$D/serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win311 qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54090 (golden, no -snapshot)"
