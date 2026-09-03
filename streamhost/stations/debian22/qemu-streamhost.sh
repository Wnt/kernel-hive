#!/usr/bin/env bash
# Debian GNU/Linux 2.2 "potato" (i386, 2000) — VMID/slot 182, UDP 54182.
#
# AIR-GAPPED GUEST: -nodefaults is mandatory and this launcher intentionally
# contains no NIC, netdev, host forwarding, or other guest network hardware.
# The qcow2 must carry the internal snapshot "golden"; launcher and disk are an
# atomic pair.  Reset is HMP `loadvm golden`, never an in-guest channel.
#
# Device set (the golden vmstate was captured on EXACTLY this set — never change
# one without recapturing):
#   * pc-i440fx-11.0, KVM, -cpu host, 256 MB, 1 vCPU (kernel 2.2.19, no highmem)
#   * IDE primary master = disk.qcow2 (the whole install + the golden vmstate)
#   * IDE secondary master = the Debian 2.2 CD1 ISO, kept attached (apt source
#     and part of the captured device set)
#   * -vga cirrus: XFree86 3.3.6 XF86_SVGA drives the Cirrus GD5446 natively
#     (3.3.x has no generic VESA server, so -vga std would leave X at 320x200)
#   * PS/2 relative mouse (XFree86 3.3.6 has no absolute/tablet protocol),
#     PS/2 keyboard; no USB, no audio
set -euo pipefail

T=/data/vms/streamhost/stations/debian22
DISK=$T/disk.qcow2
CDROM=/data/gallery-guests/Debian22/debian-2.2-i386-cd1.iso

if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  echo "debian22: required qcow2 snapshot 'golden' is missing" >&2
  exit 1
fi
[ -f "$CDROM" ] || {
  echo "debian22: CD image missing: $CDROM" >&2
  exit 1
}

if [ -f "$T/qemu.pid" ]; then
  pid=$(cat "$T/qemu.pid")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$T/qmp.sock" "$T/reset-hmp.sock" "$T/qemu.pid"

export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-debian22 \
  -nodefaults \
  -enable-kvm -machine pc-i440fx-11.0 -cpu host \
  -m 256 -smp 1 -rtc base=localtime \
  -drive file="$DISK",format=qcow2,if=ide,index=0 \
  -drive file="$CDROM",media=cdrom,if=ide,index=2 \
  -boot order=c -loadvm golden -S \
  -vga cirrus \
  -display dbus,p2p=on \
  -qmp unix:"$T/qmp.sock",server=on,wait=off \
  -monitor unix:"$T/reset-hmp.sock",server,nowait \
  -pidfile "$T/qemu.pid" \
  >"$T/qemu.log" 2>&1 &

for _ in $(seq 1 80); do
  [ -S "$T/qmp.sock" ] && [ -f "$T/qemu.pid" ] && break
  sleep 0.25
done
[ -S "$T/qmp.sock" ] && [ -f "$T/qemu.pid" ]
echo "tile debian22 qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54182 (air-gapped; -loadvm golden)"
