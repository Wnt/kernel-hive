#!/bin/bash
# trim-boot.sh — trim a boot clip's dead trailing-static tail while PRESERVING the
# seam invariant (last frame == checkpoint) AND the boot chime. Operates in place on a
# boot-rec dir (backs the original up as boot.mp4.orig). Idempotent + safe to re-run.
#
#   Usage: trim-boot.sh <boot-rec-dir>
#   Env:   TRIM_SCENE_THRESH (default 0.004)  videoSettle = timestamp of the LAST frame
#                                             whose scene-change score exceeds this (the
#                                             last significant frame-to-frame change);
#                                             trailing frames below it are the dead tail.
#          TRIM_SILENCE_DB   (default -50)    silencedetect noise floor (dB). audioEnd
#                                             = last non-silent audio (chime is never cut).
#          TRIM_HOLD_S       (default 1.2)    hold appended after max(settle,audioEnd).
#          TRIM_MIN_SAVE_S   (default 1.5)    below this many seconds removable => no-op.
#          BOOTREC_LIB       (default: sibling bootrec-lib.sh)
#          POSTPROCESS       (default: sibling postprocess-boot.sh)
#
# WHY stream-copy (not a fresh re-encode): the staged boot.mp4 is ALREADY §6-encoded
# (record-boot.sh single-pass §6.1: libx264 high/yuv420p/crf18/keyint=15/+faststart), so
# a copy preserves every §6 property. More importantly, H.264 is lossy: re-encoding the
# tail changes the decoded final frame and BREAKS the byte-identical seam gate (a fresh
# crf18 pass over the settled desktop yields a different md5). And because each frame is
# lossily coded per its GOP position, NO two frames of a "static" desktop share an md5 —
# so simple truncation cannot reproduce the original's exact final frame either. The only
# construction that satisfies the hard gate is to KEEP the original's final GOP verbatim:
#   out = copy[0 .. kfHold)  ++  copy[kfLast .. end]
# dropping the static middle [kfHold, kfLast]. The last packet is the original's, so the
# last decoded frame is byte-identical to the checkpoint by construction; both segments are
# original §6 packets, so the output stays §6-compliant.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
POSTPROCESS="${POSTPROCESS:-$HERE/postprocess-boot.sh}"

DIR="${1:?usage: trim-boot.sh <boot-rec-dir>}"
DIR="$(cd "$DIR" && pwd)"
BOOT_MP4="$DIR/boot.mp4"
ORIG="$DIR/boot.mp4.orig"
[ -s "$BOOT_MP4" ] || br_die "no boot.mp4 in $DIR"

SCENE_THRESH="${TRIM_SCENE_THRESH:-0.004}"
SILENCE_DB="${TRIM_SILENCE_DB:--50}"
HOLD_S="${TRIM_HOLD_S:-1.2}"
MIN_SAVE_S="${TRIM_MIN_SAVE_S:-1.5}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/trimboot.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── back up the pristine original ONCE (idempotent — later runs keep the first) ──
if [ ! -f "$ORIG" ]; then
  cp -f "$BOOT_MP4" "$ORIG"
  br_log "backed up original -> $ORIG"
else
  br_log "reusing existing backup $ORIG as the golden reference"
fi
# The seam gate always compares against the pristine original, never a prior trim.
SRC="$ORIG"

# ── probe geometry ──
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC")"
HAS_AUDIO=1
ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$SRC" | grep -q . || HAS_AUDIO=0
br_log "clip dur=${DUR}s audio=$([ "$HAS_AUDIO" = 1 ] && echo yes || echo no)"

# ── VIDEO settle = timestamp of the LAST significant frame-to-frame change ──
# ffmpeg scene-change score: trailing frames below the threshold no longer change
# meaningfully — that run is the dead static tail. (H.264 is lossy, so "identical"
# frames never share pixels; the last real motion is the robust settle signal.)
VIDEO_SETTLE="$(ffmpeg -hide_banner -nostats -i "$SRC" \
  -vf "select='gt(scene,$SCENE_THRESH)',showinfo" -an -f null - 2>&1 |
  sed -n 's/.*pts_time:\([0-9.]*\).*/\1/p' | tail -1)"
[ -n "$VIDEO_SETTLE" ] || VIDEO_SETTLE="0.000"

# ── AUDIO end = timestamp of the LAST non-silent audio (protects a settle-time chime) ──
AUDIO_END="0.000"
if [ "$HAS_AUDIO" = 1 ]; then
  SIL_LOG="$WORK/silence.log"
  ffmpeg -hide_banner -nostats -i "$SRC" -af "silencedetect=noise=${SILENCE_DB}dB:d=0.2" \
    -f null - >"$SIL_LOG" 2>&1 || true
  AUDIO_END="$(
    python3 - "$SIL_LOG" "$DUR" <<'PY'
import re, sys
log, dur = sys.argv[1], float(sys.argv[2])
starts, ends = [], []
for line in open(log, errors="replace"):
    ms = re.search(r'silence_start:\s*([0-9.]+)', line)
    me = re.search(r'silence_end:\s*([0-9.]+)', line)
    if ms: starts.append(float(ms.group(1)))
    if me: ends.append(float(me.group(1)))
# No silence at all => audio is active up to the end.
if not starts:
    print(f"{dur:.3f}"); raise SystemExit
last_start = starts[-1]
last_end = ends[-1] if ends else dur
# If the final silence runs to EOF, the last non-silent audio ended at last_start;
# otherwise audio resumed after and plays to the end.
print(f"{(last_start if last_end >= dur - 0.1 else dur):.3f}")
PY
  )"
fi

# ── cut = max(videoSettle, audioEnd) + hold, clamped to the clip length ──
CUT="$(python3 -c "print(min($DUR, max($VIDEO_SETTLE, $AUDIO_END) + $HOLD_S))")"
br_log "videoSettle=${VIDEO_SETTLE}s audioEnd=${AUDIO_END}s hold=${HOLD_S}s -> cut=${CUT}s (dur=${DUR}s)"

# ── keyframes: kfHold = first keyframe >= cut (keep the hold); kfLast = final GOP start ──
KF_LIST="$(ffprobe -v error -select_streams v:0 -skip_frame nokey \
  -show_entries frame=pts_time -of csv=p=0 "$SRC" | awk -F, 'NF{print $1}' |
  grep -E '^[0-9]' | sort -n)"
[ -n "$KF_LIST" ] || br_die "no video keyframes found in $SRC"
KF_LAST="$(printf '%s\n' "$KF_LIST" | tail -1)"
KF_HOLD="$(printf '%s\n' "$KF_LIST" | awk -v c="$CUT" '$1>=c{print $1; exit}')"
[ -n "$KF_HOLD" ] || KF_HOLD="$KF_LAST"

REMOVED="$(python3 -c "print(round($KF_LAST - $KF_HOLD, 3))")"
br_log "kfHold=${KF_HOLD}s kfLast=${KF_LAST}s removable=${REMOVED}s (min ${MIN_SAVE_S}s)"

# ── no-op guard: nothing meaningful to remove (already trimmed / no dead tail) ──
if python3 -c "import sys; sys.exit(0 if ($KF_LAST - $KF_HOLD) < $MIN_SAVE_S else 1)"; then
  br_log "TRIM SKIPPED: removable ${REMOVED}s < ${MIN_SAVE_S}s — leaving boot.mp4 untouched (no-op)."
  exit 0
fi

# ── build the trimmed clip: copy[0..kfHold) ++ copy[kfLast..end], §6 preserved ──
A="$WORK/a.mp4"
B="$WORK/b.mp4"
OUT="$WORK/trimmed.mp4"
LIST="$WORK/concat.txt"
ffmpeg -hide_banner -nostats -y -ss 0 -to "$KF_HOLD" -i "$SRC" \
  -c copy -avoid_negative_ts make_zero "$A" >/dev/null 2>&1 || br_die "segment A cut failed"
ffmpeg -hide_banner -nostats -y -ss "$KF_LAST" -i "$SRC" \
  -c copy -avoid_negative_ts make_zero "$B" >/dev/null 2>&1 || br_die "segment B (final GOP) cut failed"
printf 'file %q\nfile %q\n' "$A" "$B" >"$LIST"
ffmpeg -hide_banner -nostats -y -f concat -safe 0 -i "$LIST" \
  -c copy -movflags +faststart "$OUT" >/dev/null 2>&1 || br_die "concat failed"

# ── HARD GATE: trimmed last decoded frame must be byte-identical to the checkpoint ──
last_frame_md5() {
  local f="$1" n i
  n="$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$f")"
  i=$((n - 1))
  ffmpeg -hide_banner -nostats -i "$f" -vf "select=eq(n\\,$i)" -frames:v 1 -f rawvideo - 2>/dev/null | md5sum | awk '{print $1}'
}
MD5_ORIG="$(last_frame_md5 "$SRC")"
MD5_TRIM="$(last_frame_md5 "$OUT")"
NEW_DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT")"
br_log "seam gate: orig=$MD5_ORIG trim=$MD5_TRIM"
if [ "$MD5_ORIG" != "$MD5_TRIM" ]; then
  br_die "SEAM INVARIANT VIOLATED — trimmed last frame != golden. NOT overwriting $BOOT_MP4."
fi
br_log "seam invariant OK — last frame byte-identical (md5 $MD5_ORIG)"

# ── commit: replace boot.mp4, then regenerate sprite.jpg + thumbs.vtt + durationMs ──
mv -f "$OUT" "$BOOT_MP4"
br_log "trimmed boot.mp4 written: ${DUR}s -> ${NEW_DUR}s"
parent="$(dirname "$DIR")"
base="$(basename "$DIR")"
BOOTREC_STAGING_ROOT="$parent" "$POSTPROCESS" "$base" >/dev/null
br_log "TRIM COMPLETE: $DIR (sprite.jpg + thumbs.vtt + boot.json regenerated). Backup: $ORIG"
