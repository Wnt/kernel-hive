#!/bin/bash
# detect-interactive.sh — P1b: decide WHEN a booting guest has reached its settled,
# interactive desktop (the frame the recorder freezes + savevm's, §2.7 of the spec).
#
#   Usage: detect-interactive.sh <tile> <qmp.sock> <workdir>
#   Env:   BOOTREC_LIB (default: sibling bootrec-lib.sh)
#          Per-tile detection params come from bootrec-tiles.conf (BR_DETECT_TIER etc).
#
# Data-driven, 3 tiers (chosen per tile in bootrec-tiles.conf):
#   Tier 1  framebuffer-stability: cf (=1-SSIM) between consecutive screendumps stays
#           below BR_CF_THRESHOLD for BR_SETTLE_MS. Good for static desktops.
#   Tier 2  reference-region match: SSIM of a stable crop (BR_REF_CROP) vs a per-tile
#           reference PNG (BR_REF_PNG) >= 0.985 for BR_REF_MATCH_K consecutive frames.
#           For desktops that keep animating (clock/CDE) where Tier 1 never settles.
#   Tier 3  fixed settle timer: sleep BR_TIER3_TIMER_MS; then, if a reference is set,
#           confirm with a Tier-2 region match. Last resort for unpredictable boots.
#
# All tiers are bounded by BR_MAX_MS (a recording is never unbounded). Prints the
# reached-epoch (date +%s) on stdout and exits 0 when interactive; exits 3 on the
# BR_MAX_MS cap (caller records up to the cap and proceeds — a bounded clip).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
# shellcheck source=bootrec-tiles.conf disable=SC1091
source "$HERE/bootrec-tiles.conf"

TILE="${1:?usage: detect-interactive.sh <tile> <qmp.sock> <workdir>}"
QMP="${2:?qmp.sock required}"
WORK="${3:?workdir required}"
bootrec_load_tile "$TILE"
mkdir -p "$WORK"

SSIM_MATCH="${BR_SSIM_MATCH:-0.985}" # Tier-2 "same region" threshold
POLL_MS="${BR_POLL_MS:-1000}"        # screendump cadence
now_ms() { echo $(($(date +%s%3N))); }
START_MS="$(now_ms)"
elapsed_ms() { echo $(($(now_ms) - START_MS)); }

br_log "detect[$TILE] tier=$BR_DETECT_TIER max=${BR_MAX_MS}ms canvas=${BR_CANVAS_W}x${BR_CANVAS_H}"

reached() {
  br_log "detect[$TILE] INTERACTIVE reached at +$(elapsed_ms)ms ($1)"
  date +%s
  exit 0
}
capped() {
  br_warn "detect[$TILE] hit BR_MAX_MS=${BR_MAX_MS}ms without settle — proceeding (bounded clip)"
  date +%s
  exit 3
}

tier1() {
  local prev="" cur="$WORK/det.png" cf settle_start_ms=0 held=0
  while :; do
    [ "$(elapsed_ms)" -ge "$BR_MAX_MS" ] && capped
    cur="$WORK/det-$(now_ms).png"
    br_screendump "$QMP" "$cur" || {
      sleep 1
      continue
    }
    if [ -n "$prev" ] && [ -s "$prev" ]; then
      cf="$(br_change_fraction "$cur" "$prev")"
      br_log "detect[$TILE] cf=$cf (thr=$BR_CF_THRESHOLD)"
      if python3 -c "import sys; sys.exit(0 if float('$cf') < float('$BR_CF_THRESHOLD') else 1)"; then
        [ "$held" -eq 0 ] && settle_start_ms="$(now_ms)"
        held=1
        if [ $(($(now_ms) - settle_start_ms)) -ge "$BR_SETTLE_MS" ]; then
          rm -f "$prev"
          reached "tier1 stable ${BR_SETTLE_MS}ms"
        fi
      else
        held=0
      fi
      rm -f "$prev"
    fi
    prev="$cur"
    sleep "$(python3 -c "print($POLL_MS/1000)")"
  done
}

tier2() {
  local cur ok=0
  [ -s "$BR_REF_PNG" ] || br_die "tier2 needs BR_REF_PNG (per-tile reference screendump) — got '$BR_REF_PNG'"
  while :; do
    [ "$(elapsed_ms)" -ge "$BR_MAX_MS" ] && capped
    cur="$WORK/det-$(now_ms).png"
    br_screendump "$QMP" "$cur" || {
      sleep 1
      continue
    }
    local s
    s="$(br_ssim "$cur" "$BR_REF_PNG" "$BR_REF_CROP")"
    [ -z "$s" ] && s=0
    br_log "detect[$TILE] region-ssim=$s (need >= $SSIM_MATCH x$BR_REF_MATCH_K, have $ok)"
    if python3 -c "import sys; sys.exit(0 if float('$s') >= float('$SSIM_MATCH') else 1)"; then
      ok=$((ok + 1))
      [ "$ok" -ge "$BR_REF_MATCH_K" ] && {
        rm -f "$cur"
        reached "tier2 region match x$ok"
      }
    else
      ok=0
    fi
    rm -f "$cur"
    sleep "$(python3 -c "print($POLL_MS/1000)")"
  done
}

tier3() {
  br_log "detect[$TILE] tier3 fixed settle: sleeping ${BR_TIER3_TIMER_MS}ms"
  # sleep in <=BR_MAX_MS-bounded chunks so an over-long timer still caps.
  local waited=0 chunk=1000
  while [ "$waited" -lt "$BR_TIER3_TIMER_MS" ]; do
    [ "$(elapsed_ms)" -ge "$BR_MAX_MS" ] && capped
    sleep 1
    waited=$((waited + chunk))
  done
  if [ -n "$BR_REF_PNG" ] && [ -s "$BR_REF_PNG" ]; then
    br_log "detect[$TILE] tier3 -> tier2 confirm"
    tier2
  fi
  reached "tier3 timer ${BR_TIER3_TIMER_MS}ms"
}

case "$BR_DETECT_TIER" in
  1) tier1 ;;
  2) tier2 ;;
  3) tier3 ;;
  *) br_die "unknown BR_DETECT_TIER=$BR_DETECT_TIER" ;;
esac
