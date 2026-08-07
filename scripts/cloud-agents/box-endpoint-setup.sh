#!/bin/bash
# box-endpoint-setup.sh — install the cloud-agent SSH endpoint ON the box.
#
# WHAT THIS BUILDS (and why it is not just "open port 22")
#   Cloud coding agents (Google Jules, Claude cloud sessions, …) run outside the
#   LAN and still need `ssh lab` to drive tiles. Two rules shape the design:
#     * no inbound port on the home WAN — the box dials OUT to the forwarder VPS
#       (Wnt/forwarder), which publishes the far end on a public TCP port;
#     * the publicly reachable sshd is NOT the LAN sshd. This installs a second,
#       purpose-built sshd instance that
#         - listens on 127.0.0.1 only (so the LAN cannot reach it either — the
#           ONLY way in is the tunnel),
#         - accepts exactly the keys in /etc/cloud-agent-ssh/authorized_keys,
#         - has passwords/keyboard-interactive off, so a stolen password is
#           worthless and the public port cannot be brute-forced.
#   Revoking every cloud agent is therefore one file truncate + one restart, and
#   it never touches how you or the LAN reach the box.
#
# RUN IT (from a workstation checkout — the file never lives on the box):
#   ssh lab 'CA_PUBKEY="ssh-ed25519 AAAA… cloud-agent" CA_TOKEN=… bash -s' \
#     < scripts/cloud-agents/box-endpoint-setup.sh
#   `scripts/cloud-agents/install-box-endpoint.sh` is the wrapper that also
#   ships the forwarder-agent binary; prefer it.
#
# Idempotent: safe to re-run after a key rotation, a port change, or a reboot.
set -euo pipefail

CA_PUBKEY="${CA_PUBKEY:?set CA_PUBKEY to the cloud-agent public key line}"
CA_TOKEN="${CA_TOKEN:?set CA_TOKEN to the forwarder shared agent token}"
CA_CONTROL_HOST="${CA_CONTROL_HOST:-tunnel.example.com}"
CA_PUBLIC_PORT="${CA_PUBLIC_PORT:-10022}" # public TCP port on the forwarder VPS
CA_SSHD_PORT="${CA_SSHD_PORT:-2222}"      # loopback port of the extra sshd
CA_TUNNEL_ID="${CA_TUNNEL_ID:-labssh}"
CA_AGENT_BIN="${CA_AGENT_BIN:-/usr/local/bin/forwarder-agent}"
# The public gallery rides the SAME agent: one dial-out connection carries both
# the cloud-agent SSH port and kernelhive's HTTP. Caddy terminates TLS at the
# edge and the agent hands the request to the HTTPS server's plaintext loopback
# listener (PUBLIC_PORT in scripts/serve/osgallery-https.service), which is the
# session-gated one. Set GALLERY_HOST= to leave the gallery unpublished.
GALLERY_HOST="${GALLERY_HOST-gallery.example.com}"
GALLERY_LOCAL_PORT="${GALLERY_LOCAL_PORT:-8081}"
GALLERY_TUNNEL_ID="${GALLERY_TUNNEL_ID:-gallery}"

SSH_DIR=/etc/cloud-agent-ssh
AGENT_DIR=/etc/forwarder-agent
SSHD_UNIT=sshd-cloud-agent.service
AGENT_UNIT=forwarder-agent.service

say() { printf '\n== %s\n' "$*"; }

[ -x "$CA_AGENT_BIN" ] || {
  echo "missing $CA_AGENT_BIN — ship it first (install-box-endpoint.sh does)" >&2
  exit 1
}

say "authorized key -> $SSH_DIR/authorized_keys"
install -d -m 0755 -o root -g root "$SSH_DIR"
# Single writer: the file is REPLACED, so removing an agent's key upstream and
# re-running is a real revocation rather than an append.
printf '%s\n' "$CA_PUBKEY" >"$SSH_DIR/authorized_keys"
chmod 0600 "$SSH_DIR/authorized_keys"
ssh-keygen -l -f "$SSH_DIR/authorized_keys"

say "hardened sshd config -> $SSH_DIR/sshd_config"
cat >"$SSH_DIR/sshd_config" <<EOF
# Managed by scripts/cloud-agents/box-endpoint-setup.sh — edits are overwritten.
# Second sshd instance: the far end of the cloud-agent reverse tunnel.
Port $CA_SSHD_PORT
ListenAddress 127.0.0.1
AddressFamily inet
PidFile /run/sshd-cloud-agent.pid

# Same host identity as the LAN sshd, so one known_hosts line covers both.
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin prohibit-password
PubkeyAuthentication yes
AuthorizedKeysFile $SSH_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AllowUsers root
UsePAM yes

# Agents scp files and occasionally forward the SPA port; both are in scope.
Subsystem sftp /usr/lib/openssh/sftp-server
AllowTcpForwarding yes
AllowAgentForwarding no
X11Forwarding no
PermitTunnel no

MaxAuthTries 3
MaxStartups 10:30:60
LoginGraceTime 20
ClientAliveInterval 30
ClientAliveCountMax 4
LogLevel VERBOSE
EOF
/usr/sbin/sshd -t -f "$SSH_DIR/sshd_config"

say "unit -> /etc/systemd/system/$SSHD_UNIT"
cat >"/etc/systemd/system/$SSHD_UNIT" <<EOF
[Unit]
Description=sshd (cloud-agent tunnel endpoint, loopback only)
Documentation=file://$SSH_DIR/sshd_config
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/sshd
ExecStart=/usr/sbin/sshd -D -e -f $SSH_DIR/sshd_config
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

say "forwarder-agent env -> $AGENT_DIR/agent.env"
install -d -m 0700 -o root -g root "$AGENT_DIR"
TUNNELS="$CA_TUNNEL_ID:tcp:$CA_PUBLIC_PORT:$CA_SSHD_PORT"
[ -n "$GALLERY_HOST" ] &&
  TUNNELS="$TUNNELS,$GALLERY_TUNNEL_ID:http:$GALLERY_HOST:$GALLERY_LOCAL_PORT"
cat >"$AGENT_DIR/agent.env" <<EOF
# Managed by scripts/cloud-agents/box-endpoint-setup.sh — edits are overwritten.
FORWARDER_SERVER=$CA_CONTROL_HOST
FORWARDER_AGENT_TOKEN=$CA_TOKEN
FORWARDER_TUNNELS=$TUNNELS
EOF
chmod 0600 "$AGENT_DIR/agent.env"

say "unit -> /etc/systemd/system/$AGENT_UNIT"
cat >"/etc/systemd/system/$AGENT_UNIT" <<EOF
[Unit]
Description=forwarder-agent (dial-out reverse tunnel: public :$CA_PUBLIC_PORT -> loopback :$CA_SSHD_PORT)
Documentation=https://github.com/Wnt/forwarder
After=network-online.target $SSHD_UNIT
Wants=network-online.target
Requires=$SSHD_UNIT

[Service]
EnvironmentFile=$AGENT_DIR/agent.env
ExecStart=$CA_AGENT_BIN
Restart=always
RestartSec=5
# It only dials out and connects to loopback — no privilege needed.
DynamicUser=yes
NoNewPrivileges=yes
ProtectHome=yes
PrivateTmp=yes
RestrictAddressFamilies=AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF

say "enable + (re)start"
systemctl daemon-reload
systemctl enable --now "$SSHD_UNIT" "$AGENT_UNIT" >/dev/null
systemctl restart "$SSHD_UNIT"
systemctl restart "$AGENT_UNIT"

say "verify"
for _ in $(seq 1 20); do
  ss -ltn "sport = :$CA_SSHD_PORT" | grep -q 127.0.0.1 && break
  sleep 0.5
done
ss -ltn "sport = :$CA_SSHD_PORT" | tail -n +2
systemctl is-active "$SSHD_UNIT" "$AGENT_UNIT"
# The agent logs the public address it was granted; surface it either way.
journalctl -u "$AGENT_UNIT" -n 15 --no-pager | tail -8
echo
echo "cloud-agent endpoint ready: ssh -p $CA_PUBLIC_PORT root@$CA_CONTROL_HOST"
