#!/usr/bin/env bash
# .claude/hooks/shared-clone-flag-sessionstart.sh — SessionStart: /clear ends
# the "use shared clone" grant.
#
# WHY. 2026-08-26: the operator cleared a session with /clear and the next one
# still reported SHARED-CLONE EDITS ALLOWED. The grant is a FILE
# (.claude/shared-clone-ok), so it outlived by days the conversation that
# granted it — a permission nobody remembers giving is still a permission. The
# phrase is spoken to a conversation, so it should not outlive one.
#
# POLICY. On SessionStart with source=clear, remove the flag. A resumed,
# forked, compacted or freshly started session KEEPS it, so the grant still
# spans a --continue and an ordinary relaunch; "back to sandboxes" (deleting
# the file) and KH_ALLOW_SHARED_EDIT=1 are unchanged.
#
# settings.json declares matcher "clear" (SessionStart matches on `source`),
# and this script re-checks `source` from the payload: two nets, so a matcher
# that ever stops filtering cannot silently revoke on every startup.
#
# The removal is ANNOUNCED (systemMessage), never silent — a revoked
# permission the operator cannot see is the same class of surprise as one that
# never expires. It revokes for the whole clone, so a background job editing
# in place is stopped too; that is what clearing is asking for.
set -uo pipefail

FLAG="${CLAUDE_PROJECT_DIR:-.}/.claude/shared-clone-ok"
[ -e "$FLAG" ] || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"
export PAYLOAD
python3 <<'PY' || exit 0
import json, os, sys

try:
    d = json.loads(os.environ.get("PAYLOAD") or "{}")
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or d.get("source") != "clear":
    sys.exit(1)
flag = os.path.join(os.environ.get("CLAUDE_PROJECT_DIR") or ".", ".claude", "shared-clone-ok")
try:
    os.remove(flag)
except OSError:
    sys.exit(1)
print(json.dumps({"systemMessage":
                  "shared-clone-guard: /clear removed .claude/shared-clone-ok — "
                  "the shared clone is land-only again. "
                  'Say "use shared clone" to re-grant.'}))
PY
