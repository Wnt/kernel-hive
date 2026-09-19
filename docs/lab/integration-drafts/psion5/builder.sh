#!/bin/bash
# DRAFT ONLY: stage Psion Series 5mx ROM and prepare the MAME-vs-WindEmu race.
set -euo pipefail
WORK="${WORK:-/data/vms/build-psion5}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/psion5}"
PSION_ROM="${PSION_ROM:-}"
MAME_BIN="${MAME_BIN:-mame}"
mkdir -p "$WORK" "$ASSETS/roms"
[ -n "$PSION_ROM" ] || { echo "set PSION_ROM to acquired Series 5mx ROM" >&2; exit 2; }
cp -f "$PSION_ROM" "$WORK/psion5mx.rom"
sha256sum "$WORK/psion5mx.rom" | tee "$WORK/MANIFEST.sha256"
"$MAME_BIN" psion5mx -listxml >"$WORK/psion5mx.xml" 2>/dev/null || true
cat >&2 <<'EOF'
RACE ORDER:
  1. Repackage the ROM exactly as pinned MAME psion5mx -listxml requires and smoke MAME.
  2. If MAME stays blank/preliminary, stop and build WindEmu from https://github.com/Treeki/WindEmu.
Do not patch MAME before the WindEmu smoke exists.
EOF
