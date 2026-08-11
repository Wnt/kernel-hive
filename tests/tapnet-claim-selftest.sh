#!/bin/bash
# tapnet-claim-selftest.sh — proves the properties `tapnet.sh claim` exists for.
# Run as root on the lab box. It only ever touches taps in its OWN slot range
# (default 40..46, disjoint from the low slots a rig would take) and its own
# claim directory, so it is safe beside running clones.
#
#   tests/tapnet-claim-selftest.sh [--min N] [--max N]
#
#   1 CONCURRENCY   several claims fired at once all get DISTINCT slots, and
#                   every one of them comes up with a COMPLETE fail-closed
#                   ruleset (the xtables-lock race used to leave taps open)
#   2 SLOT 0        the production tile's slot is never handed out, and
#                   `release 0` is refused
#   3 RELEASE       a released slot leaves no tap, no chains and no claim
#   4 GC            a claim whose owner process is gone is reaped, and the slot
#                   is immediately reusable
set -u

TAPNET="${TAPNET_SH:-$(cd "$(dirname "$0")/.." && pwd)/streamhost/stations/irix/tapnet.sh}"
MIN=40
MAX=46
while [ "$#" -gt 0 ]; do
  case "$1" in
    --min)
      MIN="$2"
      shift 2
      ;;
    --max)
      MAX="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--min N] [--max N]" >&2
      exit 2
      ;;
  esac
done

[ "$(id -u)" = 0 ] || {
  echo "SKIP  needs root (creates taps and iptables chains)"
  exit 0
}
[ -f "$TAPNET" ] || {
  echo "FAIL  no tapnet.sh at $TAPNET"
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tapnet-selftest.XXXXXX")"
export IRIX_TAP_CLAIMS="$WORK/claims"
export IRIX_TAP_PREFIX="tnst"      # own namespace: tnst40, tnst41, ...
export IRIX_TAP_SLOT_NET=172.31.29 # own /24, never the tile's 172.31.20
export IRIX_TAP_SLOT_MAX="$MAX"
FAILED=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  FAILED=1
}

# shellcheck disable=SC2317 # runs from the EXIT trap
cleanup() {
  local d n
  for d in "$IRIX_TAP_CLAIMS"/*; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    bash "$TAPNET" release "$n" >/dev/null 2>&1 || true
  done
  for n in $(seq "$MIN" "$MAX"); do
    ip link show "$IRIX_TAP_PREFIX$n" >/dev/null 2>&1 &&
      bash "$TAPNET" release "$n" >/dev/null 2>&1
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

# The allocator starts at slot 1; this test wants its own range, so slots below
# MIN are pre-claimed with a live owner (this shell) and released at the end.
for n in $(seq 1 $((MIN - 1))); do
  mkdir -p "$IRIX_TAP_CLAIMS/$n"
  printf 'slot=%s\nif=%s%s\npid=%s\ntag=selftest-reserved\n' \
    "$n" "$IRIX_TAP_PREFIX" "$n" "$$" >"$IRIX_TAP_CLAIMS/$n/claim"
done

# --- 1 CONCURRENCY ----------------------------------------------------------
N=5
for i in $(seq 1 "$N"); do
  (bash "$TAPNET" claim "self$i" >"$WORK/c$i.out" 2>"$WORK/c$i.err") &
done
wait
slots="$(grep -h '^IRIX_TAP_SLOT=' "$WORK"/c*.out | cut -d= -f2 | sort -n)"
uniq_n="$(echo "$slots" | sort -u | grep -c .)"
got_n="$(echo "$slots" | grep -c .)"
if [ "$got_n" = "$N" ] && [ "$uniq_n" = "$N" ]; then
  ok "concurrency: $N simultaneous claims -> $uniq_n distinct slots"
else
  bad "concurrency: $got_n claims, $uniq_n distinct (want $N/$N)"
fi
rules_ok=1
for s in $slots; do
  ifn="$IRIX_TAP_PREFIX$s"
  g="$IRIX_TAP_SLOT_NET.$((4 * s + 2))"
  h="$IRIX_TAP_SLOT_NET.$((4 * s + 1))"
  all="$(iptables -w 15 -S)"
  for want in \
    "-A INPUT -i $ifn -j IRIXNET-IN-$ifn" \
    "-A FORWARD -j IRIXNET-FWD-$ifn" \
    "-A IRIXNET-FWD-$ifn -i $ifn -j DROP" \
    "-A IRIXNET-FWD-$ifn -o $ifn -j DROP" \
    "-A IRIXNET-IN-$ifn -s $g/32 -d $h/32 -j RETURN" \
    "-A IRIXNET-IN-$ifn -j DROP"; do
    grep -qx -- "$want" <<<"$all" || {
      rules_ok=0
      echo "      missing: $want"
    }
  done
done
[ "$rules_ok" = 1 ] &&
  ok "fail-closed: every concurrently claimed tap has a complete ruleset" ||
  bad "fail-closed: a concurrently claimed tap came up without its rules"

# --- 2 SLOT 0 ---------------------------------------------------------------
echo "$slots" | grep -qx 0 && bad "slot 0 was handed out" || ok "slot 0 never allocated"
if bash "$TAPNET" release 0 >/dev/null 2>&1; then
  bad "release 0 was accepted (the production tile's slot)"
else
  ok "release 0 refused"
fi

# --- 3 RELEASE --------------------------------------------------------------
first="$(echo "$slots" | head -1)"
bash "$TAPNET" release "$first" >/dev/null 2>&1
ifn="$IRIX_TAP_PREFIX$first"
if ip link show "$ifn" >/dev/null 2>&1 ||
  iptables -w 15 -S 2>/dev/null | grep -q -- "$ifn" ||
  [ -d "$IRIX_TAP_CLAIMS/$first" ]; then
  bad "release left a tap, a rule or a claim behind ($ifn)"
else
  ok "release: tap, chains and claim all gone"
fi

# --- 4 GC -------------------------------------------------------------------
second="$(echo "$slots" | sed -n 2p)"
sed -i 's/^pid=.*/pid=999999/' "$IRIX_TAP_CLAIMS/$second/claim" # an owner that cannot exist
bash "$TAPNET" gc >/dev/null 2>&1
if [ -d "$IRIX_TAP_CLAIMS/$second" ] || ip link show "$IRIX_TAP_PREFIX$second" >/dev/null 2>&1; then
  bad "gc did not reap the dead owner's slot $second"
else
  ok "gc reaped the dead owner's slot"
fi
out="$(bash "$TAPNET" claim reuse 2>/dev/null | grep '^IRIX_TAP_SLOT=' | cut -d= -f2)"
if [ -n "$out" ]; then
  ok "a reaped slot is immediately reusable (got slot $out)"
else
  bad "could not claim after gc"
fi

exit "$FAILED"
