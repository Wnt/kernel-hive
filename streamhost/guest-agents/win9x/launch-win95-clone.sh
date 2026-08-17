#!/bin/bash
# Isolated win95 clone for the warpnet absolute-cursor agent proving run (TCP variant).
# COLD boot (no -loadvm) so WIN.INI load=C:\WARPNET.EXE fires and the agent starts.
# M/P/R/B transport is warpd-over-TCP: hostfwd 127.0.0.1:57799 -> guest :7777 on the
# user netdev (NO serial chardev here; the serial variant is warpwin-serial-altbuild.c).
# Own qmp+pid.
# Device set intentionally simplified for a headless clone (display none, no audio);
# cold boot means it need not match the golden snapshot. Kill ONLY by this pidfile.
set -e
D=/data/vms/sandbox/win95-c1
DISK="$D/disk.qcow2"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
nohup qemu-system-x86_64 \
  -name win95-c1 \
  -enable-kvm -m 256 -smp 1 \
  -machine pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm -cpu pentium,-apic \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display none \
  -drive file="$DISK",format=qcow2,if=ide \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:57799-:7777 -device pcnet,netdev=n0 \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "win95-c1 pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock serial=$D/serial.sock (COLD boot)"
