#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scene-v2-server.sh start|stop|status <port>

Start, inspect, or stop a task-owned scene-v2 Vite server.

start   Reuse the main checkout's spa/node_modules (or run npm ci), create the
        credentials.ts placeholder if absent, launch Vite in a new session,
        write /tmp/scene-v2-server-<port>.{pid,log}, and wait for HTTP health.
stop    Stop only the process group recorded in that port's pidfile, then scan
        /proc cmdlines for an orphan from this checkout.
status  Report pidfile/process/HTTP state.

Ports 5197 and 5199 are reserved and always refused.
EOF
}

die() {
  echo "scene-v2-server: $*" >&2
  exit 1
}

[[ ${1:-} != --help && ${1:-} != -h ]] || {
  usage
  exit 0
}
[[ $# -eq 2 ]] || {
  usage >&2
  exit 2
}
action=$1
port=$2
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1024 && port <= 65535)) ||
  die "port must be an integer from 1024 through 65535"
[[ $port != 5197 && $port != 5199 ]] || die "port $port is reserved"

root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
spa=$root/spa
pidfile=/tmp/scene-v2-server-"$port".pid
logfile=/tmp/scene-v2-server-"$port".log

read_pid() {
  [[ -f $pidfile ]] || return 1
  IFS= read -r pid <"$pidfile"
  [[ $pid =~ ^[0-9]+$ ]] || return 1
}

owned_process() {
  read_pid || return 1
  [[ -r /proc/$pid/cmdline ]] || return 1
  cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline")
  [[ $cmdline == *"npm run dev"* && $cmdline == *"--port $port"* ]]
}

health() {
  curl --fail --silent --show-error --max-time 2 \
    "http://127.0.0.1:$port/museum" >/dev/null 2>&1
}

orphan_check() {
  local proc command found=0
  for proc in /proc/[0-9]*/cmdline; do
    [[ -r $proc ]] || continue
    command=$(tr '\0' ' ' <"$proc" 2>/dev/null || true)
    if [[ $command == *"$spa/"* && $command == *"--port $port"* ]]; then
      echo "scene-v2-server: orphan remains: ${proc#/proc/}: $command" >&2
      found=1
    fi
  done
  return "$found"
}

wait_for_no_orphan() {
  for _ in {1..20}; do
    orphan_check >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  orphan_check
}

stop_server() {
  if [[ ! -f $pidfile ]]; then
    echo "scene-v2-server: stopped (no pidfile for $port)"
    wait_for_no_orphan || return 1
    return 0
  fi
  read_pid || die "invalid pidfile: $pidfile"
  if [[ ! -e /proc/$pid ]]; then
    rm -f -- "$pidfile"
    echo "scene-v2-server: removed stale pidfile for dead pid $pid"
    wait_for_no_orphan || return 1
    return 0
  fi
  owned_process || die "pid $pid cmdline does not match this Vite server; refusing kill"
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
  for _ in {1..20}; do
    [[ ! -e /proc/$pid ]] && break
    sleep 0.25
  done
  if [[ -e /proc/$pid ]]; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid"
  fi
  rm -f -- "$pidfile"
  wait_for_no_orphan || return 1
  echo "scene-v2-server: stopped port $port (pid $pid)"
}

case $action in
  start)
    if owned_process; then
      health && {
        echo "scene-v2-server: already healthy at http://127.0.0.1:$port (pid $pid)"
        exit 0
      }
      die "recorded process $pid is alive but HTTP health failed"
    fi
    [[ ! -f $pidfile ]] || die "stale or mismatched pidfile exists: $pidfile"
    health && die "port $port already serves HTTP without this tool's pidfile"

    modules=$spa/node_modules
    if [[ -L $modules && ! -e $modules ]]; then
      rm -- "$modules"
    fi
    if [[ ! -e $modules ]]; then
      common=$(git -C "$root" rev-parse --git-common-dir)
      common_abs=$(cd "$root" && cd "$common" && pwd -P)
      main_modules=$(dirname "$common_abs")/spa/node_modules
      if [[ -d $main_modules ]]; then
        ln -s "$main_modules" "$modules"
        echo "scene-v2-server: linked node_modules from main checkout"
      else
        echo "scene-v2-server: main checkout has no node_modules; running npm ci"
        npm --prefix "$spa" ci
      fi
    fi
    credentials=$spa/src/data/credentials.ts
    if [[ ! -e $credentials ]]; then
      cp "$spa/src/data/credentials.example.ts" "$credentials"
      echo "scene-v2-server: created placeholder credentials.ts"
    fi
    (
      cd "$spa"
      setsid npm run dev -- --host 127.0.0.1 --port "$port" >"$logfile" 2>&1 &
      launched=$!
      printf '%s\n' "$launched" >"$pidfile.tmp.$$"
      mv -f -- "$pidfile.tmp.$$" "$pidfile"
    )
    for _ in {1..40}; do
      health && {
        read_pid
        echo "scene-v2-server: healthy http://127.0.0.1:$port (pid $pid; log $logfile)"
        exit 0
      }
      # npm briefly changes process state while running predev; a single
      # /proc cmdline read can be empty during that handoff. Keep polling the
      # PID we just recorded and apply the strict ownership check on stop.
      read_pid
      [[ -e /proc/$pid ]] || break
      sleep 0.5
    done
    tail -n 30 "$logfile" >&2 || true
    stop_server >/dev/null 2>&1 || true
    die "Vite failed its health check; see $logfile"
    ;;
  stop)
    stop_server
    ;;
  status)
    if owned_process; then
      if health; then
        echo "scene-v2-server: healthy http://127.0.0.1:$port (pid $pid; log $logfile)"
        exit 0
      fi
      echo "scene-v2-server: pid $pid is running but HTTP health failed (log $logfile)" >&2
      exit 1
    fi
    [[ ! -f $pidfile ]] || {
      echo "scene-v2-server: stale or mismatched pidfile: $pidfile" >&2
      exit 1
    }
    echo "scene-v2-server: stopped on port $port"
    exit 3
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
