#!/bin/bash
# check-tunnel.sh — prove the cloud-agent path end to end, the way a cloud agent
# sees it: from OUTSIDE the LAN, through the public tunnel port, into labhost.
#
#   scripts/cloud-agents/check-tunnel.sh --key ~/.ssh/lab_cloudagent
#
# Passing means a Jules/Claude cloud VM with the same key can run `ssh lab`.
# Failing tells you which of the three links broke: box units, VPS listener, or
# the SSH login itself.
set -uo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/local-env.sh"

HOST="${FORWARDER_HOST:-${SH_TUNNEL_HOST:-tunnel.example.com}}"
PORT="${CLOUD_AGENT_PORT:-10022}"
KEY=""
# An array, because LAB_SSH is a command with arguments ("ssh lab"), not a word.
read -r -a LAB <<<"${LAB_SSH:-ssh lab}"

while [ $# -gt 0 ]; do
  case "$1" in
    --key) KEY="$2" && shift 2 ;;
    --host) HOST="$2" && shift 2 ;;
    --port) PORT="$2" && shift 2 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

fails=0
check() {
  local label="$1"
  shift
  if "$@" >/tmp/ct.$$ 2>&1; then
    printf 'PASS  %-28s %s\n' "$label" "$(head -3 /tmp/ct.$$ | tr '\n' ' ')"
  else
    printf 'FAIL  %-28s %s\n' "$label" "$(head -5 /tmp/ct.$$ | tr '\n' ' ')"
    fails=$((fails + 1))
  fi
  rm -f /tmp/ct.$$
}

echo "== box side (over the LAN)"
check "sshd-cloud-agent active" "${LAB[@]}" 'systemctl is-active sshd-cloud-agent'
check "forwarder-agent active" "${LAB[@]}" 'systemctl is-active forwarder-agent'
check "loopback sshd listening" "${LAB[@]}" 'ss -ltn "sport = :2222" | grep 127.0.0.1'

echo
echo "== public side (as a cloud agent sees it)"
check "tcp $HOST:$PORT open" timeout 10 bash -c "cat </dev/null >/dev/tcp/$HOST/$PORT"
if [ -n "$KEY" ]; then
  check "ssh login + hostname" timeout 25 ssh -i "$KEY" -p "$PORT" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
    "root@$HOST" 'hostname && labctl ls | head -3'
else
  echo "SKIP  ssh login                   (pass --key <private key> to test it)"
fi

echo
[ "$fails" -eq 0 ] && echo "cloud-agent tunnel: OK" && exit 0
echo "cloud-agent tunnel: $fails check(s) failed" >&2
exit 1
