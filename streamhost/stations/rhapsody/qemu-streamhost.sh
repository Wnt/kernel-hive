#!/bin/bash
# Launch station 'rhapsody' (slot 146) — Rhapsody 5.1 Developer Release 2 for
# Intel (Apple, 1998): the Platinum Finder on the NeXT/Mach substrate, the
# hinge between the nextstep station and the macos poster.
# See docs/guests/rhapsody.md and docs/lab/research/candidate-rhapsody.md.
#
#   * qemu-system-i386 from /opt/qemu-rhapsody — the kernel-hive QEMU fork
#     (11.0.2 + fast-poll) plus streamhost/qemu-patches/0006-i8259-lenient-
#     spurious-cascade.patch, enabled by KH_I8259_LENIENT_CASCADE=1. Without it
#     Rhapsody's Mach kernel loses every IDE interrupt after the first time the
#     timer and an IDE completion coincide (a spurious IRQ15 it never EOIs on
#     the master): "hc0: interrupt timeout ... Resetting drives". Stock pve-qemu
#     cannot run this guest.
#   * TCG, pentium2, 1 CPU, 64 MB (VOM's confirmed working RAM size; the DR2
#     kernel is known not to boot above 192 MB), i440fx.
#   * ONE IDE disk (rhapsody-golden.qcow2, 2 GB, MBR + Rhapsody UFS) — the
#     device set is deliberately minimal (VOM's shape). Never delete/recreate
#     it: the golden snapshot lives inside it.
#   * Cirrus GD5446 PCI (-vga cirrus; DR2 ships a "Cirrus Logic GD5446 PCI
#     Display Adapter (2MB)" driver — configured for 800x600 RGB:555/16 @60),
#     Intel EtherExpress PRO/100B PCI (-device i82557b) user-net, PS/2 mouse
#     (relative, through the daemon's abs->rel bridge, SH_INPUT_BACKEND=
#     dbus-rel; DR2's PS/2 driver mis-decodes deltas when the i8042 queue is
#     flooded — the daemon paces), COM1 to serial.log.
#   * -loadvm golden -S when the snapshot exists (frozen at the checkpoint,
#     the daemon wakes it); cold disk boot otherwise (install phase / rebake).
set -e
D=/data/vms/streamhost/stations/rhapsody
QEMU=/opt/qemu-rhapsody/bin/qemu-system-i386
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/rhapsody-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
export KH_I8259_LENIENT_CASCADE=1
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup "$QEMU" \
  -name streamhost-rhapsody \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium2 \
  -rtc base=localtime \
  -drive file=$D/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0 -boot c \
  -vga cirrus \
  -display dbus,p2p=on \
  -netdev user,id=n0 -device i82557b,netdev=n0 \
  -serial file:$D/serial.log \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station rhapsody qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54146 loadvm='${LOADVM:-<none: cold boot>}'"
