#!/bin/bash
# sync-venv.sh — build the gallery server's Python virtualenv from the repo's
# lockfile. RUN ON labhost (or via `ssh lab`). Idempotent: re-running with an
# unchanged lock is a no-op after the hash check.
#
# The server's third-party Python (WebAuthn) is pinned by scripts/serve/
# requirements.txt — compiled from requirements.in with hashes — instead of
# coming from apt. Two reasons: labhost gets upstream security fixes the day
# they ship rather than when Debian backports them, and Dependabot can open the
# upgrade PR itself (.github/dependabot.yml).
#
#   sync-venv.sh [--venv DIR] [--requirements FILE] [--check]
#
#   --check   verify the venv matches the lock; exit non-zero if not. Installs
#             nothing. Intended for a deploy gate.
set -euo pipefail

VENV=/data/vms/streamhost/serve/.venv
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ="$HERE/requirements.txt"
CHECK=0

while [ $# -gt 0 ]; do
  case "$1" in
    --venv) VENV="$2" && shift 2 ;;
    --requirements) REQ="$2" && shift 2 ;;
    --check) CHECK=1 && shift ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '[venv] %s\n' "$*"; }
die() {
  printf '[venv] ERROR: %s\n' "$*" >&2
  exit 1
}

[ -f "$REQ" ] || die "no lockfile at $REQ"

# The lock's own digest is the staleness marker: same lock + existing venv means
# there is nothing to do, and a changed lock forces a reinstall even if the
# version numbers happen to look unchanged.
WANT="$(sha256sum "$REQ" | awk '{print $1}')"
STAMP="$VENV/.requirements.sha256"
HAVE="$(cat "$STAMP" 2>/dev/null || true)"

if [ "$WANT" = "$HAVE" ] && [ -x "$VENV/bin/python" ]; then
  log "up to date ($VENV)"
  exit 0
fi

if [ "$CHECK" = 1 ]; then
  die "venv at $VENV does not match $REQ — run sync-venv.sh"
fi

log "building $VENV from $(basename "$REQ")"
if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV" || die "python3 -m venv failed (is python3-venv installed?)"
fi

# --require-hashes: every wheel must match a hash in the lock, so a compromised
# or substituted package fails the install instead of landing on labhost.
# --upgrade so a downgrade in the lock is honoured too.
"$VENV/bin/pip" install --quiet --upgrade --require-hashes -r "$REQ" ||
  die "pip install from the lockfile failed"

printf '%s\n' "$WANT" >"$STAMP"
log "installed:"
"$VENV/bin/pip" list --format=freeze | sed 's/^/[venv]   /'
