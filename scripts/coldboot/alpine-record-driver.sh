#!/bin/bash
# Alpine's stock LiveCD stops at tty1 login; enter the passwordless root account
# on the clone so record-boot reaches an actual input-ready shell with no human input.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}/alpine-driver"
mkdir -p "$WORK"

# The observed clone reached localhost login after ~12 s. Hold to 18 s so the
# keystrokes cannot land in ISOLINUX/OpenRC even on a slower fresh rebuild.
sleep 18
br_screendump "$QMP" "$WORK/login.png" || br_die "alpine driver: login framebuffer unavailable"
for k in r o o t ret; do
  br_hmp "$QMP" "sendkey $k" >/dev/null
  sleep 0.15
done
sleep 3
br_screendump "$QMP" "$WORK/ready.png" || br_die "alpine driver: ready framebuffer unavailable"
