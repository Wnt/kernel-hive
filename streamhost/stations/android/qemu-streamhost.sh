#!/bin/bash
# Launch tile "android" (VMID 101) QEMU with the streamhost display wiring.
#
# GOLDEN TEST FIXTURE MODE (android):
#   This tile is a curated golden fixture. The disk /data/gallery-guests/Android/
#   android.qcow2 holds an internal snapshot named "golden" (savevm) that captures
#   the fixture (RAM+devices+disk). We run WITHOUT -snapshot (writes persist) and
#   boot straight into the fixture with -loadvm golden, so every normal start is
#   identical. A fresh rebuild without the snapshot cold-boots once so the
#   fixture can be baked instead of making the launcher fail immediately.
#   resetMode=loadvm: reset live (no reboot) by sending "loadvm golden" to the
#   dedicated HMP reset socket (reset-hmp.sock) below; a plain restart also lands
#   on golden because of -loadvm golden. See golden-manifest.md.
#   Base disk backed up at android.qcow2.bak-pre-golden before the fixture edits.
#
# Kill only by pidfile.
set -e
T=/data/vms/streamhost/stations/android
DISK=/data/gallery-guests/Android/android.qcow2
LOADVM=()
if qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  LOADVM=(-loadvm golden -S)
fi
[ -f "$T/qemu.pid" ] && kill "$(cat "$T/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$T/qmp.sock" "$T/qemu.pid" "$T/reset-hmp.sock"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-android \
  -enable-kvm -m 3072 -smp 4 \
  -machine pc-q35-11.0 -cpu host \
  -rtc base=localtime \
  -boot c \
  "${LOADVM[@]}" \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device intel-hda -device hda-output,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file="$DISK",if=none,id=hd0,format=qcow2 -device virtio-blk-pci,drive=hd0 -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -qmp unix:"$T/qmp.sock",server=on,wait=off \
  -monitor unix:"$T/reset-hmp.sock",server,nowait \
  -pidfile "$T/qemu.pid" \
  >"$T/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$T/qmp.sock" ] && [ -f "$T/qemu.pid" ] && break
  sleep 0.5
done
if [ "${#LOADVM[@]}" -gt 0 ]; then
  echo "tile android qemu pid=$(cat "$T/qemu.pid" 2>/dev/null) qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54101 (booted -loadvm golden)"
else
  echo "tile android qemu pid=$(cat "$T/qemu.pid" 2>/dev/null) qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54101 (cold boot: golden not present yet)"
fi
