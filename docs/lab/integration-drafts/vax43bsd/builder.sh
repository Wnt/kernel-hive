#!/bin/bash
# DRAFT ONLY: pin Open SIMH + 4.3BSD distribution/seed disk inputs.
set -euo pipefail
WORK="${WORK:-/data/vms/build-vax43bsd}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/vax43bsd}"
SIMH_REPO="${SIMH_REPO:-https://github.com/open-simh/simh.git}"
BSD_MEDIA="${BSD_MEDIA:-}"   # directory containing 4.3BSD distribution files or a smoke-only installed disk
mkdir -p "$WORK" "$ASSETS/bin" "$ASSETS/media"
git clone "$SIMH_REPO" "$WORK/simh"
( cd "$WORK/simh"; git rev-parse HEAD ) | tee "$WORK/simh.commit"
[ -n "$BSD_MEDIA" ] && cp -a "$BSD_MEDIA/." "$ASSETS/media/" || true
cat >&2 <<'EOF'
WORKER:
  pin SIMH commit/tag and build the vax780 simulator;
  for reproducible install stage stand/miniroot/rootdump/usr/src archives from TUHS;
  a ready installed RA81 disk is acceptable for the first framebuffer/input smoke only;
  create a final boot.ini that enables DZ lines and TCP listener 8888.
EOF
