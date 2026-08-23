#!/bin/bash
# os2-retronet-rig.sh — boot the os2warp retronet bring-up clone.
#
# Same DEVICE SET as the live os2warp station (loadvm golden requires it):
# TCG, -cpu pentium, pc-i440fx-11.0 acpi=off usb=off, -vga std + vgamem_mb=2
# (the GENGRADD 1024x768 fix -- do not change), sb16, the COM1 warpd chardev on
# the default serial0, one IDE qcow2, and one pcnet on the retronet tap. Only
# the -display/-audiodev BACKENDS differ from production (none/none here vs
# dbus there); those are UI backends, not devices, so the device set matches.
#
# The MAC is read from the same gitignored registry/local.env line the launcher
# uses, so the clone leases the same reserved address as the real station. Only
# one guest may hold the tap at a time -- stop the live station first.
set -euo pipefail
R=/data/vms/sandbox/rn-web-os2warp/rig
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
MAC="02:00:00:00:00:13"
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_OS2WARP_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && MAC="$_m"
fi
rm -f "$R/qmp.sock" "$R/serial.sock" "$R/qemu.pid"
nohup qemu-system-x86_64 \
  -name streamhost-os2warp-rig \
  -accel tcg -m 256 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,usb=off -cpu pentium \
  -rtc base=localtime -boot c \
  -vga std -global VGA.vgamem_mb=2 \
  -display none \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -chardev socket,id=ser0,path="$R/serial.sock",server=on,wait=off -serial chardev:ser0 \
  -drive file="$R/os2.qcow2",format=qcow2,if=ide \
  -netdev tap,id=n0,ifname=os2rn0,script=no,downscript=no \
  -device pcnet,netdev=n0,mac="$MAC" \
  -qmp unix:"$R/qmp.sock",server=on,wait=off \
  -pidfile "$R/qemu.pid" \
  >"$R/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$R/qmp.sock" ] && [ -f "$R/qemu.pid" ] && break
  sleep 0.5
done
echo "rig pid=$(cat "$R/qemu.pid" 2>/dev/null) mac=${MAC//[0-9a-f]/x} qmp=$R/qmp.sock"
