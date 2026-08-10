#!/bin/bash
# Launch tile 'armeval' (VMID 238) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running the SAME purpose-built MAME
# `bbcb` (MAME 0.289, SUBTARGET=bbcb) the bbcmicro tile ships, but with the ARM
# Evaluation System fitted to the BBC Micro's Tube — `-tube arm`, the Acorn 1770
# disc interface, Acorn ADFS 1.30 in sideways socket 3 and Disc 3 of the ARM
# Evaluation System set in drive 0. Fullscreen with aspect correction on an
# 800x600 X root. Keyboard exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/mpf2/plus4/bbcmicro).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + MAME sitting INSIDE ARM BBC Basic
# V 1.00, running on the 1986 ARM, with the two `A*` lines that loaded it off
# the floppy still on screen above the `>` prompt.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
set -e
BASE=/data/vms/streamhost/tiles/armeval
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden ARM BASIC fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-armeval \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5838-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile armeval qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54135 ssh=127.0.0.1:5838 loadvm='${LOADVM:-<none: cold boot>}'"
