#!/usr/bin/env bash
# =============================================================================
# tile-accept.sh — the post-migration health bundle for ONE station, as one call.
#
# WHY THIS EXISTS
#   scripts/dev/migrate-tile.sh ends at "HUMAN REQUIRED" with two PNG paths, and
#   everything after that was done by hand, differently, by each of the three
#   agents who ran a wave on 2026-08-10. This is that tail, written down: unit,
#   daemon health, stream-ticket acceptance, the exec channel, the checkpoint
#   restore, and one fresh framebuffer measured by scripts/dev/frame-compare.py.
#
#   The order is not arbitrary — each step also sets up the next. `labctl exec`
#   resumes an idle-paused guest and re-proves the suite from INSIDE the
#   production boot (not the builder's); `labctl reset` proves `loadvm golden`
#   restores under the station's OWN qemu-streamhost.sh, which migrate-tile.sh
#   never checks when the builder captured the checkpoint itself (it returns at "golden
#   snapshot already present" — all six wave-4 stations took that branch, and the
#   plan doc says that class "surfaces at some visitor's first reset"); and
#   shooting AFTER that reset is what makes the AFTER frame the same KIND of
#   frame as migrate-tile.sh's BEFORE, which is reset + settle + shot. Comparing
#   a settled checkpoint against a just-started unit was never a fair test.
#
# WHAT IT WILL NOT DO
#   * It never starts a stopped station. Four kiosks are down right now and
#     only three of them are declared anywhere (indyr4400, star, nextstep are
#     the operator's pause; amiga fell over at 02:12 on 2026-08-10 with
#     ExecMainStatus=15). Starting someone else's stopped station corrupts a
#     measurement campaign, and "it exists" is not "it is mine" — a station this
#     script did not stop is a refusal, not a silent `systemctl start`.
#   * It never prints ACCEPTED. Every check here is mechanical; whether the
#     frame shows the MACHINE's own screen is a judgement no pixel statistic
#     makes, and the summary says so on its last line.
#
# usage: tile-accept.sh <tile> [options]
#   --before PNG     also compare the fresh frame against this one (the
#                    migration's before-bookworm.png) via frame-compare.py
#   --no-reset       skip the `loadvm golden` proof (the summary then says
#                    RESET NOT PROVEN — a skipped check is never a silent pass)
#   --settle N       seconds between the reset and the shot (default 20),
#                    applied identically to both sides of any comparison
#   --expect WxH     require this framebuffer geometry
#   --evidence DIR   where the PNGs are copied locally (default
#                    ./tile-accept-evidence/<tile>)
#   --keep           leave the labhost-side run directory in place
#   -n, --dry-run    print every command this would run, touch nothing
#
# exit: 0  every mechanical check passed (a human still owes the identity call)
#       1  a check FAILED — named in the summary
#       2  usage, unknown station, or a refusal (an inactive station, mainly)
#       3  ssh lab unreachable — nothing was verified
#      10  the frame comparison says DIFFERS: a human must look. Not a failure,
#          and deliberately not 1 — see frame-compare.py's exit table.
# =============================================================================
set -uo pipefail

LAB="${LAB:-lab}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE="$HERE/frame-compare.py"
TICKETS="${TILE_ACCEPT_TICKETS:-/data/vms/streamhost/serve/check-stream-tickets.py}"
# Every box-side artefact of this run lives in ONE namespaced directory under
# the clone root, so two agents running this concurrently cannot collide and
# neither can write anywhere near a production station directory.
RUN_TAG="$$-$(date -u +%Y%m%dT%H%M%SZ)"

TILE=""
BEFORE=""
EVIDENCE=""
EXPECT=""
SETTLE=20
DO_RESET=1
KEEP=0
DRY=0

die() {
  printf 'tile-accept: %s\n' "$1" >&2
  exit "${2:-2}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --before | --evidence | --expect | --settle)
      [ "$#" -ge 2 ] || die "$1 needs a value"
      case "$1" in
        --before) BEFORE="$2" ;;
        --evidence) EVIDENCE="$2" ;;
        --expect) EXPECT="$2" ;;
        --settle) SETTLE="$2" ;;
      esac
      shift
      ;;
    --no-reset) DO_RESET=0 ;;
    --keep) KEEP=1 ;;
    -n | --dry-run) DRY=1 ;;
    -h | --help)
      sed -n '4,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*) die "unknown option: $1" ;;
    *)
      [ -z "$TILE" ] || die "one tile per run (got '$TILE' and '$1')"
      TILE="$1"
      ;;
  esac
  shift
done

[ -n "$TILE" ] || die "usage: tile-accept.sh <tile> [--before PNG] [--no-reset] [--settle N]"
[ -f "$COMPARE" ] || die "frame-compare.py is missing next to this script ($COMPARE)"
case "$SETTLE" in '' | *[!0-9]*) die "--settle wants whole seconds, got '$SETTLE'" ;; esac
[ -z "$BEFORE" ] || [ -f "$BEFORE" ] || die "--before: no such file: $BEFORE"
EVIDENCE="${EVIDENCE:-./tile-accept-evidence/$TILE}"
RUNDIR="/data/vms/sandbox/tile-accept/$TILE-$RUN_TAG"

# --- reporting -------------------------------------------------------------
# One row per check, printed together at the end: a check whose result is only
# visible in the middle of 200 lines of scrollback is a check nobody reads.
ROWS=()
FAILED=0
OWED=()

record() { # record <check> <verdict> <detail>
  ROWS+=("$(printf '%-8s %-14s %s' "$1" "$2" "$3")")
  printf '  %-8s %-14s %s\n' "$1" "$2" "$3"
  case "$2" in FAIL) FAILED=$((FAILED + 1)) ;; esac
}

owes() { OWED+=("$1"); }

step() { printf '\n== %s\n' "$1"; }

box() { # box <command…> — a read of the box; stdout is the answer
  if [ "$DRY" -eq 1 ]; then
    printf "  [would] ssh %s '%s'\n" "$LAB" "$*" >&2
    return 0
  fi
  ssh -o ConnectTimeout=15 "$LAB" "$@"
}

# --- 0. labhost has to be there --------------------------------------------
if [ "$DRY" -eq 0 ] && ! ssh -o ConnectTimeout=8 -o BatchMode=yes "$LAB" true 2>/dev/null; then
  die "ssh $LAB unreachable — NOTHING was verified (this is not a pass)" 3
fi

printf 'tile-accept: %s   (box %s, run %s)\n' "$TILE" "$LAB" "$RUN_TAG"
printf 'protocol:    %s settle %ss, then labctl shot\n' \
  "$([ "$DO_RESET" -eq 1 ] && echo 'labctl reset,' || echo 'no reset,')" "$SETTLE"

# --- 1. facts ---------------------------------------------------------------
# labctl facts is the single source for the identity/unit/disk/exec facts this
# script would otherwise re-derive out of ten files, the way migrate-tile.sh's
# own 35-line inline probe does.
step "1/7  facts — labctl facts $TILE --json"
FACTS=""
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s 'labctl facts %s --json'\n" "$LAB" "$TILE"
else
  FACTS="$(ssh -o ConnectTimeout=15 "$LAB" "labctl facts $(printf '%q' "$TILE") --json" 2>&1)" ||
    die "labctl facts failed for '$TILE':
$FACTS" 2
fi

FACT_TSV="$(mktemp "${TMPDIR:-/tmp}/tile-accept.XXXXXX")" || die "mktemp failed"
# shellcheck disable=SC2317 # invoked by the EXIT trap
cleanup() {
  rm -f "$FACT_TSV"
  if [ "$DRY" -eq 0 ] && [ "$KEEP" -eq 0 ] && [ -n "${RUNDIR_MADE:-}" ]; then
    ssh -o ConnectTimeout=15 "$LAB" "rm -rf -- $(printf '%q' "$RUNDIR")" >/dev/null 2>&1 ||
      printf 'tile-accept: could not remove the box run dir %s — remove it by hand\n' "$RUNDIR" >&2
  fi
}
trap cleanup EXIT

if [ "$DRY" -eq 0 ]; then
  printf '%s' "$FACTS" | python3 -c '
import json, sys
f = json.load(sys.stdin)
def out(k, v):
    print("%s\t%s" % (k, "" if v is None else v))
out("id", f.get("id"))
out("sh_tile", f.get("sh_tile"))
out("unit", (f.get("unit") or {}).get("name"))
out("state", (f.get("unit") or {}).get("state"))
out("kind", f.get("kind"))
out("backing", (f.get("disk") or {}).get("backing"))
out("snapshots", ",".join((f.get("snapshots") or [])))
out("resettable", f.get("golden_resettable"))
out("exec_kind", (f.get("exec") or {}).get("kind"))
out("suite_declared", (f.get("suite") or {}).get("declared"))
out("suite_actual", (f.get("suite") or {}).get("actual"))
out("commit", (f.get("repo") or {}).get("commit"))
' >"$FACT_TSV" || die "labctl facts returned something that is not the JSON we know" 2
fi

fact() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$FACT_TSV"; }

if [ "$DRY" -eq 0 ]; then
  record FACTS ok "id=$(fact id) SH_STATION=$(fact sh_tile) kind=$(fact kind) (repo @ $(fact commit))"
  if [ -z "$(fact suite_declared)" ]; then
    record SUITE n/a "not a bridge tile — no registry/bridge-suites.json entry; backing=$(fact backing)"
  else
    record SUITE info "declared=$(fact suite_declared) actual=$(fact suite_actual) backing=$(fact backing)"
  fi
  [ "$(fact suite_declared)" = "$(fact suite_actual)" ] ||
    owes "the ledger says $(fact suite_declared) and the disk says $(fact suite_actual) — flip registry/bridge-suites.json in the same commit as the prose"
fi

# --- 2. the unit ------------------------------------------------------------
step "2/7  unit"
UNIT="$(fact unit)"
STATE="$(fact state)"
if [ "$DRY" -eq 1 ]; then
  printf '  [would] read unit state from the facts above\n'
elif [ "$STATE" = "active" ]; then
  record UNIT PASS "$UNIT is active"
else
  record UNIT FAIL "$UNIT is $STATE"
  cat >&2 <<EOM

tile-accept: REFUSING to go further, and refusing to start it.
  $UNIT is '$STATE'. Four bridge tiles are down: indyr4400, star and nextstep
  are the operator's deliberate quiesce, and amiga fell over on its own at
  02:12 on 2026-08-10 (ExecMainStatus=15). Starting a tile someone else stopped
  ruins a measurement campaign; starting one that FELL OVER hides the outage
  behind a migration. Decide which of those this is, by hand, first.
EOM
  exit 2
fi

# --- 3. daemon health -------------------------------------------------------
step "3/7  daemon health — labctl health $TILE"
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s '%s'\n" "$LAB" "labctl health $TILE"
else
  HEALTH="$(box "labctl health $(printf '%q' "$TILE")" 2>&1)"
  OVERALL="$(printf '%s\n' "$HEALTH" | sed -n 's/^Overall: *//p' | head -1)"
  QSTATE="$(printf '%s\n' "$HEALTH" | sed -n 's/^QEMU state: *//p' | head -1)"
  case "$OVERALL" in
    HEALTHY*) record HEALTH PASS "Overall: $OVERALL; QEMU state: ${QSTATE:-n/a}" ;;
    "") record HEALTH FAIL "labctl health printed no Overall line" ;;
    *) record HEALTH FAIL "Overall: $OVERALL" ;;
  esac
fi

# --- 4. stream tickets ------------------------------------------------------
# The fleet checker has no per-station mode and its exit code covers every station, so
# an unrelated broken exhibit would turn this red. We read OUR row and ignore
# its fleet-wide exit code, on purpose.
step "4/7  stream ticket — this tile's row from check-stream-tickets.py"
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s '%s'\n" "$LAB" "python3 $TICKETS"
else
  TROW="$(box "python3 $(printf '%q' "$TICKETS") 2>&1 | grep -E '^[[:space:]]+(ok|FAIL|SKIP)[[:space:]]+$(fact id)([[:space:]]|\$)'")"
  case "$TROW" in
    *ok*) record TICKET PASS "$(printf '%s' "$TROW" | sed 's/^ *//')" ;;
    "") record TICKET FAIL "no row for '$(fact id)' in the fleet ticket check" ;;
    *) record TICKET FAIL "$(printf '%s' "$TROW" | sed 's/^ *//')" ;;
  esac
fi

# --- 5. exec channel --------------------------------------------------------
# For a kiosk /etc/bridge/suite is the suite the PRODUCTION boot actually
# has, which is a different claim from the backing file the disk records.
step "5/7  exec channel"
EXEC_KIND="$(fact exec_kind)"
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s '%s'\n" "$LAB" "labctl exec $TILE 'cat /etc/bridge/suite || uname -sr'"
elif [ -z "$EXEC_KIND" ]; then
  record EXEC none "this tile declares no exec channel — nothing to answer (not a failure)"
  owes "no exec channel: the in-guest suite could not be re-proved from inside the production boot"
else
  EOUT="$(box "labctl exec $(printf '%q' "$TILE") 'cat /etc/bridge/suite 2>/dev/null || uname -sr'" 2>&1)"
  ERC=$?
  # ssh's own "Permanently added …" chatter is not the guest's answer.
  ESAY="$(printf '%s\n' "$EOUT" | grep -v '^Warning: Permanently added' | grep -v '^[[:space:]]*$' | tail -1)"
  ACTUAL="$(fact suite_actual)"
  if [ "$ERC" -ne 0 ]; then
    record EXEC FAIL "$EXEC_KIND channel returned $ERC: $(printf '%s' "$EOUT" | tr '\n' ' ' | cut -c1-60)"
  elif [ -n "$ACTUAL" ] && [ "$ESAY" != "$ACTUAL" ] && printf '%s' "$ESAY" | grep -qx '[a-z]*'; then
    # The disk's backing file and the booted root are two different claims about
    # one suite. When they disagree the station is running something nobody
    # declared, and that is exactly what a migration must not ship.
    record EXEC FAIL "in-guest suite is '$ESAY' but the disk backs onto '$ACTUAL'"
  else
    record EXEC PASS "$EXEC_KIND says: $ESAY (production boot; disk says $ACTUAL)"
  fi
fi

# --- 6. the golden restore --------------------------------------------------
step "6/7  golden — does loadvm restore under the tile's OWN launcher?"
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s '%s'\n" "$LAB" "labctl reset $TILE"
  printf '  [would] sleep %s   (settle, identical on both sides of the compare)\n' "$SETTLE"
elif [ "$DO_RESET" -eq 0 ]; then
  record GOLDEN skipped "--no-reset: snapshots=[$(fact snapshots)] present, loadvm NOT proven"
  owes "RESET NOT PROVEN — run again without --no-reset before you believe the golden"
elif [ "$(fact resettable)" != "True" ] && [ "$(fact kind)" = "bridge" ]; then
  # A kiosk without a golden is a migration failure: migrate-tile.sh bakes
  # one, and a visitor's reset button restores it.
  record GOLDEN FAIL "a bridge tile with NO golden snapshot (snapshots=[$(fact snapshots)])"
elif [ "$(fact resettable)" != "True" ]; then
  record GOLDEN cold "no golden snapshot — labctl refuses to reset this tile (it boots cold)"
  owes "no golden snapshot: 'labctl reset' cannot restore this tile, so nothing here proved a restore"
else
  ROUT="$(box "labctl reset $(printf '%q' "$TILE") && sleep $(printf '%q' "$SETTLE")" 2>&1)"
  RRC=$?
  if [ "$RRC" -eq 0 ]; then
    record GOLDEN PASS "$(printf '%s' "$ROUT" | head -1)"
  else
    record GOLDEN FAIL "labctl reset exited $RRC: $(printf '%s' "$ROUT" | tr '\n' ' ' | cut -c1-70)"
  fi
fi

# --- 7. one fresh framebuffer ----------------------------------------------
step "7/7  framebuffer — shot, then frame-compare.py"
FRAME_RC=0
if [ "$DRY" -eq 1 ]; then
  printf "  [would] ssh %s '%s'\n" "$LAB" "mkdir -p $RUNDIR && labctl shot $TILE $RUNDIR/after.png"
  printf '  [would] pipe %s to python3 on the box against %s\n' "$COMPARE" "${BEFORE:-<no --before>}"
else
  RUNDIR_MADE=1
  box "mkdir -p $(printf '%q' "$RUNDIR")" >/dev/null || die "cannot create $RUNDIR on the box" 2
  [ "$DO_RESET" -eq 1 ] || box "sleep $(printf '%q' "$SETTLE")" >/dev/null
  if ! SHOT_OUT="$(box "labctl shot $(printf '%q' "$TILE") $(printf '%q' "$RUNDIR/after.png")" 2>&1)"; then
    record FRAME FAIL "labctl shot failed: $(printf '%s' "$SHOT_OUT" | tr '\n' ' ' | cut -c1-70)"
  else
    ARGS=()
    if [ -n "$BEFORE" ]; then
      scp -q "$BEFORE" "$LAB:$RUNDIR/before.png" || die "could not copy $BEFORE to the box" 2
      ARGS+=("$RUNDIR/before.png" "$RUNDIR/after.png")
    else
      ARGS+=(--frame "$RUNDIR/after.png")
    fi
    ARGS+=(--label "$TILE")
    [ -z "$EXPECT" ] || ARGS+=(--expect "$EXPECT")
    # The frames are on labhost and labhost has numpy+Pillow, so the analysis
    # runs where the pixels are; the script travels on stdin, never on argv.
    REMOTE_ARGS="$(printf ' %q' "${ARGS[@]}")"
    FRAME_OUT="$(ssh -o ConnectTimeout=30 "$LAB" "python3 -${REMOTE_ARGS}" <"$COMPARE" 2>&1)"
    FRAME_RC=$?
    printf '%s\n' "$FRAME_OUT" | sed 's/^/  | /'
    VERDICT="$(printf '%s\n' "$FRAME_OUT" | sed -n 's/^VERDICT \([A-Z-]*\).*/\1/p' | head -1)"
    case "$FRAME_RC" in
      0) record FRAME PASS "${VERDICT:-?} — floor cleared" ;;
      10) record FRAME differs "${VERDICT:-DIFFERS} — a human must look; this is not a failure" ;;
      *) record FRAME FAIL "${VERDICT:-frame-compare rc=$FRAME_RC} — see the report above" ;;
    esac
    mkdir -p "$EVIDENCE" && scp -q "$LAB:$RUNDIR/after.png" "$EVIDENCE/after-$RUN_TAG.png" &&
      printf '  fresh frame: %s\n' "$EVIDENCE/after-$RUN_TAG.png"
  fi
fi

# --- summary ----------------------------------------------------------------
printf '\n================================ %s ================================\n' "$TILE"
for r in "${ROWS[@]}"; do printf '  %s\n' "$r"; done
if [ "${#OWED[@]}" -gt 0 ]; then
  printf '\nSTILL OWED:\n'
  for o in "${OWED[@]}"; do printf '  - %s\n' "$o"; done
fi
printf '\nNo check above says the frame is the MACHINE'\''s own screen — a Workbench\n'
printf 'desktop and a GRUB console pass the same pixel statistics. That judgement\n'
printf 'is still a human'\''s, and it is the whole reason this script never prints\n'
printf 'the word every wave report wanted to write.\n'

if [ "$DRY" -eq 1 ]; then
  printf '\n(--dry-run: nothing above was executed.)\n'
  exit 0
fi
[ "$FAILED" -eq 0 ] || exit 1
[ "$FRAME_RC" -ne 10 ] || exit 10
exit 0
