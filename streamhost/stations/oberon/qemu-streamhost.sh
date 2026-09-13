#!/bin/bash
# Launch station 'oberon' (VMID 195) QEMU with the streamhost display wiring.
# ETH Oberon System 3 / PC Native 2.3.6 (13 May 1999) — Wirth/Gutknecht's
# tiling text-and-gadgets desktop, booted from disk.qcow2: the ready-installed
# Native Oberon 2.3.6 IDE image published by github.com/asig/native-oberon
# (raw, 83,886,080 bytes, MBR + one 0x4f Oberon partition, Gadgets desktop at
# 1280x1024 via the VESA 2.0 driver), converted to qcow2 by
# scripts/build-guests/tiles/oberon.sh. disk.qcow2 is the ONLY block device
# and carries the `golden` vmstate. Kill only by pidfile.
#
# Device set (golden + binary + devices are ONE combination — rule 6):
# pc-i440fx-11.0 acpi=off, KVM, -cpu host, 64 MB, 1 vCPU (a 1999 kernel; rule
# of thumb from the wall table: one vCPU first), -vga std (Bochs VBE 2.0 LFB,
# what Oberon's Display.VESA driver expects), IDE disk index 0, one empty
# 1.44 MB floppy (Oberon's Diskette driver probes the FDC at boot), PS/2
# keyboard + PS/2 mouse (RELATIVE; measured 1.5 px per unit, see the fixture),
# sb16 over the dbus audiodev (Oberon's Sound driver is SB16), ONE ne2k_pci
# NIC (the guest's NetNe2000pci driver — Native Oberon's own TCP/IP).
#
# NIC backend: the golden holds the ne2k_pci DEVICE, so the backend can be
# swapped without a re-bake. Until the retronet web plane is proven for this
# station (rule 15: rn-tapnet.sh ships only with a proven station) the backend
# is SLIRP `restrict=on` — no route to labhost or the world. When
# rn-tapnet.sh exists next to this file the NIC moves to the tap `oberonrn0`
# on the offline retronet bridge (10.99.0.42, no router option).
set -e
SDIR=/data/vms/streamhost/stations/oberon
B="$(dirname "$0")"
NETDEV="-netdev user,id=n0,restrict=on"
if [ -f "$B/rn-tapnet.sh" ]; then
  bash "$B/rn-tapnet.sh" up
  RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
  RN_OBERON_MAC="02:00:00:00:00:2a" # placeholder (committed); real value from local.env
  if [ -r "$RN_LOCAL_ENV" ]; then
    _m="$(sed -n 's/^RN_OBERON_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
    [ -n "$_m" ] && RN_OBERON_MAC="$_m"
  fi
  NETDEV="-netdev tap,id=n0,ifname=oberonrn0,script=no,downscript=no"
  NICMAC=",mac=$RN_OBERON_MAC"
fi
[ -f "$SDIR/qemu.pid" ] && kill "$(cat "$SDIR/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$SDIR/qmp.sock" "$SDIR/qemu.pid"
[ -f "$SDIR/floppy-empty.img" ] || dd if=/dev/zero of="$SDIR/floppy-empty.img" bs=1024 count=1440 status=none
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$SDIR/disk.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM / $NETDEV must word-split
nohup qemu-system-x86_64 \
  -name streamhost-oberon \
  -enable-kvm -m 64 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host \
  -rtc base=localtime \
  -drive file=$SDIR/disk.qcow2,format=qcow2,if=ide,index=0 \
  -drive file=$SDIR/floppy-empty.img,format=raw,if=floppy,index=0 \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  $NETDEV -device ne2k_pci,netdev=n0${NICMAC:-} \
  -qmp unix:$SDIR/qmp.sock,server=on,wait=off \
  -pidfile $SDIR/qemu.pid \
  >"$SDIR/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$SDIR/qmp.sock" ] && [ -f "$SDIR/qemu.pid" ] && break
  sleep 0.5
done
echo "station oberon qemu pid=$(cat $SDIR/qemu.pid 2>/dev/null) qmp=$SDIR/qmp.sock udp=54195"
