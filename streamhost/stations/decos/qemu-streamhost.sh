#!/bin/bash
# Launch tile 'decos' (VMID 229) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running ONE fullscreen xterm (green on
# black, 80x31) whose only program is a chooser offering three of the operating
# systems DEC sold for the PDP-11 — RT-11 V5.3, RSX-11M V4.2 and RSTS/E V9.6 —
# each simulated by Open SIMH (one BIN/pdp11 binary, three .ini files). Keyboard
# exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/plus4).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + the xterm parked ON THE CHOOSER,
# blocked in `read`. No simulator is running in the golden, so a tile nobody is
# looking at costs nothing.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it,
#     and so do the three prepared PDP-11 packs under /opt/decos/disks.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
#   * 768 MB is enough and was verified in the guest: the whole exhibit is one
#     xterm plus at most one SIMH process whose largest configured PDP-11 has
#     4 MB of core (measured guest RSS 17-82 MB per simulator).
set -e
BASE=/data/vms/streamhost/stations/decos
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden PDP-11 chooser fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-decos \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5829-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile decos qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54126 ssh=127.0.0.1:5829 loadvm='${LOADVM:-<none: cold boot>}'"
