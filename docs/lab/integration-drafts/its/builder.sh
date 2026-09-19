#!/bin/bash
# DRAFT ONLY: build ITS from the maintained source tree with SIMH.
set -euo pipefail
WORK="${WORK:-/data/vms/build-its}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/its}"
ITS_REPO="${ITS_REPO:-https://github.com/PDP-10/its.git}"
ITS_REF="${ITS_REF:-master}"
mkdir -p "$WORK" "$ASSETS"
git clone --recursive "$ITS_REPO" "$WORK/its"
( cd "$WORK/its"; git checkout "$ITS_REF"; git submodule update --init --recursive; git rev-parse HEAD ) | tee "$WORK/its.commit"
( cd "$WORK/its"; make EMULATOR=simh )
rm -rf "$ASSETS/tree"
cp -a "$WORK/its" "$ASSETS/tree"
find "$ASSETS/tree/out" -type f -print0 | sort -z | xargs -0 sha256sum >"$ASSETS/out.MANIFEST.sha256"
cat >&2 <<'EOF'
LAB STEP:
  run ./start once and measure the exact unattended boot dialogue for SIMH;
  turn that measured sequence into assets/its/start-auto (expect or equivalent);
  prove the separate user terminal on TCP 10004; production runtime never exposes the simulator console.
EOF
