#!/usr/bin/env bash
# ============================================================================
# station-accept.sh — rule 9 as a command: does this station REACT, through the
# path it actually ships on?
#
# WHY THIS EXISTS
# On 2026-08-30 a station cutover passed every proof its authors ran and then
# failed on the live station. The pointer mechanism was perfect — the guest's
# own coordinate read back exactly the commanded target, 8/8 and 6/6, three
# observers, two runs, framebuffer-exact. Every one of those proofs spoke the
# control protocol to QEMU directly, with `streamhost` NOT RUNNING in the rig,
# and every one used a single session. The daemon's input sink — the component
# that actually shipped — sat outside the proof boundary, and it was the only
# thing that broke. Five independent, rigorous agents each drew the boundary one
# component short, and a coordinator reviewing all five did not notice.
#
# That is what happens whenever the AUTHOR OF A CHANGE ALSO CHOOSES THE BOUNDARY
# OF ITS PROOF. This script exists so the boundary is chosen once, in code, and
# runs the same way for every station.
#
# THE BOUNDARY, FIXED AND NON-NEGOTIABLE:
#   browser client -> SPA/signaling -> streamhost daemon -> input sink -> device
#   -> guest -> framebuffer
# Evidence that does not traverse the whole path is a component test — valuable
# while developing, never acceptance — and this gate refuses to certify on it.
#
# FOUR THINGS THIS REFUSES TO TREAT AS HEALTH, each measured true-and-meaningless
# on 2026-08-30, at four different layers:
#   * `STAT` reporting healthy while the drawn cursor sat 1-2 px off;
#   * input-router counters frozen at the first session's totals while 40
#     sessions failed to negotiate;
#   * a <video> that is sized, ready and non-black while showing a STOPPED
#     stream — a paused element with a stale frame passes all three;
#   * an observer's EMPTY log, read as "hadn't started yet", while it held the
#     single-client QMP monitor for the whole window.
# So: the evidence is inter-frame motion in a NAMED rectangle after a commanded
# interaction. Telemetry may corroborate a pass; it may never substitute for it.
#
# SESSION CHURN IS MANDATORY. See --sessions/--abandon-at: the run drives
# several sequential sessions and SIGKILLs one mid-stream, then requires a LATER
# session to negotiate and show motion. A single-session acceptance run is not
# an acceptance run; it certifies the rhapsody defect by construction.
#
# EVERY PASS RUNS A SIMULTANEOUS CONTROL STATION, because this gate can in
# principle cause what it detects. candidate fails + control passes -> the
# station is at fault. candidate fails + control ALSO fails -> the harness or
# the box is suspect and NOTHING is rolled back: rolling a healthy release back
# on a harness fault is rollback flapping, which is worse than no gate.
#
# WHAT IT WILL NOT DO
#   * It never prints ACCEPTED. Whether the frame shows the MACHINE's own screen
#     is a judgement no pixel statistic makes.
#   * It never starts, stops or resets a station. "It exists" is not "it is
#     mine"; a stopped station is a refusal, not a silent `systemctl start`.
#   * It holds no exclusive resource across the run. QMP serves ONE client at a
#     time, and an observer holding it is indistinguishable, from the station's
#     side, from the station being broken.
#
# usage: station-accept.sh <station> [options]
#   --control <station>  the same-pass control (default: acceptance.controlStation)
#   --sessions N         sequential sessions (default from the registry, min 2)
#   --abandon-at K       which session to SIGKILL mid-stream (default 2)
#   --rect x,y,w,h       watched rectangle, guest pixels (default from registry)
#   --sample-ms N        ms between samples (default from registry)
#   --base URL           origin (default https://$LAB_HOST:8443)
#   --evidence DIR       where JSON + shots land (default ./station-accept-evidence)
#   -n, --dry-run        print what would run, touch nothing
#
# exit: 0  the station reacted through the shipping path (a human still owes the
#          identity call — see the last lines it prints)
#       1  the candidate FAILED and the control PASSED: the station is at fault
#       2  usage, unknown station, missing acceptance spec, or a refusal
#       3  ssh lab unreachable, or no browser leg available — nothing was verified
#      10  candidate and control BOTH failed: harness or box suspect, a human
#          must look. Deliberately not 1 — "I cannot decide this" and "this is
#          broken" are different answers, and only one of them may roll back.
# ============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

SELF="station-accept"
LAB="${LAB:-lab}"
PROBE="scripts/e2e/station-accept-probe.mjs"
EVIDENCE="./station-accept-evidence"
DRY=0
STATION=""
CONTROL=""
SESSIONS=""
ABANDON=""
RECT=""
SAMPLE_MS=""
BASE="${GALLERY_URL:-}"

die() {
  printf '%s: %s\n' "$SELF" "$1" >&2
  exit "${2:-2}"
}
say() { printf '%s\n' "$1"; }
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --control)
      CONTROL="${2:-}"
      shift
      ;;
    --sessions)
      SESSIONS="${2:-}"
      shift
      ;;
    --abandon-at)
      ABANDON="${2:-}"
      shift
      ;;
    --rect)
      RECT="${2:-}"
      shift
      ;;
    --sample-ms)
      SAMPLE_MS="${2:-}"
      shift
      ;;
    --base)
      BASE="${2:-}"
      shift
      ;;
    --evidence)
      EVIDENCE="${2:-}"
      shift
      ;;
    -n | --dry-run) DRY=1 ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$STATION" ] && STATION="$1" || die "one station at a time (got '$STATION' and '$1')"
      ;;
  esac
  shift
done
[ -n "$STATION" ] || die "usage: station-accept.sh <station> [options]"

# --- the acceptance spec, read from the registry -----------------------------
# A station with no `acceptance:` stanza is a REFUSAL, not a pass. There is no
# default spec: the watched rectangle, the probe point and the sampling interval
# are per-station facts nobody can guess, and a gate that invents them would
# certify whatever it happened to look at.
read_spec() {
  python3 - "$1" <<'PYEOF'
import json
import sys
from pathlib import Path

station = sys.argv[1]
path = Path("registry/stations") / f"{station}.json"
if not path.exists():
    print("ERR unknown station")
    raise SystemExit(0)
row = json.loads(path.read_text())
spec = row.get("acceptance")
if not spec:
    print("ERR no acceptance stanza")
    raise SystemExit(0)
rect = spec.get("watchRect") or []
point = spec.get("probePoint") or []
guest = spec.get("guestSize") or []
print("OK")
print(f"rect={','.join(str(int(v)) for v in rect)}" if len(rect) == 4 else "rect=")
print(f"point={','.join(str(int(v)) for v in point)}" if len(point) == 2 else "point=")
print(f"guest={'x'.join(str(int(v)) for v in guest)}" if len(guest) == 2 else "guest=")
print(f"control={spec.get('controlStation', '')}")
print(f"sessions={spec.get('sessions', 3)}")
print(f"abandon={spec.get('abandonAt', 2)}")
print(f"sample={spec.get('sampleIntervalMs', 1000)}")
print(f"floor={spec.get('sampleFloorMs', 0)}")
print(f"ceiling={spec.get('sampleCeilingMs', 0)}")
print(f"bank={spec.get('cursorBank', '')}")
PYEOF
}
SPEC="$(read_spec "$STATION")"
case "$SPEC" in
  "ERR unknown station"*) die "unknown station '$STATION' (no registry/stations/$STATION.json)" ;;
  "ERR no acceptance stanza"*)
    die "station '$STATION' has no acceptance: stanza. That is a refusal, not a pass —
       the watched rectangle and probe point are per-station facts, and a gate that
       guessed them would certify whatever it happened to look at. See
       docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md 6."
    ;;
esac
spec_get() { printf '%s\n' "$SPEC" | sed -n "s/^$1=//p" | head -1; }
[ -z "$RECT" ] && RECT="$(spec_get rect)"
[ -z "$CONTROL" ] && CONTROL="$(spec_get control)"
[ -z "$SESSIONS" ] && SESSIONS="$(spec_get sessions)"
[ -z "$ABANDON" ] && ABANDON="$(spec_get abandon)"
[ -z "$SAMPLE_MS" ] && SAMPLE_MS="$(spec_get sample)"
POINT="$(spec_get point)"
GUEST="$(spec_get guest)"
FLOOR="$(spec_get floor)"
CEILING="$(spec_get ceiling)"
BANK="$(spec_get bank)"
[ -n "$RECT" ] || die "acceptance.watchRect is missing for '$STATION'"
[ -n "$CONTROL" ] || die "acceptance.controlStation is missing for '$STATION' — every pass
       runs a simultaneous control, because this gate can cause what it detects."
[ "$CONTROL" != "$STATION" ] || die "the control must be a DIFFERENT station from the candidate"

# THE TWO SAMPLING BOUNDS, IN TENSION BY CONSTRUCTION. Too sparse misses the
# defect; too dense BECOMES it — screendumping a station every second was itself
# enough to stop a session negotiating, identified at the cost of two failed runs.
# Both bounds are per-station and must be declared; this refuses to invent either.
if [ "${FLOOR:-0}" -gt 0 ] 2>/dev/null && [ "$SAMPLE_MS" -lt "$FLOOR" ]; then
  die "sampleIntervalMs $SAMPLE_MS is below this station's declared floor ${FLOOR}ms
       (too dense: observation can manufacture the failure it tests for)"
fi
if [ "${CEILING:-0}" -gt 0 ] 2>/dev/null && [ "$SAMPLE_MS" -gt "$CEILING" ]; then
  die "sampleIntervalMs $SAMPLE_MS is above this station's declared ceiling ${CEILING}ms
       (too sparse: the commanded change can complete between samples)"
fi

say "== station-accept: $STATION (control: $CONTROL) =="
say "   boundary: browser -> SPA/signaling -> daemon -> input sink -> device -> guest -> framebuffer"
say "   rect=$RECT  sample=${SAMPLE_MS}ms  sessions=$SESSIONS  abandon-at=$ABANDON"

# --- preconditions (read-only; a stopped station is a refusal) ---------------
if [ "$DRY" = 0 ]; then
  ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null ||
    die "ssh $LAB unreachable — nothing was verified" 3
  for s in "$STATION" "$CONTROL"; do
    state="$(ssh -n -o ConnectTimeout=15 "$LAB" \
      "systemctl is-active streamhost@$(printf '%q' "$s") 2>/dev/null")"
    if [ "$state" != "active" ]; then
      die "station '$s' is $state, not active. This script never starts a station:
       starting one it did not stop corrupts somebody else's measurement." 2
    fi
  done
  ok "both stations active"
  if ssh -n -o ConnectTimeout=25 "$LAB" \
    'python3 /data/vms/streamhost/serve/check-stream-tickets.py' >/dev/null 2>&1; then
    ok "stream tickets accepted"
  else
    bad "check-stream-tickets.py is unhappy — sessions may be refused before any probe runs"
  fi
fi

# --- input-router counters: CORROBORATION ONLY ------------------------------
# Frozen counters were one of the four true-and-meaningless indicators, so these
# never decide anything. They are recorded because the ADVANCE across the churn
# is the one place they carry weight: counters stuck at the first session's
# totals is precisely what the rhapsody failure looked like.
counters() {
  [ "$DRY" = 1 ] && {
    printf '  [would] read [input-router] counters for %s\n' "$1"
    return 0
  }
  ssh -n -o ConnectTimeout=20 "$LAB" \
    "journalctl -u streamhost@$(printf '%q' "$1") -n 400 --no-pager 2>/dev/null |
       grep -F '[input-router]' | tail -1" 2>/dev/null
}

# k=v pairs -> JSON. Unreadable counters become null, and the verdict then
# reports the mechanism UNASSERTED rather than inventing a clean one.
counters_json() {
  printf '%s\n' "$1" | python3 -c '
import json, re, sys
text = sys.stdin.read()
pairs = dict(re.findall(r"([a-z-]+)=(\d+)", text))
print(json.dumps({k: int(v) for k, v in pairs.items()}) if pairs else "null")
'
}

# PER-STATION TEMPLATE PROVISIONING IS A PRECONDITION, and a missing bank is
# INCONCLUSIVE. A NOTFOUND from the cursor matcher was once a bank that did not
# cover the station's glyph set -- a harness gap, not a device fault. Rolling a
# healthy station back for that is the flapping this gate must never do.
TEMPLATES="unknown"
if [ -n "$BANK" ]; then
  if [ -f "$BANK" ]; then
    TEMPLATES="ok"
    ok "cursor template bank present ($BANK)"
  else
    TEMPLATES="missing"
    skip "cursor template bank $BANK is MISSING — the pointer leg cannot be judged;"
    skip "  this run will be INCONCLUSIVE, which is not a failure and rolls nothing back"
  fi
fi

mkdir -p "$EVIDENCE"
C_BEFORE="$(counters "$STATION")"

# --- the browser leg, candidate and control IN THE SAME PASS ----------------
if [ ! -f "$PROBE" ]; then die "missing $PROBE" 3; fi
# probe_args <station> <rect> <point> <guest>
probe_args() {
  printf '%s' "--station $1 --sessions $SESSIONS --abandon-at $ABANDON --rect $2 --sample-ms $SAMPLE_MS"
  [ -n "${3:-}" ] && printf ' --point %s' "$3"
  [ -n "${4:-}" ] && printf ' --guest %s' "$4"
  [ -n "$BASE" ] && printf ' --base %s' "$BASE"
}
# THE CONTROL USES ITS OWN SPEC, NOT THE CANDIDATE'S. Caught by reading a
# --dry-run: the control was inheriting the candidate's watchRect, so it would
# have watched a rectangle meaningless for itself, shown no motion, and failed
# every run. Every verdict would then collapse to "candidate and control both
# failed -> harness suspect", and the gate could never blame a station for
# anything. A control that cannot pass is not a control.
CTRL_SPEC="$(read_spec "$CONTROL")"
case "$CTRL_SPEC" in
  ERR*)
    die "control station '$CONTROL' has no acceptance: stanza of its own.
       A control needs its own watched rectangle — sharing the candidate's would
       make it fail every run, and a control that cannot pass turns every verdict
       into 'harness suspect' and blames nobody for anything."
    ;;
esac
ctrl_get() { printf '%s\n' "$CTRL_SPEC" | sed -n "s/^$1=//p" | head -1; }
CTRL_RECT="$(ctrl_get rect)"
CTRL_POINT="$(ctrl_get point)"
CTRL_GUEST="$(ctrl_get guest)"
[ -n "$CTRL_RECT" ] || die "control station '$CONTROL' declares no acceptance.watchRect"

CAND_JSON="$EVIDENCE/$STATION.json"
CTRL_JSON="$EVIDENCE/$CONTROL.control.json"

if [ "$DRY" = 1 ]; then
  printf '  [would] node %s %s > %s   (candidate)\n' "$PROBE" "$(probe_args "$STATION" "$RECT" "$POINT" "$GUEST")" "$CAND_JSON"
  printf '  [would] node %s %s > %s   (control, same pass)\n' "$PROBE" "$(probe_args "$CONTROL" "$CTRL_RECT" "$CTRL_POINT" "$CTRL_GUEST")" "$CTRL_JSON"
  printf '  [would] compare, then apply the rollback decision matrix\n'
  exit 0
fi
command -v node >/dev/null 2>&1 || die "node not found — the browser leg cannot run here" 3

say "-- driving $SESSIONS session(s) against candidate and control simultaneously --"
# shellcheck disable=SC2046 # probe_args is a deliberately word-split argv line
node "$PROBE" $(probe_args "$STATION" "$RECT" "$POINT" "$GUEST") >"$CAND_JSON" &
cand_pid=$!
# shellcheck disable=SC2046
node "$PROBE" $(probe_args "$CONTROL" "$CTRL_RECT" "$CTRL_POINT" "$CTRL_GUEST") >"$CTRL_JSON" &
ctrl_pid=$!
wait "$cand_pid"
cand_rc=$?
wait "$ctrl_pid"
ctrl_rc=$?
C_AFTER="$(counters "$STATION")"

C_JSON="{\"before\": $(counters_json "$C_BEFORE"), \"after\": $(counters_json "$C_AFTER")}"
verdict() { # verdict <json> <rc> [counters] [templates] -> STATE — reason
  python3 scripts/dev/station_accept_verdict.py "$1" "$2" "${3:-}" "${4:-unknown}"
}
CAND="$(verdict "$CAND_JSON" "$cand_rc" "$C_JSON" "$TEMPLATES")"
CTRL="$(verdict "$CTRL_JSON" "$ctrl_rc")"
say ""
say "  candidate $STATION: $CAND"
say "  control   $CONTROL: $CTRL"
say "  [input-router] before: ${C_BEFORE:-<none>}"
say "  [input-router] after : ${C_AFTER:-<none>}  (corroboration only, never the gate)"

case "${CAND%% *}/${CTRL%% *}" in
  DISAGREE/*)
    bad "two checks DISAGREE about $STATION — this gate does not adjudicate"
    say "         Both results are above, and neither is preferred. The last time a"
    say "         gate silently trusted the passing check it certified a fix that was"
    say "         necessary but not sufficient, and hid two further defects behind the"
    say "         same symptom. A human resolves this, not a tie-break rule."
    rc=1
    ;;
  NORUN/*)
    skip "INCONCLUSIVE — nothing was proven about $STATION, and nothing may be rolled back"
    rc=10
    ;;
  PASS/*)
    ok "$STATION reacted through the shipping path, across session churn"
    [ "${CTRL%% *}" = PASS ] || skip "the control did not pass — the candidate's pass still stands, but look at the harness"
    rc=0
    ;;
  FAIL/PASS)
    bad "$STATION failed while the control passed — the station is at fault"
    rc=1
    ;;
  *)
    skip "candidate AND control both failed — harness or box suspect, NOT the station"
    say "         Nothing should be rolled back on this. Rolling a healthy release"
    say "         back on a harness fault is rollback flapping, which is worse than"
    say "         no gate at all. A human must look."
    rc=10
    ;;
esac

say ""
say "Evidence: $CAND_JSON, $CTRL_JSON, plus screenshots under \$HOME/e2e/shots."
say "No check above says the frame shows the MACHINE's own screen. A desktop and a"
say "boot console pass the same pixel statistics. That judgement is still a human's,"
say "and it is why this script never prints the word every wave report wants to write."
exit "$rc"
