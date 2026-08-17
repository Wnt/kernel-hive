#!/usr/bin/env bash
# .claude/hooks/shared-clone-guard-pretooluse.sh — PreToolUse(Edit|Write|
# MultiEdit|NotebookEdit): the shared clone is LAND-ONLY.
#
# WHY. 2026-08-17 evening: a session did its first task correctly in a wt.sh
# sandbox, removed the sandbox, and — now standing in the shared clone — began
# the follow-up there. Its uncommitted edit to the https server collided with
# the orchestrator's cherry-pick minutes later. AGENTS.md says every task
# starts with `wt.sh new`; this hook makes that a hard stop at the harness,
# the way mount-guard does for umount.
#
# POLICY (deny = exit 2; stderr goes back to the agent):
#   * deny an Edit/Write whose file_path resolves under the project dir
#     ($CLAUDE_PROJECT_DIR — the clone the session was launched in) …
#   * … unless that project dir is itself a wt.sh sandbox
#     (/data/vms/sandbox/<name>/repo) or an agent worktree (.claude/worktrees/);
#   * … unless the path is under .claude/ (hooks/settings are per-clone) or is
#     gitignored scratch the repo never sees (registry/local.env, build/);
#   * … unless KH_ALLOW_SHARED_EDIT=1 (a deliberate orchestrator fix, or the
#     operator working solo — say so in the commit).
# Bash heredocs are not caught; the pre-commit path and here.sh's "dirty"
# line are the second and third nets.
set -uo pipefail

[ "${KH_ALLOW_SHARED_EDIT:-0}" = 1 ] && exit 0
PAYLOAD="$(cat 2>/dev/null || true)"
export PAYLOAD
python3 <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    sys.exit(0)
tool = d.get("tool_name", "")
if tool not in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    sys.exit(0)
path = (d.get("tool_input") or {}).get("file_path") or (d.get("tool_input") or {}).get("notebook_path") or ""
proj = os.environ.get("CLAUDE_PROJECT_DIR") or d.get("cwd") or ""
if not path or not proj:
    sys.exit(0)
rp = os.path.realpath(path)
pp = os.path.realpath(proj)
# a session launched inside a sandbox or agent worktree is already isolated
if pp.startswith("/data/vms/sandbox/") or "/.claude/worktrees/" in pp + "/":
    sys.exit(0)
if not (rp == pp or rp.startswith(pp + "/")):
    sys.exit(0)  # editing somewhere else (a sandbox, /data, scratch) — fine
rel = os.path.relpath(rp, pp)
allowed_prefixes = (".claude/", "registry/local.env", "build/", "spa/dist/", "spa/node_modules/")
if rel.startswith(allowed_prefixes):
    sys.exit(0)
sys.stderr.write(
    "shared-clone-guard: REFUSED — %s is in the shared clone (%s), which is land-only.\n"
    "  Every task runs in its own full stack: scripts/dev/wt.sh new <name> && cd /data/vms/sandbox/<name>/repo\n"
    "  (AGENTS.md → 'Every task runs in its own full stack'). Orchestrator fix on purpose? KH_ALLOW_SHARED_EDIT=1.\n"
    % (rel, pp)
)
sys.exit(2)
PY
