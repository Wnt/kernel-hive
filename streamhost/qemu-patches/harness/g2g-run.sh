#!/bin/bash
# g2g-run.sh <label> <ntrials> — keystroke glass-to-glass (inject->wire) for one
# config. Env: QEMU_BIN, SH_DBUS_UPDATE_MS (unset = stock 30ms). Fresh boot.
set -eu
D=/data/vms/soltest/freedos-fastpoll
Q="$D/qmp.sock"
LABEL="$1"
NT="${2:-40}"
W="/tmp/g2g_$LABEL"
rm -rf "$W"
mkdir -p "$W"
kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
kill "$(cat "$D/sh.pid")" 2>/dev/null || true
sleep 1
rm -f "$D/overlay.qcow2" "$D/qmp.sock" "$D/qemu.pid"
qemu-img create -f qcow2 -b /data/gallery-guests/FreeDOS/freedos.qcow2 \
  -F qcow2 "$D/overlay.qcow2" >/dev/null
"$D/launch-qemu.sh" >/dev/null
sleep 14
drive() {
  python3 /root/cdrv.py "$Q" "$@" >/dev/null 2>&1
  sleep 0.5
}
drive key c
drive sh "cls"
"$D/launch-streamhost.sh" >/dev/null 2>&1
sleep 3
DUR="$(awk "BEGIN{print $NT*0.28+8}")"
"$D/wtenv/bin/python" "$D/wt_probe.py" 192.0.2.10 54200 "$DUR" \
  "$W/probe.csv" >"$W/probe.out" 2>&1 &
PP=$!
sleep 3
python3 "$D/g2g_key_inject.py" "$Q" "$NT" 0.25 >"$W/inject.log" 2>&1
wait "$PP"
echo "===== G2G label=$LABEL SH_DBUS_UPDATE_MS=${SH_DBUS_UPDATE_MS:-<unset/30ms>} ntrials=$NT ====="
grep -E "AUS_RECORDED" "$W/probe.out"
"$D/wtenv/bin/python" "$D/g2g_key_detect.py" "$W/probe.csv" "$W/inject.log" "$W" \
  2>/dev/null | grep -E "trials=|G2G|samples_ms"
