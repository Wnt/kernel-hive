#!/bin/bash
# DRAFT ONLY: stage a TK4/TK5 MVS 3.8j environment and terminal rootfs.
set -euo pipefail
WORK="${WORK:-/data/vms/build-mvs38}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/mvs38}"
TK5_SOURCE="${TK5_SOURCE:-}"
mkdir -p "$WORK" "$ASSETS/tk5"
[ -n "$TK5_SOURCE" ] || { echo "set TK5_SOURCE" >&2; exit 2; }
case "$TK5_SOURCE" in
  http://*|https://*) curl -fL --retry 3 -o "$WORK/tk5.archive" "$TK5_SOURCE" ;;
  *) cp -a "$TK5_SOURCE" "$WORK/tk5.source" ;;
esac
cat >&2 <<'EOF'
WORKER:
  unpack/copy the chosen TK system into assets/mvs38/tk5;
  run its documented Hercules startup once;
  prove nc -z 127.0.0.1 3270;
  record TSO credentials in private credential storage;
  stage a minimal nspawn rootfs carrying Xvfb+x3270;
  hash the actual DASD/config files production runs.
EOF
