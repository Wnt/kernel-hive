#!/usr/bin/env bash
# verify-box-sync.sh — MD5-gate every documented repo/live box mirror.
#
# The pair table, the secret guard and the scrub map moved to the sourceable
# scripts/lib/box-sync-pairs.sh so that the RECONCILE half —
# scripts/dev/box-sync-push.sh — reads exactly the same rows and the same
# substitution map this gate reads. A pair that can be verified one way and
# pushed another is the bug that tool exists to prevent. This file is now the
# detector only: it classifies and reports, and writes nothing anywhere.
#
# Placeholder awareness (the reason this gate can be green at all):
# this repo is scrubbed for public release — the operator's real LAN IP and
# public hostnames live ONLY in gitignored registry/local.env, and tracked
# files carry RFC 5737 / RFC 2606 placeholders instead (see AGENTS.md and
# registry/README.md). A handful of box copies are DEPLOYED with the real
# values substituted in, so a naive md5 compare marks them drifted forever.
# Those pairs are declared `scrub`: the box-side hash is taken AFTER reversing
# the substitution (real value -> repo placeholder), on the box, inside the one
# batched SSH session. Real values therefore never touch the wire in a hash,
# never land in a local temp file, and are never printed. With no
# registry/local.env (a fresh public clone) scrubbed pairs report UNCHECKED —
# they never silently pass and never spuriously fail.
#
# Usage: verify-box-sync.sh [--all] [--table]
#   (default)  only rows that need attention, grouped by kind, with counts
#   --all      every row, including MATCH
#   --table    machine-readable TSV: status<TAB>label<TAB>repo_md5<TAB>box_md5
# Exit 0 when nothing needs attention (UNCHECKED rows do not fail the gate).
set -euo pipefail

LAB="${LAB:-lab}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BOX_SYNC_REPO_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
BOX_ROOT="${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}"

show_all=0 table=0
for arg in "$@"; do
  case "$arg" in
    --all) show_all=1 ;;
    --table) table=1 ;;
    -h | --help)
      printf 'usage: verify-box-sync.sh [--all] [--table]\n'
      printf '  (default)  only rows needing attention, grouped by kind\n'
      printf '  --all      every row, including MATCH\n'
      printf '  --table    TSV: status<TAB>label<TAB>repo_md5<TAB>box_md5\n'
      exit 0
      ;;
    *)
      printf 'verify-box-sync: unknown argument %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR_LIB="$(cd "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR_LIB/box-sync-pairs.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

box_sync_scrub_init "$REPO"
box_sync_load_pairs "$REPO" "$BOX_ROOT" "$LAB" "$tmpdir"

LABELS=("${BOX_SYNC_LABELS[@]}") REPO_FILES=("${BOX_SYNC_REPO_FILES[@]}")
BOX_FILES=("${BOX_SYNC_BOX_FILES[@]}") MODES=("${BOX_SYNC_MODES[@]}")
canon_prog="$BOX_SYNC_CANON_PROG" sed_prog="$BOX_SYNC_REVERSE_PROG"
scrub_ready="$BOX_SYNC_SCRUB_READY"

lines=()
for i in "${!LABELS[@]}"; do
  mode="${MODES[$i]}"
  [ "$mode" = scrub ] && [ "$scrub_ready" = 0 ] && mode=skip
  lines+=("$(printf '%s\t%s' "$mode" "${BOX_FILES[$i]}")")
done
mapfile -t BOX_MD5 < <(printf '%s\n' "$sed_prog" "${lines[@]}" |
  ssh -o ConnectTimeout=15 "$LAB" "$BOX_SYNC_REMOTE_HASH")

[ "${#BOX_MD5[@]}" -eq "${#BOX_FILES[@]}" ] || {
  printf 'verify-box-sync: incomplete remote hash response\n' >&2
  exit 2
}

# --- classify --------------------------------------------------------------
declare -a ROWS=()
match=0 unchecked=0
declare -A KIND_COUNT=()
for i in "${!LABELS[@]}"; do
  if [ ! -f "$REPO/${REPO_FILES[$i]}" ]; then
    repo_md5=MISSING
  elif [ "${MODES[$i]}" = scrub ]; then
    repo_md5="$(sed -e "$canon_prog" -- "$REPO/${REPO_FILES[$i]}" | md5sum | awk '{print $1}')"
  else
    repo_md5="$(md5sum -- "$REPO/${REPO_FILES[$i]}" | awk '{print $1}')"
  fi
  box_md5="${BOX_MD5[$i]}"
  if [ "${MODES[$i]}" = scrub ] && [ "$scrub_ready" = 0 ]; then
    status='UNCHECKED (no local.env)'
    unchecked=$((unchecked + 1))
  elif [ "$repo_md5" = MISSING ] && [ "$box_md5" = MISSING ]; then
    status=MISSING_BOTH
  elif [ "$repo_md5" = MISSING ]; then
    status=MISSING_IN_REPO
  elif [ "$box_md5" = MISSING ]; then
    status=MISSING_ON_BOX
  elif [ "$repo_md5" = "$box_md5" ]; then
    status=MATCH
    match=$((match + 1))
  else
    status=DIFFERS
  fi
  ROWS+=("$(printf '%s\t%s\t%s\t%s' "$status" "${LABELS[$i]}" "$repo_md5" "$box_md5")")
  case "$status" in MATCH | UNCHECKED*) ;; *) KIND_COUNT["$status"]=$((${KIND_COUNT["$status"]:-0} + 1)) ;; esac
done

drift=0
for k in "${!KIND_COUNT[@]}"; do drift=$((drift + KIND_COUNT[$k])); done
total="${#LABELS[@]}"

if [ "$table" = 1 ]; then
  printf '%s\n' "${ROWS[@]}"
  [ "$drift" -eq 0 ] && exit 0
  exit 1
fi

print_group() { # $1 status, $2 heading
  local n="${KIND_COUNT[$1]:-0}" row
  [ "$n" -gt 0 ] || return 0
  printf '\n%s (%d)\n  %s\n' "$1" "$n" "$2"
  for row in "${ROWS[@]}"; do
    case "$row" in "$1"$'\t'*) printf '    %s\n' "$(printf '%s' "$row" | cut -f2)" ;; esac
  done
}

if [ "$show_all" = 1 ]; then
  printf '%-46s %-34s %-34s %s\n' PAIR REPO_MD5 BOX_MD5 STATUS
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r st lb rm bm <<<"$row"
    printf '%-46s %-34s %-34s %s\n' "$lb" "$rm" "$bm" "$st"
  done
fi

print_group DIFFERS 'content differs — decide which side is authoritative, then sync that way'
print_group MISSING_ON_BOX 'in the repo, never mirrored to the box — deploy it, or drop the pair'
print_group MISSING_IN_REPO 'box-only (stale or scratch) — delete on the box, or adopt deliberately'
print_group MISSING_BOTH 'the pair definition itself is wrong or obsolete — fix the path or drop it'

if [ "$unchecked" -gt 0 ]; then
  printf '\nUNCHECKED (%d)\n  scrubbed pairs need registry/local.env to reverse the substitution;\n  copy registry/local.env.example and fill it in to check these.\n' "$unchecked"
fi

printf '\nsummary: %d MATCH, %d need attention, %d unchecked, %d pairs\n' \
  "$match" "$drift" "$unchecked" "$total"
[ "$drift" -eq 0 ] || printf 'remediation: scripts/dev/verify-box-sync.sh --all   (full table)\n'
[ "$drift" -eq 0 ]
