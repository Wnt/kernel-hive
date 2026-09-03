#!/usr/bin/env bash
# station-land.sh — the whole LANDING WINDOW for one new station, in ONE command.
#
# WHY. Nine parallel new-station waves on 2026-09-03 each landed by hand, one at
# a time, through a coordinator. A window took 5-25 minutes and almost none of
# it was thinking: take the lock, merge main, un-break the two SPA scene tables a
# clean-but-wrong merge had just produced, regenerate, run the gate, push,
# box-deploy, swap the golden, take the smoke rig down, station-up, re-home the
# claims, prove it on the framebuffer, deploy the SPA, re-arm the dark launches
# the SPA deploy had just wiped, release the lock. Every step is documented;
# the SEQUENCE was in a person's head, and the long windows were the ones where
# a step was forgotten and discovered three steps later.
#
#   usage: scripts/dev/station-land.sh <id> [options]
#     --dry-run             print every step and run NOTHING. Start here.
#     --golden PATH         swap this staged qcow2 in as the station disk
#     --merge BRANCH        merge this branch too (repeatable)
#     --x11warp HOST:N      prove the absolute pointer through this X display
#     --station-session S   claim owner after landing (default: station-<id>)
#     --no-spa              skip the SPA build + deploy
#     --no-push             stop before `git push` (rehearse the gate)
#     --keep-window         do not release the landing window at the end
#
# RUN IT FROM YOUR OWN /data SANDBOX WORKTREE, never the shared clone: it
# commits, pushes and hands labhost your tree. The pre-push gate is THE gate —
# this script does not reimplement it, it just stops when it goes red.
#
# ROLLBACK. A launcher and its disk are ONE unit (AGENTS.md rule 6): if the
# golden swap or the proofs fail, put the parked disk back AND leave the
# launcher at the commit that matches it. Every failing step prints the exact
# rollback line before it exits.
#
# WHAT THIS DELIBERATELY DOES NOT DO: recapture a checkpoint (checkpoint-guard
# only), restart the fleet (fleet_rollout.py), or decide that a station is
# ready. The framebuffer decides that, and a human looks at it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB="${LAB:-lab}"
BOX_STATIONS="/data/vms/streamhost/stations"
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/kh-session.sh" 2>/dev/null || true

id=""
golden=""
x11warp=""
station_session=""
dry=0
no_spa=0
no_push=0
keep_window=0
declare -a merges=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --no-spa) no_spa=1 ;;
    --no-push) no_push=1 ;;
    --keep-window) keep_window=1 ;;
    --golden)
      golden="$2"
      shift
      ;;
    --merge)
      merges+=("$2")
      shift
      ;;
    --x11warp)
      x11warp="$2"
      shift
      ;;
    --station-session)
      station_session="$2"
      shift
      ;;
    -h | --help)
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    -*)
      echo "station-land: unknown flag $1" >&2
      exit 2
      ;;
    *) id="$1" ;;
  esac
  shift
done
[ -n "$id" ] || {
  sed -n '13,23p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
case "$id" in *[!a-z0-9-]*)
  echo "station-land: bad station id '$id'" >&2
  exit 2
  ;;
esac
: "${station_session:=station-$id}"
tag="$(date +%Y%m%d-%H%M%S)"

step_label=""
step() {
  step_label="$*"
  printf '\n== %s\n' "$*"
}
say() { printf '   %s\n' "$*"; }
# Every mutation goes through run(): that is what makes --dry-run a real
# rehearsal rather than a promise. Nothing below may mutate anything, locally or
# on the box, except through this function.
run() {
  if [ "$dry" = 1 ]; then
    printf '   WOULD RUN: %s\n' "$*"
    return 0
  fi
  printf '   + %s\n' "$*"
  "$@"
}
rollback_hint=""
fail() {
  printf '\nstation-land: FAILED at step "%s": %s\n' "$step_label" "$1" >&2
  [ -n "$rollback_hint" ] && printf 'station-land: ROLLBACK: %s\n' "$rollback_hint" >&2
  [ "$keep_window" = 0 ] && [ "$dry" = 0 ] && release_window
  exit 1
}

WAVE_SH="$SCRIPT_DIR/wave.sh"
release_window() {
  [ -x "$WAVE_SH" ] || return 0
  "$WAVE_SH" land end "$id" || echo "station-land: WARNING: could not release the landing window" >&2
}

# ---- 0 preflight -------------------------------------------------------------
step "0 preflight"
say "station        : $id"
say "session        : ${KH_SESSION:-<unset>}  ->  $station_session"
say "worktree       : $REPO_ROOT"
say "mode           : $([ "$dry" = 1 ] && echo 'DRY RUN — nothing will be changed' || echo 'LIVE')"
[ -n "${KH_SESSION:-}" ] || fail "KH_SESSION is unset — run from a wt.sh sandbox worktree (AGENTS.md rule 3)"
[ -f "$REPO_ROOT/registry/stations/$id.json" ] || fail "registry/stations/$id.json does not exist"
[ "$REPO_ROOT" = "/home/wnt/kernel-hive" ] && fail "this is the shared clone — land from your own sandbox worktree (rule 3)"
branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[ "$branch" = "main" ] && fail "you are on main; land from your wave branch"
say "branch         : $branch"
if [ -n "$golden" ]; then
  case "$golden" in /*) ;; *) fail "--golden must be an absolute path ON THE BOX" ;; esac
  say "golden         : $golden  (parks the live disk as disk.qcow2.pre-$tag)"
fi
[ ${#merges[@]} -gt 0 ] && say "extra merges   : ${merges[*]}"

# ---- 1 the landing window ----------------------------------------------------
step "1 take the landing window"
if [ -x "$WAVE_SH" ]; then
  run "$WAVE_SH" land begin "$id" || fail "could not take the landing window (see: $WAVE_SH land status)"
else
  say "no wave.sh, serialise by hand — announce 'ready to land $id' and wait for 'go'"
  say "  (scripts/dev/wave.sh is agent A's deliverable; until it lands, two"
  say "   concurrent landings will conflict in the four append-only shared files)"
fi

# ---- 2 merge main (and any named branches) -----------------------------------
step "2 fetch + merge origin/main${merges[*]+ + ${merges[*]}}"
run git -C "$REPO_ROOT" fetch -q origin main || fail "git fetch failed"
run git -C "$REPO_ROOT" merge --no-edit origin/main ||
  fail "merge conflict with origin/main — resolve it, then re-run (the window is still yours)"
for b in ${merges[@]+"${merges[@]}"}; do
  run git -C "$REPO_ROOT" fetch -q origin "$b" || fail "git fetch origin $b failed"
  run git -C "$REPO_ROOT" merge --no-edit FETCH_HEAD || fail "merge conflict with $b"
done

# ---- 3 rebuild the two SPA scene tables --------------------------------------
# NOT a merge: main's table, plus THIS station's row at its lineup index. A
# three-way merge of two waves that each appended a row resolves cleanly and
# wrongly, and vitest only says so at push time.
step "3 rebuild the SPA scene rows from origin/main"
run python3 "$SCRIPT_DIR/spa-scene-rows.py" "$id" --base-ref origin/main --apply ||
  fail "spa-scene-rows refused — see its message (a --tuple is usually what is missing)"

# ---- 4 regenerate + validate + the scene suite -------------------------------
# Regenerate AFTER the merge, not before: generated artifacts auto-merge cleanly
# into content neither branch ever had (AGENT-CI-EXIT-RULE.md).
step "4 regenerate, validate, vitest"
run python3 "$REPO_ROOT/scripts/stations-registry.py" generate || fail "registry generate failed"
run python3 "$REPO_ROOT/scripts/stations-registry.py" validate || fail "registry validate failed"
if [ "$dry" = 1 ]; then
  say "WOULD RUN: (cd spa && npx vitest run)"
elif [ -d "$REPO_ROOT/spa/node_modules" ]; then
  (cd "$REPO_ROOT/spa" && npx vitest run) || fail "vitest failed"
else
  say "SKIPPED vitest: spa/node_modules is absent in this worktree (npm ci, or symlink it)"
  say "  the pre-push gate below still owes it — do not push a red scene suite"
fi

# ---- 5 commit + push ---------------------------------------------------------
step "5 commit + push (the pre-push gate is the gate)"
if [ "$dry" = 1 ]; then
  say "WOULD RUN: git add -A && git commit -m '$id: land' && git push origin HEAD:main"
  git -C "$REPO_ROOT" status --short | sed 's/^/   /'
elif [ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]; then
  run git -C "$REPO_ROOT" add -A || fail "git add failed"
  run git -C "$REPO_ROOT" commit -q -m "$id: land — merge main, rebuild scene rows, regenerate" ||
    fail "git commit failed"
else
  say "nothing to commit (merge + rebuild produced no change)"
fi
if [ "$no_push" = 1 ]; then
  say "--no-push: stopping before the push. Nothing on the box has been touched."
  [ "$keep_window" = 0 ] && [ "$dry" = 0 ] && release_window
  exit 0
fi
rollback_hint="nothing is deployed yet; git reset --hard origin/main on this branch"
run git -C "$REPO_ROOT" push origin HEAD:main || fail "push refused (gate red, or main moved — re-run to re-merge)"

# ---- 6 deploy the commit -----------------------------------------------------
step "6 box-deploy the pushed commit"
rollback_hint="the box checkout carries this commit; a revert needs a new commit + box-deploy --apply"
run "$SCRIPT_DIR/box-deploy.sh" --apply || fail "box-deploy --apply failed"

# ---- 7 golden swap -----------------------------------------------------------
step "7 golden disk"
if [ -z "$golden" ]; then
  say "no --golden: the live disk is untouched"
else
  live="$BOX_STATIONS/$id/disk.qcow2"
  parked="$live.pre-$tag"
  rollback_hint="systemctl stop streamhost@$id; mv $parked $live; systemctl start streamhost@$id"
  say "stop unit, park $live -> $parked, copy $golden in"
  run ssh -n "$LAB" "systemctl stop streamhost@$id" || fail "could not stop streamhost@$id"
  run ssh -n "$LAB" "test -f '$golden'" || fail "$golden is not a file on the box"
  run ssh -n "$LAB" "if [ -f '$live' ]; then mv '$live' '$parked'; fi" || fail "could not park the live disk"
  run ssh -n "$LAB" "cp --reflink=auto '$golden' '$live'" || fail "could not install the staged golden"
  say "parked disk kept at $parked — delete it only after the framebuffer proof"
fi

# ---- 8 take the smoke rig down ----------------------------------------------
step "8 smoke rig"
if [ "$dry" = 1 ]; then
  say "WOULD RUN: smoke-rig.sh $id --down (if a rig is up)"
elif ssh -n "$LAB" "test -e /data/vms/sandbox/$KH_SESSION/smoke/qmp.sock" 2>/dev/null; then
  run "$SCRIPT_DIR/smoke-rig.sh" "$id" --down ||
    say "WARNING: smoke-rig --down failed; withdraw the overlay by hand before the SPA deploy"
else
  say "no smoke rig socket for this session — nothing to take down"
fi

# ---- 9 bring the station up --------------------------------------------------
step "9 station-up (emit, binary, unit, manifests, checks)"
# Stamped BEFORE station-up, because station-up's last act is POST /restore —
# the reset an IM client has to survive. rn-verify --since needs a mark that
# predates it, or a login line from the PREVIOUS run reads as this run's proof.
# The BOX clock, not this one: the journal it greps is CT 951's.
if [ "$dry" = 1 ]; then
  reset_ts="<box date at station-up time>"
else
  reset_ts="$(ssh -n "$LAB" "date '+%Y-%m-%d %H:%M:%S'")" || reset_ts=""
fi
say "reset mark: $reset_ts"
run "$SCRIPT_DIR/station-up.sh" "$id" || fail "station-up did not come back green"

# ---- 10 re-home the claims ---------------------------------------------------
# A claim taken by the WAVE session becomes unfindable the moment the wave ends;
# the next session's kh-claim then says "not yours" about a live station's own
# port. Move every claim whose purpose names this station onto the station
# session, which outlives the wave.
step "10 re-home claims: $KH_SESSION -> $station_session"
if [ "$dry" = 1 ]; then
  say "WOULD RUN: for each claim of $KH_SESSION mentioning $id: kh-claim release, then take as $station_session"
else
  claims="$(ssh -n "$LAB" "KH_SESSION='$KH_SESSION' kh-claim ls --mine --json" 2>/dev/null || echo '[]')"
  printf '%s' "$claims" | python3 -c '
import json, shlex, sys
station = sys.argv[1]
try:
    rows = json.loads(sys.stdin.read() or "[]")
except ValueError:
    rows = []
for row in rows:
    blob = f"{row.get('"'"'name'"'"','"'"''"'"')} {row.get('"'"'purpose'"'"','"'"''"'"')}"
    if station in blob:
        print(shlex.quote(row["class"]), shlex.quote(str(row["name"])), shlex.quote(row.get("purpose", "")))
' "$id" | while read -r cls name purpose; do
    [ -n "$cls" ] || continue
    say "re-home $cls/$name"
    ssh -n "$LAB" "KH_SESSION='$KH_SESSION' kh-claim release $cls $name" >/dev/null 2>&1
    ssh -n "$LAB" "KH_SESSION='$station_session' kh-claim take $cls $name --purpose $purpose" >/dev/null 2>&1 ||
      echo "   WARNING: $cls/$name not re-taken — check kh-claim who $cls $name" >&2
  done
  say "verify: ssh lab \"KH_SESSION='$station_session' kh-claim ls --mine\""
fi

# ---- 11 proofs (the framebuffer is the only proof — AGENTS.md rule 9) --------
step "11 proofs"
shot="/data/vms/sandbox/${KH_SESSION}/$id-landed.png"
run ssh -n "$LAB" "labctl shot $id $shot" || fail "labctl shot failed — the guest is not painting"
say "shot: $shot   (LOOK AT IT; a green unit is not a proof)"
if [ -n "$x11warp" ]; then
  probe="$SCRIPT_DIR/x11warp-probe.py"
  [ -x "$probe" ] || probe="$SCRIPT_DIR/x11ptr.py"
  if [ -e "$probe" ]; then
    run python3 "$probe" --display "$x11warp" --warp 100 700 --warp 900 100 ||
      fail "x11warp readback did not match — the pointer proof is not done"
  else
    say "WARNING: no x11warp probe in scripts/dev (agent D's deliverable) — prove the pointer by hand"
  fi
fi
if grep -q '"retronet"' "$REPO_ROOT/registry/stations/$id.json"; then
  # The RECONNECT proof for an IM station is two facts, not one: a NEW
  # "login successful uin=<uin>" in CT 951's ICQ journal AFTER the reset, and the
  # frame. A client that never re-logs in after `loadvm golden` looks perfectly
  # alive on the framebuffer — slackware's micq needed a watchdog for exactly
  # that — so the journal line is what separates "painting" from "on the plane".
  # rn-verify owns that grep; this script must not grow its own.
  declare -a rn_args=("$id")
  uin="$(python3 -c '
import json, sys
rows = json.load(open("scripts/retronet/icq/roster.json"))["stations"]
print(next((r["uin"] for r in rows if r.get("station") == sys.argv[1] and r.get("uin")), ""))
' "$id" 2>/dev/null || true)"
  if [ -n "$uin" ] && [ -n "$reset_ts" ]; then
    rn_args+=(--icq "$uin" --since "$reset_ts")
  elif [ -n "$uin" ]; then
    say "WARNING: no reset mark — the ICQ reconnect cannot be proved to be NEW; re-run the proof by hand"
  fi
  if [ -x "$REPO_ROOT/scripts/retronet/rn-verify.sh" ]; then
    run "$REPO_ROOT/scripts/retronet/rn-verify.sh" "${rn_args[@]}" ||
      fail "rn-verify says $id is not on the plane (tap, reservation, fdb, or the post-reset ICQ login)"
  else
    say "WARNING: scripts/retronet/rn-verify.sh absent (agent B's deliverable) — verify by hand:"
    say "  the tap UP on vmbr-rn, the reservation rendered in CT 951, the MAC on the bridge fdb,"
    [ -n "$uin" ] && say "  and a NEW 'login successful uin=$uin' in CT 951's ICQ journal after $reset_ts"
  fi
fi

# ---- 12 SPA ------------------------------------------------------------------
step "12 SPA build + deploy"
if [ "$no_spa" = 1 ]; then
  say "--no-spa: the gallery still serves the previous bundle"
elif [ "$dry" = 1 ]; then
  say "WOULD RUN: (cd spa && npm run build) then scripts/serve-https-spa.sh deploy"
  say "NOTE the bundle must be built with the Instana key present, or deploy refuses it"
else
  (cd "$REPO_ROOT/spa" && npm run build) || fail "SPA build failed"
  run "$REPO_ROOT/scripts/serve-https-spa.sh" deploy || fail "SPA deploy failed"
fi

# ---- 13 dark launches --------------------------------------------------------
step "13 dark-launch overlays"
say "publish_manifests re-overlays serve/darklaunch.d itself now — no hand re-arm."
say "confirm: ssh lab 'python3 /data/vms/streamhost/serve/darklaunch-station.py reapply'"

# ---- 14 release --------------------------------------------------------------
step "14 release the landing window"
if [ "$keep_window" = 1 ]; then
  say "--keep-window: still yours; release with '$WAVE_SH land end $id'"
elif [ "$dry" = 1 ]; then
  say "WOULD RUN: $WAVE_SH land end $id"
else
  release_window
fi

printf '\n== LANDED %s\n' "$id"
say "commit  : $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
[ -n "$golden" ] && say "rollback: mv $BOX_STATIONS/$id/disk.qcow2.pre-$tag $BOX_STATIONS/$id/disk.qcow2 (with the matching launcher commit)"
say "next    : open /os/$id, look at the framebuffer, then delete the parked disk"
