#!/bin/bash
# Launch tile 'nextstep' (VMID 237) QEMU with the streamhost display wiring.
# BRIDGE tile: a captured Debian-12 kiosk running the Previous emulator as a
# NeXTcube (Motorola 68040, 25 MHz, 64 MB, Rev 2.5 v66 ROM) booting NeXTSTEP 3.3
# for m68k off a SCSI disk image, drawn on an X root that is EXACTLY the size of
# the NeXT MegaPixel display, 1120x832. See scripts/build-guests/tiles/nextstep.sh and
# docs/guests/nextstep.md. Kill only by pidfile.
#
# GOLDEN FIXTURE tile (resetMode=loadvm, like c64/amiga/pdp11). overlay.qcow2 is
# a THIN qcow2 overlay on the read-only shared /data/vms/bridge/bridge-base.qcow2
# and holds an INTERNAL 'golden' snapshot (full RAM+device state) of the kiosk
# resting on NeXTSTEP's own Workspace: the grey workspace, the Workspace menu at
# the top left, the File Viewer the machine opens for itself at login, and the
# Dock down the right-hand edge.
#   * NEVER delete/recreate overlay.qcow2 — the golden snapshot lives inside it,
#     and so does the NeXTSTEP disk image (never committed, never served).
#   * Device set MUST match the golden bake EXACTLY or -loadvm golden fails.
#   * -smp 4 is not decoration. Previous runs the 68040, the DSP, the SLIRP
#     thread and its own SDL present loop; at -smp 2 the emulator ran at half
#     speed, its input queue backed up, and the NeXT cursor lagged behind the
#     pointer by hundreds of pixels. Measured at -smp 4 / -m 1536: guest
#     MemAvailable 957 MB, `previous` RSS 247 MB, host QEMU RSS 1.06 GB.
#   * POINTER IS ABSOLUTE, end to end (2026-08-09). Previous emulates a
#     SummaGraphics digitiser on the NeXT SCC serial port B and feeds it the
#     host's ABSOLUTE window coordinates whenever `[Tablet] nTabletType` is set
#     AND the guest's tablet driver is attached; the golden is baked with
#     /NextAdmin/InstallTablet.app already run, so every visitor and every
#     `loadvm golden` gets it. The tile therefore ships `-usb -device usb-tablet`
#     and SH_INPUT_BACKEND=dbus-abs. `vmport=off` STAYS: it predates the tablet
#     (it protected the old relative path) but QEMU's implicit VMware mouse
#     would now be a SECOND absolute pointer competing with the usb-tablet, so
#     leaving it off keeps exactly one. The X root being EXACTLY 1120x832 at
#     +0+0 is load-bearing for the 1:1 map, not cosmetic — see the builder.
#   * The AC97 card is in the device set both because the golden was baked with
#     it and because the NeXT's own sound reaches ALSA through it.
set -e
BASE=/data/vms/streamhost/tiles/nextstep
OVERLAY="$BASE/overlay.qcow2"
[ -f "$BASE/qemu.pid" ] && kill "$(cat "$BASE/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$BASE/qmp.sock" "$BASE/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden NeXTSTEP Workspace fixture when it is present.
LOADVM=""
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-nextstep \
  -enable-kvm -machine pc-i440fx-11.0,vmport=off \
  -m 1536 -smp 4 -cpu host \
  -rtc base=localtime \
  -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5837-:22 -device e1000,netdev=n0 \
  $LOADVM \
  -qmp unix:$BASE/qmp.sock,server=on,wait=off \
  -pidfile $BASE/qemu.pid \
  >"$BASE/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$BASE/qmp.sock" ] && [ -f "$BASE/qemu.pid" ] && break
  sleep 0.5
done
echo "tile nextstep qemu pid=$(cat $BASE/qemu.pid 2>/dev/null) qmp=$BASE/qmp.sock udp=54134 ssh=127.0.0.1:5837 loadvm='${LOADVM:-<none: cold boot>}'"
