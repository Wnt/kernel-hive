#!/bin/bash
# Build the shipping Dragon 32 MAME binary from a pinned upstream source revision.
#
# WHY A PURPOSE-BUILT BINARY AT ALL.  While this tile is on the Debian 12 bridge
# base the lab host is not, so the host's /usr/games/mame (0.276) cannot simply
# be copied into a tile: its glibc/libstdc++ ABI does not match.  The two
# remaining choices are Debian 12's packaged MAME or a binary built in the
# suite's own chroot.  This tile takes the second, for the same reason mpf2 does
# and for one more: mpf2 already ships MAME 0.289 built from commit f34f025 in
# that chroot, so pinning the SAME commit here means the gallery has exactly one
# MAME version across its two MAME bridge exhibits instead of two that drift
# apart.  The chroot is chosen from the tile's suite in
# registry/bridge-suites.json; once dragon32 moves to trixie the chroot matches
# the host and only the pin, not the ABI, is doing the work (see
# docs/lab/BRIDGE-TRIXIE-MIGRATION.md).
#
# NO PATCH.  mpf2 needs `mame-irix-skip-warnings.patch` because its driver is
# marked imperfect and MAME puts up a nag panel.  `dragon32` is
# `<driver status="good" emulation="good">` in the pinned tree, so it never nags
# and this build is pristine upstream.  Do not add the patch "for symmetry": a
# patched binary would have to be re-justified every time it is audited.
#
# Only src/mame/trs/dragon.cpp (which owns dragon32) is compiled into the driver
# set; the whole MAME core/devices/OSD still build, so budget ~1 hour.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-dragon32.sh [work-dir] [output-binary]
# Env:
#   BRIDGE_SUITE          force a suite (experiment clones only; see the resolver)
#   MAME_BOOKWORM_CHROOT  DEPRECATED escape hatch: chroot root to use instead of
#                         the suite's own.  Warns on stderr; still honoured.
#   MAME_SEED_REPO        optional local MAME git tree to clone from instead of
#                         hitting the network (any revision; it is reset to the
#                         pin below).  Saves ~1 GB of fetch on a box that already
#                         has a checkout.
#   JOBS                  parallel compile jobs (default: nproc, capped at 12 --
#                         MAME's heavier translation units want ~1.5 GB each and
#                         this box shares its RAM with 30+ emulators)
set -euo pipefail

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-suite.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/mame-ccache.sh"
CHROOT_GUARD_LIB="$(dirname "${BASH_SOURCE[0]}")/../../lib/chroot-guard.sh"
# The chroot below runs in a PRIVATE mount namespace: nothing it mounts is
# visible to the host, and no unmount can propagate out (the 2026-08-10
# "PTY allocation failed" incident — scripts/lib/chroot-guard.sh).
# shellcheck disable=SC1090,SC1091
if [ -f "$CHROOT_GUARD_LIB" ]; then . "$CHROOT_GUARD_LIB"; else . /usr/local/bin/chroot-guard; fi
chroot_guard_reexec_private "$@"
SUITE="$(bridge_suite_for dragon32)"
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
CHROOT_WORK="/build/mame-dragon32-build-$$"
WORK="${1:-$CHROOT$CHROOT_WORK}"
OUT="${2:-/data/vms/streamhost/assets/dragon32/mame/dragon}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
SEED="${MAME_SEED_REPO:-}"
DEFAULT_JOBS=$(nproc)
[ "$DEFAULT_JOBS" -gt 12 ] && DEFAULT_JOBS=12
JOBS="${JOBS:-$DEFAULT_JOBS}"
# MAME 0.289, the same commit the mpf2 tile ships.
MAME_DRAGON32_BASE="f34f02505e32c1993c6a782b6814232cbfc74e36"

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

if [ -n "$SEED" ]; then
  [ -e "$SEED/.git" ] || {
    echo "MAME_SEED_REPO is not a git checkout: $SEED" >&2
    exit 1
  }
  say "seeding from local MAME checkout $SEED (no network fetch)"
  if [ ! -d "$WORK/mame/.git" ]; then
    git clone --local --no-hardlinks "$SEED" "$WORK/mame"
  fi
fi

# Shared compiler cache at <chroot>/ccache, outside every build tree, so this
# tile's cold tree still reuses the objects a sibling MAME build already
# produced (mame-ccache.sh explains why the hash survives the tree name). It
# touches no file in the tree, so the pristine-source assertion above stands.
mame_ccache_prepare "$CHROOT"

say "building MAME 0.289 (SUBTARGET=dragon) in $SUITE with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- "$CHROOT_WORK" "$UPSTREAM" "$MAME_DRAGON32_BASE" "$JOBS" <<'EOS'
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
git rev-parse --verify -q "$base^{commit}" >/dev/null || git fetch -q origin "$base"
git reset -q --hard "$base"
git clean -qfd
# Pristine upstream: assert nothing is patched in before compiling, so the
# provenance line printed at the end is true.
[ -z "$(git status --porcelain)" ] || {
  echo "MAME source tree is not pristine at the pin; refusing to build" >&2
  git status --porcelain >&2
  exit 1
}
# Default to genie's own compilers; /ccache/env.sh swaps in `ccache gcc`.
MAME_MAKE_CC_ARGS=(OVERRIDE_CC=gcc OVERRIDE_CXX=g++)
# shellcheck disable=SC1091
if [ -r /ccache/env.sh ]; then . /ccache/env.sh; fi
# Qt debugger is irrelevant to an SDL kiosk and is not installed in the chroot.
nice -n 5 make SUBTARGET=dragon SOURCES=src/mame/trs/dragon.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 "${MAME_MAKE_CC_ARGS[@]}" -j"$jobs"
EOS

[ -x "$WORK/mame/dragon" ] || {
  echo "MAME build completed without dragon binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/dragon" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME 0.289 commit $MAME_DRAGON32_BASE (pristine upstream, no patch)
Driver: dragon32 (src/mame/trs/dragon.cpp), <driver status="good">
EOF
