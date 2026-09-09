#!/bin/bash
# Launch station 'sculpt' (VMID 190): Genode Sculpt OS 25.04 under KVM.
# Device set (2026-09-09, sculpt wave, raced): q35, -cpu host, 4 GiB, 2 vCPUs,
# AHCI disk carrying the Sculpt image (GPT) + the 'golden' vmstate, an EHCI
# controller with a RELATIVE USB mouse and a USB keyboard, ONE guest NIC: the
# retronet tap (e1000 — Genode's PC NIC driver does not drive the rtl8139: bound, never transmitted). Genode's usb_hid never binds QEMU's absolute
# usb-tablet (on xHCI the sprite exists but never moves; on EHCI no sprite at
# all) and HMP mouse_move is dead — a six-runner race proved usb-mouse on EHCI
# is the pointer that moves nitpicker's sprite, so the station ships the
# daemon's rel bridge with readback (docs/lab/SCULPT-WAVE.md). No audio device:
# the default Sculpt scenario has no audio driver. Disk + launcher are ONE
# combination: the golden vmstate was baked on exactly this device set.
# Kill only by pidfile.
set -euo pipefail
T="${SCULPT_STATION_DIR:-/data/vms/streamhost/stations/sculpt}"
DISK="${SCULPT_DISK:-$T/disk.qcow2}"
if [ -z "${SCULPT_NO_GOLDEN:-}" ]; then
  if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
    echo "sculpt: required qcow2 snapshot 'golden' is missing in $DISK" >&2
    exit 1
  fi
  LOADVM=(-loadvm golden -S)
else
  LOADVM=()
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
# Retronet link: create/enslave the vmbr-rn tap and arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an EXISTING tap).
# Fail-closed under set -e: no containment, no guest.
bash "$(dirname "$0")/rn-tapnet.sh" up
# UNIQUE per-station MAC on vmbr-rn (retronet scheme 52:4e:<last IP octet>). The
# real value is box-local in gitignored registry/local.env RN_SCULPT_MAC; the
# committed fallback is a scrubbed placeholder. The MAC is ALSO in the golden's
# device vmstate, so this mac= must MATCH the one the golden was baked with.
RN_SCULPT_MAC="02:00:00:00:00:26" # placeholder (committed); real value from local.env
RN_LOCAL_ENV=/data/kernel-hive/registry/local.env
if [ -f "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^[[:space:]]*RN_SCULPT_MAC=//p' "$RN_LOCAL_ENV" | tail -1 | tr -d '\042\047')"
  [ -n "$_m" ] && RN_SCULPT_MAC="$_m"
fi
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name "streamhost-${SCULPT_NAME:-sculpt}" \
  -enable-kvm -machine pc-q35-11.0 -cpu host \
  -m 4096 -smp 2 -rtc base=localtime \
  -drive id=disk0,file="$DISK",format=qcow2,if=none \
  -device ahci,id=ahci0 -device ide-hd,drive=disk0,bus=ahci0.0 \
  -boot order=c \
  -vga std \
  -device usb-ehci,id=ehci0 -device usb-mouse,bus=ehci0.0 -device usb-kbd,bus=ehci0.0 \
  -netdev tap,id=rn0,ifname="${SCULPT_TAP:-sculptrn0}",script=no,downscript=no -device e1000,netdev=rn0,mac="$RN_SCULPT_MAC" \
  "${LOADVM[@]}" \
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
echo "tile sculpt qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54190 (Sculpt 25.04 on retronet 10.99.0.38 via tap ${SCULPT_TAP:-sculptrn0}; -loadvm golden)"
