#!/bin/bash
# install-amiga-coldboot.sh — install the Amiga cold-boot-on-visit lifecycle
# (AUTHORED 2026-07-14 from the live install; the original was hand-applied).
# RUN ON THE BOX from a repo checkout, with the amiga kiosk built & up.
#
# Pieces (all byte-copies of the live install, in this directory):
#   host  : amiga-coldboot-watch.sh  -> /usr/local/bin/  (journal watcher; ssh's the kiosk)
#   host  : ../../streamhost/deploy/amiga-coldboot-watch.service -> systemd unit
#   kiosk : amiga-emu                -> guest /usr/local/bin/amiga-emu  (boot|stop|status flag)
#   kiosk : amiga-launch-coldboot.sh -> guest /etc/bridge/launch.sh    (supervisor loop;
#           REPLACES the plain `exec fs-uae` launcher that scripts/build-guests/tiles/amiga.sh bakes)
#
# Requires tile.env SH_IDLE_PAUSE_SECS=0 for amiga (the daemon must never
# QMP-freeze the kiosk out from under the watcher) — asserted below.
set -euo pipefail

SSH_PORT="${SSH_PORT:-5818}"
KEY="${KEY:-/data/vms/bridge/bridge_key}"
TILE_ENV="${TILE_ENV:-/data/vms/streamhost/tiles/amiga/tile.env}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT="$HERE/../../streamhost/deploy/amiga-coldboot-watch.service"
log() { printf '[amiga-coldboot] %s\n' "$*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }

for f in "$HERE/amiga-coldboot-watch.sh" "$HERE/amiga-emu" "$HERE/amiga-launch-coldboot.sh" "$UNIT"; do
  [ -f "$f" ] || {
    echo "[amiga-coldboot] missing $f" >&2
    exit 1
  }
done

grep -q '^SH_IDLE_PAUSE_SECS=0' "$TILE_ENV" ||
  {
    echo "[amiga-coldboot] $TILE_ENV must set SH_IDLE_PAUSE_SECS=0 (QMP stop would freeze the whole kiosk)" >&2
    exit 1
  }

log "kiosk: installing amiga-emu + coldboot launch.sh (over ssh :$SSH_PORT)"
guest "cat > /usr/local/bin/amiga-emu && chmod +x /usr/local/bin/amiga-emu" <"$HERE/amiga-emu"
guest "cat > /etc/bridge/launch.sh && chmod +x /etc/bridge/launch.sh && chown root:root /etc/bridge/launch.sh" \
  <"$HERE/amiga-launch-coldboot.sh"
# restart the kiosk X session so the supervisor variant takes over (bridge-base
# respawns X -> launch.sh); the emulator starts OFF (black) until a visitor.
guest "pkill -u bridge fs-uae 2>/dev/null; pkill -HUP -u bridge xinit 2>/dev/null; true"

log "host: installing watcher + unit"
install -m 0755 "$HERE/amiga-coldboot-watch.sh" /usr/local/bin/amiga-coldboot-watch.sh
install -m 0644 "$UNIT" /etc/systemd/system/amiga-coldboot-watch.service
systemctl daemon-reload
systemctl enable --now amiga-coldboot-watch.service
systemctl --no-pager --lines 3 status amiga-coldboot-watch.service || true
log "done — visit the tile: FS-UAE should cold-boot (Kickstart hand -> Workbench); idle ${IDLE_GRACE:-60}s -> power-off"
