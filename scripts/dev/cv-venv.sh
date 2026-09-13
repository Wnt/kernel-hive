#!/usr/bin/env bash
# cv-venv.sh — the ONE OpenCV venv for this host, on the shared durable mount.
#
# OpenCV must never land in labhost's or CT950's system python (AGENTS.md
# rule: no apt/pip into a system python). labhost and CT950 run different
# python versions, so this is one venv PER HOST, keyed by hostname, living
# under /data/vms/tools/cv-venv — /data/vms is shared and durable, unlike a
# sandbox under /data/vms/sandbox/<slot>, which `wt.sh rm` deletes. A tool
# that needs cv2 (scripts/dev/cursor-locate-cv.py) execs into this venv's
# python at the same path rule, so this script only needs to run once per
# host, ever, not once per sandbox.
#
# Usage:
#   cv-venv.sh          create (if missing) and report the venv's python path
#   cv-venv.sh --check  import cv2 in that venv and print its version
set -euo pipefail

VENV_ROOT="/data/vms/tools/cv-venv"
VENV="$VENV_ROOT/$(hostname)"
PY="$VENV/bin/python3"

# Versions verified working together on both labhost (python 3.13) and
# CT950 (python 3.12) as of 2026-09-13.
OPENCV_VERSION="4.10.0.84"
NUMPY_VERSION="2.1.3"
PILLOW_VERSION="11.0.0"

if [[ "${1:-}" == "--check" ]]; then
  if [[ ! -x "$PY" ]]; then
    echo "no venv at $VENV — run cv-venv.sh first" >&2
    exit 1
  fi
  "$PY" -c 'import cv2; print(f"cv2 {cv2.__version__} at {cv2.__file__}")'
  exit 0
fi

mkdir -p "$VENV_ROOT"

if [[ ! -x "$PY" ]]; then
  python3 -m venv "$VENV"
fi

"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet \
  "opencv-python-headless==${OPENCV_VERSION}" \
  "numpy==${NUMPY_VERSION}" \
  "pillow==${PILLOW_VERSION}"

echo "$PY"
