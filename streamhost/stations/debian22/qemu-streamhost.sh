#!/usr/bin/env bash
# Debian GNU/Linux 2.2 "potato" (i386, 2000) — VMID/slot 182, UDP 54182.
#
# -nodefaults with ONE NIC: ne2k_pci on SLIRP, whose only host forward is a
# LOOPBACK port publishing the guest X server for the x11warp pointer sink
# (127.0.0.1:6082 -> 10.0.2.15:6000). No other network hardware or forwards.
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
#   * TWO NICs. OSCAR and the retronet web plane cannot traverse slirp, and the
#     x11warp hostfwd cannot ride a bridge, so the station carries both (amix
#     precedent). The tap NIC is deliberately an rtl8139, a DIFFERENT driver
#     from the slirp ne2k_pci, so Linux 2.2.17 numbers them deterministically:
#     ne2k-pci.o = eth0 (slirp 10.0.2.15), rtl8139.o = eth1 (retronet
#     10.99.0.36, static, DNS 10.99.0.2, NO default route). rn-tapnet.sh owns
#     tap debian22rn0 + the fail-closed DEBIAN22RN-IN guard chain and is called
#     `up` on every launch. The MAC lives in the golden vmstate, so this mac=
#     must MATCH the baked one (52:54:00:52:4e:24) — a change needs a cold bake.
#   * ne2k_pci on user-mode SLIRP with restrict=on: the hostfwd to :6000 still
#     works (it is inbound), but the guest can no longer reach labhost's stack
#     through 10.0.2.2 — the slirp NIC is a pointer sink only, and the retronet
#     tap is the guest's ONLY way out. hostfwd tcp:127.0.0.1:6082-10.0.2.15:6000
#     (x11warp: the daemon warps the pointer through the guest X server and
#     reads it back; /etc/X0.hosts in the golden grants 10.0.2.2)
#   * PS/2 keyboard + PS/2 mouse for buttons; no USB, no audio
#   * hdparm -d1 in rcS: PIIX bus-master DMA (60+ MB/s) instead of 27 KB/s PIO
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

bash "$(dirname "$0")/rn-tapnet.sh" up

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
  -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:6082-10.0.2.15:6000 -device ne2k_pci,netdev=n0 \
  -netdev tap,id=n1,ifname=debian22rn0,script=no,downscript=no \
  -device rtl8139,netdev=n1,mac=52:54:00:52:4e:24 \
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
echo "tile debian22 qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54182 x11warp=127.0.0.1:6082 (-loadvm golden)"
