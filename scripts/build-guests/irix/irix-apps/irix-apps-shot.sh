#!/usr/bin/env bash
# REAL framebuffer capture of the install rig -- the ONLY acceptable way to
# verify an install step (never infer progress from logs or disk state).
#
#   irix-apps-shot.sh [out.png]
#
# Primary channel: the MAME Lua SNAP verb (MAME's own framebuffer -> PNG in
# $D/snap). Fallback: ImageMagick import off the Xvfb root (flaky on a WM-less
# display, so it is only used if SNAP produced nothing).
set -u
D="${IRIX_APPS_DIR:-/data/vms/soltest/irix-apps}"
# The display is whatever irix-apps-launch.sh was ALLOCATED (recorded on start);
# never a hardcoded guess, which is how a shot ends up being of another rig.
DISP="${IRIX_APPS_DISPLAY:-$(cat "$D/display" 2>/dev/null)}"
[ -n "$DISP" ] || {
  echo "FATAL: no display recorded in $D/display - is the rig running?" >&2
  exit 1
}
OUT="${1:-$D/logs/shot.png}"

before=$(find "$D/snap" -name '*.png' 2>/dev/null | wc -l)
"$D/irix-apps-cmd.sh" snap
for _ in $(seq 1 40); do
  after=$(find "$D/snap" -name '*.png' 2>/dev/null | wc -l)
  [ "$after" -gt "$before" ] && break
  sleep 0.5
done

newest=$(find "$D/snap" -name '*.png' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
if [ -n "$newest" ] && [ "$after" -gt "$before" ]; then
  cp "$newest" "$OUT"
else
  echo "SNAP produced nothing; falling back to X import" >&2
  DISPLAY="$DISP" import -window root "$OUT"
fi
ls -l "$OUT"
