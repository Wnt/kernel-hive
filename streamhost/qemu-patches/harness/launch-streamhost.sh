#!/bin/bash
# launch-streamhost.sh — run a streamhost daemon for the FreeDOS clone with
# SH_CAP_TRACE=1 (per-2s capstat cadence). Own UDP port 54200. Logs to sh.log.
set -eu
D=/data/vms/sandbox/freedos-fastpoll
BIN=/data/vms/streamhost/build/target/release/streamhost
if [ -f "$D/sh.pid" ]; then kill "$(cat "$D/sh.pid")" 2>/dev/null || true; fi
sleep 0.3
env SH_STATION=fastpoll SH_QMP="$D/qmp.sock" SH_PORT=54200 \
  SH_POINTER=rel SH_AUDIO=off SH_FPS=240 \
  SH_HOST_IP=192.0.2.10 SH_ADVERTISE_HOST=192.0.2.10 \
  SH_HASH_FILE="$D/cert_hash_b64.txt" SH_SIGNALING_JSON="$D/signaling.json" \
  SH_CAP_TRACE=1 \
  nohup "$BIN" >"$D/sh.log" 2>&1 &
echo $! >"$D/sh.pid"
sleep 2
echo "streamhost pid=$(cat "$D/sh.pid") port=54200"
tail -3 "$D/sh.log"
