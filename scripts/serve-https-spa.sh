#!/usr/bin/env bash
# serve-https-spa.sh  (SERVE agent — reproducible bring-up)
# ---------------------------------------------------------------------------
# Stand up the HTTPS serving plane for the Kernel Hive UI on the LAN so the
# page is a SECURE CONTEXT (required for WebTransport / WebCodecs), and expose
# SAME-ORIGIN signaling JSON for the registry's production streamhost stations.
#
# It deploys only the UI entries present in dist/ and leaves other webroot
# content in place and republishes boot/ (boot-replay videos, baked on the box —
# see publish_boot) from the box staging every time. It does not manage
# the streamhost station processes or any Proxmox guests.
#
# Runs from a workstation or the dev box (needs ssh to the host). Sub-commands:
#   build     npm run build in spa/
#   deploy    push built dist + server + ca script to the host
#   manifests publish generated tiles.json + gallery-manifest.json + boot/ (no UI build)
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
# All five published documents are RENDERED, never committed: resolved from
# registry/stations/*.json + registry/posters/*.md on the way out
# (stations-registry.py rendered()). publish_manifests re-renders before it reads.
TILES_SRC="$REPO/build/registry/tiles.json"
GALLERY_MANIFEST_SRC="$REPO/build/registry/gallery-manifest.json"
POSTER_DOCS_SRC="$REPO/build/registry/poster-docs.json"
GOLDEN_MANIFEST_SRC="$REPO/build/registry/golden-manifest.json"
FLEET_TABLE_SRC="$REPO/build/registry/fleet-table.json"

# host-side layout
SERVE_DIR="/data/vms/streamhost/serve"
BOX_REPO="${BOX_REPO:-/data/kernel-hive}" # the box checkout (scripts/dev/box-repo.sh)
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
  # Instana EUM (spa/index.html's bootstrap + spa/src/analytics/instana.ts) is
  # configured entirely through build-time env: Vite only exposes/substitutes
  # VITE_-prefixed vars (see VITE_BASE above), so the INSTANA_* keys
  # local-env.sh already loaded from registry/local.env are re-exported under
  # their VITE_ names here, right before the one place that invokes `vite
  # build`. Unset on a fresh clone / CI / a contributor's build — that is not
  # an error, it is the documented no-key fallback (index.html: no ineum stub,
  # no script tag, nothing sent).
  msg "building SPA (npm run build) in $SPA_WEB"
  (
    cd "$SPA_WEB"
    export VITE_INSTANA_WEBSITE_KEY="${INSTANA_WEBSITE_KEY:-}"
    # The bundle gets the beacon proxy's FIRST-PARTY PATH, never the tenant URL
    # (docs/ANALYTICS.md §8.3). `:+` not `:-`: an unset upstream still exports
    # EMPTY, so index.html's no-url no-op is reached rather than a
    # contributor's build pointing at a proxy they do not run.
    export VITE_INSTANA_EUM_REPORTING_URL="${INSTANA_EUM_REPORTING_URL:+/eum}"
    npm run build
  )
  [ -f "$DIST/index.html" ] || {
    msg "ERROR: build produced no dist/index.html"
    exit 1
  }
  msg "built -> $DIST"
}

# ---------------------------------------------------------------------------
# THE SILENT-TELEMETRY TRAP, and the guard that closes it.
#
# `build()` above is the ONLY place that exports VITE_INSTANA_* into `vite
# build`. A bare `npm run build` in spa/ — which every quality-gate run, every
# `npm test && npm run build`, and every contributor without registry/local.env
# does — leaves the percent-delimited placeholders unsubstituted, and
# spa/index.html's bootstrap then takes its documented no-key path: no ineum
# stub, no vendor script tag, ZERO telemetry.
#
# `deploy()` does NOT rebuild. It publishes whatever dist/ happens to be there.
# So "run the gate, then deploy" silently ships a bundle with Instana entirely
# disabled — which happened on 2026-09-01 and cost a full debugging cycle
# chasing missing beacons that were never sent.
#
# The keyless build stays legal: a contributor with no local.env must still be
# able to build and deploy their own gallery. What must never happen is a
# keyless dist being published by a machine that HAS the key — that is always
# an accident, and the fix is always the same one command. So the guard asks
# both questions, not one.
dist_placeholder_names() {
  # The VITE_ placeholder names still unsubstituted in the built index.html,
  # one per line. Built with a character class rather than a literal so this
  # very script never becomes substitution text (spa/index.html's own comments
  # take the same precaution, for the same reason).
  #
  # The `|| true` is load-bearing under `set -euo pipefail`: grep exits 1 when
  # it matches NOTHING, which is the GOOD case here, and an unguarded failure
  # inside `$(...)` on the right of an assignment kills the script — silently,
  # with no output at all, right before the deploy it was meant to guard.
  # Measured, not imagined: that is exactly how the first cut of this function
  # behaved on a correctly-built dist.
  { grep -o "%VITE[_A-Z0-9]*%" "$DIST/index.html" 2>/dev/null || true; } | sort -u
}

check_dist_is_publishable() {
  local placeholders newer
  placeholders="$(dist_placeholder_names)"

  if [ -n "$placeholders" ] && [ -n "${INSTANA_WEBSITE_KEY:-}" ]; then
    msg "ERROR: refusing to deploy — this dist was built WITHOUT the Instana key,"
    msg "       but this machine HAS one (registry/local.env). Publishing it would"
    msg "       silently disable ALL browser telemetry on the live gallery."
    msg "       Unsubstituted placeholders in $DIST/index.html:"
    while IFS= read -r ph; do printf '         %s\n' "$ph" >&2; done <<<"$placeholders"
    msg "       A bare 'npm run build' in spa/ does this — only '$0 build'"
    msg "       exports the VITE_INSTANA_* vars. Rebuild and retry:"
    msg "         $0 build && $0 deploy"
    exit 1
  fi

  if [ -n "$placeholders" ]; then
    # No key configured: the documented no-key fallback. Legal, but never silent.
    msg "NOTE: keyless build (no INSTANA_WEBSITE_KEY in registry/local.env)."
    msg "      The deployed SPA will send no Instana beacons — this is the"
    msg "      documented fallback, not a fault. Unsubstituted: $(echo "$placeholders" | tr '\n' ' ')"
  fi

  # Staleness: a dist older than the sources it was built from is the same
  # class of mistake wearing different clothes (deploying yesterday's bundle
  # and reading today's behaviour into it). Scoped to what vite actually
  # consumes, so an unrelated docs edit never blocks a deploy.
  newer="$(find "$SPA_WEB/src" "$SPA_WEB/index.html" "$SPA_WEB/package.json" \
    "$SPA_WEB/vite.config.ts" -newer "$DIST/index.html" -print -quit 2>/dev/null || true)"
  if [ -n "$newer" ]; then
    if [ -n "${ALLOW_STALE_DIST:-}" ]; then
      msg "WARNING: $DIST is older than the SPA sources (e.g. $newer)."
      msg "         Deploying anyway — ALLOW_STALE_DIST is set."
    else
      msg "ERROR: refusing to deploy — $DIST is older than the SPA sources."
      msg "       Newer than the build: $newer"
      msg "       Rebuild first:  $0 build"
      msg "       To publish an intentionally older bundle: ALLOW_STALE_DIST=1 $0 deploy"
      exit 1
    fi
  fi
}

deploy() {
  [ -f "$DIST/index.html" ] || {
    msg "ERROR: no built dist; run '$0 build' first"
    exit 1
  }
  check_dist_is_publishable
  # scripts/dev/stage.sh builds a preview into this SAME dist/ with
  # vite base=/staging/<name>/, so a deploy that follows a stage ships a bundle
  # whose asset paths AND router basename point at the staging path — the live
  # gallery then renders NOTHING. (Done exactly that on 2026-08-23.) The
  # production build is the only one whose entry script is rooted at /assets/.
  if ! grep -q 'src="/assets/' "$DIST/index.html"; then
    msg "ERROR: $DIST was not built for the production base."
    msg "       Its entry script is: $(grep -o 'src="[^\"]*"' "$DIST/index.html" | head -1)"
    msg "       A stage.sh preview leaves a staged dist behind. Rebuild first:"
    msg "         (cd spa && npm run build)"
    exit 1
  fi
  # Upload this build's source maps to Instana BEFORE the maps are stripped
  # from what actually ships (immediately below). If this is a no-op
  # (unconfigured) or fails, it never blocks the rest of the deploy — see the
  # function for why.
  publish_instana_sourcemaps
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
  #
  # .map files ARE shipped here (no --exclude). vite.config.ts's
  # `sourcemap: true` writes a `//# sourceMappingURL=` comment into the
  # shipped JS, and it needs a map to actually resolve at that URL. This is
  # deliberate, not an oversight: the built bundle already serves
  # unauthenticated (only the app shell at '/' is passkey-gated — verified:
  # `/assets/index-*.js` returns 200 with no session, `/` returns 401 — see
  # docs/PUBLIC-GALLERY.md), and the source is the openly-public kernel-hive
  # GitHub repo, so a map reveals nothing the repo doesn't already. A browser
  # only fetches a .map when its devtools is open, so this costs an ordinary
  # visitor nothing. The Instana upload just above is KEPT alongside this,
  # not replaced by it — see publish_instana_sourcemaps for why both exist.
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
  # The route modules the server IMPORTS, shipped from the same tree as the
  # server itself. box-deploy carries them too (they are tracked pairs), but a
  # deploy that ships a new server against an older signal_route.py/config.py
  # fails at IMPORT — and a serving unit that will not start takes the LAN
  # gallery down with the public one. That is the B1 failure shape from
  # docs/lab/walkin/PREFLIGHT.md, one level along: ship them together.
  for _mod in config.py signal_route.py walkin_plane.py; do
    $SSH "cat > $SERVE_DIR/$_mod" <"$REPO/scripts/serve/$_mod"
  done
  $SSH "cat > $CLIENTCMD_SH && chmod +x $CLIENTCMD_SH" <"$REPO/scripts/serve/clientcmd.sh"
  $SSH "cat > $CA_SH && chmod +x $CA_SH" <"$REPO/scripts/serve/gen-local-ca.sh"
  # The server shells out to this for POST /restore/<osId>, so it has to travel
  # with the server that calls it — it is a tracked box-sync pair, and leaving it
  # out of deploy meant a fix in the repo silently never reached labhost.
  $SSH "cat > $RESET_SH && chmod +x $RESET_SH" <"$REPO/scripts/serve/reset-tile.sh"
  # The public gallery's plane: the auth package the server imports, the
  # sign-in/people pages it serves, the walk-in broker package, and the
  # lockfile + venv builder its unit runs as ExecStartPre. These travel WITH
  # the server for the same reason reset-tile.sh does — the server fails to
  # import half a deploy.
  # Replaced wholesale, not merged: a module dropped from the repo must not
  # linger on labhost, where the package would happily keep importing it.
  #
  # THE THREE NAMES IN THIS rm -rf ARE CODE DIRECTORIES, AND THE LIST MUST NOT
  # GROW TOWARDS ITS SIBLINGS. `$SERVE_DIR` also holds `auth-state.json` — every
  # account, every passkey credential, every walk-in handle, and the walk-in
  # access switch — plus its dated rotations. It is state of record, not a
  # deploy artifact: a golden can be recaptured, but a passkey cannot be
  # regenerated and a walk-in handle IS the account. Nothing in this script may
  # delete, materialize or overwrite it, and anything that treats $SERVE_DIR as
  # a replaceable tree (a future content-addressed release layout, say) has to
  # enumerate what in it is NOT part of the deploy first — or the swap is a
  # delete. Same for `darklaunch.d/`. See docs/PUBLIC-GALLERY.md and the guarded
  # reset-auth.sh, which exists because the reflex it prevents is `rm` here.
  msg "shipping the auth plane"
  tar czf - -C "$REPO/scripts/serve" --exclude __pycache__ auth authui walkin |
    $SSH "set -e; rm -rf $SERVE_DIR/auth $SERVE_DIR/authui $SERVE_DIR/walkin; tar xzf - -C $SERVE_DIR"
  $SSH "cat > $SERVE_DIR/requirements.txt" <"$REPO/scripts/serve/requirements.txt"
  $SSH "cat > $SERVE_DIR/requirements.in" <"$REPO/scripts/serve/requirements.in"
  $SSH "cat > $SERVE_DIR/sync-venv.sh && chmod +x $SERVE_DIR/sync-venv.sh" <"$REPO/scripts/serve/sync-venv.sh"
  # The guarded account reset. It must live ON labhost, because the failure mode
  # it exists to prevent is someone reaching for `rm auth-state.json` there.
  $SSH "cat > $SERVE_DIR/reset-auth.sh && chmod +x $SERVE_DIR/reset-auth.sh" <"$REPO/scripts/serve/reset-auth.sh"
  $SSH "cat > $SERVE_DIR/check-stream-tickets.py" <"$REPO/scripts/serve/check-stream-tickets.py"
  $SSH "cat > $SERVE_DIR/pen-trace.py" <"$REPO/scripts/serve/pen-trace.py"
  $SSH "cat > $SERVE_DIR/key-trace.py" <"$REPO/scripts/serve/key-trace.py"
  publish_manifests
  publish_boot
  publish_instana_agent
  msg "deployed."
}

# Fetch the pinned Instana EUM agent from INSTANA_EUM_SCRIPT_URL and publish it
# self-hosted at $WEBROOT/vendor/instana-eum.min.js — spa/index.html's
# bootstrap loads it from that path, never from IBM's CDN directly, and it is
# NEVER committed to this public repo (gitignored on the box the same way
# scripts/serve/pki/ is). Every other document this script publishes is
# rendered FROM the repo; this one is fetched from a third party at deploy
# time, and it must not fail SILENTLY — an operator who thinks Instana is live
# while serving a 404 for the agent finds out from a support ticket.
publish_instana_agent() {
  if [ -z "${INSTANA_EUM_SCRIPT_URL:-}" ]; then
    msg "INSTANA_EUM_SCRIPT_URL unset — Instana EUM not configured, skipping vendor fetch"
    return 0
  fi
  msg "fetching Instana EUM agent from $INSTANA_EUM_SCRIPT_URL -> $WEBROOT/vendor/instana-eum.min.js"
  if $SSH "set -e; mkdir -p '$WEBROOT/vendor'; tmp=\$(mktemp '$WEBROOT/vendor/.instana-eum.min.js.XXXXXX'); \
      curl -fsSL --max-time 30 '$INSTANA_EUM_SCRIPT_URL' -o \"\$tmp\" && \
      test -s \"\$tmp\" && \
      mv \"\$tmp\" '$WEBROOT/vendor/instana-eum.min.js'"; then
    msg "published Instana EUM agent"
  else
    # LOUD, not silent: the deploy continues (a stale-but-present agent file
    # from a prior deploy is a fine fallback, and refusing the whole deploy
    # over a third-party fetch would hold the rest of the UI hostage to IBM's
    # uptime), but this line must be impossible to miss in the deploy log.
    msg "WARNING: failed to fetch the Instana EUM agent — /vendor/instana-eum.min.js was NOT updated." >&2
    msg "         Instana EUM will be broken (404) until this is retried: '$0 all' or rerun deploy." >&2
  fi
  # THE BEACON PROXY'S ONE UPSTREAM — the other half of the same artifact: the
  # bundle posts to our own /eum and scripts/serve/eum_proxy.py forwards here.
  # A file, not a unit Environment= line: the unit is committed to a PUBLIC
  # repo and the tenant URL is not. Read once per process — changing it needs a
  # restart. docs/ANALYTICS.md §8.3.
  local up="$SERVE_DIR/instana-eum-upstream.txt"
  if [ -n "${INSTANA_EUM_REPORTING_URL:-}" ] &&
    printf '%s\n' "$INSTANA_EUM_REPORTING_URL" | $SSH "cat > $up && chmod 600 $up"; then
    msg "published the EUM beacon proxy upstream"
  else
    msg "WARNING: no EUM beacon-proxy upstream — POST /eum will 404, beacons dropped." >&2
  fi
}

# Upload this build's JS source maps to Instana, so its stack-trace
# translation (docs/lab/… — see the offline Instana docs' "JavaScript stack
# trace translation" section) can turn a beacon's minified frame back into a
# real file/line. Runs from THIS machine (no $SSH — dist/ already exists
# locally after build()); never touches the box.
#
# WHY UPLOAD AS WELL AS SERVE THE MAP PUBLICLY: since vite.config.ts's
# `sourcemap: true` and deploy()'s dropped --exclude, the map IS now public —
# `sourceMappingURL` points at it and a browser can fetch it (only the app
# shell at '/' is passkey-gated; `/assets/*` is unauthenticated — see
# docs/PUBLIC-GALLERY.md). That serves a human with devtools open, which is
# the case this upload does NOT cover: Instana's own automatic retrieval
# (GET the JS, read `sourceMappingURL`, GET the map) depends on its crawler
# actually reaching us and on timing relative to the next deploy, and IBM's
# own docs describe upload as the reliable path for a private website even
# when the asset itself is reachable ("Automatic JavaScript source maps
# retrieval does not work for customers who monitor private websites...
# Instana provides a way to upload... source-mapping files for private
# websites"). So this pushes the map straight to Instana's private
# per-website store, deterministically, on every deploy — a second delivery
# path for a second consumer, not a duplicate of the public one above.
#
# THE PAIRING KEY IS THE JS FILE'S URL, NOT A VERSION. Instana's Web REST API
# associates one uploaded map with the exact URL a stack-trace frame will
# name (`-F 'url=...'`), not with any release/version string — there is no
# separate "release" identifier in this mechanism. Vite's content hash in
# each asset's filename (index-<hash>.js) already makes that URL unique per
# build, which is exactly the property this pairing needs.
#
# CREDENTIALS: the PERSONAL API TOKEN (INSTANA_API_TOKEN_FILE), never the
# agent key — this is a Web REST (config) call, not ingest. Read from the
# gitignored file path only; never printed, never baked into any built file.
#
# INSTANA_SOURCEMAP_UPLOAD_CONFIG_ID names an Instana "File Upload
# Configuration" — a per-website bucket the source maps upload API needs. IBM's
# docs only ever show it created BY HAND in the UI (website's Configuration
# tab -> JS Stack Trace Translation -> File Download Configurations -> Add
# Configuration); this file's own comment right above INSTANA_WEBSITE_KEY
# already used the equivalent config REST endpoint once (creating the website
# itself), and the same POST shape works to create this too — see
# registry/local.env.example for the one-time command.
publish_instana_sourcemaps() {
  if [ -z "${INSTANA_API_BASE:-}" ] || [ -z "${INSTANA_WEBSITE_KEY:-}" ] ||
    [ -z "${INSTANA_SOURCEMAP_UPLOAD_CONFIG_ID:-}" ] || [ -z "${INSTANA_API_TOKEN_FILE:-}" ]; then
    msg "Instana source-map upload not fully configured (need INSTANA_API_BASE, INSTANA_WEBSITE_KEY,"
    msg "INSTANA_SOURCEMAP_UPLOAD_CONFIG_ID, INSTANA_API_TOKEN_FILE) — skipping upload, maps stay unpublished only"
    return 0
  fi
  local token_file="$REPO/$INSTANA_API_TOKEN_FILE"
  [ -f "$token_file" ] || {
    msg "WARNING: INSTANA_API_TOKEN_FILE=$INSTANA_API_TOKEN_FILE not found — skipping source-map upload" >&2
    return 0
  }
  [ -z "${SH_GALLERY_HOST:-}" ] && {
    msg "WARNING: SH_GALLERY_HOST unset — cannot form the public asset URLs maps must be keyed to; skipping upload" >&2
    return 0
  }
  local token maps_found=0 failed=0
  token="$(cat "$token_file")"
  for map in "$DIST"/assets/*.js.map; do
    [ -f "$map" ] || continue
    maps_found=$((maps_found + 1))
    local js_name js_url resp http_code
    js_name="$(basename "$map" .map)"
    js_url="https://$SH_GALLERY_HOST/assets/$js_name"
    resp="$(curl -sS -L -X PUT \
      -o /dev/null -w '%{http_code}' \
      "$INSTANA_API_BASE/api/website-monitoring/config/$INSTANA_WEBSITE_KEY/sourcemap-upload/$INSTANA_SOURCEMAP_UPLOAD_CONFIG_ID/form" \
      -H "authorization: apiToken $token" \
      -F "url=$js_url" \
      -F "sourceMap=@$map" || echo '000')"
    http_code="$resp"
    if [ "$http_code" = "200" ]; then
      msg "uploaded source map for $js_url"
    else
      failed=$((failed + 1))
      msg "WARNING: source-map upload for $js_url failed (HTTP $http_code)" >&2
    fi
  done
  if [ "$maps_found" = 0 ]; then
    msg "WARNING: no .map files in $DIST/assets — was the build made with sourcemaps enabled (vite.config.ts)?" >&2
  elif [ "$failed" -gt 0 ]; then
    # LOUD, not silent, same standard as publish_instana_agent: the deploy
    # continues (Instana keeps translating against the PREVIOUS build's maps,
    # a fine fallback — stale-but-present beats none), but this must be
    # impossible to miss.
    msg "WARNING: $failed of $maps_found source-map upload(s) failed — Instana stack traces for this build may show minified frames." >&2
  fi
}

# Republish the boot-replay assets (/boot/<id>/boot.mp4 … + /boot/index.json).
# They are baked ON labhost (scripts/coldboot/, staging /data/vms/streamhost/
# boot-rec/) and never enter git or the Vite bundle, so nothing off-box can
# restore them — and a wholesale webroot swap once dropped the whole tree,
# leaving every boot-video station 404ing for a week. gen-boot-manifest.sh is an
# idempotent rsync + index merge, so running it on every deploy costs nothing
# and makes the published tree a function of the staging dir again. No staging
# on this box (fresh install) is not an error; a failing publish is.
publish_boot() {
  msg "republishing boot-replay assets from the box staging -> $WEBROOT/boot/"
  $SSH "set -e; \
    staging=/data/vms/streamhost/boot-rec; gen=$BOX_REPO/scripts/coldboot/gen-boot-manifest.sh; \
    ls \"\$staging\"/*/boot.json >/dev/null 2>&1 || { echo '[serve-https] no staged boot recordings on this box; boot/ left as is'; exit 0; }; \
    test -x \"\$gen\" || { echo \"[serve-https] ERROR: \$gen missing — sync the box checkout (scripts/dev/box-repo.sh)\" >&2; exit 1; }; \
    WEBROOT=$WEBROOT \"\$gen\""
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
  for src in "$TILES_SRC" "$GALLERY_MANIFEST_SRC" "$POSTER_DOCS_SRC" "$GOLDEN_MANIFEST_SRC" "$FLEET_TABLE_SRC"; do
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
  # The /fleet table (tier, emulator, kiosk, I/O paths per station) is rendered
  # from the same registry; publish it beside the gallery manifest.
  $SSH "set -e; tmp=$WEBROOT/fleet-table.json.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $WEBROOT/fleet-table.json" <"$FLEET_TABLE_SRC"
  # reset-tile.sh reads this to find each station's resetMode, so a station missing
  # here has a dead "Restore to golden" button. It went stale for irix and the
  # box copy simply had no entry, which reads as `unknown osId` at reset time.
  $SSH "set -e; tmp=$SERVE_DIR/golden-manifest.json.tmp; cat > \"\$tmp\"; mv \"\$tmp\" $SERVE_DIR/golden-manifest.json" <"$GOLDEN_MANIFEST_SRC"
  msg "published tiles.json + webroot/gallery-manifest.json + webroot/poster-docs.json + webroot/fleet-table.json + golden-manifest.json"
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
  manifests)
    publish_manifests
    publish_boot
    ;;
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
