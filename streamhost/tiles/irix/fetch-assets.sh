#!/bin/bash
# fetch-assets.sh — stage the large IRIX/MAME binaries the irix tile needs at
# runtime (issue #20). These are NOT committed to the repo (a 2 GiB CHD, the SGI
# PROM roms and the patched MAME sgi binary); this script
# documents + stages them, like the other bridge tiles' golden builders.
#
# Run ON the box (root@192.0.2.10). Idempotent. The runtime (x11-runtime.sh)
# reads these via IRIX_ASSETS / IRIX_MAME (defaults below).
#
# No private glibc bundle is staged any more: the sgi binary needs at most
# GLIBC_2.38 / GLIBCXX_3.4.32 and the trixie host provides 2.41 / 3.4.33, so it
# is exec'd directly (the bundle only ever existed for a bookworm rootfs).
set -euo pipefail

ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
MAME_BIN="${IRIX_MAME:-/data/vms/streamhost/assets/irix/mame/sgi}"

echo "== irix tile asset check =="
fail=0
check() { # $1 = path, $2 = description
  if [ -e "$1" ]; then
    echo "  OK   $2: $1"
  else
    echo "  MISS $2: $1" >&2
    fail=1
  fi
}

check "$MAME_BIN" "MAME sgi binary (0.288+, skip_warnings + 256MB-RAM patches)"
check "$ASSETS/irix65-apps.chd" "IRIX 6.5 exhibit CHD (444 + immutable; md5 09e51dbc)"
check "$ASSETS/irix65.chd" "IRIX 6.5 base CHD (444 + immutable; md5 430bf0ba)"
check "$ASSETS/roms/indy_4610" "SGI Indy PROM roms (bios b10)"
check "$ASSETS/nvram/indy_4610" "PROM nvram (eaddr + monitor=h baked)"
check "$ASSETS/uicfg/ui.ini" "ui.ini (skip_warnings 1)"
check "$ASSETS/irixagent.lua" "Lua input agent (asset-stage copy for clone rigs)"

# Guarantee the golden CHD can never be corrupted by a read-write MAME run.
# chmod 444 is NOT enough: MAME runs as root and root ignores the mode bits, so
# it opens the CHD O_RDWR, skips the -diff_directory overlay entirely and
# mutates the golden in place. `chattr +i` is the only root-proof lock (works on
# this ZFS). With it, MAME falls back to read-only and writes the diff.
for chd in "$ASSETS/irix65-apps.chd" "$ASSETS/irix65.chd"; do
  [ -f "$chd" ] || continue
  chmod 444 "$chd" 2>/dev/null || true
  chattr +i "$chd"
  echo "  locked $chd read-only (444 + immutable)"
  lsattr "$chd"
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF

Some assets are missing. Rebuild recipe (see docs/history/irix-tile-issue20-handoff.md
and /data/vms/soltest/irix-mame/RECIPE.txt):
  * Media from archive.org item 'irix65.7z' (bundles indy_4610.7z PROM + CHD):
      7z e -y irix65.7z && chmod 444 irix65.chd
  * MAME 0.288+ built with scripts/build-guests/mame-irix-skip-warnings.patch
    AND scripts/build-guests/mame-indy-256mb-ram.patch (256 MB, not 16 MB).
    Verify offline: sgi -listxml indy_4610 | grep -A9 'RAM bank A' -> 4x32M
    must carry default="yes" (same for bank B).
EOF
  exit 1
fi
echo "== all irix tile assets present =="
