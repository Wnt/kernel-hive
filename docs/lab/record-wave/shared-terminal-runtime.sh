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
#   KH_TERM_READY_LOG_RE='regex'      # REQUIRED in practice — see finding 1
#   KH_TERM_EMULATOR_STDIN=/dev/null  # or a pty; never a pipe — see finding 2
#
# Contract:
#   * Xvfb is the only published graphics surface.
#   * Emulator/operator console goes to a logfile and is never shown.
#   * The visitor client starts only after readiness is PROVEN — see the two
#     lane findings below; a port probe alone is not readiness.
#   * If the hidden emulator exits, launch fails loudly.
#   * Station-specific reset must copy pristine mutable media BEFORE invoking this file.
#
# ---------------------------------------------------------------------------
# LANE FINDINGS (multics, 2026-09-20 — measured, docs/lab/MULTICS-WAVE.md)
#
# 1. A TCP PORT PROBE IS NOT A READINESS PROBE.
#    DPS8M's FNP opens 0.0.0.0:6180 four seconds after launch and Multics is
#    not usable for another forty-eight: the answering service only announces
#    itself at +52 s (`as_init_: Multics MR12.8; Answering Service 17.0`).
#    A visitor client started on the port probe attaches to a line on a system
#    that has nobody to answer it. Every station on this lane must therefore
#    also give KH_TERM_READY_LOG_RE — a regex matched against the hidden
#    emulator's OWN console stream — and the port probe stays only as the cheap
#    precondition it is. Expect the same shape on MVS (JES2 up), VAX (multiuser
#    getty) and ITS.
#
# 2. NEVER GIVE THE HIDDEN EMULATOR A PIPE OR A FIFO ON STDIN.
#    `dps8 MR12.8_boot.ini < fifo` prints as far as the FNP listen line and
#    then sleeps forever — no CPU thread, no boot. /dev/null boots; a pty
#    boots. The console is the simulator's own input path, the same trap as
#    PERQ needing a TTY as its clock (docs/lab/perq-station.md). So: /dev/null
#    when nothing drives the console, a pty when something must.
#    `bash -lc "exec $EMU_CMD" &` below inherits THIS script's stdin — which is
#    whatever the outer launcher had — so it is pinned explicitly.
#
# 3. IF YOU DRIVE AN OPERATOR CONSOLE, HANDSHAKE ON ITS PROMPT.
#    Multics' system_control drops the request text that arrives in the same
#    write as the attention ESC. ESC -> wait for a NEW prompt in the console
#    stream -> settle -> send the request. A single `printf '\033shut\r'` is
#    silently lost.
# ---------------------------------------------------------------------------
set -euo pipefail

DISP="${KH_TERM_DISPLAY:?KH_TERM_DISPLAY required}"
GEOM="${KH_TERM_GEOM:-1024x768}"
EMU_CMD="${KH_TERM_EMULATOR_CMD:?KH_TERM_EMULATOR_CMD required}"
READY_PORT="${KH_TERM_READY_PORT:?KH_TERM_READY_PORT required}"
CLIENT_CMD="${KH_TERM_CLIENT_CMD:?KH_TERM_CLIENT_CMD required}"
TIMEOUT="${KH_TERM_READY_TIMEOUT_S:-300}"
READY_RE="${KH_TERM_READY_LOG_RE:-}"
EMU_STDIN="${KH_TERM_EMULATOR_STDIN:-/dev/null}"
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
bash -lc "exec $EMU_CMD" >"$WORK/emulator.log" 2>&1 <"$EMU_STDIN" &
EPID=$!

# Readiness = the port AND, when the station declares one, a line the emulator
# itself printed. Finding 1: the port alone lies by ~48 s on Multics.
ready() {
  nc -z 127.0.0.1 "$READY_PORT" 2>/dev/null || return 1
  [ -z "$READY_RE" ] && return 0
  grep -Eq "$READY_RE" "$WORK/emulator.log" 2>/dev/null
}
[ -n "$READY_RE" ] || echo "WARNING: no KH_TERM_READY_LOG_RE — a port probe is not readiness" >&2

deadline=$(( $(date +%s) + TIMEOUT ))
while ! ready; do
  kill -0 "$EPID" 2>/dev/null || {
    echo "hidden emulator exited before terminal became ready" >&2
    tail -100 "$WORK/emulator.log" >&2 || true
    exit 1
  }
  [ "$(date +%s)" -lt "$deadline" ] || {
    echo "terminal not ready after ${TIMEOUT}s (port $READY_PORT${READY_RE:+, log /$READY_RE/})" >&2
    tail -100 "$WORK/emulator.log" >&2 || true
    exit 1
  }
  sleep .5
done

# Client becomes PID 1-ish payload for the station container; its X window is
# the museum surface. No host/operator console is ever mapped into the capture.
exec bash -lc "$CLIENT_CMD"
