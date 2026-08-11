#!/usr/bin/env bash
# verify-prodclone.sh — boot a candidate MAME binary under the EXACT production
# station configuration, in a clone, and screendump it on a fixed schedule.
#
#   verify-prodclone.sh <binary> <outdir> <cpus> [dump-seconds ...]
#
# This is a CORRECTNESS check, not a speed measurement: same launcher, same
# station.env values, same golden, both watchdogs armed, and THROTTLED exactly as
# shipped. Use `irixbench.sh` for speed.
#
# It exists because a binary can be green in the bench rig and broken on the
# exhibit. The fastram build was: correct and ~9% faster in the rig, and it
# stopped IRIX at its own memory diagnostic under the station's full flag set. The
# only thing that catches that is the production configuration, end to end, read
# off the framebuffer.
#
# The live `streamhost@irix` service stays stopped throughout. This copies the
# station's launcher, agent and env into a namespaced dir and runs it there —
# x11-runtime.sh derives its runtime dir from its own location, so the copy
# never writes into /data/vms/streamhost.
set -u

BIN="${1:?binary}"
V="${2:?outdir}"
CPUS="${3:?cpus}"
shift 3
DUMPS=("$@")
[ ${#DUMPS[@]} -gt 0 ] || DUMPS=(180 300 420 540 660)

T="${IRIX_TILE_DIR:-/data/vms/streamhost/stations/irix}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
RIG="$(cd -- "$(dirname -- "$0")" && pwd)"

case "$V" in
  /data/vms/soltest/*) : ;;
  *)
    echo "refusing to work outside /data/vms/soltest" >&2
    exit 1
    ;;
esac
# A stale MAME from a previous attempt keeps writing the SAME fb.shm and makes
# every screendump a lie about which binary drew it. Refuse to start on top of
# one rather than produce ambiguous evidence.
if pgrep -f "$V/disk.chd" >/dev/null; then
  echo "FATAL: something is still running on $V/disk.chd" >&2
  exit 1
fi

rm -rf "$V"
mkdir -p "$V"
cp "$T/x11-runtime.sh" "$T/irixagent.lua" "$T/fbstat.py" "$T/tapnet.sh" "$V/"
# Refuse a launcher that would reach into the live station tree.
"$CG" check-launcher "$V/x11-runtime.sh" || exit 1
md5sum "$BIN" >"$V/binary.md5"

(
  # station.env is a systemd EnvironmentFile, NOT a shell script: values are
  # unquoted and SH_FIXTURE_DESC contains spaces and parentheses, so sourcing it
  # is a syntax error. Read it the way systemd does — split on the first `=` and
  # take the rest of the line verbatim.
  while IFS= read -r line; do
    case "$line" in '#'* | '') continue ;; esac
    export "${line%%=*}=${line#*=}"
  done <"$T/station.env"
  export IRIX_MAME="$BIN" IRIX_CPUS="$CPUS" IRIX_WATCH_UNIT=""
  # One-variable departures from the station's own env, for bisecting a
  # production-only failure (e.g. IRIX_NET_OVERRIDE=off to take the tap and the
  # machine cfg out of the picture).
  [ -n "${IRIX_NET_OVERRIDE:-}" ] && export IRIX_NET="$IRIX_NET_OVERRIDE"
  export SH_SHM_PATH="$V/fb.shm" SH_X11_CMD_FILE="$V/irix_cmd"
  bash "$V/x11-runtime.sh" >"$V/launch.log" 2>&1
)
echo "launched $BIN; mame.pid=$(cat "$V/mame.pid" 2>/dev/null)"

prev=0
for t in "${DUMPS[@]}"; do
  sleep $((t - prev))
  prev=$t
  printf 't=%ss ' "$t"
  python3 "$RIG/shmpng.py" "$V/fb.shm" "$V/shot-t$t.png" || echo "no frame"
done

# Teardown is part of "done": the emulator goes through clone-guard by pidfile
# and BOTH watchdogs are killed, so nothing survives to relaunch it.
"$CG" kill-pidfile "$V/mame.pid"
for w in bootwatch livewatch; do
  [ -f "$V/$w.pid" ] && kill "$(cat "$V/$w.pid")" 2>/dev/null
done
sleep 2
if pgrep -f "$V/disk.chd" >/dev/null; then
  echo "WARNING: MAME survived the stop" >&2
  exit 1
fi
echo "stopped, clean"
