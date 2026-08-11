#!/bin/bash
# install-box-endpoint.sh — workstation-side installer for the cloud-agent
# SSH endpoint (see docs/lab/CLOUD-AGENTS.md for the whole picture).
#
# It does the three things labhost cannot do for itself:
#   1. fetch the `forwarder-agent` binary (Wnt/forwarder CI artifact, or a local
#      build you point it at) and ship it to labhost,
#   2. read the forwarder's shared token off the VPS (never printed, never
#      written to the repo),
#   3. run scripts/cloud-agents/box-endpoint-setup.sh over ssh, which installs
#      the hardened loopback sshd + the dial-out tunnel unit.
#
# Usage:
#   scripts/cloud-agents/install-box-endpoint.sh --pubkey ~/.ssh/lab_cloudagent.pub
#   scripts/cloud-agents/install-box-endpoint.sh --pubkey KEY.pub --port 10022
#
# Env overrides: LAB_SSH (default `ssh lab`), FORWARDER_HOST, FORWARDER_SSH,
# FORWARDER_AGENT_TOKEN (skips the VPS read), FORWARDER_AGENT_BIN (skips the
# CI download).
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/local-env.sh"

FORWARDER_HOST="${FORWARDER_HOST:-${SH_TUNNEL_HOST:-tunnel.example.com}}"
# Arrays, because these are commands with arguments, not single words.
read -r -a LAB <<<"${LAB_SSH:-ssh lab}"
read -r -a VPS <<<"${FORWARDER_SSH:-ssh root@$FORWARDER_HOST}"
PUBLIC_PORT=10022
PUBKEY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pubkey) PUBKEY_FILE="$2" && shift 2 ;;
    --port) PUBLIC_PORT="$2" && shift 2 ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done
[ -n "$PUBKEY_FILE" ] && [ -r "$PUBKEY_FILE" ] || {
  echo "--pubkey <file> is required (the cloud agent's PUBLIC key)" >&2
  exit 2
}
case "$(cat "$PUBKEY_FILE")" in
  *PRIVATE*)
    echo "refusing: $PUBKEY_FILE looks like a PRIVATE key" >&2
    exit 2
    ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== forwarder-agent binary"
BIN="${FORWARDER_AGENT_BIN:-}"
if [ -z "$BIN" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  RUN_ID="$(gh run list --repo Wnt/forwarder --workflow CI --branch main \
    --status success --limit 1 --json databaseId --jq '.[0].databaseId')"
  echo "   downloading from Wnt/forwarder CI run $RUN_ID"
  gh run download --repo Wnt/forwarder -n forwarder-binaries --dir "$TMP" "$RUN_ID"
  BIN="$TMP/forwarder-agent-linux-amd64"
fi
[ -s "$BIN" ] || {
  echo "no forwarder-agent binary at $BIN" >&2
  exit 1
}
# Ship to a temp name and move into place, so a running agent is never a
# half-written file (ETXTBSY / truncated binary on the next restart).
"${LAB[@]}" 'cat > /usr/local/bin/.forwarder-agent.new' <"$BIN"
"${LAB[@]}" 'chmod 0755 /usr/local/bin/.forwarder-agent.new &&
	mv /usr/local/bin/.forwarder-agent.new /usr/local/bin/forwarder-agent &&
	/usr/local/bin/forwarder-agent --help 2>&1 | head -1' || true

echo "== forwarder shared token"
TOKEN="${FORWARDER_AGENT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  TOKEN="$("${VPS[@]}" 'sed -n "s/^FORWARDER_AGENT_TOKEN=//p" /etc/forwarder/forwarder.env')"
fi
[ -n "$TOKEN" ] || {
  echo "empty token — set FORWARDER_AGENT_TOKEN or check the VPS env file" >&2
  exit 1
}
echo "   got it (${#TOKEN} chars, not printed)"

echo "== box-side install"
# The secrets ride in the piped script body, not in the remote argv — otherwise
# the token would sit in labhost's process list for the length of the run.
{
  printf 'export CA_PUBKEY=%q CA_TOKEN=%q CA_CONTROL_HOST=%q CA_PUBLIC_PORT=%q\n' \
    "$(cat "$PUBKEY_FILE")" "$TOKEN" "$FORWARDER_HOST" "$PUBLIC_PORT"
  cat "$HERE/box-endpoint-setup.sh"
} | "${LAB[@]}" 'bash -s'

echo
echo "== now verify from outside: scripts/cloud-agents/check-tunnel.sh --key <privkey>"
