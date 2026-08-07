#!/bin/bash
# Launch tile 'amstradcpc' (VMID 219) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running Caprice32 (cap32) in its
# framebuffer-verified scale-3 SDL/X11 window, emulating an Amstrad CPC 6128
# that boots Locomotive BASIC to the yellow-on-blue Ready prompt (see
# scripts/build-guests/amstradcpc.sh and streamhost/docs/BRIDGE.md).
# Keyboard exhibit (no mouse; the AMX mouse was rare). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/atarist). The overlay.qcow2 holds
# an INTERNAL 'golden' snapshot (full RAM+device state) of the running CPC Ready prompt.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden) so the
#     tile comes up already on the Locomotive BASIC Ready prompt (no CPC boot, no keys).
#   * overlay.qcow2 is a THIN qcow2 OVERLAY on the read-only shared base
#     /data/vms/bridge/bridge-base.qcow2 — NEVER delete/recreate it (the golden
#     snapshot lives inside it). Runs WITHOUT -snapshot so savevm persists.
#   * Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: browser absolute coords translate to tablet-free PS/2 REL
#     (vmport=off); the CPC has no pointer, so mouse motion is inert by design.
set -e
BASE=/data/vms/streamhost/tiles/amstradcpc
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# Boot straight into the golden CPC-Ready fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-amstradcpc \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 1536 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5819-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile amstradcpc qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54119 ssh=127.0.0.1:5819 loadvm='${LOADVM:-<none: cold boot>}'"
