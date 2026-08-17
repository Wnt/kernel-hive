#!/bin/bash
# launch-qemu.sh — cold-boot the FreeDOS capture-latency clone.
# Env: QEMU_BIN (default = patched build), SH_DBUS_UPDATE_MS (unset = stock 30ms),
# SH_DBUS_TRACE (1 = print poll-tick rate). Isolated: own overlay disk, qmp.sock,
# pidfile. Kill ONLY by pidfile. Device set mirrors the live freedos tile minus
# audio (audio irrelevant to capture latency). NEVER point this at a fleet tile.
set -eu
D=/data/vms/sandbox/freedos-fastpoll
QEMU_BIN="${QEMU_BIN:-$D/../qemu-fastpoll/qemu-11.0.0/build/qemu-system-x86_64}"
if [ -f "$D/qemu.pid" ]; then kill "$(cat "$D/qemu.pid")" 2>/dev/null || true; fi
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
echo "launch QEMU_BIN=$QEMU_BIN SH_DBUS_UPDATE_MS=${SH_DBUS_UPDATE_MS:-<unset/stock>}"
nohup env SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-}" SH_DBUS_TRACE="${SH_DBUS_TRACE:-}" \
  "$QEMU_BIN" \
  -name fastpoll-freedos \
  -enable-kvm -m 64 -smp 2 \
  -machine pc,acpi=off -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga cirrus \
  -display dbus,p2p=on \
  -drive file="$D/overlay.qcow2",format=qcow2,if=ide \
  -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -qmp unix:"$D/qmp.sock",server=on,wait=off \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock"
