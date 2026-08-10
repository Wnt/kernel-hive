#!/bin/bash
# Launch tile 'oricatmos' (VMID 234) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running MAME's `orica` driver, an Oric
# Atmos (1984) resting at its own power-on screen — ORIC EXTENDED BASIC V1.1,
# (c) 1983 TANGERINE, 37631 BYTES FREE, Ready — drawn fullscreen with aspect
# correction on an 800x600 X root (4:3, the shape the machine drew on a
# television). Keyboard exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/mpf2).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + MAME at the BASIC banner.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
#   * 768 MB is the whole guest: Debian 13 with no desktop, X, and one 6502.
set -e
BASE=/data/vms/streamhost/tiles/oricatmos
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden Oric BASIC fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-oricatmos \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5834-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile oricatmos qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54131 ssh=127.0.0.1:5834 loadvm='${LOADVM:-<none: cold boot>}'"
