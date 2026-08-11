#!/bin/bash
# GOLDEN FIXTURE: golden = the RO raw _disk_image; this launcher discards the
# overlay and boots fresh every run => resetMode=restart. See ./GOLDEN.md.
# Launch tile 'serenityos' (VMID 102) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
set -e
[ -f "/data/vms/streamhost/tiles/serenityos/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/tiles/serenityos/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/tiles/serenityos/qmp.sock" "/data/vms/streamhost/tiles/serenityos/qemu.pid"
# --- fresh per-boot writable qcow2 overlay over the read-only golden raw ext2 root ---
# (SerenityOS Ext2FS root must mount RW or the kernel panics; golden _disk_image is RO)
rm -f /data/vms/streamhost/tiles/serenityos/serenity.qcow2
qemu-img create -q -f qcow2 -F raw -b /data/gallery-guests/SerenityOS/_disk_image /data/vms/streamhost/tiles/serenityos/serenity.qcow2
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-serenityos \
  -enable-kvm -m 2048 -smp 2 \
  -machine pc-q35-11.0 -cpu host \
  -rtc base=localtime \
  \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  \
  -kernel /data/gallery-guests/SerenityOS/Kernel/Kernel -append root=nvme0:1:0 -drive file=/data/vms/streamhost/tiles/serenityos/serenity.qcow2,if=none,format=qcow2,id=boot-drive -device i82801b11-bridge,id=bridge4 -device nvme,serial=deadbeef,drive=boot-drive,bus=bridge4,logical_block_size=4096,physical_block_size=4096 \
  -qmp unix:/data/vms/streamhost/tiles/serenityos/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/tiles/serenityos/qemu.pid \
  >"/data/vms/streamhost/tiles/serenityos/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/tiles/serenityos/qmp.sock" ] && [ -f "/data/vms/streamhost/tiles/serenityos/qemu.pid" ] && break
  sleep 0.5
done
echo "tile serenityos qemu pid=$(cat /data/vms/streamhost/tiles/serenityos/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/tiles/serenityos/qmp.sock udp=54102"
