#!/bin/bash
# DRAFT ONLY: stage Kaypro II ROM + CP/M 2.2/WordStar disks.
set -euo pipefail
WORK="${WORK:-/data/vms/build-cpm22}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/cpm22}"
ROM_SOURCE="${ROM_SOURCE:-}"
SYSTEM_DISK="${SYSTEM_DISK:-}"
WORDSTAR_DISK="${WORDSTAR_DISK:-}"
MAME_BIN="${MAME_BIN:-mame}"
mkdir -p "$WORK" "$ASSETS/roms" "$ASSETS/disks"
[ -n "$ROM_SOURCE" ] && cp -f "$ROM_SOURCE" "$WORK/rom.source" || true
[ -n "$SYSTEM_DISK" ] || {
  echo "set SYSTEM_DISK to bootable Kaypro CP/M 2.2 image" >&2
  exit 2
}
cp -f "$SYSTEM_DISK" "$ASSETS/disks/system.img"
[ -n "$WORDSTAR_DISK" ] && cp -f "$WORDSTAR_DISK" "$ASSETS/disks/wordstar.img"
"$MAME_BIN" kaypro2 -listxml >"$WORK/kaypro2.xml"
"$MAME_BIN" kaypro2 -listmedia >"$WORK/kaypro2.media.txt" || true
sha256sum "$ASSETS/disks/"* >"$ASSETS/disks/MANIFEST.sha256"
cat >&2 <<'EOF'
WORKER:
  satisfy pinned MAME kaypro2 ROM list exactly;
  convert TD0/Teledisk sources only if the pinned MAME cannot attach them;
  smoke system disk first, then add WordStar as a second drive only if useful.
EOF
