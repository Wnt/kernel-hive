#!/bin/bash
# Launch tile 'win311' (VMID 90) QEMU with the streamhost display wiring.
# Kill only by pidfile. This REPLACES the neko capture for this one tile during
# its pilot; neko is restored by ROLLBACK.md.
#
# GOLDEN FIXTURE MODE: boots the persistent golden qcow2 disks (NO -snapshot) so
# QMP savevm/loadvm can create/restore the live "golden" reset point.
# resetMode=loadvm  (see GOLDEN.md). Disks are standalone qcow2 (no backing dep).
set -e
D=/data/vms/streamhost/stations/win311
B="$(dirname "$0")"
# NETWORK: on the retronet. Same ne2k_pci (RTL8029) NIC the golden always had —
# only the backend went user(slirp) -> tap on the retronet bridge vmbr-rn, plus
# a per-station mac=. The guest runs MS TCP/IP-32 over the RTL8029 NDIS3 driver
# and DHCPs 10.99.0.27 from the gateway CT 10.99.0.2 (reservation withholds the
# router option, so it has NO default route). rn-tapnet.sh is called `up` below
# on every launch and owns the tap + the fail-closed WIN311RN-IN guard chain.
# Nothing else rides this netdev — the warpd pointer agent is on COM1. See
# docs/lab/retronet/WEB-STATION-win311.md.
bash "$B/rn-tapnet.sh" up
# Per-station retronet MAC (fleet scheme 52:54:00:52:4e:xx). The golden's
# vmstate carries the MAC, so this only matters on a COLD (re-)bake; loadvm
# golden uses the baked MAC regardless, but this mac= must MATCH it. Only the
# one line is read, never the whole (secret-bearing) file.
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
RN_WIN311_MAC="02:00:00:00:00:1b" # placeholder (committed); real value from local.env
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_WIN311_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && RN_WIN311_MAC="$_m"
fi
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l "$D/win311-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# Patched SeaBIOS: INT 16h "check keystroke" returns IF=1 like the IBM AT BIOS.
# Stock SeaBIOS hands DOS POWER.EXE's INT 16h chain IF=0 back, WfW's VMM copies
# that into the System VM and the guest runs with interrupts disabled until reset
# (docs/lab/win311-interrupts-disabled-freeze.md). Built by
# scripts/provision/build-seabios-int16if.sh. ROM bytes live in the vmstate, so
# the golden MUST be re-baked from a cold boot whenever this file changes.
BIOS=/data/vms/streamhost/firmware/bios-256k-int16if.bin
[ -s "$BIOS" ] || {
  echo "win311: missing $BIOS — run scripts/provision/build-seabios-int16if.sh" >&2
  exit 1
}
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-i386 \
  -name streamhost-win311 \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium \
  -bios $BIOS \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  \
  -drive file=$D/win311-golden.qcow2,format=qcow2,if=ide -drive file=$D/games-golden.qcow2,format=qcow2,if=ide,index=1 -netdev tap,id=n0,ifname=win311rn0,script=no,downscript=no -device ne2k_pci,netdev=n0,mac="$RN_WIN311_MAC" \
  -chardev socket,id=ser0,path=$D/serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win311 qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54090 (golden, no -snapshot)"
