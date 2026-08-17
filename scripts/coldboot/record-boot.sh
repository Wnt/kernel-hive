#!/bin/bash
# record-boot.sh — P1a (capture) + P1c (bake) for the boot-video replay feature.
# RUN ON labhost (ssh lab). Records a station's cold power-on to a scrub-optimised MP4
# whose LAST FRAME is byte-identical to the checkpoint's first live frame, so the UI's
# recorded-video -> live-stream handoff is invisible (spec §1.1, §3.1).
#
#   Usage: record-boot.sh <tile> [--dry-run]
#
# It is a STANDALONE SIDECAR (model: scripts/coldboot/amiga-coldboot-watch.sh) — NO
# streamhost daemon change, so it is unaffected by the shared-binary redeploys of
# scripts/dev/build-deploy.sh. It cold-launches a CLONE of the station under
# /data/vms/sandbox/ on the station's EXACT live device set (a byte copy of the live
# qemu-streamhost.sh with only paths/ports/loadvm rewritten — loadvm golden requires
# an exact device match), taps QEMU's dbus display + audio the same way the daemon
# does, and feeds raw BGRA + PCM into a single-pass ffmpeg encode (§2.3 RECOMMENDED:
# fixed canvas, no mid-boot SPS/resolution problem). Kills the clone ONLY by pidfile.
#
# ── THE dbus TAP (the one piece that needs labhost + a tiny companion binary) ──────
# Tapping QEMU's p2p D-Bus display/audio needs SCM_RIGHTS fd-passing + zbus — it is
# NOT expressible in bash and cannot be exercised off labhost. It is the EXACT mechanism
# streamhost already ships:
#     video: streamhost/streamhost/src/capture.rs  `pub async fn connect(qmp)`  — QMP
#            getfd(dbusdisp)+add_client{@dbus-display} then Console RegisterListener,
#            yields BGRA scanout frames (capture.rs:621-660).
#     audio: streamhost/streamhost/src/audio.rs     `register(...)` — RegisterOutListener,
#            yields s16le PCM (audio.rs:139-200).
# The companion reader is a ~120-line `[[bin]]` in that crate whose main():
#   (1) capture::connect(<qmp.sock>); on each frame, letterbox/scale the scanout to a
#       CONSTANT <WxH> canvas (using QEMU's per-frame scanout dims) and write BGRA to
#       argv video-fifo, PACED to <fps> (duplicate the last frame between damage) so
#       the downstream `-f rawvideo` sees a fixed size + constant rate;
#   (2) audio::register(...); write s16le to argv audio-fifo (open+close it even when
#       the station has an audiodev but no card, else ffmpeg blocks on the missing writer).
# Point record-boot at it via  SH_DBUS_TAP=/path/to/bootrec-tap  (contract below). Any
# producer honouring that contract works — e.g. a synthetic BGRA generator for testing
# the ffmpeg/detect/capture plumbing off labhost (mirrors amiga-coldboot-watch.sh's SH_FEED_CMD; labhost-side prototype, not in repo).
#
#   SH_DBUS_TAP contract:  $SH_DBUS_TAP <qmp.sock> <video.fifo> <audio.fifo|""> <WxH> <fps> <arate> <ach>
#     writes constant-size BGRA frames at <fps> to <video.fifo>; s16le PCM to <audio.fifo>
#     (skipped when "" is passed); exits cleanly on SIGTERM (closing the fifos -> ffmpeg EOF).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"
# shellcheck source=bootrec-tiles.conf disable=SC1091
source "$HERE/bootrec-tiles.conf"

TILE="${1:?usage: record-boot.sh <tile> [--dry-run]}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
bootrec_load_tile "$TILE"

TILE_DIR="$BOOTREC_TILES_ROOT/$TILE"
LAUNCHER="$TILE_DIR/qemu-streamhost.sh"
CLONE_DIR="$BOOTREC_CLONE_ROOT/bootrec-$TILE-$$"
STAGE_DIR="$BOOTREC_STAGING_ROOT/$TILE"
CLONE_LAUNCHER="$CLONE_DIR/qemu-streamhost.sh"
CLONE_QMP="$CLONE_DIR/qmp.sock"
CLONE_PID="$CLONE_DIR/qemu.pid"
VFIFO="$CLONE_DIR/video.fifo"
AFIFO=""
[ "$BR_HAS_AUDIO" -eq 1 ] && AFIFO="$CLONE_DIR/audio.fifo"
BOOT_MP4="$STAGE_DIR/boot.mp4"
VID_MP4="$CLONE_DIR/boot_video.mp4" # video-only intermediate (single-pipe encode)
AUD_M4A="$CLONE_DIR/boot_audio.m4a" # audio-only intermediate (single-pipe encode)
POSTER_PNG="$CLONE_DIR/poster.png"  # lossless freeze frame (verify reference)
POSTER_JPG="$STAGE_DIR/poster.jpg"  # served poster
VERIFY_PNG="$CLONE_DIR/verify.png"
BOOT_JSON="$STAGE_DIR/boot.json"

TAP_PID=""
FFMPEG_V_PID=""
FFMPEG_A_PID=""
cleanup() {
  local rc=$? p
  if [ -n "$TAP_PID" ]; then kill "$TAP_PID" 2>/dev/null || true; fi
  for p in "$FFMPEG_V_PID" "$FFMPEG_A_PID"; do
    if [ -n "$p" ]; then
      kill "$p" 2>/dev/null || true
      wait "$p" 2>/dev/null || true
    fi
  done
  br_kill_pidfile "$CLONE_PID"
  br_log "cleanup done (rc=$rc); clone dir kept for inspection: $CLONE_DIR"
  exit "$rc"
}
trap cleanup EXIT INT TERM

# ── build the clone launcher (exact device set; only paths/ports/loadvm rewritten) ──
build_clone_launcher() {
  [ -f "$LAUNCHER" ] || br_die "live launcher not found: $LAUNCHER"
  mkdir -p "$CLONE_DIR" "$STAGE_DIR"
  # copy the disks the launcher references INTO the clone (savevm writes the COPY).
  # Skipped on --dry-run (preview only needs the rewritten launcher, not a multi-GB copy).
  local d
  for d in $BR_DISKS; do
    [ -f "$TILE_DIR/$d" ] || br_die "disk '$d' not found in $TILE_DIR"
    if [ "$DRY" -eq 1 ]; then
      br_log "dry-run: would clone disk $d -> $CLONE_DIR/$d (reflink if supported)"
    else
      br_log "cloning disk $d (reflink if supported) ..."
      cp --reflink=auto -f "$TILE_DIR/$d" "$CLONE_DIR/$d"
    fi
  done
  # Writable disks outside the station directory need an explicit copy+rewrite. This
  # closes the win98se/os2warp/reactos-style footgun for data-driven arms: a clone
  # must never attach a live writable qcow2 merely because its path was absolute.
  local spec src dst
  for spec in "${BR_EXTERNAL_DISKS[@]}"; do
    src="${spec%%|*}"
    dst="${spec#*|}"
    if [ -z "$src" ] || [ -z "$dst" ] || [ "$src" = "$dst" ]; then
      br_die "bad BR_EXTERNAL_DISKS entry '$spec' (want /absolute/source|basename)"
    fi
    [ -f "$src" ] || br_die "external disk not found: $src"
    if [ "$DRY" -eq 1 ]; then
      br_log "dry-run: would clone external disk $src -> $CLONE_DIR/$dst"
    else
      br_log "cloning external disk $src -> $dst (reflink if supported) ..."
      cp --reflink=auto -f "$src" "$CLONE_DIR/$dst"
    fi
  done
  # rewrite: (1) redirect ALL station-dir paths (BASE/DISK/OVERLAY/qmp.sock/pidfile) to
  # the clone dir; (2) rename -name to avoid confusion; (3) bump the guest hostfwd port
  # off the LIVE forward; (4) vmstate only -> neutralise -loadvm golden (COLD boot).
  sed -e "s#${TILE_DIR}#${CLONE_DIR}#g" \
    -e "s/-name streamhost-${TILE}/-name streamhost-${TILE}-bootrec/" \
    "$LAUNCHER" >"$CLONE_LAUNCHER"
  for spec in "${BR_EXTERNAL_DISKS[@]}"; do
    src="${spec%%|*}"
    dst="${spec#*|}"
    sed -i "s#${src}#${CLONE_DIR}/${dst}#g" "$CLONE_LAUNCHER"
  done
  if [ -n "$BR_HOSTFWD_ORIG" ] && [ -n "$BR_HOSTFWD_CLONE" ]; then
    sed -i "s/hostfwd=tcp:127.0.0.1:${BR_HOSTFWD_ORIG}-/hostfwd=tcp:127.0.0.1:${BR_HOSTFWD_CLONE}-/g" "$CLONE_LAUNCHER"
  fi
  local ports from to
  for ports in "${BR_PORT_REWRITES[@]}"; do
    from="${ports%%:*}"
    to="${ports#*:}"
    sed -i "s#127.0.0.1:${from}#127.0.0.1:${to}#g" "$CLONE_LAUNCHER"
  done
  if [ "$BR_BOOT_KIND" = "vmstate" ]; then
    # Launchers express the same action four ways: scalar/array LOADVM variables,
    # standalone or inline -loadvm, and (msdoswin1) a post-launch qmp helper. Strip
    # all executable forms while preserving the exact QEMU device set.
    sed -i \
      -e 's/-loadvm golden//g' \
      -e '/^[[:space:]]*python3 .*loadvm golden/ s/^/# bootrec cold boot: /' \
      "$CLONE_LAUNCHER"
    if grep -Eq '^[[:space:]]*([^#].*)?(-loadvm golden|python3 .*loadvm golden)' "$CLONE_LAUNCHER"; then
      br_die "loadvm neutralise incomplete — inspect $CLONE_LAUNCHER"
    fi
  fi
  chmod +x "$CLONE_LAUNCHER"
}

record_pipeline() {
  mkfifo "$VFIFO"
  [ -n "$AFIFO" ] && mkfifo "$AFIFO"
  # TWO single-pipe encoders (video-only + audio-only), muxed after the recording.
  # WHY NOT one two-input ffmpeg: a single ffmpeg reading TWO realtime pipes
  # (rawvideo + s16le) starves its video demux — one demux thread blocks on the
  # audio pipe read and the huge 3 MB raw frames back up, throttling capture to
  # ~5 fps (measured; produces a badly time-compressed clip). Splitting so each
  # ffmpeg reads exactly ONE pipe keeps both at real-time 1x; a fast -c copy mux
  # (finalize step) recombines them. Video still lands the delivered §6.1 params
  # (fixed canvas => one SPS, no mid-boot resolution change).
  local xparams="keyint=15:min-keyint=15:no-scenecut=1:bframes=0:rc-lookahead=0"
  local -a vcmd=(ffmpeg -hide_banner -y
    -f rawvideo -pixel_format bgra -video_size "${BR_CANVAS_W}x${BR_CANVAS_H}" -framerate "$BR_FPS" -i "$VFIFO"
    -vf "format=yuv420p" -c:v libx264 -profile:v high -pix_fmt yuv420p
    -preset veryfast -tune zerolatency -crf "${BR_CRF:-18}" -x264-params "$xparams"
    -an -movflags +faststart "$VID_MP4")
  br_log "ffmpeg(video): ${vcmd[*]}"
  "${vcmd[@]}" >/dev/null 2>"$CLONE_DIR/ffmpeg-video.log" &
  FFMPEG_V_PID=$!
  if [ -n "$AFIFO" ]; then
    local -a acmd=(ffmpeg -hide_banner -y
      -f s16le -ar "$BR_AUDIO_RATE" -ac "$BR_AUDIO_CH" -i "$AFIFO"
      -c:a aac -b:a 128k "$AUD_M4A")
    br_log "ffmpeg(audio): ${acmd[*]}"
    "${acmd[@]}" >/dev/null 2>"$CLONE_DIR/ffmpeg-audio.log" &
    FFMPEG_A_PID=$!
  fi
  br_log "dbus tap: $SH_DBUS_TAP $CLONE_QMP $VFIFO '${AFIFO}' ${BR_CANVAS_W}x${BR_CANVAS_H} $BR_FPS $BR_AUDIO_RATE $BR_AUDIO_CH"
  "$SH_DBUS_TAP" "$CLONE_QMP" "$VFIFO" "$AFIFO" "${BR_CANVAS_W}x${BR_CANVAS_H}" \
    "$BR_FPS" "$BR_AUDIO_RATE" "$BR_AUDIO_CH" >>"$CLONE_DIR/tap.log" 2>&1 &
  TAP_PID=$!
}

golden_sha() {
  if [ "$BR_BOOT_KIND" != "vmstate" ]; then
    echo "n/a-$BR_BOOT_KIND"
    return
  fi
  local first disk
  first="${BR_GOLDEN_DISK:-$(echo "$BR_DISKS" | awk '{print $1}')}"
  [ -n "$first" ] || br_die "vmstate tile '$TILE' has no BR_GOLDEN_DISK/BR_DISKS"
  disk="$CLONE_DIR/$first"
  qemu-img snapshot -l "$disk" 2>/dev/null | sha256sum | awk '{print $1}'
}

write_boot_json() {
  python3 - "$BOOT_JSON" "$TILE" "$BR_CANVAS_W" "$BR_CANVAS_H" "$BR_HAS_AUDIO" \
    "$(golden_sha)" "$BR_BOOT_KIND" "$BR_DETECT_TIER" "$BR_CF_THRESHOLD" \
    "$BR_SETTLE_MS" "$BR_TIER3_TIMER_MS" <<'PY'
import json, sys, datetime
(out, tile, w, h, aud, gsha, kind, tier, cfthr, settle, timer) = sys.argv[1:12]
detect = {"tier": int(tier)}
if int(tier) == 1: detect.update(cfThreshold=float(cfthr), settleMs=int(settle))
elif int(tier) == 3: detect.update(timerMs=int(timer))
doc = {
  "id": tile,
  "mp4": "boot.mp4", "poster": "poster.jpg", "sprite": "sprite.jpg", "vtt": "thumbs.vtt",
  "width": int(w), "height": int(h), "hasAudio": bool(int(aud)),
  "bakedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
  "goldenSha": gsha, "bootKind": kind, "detect": detect,
  # durationMs is filled by postprocess-boot.sh once the clip is probed.
}
json.dump(doc, open(out, "w"), indent=2)
print(out)
PY
}

main() {
  [ "${SH_DBUS_TAP:-}" != "" ] || [ "$DRY" -eq 1 ] || br_die \
    "SH_DBUS_TAP unset. Build the companion reader from streamhost capture.rs+audio.rs (see header) and export SH_DBUS_TAP=/path/to/bootrec-tap. Re-run with --dry-run to preview the plan without it."

  build_clone_launcher

  if [ "$DRY" -eq 1 ]; then
    br_log "── DRY RUN — clone launcher written, nothing launched ──"
    br_log "clone dir : $CLONE_DIR"
    br_log "boot kind : $BR_BOOT_KIND  canvas ${BR_CANVAS_W}x${BR_CANVAS_H}@${BR_FPS}  audio=$BR_HAS_AUDIO"
    br_log "detect    : tier $BR_DETECT_TIER (cf<$BR_CF_THRESHOLD/${BR_SETTLE_MS}ms | ref '$BR_REF_PNG' | timer ${BR_TIER3_TIMER_MS}ms)"
    [ "$BR_BOOT_KIND" = "bridge" ] && br_log "emu trigger: ssh -p $BR_EMU_SSH_PORT ... prep='$BR_EMU_PREP_CMD' boot='$BR_EMU_BOOT_CMD'"
    br_log "── rewritten clone launcher (verify device set matches live!) ──"
    grep -nE 'LOADVM|hostfwd|-name|qmp.sock|qemu.pid|-display|-audiodev|-device|\.qcow2' "$CLONE_LAUNCHER" >&2 || true
    return 0
  fi

  # 1. COLD LAUNCH the clone (vmstate: no loadvm; bridge: loadvm the kiosk checkpoint).
  br_log "launching clone: $CLONE_LAUNCHER"
  bash "$CLONE_LAUNCHER" >>"$CLONE_DIR/launch.log" 2>&1 || br_die "clone launch failed (see $CLONE_DIR/launch.log)"
  br_wait_qmp "$CLONE_QMP" 80 || br_die "clone QMP never came up"

  # A bridge clone resumes the kiosk checkpoint. Stop the emulator before capture so
  # the recorded first frame is its powered-off surface, not yesterday's desktop.
  if [ "$BR_BOOT_KIND" = "bridge" ] && [ -n "$BR_EMU_PREP_CMD" ]; then
    br_log "bridge: preparing powered-off emulator via ssh :$BR_EMU_SSH_PORT"
    ssh -i "$BR_EMU_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      -p "$BR_EMU_SSH_PORT" root@127.0.0.1 "$BR_EMU_PREP_CMD" ||
      br_die "bridge emulator prep failed"
  fi

  # 2. START RECORDER (ffmpeg <- dbus tap).
  record_pipeline

  # kiosks: the "cold boot" is the in-kiosk emulator — trigger it now, over the
  # clone's bumped ssh forward, so the visitor-visible power-on gets recorded.
  if [ "$BR_BOOT_KIND" = "bridge" ]; then
    [ -n "$BR_EMU_BOOT_CMD" ] || br_die "bridge tile missing BR_EMU_BOOT_CMD"
    br_log "bridge: cold-booting the in-kiosk emulator via ssh :$BR_EMU_SSH_PORT"
    ssh -i "$BR_EMU_SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      -p "$BR_EMU_SSH_PORT" root@127.0.0.1 "$BR_EMU_BOOT_CMD" || br_warn "emu boot trigger returned non-zero"
  fi

  if [ -n "$BR_BOOT_DRIVER" ]; then
    [ -x "$HERE/$BR_BOOT_DRIVER" ] || br_die "boot driver is not executable: $HERE/$BR_BOOT_DRIVER"
    br_log "running automated boot driver: $BR_BOOT_DRIVER"
    "$HERE/$BR_BOOT_DRIVER" "$CLONE_QMP" "$CLONE_DIR"
  fi

  # 3. DETECT interactive-reached (bounded by BR_MAX_MS).
  bash "$HERE/detect-interactive.sh" "$TILE" "$CLONE_QMP" "$CLONE_DIR/detect" || true

  # 4. PAUSE at the settle frame; poster == last encoded video frame == checkpoint 1st frame.
  br_log "freeze: QMP stop"
  br_qmp "$CLONE_QMP" '{"execute":"stop"}' >/dev/null || br_die "QMP stop failed"
  br_screendump "$CLONE_QMP" "$POSTER_PNG" || br_die "poster screendump failed"
  ffmpeg -hide_banner -y -i "$POSTER_PNG" -qscale:v 3 "$POSTER_JPG" >/dev/null 2>&1 || br_die "poster.jpg failed"

  # 5. CAPTURE (vmstate only): savevm golden ON THE PAUSED STATE (the §1.1 invariant).
  if [ "$BR_BOOT_KIND" = "vmstate" ]; then
    br_log "bake: delvm golden (ignore-if-absent) then savevm golden on the PAUSED VM"
    br_hmp "$CLONE_QMP" "delvm golden" >/dev/null 2>&1 || true
    br_hmp "$CLONE_QMP" "savevm golden" >/dev/null || br_die "savevm golden failed"
  else
    br_log "$BR_BOOT_KIND tile: SKIP savevm (boot artifact/emulator is the reset source)"
  fi

  # 6. STOP recorder, finalize boot.mp4 (mux the two single-pipe intermediates).
  br_log "stopping recorder -> finalize $BOOT_MP4"
  kill "$TAP_PID" 2>/dev/null || true
  TAP_PID="" # closes both fifos -> both ffmpegs EOF
  wait "$FFMPEG_V_PID" 2>/dev/null || true
  FFMPEG_V_PID=""
  [ -n "$FFMPEG_A_PID" ] && {
    wait "$FFMPEG_A_PID" 2>/dev/null || true
    FFMPEG_A_PID=""
  }
  [ -s "$VID_MP4" ] || br_die "video intermediate empty (see $CLONE_DIR/ffmpeg-video.log + tap.log)"
  if [ -n "$AFIFO" ] && [ -s "$AUD_M4A" ]; then
    br_log "mux: $VID_MP4 + $AUD_M4A -> $BOOT_MP4 (-c copy, +faststart)"
    ffmpeg -hide_banner -y -i "$VID_MP4" -i "$AUD_M4A" -c copy -shortest \
      -movflags +faststart "$BOOT_MP4" >/dev/null 2>"$CLONE_DIR/ffmpeg-mux.log" ||
      br_die "mux failed (see $CLONE_DIR/ffmpeg-mux.log)"
  else
    br_log "no audio intermediate -> boot.mp4 is video-only"
    cp -f "$VID_MP4" "$BOOT_MP4"
  fi
  [ -s "$BOOT_MP4" ] || br_die "boot.mp4 empty (see $CLONE_DIR/ffmpeg-*.log + tap.log)"

  # 7. boot.json (partial; postprocess adds durationMs + sprite/vtt).
  write_boot_json >/dev/null
  br_log "wrote $BOOT_JSON"

  # 8. VERIFY (vmstate, mandatory framebuffer truth): loadvm golden -> screendump ->
  #    SSIM vs the poster; assert the seam is invisible.
  if [ "$BR_BOOT_KIND" = "vmstate" ]; then
    br_log "verify: loadvm golden -> screendump -> SSIM vs poster"
    br_hmp "$CLONE_QMP" "loadvm golden" >/dev/null || br_die "loadvm golden (verify) failed"
    sleep 1
    br_screendump "$CLONE_QMP" "$VERIFY_PNG" || br_die "verify screendump failed"
    local s
    s="$(br_ssim "$VERIFY_PNG" "$POSTER_PNG")"
    [ -z "$s" ] && s=0
    br_log "verify SSIM(golden-first-frame, poster)=$s (need >= 0.999)"
    python3 -c "import sys; sys.exit(0 if float('$s') >= 0.999 else 1)" ||
      br_die "INVARIANT VIOLATED: golden first frame != boot.mp4 last frame (SSIM $s). Do NOT publish."
    br_log "INVARIANT OK: seam is invisible."
  fi

  br_log "RECORD COMPLETE. Staged: $STAGE_DIR (boot.mp4, poster.jpg, boot.json)"
  br_log "next: postprocess-boot.sh $TILE  then  gen-boot-manifest.sh"
}

main
