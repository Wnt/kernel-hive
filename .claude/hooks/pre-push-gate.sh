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

# --- read git's ref list, derive the pushed ranges and whether we owe the gate -
zero="0000000000000000000000000000000000000000"
gate_needed="${GATE_ALL:-0}"
ranges=()
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  [[ "$local_sha" == "$zero" ]] && continue # branch deletion
  if [[ "$remote_sha" == "$zero" ]]; then
    # New branch: everything it adds on top of the integration branch, and if
    # that is unknown, a bounded slice of its own history.
    if git rev-parse --verify --quiet origin/main >/dev/null; then
      ranges+=("origin/main..$local_sha")
      revs=$(git rev-list --max-count=200 "origin/main..$local_sha" 2>/dev/null)
    else
      ranges+=("$local_sha")
      revs=$(git rev-list --max-count=200 "$local_sha" 2>/dev/null)
    fi
  else
    ranges+=("$remote_sha..$local_sha")
    revs=$(git rev-list "$remote_sha..$local_sha" 2>/dev/null)
  fi
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if git show -s --format='%B' "$c" | grep -qiE 'Claude-Session:|Co-Authored-By: .*Claude'; then
      gate_needed=1
      break
    fi
  done <<<"$revs"
done

# Run by hand (no ref list on stdin): fall back to what a push would send.
if [[ "${#ranges[@]}" -eq 0 ]]; then
  if git rev-parse --verify --quiet '@{push}' >/dev/null 2>&1; then
    ranges+=('@{push}..HEAD')
  elif git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1; then
    ranges+=('@{upstream}..HEAD')
  elif git rev-parse --verify --quiet origin/main >/dev/null; then
    ranges+=('origin/main..HEAD')
  else
    ranges+=('HEAD')
  fi
  echo "pre-push-gate: no ref list on stdin; using ${ranges[*]}"
fi

if [[ "$gate_needed" != "1" && "${GATE_FULL:-0}" != "1" ]]; then
  echo "pre-push-gate: no Claude-session commits in this push; skipping (GATE_ALL=1 to force)"
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

echo "pre-push-gate: running quality gate (SKIP_GATE=1 to bypass)"
fail=0

# --- per-language lint: owed only when that language changed in the range -----
if ! touches '^spa/|\.(ts|tsx|js|jsx|mjs|cjs)$'; then
  echo "== TS/JS lint == not owed (no TS/JS in the pushed range)"
elif ! have npx; then
  echo "== TS/JS lint == SKIPPED: npx not found (CI covers this)"
else
  echo "== TS/JS lint (eslint + knip) =="
  if (cd spa && npx eslint . --max-warnings=0 && npx knip); then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
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
  echo "== Rust lint (fmt + clippy) =="
  if (cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings); then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
fi

if ! touches '\.py$'; then
  echo "== Python lint == not owed (no Python in the pushed range)"
elif ! have ruff; then
  echo "== Python lint == SKIPPED: ruff not found (CI covers this)"
else
  echo "== Python lint (ruff) =="
  if ruff check scripts && ruff format --check scripts; then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
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
    echo "== Bash lint (shfmt + shellcheck) — ${#SH_LIVE[@]} file(s) from the range =="
    if shfmt -d "${SH_LIVE[@]}" && shellcheck "${SH_LIVE[@]}"; then
      echo "  ok"
    else
      echo "  FAIL"
      fail=1
    fi
  fi
fi

# --- cross-cutting gates: owed by EVERY branch, regardless of language --------
# --committed, not the default union: by push time your own new file is tracked,
# so a real breach is still caught (proven), while a sibling's untracked
# in-flight file cannot block a push its author has nothing to do with.
echo "== file-size budget (--strict --committed) =="
if node scripts/check-file-size.mjs --strict --committed; then
  echo "  ok"
else
  echo "  FAIL"
  fail=1
fi

echo "== generated-file drift =="
if bash scripts/check-generated-drift.sh; then
  echo "  ok"
else
  echo "  FAIL"
  fail=1
fi

# --- box state (ONLY when the box is actually reachable) ---
# A public clone, an offline laptop and GitHub Actions have no `ssh lab`, so
# this is probe-gated: unreachable box => SKIP with a message, never a failure.
# Since 2026-08-17 the box is INSTALLED FROM A COMMIT (scripts/dev/box-deploy.sh
# → scripts/host/box-install.sh from /data/kernel-hive), so "box behind main"
# is the normal state between a push and its deploy and is only a WARN here.
# What still hard-fails is the thing that used to hide inside "drift": live
# files that differ from the commit the box checkout is at — i.e. someone
# edited labhost by hand, or an install was left half done. That is one
# in-process dry-run of box-install on labhost, no hashes over the wire.
echo "== box state (deployed commit vs live files) =="
if ssh -n -o ConnectTimeout=4 -o BatchMode=yes "${LAB:-lab}" true 2>/dev/null; then
  if bs="$(ssh -n -o ConnectTimeout=15 "${LAB:-lab}" '/data/kernel-hive/scripts/host/box-install.sh --repo /data/kernel-hive --json 2>/dev/null')" && [ -n "$bs" ]; then
    changed="$(printf '%s' "$bs" | sed -n 's/.*"changed":\([0-9]*\).*/\1/p')"
    newr="$(printf '%s' "$bs" | sed -n 's/.*"new":\([0-9]*\).*/\1/p')"
    refused="$(printf '%s' "$bs" | sed -n 's/.*"refused":\([0-9]*\).*/\1/p')"
    boxsha="$(printf '%s' "$bs" | sed -n 's/.*"sha":"\([0-9a-f]\{12\}\).*/\1/p')"
    if [ "${changed:-0}" = 0 ] && [ "${newr:-0}" = 0 ] && [ "${refused:-0}" = 0 ]; then
      echo "  ok — live files match the box checkout ($boxsha)"
    else
      echo "  FAIL — live files differ from the box checkout ($boxsha): changed=$changed new=$newr refused=$refused"
      echo "         → scripts/dev/box-deploy.sh            (plan: which rows, and why)"
      echo "         → scripts/dev/box-deploy.sh --apply    (install the checkout; hand edits are backed up)"
      fail=1
    fi
    if ! git merge-base --is-ancestor "$(git rev-parse HEAD)" "$boxsha" 2>/dev/null; then
      echo "  note: after this push, deploy it: scripts/dev/box-deploy.sh --apply"
    fi
  else
    # old-style fallback: the box checkout has no box-install.sh yet
    if bash scripts/dev/verify-box-sync.sh; then echo "  ok"; else
      echo "  FAIL — repo and box have drifted; scripts/dev/box-deploy.sh --apply"
      fail=1
    fi
  fi
else
  echo "  SKIPPED: ssh ${LAB:-lab} unreachable (public clone, offline, or CI)"
fi

if [[ "$fail" != "0" ]]; then
  echo "pre-push-gate: BLOCKED — fix the failures above (report BLOCKED, not done)."
  echo "               Emergency bypass: SKIP_GATE=1 git push  (never for main)."
  exit 1
fi

echo "pre-push-gate: OK — gate green"
exit 0
