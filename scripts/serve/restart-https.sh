#!/bin/bash
# restart-https.sh — (re)start the osgallery single-origin HTTPS server that
# serves the UI + /signal/<tile>.json + POST /restore/<osId>. When the systemd
# unit osgallery-https.service is installed (the supervised, reboot-surviving
# path — see install-https-service.sh) this restarts THROUGH systemd; otherwise
# it falls back to the legacy detached relaunch. Idempotent; safe to re-run
# after a webroot redeploy.
#
# OSG_ADMIN_EVAL is ON by default and is an explicit DISABLE switch: pass
# OSG_ADMIN_EVAL=0 to turn arbitrary in-browser JS off for this restart. The
# enqueue endpoint is box-side only (loopback peer + operator token, and a flat
# 404 on the public listener), so nothing a browser can reach can issue an eval.
set -u
SERVE=/data/vms/streamhost/serve
PY="$SERVE/osgallery-https-server.py"
UNIT=osgallery-https.service
RUN_ENV=/run/osgallery-https.env

export WEBROOT="${WEBROOT:-$SERVE/webroot}"
export SIGNAL_CONFIG="${SIGNAL_CONFIG:-$SERVE/tiles.json}"
export CERT="${CERT:-$SERVE/pki/leaf.crt}"
export KEY="${KEY:-$SERVE/pki/leaf.key}"
export SIGNAL_HOST="${SIGNAL_HOST:-${SH_HOST_IP:-192.0.2.10}}"
export BIND_IP="${BIND_IP:-0.0.0.0}"
export PORT="${PORT:-8443}"
# Remote debugging is the point of this plane; eval is on unless turned off.
export OSG_ADMIN_EVAL="${OSG_ADMIN_EVAL:-1}"
# Restore-to-checkpoint endpoint authority (defaults sit beside the server).
export RESET_SCRIPT="${RESET_SCRIPT:-$SERVE/reset-tile.sh}"
export GOLDEN_MANIFEST="${GOLDEN_MANIFEST:-$SERVE/golden-manifest.json}"
# Walk-in env floor (ledger §4.2): only lowers the /admin switch, never raises
# it. `1` imposes no ceiling; unset/0 would floor it closed and defeat the
# admin toggle.
export WALKIN_OPEN="${WALKIN_OPEN:-1}"

if systemctl cat "$UNIT" >/dev/null 2>&1; then
  # Supervised path: hand this restart's overrides to systemd through a tmpfs
  # EnvironmentFile (the unit loads it last, so it wins), then restart. /run is
  # wiped on boot, so a per-restart OSG_ADMIN_EVAL=0 lapses back to the unit's
  # default rather than silently disabling eval forever.
  {
    printf 'WEBROOT=%s\n' "$WEBROOT"
    printf 'SIGNAL_CONFIG=%s\n' "$SIGNAL_CONFIG"
    printf 'CERT=%s\n' "$CERT"
    printf 'KEY=%s\n' "$KEY"
    printf 'SIGNAL_HOST=%s\n' "$SIGNAL_HOST"
    printf 'BIND_IP=%s\n' "$BIND_IP"
    printf 'PORT=%s\n' "$PORT"
    printf 'OSG_ADMIN_EVAL=%s\n' "$OSG_ADMIN_EVAL"
    printf 'RESET_SCRIPT=%s\n' "$RESET_SCRIPT"
    printf 'GOLDEN_MANIFEST=%s\n' "$GOLDEN_MANIFEST"
    printf 'WALKIN_OPEN=%s\n' "$WALKIN_OPEN"
  } >"$RUN_ENV"
  systemctl restart "$UNIT"
  sleep 1
  if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
    echo "https server up on :$PORT via systemd $UNIT (webroot=$WEBROOT, admin_eval=$OSG_ADMIN_EVAL)"
  else
    echo "https server FAILED to bind :$PORT via systemd — journalctl -u $UNIT" >&2
    journalctl -u "$UNIT" --no-pager --lines 5 1>&2 || true
    exit 1
  fi
  exit 0
fi

# Legacy fallback (no systemd unit installed): kill the detached instance by
# matching the script path (NOT a broad pkill), then relaunch detached.
for pid in $(pgrep -f "osgallery-https-server.py" 2>/dev/null); do
  kill "$pid" 2>/dev/null || true
done
sleep 0.5

nohup python3 "$PY" >"$SERVE/https-server.log" 2>&1 &
sleep 1
if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
  echo "https server up on :$PORT (webroot=$WEBROOT, restore=$RESET_SCRIPT, admin_eval=$OSG_ADMIN_EVAL)"
else
  echo "https server FAILED to bind :$PORT — see $SERVE/https-server.log" >&2
  tail -5 "$SERVE/https-server.log" >&2
  exit 1
fi
