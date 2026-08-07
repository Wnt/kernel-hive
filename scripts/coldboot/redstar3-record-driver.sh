#!/bin/bash
# redstar3-record-driver.sh — dismiss the clone-only no-audio notice after auto-login.
#
# Red Star 3 occasionally ignores the persisted "do not show again" setting on a
# true disk boot. Detect the notice from two framebuffer pixels (the red close
# control and its grey title bar), then accept the focused dialog with Enter. No
# credential or live-tile input is involved.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"

QMP="${1:?qmp.sock required}"
WORK="${2:?workdir required}"
SHOT="$WORK/redstar3-driver.png"

pixel_rgb() {
  local image="$1" x="$2" y="$3"
  ffmpeg -hide_banner -loglevel error -i "$image" \
    -vf "crop=1:1:${x}:${y},format=rgb24" -frames:v 1 -f rawvideo - 2>/dev/null |
    od -An -tu1
}

for _ in $(seq 1 120); do
  if br_screendump "$QMP" "$SHOT"; then
    read -r close_r close_g close_b <<<"$(pixel_rgb "$SHOT" 286 258)"
    read -r title_r title_g title_b <<<"$(pixel_rgb "$SHOT" 350 270)"
    if [ "$close_r" -ge 220 ] && [ "$close_g" -ge 50 ] && [ "$close_g" -le 130 ] &&
      [ "$close_b" -ge 50 ] && [ "$close_b" -le 130 ] &&
      [ "$title_r" -ge 200 ] && [ "$title_g" -ge 200 ] && [ "$title_b" -ge 200 ]; then
      br_log "redstar3 driver: no-audio notice detected; accepting focused dialog"
      br_hmp "$QMP" "sendkey ret" >/dev/null
      br_log "redstar3 driver: parking tablet cursor at the lower-right edge"
      br_qmp "$QMP" '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":32767}},{"type":"abs","data":{"axis":"y","value":32767}}]}}' >/dev/null
      sleep 10
      exit 0
    fi
  fi
  sleep 1
done

# Fail closed instead of freezing an unrecognised UI state into the clip.
br_die "redstar3 driver: no-audio notice not detected within 120 polls"
