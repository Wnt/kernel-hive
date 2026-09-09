#!/usr/bin/env bash
# Red Hat Linux 6.2 "Zoot" (2000) — VMID/slot 181, UDP 54181.
#
# Kickstart-installed guest (scripts/build-guests/assets/redhat62/ks.cfg) on
# -vga cirrus (XF86_SVGA 3.3.6, 1024x768x16) with ONE NIC: ne2k_pci on SLIRP.
# KVM is viable ONLY because the golden boots the UP kernel (LILO default
# linux-up; anaconda's default "linux" is kernel-smp, which loops on
# "hda: lost interrupt" through the IO-APIC) and rc.local runs `hdparm -d1`:
# measured 2026-09-03 using_dma=1, 69.57 MB/s buffered reads under -cpu host,
# against ~27 KB/s of 512-byte PIO without it. loadvm golden lands after both.
# restrict=on on the SLIRP netdev (2026-09-03): the hostfwd still reaches the
# guest's X server, but the guest can no longer reach labhost's stack through
# 10.0.2.2 in the other direction. eth0 is therefore configured STATIC
# (10.0.2.15/24, no gateway) in the guest: nothing on the SLIRP side hands out a
# default route any more, and the guest's only peer is the retronet gateway
# 10.99.0.2, on-link via eth1. There is NO default route on either NIC.
# The SLIRP hostfwd publishes the guest's X server on a LOOPBACK-ONLY host port
# (127.0.0.1:6081 -> 10.0.2.15:6000) for the x11warp pointer backend: the daemon
# moves the pointer with XWarpPointer and reads it back with XQueryPointer
# (SH_X11WARP_DISPLAY=127.0.0.1:81). Access is granted in the golden by
# /etc/X0.hosts (10.0.2.2 only) — never `xhost +`. No default route leaves the
# guest beyond SLIRP; there is no retronet tap on this station (yet).
# SECOND NIC, added 2026-09-03: a BRIDGED tap (redhat62rn0 on vmbr-rn) that puts
# the guest on the retronet at 10.99.0.33/24 for the WEB and ICQ planes. OSCAR
# cannot traverse SLIRP, so the ICQ NIC has to be a real bridge port; the SLIRP
# NIC stays because it carries the ONLY path the x11warp pointer has (the amix
# precedent). eth1 is static with no default route; containment is armed by
# rn-tapnet.sh before QEMU opens the tap. docs/lab/retronet/STATION-redhat62.md.
# The qcow2 must carry the internal snapshot "golden"; launcher and disk are an
# atomic pair. Reset is HMP `loadvm golden`, never an in-guest channel.
set -euo pipefail

T=/data/vms/streamhost/stations/redhat62
DISK=/data/gallery-guests/RedHat62/redhat62.qcow2

if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  echo "redhat62: required qcow2 snapshot 'golden' is missing" >&2
  exit 1
fi

if [ -f "$T/qemu.pid" ]; then
  pid=$(cat "$T/qemu.pid")
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$T/qmp.sock" "$T/reset-hmp.sock" "$T/qemu.pid"

# Retronet link: create/enslave the vmbr-rn tap (redhat62rn0) + arm the guest-
# containment chain BEFORE QEMU opens it (script=no means QEMU attaches to an
# EXISTING tap, it does not create one). Idempotent, fail-closed: if containment
# does not verify this dies here and QEMU never starts.
bash "$T/rn-tapnet.sh" up

# Guest NIC MAC for the bridged tap. Real per-station MACs are NEVER committed
# (AGENTS.md rule 1); the real value lives in gitignored registry/local.env as
# RN_REDHAT62_MAC (retronet fleet scheme 52:54:00:52:4e:<last-IP-octet>,
# "52:4e"=RN, .33 -> ...21). The golden's vmstate carries the MAC, so this only
# matters on a COLD (re-)bake; loadvm golden uses the baked MAC regardless.
# Only the one line is read, never the whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_REDHAT62_MAC="02:00:00:00:00:21" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_REDHAT62_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_REDHAT62_MAC="$_m"
fi

export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-redhat62 \
  -nodefaults \
  -enable-kvm -machine pc-i440fx-11.0 -cpu host \
  -m 256 -smp 1 -rtc base=localtime \
  -drive file="$DISK",format=qcow2,if=ide,index=0 \
  -boot order=c -loadvm golden -S \
  -vga cirrus \
  -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:6081-10.0.2.15:6000 -device ne2k_pci,netdev=n0 \
  -netdev tap,id=n1,ifname=redhat62rn0,script=no,downscript=no -device ne2k_pci,netdev=n1,mac="$RN_REDHAT62_MAC" \
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
echo "tile redhat62 qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54181 x11warp=127.0.0.1:6081 retronet=10.99.0.33 (-loadvm golden)"
