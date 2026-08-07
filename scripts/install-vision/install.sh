#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VENV=${VISION_VENV:-"$HERE/.venv"}

command -v python3 >/dev/null || {
  echo "python3 is required" >&2
  exit 1
}
command -v tesseract >/dev/null || {
  echo "tesseract is required (Debian/Ubuntu: apt-get install -y tesseract-ocr)" >&2
  exit 1
}
python3 -m venv "$VENV"
"$VENV/bin/pip" install --disable-pip-version-check -r "$HERE/requirements.txt"
echo "$VENV/bin/python"
