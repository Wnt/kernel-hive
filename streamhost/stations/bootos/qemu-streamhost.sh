#!/bin/bash
# Launch station 'bootos' (VMID 174) QEMU with the streamhost display wiring.
# bootOS (Oscar Toledo G., 2019): an entire OS in one 512-byte boot sector, on a
# 720K floppy that also carries 19 boot-sector programs. HOST-NATIVE Tier 1.
#   * ONE block device: floppy.qcow2 — the 720K floppy image AS QCOW2. It holds
#     the filesystem the guest writes (enter/del/format) AND the `savevm golden`
#     vmstate, so `loadvm golden` restores the floppy contents too: a visitor who
#     deletes fbird does not delete it for the next visitor.
#   * create-if-missing: the first launch copies the builder's pristine floppy
#     from /data/gallery-guests/BootOS; after the bake it carries the golden.
#     NEVER delete floppy.qcow2 -- it IS the golden snapshot.
#   * Conditional -loadvm golden -S (streamhost resumes it), cold boot otherwise.
#   * Keyboard-only: bootOS reads the BIOS keyboard (int 16h). No pointer device,
#     SH_INPUT_BACKEND=disabled. PC speaker -> the dbus audiodev.
# Kill only by pidfile.
set -e
BASE=/data/vms/streamhost/stations/bootos
FLOPPY="$BASE/floppy.qcow2"
PRISTINE=/data/gallery-guests/BootOS/bootos-floppy.qcow2
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
[ -f "$FLOPPY" ] || cp "$PRISTINE" "$FLOPPY"
LOADVM=""
qemu-img snapshot -l "$FLOPPY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup qemu-system-x86_64 \
  -name streamhost-bootos \
  -enable-kvm -m 64 -smp 1 \
  -machine pc-i440fx-11.0,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -drive file="$FLOPPY",if=floppy,format=qcow2 -boot a \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "station bootos qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54174 loadvm='${LOADVM:-<none: cold boot>}'"
