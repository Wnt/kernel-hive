#!/bin/bash
# Launch station 'macos753' (slot 142) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# Mac OS 7.5.3 on a Motorola 68040 Quadra 800 — the fleet's FIRST
# foreign-architecture QEMU station. Everything unusual about this launcher
# follows from that.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships x86_64/i386/arm/aarch64
# and no m68k target at all, so this station runs a standalone build of the
# kernel-hive QEMU fork (github.com/Wnt/qemu, branch kernel-hive) installed at
# /opt/qemu-m68k — the same arrangement nt4 uses for its Cirrus-fix build. The
# usual objection to a non-pve binary is that it cannot `loadvm` a checkpoint
# carrying pve's pbs-state vmstate section; it does not apply here, because this
# station's checkpoint is baked AND restored by this binary and never contains
# that section. Rebuild it whenever the fork moves:
#   ../configure --target-list=m68k-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-m68k
#
# TCG, NO KVM. m68k has no hardware acceleration path, so this station burns
# real host CPU whenever it runs. That is why it starts PAUSED (-S) at the
# checkpoint and leans on idle auto-pause: an unwatched station costs ~0.
#
# THE PRAM IS A qcow2, NOT RAW, and that is load-bearing. A raw `if=mtd` drive
# makes `savevm` refuse outright — "Device 'mtd0' is writable but does not
# support snapshots" — so the whole checkpoint plane depends on this one flag.
# The PRAM also carries the boot device (offset 120) and the mouse-tracking
# setting the 1:1 pointer calibration depends on; it is fixture state, not
# scratch, and is restored from the checkpoint like everything else.
#
# NO NETWORK CARD. The q800 has a dp83932 and Mac OS would happily drive it,
# but the exhibit needs no network, and every device omitted is one less thing
# in the vmstate and one less thing for TCG to emulate.
#
# AUDIO IS NOT OPTIONAL. `-M q800` instantiates the Apple Sound Chip and QEMU
# REFUSES TO START without an audiodev bound to the machine
# ("Initializing audio stream failed"), so `audiodev=snd0` on -M is required
# even though the audio itself rides the dbus display.
#
# POINTER: ADB relative. There is no absolute pointer path on this machine at
# all — no USB bus, no tablet — so the daemon runs SH_INPUT_BACKEND=dbus-rel and
# converts absolute client coordinates into deltas. The guest moves 0.36 px per
# delta unit (Mouse control panel at "Very Slow", the only non-accelerated
# setting), hence SH_CURSOR_SCALE=2.7778 in the emitted station.env.
#
# CHECKPOINT MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent station-LOCAL qcow2 pair (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN them.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S)
#     so the station comes up already at the quiet Finder desktop, frozen until
#     the first visitor arrives. The first-ever bake launches cold.
set -e
D=/data/vms/streamhost/stations/macos753
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/macos753-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms. The patch
# is in the fork this binary is built from, and its run-state idle gate is what
# keeps a paused TCG station at ~0 cost.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup /opt/qemu-m68k/bin/qemu-system-m68k \
  -name streamhost-macos753 \
  -accel tcg -m 128 \
  -M q800,audiodev=snd0 -cpu m68040 \
  -bios /data/vms/streamhost/assets/macos753/800.ROM \
  -g 1152x870x8 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive file=$D/pram-golden.qcow2,format=qcow2,if=mtd \
  -device scsi-hd,scsi-id=6,drive=hd0 \
  -drive file=$D/macos753-golden.qcow2,format=qcow2,cache=writeback,aio=threads,if=none,id=hd0 \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station macos753 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54142 loadvm='${LOADVM:-<none: cold boot>}' (checkpoint, no -snapshot)"
