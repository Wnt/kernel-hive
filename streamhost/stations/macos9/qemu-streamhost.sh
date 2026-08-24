#!/bin/bash
# Launch station 'macos9' (slot 150) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# Mac OS 9.2.2 on a PowerPC G4 "mac99" — the fleet's FIRST PowerPC station.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no ppc target, so this
# station runs a standalone build of the kernel-hive QEMU fork installed at
# /opt/qemu-ppc (the macos753/-m68k arrangement). Its checkpoint is baked AND
# restored by this binary, so pve's pbs-state vmstate section never appears.
#
# THE FORK MUST INCLUDE THE cpu/tb_env VMSTATE PATCH (fork commit 196124d,
# 2026-08-24). Stock QEMU never migrates the softmmu timebase (tb_offset,
# decr_next): a checkpoint restored in a fresh process resumed with the TB
# jumped ~30 s ahead of the guest's own records, and Mac OS 9's nanokernel
# wedged permanently in its interrupts-off TB-repair loop (frozen clock,
# frozen framebuffer, 100% of a core). A golden captured by a pre-patch
# binary predates the subsection and still wedges — after any binary change
# here, re-bake the golden cold and re-prove the restore with the guest's
# menubar clock advancing two ticks in a fresh process.
# Rebuild whenever the fork moves:
#   ../configure --target-list=ppc-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-ppc
# and copy pc-bios/{openbios-ppc,vgabios-stdvga.bin,qemu_vga.ndrv} into
# /opt/qemu-ppc/share/qemu/ — ninja alone installs no firmware, and the machine
# needs all three (OpenBIOS boots it, Mac OS drives the display via the ndrv).
#
# via=pmu IS MANDATORY. The default via=cuda breaks USB keyboard and mouse in
# this guest. With via=pmu the machine instantiates its OWN USB keyboard and
# mouse behind a hub — do NOT add -device usb-kbd/-device usb-mouse: a second
# HID pair splits QEMU's input routing across two mice and clicks go nowhere
# (cost an hour of this bring-up).
#
# TCG, NO KVM: ppc guest on x86 host. Starts PAUSED at the checkpoint (-S) and
# leans on idle auto-pause; an unwatched station costs ~0.
#
# NO NIC, DELIBERATELY (-nic none). QEMU otherwise auto-creates a default
# user-mode sungem NIC on mac99. Operator scope for this add: ordinary station,
# no retronet, no networking. The golden is baked with this exact device set.
#
# NO AUDIO: QEMU's mac99 has no sound device (the community "screamer" patch is
# not in the fork). Nothing to declare, nothing to capture.
#
# POINTER: relative USB HID. Mac OS 9 has no driver for QEMU's usb-tablet
# (verified on the framebuffer: abs events never move the cursor), so the
# daemon runs its abs->rel bridge. The checkpoint pins Mouse tracking to
# "Very Slow", the only NON-accelerated setting, measured DEAD LINEAR at
# exactly 0.18 px per delta unit (600 units -> 108 px at every chunk size
# 1..32). SH_CURSOR_SCALE=5.5556 is that factor's reciprocal.
#
# CHECKPOINT MODE (resetMode=loadvm):
#   * Boots the persistent station-LOCAL qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point in it.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S),
#     frozen until the first visitor. The first-ever bake launches cold.
set -e
D=/data/vms/streamhost/stations/macos9
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/macos9-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (fork patch); its run-state idle gate keeps a
# paused TCG station at ~0 cost.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden -S (or vanish on a cold boot)
nohup /opt/qemu-ppc/bin/qemu-system-ppc \
  -name streamhost-macos9 \
  -accel tcg -m 512 \
  -M mac99,via=pmu -cpu g4 \
  -g 1024x768x32 \
  -display dbus,p2p=on \
  -nic none \
  -drive file=$D/macos9-golden.qcow2,format=qcow2,cache=writeback,aio=threads \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station macos9 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54150 loadvm='${LOADVM:-<none: cold boot>}' (checkpoint, no -snapshot)"
