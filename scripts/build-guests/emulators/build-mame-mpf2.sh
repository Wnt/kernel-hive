#!/bin/bash
# Build the shipping MPF-II MAME binary from a pinned upstream source revision.
# The build runs in the chroot whose glibc/libstdc++ ABI matches the bridge
# guest this tile is built on — bookworm today, trixie once mpf2 is migrated
# (registry/bridge-suites.json, docs/lab/BRIDGE-TRIXIE-MIGRATION.md). On a
# trixie tile that chroot is the host's own generation, so the ABI detour this
# script exists for finally goes away. It deliberately builds only tk2000.cpp
# (which owns mpf2) in a namespaced soltest worktree.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-mpf2.sh [work-dir] [output-binary]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/bridge-suite.sh"
# shellcheck disable=SC1091
. "$HERE/mame-ccache.sh"
CHROOT_GUARD_LIB="$HERE/../../lib/chroot-guard.sh"
# The chroot below runs in a PRIVATE mount namespace: nothing it mounts is
# visible to the host, and no unmount can propagate out (the 2026-08-10
# "PTY allocation failed" incident — scripts/lib/chroot-guard.sh).
# shellcheck disable=SC1090,SC1091
if [ -f "$CHROOT_GUARD_LIB" ]; then . "$CHROOT_GUARD_LIB"; else . /usr/local/bin/chroot-guard; fi
chroot_guard_reexec_private "$@"
SUITE="$(bridge_suite_for mpf2)"
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
CHROOT_WORK="/build/mame-mpf2-build-$$"
WORK="${1:-$CHROOT$CHROOT_WORK}"
OUT="${2:-/data/vms/streamhost/assets/mpf2/mame/mpf2}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
MAME_MPF2_BASE="f34f02505e32c1993c6a782b6814232cbfc74e36"
PATCH="$HERE/../patches/mame-irix-skip-warnings.patch"
# Published fork submodule (github.com/Wnt/mame, branch `mpf2`): the same
# warning-suppression patch, already committed there. If it's checked out,
# seed the chroot build from it instead of cloning upstream + patching --
# see scripts/build-guests/README.md for which form to edit.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SUBMODULE="$REPO_ROOT/third_party/mame-mpf2"

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

USE_SUBMODULE=0
if [ -e "$SUBMODULE/.git" ]; then
  USE_SUBMODULE=1
  say "seeding the chroot build from the published mame-mpf2 submodule (patch already committed on its 'mpf2' branch)"
  rm -rf "$WORK/mame"
  git clone --local "$SUBMODULE" "$WORK/mame"
else
  [ -f "$PATCH" ] || {
    echo "missing warning-suppression patch: $PATCH" >&2
    exit 1
  }
  say "submodule not initialized at $SUBMODULE -- falling back to upstream clone + loose-patch apply"
  say "run 'git submodule update --init third_party/mame-mpf2' to use the published fork instead"
  install -m 644 "$PATCH" "$WORK/mame-irix-skip-warnings.patch"
fi

# Shared compiler cache at <chroot>/ccache — this builder names its tree with
# $$, so every run is a cold tree and ccache is the only thing that carries any
# work forward (mame-ccache.sh explains why the hash survives the tree name).
mame_ccache_prepare "$CHROOT"

say "building MAME 0.289 in $SUITE with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- "$CHROOT_WORK" "$UPSTREAM" "$MAME_MPF2_BASE" "$JOBS" "$USE_SUBMODULE" <<'EOS'
set -euo pipefail
work="$1"
upstream="$2"
base="$3"
jobs="$4"
use_submodule="$5"
cd "$work"
if [ "$use_submodule" = 1 ]; then
  # mame/ was already seeded from the submodule, patch already committed there.
  :
else
  if [ ! -d mame/.git ]; then
    git clone --filter=blob:none "$upstream" mame
  fi
  cd mame
  git fetch -q origin "$base"
  git reset -q --hard "$base"
  git clean -qfd
  patch -p1 --dry-run -f <../mame-irix-skip-warnings.patch >/dev/null 2>&1 || {
    echo "warning-suppression patch does not apply to pinned MAME source" >&2
    exit 1
  }
  patch -p1 -f <../mame-irix-skip-warnings.patch >/dev/null
fi
cd "$work/mame"
# Default to genie's own compilers; /ccache/env.sh swaps in `ccache gcc`.
MAME_MAKE_CC_ARGS=(OVERRIDE_CC=gcc OVERRIDE_CXX=g++)
# shellcheck disable=SC1091
if [ -r /ccache/env.sh ]; then . /ccache/env.sh; fi
# Qt Debugger is irrelevant to the SDL kiosk and not installed in the chroot.
nice -n 5 make SUBTARGET=mpf2 SOURCES=src/mame/apple/tk2000.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 "${MAME_MAKE_CC_ARGS[@]}" -j"$jobs"
EOS

[ -x "$WORK/mame/mpf2" ] || {
  echo "MAME build completed without mpf2 binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/mpf2" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME 0.289 commit $MAME_MPF2_BASE
Patch: $(basename "$PATCH")
EOF
