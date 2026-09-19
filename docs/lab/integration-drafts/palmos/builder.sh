#!/bin/bash
# DRAFT ONLY: Palm OS ROM staging + MAME smoke race.
set -euo pipefail
OUT="${OUT:-/data/vms/build-palmos}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/palmos}"
PALM_ROM="${PALM_ROM:-}"
MAME_BIN="${MAME_BIN:-mame}"
mkdir -p "$OUT" "$ASSETS/roms"
[ -n "$PALM_ROM" ] || { echo "set PALM_ROM to acquired Palm III/m505 ROM" >&2; exit 2; }
cp -f "$PALM_ROM" "$OUT/rom.bin"
sha256sum "$OUT/rom.bin" | tee "$OUT/MANIFEST.sha256"
for drv in palmiii palmm505; do "$MAME_BIN" "$drv" -listxml >"$OUT/$drv.xml" 2>/dev/null || true; done
cat >&2 <<'EOF'
RACE palmiii first, palmm505 second.
Repackage rom.bin to the exact member name/hash required by the pinned MAME listxml.
Smoke until Launcher + pen input work.
If pen/display is the wall, pivot to CloudpilotEmu before patching MAME.
EOF
