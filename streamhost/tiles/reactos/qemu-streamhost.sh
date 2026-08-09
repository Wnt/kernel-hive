#!/bin/bash
# Launch tile 'reactos' (VMID 106) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN-FIXTURE (resetMode=loadvm) — see /data/gallery-guests/ReactOS/golden-manifest.json
#  * reactos-golden.qcow2 holds the live `savevm golden` snapshot (RAM+devices)
#    of the curated fixture desktop. ReactOS boots the LiveCD (-boot d) and does
#    NOT use this disk; the qcow2 exists solely so a diskless LiveCD tile can be
#    reset live via QMP `loadvm golden`.
#  * NO -snapshot: writes must persist so the snapshot lives in the qcow2.
#    Startup loads that snapshot directly; QMP loadvm provides later resets.
#  * NO floppy at runtime: the fixture was built with a generated settings floppy
#    (reactos-settings.img) which was ejected before savevm, so the golden
#    snapshot has an empty floppy0 — matched here by the pc machine's default
#    empty floppy0 (no -fda). scripts/build-guests/tiles/reactos.sh invokes the fully
#    automated streamhost/tiles/reactos/golden-bake.sh to rebuild it cold.
set -e
GDIR=/data/gallery-guests/ReactOS
[ -f "/data/vms/streamhost/tiles/reactos/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/tiles/reactos/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/tiles/reactos/qmp.sock" "/data/vms/streamhost/tiles/reactos/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-reactos \
  -enable-kvm -m 512 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/ReactOS/ReactOS.iso -boot d \
  -drive file=$GDIR/reactos-golden.qcow2,if=ide,index=0,media=disk,format=qcow2 \
  -loadvm golden \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  \
  -qmp unix:/data/vms/streamhost/tiles/reactos/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/tiles/reactos/qemu.pid \
  >"/data/vms/streamhost/tiles/reactos/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/tiles/reactos/qmp.sock" ] && [ -f "/data/vms/streamhost/tiles/reactos/qemu.pid" ] && break
  sleep 0.5
done
echo "tile reactos qemu pid=$(cat /data/vms/streamhost/tiles/reactos/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/tiles/reactos/qmp.sock udp=4433"
