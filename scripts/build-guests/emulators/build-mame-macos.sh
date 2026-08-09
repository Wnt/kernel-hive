#!/usr/bin/env bash
# Build a patched MAME `sgi` subtarget for running the IRIX exhibit image locally
# on macOS (Apple Silicon or Intel). Produces ./sgi in the MAME source tree.
#
# Why patched: stock MAME gives the emulated Indy 16 MB, which makes IRIX 6.5 page
# constantly (~793 s to desktop vs ~390 s at 256 MB). The RAM patch fixes that --
# but it also EXPOSES a latent upstream DMA bug that panics the guest, so the two
# patches below are a required pair, never one without the other.
#
#   usage: ./build-mame-macos.sh [workdir]     (default: ~/irix/mame-build)
set -euo pipefail

WORK="${1:-$HOME/irix/mame-build}"
BASE_COMMIT="8f21e978d0bd54971145e08ab5fab6c3c3d4ba81" # the commit our patches target
PATCH_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Published fork submodule (github.com/Wnt/mame, branch `irix`). If the repo
# checkout this script lives in has it initialized, build from it directly
# instead of cloning upstream + applying loose patches -- see
# scripts/build-guests/README.md for which form (patch vs. fork branch) to edit.
REPO_ROOT="$(cd "$PATCH_SRC/../.." && pwd)"
SUBMODULE="$REPO_ROOT/third_party/mame-irix"

say() { printf '\n=== %s\n' "$*"; }

say "checking prerequisites"
xcode-select -p >/dev/null 2>&1 || {
  echo "Xcode command line tools missing. Run: xcode-select --install" >&2
  exit 1
}
command -v brew >/dev/null || {
  echo "Homebrew missing: https://brew.sh" >&2
  exit 1
}
# MAME needs SDL2 and a python3; pkg-config lets its build find SDL2.
for f in sdl2 sdl2_ttf pkg-config python3; do
  brew list --formula "$f" >/dev/null 2>&1 || {
    echo "installing $f"
    brew install "$f"
  }
done

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
  git clean -qfd
else
  say "submodule not initialized at $SUBMODULE -- falling back to upstream clone + loose-patch apply"
  say "run 'git submodule update --init third_party/mame-irix' to use the published fork instead"
  if [ ! -d mame/.git ]; then
    say "cloning MAME (shallow at the pinned commit; a few minutes)"
    # Full clone: MAME's history is large but a shallow clone of one commit is not
    # fetchable by SHA on all servers, so clone then check out.
    git clone --filter=blob:none https://github.com/mamedev/mame.git mame
  fi

  cd mame
  say "checking out the pinned base $BASE_COMMIT"
  git fetch --tags origin
  git checkout -q "$BASE_COMMIT"
  git reset -q --hard "$BASE_COMMIT"
  git clean -qfd

  say "applying patches"
  # The stack, its order and its dependencies live in ONE place so the box build
  # and this one cannot drift apart -- see irix-mame-stack.sh for what each patch
  # buys, which pairs are required, and what is deliberately excluded. On macOS
  # the arch and OS gates in that file skip the 256 MB DRC cache patch (arm64
  # branches cannot reach across a 256 MB code cache) and the taptun interface
  # patch (Linux tap devices only). Everything else is exactly what ships.
  # shellcheck source=scripts/build-guests/irix-mame-stack.sh
  . "$PATCH_SRC/irix-mame-stack.sh"
  [ "$BASE_COMMIT" = "$IRIX_MAME_BASE" ] || {
    echo "base commit drift: this script says $BASE_COMMIT, the stack says $IRIX_MAME_BASE" >&2
    exit 1
  }
  irix_mame_apply "$WORK/mame" "$PATCH_SRC"
fi

say "building (this takes 30-60 min the first time)"
JOBS="$(sysctl -n hw.ncpu)"
make SUBTARGET=sgi SOURCES=src/mame/sgi/indy_indigo2.cpp -j"$JOBS"

say "done"
cat <<EOF
Binary: $WORK/mame/sgi

Run it (adjust paths to where you unpacked the assets):

  $WORK/mame/sgi indy_4610 -bios b10 \\
    -rompath  \$HOME/irix/roms \\
    -gio64_gfx xl24 \\
    -hard1    \$HOME/irix/irix-v3-compressed.chd \\
    -diff_directory \$HOME/irix/diff \\
    -nvram_directory \$HOME/irix/nvram \\
    -skip_gameinfo -window

Login: root, empty password. Verify the RAM took with 'hinv' -- it should say
"Main memory size: 256 Mbytes". Sound is on by default (CoreAudio); the gallery
tile only lacks it because it runs with -sound none.
EOF
