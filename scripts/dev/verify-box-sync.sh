#!/usr/bin/env bash
# verify-box-sync.sh — MD5-gate every documented repo/live labhost mirror.
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
# registry/README.md). A handful of labhost copies are DEPLOYED with the real
# values substituted in, so a naive md5 compare marks them drifted forever.
# Those pairs are declared `scrub`: the labhost-side hash is taken AFTER reversing
# the substitution (real value -> repo placeholder), on labhost, inside the one
# batched SSH session. Real values therefore never touch the wire in a hash,
# never land in a local temp file, and are never printed. With no
# registry/local.env (a fresh public clone) scrubbed pairs report UNCHECKED —
# they never silently pass and never spuriously fail.
#
# Darklaunch awareness: a deliberate, additive, labhost-side overlay (a rig
# exposing rows from a git worktree) may DECLARE itself in
# $BOX_ROOT/serve/darklaunch.d/. A declared row is verified subtractively —
# box copy minus the declared ids must still match the repo — and reported
# DARKLAUNCH rather than DIFFERS, without failing the gate. A stale or
# unprovable declaration DOES fail it. See "darklaunch overlays" in
# scripts/lib/box-sync-pairs.sh.
#
# Usage: verify-box-sync.sh [--all] [--table]
#   (default)  only rows that need attention, grouped by kind, with counts
#   --all      every row, including MATCH
#   --table    machine-readable TSV:
#              status<TAB>label<TAB>repo_md5<TAB>box_md5<TAB>darklaunch-names
# Exit 0 when nothing needs attention (UNCHECKED and DARKLAUNCH rows do not
# fail the gate).
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
box_sync_darklaunch_load "$LAB" "$BOX_ROOT"

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
match=0 unchecked=0 dark=0
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
  # Darklaunch declarations cover exact-mode JSON pairs only.
  dl_names="${BOX_SYNC_DL_NAMES[${BOX_FILES[$i]}]:-}"
  [ "${MODES[$i]}" = exact ] || dl_names=""
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
    if [ -n "$dl_names" ]; then
      # Declared, yet the raw copies already agree: the declaration explains
      # nothing (rows gone, or committed since). A stale claim fails the gate.
      status=DARKLAUNCH_STALE
    else
      status=MATCH
      match=$((match + 1))
    fi
  elif [ -n "$dl_names" ]; then
    dl_md5="${BOX_SYNC_DL_MD5[${BOX_FILES[$i]}]}"
    if [ "${dl_md5#ERROR:}" != "$dl_md5" ]; then
      status=DARKLAUNCH_BROKEN
    elif [ "${BOX_SYNC_DL_FOUND[${BOX_FILES[$i]}]:-0}" -gt 0 ] &&
      [ "$dl_md5" = "$(box_sync_canon_json_md5 "$REPO/${REPO_FILES[$i]}")" ]; then
      status=DARKLAUNCH
      dark=$((dark + 1))
    else
      status=DIFFERS
    fi
  else
    status=DIFFERS
  fi
  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s' "$status" "${LABELS[$i]}" "$repo_md5" "$box_md5" "$dl_names")")
  case "$status" in MATCH | DARKLAUNCH | UNCHECKED*) ;; *) KIND_COUNT["$status"]=$((${KIND_COUNT["$status"]:-0} + 1)) ;; esac
done

# An unreadable declaration file names no pair row; surface it anyway — an
# invisible broken claim is the exact failure this ledger exists to prevent.
for path in "${!BOX_SYNC_DL_MD5[@]}"; do
  case "${BOX_SYNC_DL_MD5[$path]}" in ERROR:*) ;; *) continue ;; esac
  seen=0
  for i in "${!BOX_FILES[@]}"; do
    [ "${BOX_FILES[$i]}" = "$path" ] && seen=1
  done
  [ "$seen" = 1 ] && continue
  ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s' DARKLAUNCH_BROKEN "(declaration) $path" - - "${BOX_SYNC_DL_NAMES[$path]}")")
  KIND_COUNT[DARKLAUNCH_BROKEN]=$((${KIND_COUNT[DARKLAUNCH_BROKEN]:-0} + 1))
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
  local n="${KIND_COUNT[$1]:-0}" row lb dn
  [ "$n" -gt 0 ] || return 0
  printf '\n%s (%d)\n  %s\n' "$1" "$n" "$2"
  for row in "${ROWS[@]}"; do
    case "$row" in
      "$1"$'\t'*)
        lb="$(printf '%s' "$row" | cut -f2)"
        dn="$(printf '%s' "$row" | cut -f5)"
        printf '    %s%s\n' "$lb" "${dn:+   [$dn]}"
        ;;
    esac
  done
}

if [ "$show_all" = 1 ]; then
  printf '%-46s %-34s %-34s %s\n' PAIR REPO_MD5 BOX_MD5 STATUS
  for row in "${ROWS[@]}"; do
    IFS=$'\t' read -r st lb rm bm dn <<<"$row"
    printf '%-46s %-34s %-34s %s\n' "$lb" "$rm" "$bm" "$st${dn:+ [$dn]}"
  done
fi

print_group DIFFERS 'content differs — decide which side is authoritative, then sync that way'
print_group DARKLAUNCH_STALE 'declared in serve/darklaunch.d but the ids are not overlaid (withdrawn by hand, or committed since) — remove or refresh the declaration'
print_group DARKLAUNCH_BROKEN 'a darklaunch declaration that cannot be proven (unreadable, wrong kind, target unparseable) — fix or remove it; the row blocks until then'
print_group MISSING_ON_BOX 'in the repo, never mirrored to the box — deploy it, or drop the pair'
print_group MISSING_IN_REPO 'box-only (stale or scratch) — delete on the box, or adopt deliberately'
print_group MISSING_BOTH 'the pair definition itself is wrong or obsolete — fix the path or drop it'

if [ "$dark" -gt 0 ]; then
  printf '\nDARKLAUNCH (%d)\n  declared additive overlay (serve/darklaunch.d), verified: the box copy minus\n  the declared ids matches the repo — deliberate divergence, does not block.\n' "$dark"
  for row in "${ROWS[@]}"; do
    case "$row" in
      DARKLAUNCH$'\t'*)
        printf '    %s   [%s]\n' "$(printf '%s' "$row" | cut -f2)" "$(printf '%s' "$row" | cut -f5)"
        ;;
    esac
  done
fi

if [ "$unchecked" -gt 0 ]; then
  printf '\nUNCHECKED (%d)\n  scrubbed pairs need registry/local.env to reverse the substitution;\n  copy registry/local.env.example and fill it in to check these.\n' "$unchecked"
fi

printf '\nsummary: %d MATCH, %d DARKLAUNCH, %d need attention, %d unchecked, %d pairs\n' \
  "$match" "$dark" "$drift" "$unchecked" "$total"
[ "$drift" -eq 0 ] || printf 'remediation: scripts/dev/verify-box-sync.sh --all   (full table)\n'
[ "$drift" -eq 0 ]
