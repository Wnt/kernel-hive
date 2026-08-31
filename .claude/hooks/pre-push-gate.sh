#!/usr/bin/env bash
# .claude/hooks/pre-push-gate.sh — local mirror of the CI quality gate.
#
# Blocks a push whose commits carry the repo's Claude-session trailer
# (Claude-Session: / Co-Authored-By: ... Claude) unless the gate is green, so
# agent branches never reach origin red. Human pushes pass through unless
# GATE_ALL=1. Emergency bypass: SKIP_GATE=1 (never for main).
#
# ---------------------------------------------------------------------------
# WHAT IT CHECKS: THE PUSHED RANGE, NOT THE DIRTY WORKING TREE
# ---------------------------------------------------------------------------
# The input is `<remote_sha>..<local_sha>` for each ref git hands us on stdin
# (falling back to @{push}..HEAD / origin/main..HEAD / HEAD when run by hand).
# Two consequences, both deliberate:
#
#   1. Only the language(s) that CHANGED in that range are linted. AGENTS.md:
#      "You owe the gate only for the language(s) your branch touches, plus the
#      two cross-cutting gates."
#   2. A sibling agent's untracked, half-written file is INVISIBLE here. It was
#      visible once, and it blocked a push that had nothing to do with it. A
#      gate must be satisfiable by the person it blocks — an unfixable gate
#      teaches SKIP_GATE=1, and then it protects nothing.
#
# That is the mirror image of the tracked-only blind spot fixed the same day:
# pre-COMMIT and direct invocation see tracked ∪ staged ∪ untracked-not-ignored
# (so a new file is budgeted before it is committed); pre-PUSH sees the
# committed state being pushed. Both matter; they are different questions.
# GATE_FULL=1 forces the full-tree, every-language run.
#
# EVERY SKIP IS LOUD. A silently skipped gate is the failure class this repo
# keeps paying for (`|| true` media fetches, an installer logging success it
# never earned). A stage that does not run says so, and says why.
#
# Plus one gate CI cannot run: box state — live labhost files must equal the
# commit the box checkout is at (scripts/host/box-install.sh dry-run; the box
# is installed from a commit by scripts/dev/box-deploy.sh). Probe-gated on
# `ssh lab` reachability. "Box behind main" is a note, not a failure.
#
# OPTIONAL MANUAL polish gate (needs the box; deliberately never blocking here):
#   npm --prefix tests/e2e-live run qa:lap
#
# Enable once per clone (git allows only one pre-push hook, so pick one):
#   ln -sf ../../.claude/hooks/pre-push-gate.sh .git/hooks/pre-push
#   #  or:  git config core.hooksPath .claude/hooks   (then the file must be
#   #       named 'pre-push' — e.g. symlink pre-push -> pre-push-gate.sh)
# See docs/lab/AGENT-CI-EXIT-RULE.md for the canonical command list.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

if [[ "${SKIP_GATE:-}" == "1" ]]; then
  echo "pre-push-gate: SKIP_GATE=1, bypassing"
  exit 0
fi

have() { command -v "$1" >/dev/null 2>&1; }

# --- the base every range is measured from: merge-base with CURRENT main -----
# `git diff A..B` diffs the two ENDPOINTS. So when A is a main this clone has
# not fetched, every file main moved since — an unrelated wave's Rust, say —
# lands in "the pushed range" and this push is billed for its lint. Observed
# 2026-08-30 on a rebased branch that touched no Rust at all: the gate demanded
# `cargo clippy` for somebody else's commits, and an unsatisfiable gate is how
# SKIP_GATE=1 gets taught. The cut point is not the base; the merge-base with
# CURRENT origin/main is, and "current" needs a fetch — a branch rebased onto,
# or merged with, a main this clone last saw an hour ago has a merge-base one
# hour of other people's work too early.
#
# The fetch goes to a PRIVATE ref, and it fetches BY URL rather than by remote
# name. That is not fussiness: `git fetch origin <refspec>` still performs an
# "opportunistic update" of refs/remotes/origin/*, so naming the remote would
# silently advance your origin/main as a side effect of running a gate —
# a read path that writes, which is the exact shape of the incident that made
# a dry-run plan move everyone's drift baseline. Measured, not assumed: by name
# origin/main moves, by URL it does not. refs/kh-gate/main is ours, forced and
# disposable. Fetch failure is not fatal: fall back to origin/main and say so.
# GATE_NO_FETCH=1 skips it (offline, or a hot loop).
gate_main=""
if git rev-parse --verify --quiet origin/main >/dev/null; then gate_main="origin/main"; fi
if [[ "${GATE_NO_FETCH:-0}" != "1" ]] && have timeout; then
  if timeout 25 git fetch --quiet --no-tags "$(git config remote.origin.url)" \
    "+refs/heads/main:refs/kh-gate/main" >/dev/null 2>&1; then
    gate_main="refs/kh-gate/main"
  elif [[ -n "$gate_main" ]]; then
    echo "pre-push-gate: could not fetch origin/main; measuring the range from the"
    echo "               local origin/main ($(git rev-parse --short origin/main)) — if it is"
    echo "               stale this may over-scope the range (GATE_NO_FETCH=1 to silence)"
  fi
fi

# range_base <tip> [<pushed_remote_sha>] — the LATEST ancestor of <tip> among
# the candidate bases, so the range stays as narrow as is still correct:
#   * merge-base(current main, tip)  — never sweeps in main's own commits;
#   * the ref's remote sha           — narrower still on a re-push, and used
#                                      only when it really is an ancestor of
#                                      the tip (a force-push after a rebase is
#                                      not, and must not be trusted as a base).
# Prints nothing when no base is known; the caller then falls back to a bounded
# slice of the tip's own history, exactly as before.
range_base() {
  local tip="$1" remote="${2:-}" mb="" cand=""
  [[ -n "$gate_main" ]] && mb=$(git merge-base "$gate_main" "$tip" 2>/dev/null)
  if [[ -n "$remote" && "$remote" != "$zero" ]] &&
    git merge-base --is-ancestor "$remote" "$tip" 2>/dev/null; then
    cand=$(git rev-parse "$remote" 2>/dev/null)
  fi
  # Whichever candidate is the DESCENDANT of the other is the later base.
  if [[ -n "$cand" && -n "$mb" ]]; then
    if git merge-base --is-ancestor "$mb" "$cand" 2>/dev/null; then printf '%s' "$cand"; else printf '%s' "$mb"; fi
  else
    printf '%s' "${cand:-$mb}"
  fi
}

# --- read git's ref list, derive the pushed ranges and whether we owe the gate -
zero="0000000000000000000000000000000000000000"
gate_needed="${GATE_ALL:-0}"
examined=0
ranges=()
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  [[ "$local_sha" == "$zero" ]] && continue # branch deletion
  base=$(range_base "$local_sha" "$remote_sha")
  if [[ -n "$base" ]]; then
    ranges+=("$base..$local_sha")
    revs=$(git rev-list "$base..$local_sha" 2>/dev/null)
  else
    # No main to measure against and no usable remote sha: a bounded slice of
    # this branch's own history is all there is.
    ranges+=("$local_sha")
    revs=$(git rev-list --max-count=200 "$local_sha" 2>/dev/null)
  fi
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    examined=$((${examined:-0} + 1))
    if git show -s --format='%B' "$c" | grep -qiE 'Claude-Session:|Co-Authored-By: .*Claude'; then
      gate_needed=1
      break
    fi
  done <<<"$revs"
done

# Run by hand (no ref list on stdin): fall back to what a push would send.
if [[ "${#ranges[@]}" -eq 0 ]]; then
  # Same merge-base discipline as the push path: whatever upstream this branch
  # has is only a CANDIDATE base, and it counts only if it is an ancestor.
  hand_remote=""
  for r in '@{push}' '@{upstream}'; do
    if git rev-parse --verify --quiet "$r" >/dev/null 2>&1; then
      hand_remote=$(git rev-parse "$r")
      break
    fi
  done
  base=$(range_base HEAD "$hand_remote")
  if [[ -n "$base" ]]; then ranges+=("$base..HEAD"); else ranges+=('HEAD'); fi
  echo "pre-push-gate: no ref list on stdin; using ${ranges[*]}"
  # ...and SCAN THAT RANGE, exactly as the stdin path does. Without this the
  # fallback never set gate_needed, so it skipped and then blamed the commits
  # for it — printing "no Claude-session commits in this push" having examined
  # no commits at all. A message that is true-sounding and wrong about its own
  # reason is the failure class this gate exists to prevent, and it converts an
  # unexamined push into a reassuring line in a log.
  if [[ "$base" == "" ]]; then
    hand_revs=$(git rev-list --max-count=200 HEAD 2>/dev/null)
  else
    hand_revs=$(git rev-list "$base..HEAD" 2>/dev/null)
  fi
  hand_n=0
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    hand_n=$((hand_n + 1))
    if git show -s --format='%B' "$c" | grep -qiE 'Claude-Session:|Co-Authored-By: .*Claude'; then
      gate_needed=1
      break
    fi
  done <<<"$hand_revs"
  examined="$hand_n"
fi

if [[ "$gate_needed" != "1" && "${GATE_FULL:-0}" != "1" ]]; then
  # Say what actually happened. "No Claude-session commits" is only honest when
  # commits were READ; if the range could not be determined, the skip is an
  # admission of ignorance and must read as one.
  # ZERO EXAMINED IS NOT "NONE MATCHED". The range may be empty (nothing new to
  # push), or unresolvable, or rev-list may have failed — in every one of those
  # cases the gate learned nothing, and saying "no Claude-session commits" would
  # be asserting a fact about commits it never read.
  if [[ "${examined:-0}" -eq 0 ]]; then
    echo "pre-push-gate: examined NO commits in ${ranges[*]-<no range>} — the range is empty or"
    echo "               could not be resolved, so nothing was checked. This is not a green gate;"
    echo "               it is the gate saying it had nothing to look at. GATE_ALL=1 to force."
  else
    echo "pre-push-gate: examined ${examined:-0} commit(s) in ${ranges[*]-<none>} — none carry the"
    echo "               Claude-session trailer; skipping (GATE_ALL=1 to force)"
  fi
  exit 0
fi

# --- the pushed range's changed files ----------------------------------------
CHANGED=""
if [[ "${GATE_FULL:-0}" == "1" ]]; then
  echo "pre-push-gate: GATE_FULL=1 — full-tree run, every language stage"
else
  for r in "${ranges[@]}"; do
    if [[ "$r" == *".."* ]]; then
      CHANGED+=$(git diff --name-only "$r" 2>/dev/null)$'\n'
    else
      CHANGED+=$(git show --pretty=format: --name-only "$r" 2>/dev/null)$'\n'
    fi
  done
  CHANGED=$(printf '%s' "$CHANGED" | grep -v '^$' | sort -u)
  n_changed=$(printf '%s' "$CHANGED" | grep -c . || true)
  echo "pre-push-gate: range ${ranges[*]} — $n_changed changed file(s)"
fi

# touches <extended-regex> — does the pushed range contain such a file?
touches() {
  [[ "${GATE_FULL:-0}" == "1" ]] && return 0
  printf '%s\n' "$CHANGED" | grep -qE "$1"
}

echo "pre-push-gate: running quality gate (SKIP_GATE=1 to bypass; GATE_VERBOSE=1 for full stage output)"
fail=0
FAILED_STAGES=()
GATE_TMP="$(mktemp -d)"
trap 'rm -rf "$GATE_TMP"' EXIT

# stage <name> <remedy> <cmd...> — run a stage QUIETLY. A green stage is one
# line; a red one shows its last 40 lines (GATE_VERBOSE=1: all) and the remedy.
# On 2026-08-17 a green push printed 217 lines (100 of them the size-exclusion
# ledger, 95 the registry's BYTE-IDENTICAL roll call) and the FAIL sat at line
# 211 — three greps to find it. Output is for the failure, not the ceremony.
stage() {
  local name="$1" remedy="$2" log="$GATE_TMP/stage.log" rc
  shift 2
  ("$@") >"$log" 2>&1
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    if [[ "${GATE_VERBOSE:-0}" == "1" ]]; then
      echo "== $name =="
      sed 's/^/    /' "$log"
    fi
    echo "== $name == ok"
  else
    echo "== $name == FAIL"
    if [[ "${GATE_VERBOSE:-0}" == "1" ]]; then sed 's/^/    /' "$log"; else
      grep -v '^  excl \|^BYTE-IDENTICAL \|^RENDERED \|^  ~ ' "$log" | tail -40 | sed 's/^/    /'
    fi
    [[ -z "$remedy" ]] || echo "    → $remedy"
    FAILED_STAGES+=("$name")
    fail=1
  fi
}

# --- per-language lint: owed only when that language changed in the range -----
if ! touches '^spa/|\.(ts|tsx|js|jsx|mjs|cjs)$'; then
  echo "== TS/JS lint == not owed (no TS/JS in the pushed range)"
elif ! have npx; then
  echo "== TS/JS lint == SKIPPED: npx not found (CI covers this)"
else
  stage "TS/JS lint (eslint + knip)" "cd spa && npx eslint . --max-warnings=0 && npx knip" \
    bash -c 'cd spa && npx eslint . --max-warnings=0 && npx knip'
fi

# The Rust target dir is an ABSOLUTE BOX PATH (streamhost/.cargo/config.toml:
# every box-side worktree reuses one target tree). On a workstation that path is
# unwritable, so cargo dies with "failed to create directory … Permission
# denied" before it compiles a line — the Rust stage could never pass here, on
# any commit, for anyone. Say so out loud and continue; CI builds it for real.
rust_target_dir() {
  local d="${CARGO_TARGET_DIR:-}"
  if [[ -z "$d" && -f streamhost/.cargo/config.toml ]]; then
    d=$(sed -n 's/^[[:space:]]*target-dir[[:space:]]*=[[:space:]]*"\(.*\)".*/\1/p' \
      streamhost/.cargo/config.toml | head -1)
  fi
  printf '%s' "${d:-streamhost/target}"
}
# Writable if the dir itself, or its nearest existing ancestor, is writable.
path_writable() {
  local p="$1"
  [[ "$p" != /* ]] && p="$PWD/$p"
  while [[ -n "$p" && ! -e "$p" ]]; do p="${p%/*}"; done
  [[ -n "$p" && -w "$p" ]]
}

if ! touches '\.rs$|(^|/)Cargo\.(toml|lock)$'; then
  echo "== Rust lint == not owed (no Rust in the pushed range)"
elif ! have cargo; then
  echo "== Rust lint == SKIPPED: cargo not found (CI covers this)"
elif ! path_writable "$(rust_target_dir)"; then
  echo "== Rust lint == SKIPPED: target-dir unavailable locally (CI covers this)"
  echo "     $(rust_target_dir) is not writable from this workstation;"
  echo "     it is the box's shared target tree (streamhost/.cargo/config.toml)."
  echo "     To run it here anyway: CARGO_TARGET_DIR=/tmp/kh-target GATE_FULL=1 …"
else
  stage "Rust lint (fmt + clippy)" "cd streamhost && cargo fmt --all && cargo clippy --all-targets -- -D warnings" \
    bash -c 'cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings'
fi

if ! touches '\.py$'; then
  echo "== Python lint == not owed (no Python in the pushed range)"
elif ! have ruff; then
  echo "== Python lint == SKIPPED: ruff not found (CI covers this)"
else
  stage "Python lint (ruff)" "ruff check --fix scripts && ruff format scripts" \
    bash -c 'ruff check scripts && ruff format --check scripts'
fi

# Shell: the eligible list is committed-only (no sibling's untracked file), and
# outside GATE_FULL it is narrowed to the scripts this push actually changed.
shell_targets() {
  local eligible
  eligible=$(bash scripts/lint/shell-sources.sh --committed)
  if [[ "${GATE_FULL:-0}" == "1" ]]; then
    printf '%s\n' "$eligible"
    return
  fi
  printf '%s\n' "$eligible" | grep -Fxf <(printf '%s\n' "$CHANGED") || true
}

if ! touches '\.sh$|^scripts/labctl$'; then
  echo "== Bash lint == not owed (no shell in the pushed range)"
elif ! have shfmt || ! have shellcheck; then
  echo "== Bash lint == SKIPPED: shfmt/shellcheck not found (CI covers this)"
else
  mapfile -t SH_FILES < <(shell_targets)
  # A range can change only DELETED or generated-and-excluded scripts.
  SH_LIVE=()
  for f in "${SH_FILES[@]}"; do [[ -f "$f" ]] && SH_LIVE+=("$f"); done
  if [[ "${#SH_LIVE[@]}" -eq 0 ]]; then
    echo "== Bash lint == not owed (the range's shell files are deleted or generated)"
  else
    stage "Bash lint (shfmt + shellcheck, ${#SH_LIVE[@]} file(s))" "shfmt -w <files> && shellcheck <files>" \
      bash -c 'shfmt -d "$@" && shellcheck "$@"' _ "${SH_LIVE[@]}"
  fi
fi

# --- cross-cutting gates: owed by EVERY branch, regardless of language --------
# --committed, not the default union: by push time your own new file is tracked,
# so a real breach is still caught (proven), while a sibling's untracked
# in-flight file cannot block a push its author has nothing to do with.
stage "file-size budget (--strict --committed)" \
  "split the file, or (never to hide a breach you caused) size-exclusions.json; stale entries must be deleted" \
  node scripts/check-file-size.mjs --strict --committed

stage "generated-file drift" \
  "python3 scripts/stations-registry.py generate && make station-registry-check   (never hand-edit generated files)" \
  bash scripts/check-generated-drift.sh

# --- box state (ONLY when the box is actually reachable) ---
# A public clone, an offline laptop and GitHub Actions have no `ssh lab`, so
# this is probe-gated: unreachable box => SKIP with a message, never a failure.
#
# WHAT THIS ASKS — and the two questions it refuses to ask
# Since 2026-08-17 the box is INSTALLED FROM A COMMIT (scripts/dev/box-deploy.sh
# -> scripts/host/box-install.sh from /data/kernel-hive). The only live file
# worth blocking a push over is one that NOBODY's commit accounts for: a hand
# edit on labhost, or an install left half done.
#
# It is NOT "does live equal the box CHECKOUT". That has two false alarms, and a
# six-stream wave on 2026-08-23/24 paid for both:
#   * the checkout moves without anything being installed. `.deployed-rev` is
#     what was actually written to the live paths; rows that changed between
#     .deployed-rev and the checkout HEAD are simply NOT DEPLOYED YET. Reading
#     `box-deploy.sh`'s plan used to fast-forward the checkout (fixed in the
#     same change), so one agent's read-only inspection reddened every other
#     agent's push. Comparing against .deployed-rev makes that impossible.
#   * a station agent installing ITS OWN station's file, byte-correct, from its
#     own branch is a legitimate mid-wave act. If live equals THIS working
#     tree, the row is accounted for.
# It is also NOT "does live equal the commit I am pushing" — that would newly
# block the most ordinary push there is: fix, push, deploy afterwards.
#
# And what is left over is SCOPED: it fails the push only if the push touches
# that row's repo-side file. Everything else is a NAMED warning. A gate must be
# satisfiable by the person it blocks (see the header): holding a docs commit
# hostage to macos753's live drift teaches SKIP_GATE=1 — and the remedy the old
# message printed, `box-deploy.sh --apply`, reverts other streams' in-flight
# live edits, so the advice itself was a trap during parallel work.

boxlab="${LAB:-lab}"

# label -> repo-relative path, from the ONE pair table the box itself reads.
# Empty output (ssh gone, table unreadable) => every row stays blocking, i.e.
# exactly the old behaviour; this can only ever remove failures, never add one.
box_pair_map() {
  local tmp
  tmp="$(mktemp -d)" || return 1
  (
    # shellcheck disable=SC1091
    . scripts/lib/box-sync-pairs.sh || exit 1
    box_sync_load_pairs "$PWD" "${BOX_SYNC_BOX_ROOT:-/data/vms/streamhost}" \
      "$boxlab" "$tmp" >/dev/null 2>&1
    local i
    for i in "${!BOX_SYNC_LABELS[@]}"; do
      printf '%s\t%s\n' "${BOX_SYNC_LABELS[$i]}" "${BOX_SYNC_REPO_FILES[$i]}"
    done
  ) </dev/null 2>/dev/null
  rm -rf "$tmp"
}

# box_row_line <marker> <row: kind TAB label TAB note>
box_row_line() {
  printf '    %s %-8s %-44s %s\n' "$1" \
    "$(printf '%s' "$2" | cut -f1)" "$(printf '%s' "$2" | cut -f2)" \
    "$(printf '%s' "$2" | cut -f3)"
}

echo "== box state (live labhost files vs what was installed) =="
if ssh -n -o ConnectTimeout=4 -o BatchMode=yes "$boxlab" true 2>/dev/null; then
  bs_txt="$(ssh -n -o ConnectTimeout=25 "$boxlab" '
    cat /data/vms/streamhost/.deployed-rev 2>/dev/null
    echo "@@plan@@"
    /data/kernel-hive/scripts/host/box-install.sh --repo /data/kernel-hive 2>/dev/null')"
  bs_plan="$(printf '%s\n' "$bs_txt" | sed -n '/^@@plan@@$/,$p' | tail -n +2)"
  deployed_sha="$(printf '%s\n' "$bs_txt" | sed -n 's/^sha=\([0-9a-f]\{7,\}\)$/\1/p' | head -1)"
  if [[ "$bs_plan" == box-install:* ]]; then
    boxsha="$(printf '%s\n' "$bs_plan" | sed -n '1s/.*@\([0-9a-f]\{7,\}\) from .*/\1/p')"
    mapfile -t BOX_ROWS < <(printf '%s\n' "$bs_plan" |
      awk '$1=="changed"||$1=="new"||$1=="REFUSED"{print $1"\t"$2}')
    # Cross-check the rows against box-install's own totals. Scoping is only
    # safe while we can NAME what drifted; counted-but-unnamed drift means the
    # output shape moved under us, and a check that cannot read its input must
    # say so rather than pass. (Unparseable totals read as 0, exactly as the
    # old --json path did, so this can never invent a failure either.)
    n_drift="$(printf '%s\n' "$bs_plan" | sed -n '/^ *same /{p;q;}' |
      awk '{for (i = 1; i < NF; i++) if ($i == "changed" || $i == "new" || $i == "refused") s += $(i + 1)} END {print s + 0}')"

    declare -A PAIRPATH=()
    BLOCK=() WARN_ROWS=() UNDEPLOYED=""
    if [[ "${#BOX_ROWS[@]}" -gt 0 ]]; then
      while IFS=$'\t' read -r pl pp; do
        [[ -n "${pl:-}" ]] && PAIRPATH["$pl"]="$pp"
      done < <(box_pair_map)
      # Files the checkout carries that the last INSTALL never wrote: pending
      # deployment, not drift. Unknown shas (unfetched) => no excuse granted.
      if [[ -n "$deployed_sha" && -n "$boxsha" && "$deployed_sha" != "$boxsha" ]] &&
        git cat-file -e "$deployed_sha^{commit}" 2>/dev/null &&
        git cat-file -e "$boxsha^{commit}" 2>/dev/null; then
        UNDEPLOYED="$(git diff --name-only "$deployed_sha" "$boxsha" 2>/dev/null)"
      fi
    fi

    for row in ${BOX_ROWS[@]+"${BOX_ROWS[@]}"}; do
      label="${row#*$'\t'}"
      path="${PAIRPATH[$label]:-}"
      why=""
      if [[ -n "$path" ]] && printf '%s\n' "$UNDEPLOYED" | grep -qFx -- "$path"; then
        why="pending deploy (changed since .deployed-rev ${deployed_sha:0:7})"
      elif [[ -z "$path" || "${GATE_FULL:-0}" == "1" ]]; then
        why=""
      elif ! printf '%s\n' "$CHANGED" | grep -qFx -- "$path"; then
        why="not in this push ($path)"
      fi
      if [[ -n "$why" ]]; then
        WARN_ROWS+=("$row"$'\t'"$why")
      else
        BLOCK+=("$row"$'\t'"${path:-(row absent from the pair table here)}")
      fi
    done

    # Last accounting step: does live already carry THIS working tree's bytes?
    # Only possible when the tree is visible to labhost (a sandbox under /data).
    if [[ "${#BLOCK[@]}" -gt 0 && "$PWD" == /data/* ]] &&
      ssh -n -o ConnectTimeout=8 "$boxlab" "test -e $(printf '%q' "$PWD")/.git" 2>/dev/null; then
      qlabels="" safe=1
      for row in "${BLOCK[@]}"; do
        label="$(printf '%s' "$row" | cut -f2)"
        [[ "$label" =~ ^[A-Za-z0-9._/@+-]+$ ]] || {
          safe=0
          break
        }
        qlabels+=" $(printf '%q' "$label")"
      done
      if [[ "$safe" == 1 ]] && mine="$(ssh -n -o ConnectTimeout=25 "$boxlab" \
        "/data/kernel-hive/scripts/host/box-install.sh --repo $(printf '%q' "$PWD")$qlabels 2>/dev/null")" &&
        [[ "$mine" == box-install:* ]]; then
        mapfile -t STILL < <(printf '%s\n' "$mine" |
          awk '$1=="changed"||$1=="new"||$1=="REFUSED"{print $2}')
        KEEP=()
        for row in "${BLOCK[@]}"; do
          label="$(printf '%s' "$row" | cut -f2)"
          if printf '%s\n' ${STILL[@]+"${STILL[@]}"} | grep -qFx -- "$label"; then
            KEEP+=("$row")
          else
            WARN_ROWS+=("$(printf '%s' "$row" | cut -f1,2)"$'\t'"live already carries the bytes of this tree")
          fi
        done
        BLOCK=(${KEEP[@]+"${KEEP[@]}"})
      fi
    fi

    if [[ "${#BOX_ROWS[@]}" -eq 0 && "${n_drift:-0}" -gt 0 ]]; then
      echo "  FAIL — box-install counts $n_drift drifted row(s) but named none."
      echo "         Refusing to interpret that: run it yourself and read the rows."
      echo "         → ssh lab '/data/kernel-hive/scripts/host/box-install.sh --repo /data/kernel-hive'"
      FAILED_STAGES+=("box state")
      fail=1
    elif [[ "${#BOX_ROWS[@]}" -eq 0 ]]; then
      echo "  ok — live files match the box checkout ($boxsha)"
    else
      if [[ "${#WARN_ROWS[@]}" -gt 0 ]]; then
        echo "  warn — ${#WARN_ROWS[@]} live row(s) differ from the box checkout ($boxsha), accounted for:"
        for row in "${WARN_ROWS[@]:0:12}"; do box_row_line warn "$row"; done
        [[ "${#WARN_ROWS[@]}" -gt 12 ]] && echo "    … and $((${#WARN_ROWS[@]} - 12)) more"
        echo "    not blocking. Whoever owns those rows deploys them — do NOT run"
        echo "    box-deploy.sh --apply to clear this while other streams are live."
      fi
      if [[ "${#BLOCK[@]}" -gt 0 ]]; then
        echo "  FAIL — ${#BLOCK[@]} live file(s) THIS PUSH touches match neither the box"
        echo "         checkout ($boxsha) nor this working tree — hand-edited on labhost,"
        echo "         or an install left half done:"
        for row in "${BLOCK[@]:0:12}"; do box_row_line FAIL "$row"; done
        [[ "${#BLOCK[@]}" -gt 12 ]] && echo "    … and $((${#BLOCK[@]} - 12)) more"
        echo "         → ssh lab '/data/kernel-hive/scripts/host/box-install.sh --repo /data/kernel-hive <label>'"
        echo "           names the row; scripts/lib/box-sync-pairs.sh gives its live path"
        echo "         → install YOUR row from YOUR tree, or re-run the install that half ran"
        echo "         → scripts/dev/box-deploy.sh --apply   (whole checkout; safe only when no"
        echo "           other stream has live edits in flight — it reverts them)"
        FAILED_STAGES+=("box state")
        fail=1
      fi
    fi
    if ! git merge-base --is-ancestor "$(git rev-parse HEAD)" "$boxsha" 2>/dev/null; then
      echo "  note: after this push, deploy it: scripts/dev/box-deploy.sh --apply"
    fi
  else
    # old-style fallback: the box checkout has no box-install.sh yet
    if bash scripts/dev/verify-box-sync.sh; then echo "  ok"; else
      echo "  FAIL — repo and box have drifted; scripts/dev/box-deploy.sh --apply"
      FAILED_STAGES+=("box state")
      fail=1
    fi
  fi
else
  echo "  SKIPPED: ssh $boxlab unreachable (public clone, offline, or CI)"
fi

if [[ "$fail" != "0" ]]; then
  echo "pre-push-gate: BLOCKED — failed: ${FAILED_STAGES[*]}"
  echo "               fix per the → lines above, then push again (report BLOCKED, not done)."
  echo "               Emergency bypass: SKIP_GATE=1 git push  (never for main)."
  exit 1
fi

echo "pre-push-gate: OK — gate green"
exit 0
