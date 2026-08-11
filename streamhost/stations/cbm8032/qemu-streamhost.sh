#!/bin/bash
# Launch tile 'cbm8032' (VMID 225) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-13 (trixie) kiosk running VICE `xpet -model 8032`
# emulating a Commodore CBM 8032 (1980) — the 80-column business PET — resting
# at its own untouched power-on screen, "*** commodore basic 4.0 ***", green on
# black, drawn double-size (-CRTCdsize) on a 1600x1200 X root. That root is the
# tightest advertised mode that CONTAINS the 1408x1064 SDL window: there is no
# window manager, so a window larger than the root is silently clipped, and a
# 1024x768 root leaves only the tail of one line visible. Keyboard exhibit (no
# pointer). Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/vic20/plus4/apple2/atarist/
# amiga/mpf2). The overlay.qcow2 is a THIN qcow2 overlay on the read-only shared
# base /data/vms/bridge/bridge-base-trixie.qcow2 and holds an INTERNAL 'golden'
# snapshot (full RAM+device state) of X (-nocursor) + xpet at the BASIC 4.0
# READY prompt.
#   * If the golden snapshot is present, boot STRAIGHT INTO it (-loadvm golden):
#     no Linux boot, no console text, no X startup ever becomes visible.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it.
#     Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * 768 MB, half what the other bridge tiles carry: measured in the guest with
#     xpet up at 1600x1200, MemAvailable is ~390 MB. scripts/build-guests/
#     cbm8032.sh re-asserts that floor on every build.
#   * Keyboard exhibit: no pointing device, PS/2 keyboard only (vmport=off).
set -e
BASE=/data/vms/streamhost/stations/cbm8032
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden CBM 8032 BASIC 4.0 fixture if the snapshot is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-cbm8032 \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 768 -smp 2 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5825-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile cbm8032 qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54109 ssh=127.0.0.1:5825 loadvm='${LOADVM:-<none: cold boot>}'"
