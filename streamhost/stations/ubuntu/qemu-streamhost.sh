#!/bin/bash
# Launch station 'ubuntu' (VMID 183): Ubuntu 4.10 Warty Warthog LIVE CD under
# KVM. The CD is the OS; ubuntu.qcow2 is an otherwise empty 1G disk that only
# carries the 'golden' vmstate. ISO + qcow2 + this device set are ONE combination.
# Device set measured 2026-09-03: acpi=off and NO audio device — AC97 with ACPI
# on hangs the 2.6.8 live boot at the usplash bar. -nodefaults means the ONLY
# guest NIC is the explicit retronet one below (2026-09-03: the station joined
# the retronet web + ICQ planes, docs/lab/retronet/STATION-ubuntu.md).
set -euo pipefail
T=/data/vms/streamhost/stations/ubuntu
DISK=/data/gallery-guests/Ubuntu/ubuntu.qcow2
ISO=/data/gallery-guests/Ubuntu/warty-release-live-i386.iso
if ! qemu-img snapshot -l "$DISK" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]+golden[[:space:]]'; then
  echo "ubuntu: required qcow2 snapshot 'golden' is missing" >&2
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
# Retronet link: create/enslave the vmbr-rn tap and arm the guest-containment
# chain BEFORE QEMU opens it (script=no means QEMU attaches to an EXISTING tap,
# it does not create one). Idempotent; fail-closed under `set -e` — if it cannot
# verify containment it exits non-zero and QEMU never starts.
bash "$T/rn-tapnet.sh" up
# UNIQUE per-station MAC on vmbr-rn (retronet scheme 52:4e:<last IP octet>). The
# real value is box-local in gitignored registry/local.env RN_UBUNTU_MAC; the
# committed fallback below is a scrubbed placeholder. The MAC is ALSO baked into
# the golden's device vmstate — `loadvm golden` restores THAT regardless of this
# mac=, so the golden was cold re-baked with it and this mac= must MATCH.
RN_UBUNTU_MAC="02:00:00:00:00:1e" # placeholder (committed); real value from local.env
RN_LOCAL_ENV=/data/kernel-hive/registry/local.env
if [ -f "$RN_LOCAL_ENV" ]; then
  _m="$(sed -n 's/^[[:space:]]*RN_UBUNTU_MAC=//p' "$RN_LOCAL_ENV" | tail -1 | tr -d '\042\047')"
  [ -n "$_m" ] && RN_UBUNTU_MAC="$_m"
fi
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-ubuntu \
  -nodefaults \
  -enable-kvm -machine pc-i440fx-11.0,acpi=off -cpu host \
  -m 512 -smp 1 -rtc base=localtime \
  -drive file="$DISK",format=qcow2,if=ide,index=0 \
  -drive file="$ISO",format=raw,if=ide,index=2,media=cdrom,readonly=on \
  -boot order=d -loadvm golden -S \
  -vga std \
  -usb -device usb-tablet \
  -netdev tap,id=n0,ifname=ubunturn0,script=no,downscript=no -device rtl8139,netdev=n0,mac="$RN_UBUNTU_MAC" \
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
echo "tile ubuntu qemu pid=$(cat "$T/qemu.pid") qmp=$T/qmp.sock reset-hmp=$T/reset-hmp.sock udp=54183 (live CD on retronet 10.99.0.30 via tap ubunturn0; -loadvm golden)"
