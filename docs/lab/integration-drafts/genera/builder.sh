#!/bin/bash
# DRAFT ONLY: stage OG2VLM kit + Open Genera world inputs.
set -euo pipefail
WORK="${WORK:-/data/vms/build-genera}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/genera}"
OG2VLM_REPO="${OG2VLM_REPO:-https://github.com/JMlisp/og2vlm.git}"
OG2VLM_REF="${OG2VLM_REF:-master}"
OPENGENERA_ARCHIVE="${OPENGENERA_ARCHIVE:-}"
mkdir -p "$WORK" "$ASSETS"
[ -n "$OPENGENERA_ARCHIVE" ] || { echo "set OPENGENERA_ARCHIVE to acquired opengenera2/VLM kit archive" >&2; exit 2; }
git clone "$OG2VLM_REPO" "$WORK/og2vlm"
( cd "$WORK/og2vlm"; git checkout "$OG2VLM_REF"; git rev-parse HEAD ) | tee "$WORK/og2vlm.commit"
cp -f "$OPENGENERA_ARCHIVE" "$WORK/opengenera.archive"
sha256sum "$WORK/opengenera.archive" | tee "$WORK/MANIFEST.sha256"
cat >&2 <<'EOF'
LAB STEP:
  follow the pinned og2vlm setup once in a disposable Debian/nspawn root;
  stage the working genera binary, dot.VLM, Genera-8-5e world/vlod, fonts and any FEP/LMFS disks under assets/genera;
  make every path in dot.VLM station-local;
  then prove a local X display before adding networking.
EOF
