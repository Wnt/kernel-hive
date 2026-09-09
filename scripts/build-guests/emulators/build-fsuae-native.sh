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
# Usage: [FSUAE_STATION=<station>] build-fsuae-native.sh [--no-install]
set -euo pipefail

FSUAE_FORK_URL="${FSUAE_FORK_URL:-https://github.com/Wnt/fs-uae.git}"
FSUAE_FORK_BRANCH=kernel-hive/integrated
FSUAE_FORK_PIN=e8c4f74a9dc3b4676ba15d0d5655a0aaec3e1b5e

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
#    the release tarball this builder used to fetch. automake/autoconf/
#    libtool are not on CT950 or labhost and neither box gives this script
#    root — same trick the VICE builder uses for xa65: `apt-get download`
#    needs no privilege, unpacked straight into the work dir, never
#    installed on the host.
# ---------------------------------------------------------------------------
if [ ! -x "$SRC/configure" ]; then
  if ! command -v automake >/dev/null 2>&1; then
    say "staging automake/autoconf/libtool (unpacked into the work dir, never installed on the host)"
    mkdir -p "$WORK/bin" "$WORK/autotools-pkg"
    (cd "$WORK/autotools-pkg" && apt-get download automake autoconf autotools-dev libtool libtool-bin libltdl-dev m4 >/dev/null 2>&1) ||
      die "apt-get download automake autoconf autotools-dev libtool libtool-bin libltdl-dev m4 failed — the bootstrap step needs them"
    for deb in "$WORK"/autotools-pkg/*.deb; do
      dpkg-deb -x "$deb" "$WORK/autotools-pkg/root"
    done
    find "$WORK/autotools-pkg/root/usr/bin" -maxdepth 1 -type f -exec ln -sf {} "$WORK/bin/" \;
    # libtool's aclocal m4 macros ship under share/aclocal, but libtoolize
    # looks for them at $_lt_pkgdatadir/m4 — the package's own layout, not a
    # dpkg-deb -x quirk.
    ln -sf "$WORK/autotools-pkg/root/usr/share/aclocal" "$WORK/autotools-pkg/root/usr/share/libtool/m4"
    export PATH="$WORK/bin:$PATH"
    export AUTOMAKE_LIBDIR="$WORK/autotools-pkg/root/usr/share/automake-1.16"
    export AUTOCONF_LIBDIR="$WORK/autotools-pkg/root/usr/share/autoconf"
    export ACLOCAL_PATH="$WORK/autotools-pkg/root/usr/share/aclocal"
    # Automake's perl module (Automake/Config.pm) ships INSIDE its own
    # share dir, not under a generic perl5 tree.
    export PERL5LIB="$WORK/autotools-pkg/root/usr/share/automake-1.16:${PERL5LIB:-}"
    # libtoolize resolves its own data dir from _lt_pkgdatadir, not PATH.
    export _lt_pkgdatadir="$WORK/autotools-pkg/root/usr/share/libtool"
  fi
  say "bootstrapping the autotools build (./bootstrap)"
  (cd "$SRC" && ./bootstrap >"$WORK/bootstrap.log" 2>&1) ||
    die "bootstrap failed; see $WORK/bootstrap.log"
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

say "building with $(nproc) jobs"
(cd "$SRC" && make -j"$(nproc)" >"$WORK/build.log" 2>&1) || {
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
