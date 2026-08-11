#!/bin/bash
# amiga-coldboot-watch.sh — box-side session watcher that COLD-BOOTS the Amiga 500
# kiosk's FS-UAE emulator on visit and powers it off when idle, by tracking the
# streamhost@amiga daemon's own session log lines. NO streamhost binary change needed,
# so it is unaffected by shared-binary redeploys (the daemon is shared fleet-wide).
#
# WHY a watcher instead of QMP idle-pause: this is a BRIDGE station — a Debian kiosk running
# FS-UAE. QMP stop would freeze the WHOLE kiosk (X + capture + ssh). Cold-boot here means
# restarting the *emulator inside the kiosk*, so the kiosk X server + streamhost capture
# stay live and we drive FS-UAE over ssh. Set SH_IDLE_PAUSE_SECS=0 in the tile.env so the
# daemon never freezes the kiosk out from under this watcher.
#
# Session accounting (robust against abnormal exits):
#   SESSION_ACCEPTED            -> active++     (a visitor joined)
#   SESSION_ENDED               -> active--     (clean leave)
#   "[transport] session error" -> active--     (errored leave; SESSION_ENDED skipped)
#   "LISTENING udp/"            -> active=0      (endpoint (re)bind incl. cert rotation
#                                                 drops every session at once)
#   0 -> >0 : amiga-emu boot  (COLD-boot the Amiga: Kickstart hand -> disk seek -> WB)
#   >0 -> 0 : after IDLE_GRACE, amiga-emu stop (power off -> black)
#
# Single-shell design: read the journal via process substitution with a 2 s timeout so
# the SAME shell both consumes log lines AND checks the idle grace deadline (no subshell
# scope loss, no racing background timer).
set -u
TILE=amiga
SSH_PORT=5818
KEY=/data/vms/bridge/bridge_key
IDLE_GRACE="${IDLE_GRACE:-60}" # seconds after the last visitor before power-off
emu() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  -p "$SSH_PORT" root@127.0.0.1 "/usr/local/bin/amiga-emu $1" 2>/dev/null; }

active=0
idle_deadline=0  # epoch seconds; 0 = no pending power-off
emu stop || true # start from a clean, powered-off emulator
echo "[coldboot-watch] $TILE up; grace=${IDLE_GRACE}s; emulator OFF, waiting for a visitor"

# Feed journalctl through fd 3 (process substitution) so a timed read can tick the
# grace timer between log lines. -t 2: wake every ~2 s even when the log is quiet.
# SH_FEED_CMD overrides the source (test harness feeds synthetic session lines).
FEED_CMD="${SH_FEED_CMD:-journalctl -u streamhost@${TILE} -n0 -f -o cat --since now}"
exec 3< <($FEED_CMD 2>/dev/null)
while true; do
  if IFS= read -r -t 2 -u 3 line; then
    case "$line" in
      *SESSION_ACCEPTED*)
        active=$((active + 1))
        if [ "$active" -eq 1 ]; then
          idle_deadline=0
          echo "[coldboot-watch] visitor (active=$active) -> COLD-BOOT emulator"
          emu boot
        fi
        ;;
      *SESSION_ENDED* | *"[transport] session error"*)
        [ "$active" -gt 0 ] && active=$((active - 1))
        if [ "$active" -eq 0 ]; then
          idle_deadline=$(($(date +%s) + IDLE_GRACE))
          echo "[coldboot-watch] last visitor left -> power off at deadline (+${IDLE_GRACE}s)"
        fi
        ;;
      *"LISTENING udp/"*)
        active=0
        idle_deadline=$(($(date +%s) + IDLE_GRACE))
        ;;
    esac
  fi
  # Idle power-off when the grace deadline passes with zero active sessions.
  if [ "$idle_deadline" -ne 0 ] && [ "$active" -eq 0 ] && [ "$(date +%s)" -ge "$idle_deadline" ]; then
    idle_deadline=0
    echo "[coldboot-watch] grace elapsed -> power OFF emulator"
    emu stop
  fi
done
