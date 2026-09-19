#!/bin/bash
# DRAFT qemu launcher for Linux 0.12. Text-only, no pointer/network/audio.
set -euo pipefail
D="${D:-/data/vms/streamhost/stations/linux012}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/linux012}"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep .2; rm -f "$D/qmp.sock" "$D/qemu.pid"
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-i386 -name streamhost-linux012 -accel tcg -m 4M -smp 1   -machine pc-i440fx-11.0,acpi=off -boot a -vga std -display dbus,p2p=on   -drive file="$ASSETS/boot.img",format=raw,if=floppy,index=0,readonly=on   -drive file="$ASSETS/root.img",format=raw,if=floppy,index=1,readonly=on   -qmp unix:"$D/qmp.sock",server=on,wait=off -pidfile "$D/qemu.pid"   >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do [ -S "$D/qmp.sock" ] && break; sleep .25; done
[ -S "$D/qmp.sock" ]
# If the root floppy must be writable, copy it to $D/root-work.img at launch; never mutate the seed.
