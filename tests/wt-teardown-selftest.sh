#!/usr/bin/env bash
# wt-teardown-selftest.sh — proves two wt.sh `rm` teardown bugs and their
# fixes, entirely locally: no ssh, no real box, no real claim or sandbox.
#
#   1 SELF-EXCLUSION   the live-process check no longer reports its own
#                       bash/ssh delivery chain as a "live guest" (the false
#                       positive that forced --force on every teardown), but
#                       still reports a genuine non-shell process (a stand-in
#                       for an emulator/build) sitting in the same dir.
#
#   2 CLAIM ORDERING    `wt.sh rm`, invoked the normal way — cd into the
#                       sandbox's own repo, then run its own copy of wt.sh —
#                       actually releases the claim, instead of failing
#                       silently because $LABRUN pointed at a copy of labrun
#                       that local deletion had just removed.
#
# Both sections run the CURRENT wt.sh/wt-live-pids.sh (fixed) and, where
# practical, the pre-fix algorithm/behavior for comparison, so the failing
# case is visible alongside the passing one.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
NEW_LIVE_PIDS="${WT_LIVE_PIDS_SH:-$REPO/scripts/dev/wt-live-pids.sh}"
NEW_WT="${WT_SH:-$REPO/scripts/dev/wt.sh}"
KH_CLAIM="$REPO/scripts/lib/kh-claim.sh"

[ -f "$NEW_LIVE_PIDS" ] || {
  echo "FAIL  no wt-live-pids.sh at $NEW_LIVE_PIDS"
  exit 1
}
[ -f "$NEW_WT" ] || {
  echo "FAIL  no wt.sh at $NEW_WT"
  exit 1
}
[ -f "$KH_CLAIM" ] || {
  echo "FAIL  no kh-claim.sh at $KH_CLAIM"
  exit 1
}

FAILED=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  FAILED=1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wt-teardown-selftest.XXXXXX")"
# shellcheck disable=SC2317 # runs from the EXIT trap
cleanup() {
  # bare -9 by pid, never a cmdline match (AGENTS.md rule 5)
  [ -n "${sleeper_pid:-}" ] && kill -9 "$sleeper_pid" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# =============================================================================
# 1. SELF-EXCLUSION — scripts/dev/wt-live-pids.sh vs the pre-fix algorithm
# =============================================================================
# The pre-fix scan lived inline in wt.sh (origin/main, before this branch),
# hardcoded to /data/vms/sandbox/$1 and with NO exclusion at all on a cwd
# match — every process whose cwd sat under the sandbox was reported, full
# stop. Reproduced here in parameterized form (root+name instead of a
# hardcoded path) so it can run against a throwaway temp dir instead of the
# real box; the matching/reporting logic itself is unchanged from
# origin/main:scripts/dev/wt.sh's live_pids().
old_scan() { # root name
  local d="$1/$2" p pid cwd
  for p in /proc/[0-9]*; do
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    case "$cwd" in
      "$d" | "$d"/*)
        echo "${p#/proc/} $(readlink "$p/exe" 2>/dev/null) cwd=$cwd"
        continue
        ;;
    esac
    if grep -qs -- "$d" "$p/cmdline" 2>/dev/null; then
      case "$(readlink "$p/exe" 2>/dev/null)" in
        *sshd* | */bash | */grep) ;;
        *) echo "${p#/proc/} $(readlink "$p/exe" 2>/dev/null) cmdline" ;;
      esac
    fi
  done
}

ROOT="$WORK/sandbox-root"
NAME="selftest"
D="$ROOT/$NAME"
mkdir -p "$D"

# A bash sitting in $d, standing in for the check's own bash/ssh delivery
# chain (both are plain executables cwd'd into the sandbox — the false
# positive did not care that one of them happened to be named ssh). Its
# child (sleep) stands in for genuine live work: an emulator, a build. The
# `sleep & wait` (rather than a bare `sleep 30`) stops bash from optimizing
# the subshell into a tail-call exec of sleep itself, which would leave no
# separate bash process to reproduce the false positive against.
(
  cd "$D" || exit 1
  sleep 30 &
  wait
) &
sleeper_pid=$!
# wait for the child to actually fork and inherit cwd
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -n "$(pgrep -P "$sleeper_pid" -x sleep 2>/dev/null)" ] && break
  sleep 0.2
done

old_out="$(old_scan "$ROOT" "$NAME")"
new_out="$("$NEW_LIVE_PIDS" "$ROOT" "$NAME")"

if echo "$old_out" | grep -Eq "^$sleeper_pid "; then
  ok "OLD algorithm reproduces the bug: reports its own bash ($sleeper_pid) as a live process"
else
  bad "OLD algorithm did not report the self bash — repro premise is wrong"
fi
if echo "$new_out" | grep -Eq "^$sleeper_pid "; then
  bad "NEW scan still reports the self bash ($sleeper_pid) — false positive NOT fixed"
else
  ok "NEW scan does not report the self bash ($sleeper_pid)"
fi

sleep_pid="$(pgrep -P "$sleeper_pid" -x sleep 2>/dev/null | head -1)"
if [ -z "$sleep_pid" ]; then
  bad "could not find the stand-in sleep child — test setup broken"
else
  if echo "$old_out" | grep -Eq "^$sleep_pid "; then
    ok "OLD algorithm reports the genuine live process ($sleep_pid, sleep)"
  else
    bad "OLD algorithm missed the genuine live process — repro premise is wrong"
  fi
  if echo "$new_out" | grep -Eq "^$sleep_pid "; then
    ok "NEW scan still reports the genuine live process ($sleep_pid, sleep) — real work is not hidden"
  else
    bad "NEW scan lost the genuine live process ($sleep_pid) — the fix over-excludes"
  fi
fi

kill -9 "$sleeper_pid" 2>/dev/null
wait "$sleeper_pid" 2>/dev/null
sleeper_pid=""

# =============================================================================
# 2. CLAIM ORDERING — wt.sh rm, invoked as $repo/scripts/dev/wt.sh, the
#    normal `cd $repo && wt.sh rm <name>` workflow wt.sh's own "new" hint
#    tells the caller to use.
# =============================================================================
# A local stand-in for scripts/dev/labrun: same CLI contract (stdin heredoc,
# a script FILE as the first arg, or -c 'cmd'; "$@" after that are the
# script's own positional params) but runs the script with plain `bash`
# instead of shipping it to labhost over ssh — so wt.sh's real teardown code
# runs unmodified, entirely off the real box.
# the heredoc scripts wt.sh ships over labrun call `kh-claim` as a bare
# command (it is installed on $PATH on the real box) — give it one here too.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/kh-claim" <<STUBBIN
#!/usr/bin/env bash
exec bash "$KH_CLAIM" "\$@"
STUBBIN
chmod +x "$WORK/bin/kh-claim"

cat >"$WORK/labrun" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
mode=stdin
src=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --)
      shift
      break
      ;;
    -c)
      shift
      src="$1"
      mode=cmd
      shift
      break
      ;;
    -*) shift ;;
    *)
      if [ "$mode" = stdin ] && [ -f "$1" ]; then
        src="$(cat "$1")"
        mode=file
        shift
      fi
      break
      ;;
  esac
done
[ "$mode" = stdin ] && src="$(cat)"
bash -euo pipefail -c "$src" stub-labrun "$@"
STUB
chmod +x "$WORK/labrun"

setup_claim_env() {
  export KH_CLAIMS_ROOT="$WORK/claims"
  rm -rf "$KH_CLAIMS_ROOT"
  mkdir -p "$KH_CLAIMS_ROOT"
}

# build one fake full stack: BOX_REPO (bare enough for `git worktree`
# bookkeeping calls to no-op harmlessly) + a sandbox dir with its OWN copy
# of wt.sh — reproducing the exact trigger: wt.sh invoked as
# $repo/scripts/dev/wt.sh, so $LABRUN resolves inside the tree being removed.
build_stack() { # wt_sh_source name
  local wt_src="$1" name="$2"
  local sandbox_root="$WORK/sandbox/$name-fs"
  rm -rf "$sandbox_root"
  local box_repo="$sandbox_root/box-repo" repo="$sandbox_root/sandbox/$name/repo"
  mkdir -p "$box_repo" "$repo/scripts/dev" "$repo/scripts/lib"
  git -C "$box_repo" init -q
  git -C "$repo" init -q
  cp "$wt_src" "$repo/scripts/dev/wt.sh"
  cp "$NEW_LIVE_PIDS" "$repo/scripts/dev/wt-live-pids.sh"
  cp "$WORK/labrun" "$repo/scripts/dev/labrun"
  cp "$KH_CLAIM" "$repo/scripts/lib/kh-claim.sh"
  chmod +x "$repo/scripts/dev/wt.sh" "$repo/scripts/dev/wt-live-pids.sh" "$repo/scripts/dev/labrun"
  printf '%s\n' "$sandbox_root"
}

run_teardown() { # wt_sh_source name -> prints teardown stdout+stderr, sets $rc
  local wt_src="$1" name="$2" sandbox_root repo
  sandbox_root="$(build_stack "$wt_src" "$name")"
  repo="$sandbox_root/sandbox/$name/repo"
  setup_claim_env
  KH_SESSION="$name" bash "$repo/scripts/lib/kh-claim.sh" take sandbox "$name" --purpose selftest >/dev/null
  (
    cd "$repo" || exit 1
    PATH="$WORK/bin:$PATH" BOX_REPO_DIR="$sandbox_root/box-repo" KH_SANDBOX_ROOT="$sandbox_root/sandbox" \
      bash scripts/dev/wt.sh rm "$name" --force
  )
  rc=$?
  claim_state="$(KH_CLAIMS_ROOT="$KH_CLAIMS_ROOT" bash "$KH_CLAIM" who sandbox "$name" 2>&1)"
}

# --- OLD wt.sh (origin/main, before this branch) ----------------------------
if git -C "$REPO" show origin/main:scripts/dev/wt.sh >"$WORK/old-wt.sh" 2>/dev/null; then
  run_teardown "$WORK/old-wt.sh" "old-case"
  if [ "$rc" = 0 ] && echo "$claim_state" | grep -q unclaimed; then
    bad "OLD wt.sh released the claim cleanly — repro premise is wrong (rc=$rc, claim: $claim_state)"
  else
    ok "OLD wt.sh reproduces the bug: rc=$rc, claim left \"$claim_state\" (orphaned, not unclaimed)"
  fi
else
  echo "SKIP  origin/main:scripts/dev/wt.sh not available (no fetch here) — before/after comparison skipped"
fi

# --- NEW wt.sh (this branch) -------------------------------------------------
run_teardown "$NEW_WT" "new-case"
if [ "$rc" = 0 ] && echo "$claim_state" | grep -q unclaimed; then
  ok "NEW wt.sh releases the claim cleanly when invoked as \$repo/scripts/dev/wt.sh (rc=$rc, claim: $claim_state)"
else
  bad "NEW wt.sh did NOT release the claim cleanly (rc=$rc, claim: $claim_state)"
fi

printf '\n%s\n' "$([ "$FAILED" = 0 ] && echo "all checks passed" || echo "one or more checks FAILED")"
exit "$FAILED"
