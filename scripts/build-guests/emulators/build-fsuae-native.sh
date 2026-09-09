#!/bin/bash
# build-fsuae-native.sh — pinned FS-UAE for the host-native FS-UAE stations
# (amigaos35 by default; FSUAE_STATION=amix for the Amiga UNIX station).
#
# Builds from the published fork (github.com/Wnt/fs-uae, branch
# kernel-hive/integrated) at a pinned commit, carried as the
# third_party/fs-uae-kernel-hive submodule — same shape as the VICE and es40
# builders. UNLIKE AN EARLIER VERSION OF THIS SCRIPT THERE ARE NO LOOSE
# PATCHES: the mousehack re-arm (without it every savestate restore leaves
# amigaos35's absolute mouse dead, see docs/guests/amigaos35.md) and the
# slirp hostfwd fix (stock 3.2.35 parses `slirp_redir` and then silently
# drops it; amix's x11warp pointer needs the loopback-only forward, see
# docs/guests/amix.md) are two commits on the fork, on top of upstream tag
# v3.2.35. The golden statefile + this binary + the device set are ONE
# combination: rebuilding to a different FS-UAE version or pin orphans the
# golden.
#
# A git checkout has no generated configure script (the tarball this script
# used to fetch shipped one pre-built). This lab's two boxes split the
# autotools toolchain: CT950, where this script runs (it has `zip` and the
# compiler; labhost does not), has NO autotools, while labhost has
# autoconf/automake/libtoolize/m4 but no zip. So the one bootstrap step runs
# through the one door (AGENTS.md rule 2): `ssh lab "cd $SRC && ./bootstrap"`
# on the SAME bytes ($SRC lives under /data/vms, bind-mounted into CT950) —
# no second copy, no apt-get install on either box. configure/make/install
# still run locally on CT950, same as before.
#
# Usage: [FSUAE_STATION=<station>] build-fsuae-native.sh [--no-install]
set -euo pipefail

FSUAE_FORK_URL="${FSUAE_FORK_URL:-https://github.com/Wnt/fs-uae.git}"
FSUAE_FORK_BRANCH=kernel-hive/integrated
FSUAE_FORK_PIN=4f238761d4244adf9d7f5ac424d0b4fc4a28a5c0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SUBMODULE="$REPO_ROOT/third_party/fs-uae-kernel-hive"

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "$*" >&2
  exit 1
}

ASSETS_ROOT="${FSUAE_ASSETS_ROOT:-/data/vms/streamhost/assets}"
# Which station's asset tree gets this binary. Each station keeps its OWN copy:
# golden + binary + device set are ONE combination (AGENTS.md rule 6), so two
# stations sharing one binary means a rebuild for one orphans the other's
# golden. Defaults to amigaos35, the station this script was written for.
FSUAE_STATION="${FSUAE_STATION:-amigaos35}"
PREFIX="$ASSETS_ROOT/$FSUAE_STATION/fsuae-native"
WORK="${WORK:-/data/vms/sandbox/BUILD-fsuae}"
SRC="$WORK/fs-uae-src"

INSTALL=1
[ "${1:-}" = --no-install ] && INSTALL=0

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# 1. source: the published fork at the pin, never a release tarball
# ---------------------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  if [ -e "$SUBMODULE/.git" ]; then
    say "cloning from the checked-out third_party/fs-uae-kernel-hive submodule"
    # --no-hardlinks is not optional on the box: /data/kernel-hive and
    # /data/vms are separate filesystems, and a plain --local clone dies with
    # "failed to create link ... Invalid cross-device link".
    git clone -q --local --no-hardlinks "$SUBMODULE" "$SRC"
  else
    say "cloning the published fork (submodule not checked out: git submodule update --init third_party/fs-uae-kernel-hive)"
    git clone -q --branch "$FSUAE_FORK_BRANCH" "$FSUAE_FORK_URL" "$SRC"
  fi
fi
git -C "$SRC" fetch -q origin "+$FSUAE_FORK_BRANCH:refs/remotes/origin/pin" 2>/dev/null ||
  git -C "$SRC" fetch -q origin 2>/dev/null || true
git -C "$SRC" checkout -q "$FSUAE_FORK_PIN" 2>/dev/null ||
  die "the pinned commit $FSUAE_FORK_PIN is not in $SRC — is the submodule stale?"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$FSUAE_FORK_PIN" ] ||
  die "source tree is not at the pin $FSUAE_FORK_PIN"
echo "  source: $SRC at $FSUAE_FORK_PIN ($FSUAE_FORK_BRANCH)"

# ---------------------------------------------------------------------------
# 2. bootstrap: a git checkout ships no generated configure script, unlike
#    the release tarball this builder used to fetch. This lab's two boxes
#    split the toolchain: CT950 (where this script runs — it has `zip` and
#    the compiler, labhost does not) has NO autotools; labhost has
#    autoconf/automake/libtoolize/m4 but no zip. Neither box gets a stray
#    `apt-get install`, so the one step that needs autotools goes through
#    the one door (AGENTS.md rule 2): a single `ssh lab` runs ./bootstrap
#    on the SAME bytes, since $SRC lives under /data/vms, which is
#    bind-mounted into CT950 — no separate copy, no patch to hand-apply.
#    configure/make/install all happen locally afterwards, same as before.
# ---------------------------------------------------------------------------
if [ ! -x "$SRC/configure" ]; then
  say "bootstrapping the autotools build via labhost (ssh lab \"cd $SRC && ./bootstrap\")"
  # SC2029: deliberate — $SRC is a path under /data/vms, bind-mounted into
  # CT950, so it must expand HERE (client-side) to name the same bytes on
  # both sides. There is nothing lab-side to expand it against.
  # shellcheck disable=SC2029
  ssh lab "cd $SRC && ./bootstrap" >"$WORK/bootstrap.log" 2>&1 ||
    die "bootstrap failed; see $WORK/bootstrap.log"
  [ -x "$SRC/configure" ] || die "bootstrap ran but produced no $SRC/configure"
fi

# configure needs `zip` (and the SDL2/GLib dev headers): present in CT950, NOT
# on labhost — run this script from CT950 (the a1000 wave lost a build stream
# to a silent "zip not found" exit, 2026-09-09). Its exit code is checked on
# purpose.
say "configure --prefix=$PREFIX"
(cd "$SRC" && ./configure --prefix="$PREFIX" >"$WORK/configure.log" 2>&1) || {
  tail -15 "$WORK/configure.log" >&2
  die "configure failed (see $WORK/configure.log)"
}

JOBS="${JOBS:-6}" # capped for now: other streams compile on this box
say "building with $JOBS jobs"
(cd "$SRC" && make -j"$JOBS" >"$WORK/build.log" 2>&1) || {
  tail -30 "$WORK/build.log" >&2
  exit 1
}

if [ "$INSTALL" = 0 ]; then
  echo "built (no install): $SRC/fs-uae"
  exit 0
fi

# Never clobber a binary the live golden depends on: back it up first.
if [ -x "$PREFIX/bin/fs-uae" ]; then
  cp -a "$PREFIX/bin/fs-uae" "$PREFIX/bin/fs-uae.bak-$(date +%Y%m%dT%H%M%S)"
fi
(cd "$SRC" && make install >"$WORK/install.log" 2>&1) || die "make install failed; see $WORK/install.log"
"$PREFIX/bin/fs-uae" --version </dev/null | head -1
echo "installed: $PREFIX/bin/fs-uae"
