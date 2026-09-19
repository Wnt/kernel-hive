#!/bin/bash
# DRAFT shared inner runtime for terminal-fronted host emulators.
#
# Intended users: mvs38, multics, vax43bsd, its.
# This is a PRE-LAB reference, not a proven production launcher.
#
# Required environment:
#   KH_TERM_DISPLAY=:N
#   KH_TERM_EMULATOR_CMD='command ...'   # starts the hidden emulator/service
#   KH_TERM_READY_PORT=N                 # localhost TCP port proving visitor service ready
#   KH_TERM_CLIENT_CMD='command ...'     # x3270 or xterm/telnet; exec'd as visitor surface
# Optional:
#   KH_TERM_GEOM=1024x768
#   KH_TERM_READY_TIMEOUT_S=300
#
# Contract:
#   * Xvfb is the only published graphics surface.
#   * Emulator/operator console goes to a logfile and is never shown.
#   * The visitor client starts only after a real port probe succeeds.
#   * If the hidden emulator exits, launch fails loudly.
#   * Station-specific reset must copy pristine mutable media BEFORE invoking this file.
set -euo pipefail

DISP="${KH_TERM_DISPLAY:?KH_TERM_DISPLAY required}"
GEOM="${KH_TERM_GEOM:-1024x768}"
EMU_CMD="${KH_TERM_EMULATOR_CMD:?KH_TERM_EMULATOR_CMD required}"
READY_PORT="${KH_TERM_READY_PORT:?KH_TERM_READY_PORT required}"
CLIENT_CMD="${KH_TERM_CLIENT_CMD:?KH_TERM_CLIENT_CMD required}"
TIMEOUT="${KH_TERM_READY_TIMEOUT_S:-300}"
WORK="${KH_TERM_WORK:-/work}"
N="${DISP#:}"

mkdir -p "$WORK" /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X$N"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac   >"$WORK/xvfb.log" 2>&1 &
XPID=$!
trap 'kill -TERM "$EPID" "$XPID" 2>/dev/null || true' EXIT TERM INT

for _ in $(seq 1 120); do
  [ -S "/tmp/.X11-unix/X$N" ] && break
  kill -0 "$XPID" 2>/dev/null || { cat "$WORK/xvfb.log"; exit 1; }
  sleep .25
done
[ -S "/tmp/.X11-unix/X$N" ] || { echo "no X socket" >&2; exit 1; }

export DISPLAY="$DISP"

# Operator-controlled command from a committed station fixture; shell form is
# deliberate because Hercules/DPS8M/SIMH startup often needs cd/env/redirection.
bash -lc "exec $EMU_CMD" >"$WORK/emulator.log" 2>&1 &
EPID=$!

deadline=$(( $(date +%s) + TIMEOUT ))
while ! nc -z 127.0.0.1 "$READY_PORT" 2>/dev/null; do
  kill -0 "$EPID" 2>/dev/null || {
    echo "hidden emulator exited before terminal became ready" >&2
    tail -100 "$WORK/emulator.log" >&2 || true
    exit 1
  }
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "terminal port $READY_PORT not ready after ${TIMEOUT}s" >&2
    tail -100 "$WORK/emulator.log" >&2 || true
    exit 1
  }
  sleep .5
done

# Client becomes PID 1-ish payload for the station container; its X window is
# the museum surface. No host/operator console is ever mapped into the capture.
exec bash -lc "$CLIENT_CMD"
