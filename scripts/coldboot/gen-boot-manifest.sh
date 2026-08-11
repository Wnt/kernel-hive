#!/bin/bash
# gen-boot-manifest.sh — P2b: publish. RUN ON labhost.
#   1. rsync each staged station's assets  /data/vms/streamhost/boot-rec/<id>/{boot.mp4,
#      poster.jpg,sprite.jpg,thumbs.vtt}  ->  $WEBROOT/boot/<id>/   (large binaries stay
#      OUT of git / the vite bundle; §2.8).
#   2. aggregate every staged boot.json -> $WEBROOT/boot/index.json (schema §4), keyed
#      by osId, with the served /boot/<id>/... URL paths.
#
#   Usage: WEBROOT=/path/to/spa-webroot gen-boot-manifest.sh [station...]
#          (no stations -> every staging dir that has a boot.json)
#
# NOTE (server, spec §2.9 — one-time, OUTSIDE this tooling): osgallery-https-server.py
# must serve .mp4/.vtt with correct MIME and add /boot/ as a reserved prefix, else
# <video>/<track> break and a missing asset returns index.html instead of 404.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bootrec-lib.sh disable=SC1091
source "${BOOTREC_LIB:-$HERE/bootrec-lib.sh}"

: "${WEBROOT:?WEBROOT must point at the served SPA webroot (same var the https server uses)}"
BOOT_WEBROOT="$WEBROOT/boot"
INDEX="$BOOT_WEBROOT/index.json"
mkdir -p "$BOOT_WEBROOT"

# collect the station list
TILES=("$@")
if [ "${#TILES[@]}" -eq 0 ]; then
  for d in "$BOOTREC_STAGING_ROOT"/*/; do
    [ -f "${d}boot.json" ] && TILES+=("$(basename "$d")")
  done
fi
[ "${#TILES[@]}" -gt 0 ] || br_die "no staged tiles (need $BOOTREC_STAGING_ROOT/<id>/boot.json)"

for t in "${TILES[@]}"; do
  src="$BOOTREC_STAGING_ROOT/$t"
  [ -f "$src/boot.json" ] || {
    br_warn "skip '$t' (no boot.json)"
    continue
  }
  br_log "rsync $t -> $BOOT_WEBROOT/$t/"
  mkdir -p "$BOOT_WEBROOT/$t"
  rsync -a --delete-excluded \
    --include='boot.mp4' --include='poster.jpg' --include='sprite.jpg' \
    --include='thumbs.vtt' --exclude='*' \
    "$src/" "$BOOT_WEBROOT/$t/"
done

# build index.json from the staged boot.json files, rewriting paths to /boot/<id>/...
python3 - "$INDEX" "$BOOTREC_STAGING_ROOT" "${TILES[@]}" <<'PY'
import json, os, sys
index, staging = sys.argv[1], sys.argv[2]
tiles = sys.argv[3:]
out = {}
# merge with any existing index so partial re-publishes don't drop other stations.
if os.path.exists(index):
    try: out = json.load(open(index))
    except Exception: out = {}
for t in tiles:
    p = os.path.join(staging, t, "boot.json")
    if not os.path.exists(p):
        continue
    d = json.load(open(p))
    base = f"/boot/{t}"
    out[t] = {
        "mp4":    f"{base}/boot.mp4",
        "poster": f"{base}/poster.jpg",
        "sprite": f"{base}/sprite.jpg",
        "vtt":    f"{base}/thumbs.vtt",
        "durationMs": d.get("durationMs"),
        "width":  d.get("width"), "height": d.get("height"),
        "hasAudio": d.get("hasAudio", False),
        "bakedAt": d.get("bakedAt"), "goldenSha": d.get("goldenSha"),
        "detect": d.get("detect", {}),
    }
json.dump(out, open(index, "w"), indent=2)
print(index, "->", len(out), "tiles")
PY

br_log "PUBLISHED: $INDEX"
