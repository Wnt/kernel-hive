#!/bin/bash
# Launch tile 'winxp' (VMID 94) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     disk is a standalone qcow2 (no backing dep), a curated copy of the pristine
#     gallery image which stays untouched at /data/gallery-guests/WinXPpro/winxp.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden) so the
#     tile comes up already at the curated fixture (Notepad open+focused, steady
#     caret, screensaver off, tray clock hidden). First-ever bake (no snapshot yet)
#     launches cold -- see golden-bake.sh.
set -e
D=/data/vms/streamhost/tiles/winxp
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/winxp-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-winxp \
  -enable-kvm -m 768 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/WinXPpro/retro-software.iso -boot order=c,menu=off \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file=$D/winxp-golden.qcow2,format=qcow2,if=ide -netdev user,id=n0 -device rtl8139,netdev=n0 \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile winxp qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54094 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
