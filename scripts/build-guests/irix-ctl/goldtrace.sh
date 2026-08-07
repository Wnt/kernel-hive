#!/usr/bin/env bash
# goldtrace.sh — issue #45 golden-trace differential harness, orchestration face.
#
# Records the production-shaped command corpus (goldtrace-corpus.txt) against
# ONE arm on an ALREADY-RUNNING clone, or diffs two recorded traces:
#
#   goldtrace.sh record lua /data/vms/soltest/<rig>/cloneA lua.jsonl
#   goldtrace.sh record ctl /data/vms/soltest/<rig>/cloneB ctl.jsonl
#   goldtrace.sh compare lua.jsonl ctl.jsonl
#   goldtrace.sh corpus            # print the corpus path in use
#
# The lua arm needs NO mamectl module in the binary — record (and validate)
# the corpus before the module ever builds. The ctl arm talks mamectl/1 on
# <clone-dir>/ctl.sock. Parity gate (Stage-0, binding): bug-for-bug — the
# deterministic (300,500) chooser give-up settling at ~(186,386) must
# REPRODUCE in both arms, and the giveups delta must match (3 over the
# default corpus). Fixing the give-up is out of parity scope.
#
# This script NEVER launches or stops clones. The operator prepares each
# clone identically (same patched binary, same golden, same cold-boot-or-
# restore recipe; clone-guard rules) and runs one `record` per arm. Extra
# flags after the fixed args pass through to the python tool verbatim
# (e.g. `record ... --require-fresh`, `compare ... --strict-soft`).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CORPUS=${GOLDTRACE_CORPUS:-$HERE/goldtrace-corpus.txt}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

die() {
  echo "goldtrace: $*" >&2
  exit 2
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  corpus)
    echo "$CORPUS"
    ;;
  record)
    arm=${1:-}
    dir=${2:-}
    out=${3:-}
    { [ -n "$arm" ] && [ -n "$dir" ] && [ -n "$out" ]; } || usage
    shift 3
    case "$arm" in
      lua | ctl) ;;
      *) usage ;;
    esac
    [ -d "$dir" ] || die "no such clone dir: $dir"
    fb="$dir/fb.shm"
    [ -f "$fb" ] || die "$fb missing (IRIX_CAPTURE=shm clone required)"
    magic=$(head -c4 "$fb")
    [ "$magic" = "IFB1" ] || die "$fb has no IFB1 header (MAME not publishing?)"
    if [ "$arm" = lua ]; then
      cmdfile="$dir/irix_cmd"
      if [ ! -e "$cmdfile" ]; then
        echo "goldtrace: creating $cmdfile (the agent picks it up on its next tick)" >&2
        : >"$cmdfile"
      elif [ -s "$cmdfile" ]; then
        echo "goldtrace: WARNING: $cmdfile is nonempty — not a fresh session, so the" >&2
        echo "goldtrace: post-restore-first-MOVEA corpus case is void (--require-fresh hard-fails)" >&2
      fi
    else
      sock="$dir/ctl.sock"
      [ -S "$sock" ] || die "$sock is not a unix socket (module built + MAME_CTL_SOCK set?)"
    fi
    [ -f "$CORPUS" ] || die "corpus not found: $CORPUS"
    python3 -c 'import numpy' 2>/dev/null || die "python3 numpy required on this host"
    exec python3 "$HERE/goldtrace-record.py" \
      --arm "$arm" --dir "$dir" --out "$out" --corpus "$CORPUS" "$@"
    ;;
  compare)
    a=${1:-}
    b=${2:-}
    { [ -n "$a" ] && [ -n "$b" ]; } || usage
    shift 2
    exec python3 "$HERE/goldtrace-compare.py" "$a" "$b" "$@"
    ;;
  *)
    usage
    ;;
esac
