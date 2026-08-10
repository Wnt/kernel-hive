#!/bin/bash
# Launch tile 'alto' (VMID 243) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running ContrAlto 2 as a Xerox Alto II
# XM, booted from the Non-Programmer's Disk. Zero external media — the microcode
# PROMs and the disk packs ship inside the emulator's own repository.
#
# THE ONE THING TO KNOW ABOUT THIS TILE'S GEOMETRY: the X root is 608x808,
# PORTRAIT, and that is not a compromise. The Alto's picture is 606 visible
# pixels inside a 608-wide bitmap (ContrAlto's ALTO_DISPLAY_BITMAP_WIDTH,
# "rounded up so it's a nice even multiple of 8 bits") by 808 lines, 608 is a
# multiple of 8 so QEMU std-VGA takes it directly, and the capture is therefore
# EXACTLY the machine's own screen with no letterbox and no painted surround.
# The kiosk launcher adds that mode with an explicit xrandr modeline because
# bochs-drm does not advertise it. Changing the root invalidates the golden.
#
# Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/plus4).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X + ContrAlto at the Alto Executive.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * An internal snapshot carries the DISK too, so any change made inside the
#     kiosk (a new /etc/bridge/launch.sh, say) is REVERTED by the next restore
#     until it is re-baked. scripts/build-guests/tiles/alto.sh therefore never
#     boots with -loadvm; only this production launcher does.
#   * usb-tablet is REQUIRED and is not the usual convenience: ContrAlto's UI
#     calls MouseMoveAbsolute(), warping the Alto's cursor to the host pointer
#     instead of feeding it deltas, so this tile has a genuine absolute pointer
#     with no calibration. All THREE buttons matter — RED/YELLOW/BLUE are host
#     left/middle/right, and Bravo gives each of them a different selection.
set -e
BASE=/data/vms/streamhost/tiles/alto
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden Alto Executive fixture if the snapshot is there.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-alto \
  -enable-kvm -machine pc-i440fx-11.0 \
  -m 1024 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5843-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile alto qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54137 ssh=127.0.0.1:5843 loadvm='${LOADVM:-<none: cold boot>}'"
