#!/bin/bash
# sweep.sh S N T_us [tag] — home the NeXT cursor into the top-left clamp, then
# issue N relative events of (S,0) spaced T_us apart, and read the landed
# cursor position off the framebuffer.
# shellcheck disable=SC2086  # $FLAT/$D/$E/$TAG are unquoted on purpose (optional flags, no spaces)
# shellcheck source=/dev/null  # box-only rig library, not in the repo
source /data/vms/sandbox/NSPTR-flatten-accel/lib.sh
S=$1
N=$2
T=$3
TAG=${4:-sw-$S-$N-$T}
x "for i in \$(seq 1 30); do echo \"-63 -63 20000\"; done | relmove" >/dev/null 2>&1
sleep 0.8
shot "$TAG-ref"
x "for i in \$(seq 1 $N); do echo \"$S 0 $T\"; done | relmove" >/dev/null 2>&1
sleep 0.8
shot "$TAG"
printf 'S=%-3s N=%-4s T=%-7s commanded=%-5s ' "$S" "$N" "$T" "$((S * N))"
python3 $D/fa.py track $D/cursor.npz $E/$TAG-ref.ppm $E/$TAG.ppm 0 0
