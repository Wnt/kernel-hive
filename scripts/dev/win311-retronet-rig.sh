#!/bin/bash
# win311-retronet-rig.sh — boot the win311 retronet bring-up clone.
#
# Same DEVICE SET as the live win311 station (loadvm golden requires it): TCG,
# -cpu pentium, pc-i440fx-11.0, the patched INT16h SeaBIOS (the freeze fix —
# docs/lab/win311-interrupts-disabled-freeze.md; cold boots MUST use it or the
# recapture silently loses the fix), -vga std, sb16, two IDE qcow2 disks, the
# COM1 warpd chardev on the default serial0, and one ne2k_pci on the retronet
# tap. Only the -display/-audiodev BACKENDS differ from production (none/none
# here vs dbus there); those are UI backends, not devices, so the device set
# matches and a golden baked here restores on the live launcher.
#
# The MAC is read from the same gitignored registry/local.env line the launcher
# uses, so the rig leases the station's reserved 10.99.0.27. Only one guest may
# hold the tap+lease at a time — while the LIVE station still runs slirp this
# rig can run beside it; once the tap launcher is deployed, stop the station
# first.
#
# Pass no args for a golden-restoring boot (when the rig disk has one), or
# COLD=1 for a forced cold boot (bakes the MAC + DHCP lease into the new golden).
set -euo pipefail
R="${RIG_DIR:-/data/vms/sandbox/win311-rn/rig}"
RN_LOCAL_ENV="${RN_LOCAL_ENV:-/data/kernel-hive/registry/local.env}"
MAC="02:00:00:00:00:1b"
if [ -r "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^RN_WIN311_MAC=//p' "$RN_LOCAL_ENV" | head -1)"
  [ -n "$_m" ] && MAC="$_m"
fi
BIOS=/data/vms/streamhost/firmware/bios-256k-int16if.bin
[ -s "$BIOS" ] || {
  echo "rig: missing $BIOS (the INT16h freeze fix) — refusing to cold-boot without it" >&2
  exit 1
}
bash /data/vms/sandbox/win311-rn/repo/streamhost/stations/win311/rn-tapnet.sh up
LOADVM=""
if [ "${COLD:-0}" != 1 ]; then
  qemu-img snapshot -l "$R/win311-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
fi
rm -f "$R/qmp.sock" "$R/serial.sock" "$R/qemu.pid"
# shellcheck disable=SC2086 # $LOADVM must word-split (or vanish on a cold boot)
nohup qemu-system-i386 \
  -name streamhost-win311-rig \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium \
  -bios "$BIOS" \
  -rtc base=localtime \
  -boot c \
  $LOADVM \
  -vga std \
  -display none \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -drive file="$R/win311-golden.qcow2",format=qcow2,if=ide -drive file="$R/games-golden.qcow2",format=qcow2,if=ide,index=1 -netdev tap,id=n0,ifname=win311rn0,script=no,downscript=no -device ne2k_pci,netdev=n0,mac="$MAC" \
  -chardev socket,id=ser0,path="$R/serial.sock",server=on,wait=off \
  -serial chardev:ser0 \
  -qmp unix:"$R/qmp.sock",server=on,wait=off \
  -pidfile "$R/qemu.pid" \
  >"$R/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$R/qmp.sock" ] && [ -f "$R/qemu.pid" ] && break
  sleep 0.5
done
echo "rig pid=$(cat "$R/qemu.pid" 2>/dev/null) mac=${MAC//[0-9a-f]/x} qmp=$R/qmp.sock loadvm='${LOADVM:-<cold>}'"
