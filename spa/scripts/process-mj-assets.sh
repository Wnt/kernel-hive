#!/usr/bin/env bash
# Reproducible bitmap pipeline: raw Midjourney variants -> poster art + icons.
# Reads  $MJ_OUTPUT_DIR (default spa/mj-output/<slot>/, gitignored — the raw MJ
# masters live outside the repo) and writes  spa/public/assets/generated/.
#
# Tooling: Python 3 + Pillow + numpy (installed into a local venv on first run).
# Edit the SLOTS map in process_mj_assets.py to re-select a variant, then re-run.
set -euo pipefail
cd "$(dirname "$0")/.." # -> spa/

VENV=".venv-assets"
if [ ! -x "$VENV/bin/python" ]; then
  echo "[process-mj-assets] creating venv + installing Pillow, numpy..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check Pillow numpy
fi

exec "$VENV/bin/python" scripts/process_mj_assets.py "$@"
