#!/bin/bash
# =============================================================================
# Build the shipping ZX81 MAME binary from a pinned upstream source revision.
#
# WHY A PURPOSE-BUILT BINARY AND NOT A PACKAGE. The bridge base is Debian 12
# (bookworm) and its packaged MAME is 0.251; the lab HOST runs Debian 13 with
# MAME 0.276, whose glibc/libstdc++ ABI the bookworm guest cannot load. mpf2
# already solved this by building a SUBTARGET in a bookworm chroot, so the
# collection keeps one MAME provenance story instead of two: pinned upstream
# source, one driver file, built against the exact runtime the kiosk has.
# This script is that build for `sinclair/zx.cpp`, at the SAME upstream commit
# mpf2 pins (MAME 0.289, f34f0250) so both MAME tiles ship one known version.
#
# UNLIKE mpf2 THERE IS NO PATCH. mpf2 needs mame-irix-skip-warnings.patch
# because its driver is marked imperfect and MAME puts a full-screen red
# "THIS SYSTEM DOESN'T WORK" panel in front of it that -skip_gameinfo does not
# suppress. `mame -listxml zx81` reports status="good"/"original", so the ZX81
# never raises that panel — verified on the frame by zx81.sh, not assumed here.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-zx81.sh [work-dir] [output-binary]
#
# Env:
#   MAME_BOOKWORM_CHROOT  chroot to build in (default /data/vms/soltest/bookworm-chroot)
#   MAME_LOCAL_REF        optional existing MAME clone on the host to seed from,
#                         which turns a 15-minute upstream fetch into seconds.
#                         The pinned commit is checked out and asserted either way.
#   JOBS                  make -j (default: nproc)
# =============================================================================
set -euo pipefail

CHROOT="${MAME_BOOKWORM_CHROOT:-/data/vms/soltest/bookworm-chroot}"
WORK="${1:-$CHROOT/build/mame-zx81-build-$$}"
OUT="${2:-/data/vms/streamhost/assets/zx81/mame/zx81}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
# MAME 0.289. The same commit scripts/build-guests/emulators/build-mame-mpf2.sh pins.
MAME_ZX81_BASE="f34f02505e32c1993c6a782b6814232cbfc74e36"
LOCAL_REF="${MAME_LOCAL_REF:-}"

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
if [ -n "$LOCAL_REF" ] && [ -e "$LOCAL_REF/.git" ]; then
  say "seeding from the local MAME clone $LOCAL_REF (pinned commit still asserted)"
  [ -d "$WORK/mame/.git" ] || git clone --local --no-hardlinks -q "$LOCAL_REF" "$WORK/mame"
fi

say "building MAME 0.289 SUBTARGET=zx81 in Bookworm with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- "$CHROOT_WORK" "$UPSTREAM" "$MAME_ZX81_BASE" "$JOBS" <<'EOS'
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
git rev-parse HEAD | grep -qx "$base" || {
  git fetch -q origin "$base"
  git reset -q --hard "$base"
  git clean -qfd
}
git rev-parse HEAD | grep -qx "$base" || {
  echo "MAME source is not at the pinned commit $base" >&2
  exit 1
}
# Only the Sinclair ZX driver file is compiled into the MAME core; the Qt
# debugger is irrelevant to an SDL kiosk and is not installed in the chroot.
nice -n 10 make SUBTARGET=zx81 SOURCES=src/mame/sinclair/zx.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
EOS

[ -x "$WORK/mame/zx81" ] || {
  echo "MAME build completed without a zx81 binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/zx81" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME 0.289 commit $MAME_ZX81_BASE (SUBTARGET=zx81, src/mame/sinclair/zx.cpp)
Patch:  none — the zx81 driver is status="good" and raises no warning panel
EOF
