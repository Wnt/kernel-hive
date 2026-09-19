#!/bin/bash
# DRAFT QEMU launcher for converted webOS SDK image. Defaults are provisional until OVF inventory is copied here.
set -euo pipefail
D="${D:-/data/vms/streamhost/stations/webos}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/webos}"
DISK="${DISK:-$D/webos-golden.qcow2}"
MEM_MB="${WEBOS_MEM_MB:-1024}"
MACHINE="${WEBOS_MACHINE:-pc-i440fx-11.0}"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep .2; rm -f "$D/qmp.sock" "$D/qemu.pid"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=(); qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM=(-loadvm golden -S)
read -r -a NIC <<<"${WEBOS_NIC_ARGS:-}"
read -r -a EXTRA <<<"${WEBOS_EXTRA_ARGS:-}"
nohup qemu-system-i386 -name streamhost-webos -enable-kvm -m "$MEM_MB"   -machine "$MACHINE" -vga std -display dbus,p2p=on -usb -device usb-tablet   -drive file="$DISK",format=qcow2,if=ide "${NIC[@]}" "${EXTRA[@]}" "${LOADVM[@]}"   -qmp unix:"$D/qmp.sock",server=on,wait=off -pidfile "$D/qemu.pid" >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 60); do [ -S "$D/qmp.sock" ] && break; sleep .5; done
[ -S "$D/qmp.sock" ]
# REPLACE defaults with OVF-measured hardware before baking golden.
