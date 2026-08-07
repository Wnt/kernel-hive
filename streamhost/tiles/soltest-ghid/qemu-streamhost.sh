#!/bin/bash
# Cold-boot Solaris A/B tile using the isolated gallery-hid QEMU and driver.
# VMID label 9912; UDP 54912; guest exec hostfwd 58792. Never loads VMState.
set -euo pipefail

D=/data/vms/streamhost/tiles/soltest-ghid
QEMU=/data/vms/soltest/lli/spike-solaris-a/qemu-build/qemu-system-x86_64
QEMU_DATA=/data/vms/soltest/lli/spike-solaris-a/qemu-build/pc-bios
DISK="$D/soltest-ghid.qcow2"
PIDFILE="$D/qemu.pid"

[ -x "$QEMU" ] || {
  echo "missing standalone QEMU: $QEMU" >&2
  exit 1
}
[ -d "$QEMU_DATA" ] || {
  echo "missing standalone QEMU data: $QEMU_DATA" >&2
  exit 1
}
[ -f "$DISK" ] || {
  echo "missing tile disk: $DISK" >&2
  exit 1
}
if [ -f "$PIDFILE" ]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    kill "$oldpid"
    for _ in $(seq 1 40); do
      kill -0 "$oldpid" 2>/dev/null || break
      sleep 0.25
    done
  fi
fi
rm -f "$D/qmp.sock" "$D/gallery-hid.sock" "$PIDFILE"

export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup "$QEMU" -L "$QEMU_DATA" \
  -name streamhost-soltest-ghid-vmid-9912 \
  -enable-kvm -m 3072 -smp 2 \
  -machine pc-i440fx-11.0 -cpu Nehalem \
  -rtc base=localtime -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive file="$DISK",if=ide,index=0,media=disk,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:58792-10.0.2.15:7777 \
  -device e1000,netdev=net0 \
  -chardev socket,id=ghid0,path=$D/gallery-hid.sock,server=on,wait=off \
  -device gallery-hid-pci,id=ghid0,chardev=ghid0,bus=pci.0,addr=0x1e \
  -no-shutdown \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile "$PIDFILE" \
  >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 60); do
  [ -S "$D/qmp.sock" ] && [ -S "$D/gallery-hid.sock" ] &&
    [ -f "$PIDFILE" ] && break
  sleep 0.5
done
[ -S "$D/qmp.sock" ] && [ -S "$D/gallery-hid.sock" ] &&
  [ -f "$PIDFILE" ] || {
  tail -80 "$D/qemu.log" >&2
  exit 1
}
echo "tile=soltest-ghid vmid=9912 pid=$(cat "$PIDFILE") qmp=$D/qmp.sock ghid=$D/gallery-hid.sock udp=54912 bridge=57812 hostfwd=58792 vnc=none cold_boot=yes"
