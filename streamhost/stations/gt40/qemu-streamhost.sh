#!/bin/bash
# Launch tile 'gt40' (VMID 228) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running Open SIMH's `pdp11` simulator
# with the VT11 vector display, executing the original 1973 GT40 Lunar Lander
# paper tape (PDP11/lunar11/lunar.lda, in-tree and MIT-licensed — no external
# media). SIMH's fixed 1024x1024 VT11 window is centred by SDL at +128+0 on a
# 1280x1024 X root, the smallest mode the kiosk's bochs-drm advertises that
# contains it. LIGHT-PEN exhibit: absolute USB tablet, NO keyboard use at all.
# Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/plus4).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X + the simulator at the first seconds of a fresh
# lunar descent.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * An internal snapshot carries the DISK too, so any change made inside the
#     kiosk (a new /etc/bridge/launch.sh, say) is REVERTED by the next restore
#     until it is re-baked. scripts/build-guests/tiles/gt40.sh therefore never boots
#     with -loadvm; only this production launcher does.
#   * usb-tablet is REQUIRED: the VT11 light pen is mouse button 1 in Open SIMH
#     (display/sim_ws.c: display_lp_sw = mev.b1_state), so the pen is on the
#     glass only while the button is held, at the position of that same event.
set -e
BASE=/data/vms/streamhost/stations/gt40
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden fresh-descent fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-gt40 \
  -enable-kvm -machine pc-i440fx-11.0 \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5828-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile gt40 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54125 ssh=127.0.0.1:5828 loadvm='${LOADVM:-<none: cold boot>}'"
