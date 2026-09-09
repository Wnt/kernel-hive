#!/usr/bin/env bash
# session-watchdog.sh — bring a background Claude session back to life from
# OUTSIDE the harness, when the harness itself is what stopped.
#
# WHY. On 2026-09-03 a five-hour usage limit paused all ten sessions of a
# nine-wave run together, for three hours. Everything inside the harness — the
# in-session heartbeat cron, queued peer messages — was paused with them, so
# nothing inside could restart anything. What worked was a crontab entry on
# CT950 that watched the session TRANSCRIPT's mtime and, when it went stale,
# typed a Resume prompt into a detached GNU screen running `claude attach
# <job>`. That kept the live process, its cron and its queued messages; only a
# genuinely dead process got `claude stop` + `claude --bg --resume <sid>`.
# This is that script (it was /home/wnt/.local/bin/kh-wave-watchdog.sh, with
# the job id, session id, memory file and prompt hard-coded), generalised.
#
# usage:
#   session-watchdog.sh install <job-id> <memory-file> [--sid SID]
#          [--stale-min N] [--every N] [--prompt TEXT | --prompt-file F]
#          [--done-marker TEXT] [--screen NAME]
#   session-watchdog.sh remove  <job-id>
#   session-watchdog.sh status  [<job-id>]
#   session-watchdog.sh tick    <job-id>     # what cron runs; also safe by hand
#
# STATES, per tick:
#   done     the memory file's first lines carry the done marker (default
#            "STATUS: DONE") -> uninstall the cron entry and the attach screen.
#   healthy  the transcript changed within --stale-min minutes. An idle but
#            alive session still refreshes it (its heartbeat cron fires a few
#            times an hour), so mtime is a real liveness signal.
#   stale    usage limit, crash, or a dead heartbeat -> route 1, else route 2.
#
# ROUTE 1 (preferred) types the prompt into `screen -S <name>` running `claude
# attach <job>`. The text and the Enter MUST be two separate `screen -X stuff`
# calls with a pause between: sent as one burst the terminal reads it as a
# paste and the Enter becomes a literal newline in the composer. If the usage
# limit is still in force the turn simply fails, the transcript stays stale,
# and the next tick types it again — which is why this is a cron, not a retry
# loop. ROUTE 2 (only when the job PROCESS is gone) is `claude stop` +
# `claude --bg --resume <sid>` with the same prompt.
#
# TRANSCRIPT PATHS MOVE. A session that enters a worktree gets a new project
# directory, so the transcript is found by GLOB across
# ~/.claude/projects/*/<sid>.jsonl — never by one remembered path. The original
# watchdog looked in the pre-worktree directory and never fired once during the
# three-hour pause it was installed for.
#
# Config per job lives in ~/.local/state/kh-session-watchdog/<job>.env; the log
# beside it as <job>.log. `install` is idempotent: re-running rewrites the
# config and leaves exactly one crontab line.
set -uo pipefail

STATE_DIR="${KH_WATCHDOG_STATE_DIR:-$HOME/.local/state/kh-session-watchdog}"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

die() {
  printf 'session-watchdog: %s\n' "$*" >&2
  exit 1
}
usage() {
  sed -n '17,25p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}
cfg_file() { printf '%s/%s.env\n' "$STATE_DIR" "$1"; }
log_file() { printf '%s/%s.log\n' "$STATE_DIR" "$1"; }
cron_tag() { printf 'kh-session-watchdog:%s' "$1"; }

# ------------------------------------------------------------------ install --
do_install() {
  local job="${1:-}" mem="${2:-}"
  shift 2 2>/dev/null || true
  [ -n "$job" ] && [ -n "$mem" ] || usage 2
  [ -f "$mem" ] || die "memory file not found: $mem"
  mem="$(readlink -f "$mem")"

  local sid="" stale=30 every=10 prompt="" marker="STATUS: DONE" screen_name="kh-attach-$job"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sid)
        sid="$2"
        shift
        ;;
      --stale-min)
        stale="$2"
        shift
        ;;
      --every)
        every="$2"
        shift
        ;;
      --prompt)
        prompt="$2"
        shift
        ;;
      --prompt-file)
        prompt="$(cat "$2")"
        shift
        ;;
      --done-marker)
        marker="$2"
        shift
        ;;
      --screen)
        screen_name="$2"
        shift
        ;;
      *) die "unknown flag $1" ;;
    esac
    shift
  done

  # The session id is what names the transcript; the job id names the process.
  # ~/.claude/jobs/<job>/state.json knows both, so it is the default source.
  if [ -z "$sid" ]; then
    sid="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
print(d.get("resumeSessionId") or d.get("sessionId") or "")
' "$HOME/.claude/jobs/$job/state.json" 2>/dev/null)"
  fi
  [ -n "$sid" ] || die "no session id: pass --sid (not in ~/.claude/jobs/$job/state.json)"

  [ -n "$prompt" ] || prompt="Wakeup from the OUTSIDE watchdog (session-watchdog.sh): this session's transcript was stale, so it was paused by the usage limit, crashed, or lost its heartbeat. Read $mem and run its Resume procedure now. Keep the user-facing message short."

  case "$SELF" in
    */worktrees/* | /data/vms/sandbox/*)
      echo "NOTE  this script lives in a worktree ($SELF)." >&2
      echo "      cron will keep calling that path — install from a checkout that outlives the wave" >&2
      echo "      (e.g. /data/kernel-hive/scripts/dev/session-watchdog.sh)." >&2
      ;;
  esac

  mkdir -p "$STATE_DIR"
  umask 077
  # Every value is %q-quoted: DONE_MARKER defaults to "STATUS: DONE", and a
  # bare `DONE_MARKER=STATUS: DONE` line makes the sourcing tick run `DONE`.
  {
    printf '# session-watchdog config for job %s — written %s\n' "$job" "$(date -u +%FT%TZ)"
    printf 'JOB=%q\nSID=%q\nMEM=%q\nSTALE_MIN=%q\nSCREEN_NAME=%q\nDONE_MARKER=%q\nPROMPT_B64=%q\n' \
      "$job" "$sid" "$mem" "$stale" "$screen_name" "$marker" \
      "$(printf '%s' "$prompt" | base64 -w0)"
  } >"$(cfg_file "$job")"
  local line
  line="*/$every * * * * $SELF tick $job >/dev/null 2>&1  # $(cron_tag "$job")"
  {
    crontab -l 2>/dev/null | grep -v "$(cron_tag "$job")"
    printf '%s\n' "$line"
  } | crontab - || die "could not write the crontab"
  echo "installed: every ${every} min, stale after ${stale} min"
  echo "  job     $job   sid $sid"
  echo "  memory  $mem   (a line starting '$marker' uninstalls this watchdog)"
  echo "  screen  $screen_name"
  echo "  log     $(log_file "$job")"
  echo "  prove it now:  $SELF tick $job  (add DRY_RUN=1 to see the route without typing)"
}

do_remove() {
  local job="${1:-}"
  [ -n "$job" ] || usage 2
  crontab -l 2>/dev/null | grep -v "$(cron_tag "$job")" | crontab - || true
  # shellcheck disable=SC1090
  [ -f "$(cfg_file "$job")" ] && . "$(cfg_file "$job")"
  screen -S "${SCREEN_NAME:-kh-attach-$job}" -X quit >/dev/null 2>&1 || true
  rm -f "$(cfg_file "$job")"
  echo "removed: cron entry, attach screen and config for job $job"
}

do_status() {
  local job="${1:-}"
  if [ -z "$job" ]; then
    crontab -l 2>/dev/null | grep 'kh-session-watchdog:' || echo "no watchdogs installed"
    return 0
  fi
  local cfg
  cfg="$(cfg_file "$job")"
  [ -f "$cfg" ] || die "no config for job $job ($cfg)"
  # shellcheck disable=SC1090
  . "$cfg"
  local t
  t="$(transcript_path "$SID")"
  printf 'job %s  sid %s\n' "$JOB" "$SID"
  printf '  transcript %s\n' "${t:-(none found under $HOME/.claude/projects)}"
  [ -n "$t" ] && printf '  age        %s min (stale at %s)\n' "$(age_min "$t")" "$STALE_MIN"
  printf '  screen     %s\n' "$(screen -ls 2>/dev/null | grep -c "\.${SCREEN_NAME}\b") session(s)"
  crontab -l 2>/dev/null | grep "$(cron_tag "$job")" || echo "  cron       MISSING"
  tail -n 5 "$(log_file "$job")" 2>/dev/null | sed 's/^/  log  /' || true
  return 0
}

# --------------------------------------------------------------------- tick --
transcript_path() { # newest ~/.claude/projects/*/<sid>.jsonl — the dir MOVES
  find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}
age_min() { echo "$((($(date +%s) - $(stat -c %Y "$1")) / 60))"; }

job_alive() { # the bg job is alive when `claude agents --json` gives a live pid
  local pid
  pid="$("$CLAUDE_BIN" agents --json 2>/dev/null | python3 -c '
import json, sys
for a in json.load(sys.stdin) or []:
    if a.get("id") == sys.argv[1]:
        print(a.get("pid", ""))
' "$1" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

ensure_attach_screen() {
  local name="$1" job="$2" i
  if ! screen -ls 2>/dev/null | grep -q "\.$name\b"; then
    wlog "starting attach screen $name"
    screen -dmS "$name" bash -lc "exec $CLAUDE_BIN attach $job"
    for i in $(seq 1 30); do
      pgrep -f "^$CLAUDE_BIN attach $job\$" >/dev/null 2>&1 && break
      sleep 1
    done
    sleep 8
  fi
  pgrep -f "^$CLAUDE_BIN attach $job\$" >/dev/null 2>&1
}

do_tick() {
  local job="${1:-}"
  [ -n "$job" ] || usage 2
  local cfg
  cfg="$(cfg_file "$job")"
  [ -f "$cfg" ] || die "no config for job $job — run 'install' first"
  # shellcheck disable=SC1090
  . "$cfg"
  LOG="$(log_file "$job")"
  local prompt
  prompt="$(printf '%s' "$PROMPT_B64" | base64 -d)"

  if head -40 "$MEM" 2>/dev/null | grep -q "^$DONE_MARKER"; then
    wlog "memory says '$DONE_MARKER' — uninstalling"
    do_remove "$job" >>"$LOG" 2>&1
    return 0
  fi

  local t age
  t="$(transcript_path "$SID")"
  [ -n "$t" ] || {
    wlog "no transcript for $SID under $HOME/.claude/projects (glob)"
    return 0
  }
  age="$(age_min "$t")"
  if [ "$age" -lt "$STALE_MIN" ]; then
    [ -n "${VERBOSE:-}" ] && wlog "healthy (transcript ${age} min old)"
    return 0
  fi
  wlog "STALE: transcript ${age} min old ($t)"

  if [ -n "${DRY_RUN:-}" ]; then
    if job_alive "$job"; then wlog "DRY_RUN: route 1 — would type the prompt into screen $SCREEN_NAME"; else
      wlog "DRY_RUN: route 2 — job process gone; would $CLAUDE_BIN stop $job && --bg --resume $SID"
    fi
    return 0
  fi

  if job_alive "$job" && ensure_attach_screen "$SCREEN_NAME" "$job"; then
    # TWO stuff calls: one burst reads as a paste and the Enter becomes a newline.
    screen -S "$SCREEN_NAME" -p 0 -X stuff "$prompt"
    sleep 1
    screen -S "$SCREEN_NAME" -p 0 -X stuff $'\r'
    wlog "route 1: typed the resume prompt into screen $SCREEN_NAME"
    return 0
  fi

  wlog "route 2: job process gone or attach failed — stop + --bg --resume"
  screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
  "$CLAUDE_BIN" stop "$job" >>"$LOG" 2>&1 || wlog "stop rc=$? (job may already be down)"
  sleep 5
  if "$CLAUDE_BIN" --bg --resume "$SID" --permission-mode bypassPermissions -- "$prompt" >>"$LOG" 2>&1; then
    wlog "resume issued"
  else
    wlog "resume failed rc=$? — the next tick retries"
  fi
}

LOG="${LOG:-/dev/stderr}"
wlog() {
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"
}

case "${1:-}" in
  install)
    shift
    do_install "$@"
    ;;
  remove)
    shift
    do_remove "$@"
    ;;
  status)
    shift
    do_status "$@"
    ;;
  tick)
    shift
    do_tick "$@"
    ;;
  -h | --help | '') usage 0 ;;
  *) usage 2 ;;
esac
