#!/usr/bin/env bash
# load-guard.sh — refuse to pile another guest onto a saturated labhost.
#
# Sourced by rig-clone.sh and smoke-rig.sh before either brings a guest up.
# Rule: labhost's 1-min load average (`cut -d' ' -f1 /proc/loadavg`) over
# KH_LOAD_CAP (default 50) refuses the start; --force (parsed by the caller,
# passed in as force=1) skips the check. KH_LOADAVG_CMD overrides how the
# load line is fetched, so a test can fake it without the box:
#
#   KH_LOADAVG_CMD="echo '99.0 0.0 0.0 1/200 12345'" load_guard_check demo 0
#
# usage: load_guard_check <label> <force:0|1>
#   label — what is about to start, printed in the refusal/ok line
#   force — 1 skips the load check entirely (the caller already saw --force)
# Returns 0 to proceed, 1 to refuse. Prints the load and the rule either way.

load_guard_check() {
  local label="$1" force="${2:-0}"
  local cap="${KH_LOAD_CAP:-50}"
  local cmd="${KH_LOADAVG_CMD:-cat /proc/loadavg}"
  local raw load

  if [ "$force" = 1 ]; then
    raw="$(eval "$cmd" 2>/dev/null)" || raw="(unreadable)"
    load="$(printf '%s\n' "$raw" | cut -d' ' -f1)"
    echo "load-guard: load=${load:-?} cap=$cap — --force given, starting $label anyway"
    return 0
  fi

  raw="$(eval "$cmd" 2>/dev/null)" || {
    echo "load-guard: could not read the load average ('$cmd' failed) — refusing to guess; pass --force to skip the check" >&2
    return 1
  }
  load="$(printf '%s\n' "$raw" | cut -d' ' -f1)"
  case "$load" in
    '' | *[!0-9.]*)
      echo "load-guard: unparsable load average '$raw' from '$cmd' — refusing to guess; pass --force to skip the check" >&2
      return 1
      ;;
  esac

  if awk -v l="$load" -v c="$cap" 'BEGIN { exit !(l > c) }'; then
    echo "load-guard: labhost 1-min load $load exceeds KH_LOAD_CAP=$cap — refusing to start $label (rule: don't start a new guest on a saturated box; pass --force to override)" >&2
    return 1
  fi

  echo "load-guard: load=$load cap=$cap — ok to start $label"
  return 0
}
