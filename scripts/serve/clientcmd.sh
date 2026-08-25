#!/usr/bin/env bash
# clientcmd.sh — operator wrapper for the UI client-observability plane
# (/clientcmd + /clientlog on osgallery-https-server.py).
#
#   clientcmd.sh snapshot <tile|*>   enqueue: tab(s) POST a full metrics snapshot
#   clientcmd.sh verbose  <tile|*>   enqueue: toggle verbose client debugging
#   clientcmd.sh reload   <tile|*>   enqueue: location.reload() the tab(s)
#   clientcmd.sh restore  <tile>     restore one station to its golden fixture
#   clientcmd.sh eval <sessionId|tile|*> '<js code>'  run JS in targeted tab(s)
#                                      ('*' deliberately targets every open tab)
#                                      code runs inside an async function body:
#                                      END WITH a top-level `return <value>` or
#                                      the delivered result is "[Undefined]"
#                                      (await OK; objects serialized safely)
#   clientcmd.sh sessions            active sessions: state / station / UA / time
#   clientcmd.sh audit [n]           last n issued commands (who pointed what at whom)
#   clientcmd.sh evallog [sessionId]  reassemble the latest eval-result
#   clientcmd.sh tail                tail -f the telemetry JSONL
#   clientcmd.sh log <tile>          last 200 telemetry events for one station (jq)
#
# Runs ON labhost (token + files live there). Run from anywhere else and it
# re-execs itself over `ssh lab` transparently, so both of these work:
#   ssh lab '/data/vms/streamhost/serve/clientcmd.sh snapshot amiga'
#   scripts/serve/clientcmd.sh verbose '*'
#
# eval needs no opt-in: the enqueue endpoint is box-side only (loopback + token,
# and 404 on the public listener), so nothing a browser can reach can issue a
# command. Set OSG_ADMIN_EVAL=0 on the SERVER to disable eval entirely.
#
# Env overrides: SERVE, CLIENTCMD_TOKEN, CLIENTCMD_AUDIT, CLIENTLOG, PORT, BASE.
set -euo pipefail

SERVE=${SERVE:-/data/vms/streamhost/serve}
TOKEN_FILE=${CLIENTCMD_TOKEN:-$SERVE/pki/clientcmd.token}
PORT=${PORT:-8443}
BASE=${BASE:-https://127.0.0.1:$PORT}
LOG=${CLIENTLOG:-$SERVE/clientlog.jsonl}
AUDIT=${CLIENTCMD_AUDIT:-$SERVE/clientcmd-audit.jsonl}
SESSION_ACTIVE_SECS=${SESSION_ACTIVE_SECS:-1800}

usage() {
  grep '^#   clientcmd.sh' "$0" | sed 's/^#   //'
  exit 2
}

# No token file here and ssh fallback not disabled -> we are not on labhost:
# pipe this very script over `ssh lab` with the same (safely re-quoted) args.
if [ ! -r "$TOKEN_FILE" ] && [ "${CLIENTCMD_NO_SSH:-}" != "1" ]; then
  exec ssh lab "CLIENTCMD_NO_SSH=1 bash -s -- $(printf '%q ' "$@")" <"$0"
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

case "$cmd" in
  snapshot | verbose | reload)
    tile=${1:-*}
    # jq builds the JSON so a weird station value can never break out of the body.
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
    # Derived entirely from clientlog.jsonl, so a session that never managed to
    # poll — or never managed to stream at all — is still listed. STATE is the
    # point of this view: "open" or "failed" is a session that needs help.
    printf 'SESSION\tSTATE\tLAST_SEEN_UTC\tTILE\tUA\n'
    jq -rs --argjson cutoff "$(($(date +%s) - SESSION_ACTIVE_SECS))" '
      map(select(.sessionId))
      | sort_by(.srvTs // 0)
      | group_by(.sessionId)
      | map({
          sessionId: .[0].sessionId,
          last: (last.srvTs // 0),
          tile: ([.[] | select((.tile // "") != "") | .tile] | last // ""),
          ua: ([.[] | select((.ua // "") != "") | .ua] | last // ""),
          events: [.[] | .event],
        })
      | map(select(.last >= $cutoff))
      | map(. + {state:
            (if   (.events | index("connect-giveup"))  then "FAILED"
             elif (.events | index("connect-stalled")) then "STALLED"
             elif (.events | index("connect-retry"))   then "retrying"
             elif (.events | index("connect"))         then "live"
             elif (.events | index("station-open"))    then "opening"
             elif (.events | index("session-start"))   then "no-station"
             else "unknown" end)})
      | sort_by(.last) | reverse[]
      | [.sessionId, .state, (.last | todateiso8601), .tile, .ua]
      | @tsv
    ' "$LOG"
    ;;
  audit)
    n=${1:-40}
    [ -r "$AUDIT" ] || {
      echo "no audit trail yet: $AUDIT" >&2
      exit 1
    }
    printf 'WHEN_UTC\tISSUED_BY\tCMD\tTILE\tSESSION\tCODE\n'
    tail -n "$n" "$AUDIT" | jq -r '
      [(.srvTs | todateiso8601), .issuedBy, .cmd, .tile, (.sessionId // "-"),
       ((.code // "-") | gsub("\\s+"; " ") | .[0:80])] | @tsv'
    ;;
  evallog)
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
