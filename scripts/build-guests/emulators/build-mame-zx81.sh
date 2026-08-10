#!/bin/bash
# =============================================================================
# Build the shipping ZX81 MAME binary from a pinned upstream source revision.
#
# WHY A PURPOSE-BUILT BINARY AND NOT A PACKAGE. Whichever bridge base this tile
# is on, its packaged MAME is not the pinned one (bookworm ships 0.251), and on
# bookworm the lab HOST's Debian 13 MAME 0.276 cannot be copied in either — its
# glibc/libstdc++ ABI the bookworm guest cannot load. mpf2 already solved this by
# building a SUBTARGET in a suite-matched chroot, so the collection keeps one
# MAME provenance story instead of two: pinned upstream source, one driver file,
# built against the exact runtime the kiosk has. The suite comes from
# registry/bridge-suites.json; see docs/lab/BRIDGE-TRIXIE-MIGRATION.md.
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
#   BRIDGE_SUITE          force a suite (experiment clones only; see the resolver)
#   MAME_BOOKWORM_CHROOT  DEPRECATED escape hatch: build in this chroot instead
#                         of the suite's own. Warns on stderr; still honoured.
#   MAME_LOCAL_REF        optional existing MAME clone on the host to seed from,
#                         which turns a 15-minute upstream fetch into seconds.
#                         The pinned commit is checked out and asserted either way.
#   JOBS                  make -j (default: nproc)
# =============================================================================
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-suite.sh"
SUITE="$(bridge_suite_for zx81)"
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
WORK="${1:-$CHROOT/build/mame-zx81-build-$$}"
OUT="${2:-/data/vms/streamhost/assets/zx81/mame/zx81}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
# MAME 0.289. The same commit scripts/build-guests/emulators/build-mame-mpf2.sh pins.
MAME_ZX81_BASE="f34f02505e32c1993c6a782b6814232cbfc74e36"
LOCAL_REF="${MAME_LOCAL_REF:-}"

say() { printf '\n== %s\n' "$*"; }

# The chroot must exist AND be the generation the suite claims: a stale or
# wrong-suite chroot otherwise shows up as a link/ABI error an hour into a build.
CHROOT_DEB_WANT="$(bridge_debian_version_for "$SUITE")"
[ -d "$CHROOT" ] || {
  echo "missing $SUITE MAME build chroot: $CHROOT" >&2
  exit 1
}
CHROOT_DEB_HAVE="$(cut -d. -f1 <"$CHROOT/etc/debian_version" 2>/dev/null || true)"
[ "$CHROOT_DEB_HAVE" = "$CHROOT_DEB_WANT" ] || {
  echo "chroot $CHROOT is Debian '${CHROOT_DEB_HAVE:-<no /etc/debian_version>}'," >&2
  echo "  but suite $SUITE needs Debian $CHROOT_DEB_WANT — rebuild it, or fix the suite." >&2
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

say "building MAME 0.289 SUBTARGET=zx81 in $SUITE with $JOBS jobs"
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
