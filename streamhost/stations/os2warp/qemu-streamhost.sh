#!/bin/bash
# Launch tile 'os2warp' (VMID 108) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
# DISPLAY: 1024x768x64k via IBM GENGRADD on -vga std. vgamem_mb=2 is LOAD-BEARING:
# GENPMI's mode buffers hold 64 VESA modes and SeaVGABIOS reports 93 at the 16 MB
# default, overflowing them (trap c0000005 at display init). 2 MB -> 46 modes.
# POINTER: in-guest warpd agent (C:\WARPD.EXE, PM WinSetPointerPos) over COM1, a
# device-set-safe unix-socket serial chardev on the default serial0. The golden
# RAM snapshot is baked with WARPD.EXE already running, and we boot straight into
# it (-loadvm golden) so absolute cursor tracking is live from first frame and the
# OS/2 register nag never reappears. station.env: SH_POINTER=warpd + SH_WARPD_ADDR.
# NETWORK: on the retronet. The pcnet -device is UNCHANGED (the device set must
# match the golden bake); only the netdev backend went user(slirp) -> tap on the
# retronet bridge vmbr-rn, plus a per-station mac=. The guest runs IBM MPTS/NDIS +
# TCP/IP 4.3 and DHCPs 10.99.0.19 from the gateway CT 10.99.0.2 (reservation
# withholds the router option, so it has NO default route). rn-tapnet.sh is called
# `up` below on every launch and owns the tap + the fail-closed OS2RN-IN guard
# chain. Nothing else rides this netdev — warpd is on COM1. See
# docs/lab/retronet/WEB-STATION-os2warp.md.
set -e
D=/data/vms/streamhost/stations/os2warp
DISK=/data/gallery-guests/OS2Warp/os2.qcow2
B="$(dirname "$0")"
# The retronet tap + its fail-closed guard chain. Idempotent, and re-asserted on
# EVERY launch so a station relaunch or a host reboot cannot leave the guest on
# the bridge with no containment.
bash "$B/rn-tapnet.sh" up
# Per-station retronet MAC. Unique per station (fleet scheme 52:54:00:52:4e:xx);
# the golden's vmstate carries the MAC, so this only matters on a COLD (re-)bake;
# loadvm golden uses the baked MAC regardless, but this mac= must MATCH it (cold
# boot vs loadvm bind to the same device). Only the one line is read, never the
# whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_OS2WARP_MAC="02:00:00:00:00:13" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_OS2WARP_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_OS2WARP_MAC="$_m"
fi
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# Boot straight into the golden RAM snapshot (clean desktop + WARPD.EXE running)
# when it exists; device set must match the bake exactly (adds nothing, reuses
# the default serial0). First-ever bake has no snapshot -> cold boot.
LOADVM=""
qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-os2warp \
  -accel tcg -m 256 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,usb=off -cpu pentium \
  -rtc base=localtime \
  -boot c \
  -vga std -global VGA.vgamem_mb=2 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -chardev socket,id=ser0,path=$D/serial.sock,server=on,wait=off -serial chardev:ser0 \
  -drive file=$DISK,format=qcow2,if=ide -netdev tap,id=n0,ifname=os2rn0,script=no,downscript=no -device pcnet,netdev=n0,mac="$RN_OS2WARP_MAC" \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile os2warp qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock ser=$D/serial.sock loadvm='${LOADVM:-<cold>}' udp=54108"
