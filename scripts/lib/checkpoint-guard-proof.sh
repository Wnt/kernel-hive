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
    _cpg_err "this station's idle framebuffer is not stable (two shots ${CPG_IDLE_SECONDS}s apart differ, SSIM ${CPG_LAST_SSIM:-?} < $CPG_SSIM_MIN), so no comparison could prove a restore. Park the scene (hide the clock, settle the animation) and re-run. Nothing has been captured or deleted."
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
