#!/bin/bash
# Launch tile 'pdp11' (VMID 227) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running Open SIMH's `pdp11` simulator
# as a DEC PDP-11/70 (4 MB core, FP11) booting 2.11BSD off an MSCP pack, drawn
# as green phosphor in a fixed 80x24 xterm on a 1024x768 X root. Keyboard
# exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/plus4).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + xterm + the simulator resting at
# 2.11BSD's own multiuser `login:` prompt.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup, no 60 s PDP-11 boot.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it,
#     and so does the 2.11BSD pack (which is never committed and never served).
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
#   * 512 MB is deliberate and measured: the simulated PDP-11 is 4 MB of core,
#     the simulator's RSS is 21 MB, and the guest still reports 338 MB of
#     MemAvailable at the login prompt. See scripts/build-guests/tiles/pdp11.sh.
#   * The AC97 card stays in the device set because the golden was baked with
#     it; the exhibit itself is silent (a console terminal has nothing to say).
set -e
BASE=/data/vms/streamhost/tiles/pdp11
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden 2.11BSD login fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-pdp11 \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 512 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5827-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile pdp11 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54115 ssh=127.0.0.1:5827 loadvm='${LOADVM:-<none: cold boot>}'"
