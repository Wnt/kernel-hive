#!/bin/bash
# install-https-service.sh — install + enable the systemd unit that supervises
# the osgallery single-origin HTTPS UI/signaling server (:8443) so it comes back
# on its own after a reboot / power cycle. RUN ON labhost from a repo checkout
# (or `ssh lab 'bash /data/vms/streamhost/serve/install-https-service.sh'`).
#
# Idempotent: re-running re-installs the unit, reloads systemd, and leaves the
# service enabled + running. Any legacy detached (nohup) instance started by the
# old restart-https.sh / serve-https-spa.sh path is stopped first so systemd is
# the sole owner of :8443.
set -euo pipefail

SERVE=/data/vms/streamhost/serve
UNIT_NAME=osgallery-https.service
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_UNIT="$HERE/osgallery-https.service"
DEST_UNIT="/etc/systemd/system/$UNIT_NAME"
log() { printf '[https-service] %s\n' "$*"; }

[ -f "$SRC_UNIT" ] || {
  echo "[https-service] missing unit source $SRC_UNIT" >&2
  exit 1
}
[ -f "$SERVE/osgallery-https-server.py" ] || {
  echo "[https-service] server not deployed at $SERVE (run serve-https-spa.sh deploy first)" >&2
  exit 1
}

# Stop any legacy detached instance so it can't hold :8443 against systemd.
for pid in $(pgrep -f "osgallery-https-server.py" 2>/dev/null); do
  log "stopping legacy detached server pid $pid"
  kill "$pid" 2>/dev/null || true
done
rm -f /run/osgallery-https.pid /run/osgallery-https.env
sleep 0.5

# Third-party Python comes from the repo's lockfile, not apt. Build it before
# the unit starts so a first install does not fail its own ExecStartPre.
log "syncing the python virtualenv from the lockfile"
"$SERVE/sync-venv.sh"

log "installing $DEST_UNIT"
install -m 0644 "$SRC_UNIT" "$DEST_UNIT"
systemctl daemon-reload
systemctl enable --now "$UNIT_NAME"
sleep 1

if ss -tlnp 2>/dev/null | grep -q ":8443 "; then
  log "up + enabled — :8443 bound by pid $(systemctl show -p MainPID --value "$UNIT_NAME")"
  systemctl --no-pager --lines 3 status "$UNIT_NAME" || true
  log "done — the HTTPS server will now auto-start on boot"
else
  echo "[https-service] FAILED to bind :8443 after enable" >&2
  journalctl -u "$UNIT_NAME" --no-pager --lines 20 || true
  tail -20 "$SERVE/https-server.log" 2>/dev/null || true
  exit 1
fi
