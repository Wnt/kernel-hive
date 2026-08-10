#!/bin/bash
# =============================================================================
# build-guests/emulators/build-mame-bbcb.sh — build the shipping BBC Micro MAME binary
# from a pinned upstream RELEASE, in the chroot that matches the tile's suite.
#
# WHY A PURPOSE-BUILT BINARY AND NOT THE DISTRO PACKAGE (the provenance rule):
#   * The binary must be linked against the SAME Debian generation as the bridge
#     guest it runs inside. That generation is per-tile now: bookworm today,
#     trixie once bbcmicro/armeval are migrated (registry/bridge-suites.json,
#     docs/lab/BRIDGE-TRIXIE-MIGRATION.md). On bookworm the host's own
#     /usr/games/mame (Debian 13, 0.276) is too new to copy into the overlay; on
#     trixie the host and guest finally agree and the chroot is only about
#     reproducibility, not ABI.
#   * The bridge base's own apt `mame` would be whatever the suite froze, which
#     is neither the latest stable nor a version anyone pinned.
#   * MAME moves ROM requirements between versions (kim1 renamed its 6530 dump;
#     kc85_4 changed parent). A romset is only meaningful against ONE binary, so
#     the tile builds its binary, pins it, and re-derives the wanted (name,sha1)
#     pairs from THAT binary's own -listxml. bbcmicro.sh does exactly that.
#
# PIN: tag `mame0289` == commit f34f02505e32c1993c6a782b6814232cbfc74e36 — the
# newest STABLE MAME tag at the time of the add (checked with `git ls-remote
# --tags`; 0.290 did not exist), and the same release the mpf2 tile ships, so
# the two MAME exhibits share one provenance story.
#
# SOURCES is the DIRECTORY src/mame/acorn, not bbcb.cpp alone. In 0.289 the BBC
# driver is split across bbcb.cpp / bbc_kbd.cpp / bbc_v.cpp / bbc_m.cpp behind a
# shared bbc.h, and a single-file SOURCES filter is a coin-toss on whether the
# dependency walker picks all of them up. The directory also brings in the Acorn
# second-processor (tube) devices, which the planned `armeval` exhibit needs
# from the same binary.
#
# The warning-suppression patch is the one the IRIX/MPF-II builds already use:
# MAME's startup WARNINGS screen is a separate stage from the game-info screen,
# so `-skip_gameinfo` does NOT suppress it, and `bbcb` is driver status
# "imperfect" (emulation good, imperfect sound) so it always has one. The patch
# makes the existing `skip_warnings` UI option actually gate that stage.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-bbcb.sh [work-dir] [output-binary]
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/bridge-suite.sh"
CHROOT_GUARD_LIB="$HERE/../../lib/chroot-guard.sh"
# The chroot below runs in a PRIVATE mount namespace: nothing it mounts is
# visible to the host, and no unmount can propagate out (the 2026-08-10
# "PTY allocation failed" incident — scripts/lib/chroot-guard.sh).
# shellcheck disable=SC1090,SC1091
if [ -f "$CHROOT_GUARD_LIB" ]; then . "$CHROOT_GUARD_LIB"; else . /usr/local/bin/chroot-guard; fi
chroot_guard_reexec_private "$@"
# ONE binary, TWO tiles: bbcmicro ships it and armeval reuses it from the same
# acorn driver directory (see SOURCES above). They must therefore be on the same
# suite — if the ledger ever disagrees there is no correct chroot to pick, so
# fail here rather than silently build an ABI that is wrong for one of them.
SUITE="$(bridge_suite_for bbcmicro)"
SUITE_ARMEVAL="$(bridge_suite_for armeval)"
[ "$SUITE" = "$SUITE_ARMEVAL" ] || {
  echo "bbcmicro is on '$SUITE' but armeval is on '$SUITE_ARMEVAL', and both run THIS binary." >&2
  echo "  Migrate them together in registry/bridge-suites.json (docs/lab/BRIDGE-TRIXIE-MIGRATION.md)." >&2
  exit 1
}
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
WORK="${1:-$CHROOT/build/mame-bbcb}"
OUT="${2:-/data/vms/streamhost/assets/bbcmicro/mame/bbcb}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
MAME_TAG=mame0289
MAME_BBCB_BASE=f34f02505e32c1993c6a782b6814232cbfc74e36
PATCH="$HERE/../patches/mame-irix-skip-warnings.patch"

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
[ -f "$PATCH" ] || {
  echo "missing warning-suppression patch: $PATCH" >&2
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
install -m 644 "$PATCH" "$WORK/mame-skip-warnings.patch"

say "building MAME $MAME_TAG (acorn drivers) in $SUITE with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- \
  "$CHROOT_WORK" "$UPSTREAM" "$MAME_TAG" "$MAME_BBCB_BASE" "$JOBS" <<'EOS'
set -euo pipefail
work="$1"
upstream="$2"
tag="$3"
base="$4"
jobs="$5"
cd "$work"
if [ ! -d mame/.git ]; then
  git clone -q --filter=blob:none "$upstream" mame
fi
cd mame
git fetch -q --tags origin
git checkout -q "$tag"
git reset -q --hard "$tag"
git clean -qfd
# The tag must resolve to the pinned commit; a moved tag is a silent version
# swap that would invalidate the romset assertions in bbcmicro.sh.
[ "$(git rev-parse HEAD)" = "$base" ] || {
  echo "tag $tag is not commit $base (upstream tag moved?)" >&2
  exit 1
}
patch -p1 --dry-run -f <../mame-skip-warnings.patch >/dev/null 2>&1 || {
  echo "warning-suppression patch does not apply to $tag" >&2
  exit 1
}
patch -p1 -f <../mame-skip-warnings.patch >/dev/null
# Qt Debugger is irrelevant to the SDL kiosk and not installed in the chroot.
nice -n 5 make SUBTARGET=bbcb SOURCES=src/mame/acorn \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
EOS

[ -x "$WORK/mame/bbcb" ] || {
  echo "MAME build completed without a bbcb binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/bbcb" "$OUT"

# Prove the shipped binary really knows the driver this tile pins.
"$OUT" -listxml bbcb >/dev/null 2>&1 || {
  echo "the built binary does not know driver bbcb" >&2
  exit 1
}

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME $MAME_TAG ($MAME_BBCB_BASE), SOURCES=src/mame/acorn
Patch:  $(basename "$PATCH")
EOF
