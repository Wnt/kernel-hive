#!/usr/bin/env bash
# irix-record-boot.sh — COMBINED record+rebake boot video for the IRIX tile.
#
# RUN ON THE BOX as root, with streamhost@irix STOPPED. The IRIX exhibit is
# MAME (indy_4610), not QEMU: record-boot.sh's dbus tap and savevm/loadvm bake
# do not exist here. What DOES exist is the fb.shm framebuffer mapping the
# patched MAME publishes (wire format + seqlock read protocol:
# streamhost/streamhost/src/capture/shm.rs; python reader precedent:
# scripts/build-guests/irix/irix-bench/shmpng.py) and the (savestate, disk) golden
# that scripts/build-guests/irix/irix-savestate/bake-golden.sh captures inside a
# pause window.
#
# So the recording RIDES a bake. The sampler beside this script streams fb.shm
# as constant-canvas BGRA into the house §6.1 encode (params byte-for-byte from
# scripts/coldboot/record-boot.sh) while bake-golden.sh cold-boots the
# production configuration and freezes it at the login chooser. The clip's
# final frames and the instant-restore savestate are the SAME paused
# framebuffer, so the recorded-video -> live-stream seam is exact BY
# CONSTRUCTION — no SSIM tolerance, no re-shoot on drift. The ~120 s settle
# tail the bake sleeps before PAUSE is dead footage; trim-boot.sh removes it
# afterwards while keeping the final GOP verbatim, so the trimmed clip still
# ends on the exact savestate frame.
#
#   Usage: irix-record-boot.sh            (~8-10 min: ~340 s boot + 120 s settle)
#   Env:   RIG           dir holding the deployed bake rig (bake-golden.sh)
#                        [default /data/vms/soltest/irix-ss44/rig]
#          IRIX_SHM_TAP  the fb.shm sampler [default: sibling irix-shm-tap.py]
#          REC_CPUS / BAKE_CPUS  core pins [4,12 / 6,14] — disjoint on purpose:
#                        the encode must never steal the emulator's cores.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RIG="${RIG:-/data/vms/soltest/irix-ss44/rig}"
BAKE="$RIG/bake-golden.sh"
SAMPLER="${IRIX_SHM_TAP:-$HERE/irix-shm-tap.py}"
A="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
STAGE="${BOOTREC_STAGING_ROOT:-/data/vms/streamhost/boot-rec}/irix"
REC_CPUS="${REC_CPUS:-4,12}"
BAKE_CPUS="${BAKE_CPUS:-6,14}"
GEOM=1288x1024 # the emulated framebuffer once IRIX programs the VC2 (shm.rs)
FPS=30

say() { printf '%s %s\n' "$(date +%T)" "$*"; }
die() {
  echo "FATAL: $*" >&2
  exit 1
}

# ── preflight: refuse loudly, never work around ──────────────────────────────
# The bake owns the tile's tap networking + fb.shm path. Do NOT stop the
# service ourselves — someone may be mid-measurement (AGENTS.md).
if systemctl is-active --quiet streamhost@irix.service; then
  echo "streamhost@irix is ACTIVE — the bake needs the tap free. Stop it first:" >&2
  echo "  systemctl stop streamhost@irix.service" >&2
  exit 2
fi
if pgrep -f irix-shm-tap >/dev/null; then
  echo "a previous run's sampler is still alive:" >&2
  pgrep -af irix-shm-tap >&2
  echo "tear it down by ITS pidfile (/data/vms/soltest/irix-bootrec-*/sampler.pid) first." >&2
  exit 2
fi
command -v ffmpeg >/dev/null || die "ffmpeg not found"
python3 -c 'import numpy' 2>/dev/null || die "python3+numpy required (the sampler needs it)"
[ -f "$SAMPLER" ] || die "sampler not found: $SAMPLER"
[ -f "$BAKE" ] || die "bake-golden.sh not found: $BAKE (deploy scripts/build-guests/irix/irix-savestate/ there, or set RIG=)"

D="/data/vms/soltest/irix-bootrec-$(date +%s)"
CLONE="$D/clone" # becomes IRIX_BAKE_DIR — bake-golden.sh rm-rf's + creates it
FIFO="$D/video.fifo"
MP4="$D/boot_video.mp4"
mkdir -p "$D"

# ── teardown on EVERY exit — part of "done" (AGENTS.md) ──────────────────────
# sampler/ffmpeg are OUR helper children, not emulators: plain kill by THEIR
# pidfiles (the bake-golden.sh watchdog pattern), truncate for idempotence.
# The bake kills its own MAME through clone-guard on every exit; --keep keeps
# only the DIRECTORY — so the clone needs no killing here, only verification.
teardown() {
  local rc=$? pf pid
  for pf in "$D/sampler.pid" "$D/ffmpeg.pid" "$D/audcap.pid"; do
    [ -s "$pf" ] || continue
    pid="$(cat "$pf")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    : >"$pf"
  done
  # The audcap pidfile names the SUBSHELL; the paced python reader inside it
  # survives that kill (the launcher's O_RDWR holder keeps the fifo from ever
  # EOFing). Its argv carries this run's namespaced dir — kill it directly.
  pkill -f "$D/audio\.s16" 2>/dev/null # matches the reader's argv ($CLONE/audio.fifo does NOT contain $D/audio.fifo)
  # Prove the release: no sampler, and nothing (ffmpeg, clone MAME) whose argv
  # references this run's dir. $CLONE is under $D, so one pattern covers both.
  if pgrep -f "irix-shm-tap|$D/" >/dev/null; then
    echo "TEARDOWN INCOMPLETE — survivors:" >&2
    pgrep -af "irix-shm-tap|$D/" >&2
    [ "$rc" -eq 0 ] && rc=1
  else
    say "teardown: sampler+ffmpeg released via their pidfiles; pgrep clean (no sampler/ffmpeg/clone MAME survives)"
  fi
  exit "$rc"
}
trap teardown EXIT INT TERM

# ── recorder first, bake second: the pre-boot black lead-in belongs on tape ──
# Encode is the house §6.1 line from record-boot.sh (single video pipe — this
# tile has no audio path, hence -an), fed fixed-size BGRA through a fifo. The
# sampler polls for $CLONE/fb.shm (it does not exist until the bake's launcher
# starts MAME), emits black until the first valid frame, and takes tear-free
# seqlock reads per shm.rs (seq even + unchanged around the copy, bounded
# retries).
# || die: no `set -e` here, and a missing fifo would NOT fail the pipeline —
# the sampler's `>"$FIFO"` redirect would create a REGULAR file and write raw
# BGRA at ~158 MB/s for the whole ~9 min bake before [ -s "$MP4" ] finally
# noticed.
mkfifo "$FIFO" || die "mkfifo failed: $FIFO"
XPARAMS="keyint=15:min-keyint=15:no-scenecut=1:bframes=0:rc-lookahead=0"
nohup taskset -c "$REC_CPUS" ffmpeg -hide_banner -y \
  -f rawvideo -pixel_format bgra -video_size "$GEOM" -framerate "$FPS" -i "$FIFO" \
  -vf "format=yuv420p" -c:v libx264 -profile:v high -pix_fmt yuv420p \
  -preset veryfast -tune zerolatency -crf 18 -x264-params "$XPARAMS" \
  -an -movflags +faststart "$MP4" >"$D/ffmpeg.log" 2>&1 &
echo $! >"$D/ffmpeg.pid"
nohup taskset -c "$REC_CPUS" python3 "$SAMPLER" "$CLONE/fb.shm" "$GEOM" "$FPS" \
  >"$FIFO" 2>"$D/sampler.log" &
echo $! >"$D/sampler.pid"
date +%s.%N >"$D/video_t0"
say "recorder up (sampler $(cat "$D/sampler.pid"), ffmpeg $(cat "$D/ffmpeg.pid")) -> $MP4"

# ── audio capture: the PROM chime is real PCM from the emulated HAL2 ─────────
# With the audio arm live (IRIX_AUDIO=on in tile.env), the bake's launcher
# creates $CLONE/audio.fifo and MAME's SDL disk driver writes S16LE 2ch 48k
# into it continuously from sound init. Here ffmpeg is the fifo's consumer (the
# daemon never attaches to a clone). Two-pipe house pattern (record-boot.sh
# measured a two-input ffmpeg starving at ~5 fps): capture raw beside the
# video, mux AFTER with a measured offset — audio starts when MAME does,
# seconds after the video's black lead-in, and the first-byte timestamp is
# that offset. bake-golden.sh rm-rf's $CLONE, so wait for the fifo to appear
# rather than pre-creating it.
# The reader MUST pace at exactly 192,000 B/s like the daemon does — SDL with
# SDL_DISKAUDIODELAY=0 never sleeps, so an unpaced reader (cat) lets it
# freewheel hold-fill padding ~166x realtime (measured: 14.9 GB / 21.6 h of
# PCM from one 470 s run). Pipe backpressure against this paced reader IS the
# clock, exactly as in streamhost's fifo source.
(
  until [ -p "$CLONE/audio.fifo" ]; do sleep 0.2; done
  python3 - "$CLONE/audio.fifo" "$D/audio.s16" "$D/audio_t0" <<'PY'
import sys
import time

fifo, out, t0f = sys.argv[1], sys.argv[2], sys.argv[3]
CHUNK, TICK = 3840, 0.02  # 20 ms of 48 kHz stereo s16 -> 192,000 B/s
with open(fifo, "rb") as f, open(out, "wb") as o:
    first = True
    deadline = time.monotonic()
    while True:
        buf = f.read(CHUNK)
        if not buf:
            break  # writer gone (MAME killed at bake teardown)
        if first:
            open(t0f, "w").write(f"{time.time():.6f}\n")
            first = False
        o.write(buf)
        deadline += TICK
        delay = deadline - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        elif delay < -0.25:
            deadline = time.monotonic()  # stall: resnap, never burst
PY
) >/dev/null 2>&1 &
echo $! >"$D/audcap.pid"

# ── the bake IS the boot driver ──────────────────────────────────────────────
say "running the bake (cold boot ~340 s, settle, PAUSE + SAVEST, install)"
if ! IRIX_BAKE_DIR="$CLONE" bash "$BAKE" --state golden --cpus "$BAKE_CPUS" --keep \
  2>&1 | tee "$D/bake.log"; then
  echo "BLOCKED: bake-golden.sh failed — nothing staged. Tail of $D/bake.log:" >&2
  tail -n 25 "$D/bake.log" >&2
  exit 1
fi

# ── stop the take a hair AFTER the freeze: MAME is paused (then stopped), so
# the sampler is duplicating the exact savestate frame — those dup frames are
# the final GOP that trim-boot.sh preserves verbatim.
sleep 2
kill "$(cat "$D/sampler.pid")" 2>/dev/null || true
: >"$D/sampler.pid" # sampler exit closes the fifo -> ffmpeg reads EOF
wait "$(cat "$D/ffmpeg.pid")" 2>/dev/null || true
: >"$D/ffmpeg.pid" # EOF finalized the moov (+faststart rewrite)
[ -s "$MP4" ] || die "recorder produced no video (see $D/ffmpeg.log + $D/sampler.log)"

# ── audio finalize + mux (skip cleanly if the audio arm was off) ─────────────
# The bake killed MAME, so the fifo writer is gone; stop the capture helper and
# mux if PCM arrived. Offset = first-PCM-byte wall time minus video-start wall
# time: SDL opens the fifo at MAME sound init, seconds into the video's black
# lead-in, and both clocks are this host's. -c copy on both streams; -shortest
# ends the track at the (longer) video's end.
HASAUDIO=0
if [ -s "$D/audio.s16" ] && [ -s "$D/audio_t0" ]; then
  kill "$(cat "$D/audcap.pid")" 2>/dev/null || true
  : >"$D/audcap.pid"
  OFF=$(awk -v a="$(cat "$D/audio_t0")" -v v="$(cat "$D/video_t0")" \
    'BEGIN { o = a - v; if (o < 0) o = 0; printf "%.3f", o }')
  ffmpeg -hide_banner -y -f s16le -ar 48000 -ac 2 -i "$D/audio.s16" \
    -c:a aac -b:a 128000 "$D/audio.m4a" >>"$D/ffmpeg.log" 2>&1 ||
    die "audio encode failed (see $D/ffmpeg.log)"
  ffmpeg -hide_banner -y -i "$MP4" -itsoffset "$OFF" -i "$D/audio.m4a" \
    -map 0:v -map 1:a -c copy -shortest -movflags +faststart "$D/boot_av.mp4" \
    >>"$D/ffmpeg.log" 2>&1 || die "A/V mux failed (see $D/ffmpeg.log)"
  MP4="$D/boot_av.mp4"
  HASAUDIO=1
  say "audio muxed: offset ${OFF}s, $(du -h "$D/audio.s16" | cut -f1) raw PCM"
else
  say "no PCM captured (audio arm off?) — staging video-only"
fi

# ── seam frames: the clip's true last frame, plus the settled poster ─────────
ffmpeg -hide_banner -y -sseof -0.3 -i "$MP4" -update 1 "$D/last.png" \
  >/dev/null 2>&1 || die "last-frame extract failed"
POSTER_SRC="$D/last.png"
[ -s "$CLONE/boot.png" ] && POSTER_SRC="$CLONE/boot.png" # bake's chooser shot

# ── stage (conventions: record-boot.sh; downstream stages are file-only) ─────
mkdir -p "$STAGE"
cp -f "$MP4" "$STAGE/boot.mp4" || die "staging boot.mp4 failed" # no set -e: check explicitly
ffmpeg -hide_banner -y -i "$POSTER_SRC" -qscale:v 3 "$STAGE/poster.jpg" \
  >/dev/null 2>&1 || die "poster.jpg failed"

# boot.json (house schema of record-boot.sh write_boot_json; durationMs is
# filled by postprocess-boot.sh). goldenSha binds the clip to the EXACT state
# this run installed: the provenance file already md5-binds (MAME binary,
# .sta, .chd), so its sha256 is the identity of the whole bundle.
PROV="$A/state/provenance-golden.md5"
[ -s "$PROV" ] || die "bake reported success but $PROV is missing"
GSHA="$(sha256sum "$PROV" | awk '{print $1}')"
python3 - "$STAGE/boot.json" "$GSHA" "$HASAUDIO" <<'PY'
import datetime
import json
import sys

out, gsha = sys.argv[1], sys.argv[2]
hasaudio = sys.argv[3] == "1"
doc = {
    "id": "irix",
    "mp4": "boot.mp4",
    "poster": "poster.jpg",
    "sprite": "sprite.jpg",
    "vtt": "thumbs.vtt",
    "width": 1288,
    "height": 1024,
    "hasAudio": hasaudio,
    "bakedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "goldenSha": gsha,
    "bootKind": "relaunch",
    "detect": {
        "tier": 3,
        "note": "combined record+rebake: video final GOP == savestate frame "
        "by construction (same pause window)",
    },
}
json.dump(doc, open(out, "w"), indent=2)
PY
say "staged: $STAGE (boot.mp4, poster.jpg, boot.json)"

cat <<EOF

NEXT STEPS (printed, not run):
  1. bash $HERE/postprocess-boot.sh irix     # sprite.jpg + thumbs.vtt + durationMs
  2. bash $HERE/trim-boot.sh $STAGE          # drop the settle tail (final GOP kept verbatim)
  3. WEBROOT=<spa-webroot> bash $HERE/gen-boot-manifest.sh irix
  4. systemctl start streamhost@irix.service # tile relaunches on the freshly baked golden
  5. seam check (framebuffer truth): grab the restarted tile's first frame
     (labctl shot irix /tmp/irix-live.png) and compare:
       source $HERE/bootrec-lib.sh && br_ssim $D/last.png /tmp/irix-live.png
     — expect ~1.0: the restored state IS the frame the clip ends on.
Artifacts kept for inspection: $D (bake.log, sampler.log, ffmpeg.log, last.png, clone/)
EOF
say "RECORD+REBAKE COMPLETE"
