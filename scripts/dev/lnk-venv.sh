#!/usr/bin/env bash
# lnk-venv.sh — the ONE pylnk3 venv for this host, on the shared durable mount.
#
# Minting a Windows .lnk offline needs pylnk3, which must never land in
# labhost's or CT950's system python (AGENTS.md rule: no apt/pip into a system
# python). Same shape as cv-venv.sh: one venv PER HOST, keyed by hostname,
# under /data/vms/tools/lnk-venv — durable, unlike a sandbox under
# /data/vms/sandbox/<slot> that `wt.sh rm` deletes.
#
# Usage:
#   lnk-venv.sh          create (if missing) and report the venv's python path
#   lnk-venv.sh --check  import pylnk3 in that venv and print its version
set -euo pipefail

VENV_ROOT="/data/vms/tools/lnk-venv"
VENV="$VENV_ROOT/$(hostname)"
PY="$VENV/bin/python3"

PYLNK3_VERSION="0.4.2"

if [[ "${1:-}" == "--check" ]]; then
  [[ -x "$PY" ]] || {
    echo "no venv at $VENV — run lnk-venv.sh first" >&2
    exit 1
  }
  "$PY" -c 'import pylnk3; print(f"pylnk3 at {pylnk3.__file__}")'
  exit 0
fi

mkdir -p "$VENV_ROOT"
[[ -x "$PY" ]] || python3 -m venv "$VENV"
"$PY" -m pip install --quiet --upgrade pip
"$PY" -m pip install --quiet "pylnk3==${PYLNK3_VERSION}"
echo "$PY"
