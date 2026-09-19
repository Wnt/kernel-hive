#!/bin/bash
# DRAFT qemu-streamhost launcher for early Mac OS X.
set -euo pipefail
D="${D:-/data/vms/streamhost/stations/macosx}"
QEMU="${QEMU:-/opt/qemu-ppc/bin/qemu-system-ppc}"
DISK="${DISK:-$D/macosx-golden.qcow2}"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep .3; rm -f "$D/qmp.sock" "$D/qemu.pid"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=(); qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden && LOADVM=(-loadvm golden -S)
nohup "$QEMU" -name streamhost-macosx -accel tcg -m 512   -M mac99,via=pmu -cpu g4 -g 1024x768x32   -display dbus,p2p=on -nic none   -drive file="$DISK",format=qcow2,cache=writeback,aio=threads   "${LOADVM[@]}" -qmp unix:"$D/qmp.sock",server=on,wait=off   -pidfile "$D/qemu.pid" >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do [ -S "$D/qmp.sock" ] && break; sleep .5; done
[ -S "$D/qmp.sock" ]
# MEASURE: built-in PMU HID sufficiency, pointer scale, and NIC/device set before final golden.
