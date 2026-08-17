#!/usr/bin/env bash
# kh-claim — the labhost claim registry: "it exists" becomes "it is MINE".
#
# WHY. Shared things on labhost (sandbox dirs, Xvfb displays, VMIDs, ports,
# staging slots, the fleet itself) were claimed by check-then-create and owned
# by nobody a tool could name. Sessions then guessed ownership from
# /proc/<pid>/cwd, declined to reclaim leaked rigs for hours, stopped the
# fleet under another live session, and ran the same benchmark twice
# (docs/lab/research/workflow-friction-2026-08.md §1 items 3–4).
#
# MODEL. A claim is a directory /run/kh-claims/<class>/<name>, created with
# mkdir (atomic on one filesystem — the claim IS the proof), holding one
# `owner` file: session, pid (optional), host, purpose, ts. Classes are free
# text; the conventional ones are: sandbox display vmid port staging fleet.
# /run is tmpfs: a reboot kills every process and every claim together.
#
# RULES.
#   * take fails if the claim exists AND (its pid is alive OR it has no pid and
#     is younger than --stale-after, default 12h). --steal overrides, and says so.
#   * release only releases your own session's claim unless --force.
#   * gc removes claims whose pid is dead, and pid-less claims older than
#     --stale-after; prints what it removed. Never touches a live pid.
#   * ls / who are read-only.
#
# usage:
#   kh-claim take <class> <name> [--purpose TEXT] [--pid PID] [--steal]
#   kh-claim release <class> <name> [--force]
#   kh-claim ls [--all|--mine] [--json]
#   kh-claim who <class> <name>
#   kh-claim gc [--stale-after SECS] [--apply]
# env: KH_SESSION (required for take/release; kh-session.sh derives it)
# exit: 0 ok · 1 refused (held by someone else / not yours) · 2 usage
set -uo pipefail

ROOT="${KH_CLAIMS_ROOT:-/run/kh-claims}"
STALE_AFTER="${KH_CLAIM_STALE_AFTER:-43200}"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

need_session() {
  [ -n "${KH_SESSION:-}" ] || {
    echo "kh-claim: KH_SESSION is not set (source scripts/lib/kh-session.sh)" >&2
    exit 2
  }
}

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

read_owner() { # dir -> sets o_session o_pid o_purpose o_ts
  o_session="" o_pid="" o_purpose="" o_ts=""
  [ -f "$1/owner" ] || return 1
  # shellcheck disable=SC1090,SC1091
  . "$1/owner"
  o_session="${session:-}" o_pid="${pid:-}" o_purpose="${purpose:-}" o_ts="${ts:-0}"
}

is_stale() { # dir -> 0 if stale
  read_owner "$1" || return 0
  if [ -n "$o_pid" ]; then
    alive "$o_pid" && return 1
    return 0
  fi
  local now
  now=$(date +%s)
  [ $((now - o_ts)) -gt "$STALE_AFTER" ]
}

cmd_take() {
  need_session
  local class="$1" name="$2" purpose="" pid="" steal=0
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purpose)
        purpose="$2"
        shift
        ;;
      --pid)
        pid="$2"
        shift
        ;;
      --steal) steal=1 ;;
      *) usage 2 ;;
    esac
    shift
  done
  local dir="$ROOT/$class/$name"
  mkdir -p "$ROOT/$class"
  if mkdir "$dir" 2>/dev/null; then
    :
  else
    read_owner "$dir" || true
    if [ "$o_session" = "$KH_SESSION" ]; then
      echo "kh-claim: $class/$name already yours ($KH_SESSION)"
      return 0
    fi
    if [ "$steal" = 1 ] || is_stale "$dir"; then
      local why="stale"
      [ "$steal" = 1 ] && why="STOLEN"
      echo "kh-claim: $class/$name was held by ${o_session:-?} (pid ${o_pid:-none}, ${o_purpose:-}) — $why, taking over" >&2
      rm -rf "$dir" && mkdir "$dir" || {
        echo "kh-claim: could not take $class/$name" >&2
        return 1
      }
    else
      echo "kh-claim: REFUSED $class/$name — held by ${o_session:-?} (pid ${o_pid:-none}, ${o_purpose:-no purpose}) since $(date -d "@${o_ts:-0}" '+%F %T' 2>/dev/null)" >&2
      return 1
    fi
  fi
  printf 'session=%q\npid=%q\nhost=%q\npurpose=%q\nts=%s\n' \
    "$KH_SESSION" "$pid" "$(hostname -s)" "$purpose" "$(date +%s)" >"$dir/owner"
  echo "kh-claim: took $class/$name for $KH_SESSION"
}

cmd_release() {
  need_session
  local class="$1" name="$2" force=0
  shift 2
  [ "${1:-}" = "--force" ] && force=1
  local dir="$ROOT/$class/$name"
  [ -d "$dir" ] || {
    echo "kh-claim: $class/$name not claimed"
    return 0
  }
  read_owner "$dir" || true
  if [ "$o_session" != "$KH_SESSION" ] && [ "$force" != 1 ]; then
    echo "kh-claim: REFUSED release of $class/$name — held by ${o_session:-?}, not $KH_SESSION (use --force)" >&2
    return 1
  fi
  rm -rf "$dir" && echo "kh-claim: released $class/$name"
}

cmd_ls() {
  local mode=all json=0
  for a in "$@"; do
    case "$a" in
      --mine) mode=mine ;;
      --all) mode=all ;;
      --json) json=1 ;;
    esac
  done
  [ -d "$ROOT" ] || {
    [ "$json" = 1 ] && echo '[]'
    return 0
  }
  local d state first=1
  [ "$json" = 1 ] && printf '['
  for d in "$ROOT"/*/*; do
    [ -d "$d" ] || continue
    read_owner "$d" || continue
    [ "$mode" = mine ] && [ "$o_session" != "${KH_SESSION:-}" ] && continue
    if [ -n "$o_pid" ]; then
      alive "$o_pid" && state=live || state=dead
    else
      is_stale "$d" && state=stale || state=held
    fi
    local class name
    class="$(basename "$(dirname "$d")")"
    name="$(basename "$d")"
    if [ "$json" = 1 ]; then
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"class":"%s","name":"%s","session":"%s","pid":"%s","state":"%s","purpose":"%s","ts":%s}' \
        "$class" "$name" "$o_session" "$o_pid" "$state" "$o_purpose" "${o_ts:-0}"
    else
      printf '%-8s %-10s %-28s %-22s pid=%-8s %s  %s\n' "$state" "$class" "$name" "$o_session" "${o_pid:-none}" \
        "$(date -d "@${o_ts:-0}" '+%m-%d %H:%M' 2>/dev/null)" "$o_purpose"
    fi
  done
  [ "$json" = 1 ] && printf ']\n'
  return 0
}

cmd_who() {
  local dir="$ROOT/$1/$2"
  [ -d "$dir" ] || {
    echo "unclaimed"
    return 1
  }
  read_owner "$dir" || true
  echo "$o_session pid=${o_pid:-none} ${o_purpose:-}"
}

cmd_gc() {
  local apply=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) apply=1 ;;
      --stale-after)
        STALE_AFTER="$2"
        shift
        ;;
    esac
    shift
  done
  [ -d "$ROOT" ] || return 0
  local d n=0
  for d in "$ROOT"/*/*; do
    [ -d "$d" ] || continue
    is_stale "$d" || continue
    read_owner "$d" || true
    n=$((n + 1))
    if [ "$apply" = 1 ]; then
      rm -rf "$d" && echo "gc: removed ${d#"$ROOT"/} (was ${o_session:-?}, pid ${o_pid:-none})"
    else
      echo "gc: would remove ${d#"$ROOT"/} (was ${o_session:-?}, pid ${o_pid:-none})"
    fi
  done
  [ "$apply" = 1 ] || [ "$n" = 0 ] || echo "gc: $n stale claim(s); re-run with --apply"
}

cmd="${1:-}"
shift || true
case "$cmd" in
  take)
    [ "$#" -ge 2 ] || usage 2
    cmd_take "$@"
    ;;
  release)
    [ "$#" -ge 2 ] || usage 2
    cmd_release "$@"
    ;;
  ls) cmd_ls "$@" ;;
  who)
    [ "$#" -ge 2 ] || usage 2
    cmd_who "$@"
    ;;
  gc) cmd_gc "$@" ;;
  -h | --help | help | "") usage 0 ;;
  *) usage 2 ;;
esac
