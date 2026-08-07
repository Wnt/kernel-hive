#!/bin/bash
# jules-setup.sh — environment setup script for Google Jules (and any other
# cloud agent VM that gets a checkout of this repo plus the LAB_SSH_* secrets).
#
# Paste this into the Jules repo config → Environment → "Setup script":
#     bash scripts/cloud-agents/jules-setup.sh
# and set the environment variables listed in docs/lab/CLOUD-AGENTS.md.
#
# It does two jobs:
#   1. wires up `ssh lab` — the one door into the Proxmox lab, reached through
#      the reverse tunnel (no inbound port on the home WAN);
#   2. installs the tools the repo's CI quality gate needs, because an agent
#      that cannot run the gate cannot land a change (docs/lab/AGENT-CI-EXIT-RULE.md).
#
# Non-secret defaults are baked in; only the private key is a real secret.
# Nothing here ever prints key material.
set -uo pipefail

LAB_SSH_HOST="${LAB_SSH_HOST:-tunnel.example.com}"
LAB_SSH_PORT="${LAB_SSH_PORT:-10022}"
LAB_SSH_USER="${LAB_SSH_USER:-root}"
KEY="$HOME/.ssh/lab_cloudagent"

step() { printf '\n=== %s\n' "$*"; }

# Values may arrive base64-encoded (a single-line env var survives web forms and
# shell quoting far better than a multi-line PEM), or as the raw text.
decode() {
  local v="$1" d
  d="$(printf '%s' "$v" | base64 -d 2>/dev/null)" && [ -n "$d" ] && printf '%s' "$d" && return
  printf '%s' "$v"
}

step "ssh identity"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ -n "${LAB_SSH_KEY:-}" ]; then
  decode "$LAB_SSH_KEY" >"$KEY"
  printf '\n' >>"$KEY" # ssh rejects a key file without a trailing newline
  chmod 600 "$KEY"
  # Normalise CRLF, which web-form copy/paste loves to introduce.
  sed -i 's/\r$//' "$KEY"
  ssh-keygen -y -f "$KEY" >/dev/null 2>&1 &&
    echo "   private key OK: $(ssh-keygen -lf "$KEY" | awk '{print $1, $2}')" ||
    echo "   WARNING: LAB_SSH_KEY did not parse as an OpenSSH private key"
else
  echo "   WARNING: LAB_SSH_KEY is not set — the lab will be unreachable"
fi

step "known_hosts + ssh config"
: >"$HOME/.ssh/known_hosts.lab"
if [ -n "${LAB_SSH_HOSTKEY:-}" ]; then
  # Pinning the host key means the agent never has to answer a prompt, and a
  # MITM on the public tunnel port fails closed instead of being accepted.
  printf '[%s]:%s %s\n' "$LAB_SSH_HOST" "$LAB_SSH_PORT" \
    "$(decode "$LAB_SSH_HOSTKEY")" >"$HOME/.ssh/known_hosts.lab"
else
  echo "   LAB_SSH_HOSTKEY unset — falling back to trust-on-first-use"
  ssh-keyscan -p "$LAB_SSH_PORT" -t ed25519 "$LAB_SSH_HOST" \
    >"$HOME/.ssh/known_hosts.lab" 2>/dev/null
fi
cat >"$HOME/.ssh/config" <<EOF
Host lab
    HostName $LAB_SSH_HOST
    Port $LAB_SSH_PORT
    User $LAB_SSH_USER
    IdentityFile $KEY
    IdentitiesOnly yes
    UserKnownHostsFile $HOME/.ssh/known_hosts.lab
    StrictHostKeyChecking yes
    ServerAliveInterval 30
    ConnectTimeout 20
EOF
chmod 600 "$HOME/.ssh/config"

step "lab reachability"
if ssh -o BatchMode=yes lab 'hostname; uptime' 2>&1; then
  echo "   ssh lab works — labctl and the tiles are reachable"
else
  echo "   FAILED: ssh lab did not connect."
  echo "   Check: tunnel up on the box (systemctl status forwarder-agent),"
  echo "          LAB_SSH_KEY/HOST/PORT set, Jules network access enabled."
fi

step "quality-gate tooling"
# Best-effort: a missing linter must not fail the snapshot, but the agent is
# still expected to run the gate before reporting done.
have() { command -v "$1" >/dev/null 2>&1; }
have shellcheck || sudo apt-get install -y -q shellcheck >/dev/null 2>&1 ||
  apt-get install -y -q shellcheck >/dev/null 2>&1 || echo "   shellcheck: unavailable"
have shfmt || go install mvdan.cc/sh/v3/cmd/shfmt@latest >/dev/null 2>&1 ||
  echo "   shfmt: unavailable"
have ruff || pip install --quiet --user ruff >/dev/null 2>&1 ||
  pipx install ruff >/dev/null 2>&1 || echo "   ruff: unavailable"
export PATH="$PATH:$HOME/go/bin:$HOME/.local/bin"
for t in shellcheck shfmt ruff node npm; do
  printf '   %-11s %s\n' "$t" "$(command -v $t || echo MISSING)"
done

step "spa dependencies"
if [ -f spa/package-lock.json ]; then
  (cd spa && npm ci --no-audit --no-fund >/dev/null 2>&1) &&
    echo "   npm ci OK" || echo "   npm ci failed — run it yourself before touching spa/"
fi

step "done"
echo "Read AGENTS.md first. The lab is one hop away: ssh lab 'labctl ls'"
