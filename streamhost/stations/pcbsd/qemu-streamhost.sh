#!/bin/bash
# Launch station 'pcbsd' (VMID 179) QEMU with the streamhost display wiring.
# PC-BSD 1.5.1 (FreeBSD 6.3-RELEASE + KDE 3.5.8, i386), installed from
# PCBSD1.5.1-x86-CD1.iso (archive.org, 688930816 bytes) onto disk.qcow2.
# disk.qcow2 is the ONLY block device and carries the `golden` vmstate
# (savevm golden at the clean KDE desktop). Kill only by pidfile.
# Device set (golden + binary + devices are ONE combination): pc-i440fx-11.0,
# KVM, -cpu host, 1024 MB, 1 vCPU, -vga std (X.org vesa 1024x768), IDE disk,
# AC97 over the dbus audiodev, usb-tablet (+ the pc machine's PS/2 mouse),
# e1000 user-mode NIC. No cdrom at runtime.
set -e
SDIR=/data/vms/streamhost/stations/pcbsd
[ -f "$SDIR/qemu.pid" ] && kill "$(cat "$SDIR/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$SDIR/qmp.sock" "$SDIR/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-pcbsd \
  -enable-kvm -m 1024 -smp 1 \
  -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -drive file=$SDIR/disk.qcow2,if=ide,index=0,media=disk,format=qcow2 \
  -boot c \
  -loadvm golden -S \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0 -device e1000,netdev=n0 \
  \
  -qmp unix:$SDIR/qmp.sock,server=on,wait=off \
  -pidfile $SDIR/qemu.pid \
  >"$SDIR/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$SDIR/qmp.sock" ] && [ -f "$SDIR/qemu.pid" ] && break
  sleep 0.5
done
echo "station pcbsd qemu pid=$(cat $SDIR/qemu.pid 2>/dev/null) qmp=$SDIR/qmp.sock udp=54179"
