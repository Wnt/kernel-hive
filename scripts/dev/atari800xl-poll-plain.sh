#!/bin/bash
set -x
RIG=/data/vms/sandbox/atari800xl-golden/rig
CTLPY=/data/vms/sandbox/atari800xl-golden/repo/scripts/dev/atari800xl-ctl.py
SOCK="$RIG/ctl.sock"
N="${1:-16}"
IVAL="${2:-1.5}"
NAME="${3:-poll}"
T0=$(date +%s.%N)
for i in $(seq 1 "$N"); do
  OUT="$RIG/${NAME}_$i.png"
  python3 "$CTLPY" "$SOCK" SHOT "$OUT"
  SZ=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
  NOW=$(date +%s.%N)
  EL=$(python3 -c "print($NOW-$T0)")
  echo "POLL $i elapsed=$EL size=$SZ"
  sleep "$IVAL"
done
