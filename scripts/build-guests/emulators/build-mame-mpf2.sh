#!/bin/bash
# Build the shipping MPF-II MAME binary from a pinned upstream source revision.
# The build runs in the Bookworm chroot used for the IRIX MAME build so its
# glibc/libstdc++ ABI matches the Debian 12 bridge. It deliberately builds only
# tk2000.cpp (which owns mpf2) in a namespaced soltest worktree.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-mpf2.sh [work-dir] [output-binary]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROOT="${MAME_BOOKWORM_CHROOT:-/data/vms/soltest/bookworm-chroot}"
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

say "building MAME 0.289 in Bookworm with $JOBS jobs"
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
# Qt Debugger is irrelevant to the SDL kiosk and not installed in the chroot.
nice -n 5 make SUBTARGET=mpf2 SOURCES=src/mame/apple/tk2000.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
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
