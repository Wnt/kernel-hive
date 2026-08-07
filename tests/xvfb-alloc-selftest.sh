#!/bin/bash
# xvfb-alloc-selftest.sh — proves the four properties scripts/lib/xvfb-alloc.sh
# exists for. Run it anywhere Xvfb is installed (the lab box, CT950); it only
# ever touches displays in its OWN range (default :200..:231, disjoint from the
# :64..:191 rig pool) and kills only pids it started.
#
#   tests/xvfb-alloc-selftest.sh [--min N] [--max N]
#
#   1 CONCURRENCY   several rigs started at once all get DISTINCT displays
#   2 COLLISION     a rig pinned to a taken display FAILS non-zero and does NOT
#                   attach to the incumbent (the old code's silent bug)
#   3 RELEASE       a rig that exits normally frees its display
#   4 RECLAIM       a rig killed with -9 leaves an orphan that is reported as
#                   such, reaped, and immediately reusable
set -u

LIB="${XVFB_ALLOC_LIB:-$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/xvfb-alloc.sh}"
MIN=200
MAX=231
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xvfb-selftest.XXXXXX")"
export XVFB_ALLOC_STATEDIR="$WORK/state"
FAILED=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  FAILED=1
}
# shellcheck disable=SC1090,SC1091 # resolved at run time (repo copy or /usr/local/bin)
source "$LIB"

# A rig: claims a display, records it, holds it, exits (releasing via the trap).
cat >"$WORK/rig.sh" <<EOF
#!/bin/bash
set -u
export XVFB_ALLOC_STATEDIR="$WORK/state"
source "$LIB"
xvfb_alloc --screen 64x64x24 --min "\$2" --max "\$3" --tag "rig\$1" \\
  --pidfile "$WORK/rig\$1.pid" --log "$WORK/rig\$1.log" || exit 1
echo "\$XVFB_DISPLAY" >"$WORK/rig\$1.disp"
sleep "\${4:-6}"
EOF
chmod +x "$WORK/rig.sh"

# ---- 1. concurrency --------------------------------------------------------
for i in 1 2 3 4 5 6; do bash "$WORK/rig.sh" "$i" "$MIN" "$MAX" 8 & done
sleep 5
got="$(cat "$WORK"/rig[1-6].disp 2>/dev/null | sort)"
uniq_n="$(printf '%s\n' "$got" | sort -u | grep -c .)"
n="$(printf '%s\n' "$got" | grep -c .)"
if [ "$n" = 6 ] && [ "$uniq_n" = 6 ]; then
  ok "concurrency: 6 rigs, 6 distinct displays: $(echo "$got" | tr '\n' ' ')"
else
  bad "concurrency: $n rigs reported, $uniq_n distinct: $(echo "$got" | tr '\n' ' ')"
fi

# ---- 2. induced collision --------------------------------------------------
victim="$(head -1 "$WORK/rig1.disp")"
vnum="${victim#:}"
vpid="$(cat "$WORK/rig1.pid")"
out="$(bash "$WORK/rig.sh" 9 "$vnum" "$vnum" 2 2>&1)"
rc=$?
still="$(_xa_ownerpid "$vnum")"
if [ "$rc" -ne 0 ] && [ ! -f "$WORK/rig9.disp" ] && [ "$still" = "$vpid" ]; then
  ok "collision on $victim: rig exited $rc, claimed nothing, incumbent pid $vpid untouched"
  printf '        message: %s\n' "$(printf '%s' "$out" | tail -1)"
else
  bad "collision on $victim: rc=$rc claimed=$(cat "$WORK/rig9.disp" 2>/dev/null) owner=$still (expected $vpid)"
fi

# ---- 3. release on exit ----------------------------------------------------
wait
sleep 1
leftover=""
for i in 1 2 3 4 5 6; do
  d="$(cat "$WORK/rig$i.disp" 2>/dev/null)" || continue
  [ -n "$(_xa_ownerpid "${d#:}")" ] && leftover="$leftover $d"
done
if [ -z "$leftover" ]; then
  ok "release: all 6 displays freed when their rigs exited"
else
  bad "release: still held after exit:$leftover"
fi

# ---- 4. reclaim after a crashed owner --------------------------------------
xvfb_alloc --screen 64x64x24 --min "$MIN" --max "$MAX" --tag crashrig \
  --pidfile "$WORK/crash.pid" --log "$WORK/crash.log" --no-trap || bad "reclaim: could not allocate"
cnum="$XVFB_DISPLAY_NUM"
kill -KILL "$XVFB_PID" 2>/dev/null
sleep 1
orphan="$(xvfb_reap --min "$MIN" --max "$MAX" | grep "orphan :$cnum" || true)"
xvfb_alloc --screen 64x64x24 --min "$cnum" --max "$cnum" --tag reclaimer \
  --pidfile "$WORK/reclaim.pid" --log "$WORK/reclaim.log" --no-trap
rc=$?
if [ -n "$orphan" ] && [ "$rc" = 0 ] && [ "$XVFB_DISPLAY_NUM" = "$cnum" ]; then
  ok "reclaim: :$cnum orphaned by kill -9, reported by reap, re-allocated cleanly"
else
  bad "reclaim: orphan='$orphan' realloc rc=$rc got=:$XVFB_DISPLAY_NUM (wanted :$cnum)"
fi
xvfb_release ":$cnum"
xvfb_reap --force --min "$MIN" --max "$MAX" >/dev/null # our range only

rm -rf -- "$WORK"
[ "$FAILED" = 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$FAILED"
