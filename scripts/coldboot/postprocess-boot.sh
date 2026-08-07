#!/bin/bash
# postprocess-boot.sh — P2a: turn a staged boot.mp4 into the scrub assets (§6).
# RUN ON THE BOX. Produces, in the tile's staging dir (/data/vms/streamhost/boot-rec/<id>/):
#   boot.mp4     (optionally re-encoded to §6.1 params if BOOTREC_REENCODE=1 or a
#                 boot_raw.* intermediate is present — record-boot.sh already emits the
#                 §6.1 params single-pass, so this is a normalise/idempotency pass)
#   sprite.jpg   (fps=1/N tile grid, §6.2)
#   thumbs.vtt   (#xywh media-fragment cues, §6.3)
#   boot.json    (durationMs filled in)
#
#   Usage: postprocess-boot.sh <tile>
#   Env:   BOOTREC_REENCODE=1  force the §6.1 re-encode of boot.mp4.
#          THUMB_W (default 160), COLS (default 10)  sprite geometry.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"

TILE="${1:?usage: postprocess-boot.sh <tile>}"
STAGE_DIR="$BOOTREC_STAGING_ROOT/$TILE"
BOOT_MP4="$STAGE_DIR/boot.mp4"
SPRITE="$STAGE_DIR/sprite.jpg"
VTT="$STAGE_DIR/thumbs.vtt"
BOOT_JSON="$STAGE_DIR/boot.json"
THUMB_W="${THUMB_W:-160}"
COLS="${COLS:-10}"

[ -s "$BOOT_MP4" ] || br_die "no staged boot.mp4 at $BOOT_MP4 (run record-boot.sh $TILE first)"

# ── optional §6.1 re-encode (from a boot_raw.* intermediate, or force via env) ──
RAW=""
for c in mkv mp4 nut; do [ -s "$STAGE_DIR/boot_raw.$c" ] && RAW="$STAGE_DIR/boot_raw.$c"; done
if [ -n "$RAW" ] || [ "${BOOTREC_REENCODE:-0}" = "1" ]; then
  src="${RAW:-$BOOT_MP4}"
  br_log "§6.1 re-encode $src -> boot.mp4 (crf18, keyint=15, +faststart, yuv420p high)"
  has_audio=1
  ffprobe -v 0 -select_streams a -show_entries stream=index -of csv=p=0 "$src" 2>/dev/null | grep -q . || has_audio=0
  tmp="$STAGE_DIR/.boot.reenc.mp4"
  set -- ffmpeg -hide_banner -y -i "$src" \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -preset veryfast -crf 18 \
    -x264-params "keyint=15:min-keyint=15:no-scenecut=1" -movflags +faststart
  if [ "$has_audio" = "1" ]; then set -- "$@" -c:a aac -b:a 128k; else set -- "$@" -an; fi
  "$@" "$tmp" >/dev/null 2>&1 || br_die "re-encode failed"
  mv -f "$tmp" "$BOOT_MP4"
fi

# ── probe duration + geometry ──
DUR="$(ffprobe -v 0 -of csv=p=0 -show_entries format=duration "$BOOT_MP4")"
W="$(ffprobe -v 0 -select_streams v:0 -of csv=p=0 -show_entries stream=width "$BOOT_MP4")"
H="$(ffprobe -v 0 -select_streams v:0 -of csv=p=0 -show_entries stream=height "$BOOT_MP4")"
if [ -z "$DUR" ] || [ -z "$W" ] || [ -z "$H" ]; then br_die "ffprobe failed on $BOOT_MP4"; fi
# thumb height from the clip aspect, rounded to even.
THUMB_H="$(python3 -c "print(int(round($THUMB_W*$H/$W/2))*2)")"
# N = clamp(ceil(dur/250), 1, 5)  (§6.2 cadence).
N="$(python3 -c "import math;print(max(1,min(5,math.ceil($DUR/250))))")"
COUNT="$(python3 -c "import math;print(max(1,math.ceil($DUR/$N)))")"
ROWS="$(python3 -c "import math;print(max(1,math.ceil($COUNT/$COLS)))")"
DUR_MS="$(python3 -c "print(int(round($DUR*1000)))")"
br_log "dur=${DUR}s ${W}x${H} thumb=${THUMB_W}x${THUMB_H} N=${N}s frames=$COUNT grid=${COLS}x${ROWS}"

# ── sprite sheet (§6.2) — from the SAME boot.mp4 so cue times align ──
ffmpeg -hide_banner -y -i "$BOOT_MP4" \
  -vf "fps=1/$N,scale=${THUMB_W}:${THUMB_H},tile=${COLS}x${ROWS}" \
  -an -frames:v 1 -qscale:v 4 "$SPRITE" >/dev/null 2>&1 || br_die "sprite failed"

# ── WebVTT thumbnail track (§6.3) — #xywh media fragments into sprite.jpg ──
python3 - "$DUR" "$N" "$THUMB_W" "$THUMB_H" "$COLS" >"$VTT" <<'PY'
import sys, math
dur, N, W, H, COLS = (float(sys.argv[1]), int(sys.argv[2]),
                      int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
def ts(s):
    h = int(s // 3600); m = int(s % 3600 // 60); sec = s % 60
    return f"{h:02d}:{m:02d}:{sec:06.3f}"
print("WEBVTT\n")
for i in range(math.ceil(dur / N)):
    t0 = i * N; t1 = min((i + 1) * N, dur)
    x = (i % COLS) * W; y = (i // COLS) * H
    print(f"{ts(t0)} --> {ts(t1)}")
    print(f"sprite.jpg#xywh={x},{y},{W},{H}\n")
PY

# ── fold durationMs (+ confirmed w/h) into boot.json ──
if [ -s "$BOOT_JSON" ]; then
  python3 - "$BOOT_JSON" "$DUR_MS" "$W" "$H" <<'PY'
import json, sys
p, dms, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
d = json.load(open(p))
d["durationMs"] = dms; d["width"] = w; d["height"] = h
json.dump(d, open(p, "w"), indent=2)
PY
  br_log "updated $BOOT_JSON (durationMs=$DUR_MS)"
else
  br_warn "no boot.json at $BOOT_JSON (record-boot.sh should have written it)"
fi

br_log "POSTPROCESS COMPLETE: $SPRITE + $VTT (+ boot.json). Next: gen-boot-manifest.sh"
