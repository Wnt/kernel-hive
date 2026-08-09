#!/bin/bash
# Launch tile 'dragon32' (VMID 233) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running MAME 0.289's `dragon32` driver
# — a Dragon 32 (Port Talbot, Wales, 1982) resting at its own untouched power-on
# screen, Microsoft 16K Extended Color BASIC in dark green on the MC6847's
# bright green page, drawn fullscreen with aspect correction on the stock
# 1024x768 X root. Keyboard exhibit (no pointer). Kill only by pidfile.
#
# THE ONE THING THAT MUST NOT DRIFT lives in the GUEST's /etc/bridge/launch.sh,
# not here: `-ext ""`. MAME's dragon32 defaults its `ext` slot to `dragon_fdc`,
# so without that flag the machine boots DRAGONDOS 1.0 instead of BASIC — and
# `-verifyroms` demands the FDC ROM that causes it. See
# scripts/build-guests/tiles/dragon32.sh, which asserts the banner by OCR.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like mpf2/c64/plus4/vic20).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + MAME at that power-on screen.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
set -e
BASE=/data/vms/streamhost/tiles/dragon32
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden Dragon 32 BASIC fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-dragon32 \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5833-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile dragon32 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54130 ssh=127.0.0.1:5833 loadvm='${LOADVM:-<none: cold boot>}'"
