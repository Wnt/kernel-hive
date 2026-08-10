#!/bin/bash
# Launch tile 'star' (VMID 240) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 bare-X kiosk running Darkstar (C#/mono) emulating a
# real Xerox 8010 "Dandelion" workstation running Pilot + ViewPoint 2.0
# (see scripts/build-guests/tiles/star.sh, docs/guests/star.md, streamhost/docs/BRIDGE.md).
# Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like amiga/c64/daybreak). overlay.qcow2 holds an
# INTERNAL 'golden' snapshot (full RAM+device state) of the LOGGED-ON ViewPoint desktop.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden) so the tile
#     comes up already on the desktop — no 22-minute Pilot boot, no Set Time Utility, no
#     logon sheet.
#   * overlay.qcow2 is a THIN qcow2 OVERLAY on the read-only shared base
#     /data/vms/bridge/bridge-base.qcow2 — NEVER delete/recreate it (the golden snapshot
#     lives inside it). Runs WITHOUT -snapshot so savevm persists.
#   * Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#
# TWO DEVIATIONS FROM THE USUAL BRIDGE DEVICE SET, and both are the pointer:
#   * NO usb-tablet. The Star's mouse is RELATIVE and Darkstar has no absolute path at
#     all — DWindow-IO differences the host pointer against the DisplayBox centre, feeds
#     IOP.Mouse.MouseMove(dx,dy) and warps the pointer back. So the guest must see the
#     plain PS/2 mouse and streamhost runs SH_POINTER=rel, exactly like c64/qnx/nt351.
#   * vmport=off. With the VMware-mouse port live, QEMU's absolute handler absorbs the
#     REL events before the guest's PS/2 driver sees them (the c64 lesson,
#     docs/guests/c64.md).
# The AC97 card stays in the device set for parity with the bake even though this exhibit
# is SILENT: the 8010 has no sound hardware (SH_AUDIO=off).
set -e
BASE=/data/vms/streamhost/tiles/star
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Boot straight into the golden ViewPoint-desktop fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-star \
  -enable-kvm -m 1536 -smp 2 -machine pc-i440fx-11.0,vmport=off -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5840-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile star qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54138 ssh=127.0.0.1:5840 loadvm='${LOADVM:-<none: cold boot>}'"
