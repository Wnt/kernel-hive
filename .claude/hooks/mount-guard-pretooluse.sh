#!/usr/bin/env bash
# .claude/hooks/mount-guard-pretooluse.sh — PreToolUse(Bash) tripwire: no raw
# bind-mount surgery or umount on labhost outside chroot-guard.
#
# WHY. The labhost mount tree is `shared:2`. Twice now a hand-rolled chroot
# teardown has propagated out of the sandbox and stripped the HOST's mounts:
#   2026-08-10  host /dev/pts unmounted -> every new interactive ssh login died
#               ("PTY allocation failed") while automation kept working.
#   2026-08-17  securityfs, /dev/shm and eight more /sys+/dev submounts
#               unmounted -> dbus-daemon could no longer resolve AppArmor peer
#               labels -> Proxmox's pre-start hook died in `timedatectl` ->
#               `pct start` failed fleet-wide, latent until the next restart.
# Both were agents doing the obvious dangerous thing directly. AGENTS.md
# already forbids it; this hook makes the rule a hard stop at the harness.
#
# POLICY (deny = exit 2; stderr goes back to the agent):
#   * scope: Bash commands that reach labhost's HOST namespace (`ssh … lab …`).
#     `pct exec` runs inside a guest's own mount namespace and is exempt.
#   * deny `umount` (always destructive on a shared tree) and `mount` with
#     --bind/--rbind/-B/-R/--move/-M/--make-* (the propagation footguns).
#   * plain additive `mount -t fs src tgt` stays allowed — restoring a missing
#     host mount must never be blocked by the guard that exists to protect it.
#   * anything going through `chroot-guard` is the sanctioned path and passes.
#
# This is a tripwire, not a jail: it catches the observed failure mode, not a
# determined adversary. The kernel-level guarantee is `chroot-guard
# run-private`; the on-box healer is mount-sentinel (scripts/host/).
set -uo pipefail

# Operator escape — the same mechanism as .claude/shared-clone-ok (see
# shared-clone-guard-pretooluse.sh). Lifts this raw-mount tripwire when the
# operator has explicitly taken responsibility for host mount surgery. It does
# NOT make the operation safe: labhost's shared:2 mount tree can still propagate
# an umount onto HOST mounts. `chroot-guard run-private` remains the safe path
# that trips no guard and needs no escape; prefer it. Set the flag with
#   touch .claude/mount-guard-ok      (gitignored, per clone; here.sh can show it)
[ "${KH_ALLOW_HOST_MOUNT:-0}" = 1 ] && exit 0
[ -e "${CLAUDE_PROJECT_DIR:-.}/.claude/mount-guard-ok" ] && exit 0

# The heredoc below occupies python's stdin, so hand the hook payload over via
# the environment instead of the pipe.
MOUNT_GUARD_PAYLOAD="$(cat 2>/dev/null || true)"
export MOUNT_GUARD_PAYLOAD

python3 <<'PY'
import json
import os
import re
import sys

try:
    data = json.loads(os.environ.get("MOUNT_GUARD_PAYLOAD", ""))
except ValueError:
    sys.exit(0)
if data.get("tool_name") != "Bash":
    sys.exit(0)
cmd = data.get("tool_input", {}).get("command") or ""

if "chroot-guard" in cmd:
    sys.exit(0)  # the sanctioned path
if not re.search(r"\bssh\b[^|;&]*\blab\b", cmd):
    sys.exit(0)  # not aimed at labhost's host namespace
if re.search(r"\bpct\s+exec\b", cmd):
    sys.exit(0)  # runs inside a guest's own mount namespace

dangerous = (
    re.search(r"\bumount\b", cmd)
    or re.search(r"\bmount\b[^|;&]*--(?:r?bind|move|make-\w+)\b", cmd)
    or re.search(r"\bmount\s+-[A-Za-z]*[BRM]\b", cmd)
)
if not dangerous:
    sys.exit(0)

sys.stderr.write(
    "mount-guard: BLOCKED — raw umount / bind-mount surgery on labhost.\n"
    "The host mount tree is shared:2; a hand-rolled mount/teardown propagates\n"
    "out and strips HOST mounts (2026-08-10: /dev/pts; 2026-08-17: securityfs\n"
    "-> AppArmor/dbus broke -> `pct start` failed fleet-wide).\n"
    "Use the sanctioned paths instead:\n"
    "  ad-hoc chroot work:  ssh lab 'chroot-guard run-private bash -c \"…\"'\n"
    "  in scripts:          chroot_guard_mount_api / chroot_guard_umount_all\n"
    "  restore host mounts: ssh lab 'systemctl start mount-sentinel.service'\n"
    "If you truly need a raw mount operation on the host, ask the operator.\n"
)
sys.exit(2)
PY
