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
#   7 MIRROR      the kh-claim MIRROR of the landing window is a best-effort
#                 sidecar (docs/lab comment: "the mkdir is the authority, and a
#                 mirror that disagrees prints a warning naming both") — but
#                 `land end` must not tell the operator RELEASED while that
#                 mirror still shows the window held by someone else. This is
#                 the second path by which a completed landing leaves the
#                 window looking held: not station-land.sh re-homing it (fixed
#                 in 76f4af5b), but queue.sh's own mirror_take/mirror_release
#                 swallowing a REFUSED from kh-claim whenever the mirror was
#                 already wedged onto a stale/other session — which is exactly
#                 what a PRIOR occurrence of the first bug (or a hand release
#                 of only one of the two locks) leaves behind.
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

as wave-z land end echo --force >/dev/null 2>&1   # clear test 6's still-held window
bash "$Q" "$STATE" drop wave-f foxtrot >/dev/null # and its queued waiter

echo "== 7 MIRROR STAYS IN SYNC ACROSS take AND release"
# Put a REAL kh-claim on PATH (the actual lib, not a stub) so mirror_take /
# mirror_release in queue.sh exercise the genuine REFUSED/--force/--steal
# semantics, against an isolated claims root — never /run/kh-claims.
CLAIMS="$(mktemp -d)"
BIN="$(mktemp -d)"
ln -s "$HERE/../scripts/lib/kh-claim.sh" "$BIN/kh-claim"
export PATH="$BIN:$PATH"
export KH_CLAIMS_ROOT="$CLAIMS"
trap 'rm -rf "$STATE" "$CLAIMS" "$BIN"' EXIT

# Wedge the mirror onto a session that is neither the queue's next holder nor
# ever going to release it — the state a leaked re-home (76f4af5b) or a
# hand-fixed local lock (release_window only touching one side) leaves behind.
KH_SESSION=ghost-station-session bash "$HERE/../scripts/lib/kh-claim.sh" \
  take landing window --purpose "landing window: ghost-wave / golf" >/dev/null

out="$(as wave-g land begin golf --timeout-min 1)"
check "wave-g acquires the LOCAL window even though the mirror is wedged" \
  "ACQUIRED session=wave-g id=golf" "$out"

out="$(as wave-g land end golf)"
check "wave-g's land end reports released" "RELEASED session=wave-g id=golf" "$out"

mirror="$(KH_SESSION=wave-g bash "$HERE/../scripts/lib/kh-claim.sh" who landing window 2>&1)"
check "the kh-claim MIRROR agrees the window is free, not still ghost-station-session" \
  "unclaimed" "$mirror"

echo "== 8 land end SURVIVES set -e (the way labrun actually runs it)"
# labrun ships queue.sh and runs it under `set -euo pipefail`; this selftest
# runs under `set -uo pipefail`. That one missing -e hid a real regression:
# `kh-claim who` EXITS 1 when the resource is unclaimed, so an unguarded
# command substitution in mirror_release aborted the function before the
# holder dir was removed -- land end printed nothing, returned 1, and the
# window stayed held forever. Exercise the REAL execution mode, not a laxer one.
STATE8="$(mktemp -d)"
CLAIMS8="$(mktemp -d)"
KH_SESSION=wave-h bash "$Q" "$STATE8" try wave-h hotel --timeout-min 1 >/dev/null

# The mirror is deliberately already unclaimed -- the success case, and the
# exact condition whose non-zero exit killed the release.
out="$(KH_CLAIMS_ROOT="$CLAIMS8" KH_SESSION=wave-h \
  bash -euo pipefail "$Q" "$STATE8" end wave-h hotel 2>&1 || true)"
check "land end under set -e still reports RELEASED" \
  "RELEASED session=wave-h id=hotel" "$out"

if [ -d "$STATE8/holder" ]; then
  echo "  FAIL  the holder dir survived land end under set -e (window orphaned)"
  fails=$((fails + 1))
else
  echo "  PASS  the holder dir is gone after land end under set -e"
fi
rm -rf "$STATE8" "$CLAIMS8"

echo
if [ "$fails" = 0 ]; then
  echo "wave-queue-selftest: ALL PASS"
else
  echo "wave-queue-selftest: $fails FAILURE(S)"
fi
exit "$fails"
