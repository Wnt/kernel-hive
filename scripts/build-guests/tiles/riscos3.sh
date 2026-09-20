#!/bin/bash
# =============================================================================
# build-guests/tiles/riscos3.sh — stage the riscos3 station's ROM set.
#
# RISC OS 3.11 is ROM-RESIDENT: there is no installer, no disk image and no
# media to compose. The whole exhibit is the Acorn Archimedes 310 machine
# romset (which carries every BIOS revision from Arthur 0.30 to RISC OS 3.11
# as selectable `-bios` options) plus the shared Archimedes keyboard MCU
# romset — the 8051 that scans the key matrix and counts the mouse's
# quadrature. So this builder only fetches, hash-verifies and stages; the
# same shape as dragon32.sh / zx81.sh, not a disk composer.
#
# HOST-NATIVE: no chroot, no bridge base, no QEMU. The emulator plane is
# scripts/build-guests/emulators/build-mame-native.sh riscos3 (a separate
# step, not run by this script), whose stanza native.d/riscos3.sh stages the
# rompath OUT of this staging directory and hash-gates every member against
# the pinned binary's own -listroms.
#
# ONE TRAP WORTH THE LINE: /data/assets-staging is NOT the same filesystem
# inside CT950 as it is on labhost. Staging has to happen ON THE BOX, which
# is where this script is meant to run — a copy made in the container is
# invisible to the build (measured 2026-09-20: the first native build failed
# with FileNotFoundError on exactly this path).
#
# Usage: riscos3.sh [--force]
# =============================================================================
set -euo pipefail

TILE=riscos3
STAGING=/data/assets-staging/$TILE
BASE="https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29"

# The pinned mame0289 aa310 driver takes the same romset members MAME 0.264
# shipped; every member is re-verified by the native build's own gate, so
# these two hashes gate the DOWNLOAD, not the ROM contents.
MACHINE_ZIP="$STAGING/aa310.zip"
MACHINE_URL="$BASE/aa310.zip"
MACHINE_SHA256=04d17d96963816721219691857af17e6439ae30088ebf2e89fac9d8b12d7194b

KBD_ZIP="$STAGING/archimedes_keyboard.zip"
KBD_URL="$BASE/archimedes_keyboard.zip"
KBD_SHA256=1d02b14cd4d2ff80a343c3afb1ba43de0bd77815952816fc19d0736f8644664e

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

say() { printf '\n== [%s] %s\n' "$TILE" "$*"; }
die() {
  echo "[$TILE] ERROR: $*" >&2
  exit 1
}

fetch() { # fetch <dest> <url> <sha256>
  local dest="$1" url="$2" want="$3" tmp
  if [ "$FORCE" = 0 ] && [ -f "$dest" ] &&
    [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
    echo "  have $(basename "$dest") (hash ok)"
    return 0
  fi
  tmp="$dest.part.$$"
  say "fetching $(basename "$dest")"
  curl -fsSL --retry 3 -o "$tmp" "$url" || {
    rm -f "$tmp"
    die "download failed: $url"
  }
  local got
  got="$(sha256sum "$tmp" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || {
    rm -f "$tmp"
    die "$(basename "$dest") sha256 $got != $want"
  }
  # atomic: a half-written romset must never be visible to a concurrent build
  mv -f "$tmp" "$dest"
}

mkdir -p "$STAGING"
fetch "$MACHINE_ZIP" "$MACHINE_URL" "$MACHINE_SHA256"
fetch "$KBD_ZIP" "$KBD_URL" "$KBD_SHA256"

# native.d/riscos3.sh's native_stage_roms reads LOOSE members out of this
# directory (stage-romset.py), so unpack beside the archives. -o is safe:
# every member was just hash-gated through the zip it came from.
say "unpacking members"
unzip -oq "$MACHINE_ZIP" -d "$STAGING"
unzip -oq "$KBD_ZIP" -d "$STAGING"

(cd "$STAGING" && sha256sum ./*.zip >MANIFEST.sha256)
(cd "$STAGING" && sha256sum ./*.rom ./*.bin >MANIFEST-members.sha256)

n_members="$(find "$STAGING" -maxdepth 1 \( -name '*.rom' -o -name '*.bin' \) | wc -l)"
say "staged $n_members ROM member(s) under $STAGING"
echo "  next: scripts/build-guests/emulators/build-mame-native.sh riscos3"
