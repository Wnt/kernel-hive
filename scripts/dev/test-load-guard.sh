#!/usr/bin/env bash
# test-load-guard.sh — assertions for scripts/lib/load-guard.sh, with no box
# and no real `uptime`/`/proc/loadavg`: every case fakes KH_LOADAVG_CMD.
# Exit 0 == every assertion green.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
. "$HERE/../lib/load-guard.sh"

fails=0

assert_ok() { # assert_ok <label> <expected-exit> -- <env assignments...>
  local label="$1" want="$2" out rc
  shift 2
  # shellcheck disable=SC2016  # single-quoted heredoc-of-a-string: expands inside the child bash, on purpose
  out="$(TEST_HERE="$HERE" TEST_LABEL="$label" env "$@" bash -c '
    set -euo pipefail
    # shellcheck disable=SC1091
    . "$TEST_HERE/../lib/load-guard.sh"
    load_guard_check "$TEST_LABEL" "${FORCE:-0}"
  ' 2>&1)" && rc=0 || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL: $label — exit $rc, wanted $want" >&2
    echo "$out" >&2
    fails=$((fails + 1))
  else
    echo "ok: $label (exit $rc)"
  fi
}

# under the default cap (50): allowed
assert_ok "under cap" 0 KH_LOADAVG_CMD="echo '1.23 0.9 0.5 1/200 999'"

# over the default cap: refused
assert_ok "over cap" 1 KH_LOADAVG_CMD="echo '87.5 40.0 20.0 3/400 999'"

# exactly at the cap: allowed (strictly-greater rule)
assert_ok "at cap" 0 KH_LOAD_CAP=50 KH_LOADAVG_CMD="echo '50 10 5 1/100 1'"

# a lower custom cap
assert_ok "custom cap refuses" 1 KH_LOAD_CAP=5 KH_LOADAVG_CMD="echo '6.0 1 1 1/1 1'"

# over cap but --force (FORCE=1) still proceeds
assert_ok "force overrides" 0 FORCE=1 KH_LOADAVG_CMD="echo '999 0 0 1/1 1'"

# the probe command itself fails
assert_ok "unreadable probe refuses" 1 KH_LOADAVG_CMD="false"

# the probe command returns garbage
assert_ok "garbage refuses" 1 KH_LOADAVG_CMD="echo 'not-a-number'"

if [ "$fails" -gt 0 ]; then
  echo "$fails assertion(s) failed" >&2
  exit 1
fi
echo "all load-guard assertions green"
