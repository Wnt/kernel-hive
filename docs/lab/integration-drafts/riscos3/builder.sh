#!/bin/bash
# DRAFT ONLY: copy/adapt after normal scaffolding.
set -euo pipefail
OS_ID=riscos3
OUT="${OUT:-/data/vms/build-riscos3}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/riscos3}"
ROM_SOURCE="${ROM_SOURCE:-}"
MAME_BIN="${MAME_BIN:-mame}"
log(){ printf '[draft:%s] %s\n' "$OS_ID" "$*" >&2; }
die(){ log "ERROR: $*"; exit 1; }
mkdir -p "$OUT/roms" "$ASSETS/roms"
[ -n "$ROM_SOURCE" ] || die "set ROM_SOURCE to acquired RISC OS 3.11/A310 ROM archive"
case "$ROM_SOURCE" in
  http://*|https://*) curl -fL --retry 3 -o "$OUT/source-roms" "$ROM_SOURCE" ;;
  *) cp -f "$ROM_SOURCE" "$OUT/source-roms" ;;
esac
"$MAME_BIN" aa310 -listxml >"$OUT/aa310.xml"
"$MAME_BIN" aa310 -listbios >"$OUT/aa310.bios.txt" || true
cat >&2 <<'EOF'
NEXT:
  unpack source-roms to satisfy the pinned MAME aa310 listxml exactly;
  stage the resulting ROM zip(s) under assets/riscos3/roms;
  smoke: mame aa310 -bios 311 -rompath <romdir> -skip_gameinfo;
  only race aa5000 if the intended apps require ARM3/HDD.
EOF
