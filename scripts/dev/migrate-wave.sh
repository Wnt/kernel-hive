#!/usr/bin/env bash
# =============================================================================
# migrate-wave.sh — run scripts/dev/migrate-tile.sh over a WAVE of kiosks
#
# migrate-tile.sh does one station. A wave is several, and on 2026-08-10 three
# agents ran three waves in parallel and each hand-rolled the same three things
# around it — a concurrency cap, a labhost-load check, and a summary table typed by
# hand into BRIDGE-TRIXIE-MIGRATION.md. None of that was code, so none of it was
# enforced, and the two constraints that matter most were prose in a handover:
#
#   * LABHOST LOAD. Four parallel builds once took labhost from load 9 to 34 on 16
#     threads and starved everything else on it, including someone's timing run.
#     So a station is LAUNCHED only while the 1-minute load is under a ceiling —
#     checked before each launch, and waited out rather than piled onto.
#   * THE SHARED MAME CHROOT. Every MAME builder chroots into the SAME
#     directory and mounts API filesystems in it; two at once is the failure
#     that took the host's /dev/pts down and broke every new login on labhost.
#     chroot-guard fixed the mount-propagation half. The who-owns-it half is
#     here: those stations form a SERIALIZATION GROUP declared in
#     registry/bridge-waves.json, and the group holds ONE claim taken by
#     `mkdir` ON labhost — so it serializes across agents, not merely within
#     one wave. The claim IS the proof (AGENTS.md "claim atomically"): a claim
#     this run did not create is never adopted, it is reported with its holder
#     and that station simply does not start.
#
# The group membership is declared AND derived: registry/bridge-waves.json
# lists the stations, this script re-derives them from the builders, and a
# disagreement refuses the whole run. A hand list nobody re-checks is how a new
# chroot station joins the fleet without joining the group.
#
# WHAT IT DOES NOT DO. It never claims visual acceptance — neither does
# migrate-tile.sh, and for the same reason: the failure this migration produces
# (amiga losing Mesa and rendering black) is invisible to every log and exit
# code. It collects the BEFORE/AFTER PNGs per station and ends by naming the stations
# a human still owes a compare. It also cannot cap the builders' own JOBS: the
# only environment migrate-tile.sh passes to a builder is BRIDGE_SUITE, so the
# load ceiling is the whole of this tool's back-pressure. Saying otherwise
# would be a knob that reports success while doing nothing.
#
# A failed station does NOT abort the wave — migrate-tile.sh has already rolled
# that station back on its own — and the report says which stations were never
# attempted, and why.
#
# usage: migrate-wave.sh [TILE…] | --wave <N> | --remaining
#   -j, --jobs N        stations in flight at once (default 2)
#   --max-load F        do not LAUNCH while labhost's 1-min load is >= F
#                       (default 10.0 of 16 threads; running stations continue)
#   --allow-stopped     run stations whose streamhost@ unit is inactive. Default
#                       refuses them BY NAME: four of the remaining stations are
#                       stopped, three of them on purpose, and migrate-tile.sh
#                       would take its BEFORE frame from a cold start and
#                       `systemctl start` the station at step 8
#   --flip              pass --flip to migrate-tile.sh (ledger edit only; you
#                       still owe the prose in the same commit)
#   --evidence DIR      per-station logs + PNGs (default $TMPDIR/migrate-wave/<label>)
#   -n, --dry-run       print the plan table and stop. Nothing is started, no
#                       claim is taken
#   --json              machine-readable per-station result (in addition to the table)
#
# env: LAB=lab  MIGRATE_WAVE_STALL=1800 (s with nothing runnable before giving up)
#      MIGRATE_WAVE_TILE_CMD=<path>  SELF-TEST ONLY — replaces migrate-tile.sh.
#                                    A run with it set says so, loudly, twice.
#
# exit: 0 every selected station migrated (each still owes a human frame compare)
#       1 at least one station did not migrate (rolled back / not attempted)
#       2 usage, or NOTHING was started — every station refused at preflight, or
#         none could ever be launched (a claim held elsewhere, load never fell)
#       3 box unreachable
# =============================================================================
set -uo pipefail

# The ledger's own values are what we act on; an experiment override leaking in
# from the environment would make every station agree with itself.
unset BRIDGE_SUITE

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB="${LAB:-lab}"
SSH_OPTS=(-o ConnectTimeout=15)
TILES_ROOT="${BRIDGE_TILES_ROOT:-/data/vms/streamhost/stations}"
CLAIM_ROOT="${MIGRATE_WAVE_CLAIM_ROOT:-/run/kh-claims}"
MIGRATE_TILE="${MIGRATE_WAVE_TILE_CMD:-$REPO/scripts/dev/migrate-tile.sh}"
STALL="${MIGRATE_WAVE_STALL:-1800}"

JOBS=2
MAX_LOAD=10.0
ALLOW_STOPPED=0
DRY=0
AS_JSON=0
EVIDENCE=""
PASS=()
MODE=""
SEL=()

die() {
  printf 'migrate-wave: %s\n' "$1" >&2
  exit "${2:-2}"
}
log() { printf '[wave %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
step() { printf '\n== %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --wave)
      [ "$#" -ge 2 ] || die "--wave needs a wave name"
      [ -z "$MODE" ] || die "pick ONE of: tile list, --wave, --remaining"
      MODE=wave
      SEL=("$2")
      shift
      ;;
    --remaining)
      [ -z "$MODE" ] || die "pick ONE of: tile list, --wave, --remaining"
      MODE=remaining
      ;;
    -j | --jobs)
      [ "$#" -ge 2 ] || die "--jobs needs a number"
      JOBS="$2"
      shift
      ;;
    --max-load)
      [ "$#" -ge 2 ] || die "--max-load needs a number"
      MAX_LOAD="$2"
      shift
      ;;
    --evidence)
      [ "$#" -ge 2 ] || die "--evidence needs a directory"
      EVIDENCE="$2"
      shift
      ;;
    --allow-stopped) ALLOW_STOPPED=1 ;;
    --flip) PASS+=(--flip) ;;
    --json) AS_JSON=1 ;;
    -n | --dry-run) DRY=1 ;;
    -h | --help)
      sed -n '3,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ "${MODE:-tiles}" = tiles ] || die "pick ONE of: tile list, --wave, --remaining"
      MODE=tiles
      SEL+=("$1")
      ;;
  esac
  shift
done
[ -n "$MODE" ] || die "usage: migrate-wave.sh [TILE…] | --wave <N> | --remaining"
case "$JOBS" in '' | *[!0-9]*) die "--jobs must be a positive integer (got '$JOBS')" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"
awk -v c="$MAX_LOAD" 'BEGIN{exit !(c+0 > 0)}' || die "--max-load must be a positive number"
[ -x "$MIGRATE_TILE" ] || die "not executable: $MIGRATE_TILE"

LABEL="$MODE"
[ "$MODE" = wave ] && LABEL="wave-${SEL[0]}"
[ "$MODE" = tiles ] && LABEL="adhoc-$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE="${EVIDENCE:-${TMPDIR:-/tmp}/migrate-wave/$LABEL}"
TAG="migrate-wave/$LABEL/$(hostname -s 2>/dev/null || echo host)/$$"

if [ -n "${MIGRATE_WAVE_TILE_CMD:-}" ]; then
  printf '\n!! MIGRATE_WAVE_TILE_CMD is set: this run drives %s, NOT migrate-tile.sh.\n' \
    "$MIGRATE_TILE" >&2
  printf '!! It is a self-test of the scheduler. No tile is being migrated.\n\n' >&2
fi

# --- plan: select, validate, group ------------------------------------------
# migrate-wave-plan.py does the whole declaration side in one pass, because the
# three answers are entangled: which stations, which are refused before anything
# starts, and which serialization group each belongs to. It exits 2 on a ledger
# / roster / group disagreement rather than running a wave nobody planned. It is
# a real file rather than a heredoc so ruff and a reader can both see it.
step "plan: registry/bridge-suites.json + registry/bridge-waves.json"
PLAN="$(python3 "$REPO/scripts/dev/migrate-wave-plan.py" "$REPO" "$MODE" "${SEL[@]}")" || exit 2

declare -A SUITE=() GROUP=() BUILDER=() WAVE=() REFUSAL=() UNIT=() STATE=()
declare -A VERDICT=() RC=() SECS=() LOGP=() RCF=() START=() PID=() OWNER=()
ORDER=()
while IFS=$'\t' read -r t s g b w r; do
  [ -n "$t" ] || continue
  ORDER+=("$t")
  SUITE["$t"]="$s"
  GROUP["$t"]="$g"
  BUILDER["$t"]="$b"
  WAVE["$t"]="$w"
  REFUSAL["$t"]="$r"
done <<<"$PLAN"
[ "${#ORDER[@]}" -gt 0 ] || die "the plan is empty"

# --- box preflight: unit identity and state ---------------------------------
step "preflight: the box"
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  echo "migrate-wave: ssh $LAB unreachable — nothing was touched. There is no"
  echo "  offline mode; see docs/lab/CLOUD-AGENTS.md if you are in a cloud VM."
  exit 3
fi

# shellcheck disable=SC2029 # the caller quotes its own %q substitutions
box_ro() { ssh "${SSH_OPTS[@]}" "$LAB" "$@"; }

read -r -d '' UNIT_PY <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
for tile in sys.argv[2:]:
    try:
        with open(os.path.join(root, tile, "signaling.json"), encoding="utf-8") as fh:
            sh = json.load(fh)["tile"]
    except Exception:  # noqa: BLE001 - any failure means "identity unknown"
        print("\t".join((tile, "-", "-", "no-signaling")))
        continue
    unit = "streamhost@%s" % sh
    out = subprocess.run(["systemctl", "is-active", unit], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True).stdout.strip()
    print("\t".join((tile, sh, unit, out or "unknown")))
PY
UNIT_OUT="$(printf '%s' "$UNIT_PY" |
  box_ro "python3 - $(printf '%q ' "$TILES_ROOT" "${ORDER[@]}")")" ||
  die "box preflight probe failed" 3
while IFS=$'\t' read -r t _sh u st; do
  [ -n "$t" ] || continue
  UNIT["$t"]="$u"
  STATE["$t"]="$st"
  [ "${REFUSAL[$t]}" = "-" ] || continue
  if [ "$st" != active ] && [ "$ALLOW_STOPPED" -eq 0 ]; then
    REFUSAL["$t"]="$u is $st — a stopped tile has no fair BEFORE frame (--allow-stopped)"
  fi
done <<<"$UNIT_OUT"

BOXLOAD="$(box_ro 'cut -d" " -f1 /proc/loadavg; nproc')" || die "cannot read the box load" 3
LOAD_NOW="$(printf '%s\n' "$BOXLOAD" | sed -n 1p)"
NPROC="$(printf '%s\n' "$BOXLOAD" | sed -n 2p)"
LOAD_AT=$SECONDS
LOAD_FAILS=0

# --- the plan table ---------------------------------------------------------
step "plan — $LABEL, ${#ORDER[@]} tile(s), -j $JOBS, load ceiling $MAX_LOAD of $NPROC threads"
printf '%-13s %-8s %-9s %-13s %-9s %s\n' TILE WAVE SUITE GROUP UNIT REFUSAL
PENDING=()
for t in "${ORDER[@]}"; do
  printf '%-13s %-8s %-9s %-13s %-9s %s\n' \
    "$t" "${WAVE[$t]}" "${SUITE[$t]}" "${GROUP[$t]}" "${STATE[$t]:-?}" \
    "$([ "${REFUSAL[$t]}" = "-" ] && echo "will run" || echo "${REFUSAL[$t]}")"
  if [ "${REFUSAL[$t]}" = "-" ]; then
    PENDING+=("$t")
  else
    VERDICT["$t"]=REFUSED
  fi
done
echo
echo "box 1-min load now $LOAD_NOW · evidence $EVIDENCE"
for g in $(printf '%s\n' "${GROUP[@]}" | sort -u); do
  [ "$g" = "-" ] && continue
  printf 'serialization group %s: at most one at a time, claimed at %s/%s\n' \
    "$g" "$CLAIM_ROOT" "$g"
done

if [ "${#PENDING[@]}" -eq 0 ]; then
  echo
  echo "Nothing to run: every selected tile was refused above. Nothing was started."
  exit 2
fi
if [ "$DRY" -eq 1 ]; then
  echo
  echo "--dry-run: the commands this wave would run, in this order:"
  for t in "${PENDING[@]}"; do
    printf '  MIGRATE_EVIDENCE=%s/%s %s %s%s\n' "$EVIDENCE" "$t" \
      "${MIGRATE_TILE/#$REPO\//}" "$t" \
      "$([ "${#PASS[@]}" -gt 0 ] && printf ' %s' "${PASS[*]}")"
  done
  echo
  echo "Nothing was started and no claim was taken."
  exit 0
fi

# --- claims: the mkdir IS the proof -----------------------------------------
declare -A TOLD=()
claim_take() {
  local name="$1" out
  out="$(
    box_ro "bash -s -- $(printf '%q ' "$CLAIM_ROOT" "$name" "$TAG")" <<'EOS'
set -u
root=$1 name=$2 tag=$3
mkdir -p "$root" || exit 2
if mkdir "$root/$name" 2>/dev/null; then
  { printf '%s\n' "$tag"; date -u +%FT%TZ; } >"$root/$name/holder"
  echo "TAKEN"; exit 0
fi
echo "HELD $(head -1 "$root/$name/holder" 2>/dev/null || echo '<no holder file>')"
exit 1
EOS
  )" || {
    log "serialization group '$name' is $out — not starting one of its tiles yet"
    if [ -z "${TOLD[$name]:-}" ]; then
      TOLD["$name"]=1
      log "  (a claim this run did not create is never adopted. If that holder is"
      log "   gone for good: ssh $LAB rm -rf $CLAIM_ROOT/$name)"
    fi
    return 1
  }
  log "claimed serialization group '$name' ($out)"
}

claim_release() {
  local name="$1"
  box_ro "bash -s -- $(printf '%q ' "$CLAIM_ROOT" "$name" "$TAG")" <<'EOS'
set -u
root=$1 name=$2 tag=$3
[ -d "$root/$name" ] || { echo "claim $name: not held; nothing to release"; exit 0; }
have=$(head -1 "$root/$name/holder" 2>/dev/null || true)
[ "$have" = "$tag" ] || { echo "REFUSING to release $name: held by '$have', not me" >&2; exit 1; }
rm -rf "${root:?}/${name:?}"; echo "claim $name: released"
EOS
}

INTERRUPTED=0
# shellcheck disable=SC2317 # reached through the EXIT/INT/TERM trap below
teardown() {
  local g t
  for g in "${!OWNER[@]}"; do
    [ -n "${OWNER[$g]}" ] || continue
    claim_release "$g" || true
    OWNER["$g"]=""
  done
  [ "$INTERRUPTED" -eq 1 ] && [ "${#PID[@]}" -gt 0 ] || return 0
  echo
  echo "INTERRUPTED with tiles in flight. migrate-tile.sh launches its builder"
  echo "DETACHED on the box, so killing this wrapper does NOT stop it — and a"
  echo "surviving builder writes to the overlay a rollback is about to restore"
  echo "(the decos/plus4 incident). Stop each builder group and read its log"
  echo "BEFORE touching any overlay; the pgid is in <log>.pid:"
  for t in "${!PID[@]}"; do
    printf '  %-12s /data/vms/sandbox/migrate-%s-trixie/build.log  (local: %s)\n' \
      "$t" "$t" "${LOGP[$t]:-?}"
  done
}
trap 'teardown' EXIT
trap 'INTERRUPTED=1; echo; log "interrupt — see the recovery block below"; exit 130' INT TERM

# --- scheduler ---------------------------------------------------------------
BOX_GONE=0
BLOCK=""
load_ok() {
  local now=$SECONDS
  if [ $((now - LOAD_AT)) -ge 15 ]; then
    if ! LOAD_NOW="$(box_ro 'cut -d" " -f1 /proc/loadavg')"; then
      LOAD_FAILS=$((LOAD_FAILS + 1))
      [ "$LOAD_FAILS" -ge 3 ] && BOX_GONE=1
      return 1
    fi
    LOAD_FAILS=0
    LOAD_AT=$now
  fi
  awk -v l="$LOAD_NOW" -v c="$MAX_LOAD" 'BEGIN{exit !(l+0 < c+0)}'
}

launch_tile() {
  local t="$1"
  local dir="$EVIDENCE/$t"
  mkdir -p "$dir" || die "cannot create the evidence dir $dir"
  LOGP["$t"]="$dir/migrate-tile.log"
  RCF["$t"]="$dir/wave.rc"
  rm -f "${RCF[$t]}"
  START["$t"]=$SECONDS
  (
    MIGRATE_EVIDENCE="$dir" "$MIGRATE_TILE" "$t" "${PASS[@]}" >"${LOGP[$t]}" 2>&1
    echo $? >"${RCF[$t]}"
  ) &
  PID["$t"]=$!
  log "started $t (group ${GROUP[$t]}, load $LOAD_NOW) -> ${LOGP[$t]}"
}

try_launch() {
  local -A blocked=()
  local t g i picked idx
  while [ "${#PID[@]}" -lt "$JOBS" ] && [ "${#PENDING[@]}" -gt 0 ] && [ "$BOX_GONE" -eq 0 ]; do
    if ! load_ok; then
      BLOCK="box 1-min load $LOAD_NOW >= ceiling $MAX_LOAD"
      return 0
    fi
    picked=""
    for i in "${!PENDING[@]}"; do
      t="${PENDING[$i]}"
      g="${GROUP[$t]}"
      if [ "$g" = "-" ] || { [ -z "${OWNER[$g]:-}" ] && [ -z "${blocked[$g]:-}" ]; }; then
        picked="$t"
        idx="$i"
        break
      fi
    done
    [ -n "$picked" ] || {
      BLOCK="every pending tile is in a serialization group that is busy"
      return 0
    }
    g="${GROUP[$picked]}"
    if [ "$g" != "-" ]; then
      claim_take "$g" || {
        blocked["$g"]=1
        continue
      }
      OWNER["$g"]="$picked"
    fi
    unset 'PENDING[idx]'
    PENDING=("${PENDING[@]}")
    launch_tile "$picked"
    BLOCK=""
  done
}

reap() {
  local t rc g
  for t in "${!PID[@]}"; do
    [ -s "${RCF[$t]}" ] || continue
    wait "${PID[$t]}" 2>/dev/null
    rc="$(tr -dc 0-9 <"${RCF[$t]}")"
    unset 'PID[$t]'
    SECS["$t"]=$((SECONDS - START[$t]))
    RC["$t"]="$rc"
    case "$rc" in
      0) VERDICT["$t"]=MIGRATED ;;
      1) VERDICT["$t"]=ROLLED-BACK ;;
      2) VERDICT["$t"]=REFUSED ;;
      3)
        VERDICT["$t"]=BOX-UNREACHABLE
        BOX_GONE=1
        ;;
      *) VERDICT["$t"]="FAILED" ;;
    esac
    log "finished $t: ${VERDICT[$t]} (rc=$rc, ${SECS[$t]}s)"
    g="${GROUP[$t]}"
    if [ "$g" != "-" ] && [ "${OWNER[$g]:-}" = "$t" ]; then
      claim_release "$g" || true
      OWNER["$g"]=""
    fi
  done
}

step "running"
PROGRESS=$SECONDS
SAID=$((SECONDS - 60))
while [ "${#PENDING[@]}" -gt 0 ] || [ "${#PID[@]}" -gt 0 ]; do
  before=$((${#PENDING[@]} + ${#PID[@]}))
  reap
  [ "$BOX_GONE" -eq 0 ] && try_launch
  [ $((${#PENDING[@]} + ${#PID[@]})) -ne "$before" ] && PROGRESS=$SECONDS
  # Say WHY nothing is starting. Waiting out a load spike looks identical to a
  # hang from the outside, and a silent wait is what makes people raise the cap.
  if [ -n "$BLOCK" ] && [ $((SECONDS - SAID)) -ge 60 ]; then
    log "holding off: $BLOCK (${#PENDING[@]} pending, ${#PID[@]} in flight)"
    SAID=$SECONDS
  fi
  if [ "$BOX_GONE" -eq 1 ] && [ "${#PID[@]}" -eq 0 ]; then
    BLOCK="the box became unreachable"
    break
  fi
  if [ "${#PID[@]}" -eq 0 ] && [ "${#PENDING[@]}" -gt 0 ] &&
    [ $((SECONDS - PROGRESS)) -ge "$STALL" ]; then
    BLOCK="${BLOCK:-nothing runnable} for ${STALL}s"
    break
  fi
  { [ "${#PENDING[@]}" -gt 0 ] || [ "${#PID[@]}" -gt 0 ]; } && sleep 10
done
for t in "${PENDING[@]}"; do VERDICT["$t"]=NOT-ATTEMPTED; done

# --- the report the orchestrator used to type by hand -----------------------
step "verdicts — $LABEL"
printf '%-13s %-15s %-4s %-8s %s\n' TILE VERDICT RC TIME EVIDENCE
FAILED=0
ATTEMPTED=0
OWES=()
for t in "${ORDER[@]}"; do
  v="${VERDICT[$t]:-NOT-ATTEMPTED}"
  note="${LOGP[$t]:-${REFUSAL[$t]}}"
  [ "$v" = NOT-ATTEMPTED ] && note="${BLOCK:-not reached}"
  [ -n "${RC[$t]:-}" ] && ATTEMPTED=$((ATTEMPTED + 1))
  [ "$v" = MIGRATED ] || FAILED=$((FAILED + 1))
  [ "$v" = MIGRATED ] && OWES+=("$t")
  printf '%-13s %-15s %-4s %-8s %s\n' "$t" "$v" "${RC[$t]:--}" \
    "$([ -n "${SECS[$t]:-}" ] && printf '%ss' "${SECS[$t]}" || echo -)" "$note"
done

if [ "$AS_JSON" -eq 1 ]; then
  {
    for t in "${ORDER[@]}"; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "${VERDICT[$t]:-NOT-ATTEMPTED}" \
        "${RC[$t]:-}" "${SECS[$t]:-}" "${GROUP[$t]}" "${REFUSAL[$t]}" "${LOGP[$t]:-}"
    done
  } | python3 -c 'import csv,json,sys
K=("tile","verdict","rc","seconds","group","refusal","log")
print(json.dumps([dict(zip(K,r)) for r in csv.reader(sys.stdin,delimiter="\t")],indent=2))'
fi

cat <<EOM

================================ HUMAN REQUIRED ================================
MECHANICAL results only. Neither this wave driver nor migrate-tile.sh claims
visual acceptance: a tile that renders black looks healthy in every log and
every exit code above.
EOM
if [ "${#OWES[@]}" -gt 0 ]; then
  echo "These tiles owe a BEFORE/AFTER frame compare, and the prose/ledger steps"
  echo "migrate-tile.sh printed in their logs:"
  for t in "${OWES[@]}"; do
    printf '  %-13s %s/{before-bookworm,after-trixie}.png\n' "$t" "$EVIDENCE/$t"
  done
else
  echo "No tile migrated, so no frame compare is owed."
fi
[ -n "$BLOCK" ] && printf '\nThe wave stopped launching because: %s\n' "$BLOCK"
printf '\n%d selected · %d attempted · %d migrated · evidence under %s\n' \
  "${#ORDER[@]}" "$ATTEMPTED" "${#OWES[@]}" "$EVIDENCE"

[ "$ATTEMPTED" -eq 0 ] && exit 2
[ "$FAILED" -eq 0 ] || exit 1
exit 0
