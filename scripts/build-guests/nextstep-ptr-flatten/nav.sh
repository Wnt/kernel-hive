#!/bin/bash
# nav.sh X Y [click|dblclick] — home the cursor, feed-forward to (X,Y), act, shoot.
# shellcheck disable=SC2086  # $FLAT/$D/$E/$TAG are unquoted on purpose (optional flags, no spaces)
# shellcheck source=/dev/null  # box-only rig library, not in the repo
source /data/vms/soltest/NSPTR-flatten-accel/lib.sh
TX=$1
TY=$2
ACT=${3:-none}
TAG=${4:-nav}
FLAT=${FLAT:-}
x "for i in \$(seq 1 30); do echo \"-63 -63 20000\"; done | relmove" >/dev/null 2>&1
sleep 0.6
shot "$TAG-ref"
PLAN=$(python3 $D/plan.py "$TX" "$TY" 40000 $FLAT)
x "cat <<'P' | relmove
$PLAN
P" >/dev/null 2>&1
sleep 0.6
shot "$TAG-at"
printf 'target=(%s,%s) ' "$TX" "$TY"
python3 $D/fa.py track $D/cursor.npz $E/$TAG-ref.ppm $E/$TAG-at.ppm 0 0
case "$ACT" in
  click)
    x "xdotool click 1" >/dev/null 2>&1
    sleep 1.2
    shot "$TAG-after"
    ;;
  dblclick)
    x "xdotool click 1; sleep 0.12; xdotool click 1" >/dev/null 2>&1
    sleep 2.5
    shot "$TAG-after"
    ;;
esac
