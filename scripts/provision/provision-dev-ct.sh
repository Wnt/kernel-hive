#!/bin/bash
# provision-dev-ct.sh — recreate CT 950 "osgallery-dev" (the in-lab dev workstation).
#
# *** AUTHORED-FROM-DOCS, UNTESTED ***
# Reconstructed 2026-07-14 from docs/lab/dev-box-notes.md + the live
# /etc/pve/lxc/950.conf (the original container was built by hand, 2026-07-08).
# Review each phase on first use; nothing here has been executed end-to-end.
#
#   RUN ON THE PROXMOX HOST:
#     scripts/provision-dev-ct.sh [--ctid 950] [--ip 192.0.2.11/24] [--gw 192.0.2.1]
#                                 [--storage data] [--disk 24] [--user wnt]
#                                 [--pubkey ~/.ssh/authorized_keys]
#
# What it builds (mirrors the live CT950):
#   * newest UBUNTU LTS pveam template available at runtime (latest-stable rule)
#   * 4 cores / 8G / 2G swap / nesting=1 / onboot / static IP
#   * user wnt + passwordless sudo, en_US.UTF-8 locale, mosh (sshd AcceptEnv
#     LANG LC_* stripped — macOS forwards LC_CTYPE=UTF-8 which aborts mosh-server)
#   * toolset: node LTS + npm, rustup stable, gh, claude (Claude Code CLI), git,
#     ripgrep/jq/tmux/python3, qemu-utils, ffmpeg (libavcodec is MANDATORY —
#     without it Firefox WebCodecs has NO H.264 and every avc1 e2e silently fails),
#     xdotool, mosh
#   * xdesk.service: Xvfb :1 1920x1080x24 + openbox + x11vnc shared desktop
#     (DISPLAY=:1 via /etc/profile.d/xdesk.sh; VNC on :5900 — set a password!)
#   * Playwright 1.6x + google-chrome-stable + bundled firefox, e2e-chrome helper
#   * an ssh keypair for wnt; print it so you can authorize it on labhost
set -euo pipefail

CTID=950
IP="192.0.2.11/24"
GW="192.0.2.1"
STORAGE="data"
DISK=24
DEVUSER="wnt"
PUBKEY_FILE="${PUBKEY_FILE:-/root/.ssh/authorized_keys}"
while [ $# -gt 0 ]; do case "$1" in
  --ctid)
    CTID="$2"
    shift 2
    ;;
  --ip)
    IP="$2"
    shift 2
    ;;
  --gw)
    GW="$2"
    shift 2
    ;;
  --storage)
    STORAGE="$2"
    shift 2
    ;;
  --disk)
    DISK="$2"
    shift 2
    ;;
  --user)
    DEVUSER="$2"
    shift 2
    ;;
  --pubkey)
    PUBKEY_FILE="$2"
    shift 2
    ;;
  -h | --help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
esac done
log() { printf '\033[1;36m[dev-ct]\033[0m %s\n' "$*"; }
pctx() { pct exec "$CTID" -- bash -lc "$*"; }

command -v pct >/dev/null || {
  echo "run on the Proxmox host (pct not found)" >&2
  exit 1
}
pct status "$CTID" >/dev/null 2>&1 && {
  echo "CT $CTID already exists — refusing" >&2
  exit 1
}

# ---- 1. newest Ubuntu LTS template (latest-stable rule: resolve at runtime) ----
log "resolving newest Ubuntu LTS template via pveam"
pveam update >/dev/null
# LTS = even-year .04 releases; pick the highest version pveam offers
TMPL="$(pveam available --section system | awk '{print $2}' |
  grep -E '^ubuntu-[0-9]+\.04-standard' |
  sort -V | tail -1)"
[ -n "$TMPL" ] || {
  echo "no ubuntu LTS template found in pveam" >&2
  exit 1
}
log "template: $TMPL"
pveam download local "$TMPL" || true # no-op if cached

# ---- 2. create + start the CT (mirrors live 950.conf) --------------------------
log "creating CT $CTID (4c/8G/${DISK}G on $STORAGE, nesting, $IP)"
pct create "$CTID" "local:vztmpl/$TMPL" \
  --hostname osgallery-dev --ostype ubuntu \
  --cores 4 --memory 8192 --swap 2048 \
  --rootfs "${STORAGE}:${DISK}" \
  --features nesting=1 --onboot 1 --unprivileged 0 \
  --net0 "name=eth0,bridge=vmbr0,ip=${IP},gw=${GW},type=veth" \
  --nameserver "$GW"
pct start "$CTID"
sleep 5

# ---- 3. base system: locale, user, sudo, ssh keys, mosh fix --------------------
log "base packages + locale + user $DEVUSER"
pctx "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  sudo locales curl wget ca-certificates gnupg git ripgrep jq tmux python3 python3-venv \
  openssh-server mosh qemu-utils ffmpeg xdotool unzip build-essential pkg-config"
pctx "locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8"
# macOS forwards LC_CTYPE=UTF-8 (not a valid Linux locale) -> mosh-server aborts;
# stop accepting the client's locale env, use the container's own.
pctx "sed -i 's/^AcceptEnv LANG LC_\*/#AcceptEnv LANG LC_*/' /etc/ssh/sshd_config && systemctl reload ssh || true"
pctx "id $DEVUSER >/dev/null 2>&1 || useradd -m -s /bin/bash $DEVUSER"
pctx "echo '$DEVUSER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-$DEVUSER && chmod 440 /etc/sudoers.d/90-$DEVUSER"
if [ -f "$PUBKEY_FILE" ]; then
  log "authorizing keys from $PUBKEY_FILE"
  pctx "install -d -m 700 -o $DEVUSER -g $DEVUSER /home/$DEVUSER/.ssh"
  pct push "$CTID" "$PUBKEY_FILE" "/home/$DEVUSER/.ssh/authorized_keys" --perms 600 --user 1000 --group 1000 ||
    pctx "cp /root/.ssh/authorized_keys /home/$DEVUSER/.ssh/authorized_keys 2>/dev/null; chown $DEVUSER:$DEVUSER /home/$DEVUSER/.ssh/authorized_keys" || true
fi
pctx "sudo -u $DEVUSER bash -c 'test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N \"\" -f ~/.ssh/id_ed25519 -C osgallery-dev'"

# ---- 4. dev toolchain: node LTS, rustup, gh, claude ----------------------------
log "node LTS + rustup + gh + claude"
pctx "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y -qq nodejs"
pctx "sudo -u $DEVUSER bash -c 'curl --proto \"=https\" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable'"
pctx "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && \
  apt-get update -qq && apt-get install -y -qq gh"
pctx "npm install -g @anthropic-ai/claude-code"

# ---- 5. headed-browser plane: chrome + playwright + xdesk (Xvfb/openbox/x11vnc) -
log "google-chrome + playwright + xdesk shared desktop"
pctx "curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list && \
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq google-chrome-stable xvfb openbox x11vnc x11-utils imagemagick"
pctx "sudo -u $DEVUSER bash -c 'mkdir -p ~/e2e && cd ~/e2e && npm init -y >/dev/null && npm i -D playwright@latest >/dev/null && npx playwright install firefox && npx playwright install-deps firefox' || true"

cat >/tmp/xdesk-start.$$ <<'EOS'
#!/bin/bash
# xdesk-start.sh — single shared X display: Xvfb :1 + openbox + x11vnc (:5900).
# Hardening option: add -localhost to x11vnc and tunnel ssh -L 5900:localhost:5900.
set -u
Xvfb :1 -screen 0 1920x1080x24 -nolisten tcp &
XP=$!
sleep 1
DISPLAY=:1 openbox &
x11vnc -display :1 -forever -shared -rfbport 5900 ${X11VNC_EXTRA:-} &
wait $XP
EOS
pct push "$CTID" /tmp/xdesk-start.$$ /usr/local/bin/xdesk-start.sh --perms 755
rm -f /tmp/xdesk-start.$$

cat >/tmp/xdesk-unit.$$ <<'EOS'
[Unit]
Description=Shared Xvfb+openbox+x11vnc desktop on :1 (E2E headed-browser plane)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xdesk-start.sh
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOS
pct push "$CTID" /tmp/xdesk-unit.$$ /etc/systemd/system/xdesk.service --perms 644
rm -f /tmp/xdesk-unit.$$
pctx "echo 'export DISPLAY=:1' > /etc/profile.d/xdesk.sh"
pctx "systemctl daemon-reload && systemctl enable --now xdesk.service"

cat >/tmp/e2e-chrome.$$ <<'EOS'
#!/bin/bash
# e2e-chrome <url> — headed Chrome on the shared :1 display (see dev-box-notes.md).
exec env DISPLAY=:1 google-chrome-stable --no-sandbox --use-gl=angle \
  --use-angle=swiftshader --ignore-certificate-errors --no-first-run "$@"
EOS
pct push "$CTID" /tmp/e2e-chrome.$$ /usr/local/bin/e2e-chrome --perms 755
rm -f /tmp/e2e-chrome.$$

# ---- 6. repo clone + wrap-up ----------------------------------------------------
pctx "sudo -u $DEVUSER bash -c 'test -d ~/osgallery || gh repo clone Wnt/kernel-hive ~/osgallery 2>/dev/null || git clone https://github.com/Wnt/kernel-hive ~/osgallery 2>/dev/null || true'"
log "DONE (untested-script caveats apply). Manual follow-ups:"
log "  1. authorize the CT's key on the lab box:"
pctx "cat /home/$DEVUSER/.ssh/id_ed25519.pub" || true
log "  2. gh auth login (as $DEVUSER); transfer the gitignored secrets"
log "     (uptoken, unifitoken, docs/gallery-credentials.md, credentials.ts, serve/pki)"
log "  3. set an x11vnc password or -localhost (dev-box-notes.md 'Gotchas')"
log "  4. verify Firefox H.264: apt policy ffmpeg (libavcodec) is installed — required for avc1 e2e"
