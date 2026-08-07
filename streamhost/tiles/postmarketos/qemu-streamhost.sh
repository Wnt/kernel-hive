#!/bin/bash
# Launch tile 'postmarketos' (VMID 103) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE (see golden.manifest.json):
#   Disks are qcow2 + snapshottable and this tile runs WITHOUT -snapshot so the
#   guest is writable. An internal live snapshot named 'golden' is the reset
#   point. resetMode=loadvm: `savevm golden` captured a logged-in phosh desktop
#   with GNOME Console focused; reset with QMP `loadvm golden` (see golden.manifest.json).
#   If the 'golden' snapshot exists we auto-resume it on launch (-loadvm golden).
set -e
TILE_DIR=/data/vms/streamhost/tiles/postmarketos
DISK=/data/gallery-guests/postmarketOS/pmos-phosh.qcow2
VARS=$TILE_DIR/OVMF_VARS.qcow2
[ -f "$TILE_DIR/qemu.pid" ] && kill "$(cat "$TILE_DIR/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$TILE_DIR/qmp.sock" "$TILE_DIR/qemu.pid"
# Auto-resume the golden fixture snapshot if it is present in the disk.
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | awk '{print $2}' | grep -qx golden; then
  LOADVM="-loadvm golden"
fi
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-postmarketos \
  -enable-kvm -m 3072 -smp 4 \
  -machine pc-q35-11.0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device intel-hda -device hda-output,audiodev=snd0 \
  $LOADVM \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd -drive if=pflash,unit=1,format=qcow2,file=$VARS -device ahci,id=ahci0 -drive if=none,id=disk0,file=$DISK,format=qcow2 -device ide-hd,drive=disk0,bus=ahci0.0 -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
  -qmp unix:$TILE_DIR/qmp.sock,server=on,wait=off \
  -pidfile $TILE_DIR/qemu.pid \
  >"$TILE_DIR/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$TILE_DIR/qmp.sock" ] && [ -f "$TILE_DIR/qemu.pid" ] && break
  sleep 0.5
done
echo "tile postmarketos qemu pid=$(cat $TILE_DIR/qemu.pid 2>/dev/null) qmp=$TILE_DIR/qmp.sock udp=54103 loadvm='${LOADVM:-none}'"
