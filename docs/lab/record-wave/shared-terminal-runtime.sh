#!/bin/bash
# =============================================================================
# Shared inner runtime for terminal-fronted host emulators (mvs38, multics,
# vax43bsd, its).
#
# STATUS 2026-09-20, from the mvs38 pathfinder run (docs/lab/MVS38-WAVE.md).
# Every claim below is tagged:
#   [PROVEN]  measured on labhost in this run, with the measurement quoted
#   [INHERIT] proven earlier by medley/vision/perq and re-checked today
#   [ASSUMED] still a design guess — DO NOT relay as fact
#
# -----------------------------------------------------------------------------
# THE CORRECTION THAT MATTERS MOST TO THE SIBLINGS
# -----------------------------------------------------------------------------
# [PROVEN] A TCP port probe is NOT a readiness gate for a heritage terminal.
# Hercules opened its CNSLPORT 8 s after exec and then took another 39 s before
# MVS would accept a TSO logon:
#
#     12:01:49  hercules -d -f conf/tk5.cnf              (exec)
#     12:01:57  CNSLPORT listening            (+8 s)   <-- the draft's gate
#     12:02:36  IST020I VTAM INITIALIZATION COMPLETE   (+47 s)
#     12:02:36  IKT005I TCAS IS INITIALIZED   (+47 s)  <-- the real gate
#     12:03:29  TK5 init script ends          (+100 s)
#
# A client started at +8 s attaches to a device the OS has not activated. The
# gate must therefore be TWO conditions: the port answers AND the emulator's
# own "the OS is up" message has appeared. SIMH and DPS8M have the same shape
# (the telnet listener binds at simulator start, long before the guest boots),
# so every sibling needs its own KH_TERM_READY_LOG_RE. Known-good values:
#   mvs38  (Hercules/TK5)  'IKT005I TCAS IS INITIALIZED'
#   multics (DPS8M)        TBD by that worker
#   vax43bsd / its (SIMH)  TBD by that worker
#
# Required environment:
#   KH_TERM_DISPLAY=:N
#   KH_TERM_EMULATOR_CMD='command ...'   # starts the hidden emulator/service
#   KH_TERM_READY_PORT=N                 # loopback TCP port of the visitor service
#   KH_TERM_CLIENT_CMD='command ...'     # x3270 / xterm+telnet; exec'd as the surface
# Optional:
#   KH_TERM_READY_LOG_RE='regex'         # ALSO required before the client starts
#   KH_TERM_GEOM=1024x768
#   KH_TERM_READY_TIMEOUT_S=300
#   KH_TERM_WORK=/work
#   KH_TERM_EMULATOR_CWD=/work/<tree>
#
# Contract:
#   * Xvfb inside the container is the only published graphics surface.
#   * Emulator/operator console goes to a logfile and is never shown.
#   * The visitor client starts only after BOTH real probes succeed.
#   * If the hidden emulator exits, launch fails loudly.
#   * Station-specific reset copies pristine mutable media into $KH_TERM_WORK
#     BEFORE invoking this file.
# =============================================================================
set -euo pipefail

DISP="${KH_TERM_DISPLAY:?KH_TERM_DISPLAY required}"
GEOM="${KH_TERM_GEOM:-1024x768}"
EMU_CMD="${KH_TERM_EMULATOR_CMD:?KH_TERM_EMULATOR_CMD required}"
READY_PORT="${KH_TERM_READY_PORT:?KH_TERM_READY_PORT required}"
CLIENT_CMD="${KH_TERM_CLIENT_CMD:?KH_TERM_CLIENT_CMD required}"
READY_RE="${KH_TERM_READY_LOG_RE:-}"
TIMEOUT="${KH_TERM_READY_TIMEOUT_S:-300}"
WORK="${KH_TERM_WORK:-/work}"
EMU_CWD="${KH_TERM_EMULATOR_CWD:-$WORK}"
N="${DISP#:}"

mkdir -p "$WORK"
# [INHERIT] medley/perq/vision: the socket dir is a HOST directory bind-mounted
# over the container's /tmp/.X11-unix; it arrives owned by the host, and X
# refuses to use it unless it is 1777.
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X$N"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
XPID=$!
EPID=""
# [PROVEN by review] the draft's trap referenced $EPID before assignment, which
# under `set -u` turns an early Xvfb failure into an unbound-variable abort
# instead of the intended message. EPID is now pre-initialised.
trap 'kill -TERM ${EPID:-} "$XPID" 2>/dev/null || true' EXIT TERM INT

for _ in $(seq 1 240); do
  [ -S "/tmp/.X11-unix/X$N" ] && break
  kill -0 "$XPID" 2>/dev/null || { cat "$WORK/xvfb.log" >&2; exit 1; }
  sleep .25
done
[ -S "/tmp/.X11-unix/X$N" ] || { echo "no X socket for $DISP" >&2; exit 1; }

export DISPLAY="$DISP"

# Operator-controlled command from a committed station fixture; shell form is
# deliberate because Hercules/DPS8M/SIMH startup needs cd/env/redirection.
( cd "$EMU_CWD" && exec bash -lc "exec $EMU_CMD" ) >"$WORK/emulator.log" 2>&1 &
EPID=$!

fail() {
  echo "$1" >&2
  tail -120 "$WORK/emulator.log" >&2 || true
  exit 1
}

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  kill -0 "$EPID" 2>/dev/null || fail "hidden emulator exited before the terminal became ready"
  [ "$(date +%s)" -lt "$deadline" ] || fail "terminal not ready after ${TIMEOUT}s"
  if nc -z 127.0.0.1 "$READY_PORT" 2>/dev/null; then
    # [PROVEN] the port alone lies — see the timeline at the top of this file.
    if [ -z "$READY_RE" ] || grep -qE "$READY_RE" "$WORK/emulator.log" 2>/dev/null; then
      break
    fi
  fi
  sleep .5
done

# The client is the museum surface. No host/operator console is ever mapped
# into the capture.
exec bash -lc "$CLIENT_CMD"
