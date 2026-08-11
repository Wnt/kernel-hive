#!/bin/bash
# Launch tile 'freedos' (VMID 95) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN TEST FIXTURE (2026-07-06): runs WITHOUT -snapshot (writes persist to the
# qcow2) and boots into the 'golden' live snapshot when it exists.
# resetMode=loadvm: the reset harness issues QMP `loadvm golden` to revert the
# guest to the fixture (the FreeDOS retro-games CHOICE menu). See the
# golden manifest (golden.json) in this tile dir. Without a snapshot the launcher
# cold-boots to FDAUTO->MENU.BAT so a fresh build can be calibrated and baked.
set -e
[ -f "/data/vms/streamhost/stations/freedos/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/stations/freedos/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/stations/freedos/qmp.sock" "/data/vms/streamhost/stations/freedos/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l /data/gallery-guests/FreeDOS/freedos.qcow2 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-freedos \
  -enable-kvm -m 64 -smp 2 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga cirrus \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  \
  -drive file=/data/gallery-guests/FreeDOS/freedos.qcow2,format=qcow2,if=ide -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -qmp unix:/data/vms/streamhost/stations/freedos/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/freedos/qemu.pid \
  >"/data/vms/streamhost/stations/freedos/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/stations/freedos/qmp.sock" ] && [ -f "/data/vms/streamhost/stations/freedos/qemu.pid" ] && break
  sleep 0.5
done
echo "tile freedos qemu pid=$(cat /data/vms/streamhost/stations/freedos/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/stations/freedos/qmp.sock udp=54095"
