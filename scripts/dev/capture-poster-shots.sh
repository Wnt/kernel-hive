#!/usr/bin/env bash
# Capture live exhibit framebuffers into the poster asset tree.
# Whatever the station is showing is the poster. No staging, no reset-to-golden
# first — the live framebuffer is the image.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)

if (($# == 0)); then
  echo "usage: $0 <tile-id> [tile-id ...]" >&2
  exit 2
fi

for os_id in "$@"; do
  if [[ ! "$os_id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid tile id: $os_id" >&2
    exit 2
  fi

  registry_file="$repo_root/registry/tiles/$os_id.json"
  if [[ ! -f "$registry_file" ]]; then
    echo "no registry tile: $os_id" >&2
    exit 2
  fi

  destination="$repo_root/spa/public/posters/$os_id"
  mkdir -p "$destination"
  work_dir=$(mktemp -d "/tmp/osgallery-poster.${os_id}.XXXXXX")
  source_png="$work_dir/source.png"
  source_art=""

  case "$os_id" in
    macos)
      # Showcase posters have no station to screendump, so they stand in with
      # generated art. win11 used to be here; it streams now and takes the
      # normal live-framebuffer path below.
      source_art="$repo_root/spa/public/assets/generated/hero-backplate.webp"
      ;;
    riscos)
      source_art="$repo_root/spa/public/assets/generated/era-90s.jpg"
      ;;
    *)
      tile_dir=$(
        python3 - "$registry_file" <<'PY'
import json
import sys

row = json.load(open(sys.argv[1]))
print(row.get("tileDir", row["id"]))
PY
      )
      remote_png="/tmp/osgallery-poster-${os_id}.png"
      echo "capturing $os_id from lab tile $tile_dir"
      ssh lab bash -s -- "$tile_dir" "$remote_png" <<'REMOTE'
labctl shot "$1" "$2"
REMOTE
      scp -q "lab:$remote_png" "$source_png"
      source_art="$source_png"
      ;;
  esac

  if [[ ! -s "$source_art" ]]; then
    echo "capture source is missing or empty: $source_art" >&2
    exit 1
  fi

  convert "$source_art" \
    -auto-orient -resize '1280x1280>' -strip \
    -define webp:method=6 -quality 82 \
    "$destination/desktop.webp"
  identify "$destination/desktop.webp"
  rm -f -- "$source_png"
  rmdir "$work_dir"
done
