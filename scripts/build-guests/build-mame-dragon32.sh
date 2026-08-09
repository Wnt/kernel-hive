#!/bin/bash
# Build the shipping Dragon 32 MAME binary from a pinned upstream source revision.
#
# WHY A PURPOSE-BUILT BINARY AT ALL.  The bridge base is Debian 12 and the lab
# host is not, so the host's /usr/games/mame (0.276) cannot simply be copied into
# a tile: its glibc/libstdc++ ABI does not match.  The two remaining choices are
# Debian 12's packaged MAME or a binary built in the Bookworm chroot.  This tile
# takes the second, for the same reason mpf2 does and for one more: mpf2 already
# ships MAME 0.289 built from commit f34f025 in that chroot, so pinning the SAME
# commit here means the gallery has exactly one MAME version across its two MAME
# bridge exhibits instead of two that drift apart.
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
#   scripts/build-guests/build-mame-dragon32.sh [work-dir] [output-binary]
# Env:
#   MAME_BOOKWORM_CHROOT  chroot root (default /data/vms/soltest/bookworm-chroot)
#   MAME_SEED_REPO        optional local MAME git tree to clone from instead of
#                         hitting the network (any revision; it is reset to the
#                         pin below).  Saves ~1 GB of fetch on a box that already
#                         has a checkout.
#   JOBS                  parallel compile jobs (default: nproc, capped at 12 --
#                         MAME's heavier translation units want ~1.5 GB each and
#                         this box shares its RAM with 30+ emulators)
set -euo pipefail

CHROOT="${MAME_BOOKWORM_CHROOT:-/data/vms/soltest/bookworm-chroot}"
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

say "building MAME 0.289 (SUBTARGET=dragon) in Bookworm with $JOBS jobs"
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
# Qt debugger is irrelevant to an SDL kiosk and is not installed in the chroot.
nice -n 5 make SUBTARGET=dragon SOURCES=src/mame/trs/dragon.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
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
