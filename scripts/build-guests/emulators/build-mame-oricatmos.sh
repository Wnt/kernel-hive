#!/bin/bash
# =============================================================================
# build-guests/build-mame-oricatmos.sh — build the MAME binary the Oric Atmos
# tile ships, from a pinned upstream RELEASE commit, inside the Bookworm chroot.
#
# WHY A BUILD AND NOT A PACKAGE. The tile's emulator runs inside the Debian 12
# bridge guest, so the binary must be Bookworm-ABI. The two packaged options are
# both wrong for different reasons:
#   * the LAB HOST's `/usr/games/mame` is Debian *trixie* 0.276 — newer, but
#     linked against a glibc the Bookworm guest does not have;
#   * Bookworm's own `mame` is 0.251 (2022), and `bookworm-backports` has no
#     mame at all (checked 2026-08-09).
# So the tile does what mpf2 does: build in the Bookworm chroot that the IRIX
# and MPF-II MAME builds already use, from the latest STABLE tag — `mame0289`,
# commit f34f0250 — which is also the exact commit the mpf2 tile ships.
#
# NO PATCH IS APPLIED HERE, deliberately. mpf2 needs one because its driver is
# marked `preliminary` and MAME paints a full-screen red "THIS SYSTEM DOESN'T
# WORK" panel that `-skip_gameinfo` does not suppress. `orica` is
# `<driver status="good" emulation="good" savestate="supported"/>` in the very
# `-listxml` this build produces, so there is no nag to suppress and no reason
# to ship a modified emulator. Verified by frame, not by that attribute alone.
#
# Only `src/mame/tangerine/oric.cpp` is built into the driver list (SUBTARGET),
# which keeps the binary at ~70 MB instead of ~430 MB and keeps the guest's
# rompath free of every other machine MAME knows.
#
# Usage: build-mame-oricatmos.sh [work-dir] [output-binary]
# =============================================================================
set -euo pipefail

CHROOT="${MAME_BOOKWORM_CHROOT:-/data/vms/soltest/bookworm-chroot}"
CHROOT_WORK="/build/mame-oricatmos"
WORK="${1:-$CHROOT$CHROOT_WORK}"
OUT="${2:-/data/vms/streamhost/assets/oricatmos/mame/oricatmos}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(($(nproc) > 12 ? 10 : 4))}"
# MAME 0.289 (tag mame0289) — the latest stable release at build time.
MAME_ORIC_BASE=f34f02505e32c1993c6a782b6814232cbfc74e36

say() { printf '\n== %s\n' "$*"; }

[ -d "$CHROOT" ] || {
  echo "missing Bookworm MAME build chroot: $CHROOT" >&2
  exit 1
}
[ "${WORK#"$CHROOT"}" != "$WORK" ] || {
  echo "work directory must be inside chroot: $CHROOT" >&2
  exit 1
}
CHROOT_WORK="${WORK#"$CHROOT"}"
[ -n "$CHROOT_WORK" ] && [ "${CHROOT_WORK#/}" != "$CHROOT_WORK" ] || {
  echo "invalid chroot work directory: $WORK" >&2
  exit 1
}

mkdir -p "$WORK"

say "building MAME 0.289 (oric.cpp subtarget) in Bookworm with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- "$CHROOT_WORK" "$UPSTREAM" "$MAME_ORIC_BASE" "$JOBS" <<'EOS'
set -euo pipefail
work="$1"
upstream="$2"
base="$3"
jobs="$4"
cd "$work"
if [ ! -d mame/.git ]; then
  git clone --filter=blob:none "$upstream" mame
fi
cd mame
git remote set-url origin "$upstream"
git fetch -q --depth=1 origin "$base"
git reset -q --hard "$base"
git clean -qfd
# NOWERROR: the pinned release does not build warning-clean under Bookworm's
# GCC 12. USE_QTDEBUG=0: the SDL kiosk never opens the Qt debugger and the
# chroot has no Qt.
nice -n 10 make SUBTARGET=oricatmos SOURCES=src/mame/tangerine/oric.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
EOS

[ -x "$WORK/mame/oricatmos" ] || {
  echo "MAME build completed without an oricatmos binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/oricatmos" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME 0.289 (tag mame0289) commit $MAME_ORIC_BASE
Drivers: src/mame/tangerine/oric.cpp only (oric1, orica, prav8d, telstrat, ...)
EOF
