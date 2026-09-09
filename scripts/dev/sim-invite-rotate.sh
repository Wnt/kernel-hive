#!/usr/bin/env bash
# sim-invite-rotate.sh — mint a fresh viewer invite for visitor-sim's standing
# credential, with no human completing a passkey ceremony.
#
# WHY. visitor-sim's /data/vms/streamhost/serve/pki/sim-invite.code is an
# ordinary invite: it expires (INVITE_TTL_SECS, or the ttlDays given here) and
# the only way to mint a new one used to be an admin passkey session in a
# browser, which automation cannot self-heal. /auth/invite/issue (box-side
# only, gated exactly like /clientcmd/admin) lets this script do it instead.
#
# Runs FROM CT950. Does ONE `ssh lab '<cmd>'`: on the box, curl POSTs to the
# loopback HTTPS listener with the operator token
# (/data/vms/streamhost/serve/pki/clientcmd.token, same as clientcmd.sh),
# writes the returned code to sim-invite.code atomically (tmp + mv) at mode
# 600 root, and prints only the invite's expiry — never the code itself, on
# this side or the box's. Then, back on CT950, deletes the stale
# visitor-sim invite-session cache if present, so the next run redeems the
# new code instead of trying an old cookie first (docs/lab/VISITOR-SIM.md
# "When it expires").
#
# usage: scripts/dev/sim-invite-rotate.sh [--ttl-days N]
#   --ttl-days N   invite lifetime in days, 1..90 (default 30)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB="${LAB:-lab}"
SERVE_DIR="${SERVE_DIR:-/data/vms/streamhost/serve}"
TTL_DAYS=30

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ttl-days)
      TTL_DAYS="${2:?usage: sim-invite-rotate.sh [--ttl-days N]}"
      shift
      ;;
    -h | --help)
      sed -n '2,21p' "$0"
      exit 0
      ;;
    *)
      echo "sim-invite-rotate.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

case "$TTL_DAYS" in
  '' | *[!0-9]*)
    echo "sim-invite-rotate.sh: --ttl-days must be a positive integer, got: $TTL_DAYS" >&2
    exit 2
    ;;
esac

# The remote script is self-contained: it reads the token, POSTs, and writes
# sim-invite.code atomically, all inside the ONE ssh call the brief requires.
# Only its final line (the expiry) reaches stdout here.
expires_at=$(
  # shellcheck disable=SC2029 # SERVE_DIR/TTL_DAYS are ours; client-side expansion is intended
  ssh "$LAB" "SERVE_DIR=$(printf '%q' "$SERVE_DIR") TTL_DAYS=$(printf '%q' "$TTL_DAYS") bash -s" <<'REMOTE'
set -euo pipefail
token_file="$SERVE_DIR/pki/clientcmd.token"
code_file="$SERVE_DIR/pki/sim-invite.code"
tmp_file="$code_file.tmp.$$"

if [ ! -r "$token_file" ]; then
  echo "sim-invite-rotate.sh: no admin token at $token_file" >&2
  exit 1
fi

response=$(
  curl -sk -X POST "https://127.0.0.1:8443/auth/invite/issue" \
    -H "X-Admin-Token: $(cat "$token_file")" \
    -H 'Content-Type: application/json' \
    -d "$(
      jq -nc --arg name "visitor-sim (automated)" --argjson ttlDays "$TTL_DAYS" \
        '{name:$name,role:"viewer",ttlDays:$ttlDays}'
    )"
)

code=$(printf '%s' "$response" | jq -r '.code // empty')
expires_at=$(printf '%s' "$response" | jq -r '.expiresAt // empty')
if [ -z "$code" ] || [ -z "$expires_at" ]; then
  echo "sim-invite-rotate.sh: issue failed: $response" >&2
  exit 1
fi

umask 077
printf '%s' "$code" >"$tmp_file"
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$code_file"
printf '%s\n' "$expires_at"
REMOTE
)

cache="$REPO_ROOT/scripts/visitor-sim/visitor-sim-runs/invite-session.json"
if [ -e "$cache" ]; then
  rm -f "$cache"
fi

echo "rotated: expires $expires_at"
