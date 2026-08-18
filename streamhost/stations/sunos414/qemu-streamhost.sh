#!/bin/bash
# Launch station 'sunos414' (slot 147) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# SunOS 4.1.4 (Solaris 1.1.2) with OpenWindows 3 on an emulated SPARCstation 5
# (sun4m) — a foreign-architecture QEMU station in the macos753/hpuxvue mould.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no sparc target, so this
# station runs a standalone build of the kernel-hive QEMU fork
# (github.com/Wnt/qemu, branch kernel-hive) installed at /opt/qemu-sparc; the
# OpenBIOS sparc32 firmware and the cgthree FCode ROM are the fork's own
# pc-bios blobs copied to /opt/qemu-sparc/share/qemu (-L). Rebuild:
#   ../configure --target-list=sparc-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-sparc
#   ninja qemu-system-sparc; install it + pc-bios/openbios-sparc32,QEMU,cgthree.bin
#
# TCG, NO KVM. 32-bit SPARC has no acceleration path; the station burns a host
# core whenever the guest runs.
#
# THE FOUR LOAD-BEARING FLAGS (each one cost a boot attempt, see docs/guests):
#   -vga cg3                      SunOS 4.1.4 has no driver for QEMU's TCX.
#   -m 64                         256 MB -> Trap 0x29 (Data Access Error) at boot.
#   scsi-id=3 disk / scsi-id=6 CD MUNIX/GENERIC hard-wire sd0=target 3, sr0=target 6.
#   physical_block_size=512 (CD)  SunOS's sr driver reads 512-byte blocks;
#                                 2048 -> "esp0: data transfer overrun".
#
# POINTER: Sun serial mouse, relative only (no absolute device exists on this
# platform), so the daemon runs SH_INPUT_BACKEND=dbus-rel.
#
# BOOT: OpenBIOS will NOT auto-boot the target-3 SCSI disk (its `disk` alias is
# not sd@3, and SunOS must see the disk as sd0 = target 3), so there is no cold
# auto-boot. The golden loadvm IS the boot path: with a `golden` snapshot the
# launcher restores the booted system instantly (-loadvm golden -S, frozen
# until the first visitor); without one the guest sits at the OpenBIOS "0 >"
# prompt for a human/baker to drive `boot /iommu/sbus/espdma/esp/sd@3,0:a`.
# The CD stays attached with the same ISO either way, so the device set is
# loadvm-exact.
set -e
D=/data/vms/streamhost/stations/sunos414
A=/data/vms/streamhost/assets/sunos414
QEMU=/opt/qemu-sparc/bin/qemu-system-sparc
DISK=$D/sunos414-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 4G >/dev/null
# Boot shape: a golden loadvm restores the booted SunOS instantly (the exhibit,
# frozen -S until the first visitor). Without a golden the guest lands at the
# OpenBIOS "0 >" prompt — OpenBIOS will not auto-boot the target-3 disk that
# SunOS needs to see as sd0, so the golden IS the boot path (bake it by driving
# `boot /iommu/sbus/espdma/esp/sd@3,0:a` once, then savevm golden). No -boot.
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
fi
# Telnet exec forward (labctl exec sunos414 -> sunexec.py). SLIRP forwards are
# host-side, NOT in the loadvm snapshot, so re-add on every start (alpine does
# the same for its ssh forward). Guest is 10.0.2.15 (static in the golden);
# in.telnetd runs from inetd, root has no password.
EXEC_PORT=5947
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms (fork
# patch; its run-state idle gate keeps a paused TCG station at ~0 cost).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into flags
nohup "$QEMU" -L /opt/qemu-sparc/share/qemu \
  -name streamhost-sunos414 \
  -M SS-5 -accel tcg -m 64 \
  -vga cg3 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive if=none,id=hd0,file=$DISK,format=qcow2,cache=writeback,aio=threads \
  -device scsi-hd,scsi-id=3,drive=hd0 \
  -drive if=none,id=cd0,media=cdrom,file=$A/sunos414.iso,format=raw,readonly=on \
  -device scsi-cd,scsi-id=6,drive=cd0,physical_block_size=512 \
  -net nic,model=lance -net user \
  -serial unix:$D/serial.sock,server=on,wait=off \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
# re-establish the host->guest telnet forward for labctl exec (best-effort;
# harmless if the guest is still at OpenBIOS with no telnetd yet).
[ -S "$D/qmp.sock" ] && python3 /root/qmp_hmp.py "$D/qmp.sock" \
  "hostfwd_add tcp:127.0.0.1:${EXEC_PORT}-10.0.2.15:23" >/dev/null 2>&1 || true
echo "station sunos414 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54147 exec=127.0.0.1:${EXEC_PORT} loadvm='${LOADVM:-<none: OpenBIOS prompt>}'"
