#!/bin/bash
# Launch station 'pcbsd' (VMID 179) QEMU with the streamhost display wiring.
# PC-BSD 1.5.1 (FreeBSD 6.3-RELEASE + KDE 3.5.8, i386), installed from
# PCBSD1.5.1-x86-CD1.iso (archive.org, 688930816 bytes) onto disk.qcow2.
# disk.qcow2 is the ONLY block device and carries the `golden` vmstate
# (savevm golden at the clean KDE desktop). Kill only by pidfile.
# Device set (golden + binary + devices are ONE combination): pc-i440fx-11.0,
# KVM, -cpu host, 1024 MB, 1 vCPU, -vga std (X.org vesa 1024x768), IDE disk,
# AC97 over the dbus audiodev, PS/2 relative mouse (the usb-tablet is inert in
# FreeBSD 6.3 X, so it is NOT in the set); TWO e1000 NICs. No cdrom at runtime.
#
#   n0 / em0 — SLIRP, `restrict=on`, whose ONLY job is the loopback forward
#     127.0.0.1:6079 -> 10.0.2.15:6000: pointer MOTION is absolute through the
#     guest's own X server (SH_INPUT_BACKEND=x11warp, display :79; the golden
#     carries `xhost +10.0.2.2` and X listens on TCP). `restrict=on` cuts this
#     netdev off from labhost and from the outside world while still accepting
#     the hostfwd; without it QEMU user-net would hand the guest a working
#     default route out of the museum.
#   n1 / em1 — TAP `pcbsdrn0` on the OFFLINE retronet bridge vmbr-rn. The guest
#     DHCPs 10.99.0.29 with DNS 10.99.0.2 and NO router option, and browses the
#     corpus web (Konqueror, no proxy) and signs into the OSCAR gateway
#     (Kopete 0.12.7, UIN 17900). rn-tapnet.sh creates the tap and installs the
#     fail-closed PCBSDRN-IN guard chain on every launch.
#     See docs/lab/retronet/STATION-pcbsd.md.
set -e
SDIR=/data/vms/streamhost/stations/pcbsd
B="$(dirname "$0")"
X_PORT=6079
# Create/enslave the retronet tap and (re-)install the guest containment chain.
bash "$B/rn-tapnet.sh" up
# Per-station retronet MAC (fleet scheme 52:54:00:52:4e:xx). The golden's vmstate
# carries the MAC, so this only matters on a COLD (re-)bake; `loadvm golden` uses
# the baked MAC regardless, but this mac= must MATCH it. Real value box-local.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_PCBSD_MAC="02:00:00:00:00:1d" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_PCBSD_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_PCBSD_MAC="$_m"
fi
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
  -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:${X_PORT}-10.0.2.15:6000 -device e1000,netdev=n0 \
  -netdev tap,id=n1,ifname=pcbsdrn0,script=no,downscript=no -device e1000,netdev=n1,mac="$RN_PCBSD_MAC" \
  -qmp unix:$SDIR/qmp.sock,server=on,wait=off \
  -pidfile $SDIR/qemu.pid \
  >"$SDIR/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$SDIR/qmp.sock" ] && [ -f "$SDIR/qemu.pid" ] && break
  sleep 0.5
done
echo "station pcbsd qemu pid=$(cat $SDIR/qemu.pid 2>/dev/null) qmp=$SDIR/qmp.sock udp=54179 x11=127.0.0.1:${X_PORT} rn=10.99.0.29"
