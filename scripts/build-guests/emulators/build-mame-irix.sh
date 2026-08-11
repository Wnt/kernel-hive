#!/bin/bash
# Build the SHIPPING `sgi` binary for the IRIX station, on the lab box (Linux/x86-64).
#
# This is the reproducer. The binary in
# /data/vms/streamhost/assets/irix/mame/sgi is what this script produces from a
# pristine checkout of the pinned upstream commit plus the ordered patch stack
# in irix-mame-stack.sh -- nothing else, no local edits, no env gates. If you
# cannot reproduce the shipped md5 from this script, the shipped binary is
# untrusted and should be rebuilt, not patched around.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-irix.sh [work-dir]
# Default work-dir is /data/vms/soltest/mame-irix-build-$$ -- namespaced under
# soltest on purpose. NEVER build in a live station directory.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/build-guests/irix/irix-mame-stack.sh
. "$HERE/../irix/irix-mame-stack.sh"

WORK="${1:-/data/vms/soltest/mame-irix-build-$$}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
# Published fork submodule (github.com/Wnt/mame, branch `irix`): each patch in
# irix-mame-stack.sh is also a standalone commit there. If it's checked out,
# build from it directly instead of cloning upstream + applying loose patches
# -- both paths produce the same tree, but the submodule is the published,
# reviewable form. See scripts/build-guests/README.md for which one to edit.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SUBMODULE="$REPO_ROOT/third_party/mame-irix"

say() { printf '\n== %s\n' "$*"; }

mkdir -p "$WORK"
cd "$WORK"

if [ -e "$SUBMODULE/.git" ]; then
  say "building from the published mame-irix submodule (patches already land as commits on its 'irix' branch)"
  if [ ! -d mame/.git ]; then
    git clone --local "$SUBMODULE" mame
  fi
  cd mame
  git fetch -q origin irix 2>/dev/null || true
  git reset -q --hard origin/irix 2>/dev/null || git reset -q --hard HEAD
  git clean -qfd # NOT -x: keeps build objects, which makes a rebuild minutes not an hour
else
  say "submodule not initialized at $SUBMODULE -- falling back to upstream clone + loose-patch apply"
  say "run 'git submodule update --init third_party/mame-irix' to use the published fork instead"
  if [ ! -d mame/.git ]; then
    say "cloning MAME (this is a big repo; --filter keeps it bearable)"
    git clone --filter=blob:none "$UPSTREAM" mame
  fi

  say "pinning to $IRIX_MAME_BASE"
  cd mame
  git fetch -q origin "$IRIX_MAME_BASE" 2>/dev/null || true
  git reset -q --hard "$IRIX_MAME_BASE"
  git clean -qfd # NOT -x: keeps build objects, which makes a rebuild minutes not an hour

  say "applying the patch stack"
  irix_mame_apply "$WORK/mame" "$HERE/../patches"
fi

say "building with $JOBS jobs (30-60 min from cold, a few minutes incremental)"
# USE_QTDEBUG=0 is required on the box: the Qt debugger front end wants qmake6,
# which is not installed, and genie fails the build before compiling anything.
nice -n 5 make SUBTARGET=sgi SOURCES=src/mame/sgi/indy_indigo2.cpp USE_QTDEBUG=0 -j"$JOBS"

say "done"
md5sum "$WORK/mame/sgi"
cat <<EOF

Binary: $WORK/mame/sgi

Before promoting it to /data/vms/streamhost/assets/irix/mame/sgi:
  1. smoke-test it on a CLONE running the production launcher and config
     (cold boot to 4Dwm, framebuffer screendump, serial exec, tap carrier up),
  2. keep the outgoing binary beside it as sgi.prev-<md5>,
  3. make sure no tile.env pins IRIX_MAME to some other staged binary.
EOF
