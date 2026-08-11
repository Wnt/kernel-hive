#!/bin/bash
# Launch tile 'sinclairql' (VMID 236) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running MAME 0.251's `ql` driver — a
# Sinclair QL (1984), 68008 at 7.5 MHz, 128 KB RAM, QDOS/SuperBASIC in ROM —
# resting in its 80-column MONITOR mode. The QL's 512x256 is drawn at an exact
# 2x3 integer scale on the kiosk's 1024x768 X root, so every QL pixel is one
# identical block and the picture keeps the machine's 4:3 shape. Keyboard
# exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/mpf2).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + MAME at the QL's monitor screen.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup, and — the reason this tile
#     needs it more than its siblings — neither of the two screens a QL cold
#     start stops on: MAME's imperfect-dump warning (the QL's hal16l8.ic38 PLD
#     has never been dumped anywhere) and the machine's own `F1...monitor /
#     F2...TV` chooser. Both were answered once, during the bake.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
#   * -m 768: measured MemAvailable in the running guest is ~374 MB.
set -e
BASE=/data/vms/streamhost/tiles/sinclairql
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden QL monitor-mode fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-sinclairql \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5836-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile sinclairql qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54133 ssh=127.0.0.1:5836 loadvm='${LOADVM:-<none: cold boot>}'"
