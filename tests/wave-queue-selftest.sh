#!/usr/bin/env bash
# wave-queue-selftest.sh — proves the landing-queue semantics `wave.sh land`
# exists for, with NO box: it drives scripts/dev/wave.sh with
# KH_WAVE_STATE_DIR pointed at a temp dir, so the same bytes that run on
# labhost run here against local state.
#
#   tests/wave-queue-selftest.sh
#
#   1 ACQUIRE     a free window is taken by the first caller, and `land status`
#                 names the holder
#   2 EXCLUSION   a second session cannot take a held window; it queues instead
#   3 FIFO        two waiters acquire in the order they arrived, not the order
#                 they retried — and a released window goes to the head
#   4 TIMEOUT     `land begin --timeout-min 0` fails, and LEAVES THE QUEUE, so
#                 a dead waiter never blocks the head
#   5 IDEMPOTENT  the holder re-running `land begin` succeeds instead of
#                 deadlocking on itself; `land end` from a non-holder is refused
#   6 STALE       a window older than the stale threshold is flagged, not stolen
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAVE="$HERE/../scripts/dev/wave.sh"
STATE="$(mktemp -d)"
export KH_WAVE_STATE_DIR="$STATE"
export KH_WAVE_POLL=0
trap 'rm -rf "$STATE"' EXIT

fails=0
ok() { printf '  PASS  %s\n' "$*"; }
no() {
  printf '  FAIL  %s\n' "$*"
  fails=$((fails + 1))
}
check() { # check <label> <expected-substring> <actual>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)
      no "$1"
      printf '        wanted %s\n        got    %s\n' "$2" "$(printf '%s' "$3" | tr '\n' '|')"
      ;;
  esac
}
as() { # as <session> <wave.sh args...>
  local s="$1"
  shift
  KH_SESSION="$s" bash "$WAVE" "$@" 2>&1
}

echo "== 1 ACQUIRE"
out="$(as wave-a land begin alpha --timeout-min 1)"
check "wave-a takes a free window" "ACQUIRED session=wave-a id=alpha" "$out"
check "land status names the holder" "holder  wave-a / alpha" "$(as wave-a land status)"

echo "== 2 EXCLUSION"
out="$(as wave-b land begin bravo --timeout-min 0)"
check "wave-b is refused while wave-a holds" "HELD session=wave-a id=alpha" "$out"
check "wave-b is told it timed out, not that it won" "timed out" "$out"

echo "== 3 FIFO"
# Enqueue b then c through the raw engine (one non-blocking attempt each), so
# the order under test is arrival order, not who retried last.
Q="$HERE/../scripts/dev/wave.d/queue.sh"
bash "$Q" "$STATE" try wave-b bravo >/dev/null
bash "$Q" "$STATE" try wave-c charlie >/dev/null
check "wave-c is behind wave-b" "pos=2" "$(bash "$Q" "$STATE" try wave-c charlie)"
check "wave-a releases" "RELEASED session=wave-a id=alpha" "$(as wave-a land end alpha)"
check "wave-c still waits behind wave-b" "WAITING pos=2 ahead=wave-b/bravo" "$(bash "$Q" "$STATE" try wave-c charlie)"
check "wave-b, at the head, acquires" "ACQUIRED session=wave-b id=bravo" "$(as wave-b land begin bravo --timeout-min 1)"

echo "== 4 TIMEOUT LEAVES THE QUEUE"
out="$(as wave-d land begin delta --timeout-min 0)"
check "wave-d times out" "timed out" "$out"
check "wave-d is gone from the queue" "" "$(bash "$Q" "$STATE" status | grep -c wave-d)"
[ "$(bash "$Q" "$STATE" status | grep -c wave-d)" = 0 ] &&
  ok "a timed-out waiter does not block the head" ||
  no "a timed-out waiter is still queued"

echo "== 5 IDEMPOTENT / OWNERSHIP"
check "the holder re-running begin succeeds" "ACQUIRED session=wave-b id=bravo" "$(as wave-b land begin bravo --timeout-min 0)"
out="$(as wave-c land end bravo)"
check "a non-holder cannot end the window" "held by wave-b" "$out"
check "land end --force is the documented override" "RELEASED session=wave-b" "$(as wave-c land end bravo --force)"

echo "== 6 STALE IS FLAGGED, NOT STOLEN"
bash "$Q" "$STATE" drop wave-c charlie >/dev/null # clear the queue from test 3
check "wave-e takes the now-free window" "ACQUIRED session=wave-e" "$(as wave-e land begin echo --timeout-min 1)"
# backdate the holder by an hour
sed -i "s/^ts=.*/ts=$(($(date +%s) - 3600))/" "$STATE/holder/owner"
check "an old window is flagged STALE" "STALE" "$(bash "$Q" "$STATE" try wave-f foxtrot)"
check "and is still HELD, not handed over" "HELD session=wave-e" "$(bash "$Q" "$STATE" try wave-f foxtrot)"

echo
if [ "$fails" = 0 ]; then
  echo "wave-queue-selftest: ALL PASS"
else
  echo "wave-queue-selftest: $fails FAILURE(S)"
fi
exit "$fails"
