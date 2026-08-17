#!/usr/bin/env bash
# qwen-task.sh — run offloaded work as headless OpenCode sessions ("qwenit").
# ---------------------------------------------------------------------------
# Claude stays orchestrator; each heavy task becomes one `opencode run` job on
# a cheap open-weight model, with house conventions wrapped around it: per-task
# dir, setsid process-group kills, git-worktree isolation by default, JSONL
# event log, extracted final message, and wall-time/token/cost safety caps.
#
#   qwen-task.sh run <name> [opts] (--prompt "text" | --prompt-file F)
#       --worktree            isolate in a fresh git worktree (DEFAULT; branch qwen/<name>)
#       --dir D               run in existing dir D instead
#       --base REF            worktree base (default: current HEAD)
#       --model M             provider/model (default: $QWEN_TASK_MODEL)
#       --variant V           reasoning effort (minimal|low|medium|high|max)
#       --max-wall SECONDS    wall-time cap (default: $QWEN_MAX_WALL or 7200)
#       --max-tokens N        cumulative output-token cap (default: $QWEN_MAX_OUT_TOKENS or 300000)
#       --max-cost USD        cumulative cost cap (default: $QWEN_MAX_COST or 5.00)
#   qwen-task.sh ls                      table of tasks + state
#   qwen-task.sh status <name>           state, caps, spend, last event
#   qwen-task.sh log <name> [N]          tail N (default 20) event lines
#   qwen-task.sh result <name>           print the final message (last.md)
#   qwen-task.sh resume <name> "text"    follow-up in the task's session
#   qwen-task.sh stop <name>             TERM, then KILL, the task's process group
#   qwen-task.sh clean <name>            remove task dir (+ its worktree)
#
# Task layout: <repo>/.claude/qwen-tasks/<name>/
#   brief.md events.jsonl stderr.log last.md pid watchdog.pid workdir session.txt
#   max-wall max-tokens max-cost launched-at killed
# (`killed` exists only after a cap trip. .claude/* is gitignored, so none of
# this — including model transcripts — can reach the PUBLIC repo.)
#
# THERE IS NO SANDBOX. `opencode run` executes bash and writes files with no
# permission gate (verified: `--auto` is not needed for either). The worktree
# and the dev container are the containment. Dial scope with the brief, not
# with a flag that does not exist.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${QWEN_REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
# A task's tree/ is a full checkout carrying a copy of this script; running that
# copy must not nest task dirs under the tree. Re-home to the owning checkout.
if [ -z "${QWEN_REPO_DIR:-}" ]; then
  case "$REPO" in
    */.claude/qwen-tasks/*/tree) REPO="${REPO%%/.claude/qwen-tasks/*}" ;;
  esac
fi
ROOT="${QWEN_TASKS_DIR:-$REPO/.claude/qwen-tasks}"
OPENCODE="${OPENCODE_BIN:-opencode}"
OPENCODE_HOME="${OPENCODE_HOME:-$HOME/.opencode/bin}"
OPENROUTER_KEY_FILE="${OPENROUTER_KEY_FILE:-$HOME/.config/openrouter/api-key}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
DEFAULT_MODEL="${QWEN_TASK_MODEL:-openrouter/qwen/qwen3.8-27b}"
DEFAULT_MAX_WALL="${QWEN_MAX_WALL:-7200}"
DEFAULT_MAX_OUT_TOKENS="${QWEN_MAX_OUT_TOKENS:-300000}"
DEFAULT_MAX_COST="${QWEN_MAX_COST:-5.00}"
WATCHDOG_INTERVAL="${QWEN_WATCHDOG_INTERVAL:-30}"
KILL_GRACE="${QWEN_KILL_GRACE:-30}"

die() {
  echo "[qwen-task] ERROR: $*" >&2
  exit 1
}
msg() { echo "[qwen-task] $*"; }

tdir() { echo "$ROOT/$1"; }
alive_in() { [ -f "$1/pid" ] && kill -0 "$(cat "$1/pid")" 2>/dev/null; }

state_in() { # task dir → RUNNING | DONE | KILLED | DIED | MISSING
  local d="$1"
  [ -d "$d" ] || {
    echo MISSING
    return
  }
  if [ -s "$d/killed" ]; then
    echo KILLED
  elif alive_in "$d"; then
    echo RUNNING
  elif [ -s "$d/last.md" ]; then
    echo DONE
  else echo DIED; fi
}

positive_integer() {
  case "$2" in '' | *[!0-9]* | 0) die "$1 must be a positive integer" ;; esac
}

resolve_task_dir() {
  local n="${1:?task name required}" d
  d="$(tdir "$n")"
  [ -d "$d" ] || die "no such task '$n' (looked in $ROOT)"
  echo "$d"
}

# An agent-launched shell is non-interactive and never sources ~/.bashrc, so
# neither the installer's PATH entry nor the exported key is present. Both live
# at fixed, documented paths — find them here rather than making every caller
# re-export them.
require_opencode() {
  if ! command -v "$OPENCODE" >/dev/null 2>&1; then
    [ -x "$OPENCODE_HOME/opencode" ] ||
      die "'$OPENCODE' not on PATH and no $OPENCODE_HOME/opencode (install: curl -fsSL https://opencode.ai/install | bash)"
    PATH="$OPENCODE_HOME:$PATH"
    export PATH
  fi
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    [ -r "$OPENROUTER_KEY_FILE" ] ||
      die "OPENROUTER_API_KEY unset and $OPENROUTER_KEY_FILE unreadable — see docs/lab/QWENIT.md"
    OPENROUTER_API_KEY="$(tr -d '\n' <"$OPENROUTER_KEY_FILE")"
    export OPENROUTER_API_KEY
    [ -n "$OPENROUTER_API_KEY" ] || die "$OPENROUTER_KEY_FILE is empty"
  fi
}

# --- event-stream readers ---------------------------------------------------
# OpenCode emits one JSON object per line. Usage is reported PER STEP in
# step_finish.part.tokens (NOT cumulative), so totals must be summed.

sum_output_tokens() {
  local log="$1"
  [ -r "$log" ] || return 0
  jq -s '[.[] | select(.type == "step_finish") | .part.tokens.output // 0] | add // 0' \
    "$log" 2>/dev/null || echo 0
}

sum_cost() {
  local log="$1"
  [ -r "$log" ] || return 0
  jq -s '[.[] | select(.type == "step_finish") | .part.cost // 0] | add // 0' \
    "$log" 2>/dev/null || echo 0
}

session_id_from() {
  local log="$1"
  [ -r "$log" ] || return 0
  jq -r 'select(.sessionID != null) | .sessionID' "$log" 2>/dev/null | head -1
}

# The last non-empty text part is the final assistant message. Intermediate
# steps emit whitespace-only text parts between tool calls; those are dropped.
extract_last_message() {
  local log="$1" out="$2"
  [ -r "$log" ] || return 0
  jq -rs '[.[] | select(.type == "text") | .part.text // empty]
          | map(select(gsub("\\s"; "") != "")) | last // ""' \
    "$log" 2>/dev/null >"$out.tmp" || true
  if [ -s "$out.tmp" ]; then mv -f "$out.tmp" "$out"; else rm -f "$out.tmp"; fi
}

cost_exceeded() { # spent, limit → 0 when spent >= limit
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'
}

# --- process control --------------------------------------------------------

process_group_alive() {
  kill -0 -- "-$1" 2>/dev/null || kill -0 "$1" 2>/dev/null
}

terminate_group() {
  local pgid="$1" waited=0 grace="$KILL_GRACE"
  case "$grace" in '' | *[!0-9]*) grace=30 ;; esac
  kill -TERM -- "-$pgid" 2>/dev/null || kill -TERM "$pgid" 2>/dev/null || true
  while process_group_alive "$pgid" && [ "$waited" -lt "$grace" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if process_group_alive "$pgid"; then
    kill -KILL -- "-$pgid" 2>/dev/null || kill -KILL "$pgid" 2>/dev/null || true
  fi
}

cleanup_watchdog_pid() { [ -n "${WATCHDOG_DIR:-}" ] && rm -f "$WATCHDOG_DIR/watchdog.pid"; }

stop_watchdog() {
  local d="$1" wpid="" waited=0
  [ -s "$d/watchdog.pid" ] || return 0
  wpid="$(cat "$d/watchdog.pid" 2>/dev/null || true)"
  case "$wpid" in '' | *[!0-9]*)
    rm -f "$d/watchdog.pid"
    return 0
    ;;
  esac
  if process_group_alive "$wpid"; then
    kill -TERM -- "-$wpid" 2>/dev/null || kill -TERM "$wpid" 2>/dev/null || true
    while process_group_alive "$wpid" && [ "$waited" -lt 5 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    process_group_alive "$wpid" &&
      { kill -KILL -- "-$wpid" 2>/dev/null || kill -KILL "$wpid" 2>/dev/null || true; }
  fi
  rm -f "$d/watchdog.pid"
}

write_killed_marker() {
  local d="$1" reason="$2" value="$3" limit="$4" elapsed="$5"
  local tmp="$d/killed.tmp.$$"
  {
    printf 'reason=%s\n' "$reason"
    printf 'value=%s\n' "$value"
    printf 'limit=%s\n' "$limit"
    printf 'elapsed=%s\n' "$elapsed"
    printf 'last_md=%s/last.md\n' "$d"
    printf 'note=last.md and worktree edits are preserved as partial work\n'
  } >"$tmp"
  mv -f "$tmp" "$d/killed"
}

watchdog() { # task dir, pid, max wall, max tokens, max cost, launched epoch
  local d="$1" pid="$2" max_wall="$3" max_tokens="$4" max_cost="$5" launched="$6"
  local now elapsed tokens cost
  WATCHDOG_DIR="$d"
  trap cleanup_watchdog_pid EXIT
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$WATCHDOG_INTERVAL"
    kill -0 "$pid" 2>/dev/null || break
    now="$(date +%s)"
    elapsed=$((now - launched))
    if [ "$elapsed" -gt "$max_wall" ]; then
      write_killed_marker "$d" "wall-time cap ${max_wall}s" "$elapsed" "$max_wall" "$elapsed"
      terminate_group "$pid"
      return
    fi
    tokens="$(sum_output_tokens "$d/events.jsonl" || echo 0)"
    case "$tokens" in '' | *[!0-9]*) tokens=0 ;; esac
    if [ "$tokens" -gt "$max_tokens" ]; then
      write_killed_marker "$d" "output-token cap ${max_tokens}" "$tokens" "$max_tokens" "$elapsed"
      terminate_group "$pid"
      return
    fi
    cost="$(sum_cost "$d/events.jsonl" || echo 0)"
    if cost_exceeded "$cost" "$max_cost"; then
      write_killed_marker "$d" "cost cap \$${max_cost}" "$cost" "$max_cost" "$elapsed"
      terminate_group "$pid"
      return
    fi
  done
}

prepare_watchdog() {
  local d="$1"
  printf '%s\n' "$2" >"$d/max-wall"
  printf '%s\n' "$3" >"$d/max-tokens"
  printf '%s\n' "$4" >"$d/max-cost"
  date +%s >"$d/launched-at"
}

start_watchdog() {
  local d="$1" pid launched
  pid="$(cat "$d/pid")"
  launched="$(cat "$d/launched-at")"
  setsid nohup "$SELF" __watchdog "$d" "$pid" \
    "$(cat "$d/max-wall")" "$(cat "$d/max-tokens")" "$(cat "$d/max-cost")" "$launched" \
    >/dev/null 2>&1 &
  echo $! >"$d/watchdog.pid"
}

# --- finalisation -----------------------------------------------------------
# `opencode run` has no -o flag, so the final message is extracted from the
# event stream once the process exits.

finalize() {
  local d="$1"
  extract_last_message "$d/events.jsonl" "$d/last.md"
  session_id_from "$d/events.jsonl" >"$d/session.txt" 2>/dev/null || true
  stop_watchdog "$d"
}

reaper() { # background: wait for the run to end, then extract last.md
  local d="$1" pid="$2"
  while kill -0 "$pid" 2>/dev/null; do sleep 5; done
  finalize "$d"
}

launch() { # name, task dir, workdir, prompt, rest: opencode run args
  local name="$1" d="$2" wd="$3" prompt="$4"
  shift 4
  (
    cd "$wd" && setsid nohup "$OPENCODE" run --format json "$@" "$prompt" \
      >>"$d/events.jsonl" 2>>"$d/stderr.log" &
    echo $! >"$d/pid"
  )
  start_watchdog "$d"
  setsid nohup "$SELF" __reaper "$d" "$(cat "$d/pid")" >/dev/null 2>&1 &
  sleep 2
  alive_in "$d" || {
    stop_watchdog "$d"
    finalize "$d"
    if [ -s "$d/last.md" ]; then
      msg "task '$name' finished immediately; see: $0 result $name"
      return 0
    fi
    echo "--- stderr ---" >&2
    tail -5 "$d/stderr.log" >&2
    die "task '$name' died at launch"
  }
  msg "launched '$name' (pid $(cat "$d/pid"), workdir $wd)"
  msg "caps: $(cat "$d/max-wall")s wall, $(cat "$d/max-tokens") output tokens, \$$(cat "$d/max-cost")"
  msg "watch: $0 status $name | log: $0 log $name | result: $0 result $name"
}

# --- commands ---------------------------------------------------------------

cmd_run() {
  local name="" dirmode="" base="HEAD" model="$DEFAULT_MODEL" variant="" prompt="" pfile=""
  local max_wall="$DEFAULT_MAX_WALL" max_tokens="$DEFAULT_MAX_OUT_TOKENS" max_cost="$DEFAULT_MAX_COST"
  name="${1:?run <name> required}"
  shift
  case "$name" in */* | *" "* | *@*) die "name must be a simple slug (no /, space, or @)" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) dirmode="" ;;
      --dir)
        dirmode="$2"
        shift
        ;;
      --base)
        base="$2"
        shift
        ;;
      --model)
        model="$2"
        shift
        ;;
      --variant)
        variant="$2"
        shift
        ;;
      --max-wall)
        max_wall="$2"
        shift
        ;;
      --max-tokens)
        max_tokens="$2"
        shift
        ;;
      --max-cost)
        max_cost="$2"
        shift
        ;;
      --prompt)
        prompt="$2"
        shift
        ;;
      --prompt-file)
        pfile="$2"
        shift
        ;;
      *) die "unknown flag $1" ;;
    esac
    shift
  done
  require_opencode
  positive_integer "--max-wall" "$max_wall"
  positive_integer "--max-tokens" "$max_tokens"
  [ -n "$prompt$pfile" ] || die "--prompt or --prompt-file required"

  local d
  d="$(tdir "$name")"
  [ -e "$d" ] && die "task '$name' already exists ($(state_in "$d")); pick a new name or 'clean' it"
  mkdir -p "$d"
  if [ -n "$pfile" ]; then
    [ -r "$pfile" ] || die "--prompt-file $pfile not readable"
    cp "$pfile" "$d/brief.md"
  else
    printf '%s\n' "$prompt" >"$d/brief.md"
  fi

  local wd args=()
  if [ -n "$dirmode" ]; then
    wd="$dirmode"
    [ -d "$wd" ] || die "--dir $wd does not exist"
  else
    wd="$d/tree"
    git -C "$REPO" worktree add -b "qwen/$name" "$wd" "$base" >/dev/null ||
      die "worktree add failed (branch qwen/$name exists?)"
  fi
  echo "$wd" >"$d/workdir"
  printf '%s\n' "$model" >"$d/model"

  args+=(--model "$model")
  [ -n "$variant" ] && args+=(--variant "$variant")
  prepare_watchdog "$d" "$max_wall" "$max_tokens" "$max_cost"
  launch "$name" "$d" "$wd" "$(cat "$d/brief.md")" "${args[@]}"
}

cmd_ls() {
  [ -d "$ROOT" ] || {
    msg "no tasks yet ($ROOT)"
    return 0
  }
  printf '%-24s %-8s %10s %9s  %s\n' NAME STATE TOKENS COST WORKDIR
  local d n
  for d in "$ROOT"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    printf '%-24s %-8s %10s %9s  %s\n' \
      "$n" "$(state_in "$d")" \
      "$(sum_output_tokens "$d/events.jsonl" || echo 0)" \
      "$(printf '$%.4f' "$(sum_cost "$d/events.jsonl" || echo 0)")" \
      "$(cat "$d/workdir" 2>/dev/null || echo '-')"
  done
}

cmd_status() {
  local d
  d="$(resolve_task_dir "${1:?status <name> required}")"
  echo "state:    $(state_in "$d")"
  echo "workdir:  $(cat "$d/workdir" 2>/dev/null || echo '-')"
  echo "model:    $(cat "$d/model" 2>/dev/null || echo '-')"
  echo "session:  $(cat "$d/session.txt" 2>/dev/null || session_id_from "$d/events.jsonl")"
  echo "caps:     $(cat "$d/max-wall" 2>/dev/null)s wall, $(cat "$d/max-tokens" 2>/dev/null) tokens, \$$(cat "$d/max-cost" 2>/dev/null)"
  echo "spent:    $(sum_output_tokens "$d/events.jsonl") output tokens, \$$(sum_cost "$d/events.jsonl")"
  [ -s "$d/killed" ] && {
    echo "--- cap trip ---"
    cat "$d/killed"
  }
  echo "--- last event ---"
  tail -1 "$d/events.jsonl" 2>/dev/null || echo "(no events yet)"
}

cmd_log() {
  local d n="${2:-20}"
  d="$(resolve_task_dir "${1:?log <name> required}")"
  tail -"$n" "$d/events.jsonl" 2>/dev/null || msg "no events yet"
}

cmd_result() {
  local d
  d="$(resolve_task_dir "${1:?result <name> required}")"
  [ -s "$d/last.md" ] || finalize "$d"
  [ -s "$d/last.md" ] || die "no final message yet (state: $(state_in "$d"))"
  cat "$d/last.md"
}

cmd_resume() {
  local d n="${1:?resume <name> \"text\" required}" text="${2:?follow-up text required}" sid
  d="$(resolve_task_dir "$n")"
  alive_in "$d" && die "task '$n' is still RUNNING; stop it first"
  require_opencode
  sid="$(cat "$d/session.txt" 2>/dev/null || session_id_from "$d/events.jsonl")"
  [ -n "$sid" ] || die "no session id recorded for '$n'"
  rm -f "$d/killed"
  local args=(--session "$sid" --model "$(cat "$d/model")")
  prepare_watchdog "$d" \
    "$(cat "$d/max-wall")" "$(cat "$d/max-tokens")" "$(cat "$d/max-cost")"
  launch "$n" "$d" "$(cat "$d/workdir")" "$text" "${args[@]}"
}

cmd_stop() {
  local d n="${1:?stop <name> required}"
  d="$(resolve_task_dir "$n")"
  stop_watchdog "$d"
  alive_in "$d" || {
    msg "'$n' is not running (state: $(state_in "$d"))"
    return 0
  }
  terminate_group "$(cat "$d/pid")"
  finalize "$d"
  msg "stopped '$n'"
}

cmd_clean() {
  local d n="${1:?clean <name> required}" wd
  d="$(resolve_task_dir "$n")"
  alive_in "$d" && die "'$n' is still RUNNING; stop it first"
  stop_watchdog "$d"
  wd="$(cat "$d/workdir" 2>/dev/null || true)"
  case "$wd" in
    "$d/tree") git -C "$REPO" worktree remove --force "$wd" 2>/dev/null || true ;;
  esac
  rm -rf "$d"
  msg "cleaned '$n' (branch qwen/$n kept if it had commits)"
}

usage() { sed -n '2,34p' "$SELF" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  run)
    shift
    cmd_run "$@"
    ;;
  ls)
    shift
    cmd_ls "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  log)
    shift
    cmd_log "$@"
    ;;
  result)
    shift
    cmd_result "$@"
    ;;
  resume)
    shift
    cmd_resume "$@"
    ;;
  stop)
    shift
    cmd_stop "$@"
    ;;
  clean)
    shift
    cmd_clean "$@"
    ;;
  __watchdog)
    shift
    watchdog "$@"
    ;;
  __reaper)
    shift
    reaper "$@"
    ;;
  '' | -h | --help | help) usage ;;
  *) die "unknown command '$1' (try --help)" ;;
esac
