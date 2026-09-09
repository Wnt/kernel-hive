#!/usr/bin/env bash
# wave.d/queue.sh — the landing-window lock and its FIFO queue, as pure state.
#
# WHY. Nine parallel station waves (2026-09-03) serialised their main pushes
# through a human: "ready to land <id>" -> "go <id>" -> "landed <id>". ~150
# coordinator messages in 9 hours, most of them this. A landing window is a
# lock with a queue; a lock with a queue is a tool, not a person.
#
# This file holds ONLY the state machine, so it can run two ways from the same
# bytes: shipped to labhost by `wave.sh` (via labrun) against /run/kh-wave, or
# locally against $KH_WAVE_STATE_DIR in tests/wave-queue-selftest.sh. It never
# calls ssh, never reads the registry, and needs no box.
#
# usage:  queue.sh <state-dir> try    <session> <id> [--stale-min N]
#         queue.sh <state-dir> end    <session> <id> [--force]
#         queue.sh <state-dir> drop   <session> <id>
#         queue.sh <state-dir> status
#
# `try` is ONE non-blocking attempt: it puts <session>/<id> in the queue if it
# is not already there, and acquires the window if that row is at the head and
# the window is free. The polling loop lives in wave.sh, client-side, so a
# dropped ssh cannot lose a window and each poll prints where you stand.
#
#   ACQUIRED  session=<s> id=<i> since=<epoch>            (exit 0)
#   HELD      session=<s> id=<i> since=<epoch> held_min=<n> pos=<n> [STALE] (exit 10)
#   WAITING   pos=<n> ahead=<s>/<i>                       (exit 10)
#
# THE LOCK. The window is one atomic `mkdir "$state/holder"` — the same
# primitive kh-claim is built on — because the FIFO file that decides WHO may
# take it lives in the same directory and must be updated under the same
# mutex. When `kh-claim` is on PATH the window is ALSO taken as
# `landing/window`, so `labctl who` and `here.sh` answer "who is landing?".
# That mirror is best-effort and never gates: the mkdir is the authority, and a
# mirror that disagrees prints a warning naming both.
#
# exit: 0 acquired / released / status ok · 10 not yours yet (try) · 1 refused
#       (end on a window you do not hold) · 2 usage
set -uo pipefail

state="${1:-}"
cmd="${2:-}"
[ -n "$state" ] && [ -n "$cmd" ] || {
  sed -n '13,17p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
shift 2

QUEUE_STALE_MIN="${KH_WAVE_QUEUE_STALE_MIN:-90}" # a waiter row older than this is pruned
HOLD_STALE_MIN="${KH_WAVE_HOLD_STALE_MIN:-25}"   # a window older than this earns a chase hint

holder="$state/holder"
owner="$holder/owner"
queue="$state/queue"
qlock="$state/qlock"

now() { date +%s; }
warn() { printf 'wave-queue: %s\n' "$*" >&2; }

# ---- the queue-file mutex ---------------------------------------------------
# Short-lived: every critical section below is a read + rewrite of one small
# file. A lock dir older than 60 s belonged to a killed process, so break it.
qlock_take() {
  local i
  for i in $(seq 1 100); do
    mkdir "$qlock" 2>/dev/null && return 0
    if [ -d "$qlock" ] && [ "$(($(now) - $(stat -c %Y "$qlock" 2>/dev/null || now)))" -gt 60 ]; then
      warn "breaking a stale qlock (older than 60s)"
      rmdir "$qlock" 2>/dev/null || true
    fi
    sleep 0.1
  done
  warn "could not take $qlock"
  return 1
}
qlock_free() { rmdir "$qlock" 2>/dev/null || true; }

# ---- kh-claim mirror (visibility only; the mkdir above is the authority) ----
mirror_take() {
  command -v kh-claim >/dev/null 2>&1 || return 0
  KH_SESSION="$1" kh-claim take landing window \
    --purpose "landing window: $1 / $2" >/dev/null 2>&1 ||
    warn "kh-claim landing/window not taken (held elsewhere?) — 'kh-claim who landing window'"
}
mirror_release() {
  command -v kh-claim >/dev/null 2>&1 || return 0
  KH_SESSION="$1" kh-claim release landing window >/dev/null 2>&1 || true
}

owner_field() { # owner_field <key> ; empty when there is no holder
  [ -f "$owner" ] || return 0
  sed -n "s/^$1=//p" "$owner" | head -1
}

# ---- queue file -------------------------------------------------------------
# One row per waiter: "<epoch> <session> <id>". Oldest first == FIFO. Rows
# older than QUEUE_STALE_MIN are dropped on every pass: a wave whose session
# died must not hold the head of the queue forever.
queue_prune() {
  local cutoff
  cutoff=$(($(now) - QUEUE_STALE_MIN * 60))
  [ -f "$queue" ] || return 0
  awk -v c="$cutoff" '$1 >= c' "$queue" >"$queue.new" && mv "$queue.new" "$queue"
}
queue_pos() { # queue_pos <session> <id> -> 1-based position, 0 when absent
  [ -f "$queue" ] || {
    echo 0
    return
  }
  awk -v s="$1" -v i="$2" '$2 == s && $3 == i { print NR; found = 1; exit }
    END { if (!found) print 0 }' "$queue"
}
queue_remove() {
  [ -f "$queue" ] || return 0
  awk -v s="$1" -v i="$2" '!($2 == s && $3 == i)' "$queue" >"$queue.new" &&
    mv "$queue.new" "$queue"
}

mkdir -p "$state"

case "$cmd" in
  try)
    session="${1:-}"
    id="${2:-}"
    [ -n "$session" ] && [ -n "$id" ] || {
      warn "try needs <session> <id>"
      exit 2
    }
    qlock_take || exit 1
    queue_prune
    # Idempotent for a re-run: already holding it is success, not a deadlock.
    if [ -d "$holder" ] && [ "$(owner_field session)" = "$session" ] && [ "$(owner_field id)" = "$id" ]; then
      queue_remove "$session" "$id"
      qlock_free
      echo "ACQUIRED session=$session id=$id since=$(owner_field ts)"
      exit 0
    fi
    pos="$(queue_pos "$session" "$id")"
    if [ "$pos" = 0 ]; then
      printf '%s %s %s\n' "$(now)" "$session" "$id" >>"$queue"
      pos="$(queue_pos "$session" "$id")"
    fi
    if [ -d "$holder" ]; then
      h_s="$(owner_field session)"
      h_i="$(owner_field id)"
      h_t="$(owner_field ts)"
      held_min=$((($(now) - ${h_t:-0}) / 60))
      stale=""
      [ "$held_min" -ge "$HOLD_STALE_MIN" ] && stale=" STALE"
      qlock_free
      echo "HELD session=$h_s id=$h_i since=${h_t:-0} held_min=$held_min pos=$pos$stale"
      exit 10
    fi
    if [ "$pos" != 1 ]; then
      ahead="$(awk 'NR==1 { print $2 "/" $3 }' "$queue")"
      qlock_free
      echo "WAITING pos=$pos ahead=$ahead"
      exit 10
    fi
    # Head of a free queue: the mkdir IS the acquisition.
    if ! mkdir "$holder" 2>/dev/null; then
      qlock_free
      echo "WAITING pos=$pos ahead=(window just taken)"
      exit 10
    fi
    ts="$(now)"
    {
      echo "session=$session"
      echo "id=$id"
      echo "ts=$ts"
      echo "host=$(hostname -s 2>/dev/null || echo '?')"
    } >"$owner"
    queue_remove "$session" "$id"
    qlock_free
    mirror_take "$session" "$id"
    echo "ACQUIRED session=$session id=$id since=$ts"
    ;;

  end)
    session="${1:-}"
    id="${2:-}"
    force=0
    shift 2 2>/dev/null || true
    for a in "$@"; do [ "$a" = --force ] && force=1; done
    [ -n "$session" ] && [ -n "$id" ] || {
      warn "end needs <session> <id>"
      exit 2
    }
    if [ ! -d "$holder" ]; then
      echo "FREE (nobody holds the landing window)"
      exit 0
    fi
    h_s="$(owner_field session)"
    h_i="$(owner_field id)"
    if [ "$h_s" != "$session" ] && [ "$force" = 0 ]; then
      warn "the window is held by $h_s / $h_i, not by $session — pass --force only after asking"
      exit 1
    fi
    mirror_release "$h_s"
    rm -f "$owner"
    rmdir "$holder" 2>/dev/null || rm -rf "$holder"
    echo "RELEASED session=$h_s id=$h_i by=$session"
    ;;

  drop)
    session="${1:-}"
    id="${2:-}"
    [ -n "$session" ] && [ -n "$id" ] || {
      warn "drop needs <session> <id>"
      exit 2
    }
    qlock_take || exit 1
    queue_remove "$session" "$id"
    qlock_free
    echo "DROPPED session=$session id=$id"
    ;;

  status)
    qlock_take || exit 1
    queue_prune
    qlock_free
    if [ -d "$holder" ]; then
      h_t="$(owner_field ts)"
      printf 'holder  %s / %s   held %d min (since %s)\n' \
        "$(owner_field session)" "$(owner_field id)" \
        "$((($(now) - ${h_t:-0}) / 60))" \
        "$(date -d "@${h_t:-0}" -u +%FT%TZ 2>/dev/null || echo "${h_t:-0}")"
      [ "$((($(now) - ${h_t:-0}) / 60))" -ge "$HOLD_STALE_MIN" ] &&
        printf '        ^ older than %s min — chase that session before assuming it died\n' "$HOLD_STALE_MIN"
    else
      echo "holder  (free)"
    fi
    if [ -s "$queue" ]; then
      echo "queue"
      awk -v n="$(now)" '{ printf "  %d. %-24s %-16s waiting %d min\n", NR, $2, $3, (n - $1) / 60 }' "$queue"
    else
      echo "queue   (empty)"
    fi
    ;;

  *)
    warn "unknown command '$cmd' (try|end|drop|status)"
    exit 2
    ;;
esac
