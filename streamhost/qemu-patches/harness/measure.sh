#!/bin/bash
# measure.sh <label> — one capture-cadence run.
# Env in: QEMU_BIN (default patched), SH_DBUS_UPDATE_MS (unset = stock 30ms).
# Boots a FRESH overlay, drops to FreeCom, runs an infinite text-scroll
# (continuous full-screen change > any poll rate), starts streamhost with
# SH_CAP_TRACE, and reports the QEMU poll-tick rate ([dbus_poll], patched binary
# only) + streamhost capstat over a ~12s window.
set -eu
D=/data/vms/sandbox/freedos-fastpoll
LABEL="$1"
Q="$D/qmp.sock"
kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
kill "$(cat "$D/sh.pid")" 2>/dev/null || true
sleep 1
rm -f "$D/overlay.qcow2" "$D/qmp.sock" "$D/qemu.pid"
qemu-img create -f qcow2 -b /data/gallery-guests/FreeDOS/freedos.qcow2 \
  -F qcow2 "$D/overlay.qcow2" >/dev/null
export SH_DBUS_TRACE=1
"$D/launch-qemu.sh" >/dev/null
sleep 14
drive() {
  python3 /root/cdrv.py "$Q" "$@" >/dev/null 2>&1
  sleep 0.5
}
drive key c
drive sh "copy con l.bat"
drive sh ":a"
drive sh "type fdauto.bat"
drive sh "goto a"
drive key f6
drive key ret
sleep 1
python3 /root/cdrv.py "$Q" sh "l.bat" >/dev/null 2>&1
sleep 2
"$D/launch-streamhost.sh" >/dev/null 2>&1
sleep 12
echo "===== RESULT label=$LABEL QEMU_BIN=${QEMU_BIN:-patched} SH_DBUS_UPDATE_MS=${SH_DBUS_UPDATE_MS:-<unset/30ms>} ====="
echo "--- QEMU poll-tick rate (dbus_refresh, one per poll) ---"
grep "\[dbus_poll\]" "$D/qemu.log" | tail -4 || echo "(no counter: stock binary)"
echo "--- streamhost capstat (map_update = damage rects/2s) ---"
grep "capstat" "$D/sh.log" | tail -4
