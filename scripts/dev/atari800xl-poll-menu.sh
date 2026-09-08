#!/bin/bash
# poll SHOT with distinct filenames every INTERVAL s until the frame matches
# the known-good reference menu PNG size class (or MAXN iterations), printing
# elapsed time. Bounded loop, no open sleep.
set -x
RIG=/data/vms/sandbox/atari800xl-golden/rig
CTLPY=/data/vms/sandbox/atari800xl-golden/repo/scripts/dev/atari800xl-ctl.py
SOCK="$RIG/ctl.sock"
N="${1:-40}"
IVAL="${2:-1}"
T0=$(date +%s.%N)
for i in $(seq 1 "$N"); do
  OUT="$RIG/poll_$i.png"
  python3 "$CTLPY" "$SOCK" SHOT "$OUT"
  SZ=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
  NOW=$(date +%s.%N)
  EL=$(python3 -c "print($NOW-$T0)")
  echo "POLL $i elapsed=$EL size=$SZ"
  sleep "$IVAL"
done
python3 "$CTLPY" "$SOCK" PING
