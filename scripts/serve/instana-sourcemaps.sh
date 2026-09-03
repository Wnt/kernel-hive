#!/usr/bin/env bash
# instana-sourcemaps.sh — publish_instana_sourcemaps(), split out of
# scripts/serve-https-spa.sh.
#
# Not a reorganisation for its own sake: serve-https-spa.sh stood at EXACTLY its
# 600-line hard cap, so the next line anyone needed to add to the deploy path
# could not be added at all. This function is the largest self-contained block
# in it and the one with no callers but deploy(), which makes it the cheapest
# thing to move — the same reasoning that split box-sync-pairs-retronet.sh out
# on 2026-09-03, one wave later.
#
# Sourced, never executed: it uses serve-https-spa.sh's $REPO, $DIST, $msg and
# the Instana variables local-env.sh exports.

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
