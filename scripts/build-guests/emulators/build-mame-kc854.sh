#!/bin/bash
# =============================================================================
# build-mame-kc854.sh — build the shipping KC 85/4 MAME binary from a pinned
# upstream release, in the suite's own chroot, exactly as build-mame-mpf2.sh does.
#
# WHY A PURPOSE-BUILT BINARY AND NOT THE HOST PACKAGE
#   The bridge guest is Debian 12 (bookworm) while this tile is on that suite;
#   the lab host is Debian 13 and its packaged MAME is 0.276, so a trixie-linked
#   binary will not run in a bookworm guest — and bookworm's own package is MAME
#   0.251, the release in which `kc85_4` is still a *clone* of `kc85_2` with a
#   different ROM split. Pinning one binary and assembling the romset against
#   THAT binary's -listxml is the only way the set and the emulator can be known
#   to agree. The chroot is picked from the tile's suite in
#   registry/bridge-suites.json so its glibc/libstdc++ always match the guest —
#   which is why the IRIX/mpf2 builds live there too. Once kc854 is migrated the
#   chroot becomes the host's own generation and the ABI argument above retires
#   (docs/lab/BRIDGE-TRIXIE-MIGRATION.md); the version pin still stands.
#
# WHY THE WARNING PATCH IS NOT OPTIONAL HERE
#   `mame -listxml kc85_4` reports driver status="preliminary", so MAME puts up
#   its full-screen red "THIS SYSTEM DOESN'T WORK" panel before the machine
#   runs. -skip_gameinfo does NOT suppress that panel, and a headless
#   -video none probe never shows it, so an unpatched binary would ship an
#   exhibit that is a red error screen for ever. mame-irix-skip-warnings.patch
#   makes `skip_warnings 1` (set in the tile's ui.ini) actually apply to it.
#   The kiosk therefore never needs to post a dismissal key, and the golden can
#   be baked at a genuinely untouched CAOS boot screen.
#
# Usage:
#   scripts/build-guests/emulators/build-mame-kc854.sh [work-dir] [output-binary]
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
SUITE="$(bridge_suite_for kc854)"
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
CHROOT_WORK="/build/mame-kc854-build-$$"
WORK="${1:-$CHROOT$CHROOT_WORK}"
OUT="${2:-/data/vms/streamhost/assets/kc854/mame/kc85}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-8}"
# mame0289 — the newest upstream release tag at build time (2026-08-09), and the
# same revision the mpf2 tile ships, so the two MAME tiles stay on one version.
MAME_KC854_TAG="${MAME_KC854_TAG:-mame0289}"
MAME_KC854_BASE="${MAME_KC854_BASE:-d0b7160e54874fa58f553614db373d73100d5ecb}"
# src/mame/ddr/kc.cpp owns kc85_2/kc85_3/kc85_4/kc85_5 (VEB Mühlhausen). The
# build asserts the path exists rather than trusting it, because MAME moves
# driver files between directories across releases.
DRIVER_SRC="src/mame/ddr/kc.cpp"
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
[ "${WORK#"$CHROOT"}" != "$WORK" ] || {
  echo "work directory must be inside chroot: $CHROOT" >&2
  exit 1
}
CHROOT_WORK="${WORK#"$CHROOT"}"
[ -n "$CHROOT_WORK" ] && [ "${CHROOT_WORK#/}" != "$CHROOT_WORK" ] || {
  echo "invalid chroot work directory: $WORK" >&2
  exit 1
}
[ -f "$PATCH" ] || {
  echo "missing warning-suppression patch: $PATCH" >&2
  exit 1
}

mkdir -p "$WORK"
install -m 644 "$PATCH" "$WORK/mame-irix-skip-warnings.patch"

say "building MAME $MAME_KC854_TAG (SUBTARGET=kc85) in $SUITE with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- \
  "$CHROOT_WORK" "$UPSTREAM" "$MAME_KC854_BASE" "$JOBS" "$DRIVER_SRC" <<'EOS'
set -euo pipefail
work="$1"
upstream="$2"
base="$3"
jobs="$4"
driver_src="$5"
cd "$work"
if [ ! -d mame/.git ]; then
  git clone --filter=blob:none "$upstream" mame
fi
cd mame
git fetch -q origin "$base"
git reset -q --hard "$base"
git clean -qfd
[ -f "$driver_src" ] || { echo "driver source missing at $driver_src in this MAME revision" >&2; exit 1; }
patch -p1 --dry-run -f <../mame-irix-skip-warnings.patch >/dev/null 2>&1 || {
  echo "warning-suppression patch does not apply to pinned MAME source" >&2
  exit 1
}
patch -p1 -f <../mame-irix-skip-warnings.patch >/dev/null
# Qt debugger is irrelevant to an SDL kiosk and not installed in the chroot.
nice -n 5 make SUBTARGET=kc85 SOURCES="$driver_src" \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 -j"$jobs"
EOS

[ -x "$WORK/mame/kc85" ] || {
  echo "MAME build completed without a kc85 binary" >&2
  exit 1
}
# The binary must actually contain the driver this tile exists for.
"$WORK/mame/kc85" -listxml kc85_4 >/dev/null 2>&1 || {
  echo "built binary does not know the kc85_4 driver" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/kc85" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME $MAME_KC854_TAG commit $MAME_KC854_BASE
Driver: $DRIVER_SRC (kc85_2 / kc85_3 / kc85_4 / kc85_5)
Patch:  $(basename "$PATCH")
EOF
