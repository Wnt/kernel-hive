#!/bin/bash
# Launch tile 'zxspectrum' (VMID 230) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running Debian's own MAME 0.251
# (`spectrum` driver, `-bios en`) emulating a Sinclair ZX Spectrum 48K (1982)
# that boots the 16 KB ROM straight to its power-on screen — the machine's own
# white paper across the whole raster with "© 1982 Sinclair Research Ltd" in
# black along the bottom. MAME runs FULLSCREEN with -keepaspect on the bridge
# base's stock 1024x768 X root, which the Spectrum's 4:3 picture fills exactly.
# Keyboard exhibit (no pointer: no pointing device was ever made for it).
# Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/apple2/atarist/amiga/mpf2).
# The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared base
# /data/vms/bridge/bridge-base.qcow2 and holds an INTERNAL 'golden' snapshot
# (full RAM+device state) of X (-nocursor) + MAME at the power-on screen.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * 768 MB is the whole machine's memory and is deliberate: MAME plus the X
#     kiosk leaves ~320 MB MemAvailable in the guest, measured with the kiosk up.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
#     MAME maps host LEFT shift to CAPS SHIFT and host RIGHT shift to SYMBOL
#     SHIFT, which is why the SPA ships a zxspectrum keyboard profile.
set -e
BASE=/data/vms/streamhost/stations/zxspectrum
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden ZX Spectrum fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-zxspectrum \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5830-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile zxspectrum qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54127 ssh=127.0.0.1:5830 loadvm='${LOADVM:-<none: cold boot>}'"
