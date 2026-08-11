#!/bin/bash
# Launch tile 'templeos' (VMID 105) QEMU with the streamhost display wiring.
# GOLDEN TEST FIXTURE tile (2026-07-07). TempleOS V5.03 boots from its ISO and runs
# ENTIRELY IN GUEST RAM (no writable OS disk). A persistent scratch qcow2
# ('state.qcow2') is attached whose ONLY purpose is to hold the live `savevm golden`
# VM-state snapshot (full RAM + device state). It is the only block device QEMU can
# store the golden reset point into. resetMode=loadvm (see golden.env / golden.json).
#   * Runs WITHOUT -snapshot so `savevm golden` PERSISTS inside state.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden), so the
#     tile comes up already at the curated fixture: first-boot dialogs dismissed,
#     AutoComplete/"God" demo window closed (no idle animation), main HolyC terminal
#     maximized full-width and cleared to a clean keyboard-reactive `T:/Home>` prompt,
#     with the serial warpd task already running in RAM.
#     First-ever bake (no snapshot yet) launches COLD -- see golden-bake.sh, which
#     drives the tweaks then `savevm golden`.
#   * NEVER delete state.qcow2 -- it IS the golden snapshot. Create-if-missing only.
#   * -boot d keeps booting the CD; the empty IDE disk is never booted/mounted by the guest.
#   * The in-guest serial warpd agent provides absolute pointer input; do NOT add usb-tablet.
# Kill only by pidfile. neko is restored by ROLLBACK.md.
set -e
BASE=/data/vms/streamhost/stations/templeos
STATE="$BASE/state.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid" "$BASE/serial.sock"
# create-if-missing: the golden 'savevm' snapshot lives INSIDE this qcow2; never clobber.
[ -f "$STATE" ] || qemu-img create -q -f qcow2 "$STATE" 2G
# Boot straight into the fixture if the golden snapshot is already present.
LOADVM=""
qemu-img snapshot -l "$STATE" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-templeos \
  -enable-kvm -m 1024 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/TempleOS/TempleOS.ISO -boot d \
  -drive file="$STATE",if=ide,format=qcow2 \
  -vga std \
  -display dbus,p2p=on \
  $LOADVM \
  -chardev socket,id=ser0,path=$BASE/serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile templeos qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54105 loadvm='${LOADVM:-<none: cold boot>}'"
