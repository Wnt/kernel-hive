#!/bin/bash
# Launch station 'aux' (slot 145) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# A/UX 3.0.1 — Apple's System V Unix wearing the Macintosh Finder — on the same
# emulated Quadra 800 the macos753 station runs: qemu-system-m68k -M q800 from
# the kernel-hive QEMU fork at /opt/qemu-m68k (pve-qemu ships no m68k target;
# see macos753's launcher for the full argument). TCG only, no KVM.
#
# THE INSTALL CD IS NOT ROM-BOOTABLE. The archived A/UX 3.0.1 CD's HFS boot
# blocks are zeroed and its Driver Descriptor Map lists no driver, so the ROM
# skips it (blinking-floppy) — on real hardware it was booted from the
# "Installation Boot Disk" floppy, and QEMU's SWIM floppy is a stub. So the
# INSTALL PHASE boots a throwaway copy of the macos753 System 7.5.3 disk as a
# helper at SCSI 5, mounts the CD's HFS partition in the Finder, and runs the
# CD's own Apple HD SC Setup (A/UX) + A/UX Startup from there. The helper and
# the CD leave the device set once the install is done, and the checkpoint is
# baked WITHOUT them — a checkpoint's device set is fixed at bake time and this
# one must not depend on 450 MB of install media.
#
# THE PRAM IS A qcow2 (raw if=mtd makes savevm refuse) and it carries the boot
# device selection (offset 120): SCSI 5 (helper) during the install, SCSI 6
# afterwards. AUDIO IS NOT OPTIONAL on -M q800 (Apple Sound Chip).
#
# POINTER: ADB relative (dbus-rel). SH_CURSOR_SCALE is 1.0 until measured
# against the installed A/UX desktop (X11 accel is the likely factor).
#
# THREE LAUNCH SHAPES, decided by what exists in $D:
#   1. golden snapshot in the disk -> -loadvm golden -S (the exhibit)
#   2. $D/INSTALLED marker         -> cold boot from the A/UX disk (SCSI 6)
#   3. neither                     -> INSTALL PHASE (helper at 5 + CD at 3),
#      boot the helper. Dark launch: the installer runs on camera at /os/aux.
set -e
D=/data/vms/streamhost/stations/aux
A=/data/vms/streamhost/assets/aux
QEMU=/opt/qemu-m68k/bin/qemu-system-m68k
DISK=$D/aux-golden.qcow2
PRAM=$D/pram-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 1000M >/dev/null
LOADVM=""
INSTALL=""
BOOT_SCSI=6
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
elif [ ! -f "$D/INSTALLED" ]; then
  BOOT_SCSI=5
  INSTALL="-device scsi-hd,scsi-id=5,drive=hd5 -drive file=$D/helper.qcow2,format=qcow2,cache=writeback,aio=threads,if=none,id=hd5 -device scsi-cd,scsi-id=3,drive=cd0 -drive file=$A/AUX_3.0.1_Install.iso,format=raw,media=cdrom,if=none,id=cd0"
fi
# PRAM: create if missing; outside a checkpoint force the boot-device bytes
# (offset 120: ffff + ~(scsi+32) big-endian) so the shape above is what boots.
if [ -z "$LOADVM" ]; then
  [ -f "$PRAM" ] && qemu-img convert -f qcow2 -O raw "$PRAM" "$D/pram.raw" || head -c 256 /dev/zero >"$D/pram.raw"
  python3 - "$D/pram.raw" "$BOOT_SCSI" <<'PY'
import sys
p, scsi = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read().ljust(256, b"\0")[:256])
v = (~(scsi + 32)) & 0xFFFF
b[120:124] = bytes([0xFF, 0xFF, (v >> 8) & 0xFF, v & 0xFF])
open(p, "wb").write(b)
PY
  qemu-img convert -f raw -O qcow2 "$D/pram.raw" "$PRAM"
fi
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM/$INSTALL must word-split into flags (or vanish)
nohup "$QEMU" \
  -name streamhost-aux \
  -accel tcg -m 128 \
  -M q800,audiodev=snd0 -cpu m68040 \
  -bios $A/800.ROM \
  -g 1152x870x8 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive file=$PRAM,format=qcow2,if=mtd \
  -device scsi-hd,scsi-id=6,drive=hd0 \
  -drive file=$DISK,format=qcow2,cache=writeback,aio=threads,if=none,id=hd0 \
  $INSTALL \
  -serial unix:$D/serial.sock,server=on,wait=off \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "station aux qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54145 loadvm='${LOADVM:-<none>}' install='${INSTALL:+helper+cd}' boot-scsi=$BOOT_SCSI"
