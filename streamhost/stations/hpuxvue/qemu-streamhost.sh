#!/bin/bash
# Launch station 'hpuxvue' (slot 144) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# HP-UX 10.20 with HP VUE on an emulated HP 9000/778 (Visualize B160L,
# PA-7300LC) — a foreign-architecture QEMU station in the macos753 mould.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no hppa target, so this
# station runs a standalone build of the kernel-hive QEMU fork
# (github.com/Wnt/qemu, branch kernel-hive) installed at /opt/qemu-hppa; the
# SeaBIOS-hppa firmware (hppa-firmware.img) is the one that build installs
# beside it under share/qemu, found by the binary's default -L path. Rebuild:
#   ../configure --target-list=hppa-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-hppa
#   ninja && ninja install
#
# TCG, NO KVM. PA-RISC has no hardware acceleration path; the station burns a
# host core whenever the guest runs. `-d nochain` is part of the recipe HP-UX
# is known to boot with under TCG (catalog + virtuallyfun writeup), not a
# debugging leftover — keep it until a boot WITHOUT it is proven.
#
# GRAPHICS: the built-in Artist framebuffer, 1280x1024 HARD CEILING — higher
# modes crash or leave dtwm/vuewm's pointer unable to reach y>=1146.
#
# POINTER: LASI PS/2, relative only (no USB on this machine, no tablet), so
# the daemon runs SH_INPUT_BACKEND=dbus-rel. SH_CURSOR_SCALE is 1.0 until
# measured against the installed desktop (see station.env.fixture).
#
# THREE LAUNCH SHAPES, decided by what exists in $D:
#   1. golden snapshot in the disk  -> -loadvm golden -S (the exhibit; frozen
#      at the VUE desktop until the first visitor)
#   2. $D/INSTALLED marker          -> cold boot from the SCSI disk (-boot c)
#   3. neither                      -> INSTALL PHASE: cold boot the Install and
#      Core OS CD (-boot d) against a fresh/persistent install disk. This is
#      the dark-launch shape: the installer runs on camera at /os/hpuxvue.
# The DEVICE SET IS IDENTICAL in all three (CD drive always attached with the
# same ISO, same disk, same NIC) so a checkpoint baked in shape 2 loads in
# shape 1 — loadvm requires it.
set -e
D=/data/vms/streamhost/stations/hpuxvue
A=/data/vms/streamhost/assets/hpuxvue
QEMU=/opt/qemu-hppa/bin/qemu-system-hppa
DISK=$D/hpuxvue-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 4000M >/dev/null
BOOT="-boot d"
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
  BOOT="-boot c"
elif [ -f "$D/INSTALLED" ]; then
  BOOT="-boot c"
fi
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms (fork
# patch; its run-state idle gate keeps a paused TCG station at ~0 cost).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM/$BOOT must word-split into flags
nohup "$QEMU" \
  -name streamhost-hpuxvue \
  -M B160L -accel tcg,thread=multi -smp 1 -m 512 -d nochain \
  -display dbus,p2p=on \
  -drive if=scsi,bus=0,index=6,file=$DISK,format=qcow2,cache=writeback,aio=threads \
  -drive if=scsi,bus=0,index=2,media=cdrom,file=$A/disc1.iso,format=raw,readonly=on \
  -netdev user,id=n0 -device tulip,netdev=n0 \
  -serial unix:$D/serial.sock,server=on,wait=off \
  $BOOT $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station hpuxvue qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54144 boot='$BOOT' loadvm='${LOADVM:-<none>}'"
