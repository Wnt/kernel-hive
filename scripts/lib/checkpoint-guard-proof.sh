#!/bin/bash
# checkpoint-guard-proof.sh — the FRAMEBUFFER PROOF half of checkpoint-guard.
#
# Split out of checkpoint-guard.sh when that file reached its hard size cap, and
# split HERE because this is the part that answers one question — "does this
# checkpoint actually restore?" — while the other file answers "what is safe to
# delete, and when". Rule 9 lives in this file.
#
# Sourced by the guard, not run on its own: every function below uses the
# guard's _cpg_qmp / _cpg_log / _cpg_err and its CPG_* settings. It is a
# box-sync pair for the same reason the guard is (see box-sync-pairs.sh).

# ---- declared exclusion rectangles ---------------------------------------------
# The idle-stability check (cpg_reference) is what stops a half-drawn golden, and
# it stays. But a period-correct scene can be stable everywhere EXCEPT one region
# that animates forever -- www.apple.com's 1998 homepage carries a 37-frame
# animated GIF ticker, which is why `rhapsody` could not bake the thematically
# exact page at all and shipped www.wired.com until this existed. A MASK narrows
# the area compared.
#
# It never widens what is allowed to move: the masked pixels are CROPPED OUT and
# not compared, rather than blanked in both frames -- blanking would make the
# region match perfectly and inflate a whole-frame SSIM, buying slack for the
# rest of the picture. The remaining area faces the same CPG_SSIM_MIN as always.
# Rules, reasoning and the declaration form: scripts/lib/cpg-mask.py.
CPG_MASK="${CPG_MASK:-}"
CPG_MASK_MAX_FRACTION="${CPG_MASK_MAX_FRACTION:-0.25}"
CPG_MASK_RECORD_NAME=".checkpoint-mask.json"

_cpg_mask_py() {
  local here candidate
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  for candidate in "$here/cpg-mask.py" /usr/local/lib/cpg-mask.py \
    /data/kernel-hive/scripts/lib/cpg-mask.py; do
    [ -f "$candidate" ] && {
      printf '%s' "$candidate"
      return 0
    }
  done
  _cpg_err "cpg-mask.py not found beside the guard, in /usr/local/lib or /data/kernel-hive"
  return 2
}

# Resolve the station's mask and REFUSE a bad one before anything is captured.
# DECLARED, never inferred: there is deliberately no "ignore whatever moves"
# mode, which would delete this check rather than narrow it. station.env is the
# declared home (it is deployed from the committed fixture, so the exemption is
# reviewable); $CPG_MASK is the ad-hoc override for clone work, and the two are
# told apart everywhere the mask is shown so nobody mistakes an experiment for a
# declaration.
cpg_mask_load() {
  CPG_MASK_DECL=""
  CPG_MASK_SOURCE=""
  if [ -n "$CPG_MASK" ]; then
    CPG_MASK_DECL="$CPG_MASK"
    CPG_MASK_SOURCE="env (ad-hoc)"
  elif [ -f "$ST_DIR/station.env" ]; then
    CPG_MASK_DECL="$(sed -n 's/^[[:space:]]*CPG_MASK=["'"'"']\{0,1\}\(.*\)$/\1/p' \
      "$ST_DIR/station.env" | head -1 | sed 's/["'"'"']*[[:space:]]*$//')"
    [ -n "$CPG_MASK_DECL" ] && CPG_MASK_SOURCE="station.env (declared)"
  fi
  [ -n "$CPG_MASK_DECL" ] || return 0
  local py
  py="$(_cpg_mask_py)" || return $?
  python3 "$py" --max-fraction "$CPG_MASK_MAX_FRACTION" \
    validate --mask "$CPG_MASK_DECL" >/dev/null || return 5
  _cpg_log "MASK ACTIVE from $CPG_MASK_SOURCE — these rectangles are EXCLUDED from every framebuffer comparison in this run:"
  python3 "$py" describe --mask "$CPG_MASK_DECL" >&2
  _cpg_log "the rest of the frame is held to the SAME threshold ($CPG_SSIM_MIN)."
}

# Everything the mask is, as one JSON line for the journal and the record.
cpg_mask_json() {
  [ -n "${CPG_MASK_DECL:-}" ] || {
    printf 'null'
    return 0
  }
  local py rects
  py="$(_cpg_mask_py)" || return $?
  rects="$(python3 "$py" validate --mask "$CPG_MASK_DECL" 2>/dev/null)" || rects='[]'
  printf '{"source": "%s", "declaration": "%s", "rects": %s}' \
    "$CPG_MASK_SOURCE" "$(printf '%s' "$CPG_MASK_DECL" | sed 's/["\\]/\\&/g')" "$rects"
}

# Record the mask NEXT TO THE CHECKPOINT, not only in the run journal: `prune`
# consumes the journal, and an exemption that disappears with the paperwork is an
# invisible exemption. Written on promote; REMOVED by a maskless recapture, so it
# can never over-claim for a golden baked without one.
cpg_mask_record() {
  local rec="$ST_DIR/$CPG_MASK_RECORD_NAME"
  if [ -z "${CPG_MASK_DECL:-}" ]; then
    rm -f "$rec"
    return 0
  fi
  printf '{"label": "%s", "ts": "%s", "session": "%s", "ssim_min": "%s", "mask": %s}\n' \
    "$CPG_LABEL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${KH_SESSION:-unknown}" \
    "$CPG_SSIM_MIN" "$(cpg_mask_json)" >"$rec"
  _cpg_log "MASK RECORDED with the checkpoint: $rec"
}

# What `checkpoint-guard status` prints. Loud on purpose.
cpg_mask_status() {
  local rec="$ST_DIR/$CPG_MASK_RECORD_NAME"
  if [ -n "${CPG_MASK_DECL:-}" ]; then
    printf 'mask       ACTIVE, from %s\n' "$CPG_MASK_SOURCE"
    python3 "$(_cpg_mask_py)" describe --mask "$CPG_MASK_DECL" 2>/dev/null
  else
    printf 'mask       none declared (full-frame stability check)\n'
  fi
  if [ -f "$rec" ]; then
    printf 'mask-baked THIS CHECKPOINT WAS BAKED WITH A REGION EXCLUDED:\n'
    sed 's/^/    /' "$rec"
  fi
}

# ---- framebuffer comparison ----------------------------------------------------
# Byte-identical first, then SSIM >= CPG_SSIM_MIN — the same two-step and threshold
# checkpoint-verify.sh uses. A pure byte compare refuses on every text-mode station with
# a blinking cursor, and a guard that refuses on healthy stations gets loosened.
_cpg_same() {
  # Record byte-identical as such: otherwise CPG_LAST_SSIM keeps the PREVIOUS
  # comparison's value and the success line reports a byte-perfect restore with a
  # failing-looking SSIM, which teaches people to ignore the number.
  if cmp -s "$1" "$2"; then
    CPG_LAST_SSIM="1.0 (byte-identical)"
    return 0
  fi
  # With a mask, the comparison is the area-weighted mean of ffmpeg's OWN SSIM
  # over the tiles left after the declared rectangles are cropped away -- the
  # same engine and the same threshold, applied to a smaller area.
  if [ -n "${CPG_MASK_DECL:-}" ]; then
    local out rc py
    py="$(_cpg_mask_py)" || exit 2
    out="$(python3 "$py" --max-fraction "$CPG_MASK_MAX_FRACTION" \
      check "$1" "$2" --mask "$CPG_MASK_DECL" --min "$CPG_SSIM_MIN" 2>&1)"
    rc=$?
    CPG_LAST_SSIM="$(printf '%s' "$out" | tail -1)"
    # rc 0 = same, 1 = different. ANYTHING ELSE is a broken comparison, and a
    # broken comparison must not be read as "the framebuffer moved" -- that is
    # exactly the reading that would let an unproven restore through.
    if [ "$rc" -gt 1 ]; then
      _cpg_err "the masked framebuffer comparison FAILED to run (exit $rc): $out. Refusing to guess whether these frames match. Nothing of '$CPG_LABEL' has been deleted; finish with 'checkpoint-guard resume $STATION' or clear with 'prune'."
      exit 7
    fi
    return "$rc"
  fi
  local ssim
  ssim="$(ffmpeg -hide_banner -nostats -i "$1" -i "$2" \
    -lavfi '[0:v]format=gray[x];[1:v]format=gray[y];[x][y]ssim' \
    -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1)"
  [ -n "$ssim" ] || ssim=0
  CPG_LAST_SSIM="$ssim"
  python3 -c "import sys; sys.exit(0 if float('$ssim') >= float('$CPG_SSIM_MIN') else 1)"
}

# ---- the framebuffer proof -----------------------------------------------------
# cpg_reference <ref.ppm> — a reference the restore can be compared against AT ALL. Two
# shots CPG_IDLE_SECONDS apart must agree: against a moving framebuffer (a clock, a
# spinner) "restored != reference" would mean nothing.
cpg_reference() {
  local ref="$1" second="$1.b"
  _cpg_qmp shot "$ref" >/dev/null || {
    _cpg_err "could not screendump the reference framebuffer"
    return 7
  }
  sleep "$CPG_IDLE_SECONDS"
  _cpg_qmp shot "$second" >/dev/null
  if ! _cpg_same "$ref" "$second"; then
    rm -f "$second"
    _cpg_err "this station's idle framebuffer is not stable (two shots ${CPG_IDLE_SECONDS}s apart differ, SSIM ${CPG_LAST_SSIM:-?} < $CPG_SSIM_MIN${CPG_MASK_DECL:+, WITH the declared mask already excluded}), so no comparison could prove a restore. Park the scene (hide the clock, settle the animation), or -- if one known region animates forever and the rest of the scene is genuinely still -- declare it with CPG_MASK (scripts/lib/cpg-mask.py). Nothing has been captured or deleted."
    return 7
  fi
  rm -f "$second"
  _cpg_log "reference framebuffer captured and idle-deterministic"
}

# cpg_prove_label <label> <ref.ppm> <dirty.ppm> <restored.ppm>
# Dirty the guest so the framebuffer demonstrably moves, load the label, and require
# the framebuffer back at the reference AND the guest RUNNING. Logs are not proof.
cpg_prove_label() {
  local label="$1" ref="$2" dirty="$3" restored="$4" st
  _cpg_qmp type "$CPG_DIRTY_TEXT" >/dev/null 2>&1
  sleep 1
  _cpg_qmp shot "$dirty" >/dev/null
  if _cpg_same "$ref" "$dirty"; then
    _cpg_qmp key tab sleep 0.3 key esc >/dev/null 2>&1
    sleep 1
    _cpg_qmp shot "$dirty" >/dev/null
  fi
  # Typing needs KEYBOARD FOCUS, a per-guest AND per-scene property the guard
  # cannot assume (sunos414 is click-to-focus: 0 px moved). NOT a built-in mouse
  # wiggle — a cursor move scores SSIM 0.999756 vs CPG_SSIM_MIN, i.e. "unchanged".
  if [ -n "$CPG_DIRTY_CMD" ] && _cpg_same "$ref" "$dirty"; then
    _cpg_log "typing did not move this guest; running CPG_DIRTY_CMD"
    (eval "$CPG_DIRTY_CMD") >/dev/null 2>&1 || _cpg_log "CPG_DIRTY_CMD exited non-zero; the framebuffer check decides"
    sleep 1
    _cpg_qmp shot "$dirty" >/dev/null
  fi
  if _cpg_same "$ref" "$dirty"; then
    _cpg_err "the guest's framebuffer did not move, so a matching 'restored' shot would prove NOTHING. Set CPG_DIRTY_TEXT to something this guest types, or CPG_DIRTY_CMD to a command that visibly changes ITS framebuffer (docs/lab/checkpoint-guard.md, 'When typing cannot dirty the guest'). Note the bar is SSIM < $CPG_SSIM_MIN: moving the mouse cursor alone is NOT enough. Nothing of '$CPG_LABEL' has been deleted."
    return 7
  fi
  _cpg_log "framebuffer moved off the reference — the restore proof can now mean something"

  if ! _cpg_qmp loadvm "$label" >/dev/null; then
    _cpg_err "loadvm $label FAILED — the checkpoint does not restore. Nothing of '$CPG_LABEL' has been deleted."
    return 7
  fi
  sleep "$CPG_SETTLE"
  st="$(_cpg_status)"
  if [ "$st" != "running" ]; then
    _cpg_err "loadvm $label restored a guest whose status is '$st', not running. A checkpoint captured while stopped restores PAUSED: the screenshot looks perfect and the station is dead to every visitor. Treating '$label' as UNPROVEN; nothing of '$CPG_LABEL' has been deleted."
    return 7
  fi
  _cpg_qmp shot "$restored" >/dev/null
  if ! _cpg_same "$ref" "$restored"; then
    _cpg_err "loadvm $label restored a framebuffer that does NOT match the reference (SSIM ${CPG_LAST_SSIM:-?} < $CPG_SSIM_MIN; $restored vs $ref). Treating '$label' as UNPROVEN; nothing of '$CPG_LABEL' has been deleted."
    return 7
  fi
  _cpg_log "PROVEN on the framebuffer: loadvm $label returns to the reference (SSIM ${CPG_LAST_SSIM:-1.0}), guest running"
  return 0
}
