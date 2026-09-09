#!/usr/bin/env bash
# wave.sh — the coordination a parallel station wave used to need a human for.
#
# WHY. Nine waves ran in parallel on 2026-09-03. One coordinator session sent
# ~150 messages in ~9 hours and almost all of them were two mechanical jobs:
# handing each wave its shared numbers (slot / UDP / VMID / X-warp display /
# retronet address + MAC + UIN), and serialising the main-push windows
# ("ready to land <id>" -> "go <id>" -> "landed <id>"). Both are locks with a
# queue. This is that tool; the coordinator keeps only what a tool cannot do —
# relaying findings between waves and the two single-run fleet steps.
#
# usage:
#   wave.sh alloc <id> [--retronet] [--x11warp] [--dry-run]
#   wave.sh land begin <id> [--timeout-min N] [--poll SECS]
#   wave.sh land end   <id> [--force]
#   wave.sh land status
#   wave.sh status
#
# alloc  ONE atomic allocation of everything the wave shares, all of it claimed
#        through kh-claim under $KH_SESSION. Prints a markdown ledger row and
#        writes ./.wave.env — the shell fragment the launcher, the fixture and
#        rn-onboard.sh source. Anything already held by another session is a
#        hard failure naming the holder (AGENTS.md rule 7), never a silent bump.
#        Idempotent for the same session; --retronet also writes the reservation
#        + RN_<ID>_MAC into the BOX-side registry/local.env and re-renders DHCP
#        in CT 951 (a local.env edit alone is NOT live).
#
# land   the landing window as one lock with a FIFO queue on the box, so no
#        coordinator has to issue "go". `begin` polls until the window is
#        yours, printing who holds it and for how long; `end` releases it;
#        `land status` shows holder + queue. Nothing sleeps on a guess — every
#        wait is a poll against real state (AGENTS.md rule 14).
#
# status every wave in flight in one view: the landing window and its queue,
#        claims grouped by session, and every branch pushed to origin in the
#        last KH_WAVE_STATUS_DAYS days (default 3) with whether that station
#        already has a registry row on main — i.e. whether it landed.
#
# env: KH_SESSION (scripts/lib/kh-session.sh) · LAB (ssh alias, default lab)
#      KH_WAVE_STATE_DIR — run the queue LOCALLY against this dir instead of
#      /run/kh-wave on the box. This is how tests/wave-queue-selftest.sh proves
#      the queue semantics with no box at all; never set it for real work.
# exit: 0 ok · 1 refused / timed out · 2 usage
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABRUN="$SCRIPT_DIR/labrun"
QUEUE_SH="$SCRIPT_DIR/wave.d/queue.sh"
ALLOC_SH="$SCRIPT_DIR/wave.d/alloc.sh"
BOX_STATE_DIR="${KH_WAVE_BOX_STATE_DIR:-/run/kh-wave}"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/kh-session.sh"

usage() {
  sed -n '11,17p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}
die() {
  printf 'wave: %s\n' "$*" >&2
  exit 1
}
step() { printf '\n== %s\n' "$*"; }

check_id() {
  case "${1:-}" in
    '' | *[!a-z0-9_-]*) die "bad station id '${1:-}' (want [a-z0-9_-])" ;;
  esac
}

# The queue runs either here (KH_WAVE_STATE_DIR: tests, no box) or on labhost
# (labrun ships the same bytes). One code path, two placements.
queue() {
  if [ -n "${KH_WAVE_STATE_DIR:-}" ]; then
    bash "$QUEUE_SH" "$KH_WAVE_STATE_DIR" "$@"
  else
    "$LABRUN" "$QUEUE_SH" "$BOX_STATE_DIR" "$@"
  fi
}

# ---------------------------------------------------------------- alloc ------
cmd_alloc() {
  local id="" rn=0 x11=0 apply=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --retronet) rn=1 ;;
      --x11warp) x11=1 ;;
      --dry-run) apply=0 ;;
      -h | --help) usage 0 ;;
      -*) die "unknown flag $1" ;;
      *) id="$1" ;;
    esac
    shift
  done
  check_id "$id"
  [ -n "${KH_WAVE_STATE_DIR:-}" ] && die "alloc needs the box; KH_WAVE_STATE_DIR is a queue-test override only"

  step "alloc $id (retronet=$rn x11warp=$x11 apply=$apply) as session $KH_SESSION"
  local out
  out="$("$LABRUN" "$ALLOC_SH" "$id" "$KH_SESSION" "$rn" "$x11" "$apply")" ||
    die "allocation refused — nothing was written; see the reason above"

  local envfile="$REPO_ROOT/.wave.env"
  {
    echo "# .wave.env — written by scripts/dev/wave.sh alloc $id on $(date -u +%FT%TZ)"
    echo "# Source it in the launcher, the fixture and rn-onboard.sh. Gitignored:"
    echo "# it carries the box's real retronet MAC (AGENTS.md rule 1)."
    printf '%s\n' "$out"
  } >"$envfile"
  # shellcheck disable=SC1090
  . "$envfile"

  step "ledger row (paste into the wave brief)"
  local rncell="—"
  [ "$rn" = 1 ] && rncell="${WAVE_RN_ADDRESS:-?} / \`${WAVE_RN_TAP:-?}\` / \`${WAVE_RN_CHAIN:-?}\` / UIN ${WAVE_RN_UIN:-?}"
  echo '| Station | Session | Slot / UDP / VMID | X-warp | retronet (addr / tap / chain / UIN) |'
  echo '|---|---|---|---|---|'
  printf '| %s | %s | %s / %s / %s | %s | %s |\n' \
    "$id" "$KH_SESSION" "${WAVE_SLOT:-?}" "${WAVE_UDP_PORT:-?}" "${WAVE_VMID:-?}" \
    "${WAVE_X11_DISPLAY:-—}${WAVE_X11_HOSTFWD:+ (}${WAVE_X11_HOSTFWD:-}${WAVE_X11_HOSTFWD:+)}" \
    "$rncell"
  echo
  echo "MAC is NOT in the ledger row on purpose: it lives in .wave.env and the"
  echo "box's registry/local.env only. Never paste it into a committed file."
  step "wrote $envfile"
  sed -n '4,$p' "$envfile" | sed 's/^/   /'
}

# ---------------------------------------------------------------- land -------
cmd_land() {
  local sub="${1:-}"
  shift 2>/dev/null || true
  case "$sub" in
    status) queue status ;;
    begin) land_begin "$@" ;;
    end) land_end "$@" ;;
    *) usage 2 ;;
  esac
}

land_begin() {
  local id="" timeout_min="${KH_WAVE_TIMEOUT_MIN:-45}" poll="${KH_WAVE_POLL:-20}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --timeout-min)
        timeout_min="$2"
        shift
        ;;
      --poll)
        poll="$2"
        shift
        ;;
      -*) die "unknown flag $1" ;;
      *) id="$1" ;;
    esac
    shift
  done
  check_id "$id"
  step "landing window: waiting for $id (session $KH_SESSION, timeout ${timeout_min}m)"
  local deadline last="" out rc
  deadline=$(($(date +%s) + timeout_min * 60))
  while :; do
    out="$(queue try "$KH_SESSION" "$id")"
    rc=$?
    case "$out" in
      ACQUIRED*)
        echo "$out"
        step "the window is YOURS — run the landing, then: wave.sh land end $id"
        return 0
        ;;
    esac
    [ "$rc" = 10 ] || {
      printf '%s\n' "$out" >&2
      die "queue error (rc=$rc)"
    }
    # Print only on a CHANGE: a 45-minute wait must not be 135 identical lines.
    [ "$out" != "$last" ] && printf '   %s  %s\n' "$(date -u +%H:%M:%SZ)" "$out"
    case "$out" in
      *STALE*) echo "   ^ that window is old — message its session before assuming it died (never --force blind)" ;;
    esac
    last="$out"
    if [ "$(date +%s)" -ge "$deadline" ]; then
      queue drop "$KH_SESSION" "$id" >/dev/null 2>&1 || true
      die "timed out after ${timeout_min}m — left the queue (re-run to rejoin at the back); 'wave.sh land status' says who holds it"
    fi
    sleep "$poll"
  done
}

land_end() {
  local id="" force=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=(--force) ;;
      -*) die "unknown flag $1" ;;
      *) id="$1" ;;
    esac
    shift
  done
  check_id "$id"
  queue end "$KH_SESSION" "$id" "${force[@]}" || die "the window was not released"
  step "released — the next wave in the queue acquires on its next poll"
}

# ---------------------------------------------------------------- status -----
cmd_status() {
  step "landing window"
  queue status || true

  step "claims by session (labhost)"
  if [ -n "${KH_WAVE_STATE_DIR:-}" ]; then
    echo "   (skipped: KH_WAVE_STATE_DIR is set — this is the off-box queue test mode)"
  else
    "$LABRUN" <<'EOF' || echo "   (labhost unreachable)"
kh-claim ls --all --json 2>/dev/null | python3 -c '
import collections, json, sys
by = collections.defaultdict(list)
for c in json.load(sys.stdin) or []:
    if c.get("state") == "stale":
        continue
    by[c.get("session", "?")].append("%s/%s" % (c.get("class"), c.get("name")))
for s in sorted(by):
    print("   %-24s %s" % (s, " ".join(sorted(by[s]))[:110]))
' || kh-claim ls
EOF
  fi

  # Branches accumulate for years, so "in flight" is dated, not alphabetical:
  # only branches pushed within KH_WAVE_STATUS_DAYS count, and each is marked
  # with whether that station already has a registry row on main (landed).
  local days="${KH_WAVE_STATUS_DAYS:-3}"
  step "branches pushed in the last $days day(s), and whether the station is on main"
  git -C "$REPO_ROOT" fetch -q origin 2>/dev/null || true
  local cutoff branch when id onmain
  cutoff=$(($(date +%s) - days * 86400))
  printf '   %-34s %-8s %s\n' branch age 'registry row on main'
  git -C "$REPO_ROOT" for-each-ref --sort=-committerdate \
    --format='%(refname:strip=3) %(committerdate:unix)' refs/remotes/origin 2>/dev/null |
    while read -r branch when; do
      [ "${when:-0}" -ge "$cutoff" ] || continue
      case "$branch" in main | HEAD) continue ;; esac
      id="${branch%%-*}"
      onmain='—'
      git -C "$REPO_ROOT" cat-file -e "origin/main:registry/stations/$id.json" 2>/dev/null &&
        onmain="yes ($id)"
      printf '   %-34s %-8s %s\n' "$branch" "$((($(date +%s) - when) / 3600))h" "$onmain"
    done
}

case "${1:-}" in
  alloc)
    shift
    cmd_alloc "$@"
    ;;
  land)
    shift
    cmd_land "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  -h | --help | '') usage 0 ;;
  *) usage 2 ;;
esac
