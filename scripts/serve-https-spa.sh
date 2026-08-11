#!/usr/bin/env bash
# serve-https-spa.sh  (SERVE agent — reproducible bring-up)
# ---------------------------------------------------------------------------
# Stand up the HTTPS serving plane for the Kernel Hive UI on the LAN so the
# page is a SECURE CONTEXT (required for WebTransport / WebCodecs), and expose
# SAME-ORIGIN signaling JSON for the registry's production streamhost stations.
#
# It deploys only the UI entries present in dist/ and leaves other webroot
# content (such as boot-replay videos under boot/) in place. It does not manage
# the streamhost station processes or any Proxmox guests.
#
# Runs from a workstation or the dev box (needs ssh to the host). Sub-commands:
#   build     npm run build in spa/
#   deploy    push built dist + server + ca script to the host
#   manifests publish generated tiles.json + gallery-manifest.json (no UI build)
#   cert      mint/refresh the local-CA leaf on the host, pull rootCA.pem here
#   up        (cert + deploy-if-needed +) start the HTTPS server
#   down      stop the HTTPS server by pidfile
#   status    show the HTTPS server and signaling registry
#   trust     print the one-time macOS trust command for rootCA.pem
#   all       build + deploy + cert + up   (full reproducible bring-up)
#
# Endpoints when up:
#   UI      https://192.0.2.10:8443/
#   signal   https://192.0.2.10:8443/signal/<tile>.json
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/local-env.sh"

HOST="${HOST:-${SH_HOST_IP:-192.0.2.10}}"
LAN_IP="${LAN_IP:-${SH_HOST_IP:-192.0.2.10}}"
HTTPS_PORT="${HTTPS_PORT:-8443}"
# ssh transport, portable across machines:
#   * LAB_KEY set        -> explicit key + root@$HOST   (full override)
#   * ~/.ssh/lab_key     -> that key + root@$HOST       (default key location)
#   * otherwise          -> the 'lab' ssh_config alias  (Mac / dev box)
if [ -n "${LAB_KEY:-}" ]; then
  SSH="ssh -i $LAB_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$HOST"
elif [ -f "$HOME/.ssh/lab_key" ]; then
  SSH="ssh -i $HOME/.ssh/lab_key -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@$HOST"
else
  SSH="ssh -o ConnectTimeout=10 lab"
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SPA_WEB="$REPO/spa"
DIST="$SPA_WEB/dist"
LOCAL_PKI="$REPO/scripts/serve/pki"
# All four published documents are RENDERED, never committed: resolved from
# registry/tiles/*.json + registry/posters/*.md on the way out
# (stations-registry.py rendered()). publish_manifests re-renders before it reads.
TILES_SRC="$REPO/build/registry/tiles.json"
GALLERY_MANIFEST_SRC="$REPO/build/registry/gallery-manifest.json"
POSTER_DOCS_SRC="$REPO/build/registry/poster-docs.json"
GOLDEN_MANIFEST_SRC="$REPO/build/registry/golden-manifest.json"

# host-side layout
SERVE_DIR="/data/vms/streamhost/serve"
WEBROOT="$SERVE_DIR/webroot"
HOST_PKI="$SERVE_DIR/pki"
TILES="$SERVE_DIR/tiles.json"
SRV_PY="$SERVE_DIR/osgallery-https-server.py"
CLIENTCMD_SH="$SERVE_DIR/clientcmd.sh"
CA_SH="$SERVE_DIR/gen-local-ca.sh"
RESET_SH="$SERVE_DIR/reset-tile.sh"
PIDFILE="/run/osgallery-https.pid"
LOGFILE="/var/log/osgallery-https.log"

msg() { echo "[serve-https] $*"; }

# ---------------------------------------------------------------------------
build() {
  command -v npm >/dev/null || {
    msg "ERROR: npm not on PATH (needed to build the SPA)"
    exit 1
  }
  msg "building SPA (npm run build) in $SPA_WEB"
  (cd "$SPA_WEB" && npm run build)
  [ -f "$DIST/index.html" ] || {
    msg "ERROR: build produced no dist/index.html"
    exit 1
  }
  msg "built -> $DIST"
}

deploy() {
  [ -f "$DIST/index.html" ] || {
    msg "ERROR: no built dist; run '$0 build' first"
    exit 1
  }
  msg "deploying dist + server to $HOST:$SERVE_DIR"
  $SSH "mkdir -p $WEBROOT $HOST_PKI"
  # Timestamped safety tar of the current webroot before replacing UI entries;
  # keep the newest 3.
  msg "backing up current webroot -> $SERVE_DIR/webroot-backup-<epoch>.tar.gz (keep 3)"
  $SSH "if [ -n \"\$(ls -A $WEBROOT 2>/dev/null)\" ]; then \
          tar czf $SERVE_DIR/webroot-backup-\$(date +%s).tar.gz -C $WEBROOT . && \
          ls -1t $SERVE_DIR/webroot-backup-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f; \
        else echo '[serve-https] webroot empty, nothing to back up'; fi"
  # Extract to a staging dir, then replace only top-level entries shipped by
  # dist/. Unrelated webroot content (notably boot/) remains untouched.
  tar czf - -C "$DIST" . | $SSH "set -e; \
    stage=\$(mktemp -d '$SERVE_DIR/.spa-deploy.XXXXXX'); \
    trap 'rm -rf \"\$stage\"' EXIT; \
    tar xzf - -C \"\$stage\"; \
    for src in \"\$stage\"/* \"\$stage\"/.[!.]* \"\$stage\"/..?*; do \
      [ -e \"\$src\" ] || [ -L \"\$src\" ] || continue; \
      name=\${src##*/}; \
      rm -rf -- \"$WEBROOT/\$name\"; \
      mv -- \"\$src\" \"$WEBROOT/\$name\"; \
    done"
  # ship the serving plane and operator helper
  $SSH "cat > $SRV_PY" <"$REPO/scripts/serve/osgallery-https-server.py"
  $SSH "cat > $CLIENTCMD_SH && chmod +x $CLIENTCMD_SH" <"$REPO/scripts/serve/clientcmd.sh"
  $SSH "cat > $CA_SH && chmod +x $CA_SH" <"$REPO/scripts/serve/gen-local-ca.sh"
  # The server shells out to this for POST /restore/<osId>, so it has to travel
  # with the server that calls it — it is a tracked box-sync pair, and leaving it
  # out of deploy meant a fix in the repo silently never reached labhost.
  $SSH "cat > $RESET_SH && chmod +x $RESET_SH" <"$REPO/scripts/serve/reset-tile.sh"
  # The public gallery's plane: the auth package the server imports, the
  # sign-in/people pages it serves, and the lockfile + venv builder its unit
  # runs as ExecStartPre. These travel WITH the server for the same reason
  # reset-tile.sh does — the server fails to import half a deploy.
  # Replaced wholesale, not merged: a module dropped from the repo must not
  # linger on labhost, where the package would happily keep importing it.
  msg "shipping the auth plane"
  tar czf - -C "$REPO/scripts/serve" --exclude __pycache__ auth authui |
    $SSH "set -e; rm -rf $SERVE_DIR/auth $SERVE_DIR/authui; tar xzf - -C $SERVE_DIR"
  $SSH "cat > $SERVE_DIR/requirements.txt" <"$REPO/scripts/serve/requirements.txt"
  $SSH "cat > $SERVE_DIR/requirements.in" <"$REPO/scripts/serve/requirements.in"
  $SSH "cat > $SERVE_DIR/sync-venv.sh && chmod +x $SERVE_DIR/sync-venv.sh" <"$REPO/scripts/serve/sync-venv.sh"
  # The guarded account reset. It must live ON labhost, because the failure mode
  # it exists to prevent is someone reaching for `rm auth-state.json` there.
  $SSH "cat > $SERVE_DIR/reset-auth.sh && chmod +x $SERVE_DIR/reset-auth.sh" <"$REPO/scripts/serve/reset-auth.sh"
  $SSH "cat > $SERVE_DIR/check-stream-tickets.py" <"$REPO/scripts/serve/check-stream-tickets.py"
  $SSH "cat > $SERVE_DIR/pen-trace.py" <"$REPO/scripts/serve/pen-trace.py"
  publish_manifests
  msg "deployed."
}

# Publish the two registry-generated runtime JSON documents with atomic per-file
# replacement. This is independent of deploy(): ordinary new stations need no Vite build.
publish_manifests() {
  # None of these has a committed copy to go stale: render them now, from the
  # registry, and publish those bytes. A registry that no longer validates fails
  # HERE, with the live serving plane untouched.
  msg "rendering the runtime documents from the registry"
  python3 "$REPO/scripts/stations-registry.py" render >/dev/null || {
    msg "ERROR: render failed (registry does not validate) — nothing published"
    exit 1
  }
  for src in "$TILES_SRC" "$GALLERY_MANIFEST_SRC" "$POSTER_DOCS_SRC" "$GOLDEN_MANIFEST_SRC"; do
    [ -f "$src" ] || {
      msg "ERROR: render produced no $src"
      exit 1
    }
  done
  msg "publishing runtime manifests -> $SERVE_DIR"
  $SSH "mkdir -p $WEBROOT"
  $SSH "set -e; tmp=$TILES.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $TILES" <"$TILES_SRC"
  $SSH "set -e; tmp=$WEBROOT/gallery-manifest.json.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $WEBROOT/gallery-manifest.json" <"$GALLERY_MANIFEST_SRC"
  # Poster prose is runtime data too: the UI fetches /poster-docs.json before
  # falling back to its bundled copy, so publishing here is what makes a poster
  # edit live without a Vite build.
  $SSH "set -e; tmp=$WEBROOT/poster-docs.json.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $WEBROOT/poster-docs.json" <"$POSTER_DOCS_SRC"
  # reset-tile.sh reads this to find each station's resetMode, so a station missing
  # here has a dead "Restore to golden" button. It went stale for irix and the
  # box copy simply had no entry, which reads as `unknown osId` at reset time.
  $SSH "set -e; tmp=$SERVE_DIR/golden-manifest.json.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $SERVE_DIR/golden-manifest.json" <"$GOLDEN_MANIFEST_SRC"
  msg "published tiles.json + webroot/gallery-manifest.json + webroot/poster-docs.json + golden-manifest.json"
}

cert() {
  msg "minting/refreshing local-CA leaf on the host"
  $SSH "mkdir -p $HOST_PKI; test -x $CA_SH || { mkdir -p $SERVE_DIR; }"
  # make sure the generator is present even if deploy() wasn't run yet
  $SSH "cat > $CA_SH && chmod +x $CA_SH" <"$REPO/scripts/serve/gen-local-ca.sh"
  $SSH "PKI=$HOST_PKI LAN_IP=$LAN_IP bash $CA_SH"
  mkdir -p "$LOCAL_PKI"
  $SSH "cat $HOST_PKI/rootCA.pem" >"$LOCAL_PKI/rootCA.pem"
  msg "root CA pulled -> $LOCAL_PKI/rootCA.pem"
  trust
}

trust() {
  cat <<EOF

  ── TRUST THE LOCAL CA (one time, on this Mac) ─────────────────────────────
  sudo security add-trusted-cert -d -r trustRoot \\
    -k /Library/Keychains/System.keychain "$LOCAL_PKI/rootCA.pem"

  Chrome reads the macOS System keychain, so this trusts the HTTPS SPA:
    https://$LAN_IP:$HTTPS_PORT/
  Then fully quit + reopen Chrome. (To undo: 'sudo security delete-certificate
  -c "KernelHive Local CA" /Library/Keychains/System.keychain'.)
  ───────────────────────────────────────────────────────────────────────────
EOF
}

up() {
  # ensure cert + files exist on host
  $SSH "test -f $HOST_PKI/leaf.crt && test -f $SRV_PY && test -f $WEBROOT/index.html" ||
    {
      msg "host not fully provisioned; running cert + deploy first"
      cert
      deploy
    }
  $SSH "test -f $TILES && test -f $WEBROOT/gallery-manifest.json" || publish_manifests

  msg "starting HTTPS SPA server on $LAN_IP:$HTTPS_PORT (systemd if installed, else pidfile $PIDFILE)"
  $SSH bash -s <<EOF
set -e
# Prefer the reboot-surviving systemd supervisor when it is installed; the
# detached pidfile path below is the fallback for boxes without the unit.
if systemctl cat osgallery-https.service >/dev/null 2>&1; then
  systemctl restart osgallery-https.service
  sleep 1
  if ss -ltnp 2>/dev/null | grep -q ":$HTTPS_PORT "; then
    echo "[serve-https] up via systemd osgallery-https.service"; exit 0
  fi
  echo "[serve-https] systemd start FAILED; journal tail:"
  journalctl -u osgallery-https.service --no-pager --lines 8; exit 1
fi
if [ -f "$PIDFILE" ] && kill -0 "\$(cat $PIDFILE)" 2>/dev/null; then
  echo "[serve-https] already running (pid \$(cat $PIDFILE))"; exit 0
fi
WEBROOT=$WEBROOT SIGNAL_CONFIG=$TILES BIND_IP=0.0.0.0 PORT=$HTTPS_PORT \
  CERT=$HOST_PKI/leaf.crt KEY=$HOST_PKI/leaf.key SIGNAL_HOST=$LAN_IP \
  nohup python3 $SRV_PY >$LOGFILE 2>&1 &
echo \$! > $PIDFILE
sleep 1
if kill -0 "\$(cat $PIDFILE)" 2>/dev/null; then
  echo "[serve-https] up (pid \$(cat $PIDFILE))"
else
  echo "[serve-https] FAILED; log tail:"; tail -8 $LOGFILE; exit 1
fi
EOF

  echo
  msg "READY:"
  msg "  SPA     https://$LAN_IP:$HTTPS_PORT/"
  msg "  signal  https://$LAN_IP:$HTTPS_PORT/signal/<tile>.json  (tiles: /signal/index.json)"
}

down() {
  msg "stopping HTTPS server (systemd if installed, else pidfile)"
  $SSH bash -s <<EOF
if systemctl cat osgallery-https.service >/dev/null 2>&1; then
  systemctl stop osgallery-https.service && echo "[serve-https] stopped systemd osgallery-https.service (still enabled for boot)"
  exit 0
fi
if [ -f "$PIDFILE" ] && kill -0 "\$(cat $PIDFILE)" 2>/dev/null; then
  kill "\$(cat $PIDFILE)" && echo "[serve-https] stopped (pid \$(cat $PIDFILE))"
else echo "[serve-https] not running"; fi
rm -f $PIDFILE
EOF
}

status() {
  $SSH bash -s <<EOF
if systemctl cat osgallery-https.service >/dev/null 2>&1; then
  systemctl --no-pager --lines 0 status osgallery-https.service || true
  ss -ltnp 2>/dev/null | grep ":$HTTPS_PORT" || true
elif [ -f "$PIDFILE" ] && kill -0 "\$(cat $PIDFILE)" 2>/dev/null; then
  echo "[serve-https] HTTPS RUNNING pid \$(cat $PIDFILE)  https://$LAN_IP:$HTTPS_PORT/"
  ss -ltnp 2>/dev/null | grep ":$HTTPS_PORT" || true
else echo "[serve-https] HTTPS STOPPED"; fi
echo "--- signal tiles ---"; cat $TILES 2>/dev/null || echo "(no tiles.json)"
EOF
}

case "${1:-up}" in
  build) build ;;
  deploy) deploy ;;
  manifests) publish_manifests ;;
  cert) cert ;;
  trust) trust ;;
  up) up ;;
  down) down ;;
  status) status ;;
  all)
    build
    deploy
    cert
    up
    ;;
  *)
    echo "Usage: $0 {build|deploy|manifests|cert|trust|up|down|status|all}"
    exit 2
    ;;
esac
