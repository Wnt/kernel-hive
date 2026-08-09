#!/usr/bin/env bash
# .claude/hooks/pre-push-gate.sh — local mirror of the CI quality gate.
#
# Blocks a push whose commits carry the repo's Claude-session trailer
# (Claude-Session: / Co-Authored-By: ... Claude) unless the full gate is green,
# so agent branches never reach origin red. Human pushes pass through unless
# GATE_ALL=1. Emergency bypass: SKIP_GATE=1 (never for main).
#
# Runs the canonical CI static gate locally: per-language lint (each skipped if
# its toolchain is absent) then the two cross-cutting gates (file-size budget,
# generated-file drift). Non-zero exit blocks the push.
#
# Plus one gate CI cannot run: repo/box sync drift (scripts/dev/verify-box-sync.sh).
# It is probe-gated on `ssh lab` reachability, so it blocks a push only where the
# box exists to check against, and silently skips everywhere else.
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

# --- decide whether this push needs the gate ---
zero="0000000000000000000000000000000000000000"
gate_needed="${GATE_ALL:-0}"
while read -r _local_ref local_sha _remote_ref remote_sha; do
  [[ -z "${local_sha:-}" ]] && continue
  [[ "$local_sha" == "$zero" ]] && continue # branch deletion
  if [[ "$remote_sha" == "$zero" ]]; then
    revs=$(git rev-list --max-count=200 "$local_sha" 2>/dev/null)
  else
    revs=$(git rev-list "$remote_sha..$local_sha" 2>/dev/null)
  fi
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    if git show -s --format='%B' "$c" | grep -qiE 'Claude-Session:|Co-Authored-By: .*Claude'; then
      gate_needed=1
      break
    fi
  done <<<"$revs"
  [[ "$gate_needed" == "1" ]] && break
done

if [[ "$gate_needed" != "1" ]]; then
  echo "pre-push-gate: no Claude-session commits in this push; skipping (GATE_ALL=1 to force)"
  exit 0
fi

echo "pre-push-gate: running quality gate (SKIP_GATE=1 to bypass)"
fail=0

# --- per-language lint (canonical CI commands; skipped when toolchain absent) ---
if have npx; then
  echo "== TS/JS lint (eslint + knip) =="
  if (cd spa && npx eslint . --max-warnings=0 && npx knip); then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
else
  echo "== TS/JS lint == skip (npx not found)"
fi

if have cargo; then
  echo "== Rust lint (fmt + clippy) =="
  if (cd streamhost && cargo fmt --all --check && cargo clippy --all-targets -- -D warnings); then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
else
  echo "== Rust lint == skip (cargo not found)"
fi

if have ruff; then
  echo "== Python lint (ruff) =="
  if ruff check scripts && ruff format --check scripts; then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
else
  echo "== Python lint == skip (ruff not found)"
fi

if have shfmt && have shellcheck; then
  echo "== Bash lint (shfmt + shellcheck) =="
  # shellcheck disable=SC2046  # intentional word-split of the file list
  if shfmt -d $(bash scripts/lint/shell-sources.sh) && shellcheck $(bash scripts/lint/shell-sources.sh); then
    echo "  ok"
  else
    echo "  FAIL"
    fail=1
  fi
else
  echo "== Bash lint == skip (shfmt/shellcheck not found)"
fi

# --- cross-cutting gates (this branch) ---
echo "== file-size budget (--strict) =="
if node scripts/check-file-size.mjs --strict; then
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

# --- box-sync drift (ONLY when the box is actually reachable) ---
# A public clone, an offline laptop and GitHub Actions have no `ssh lab`, so
# this is probe-gated: unreachable box => SKIP with a message, never a failure.
# That is also why it is deliberately absent from .github/workflows/quality.yml
# — a CI job that can never reach the box would be permanently red.
# Reachable box + drift => hard fail, because that is exactly the state that let
# 228 rows pile up unnoticed. Cost when it does run: one batched SSH session.
echo "== box-sync drift =="
if ssh -o ConnectTimeout=4 -o BatchMode=yes "${LAB:-lab}" true 2>/dev/null; then
  if bash scripts/dev/verify-box-sync.sh; then
    echo "  ok"
  else
    echo "  FAIL — repo and box have drifted; reconcile per-row (the box is"
    echo "         authoritative for generated/live artifacts, the repo for source)."
    echo "         Full table: scripts/dev/verify-box-sync.sh --all"
    fail=1
  fi
else
  echo "  skip (ssh ${LAB:-lab} unreachable — public clone, offline, or CI)"
fi

if [[ "$fail" != "0" ]]; then
  echo "pre-push-gate: BLOCKED — fix the failures above (report BLOCKED, not done)."
  echo "               Emergency bypass: SKIP_GATE=1 git push  (never for main)."
  exit 1
fi

echo "pre-push-gate: OK — gate green"
exit 0
