#!/usr/bin/env bash
# clientcmd.sh — operator wrapper for the SPA client-observability plane
# (/clientcmd + /clientlog on osgallery-https-server.py).
#
#   clientcmd.sh snapshot <tile|*>   enqueue: tab(s) POST a full metrics snapshot
#   clientcmd.sh verbose  <tile|*>   enqueue: toggle verbose client debugging
#   clientcmd.sh reload   <tile|*>   enqueue: location.reload() the tab(s)
#   clientcmd.sh restore  <tile>     restore one tile to its golden fixture
#   clientcmd.sh eval <sessionId|tile|*> '<js code>'  run JS in targeted tab(s)
#                                      ('*' deliberately targets every open tab)
#   clientcmd.sh sessions            active sessions with last tile / UA / time
#   clientcmd.sh evallog [sessionId]  reassemble the latest eval-result
#   clientcmd.sh tail                tail -f the telemetry JSONL
#   clientcmd.sh log <tile>          last 200 telemetry events for one tile (jq)
#
# Runs ON the box (token + files live there). Run from anywhere else and it
# re-execs itself over `ssh lab` transparently, so both of these work:
#   ssh lab '/data/vms/streamhost/serve/clientcmd.sh snapshot amiga'
#   scripts/serve/clientcmd.sh verbose '*'
#
# Env overrides: SERVE, CLIENTCMD_TOKEN, CLIENTLOG, PORT, BASE, OSG_ADMIN_EVAL.
set -euo pipefail

SERVE=${SERVE:-/data/vms/streamhost/serve}
TOKEN_FILE=${CLIENTCMD_TOKEN:-$SERVE/pki/clientcmd.token}
PORT=${PORT:-8443}
BASE=${BASE:-https://127.0.0.1:$PORT}
LOG=${CLIENTLOG:-$SERVE/clientlog.jsonl}
SESSION_ACTIVE_SECS=${SESSION_ACTIVE_SECS:-1800}
OSG_ADMIN_EVAL=${OSG_ADMIN_EVAL:-0}

usage() {
  grep '^#   clientcmd.sh' "$0" | sed 's/^#   //'
  exit 2
}

# No token file here and ssh fallback not disabled -> we are not on the box:
# pipe this very script over `ssh lab` with the same (safely re-quoted) args.
if [ ! -r "$TOKEN_FILE" ] && [ "${CLIENTCMD_NO_SSH:-}" != "1" ]; then
  exec ssh lab "CLIENTCMD_NO_SSH=1 OSG_ADMIN_EVAL=$(printf '%q' "$OSG_ADMIN_EVAL") bash -s -- $(printf '%q ' "$@")" <"$0"
fi

cmd=${1:-}
shift || true

active_session_exists() {
  local wanted=$1
  [ -r "$LOG" ] || return 1
  jq -s -e --arg wanted "$wanted" --argjson cutoff "$(($(date +%s) - SESSION_ACTIVE_SECS))" '
    any(.[]; .sessionId == $wanted and (.srvTs // 0) >= $cutoff)
  ' "$LOG" >/dev/null
}

enqueue() {
  local body=$1
  curl -sk -X POST "$BASE/clientcmd/admin" \
    -H "X-Admin-Token: $(cat "$TOKEN_FILE")" \
    -H 'Content-Type: application/json' \
    -d "$body"
  echo
}

require_eval_opt_in() {
  [ "$OSG_ADMIN_EVAL" = "1" ] || {
    echo "eval is disabled; set OSG_ADMIN_EVAL=1 explicitly on the server and this command" >&2
    exit 1
  }
}

case "$cmd" in
  snapshot | verbose | reload)
    tile=${1:-*}
    # jq builds the JSON so a weird tile value can never break out of the body.
    body=$(jq -nc --arg cmd "$cmd" --arg tile "$tile" '{cmd:$cmd,tile:$tile,args:{}}')
    enqueue "$body"
    ;;
  restore)
    tile=${1:?usage: clientcmd.sh restore <tile>}
    curl -sk -X POST "$BASE/restore/$(printf '%s' "$tile" | jq -sRr @uri)" \
      -H "X-Admin-Token: $(cat "$TOKEN_FILE")"
    echo
    ;;
  eval)
    require_eval_opt_in
    target=${1:?usage: clientcmd.sh eval <sessionId|tile|*> '<js code>'}
    code=${2:?usage: clientcmd.sh eval <sessionId|tile|*> '<js code>'}
    if active_session_exists "$target"; then
      body=$(jq -nc --arg code "$code" --arg sessionId "$target" \
        '{cmd:"eval",tile:"*",args:{code:$code,sessionId:$sessionId}}')
    else
      body=$(jq -nc --arg code "$code" --arg tile "$target" \
        '{cmd:"eval",tile:$tile,args:{code:$code}}')
    fi
    enqueue "$body"
    ;;
  sessions)
    [ -r "$LOG" ] || {
      echo "no client log: $LOG" >&2
      exit 1
    }
    printf 'SESSION\tLAST_SEEN_UTC\tTILE\tUA\n'
    jq -rs --argjson cutoff "$(($(date +%s) - SESSION_ACTIVE_SECS))" '
      map(select(.sessionId))
      | sort_by(.srvTs // 0)
      | group_by(.sessionId)
      | map({
          sessionId: .[0].sessionId,
          last: (last.srvTs // 0),
          tile: ([.[] | select((.tile // "") != "") | .tile] | last // ""),
          ua: ([.[] | select((.ua // "") != "") | .ua] | last // "")
        })
      | map(select(.last >= $cutoff))
      | sort_by(.last) | reverse[]
      | [.sessionId, (.last | todateiso8601), .tile, .ua]
      | @tsv
    ' "$LOG"
    ;;
  evallog)
    require_eval_opt_in
    wanted=${1:-}
    [ -r "$LOG" ] || {
      echo "no client log: $LOG" >&2
      exit 1
    }
    tail -n 4000 "$LOG" | jq -s --arg wanted "$wanted" '
      map(select(.event == "eval-result"
                 and ($wanted == "" or .sessionId == $wanted))) as $matching
      | if ($matching | length) == 0 then
          error("no matching eval-result events")
        else
          # With no explicit session, report the session owning the newest
          # result rather than mixing chunks from concurrent targeted tabs.
          ($matching[-1].sessionId) as $latestSession
          | ($matching | map(select(.sessionId == $latestSession))) as $events
          | ($events[-1].detail
            | capture("^\\[(?<i>[0-9]+)/(?<n>[0-9]+)\\] ")
            | .n | tonumber) as $n
          | ($events[-$n:]
              | sort_by(.detail
                  | capture("^\\[(?<i>[0-9]+)/[0-9]+\\] ")
                  | .i | tonumber)
              | map(.detail | sub("^\\[[0-9]+/[0-9]+\\] "; ""))
              | join("")
              | fromjson)
          | if .ok == true and (.result | type) == "string"
               and (.truncated // false) == false
            then .result = (try (.result | fromjson) catch .result)
            else . end
        end
    '
    ;;
  tail)
    exec tail -f "$LOG"
    ;;
  log)
    tile=${1:?usage: clientcmd.sh log <tile>}
    tail -n 2000 "$LOG" | jq -c --arg t "$tile" 'select(.tile==$t)' | tail -n 200
    ;;
  *)
    usage
    ;;
esac
