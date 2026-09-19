#!/bin/bash
# DRAFT ONLY: stage DPS8M + MR12.8 QuickStart.
set -euo pipefail
WORK="${WORK:-/data/vms/build-multics}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/multics}"
QUICKSTART="${QUICKSTART:-}"
DPS8M_REPO="${DPS8M_REPO:-https://github.com/BAN-AI-Multics/dps8m.git}"
DPS8M_REF="${DPS8M_REF:-83d7252b829f2bbc497b45ff0fc9a96d1335c347}"
mkdir -p "$WORK" "$ASSETS"
[ -n "$QUICKSTART" ] || { echo "set QUICKSTART to acquired MR12.8 QuickStart" >&2; exit 2; }
git clone "$DPS8M_REPO" "$WORK/dps8m-src"
( cd "$WORK/dps8m-src"; git checkout "$DPS8M_REF"; git rev-parse HEAD ) | tee "$WORK/dps8m.commit"
case "$QUICKSTART" in
  *.tar|*.tar.gz|*.tgz|*.tar.xz|*.zip) cp -f "$QUICKSTART" "$WORK/quickstart.archive" ;;
  *) cp -a "$QUICKSTART" "$ASSETS/quickstart" ;;
esac
cat >&2 <<'EOF'
WORKER:
  pin/build DPS8M once;
  unpack QuickStart into assets/multics/quickstart;
  prove dps8 MR12.8_boot.ini reaches the user terminal service;
  record actual terminal port (research expects 6180);
  stage minimal nspawn rootfs with Xvfb+xterm+telnet/netcat.
EOF
