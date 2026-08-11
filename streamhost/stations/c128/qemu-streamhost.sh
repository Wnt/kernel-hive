#!/bin/bash
# Launch tile 'c128' (VMID 223) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running VICE `x128` emulating a PAL
# Commodore 128 (1985) in its NATIVE 80-COLUMN mode — the VDC's RGBI text
# display, cyan on black, drawn 1:1 (NO -VDCdsize) in a 789x576 SDL window on
# an 800x600 X root, which it fills edge to edge. The CP/M Plus system disk sits
# in drive 8, attached AFTER reset by /usr/local/bin/c128-attach-cpm.sh inside
# the guest so the KERNAL's boot-sector check misses it; the visitor boots CP/M
# by typing BOOT. Keyboard exhibit (no pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/mpf2/
# vic20/plus4). The overlay.qcow2 is a THIN qcow2 overlay on the read-only
# shared base /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden'
# snapshot (full RAM+device state) of X (-nocursor) + x128 at the C128's own
# untouched power-on screen, "COMMODORE BASIC V7.0 122365 BYTES FREE ... READY."
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * 768 MB, half what the other VICE tiles use: measured with x128 running at
#     the fixture, the guest keeps ~396 MB of 708 MB MemAvailable free.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
set -e
BASE=/data/vms/streamhost/stations/c128
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden C128 80-column BASIC fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-c128 \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5823-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile c128 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54087 ssh=127.0.0.1:5823 loadvm='${LOADVM:-<none: cold boot>}'"
