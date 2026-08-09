#!/bin/bash
# Tier 2 builder scaffold for bbcmicro — installed guest or emulator bridge.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../lib/labqmp.py"
OS_ID="bbcmicro"
TILE_DIR="bbcmicro"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
# shellcheck disable=SC2317 # scaffold hook becomes reachable when TODO flow is filled
qmp() { python3 "$LABQMP" "$QMP" "$@"; }

log "TODO: gate and hash install media; create a fresh namespaced target disk"
log "TODO: automate the install/provisioning flow and preserve resumable evidence"
log "TODO: relaunch with the exact production device set, curate the fixture, and verify golden"
die "scaffold only: fill the Tier 2 builder for $TILE_DIR"
