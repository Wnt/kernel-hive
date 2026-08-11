#!/bin/bash
# Launch tile 'amiga' (VMID 218) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running FS-UAE (WINDOWED) emulating a real
# Commodore Amiga 500 (Motorola 68000) auto-booting Workbench 1.3 off a Kickstart 1.3
# ROM (see scripts/build-guests/tiles/amiga.sh, scripts/amiga-tile-notes.md, streamhost/BRIDGE.md).
# DISTINCT from the 'aros' tile (that is native AROS-on-x86). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/alpine/haiku). overlay.qcow2 holds an
# INTERNAL 'golden' snapshot (full RAM+device state) of the running Workbench 1.3 desktop.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden) so the tile
#     comes up already on the Workbench desktop (no Amiga boot, no floppy load, no keys).
#   * overlay.qcow2 is a THIN qcow2 OVERLAY on the read-only shared base
#     /data/vms/bridge/bridge-base.qcow2 — NEVER delete/recreate it (the golden snapshot
#     lives inside it). Runs WITHOUT -snapshot so savevm persists.
#   * Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
set -e
BASE=/data/vms/streamhost/stations/amiga
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Boot straight into the golden Workbench-desktop fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-amiga \
  -enable-kvm -m 1536 -smp 2 -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5818-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile amiga qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54118 ssh=127.0.0.1:5818 loadvm='${LOADVM:-<none: cold boot>}'"
