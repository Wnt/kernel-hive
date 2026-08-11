#!/bin/bash
# =============================================================================
# build-guests/emulators/build-mame-oricatmos.sh — build the MAME binary the Oric Atmos
# station ships, from a pinned upstream RELEASE commit, inside the suite's chroot.
#
# WHY A BUILD AND NOT A PACKAGE. The station's emulator runs inside the bridge
# guest, so the binary must match THAT guest's ABI — Bookworm while oricatmos is
# on the bookworm suite, Trixie once it is migrated (registry/bridge-suites.json,
# docs/lab/BRIDGE-TRIXIE-MIGRATION.md). On bookworm the two packaged options are
# both wrong for different reasons:
#   * labhost's `/usr/games/mame` is Debian *trixie* 0.276 — newer, but
#     linked against a glibc the Bookworm guest does not have;
#   * Bookworm's own `mame` is 0.251 (2022), and `bookworm-backports` has no
#     mame at all (checked 2026-08-09).
# So the station does what mpf2 does: build in the ABI-matched chroot that the IRIX
# and MPF-II MAME builds already use, from the latest STABLE tag — `mame0289`,
# commit f34f0250 — which is also the exact commit the mpf2 station ships. On the
# trixie suite the host and guest agree and the first bullet stops applying; the
# pin (and therefore this build) still does.
#
# NO PATCH IS APPLIED HERE, deliberately. mpf2 needs one because its driver is
# marked `preliminary` and MAME paints a full-screen red "THIS SYSTEM DOESN'T
# WORK" panel that `-skip_gameinfo` does not suppress. `orica` is
# `<driver status="good" emulation="good" savestate="supported"/>` in the very
# `-listxml` this build produces, so there is no nag to suppress and no reason
# to ship a modified emulator. Verified by frame, not by that attribute alone.
#
# Only `src/mame/tangerine/oric.cpp` is built into the driver list (SUBTARGET),
# which keeps the binary at ~70 MB instead of ~430 MB and keeps the guest's
# rompath free of every other machine MAME knows.
#
# Usage: build-mame-oricatmos.sh [work-dir] [output-binary]
# =============================================================================
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
SUITE="$(bridge_suite_for oricatmos)"
CHROOT="$(bridge_mame_chroot_for "$SUITE")"
if [ -n "${MAME_BOOKWORM_CHROOT:-}" ]; then
  echo "warning: MAME_BOOKWORM_CHROOT is DEPRECATED; the suite ($SUITE) resolves to $CHROOT" >&2
  echo "         honouring the override anyway: $MAME_BOOKWORM_CHROOT" >&2
  CHROOT="$MAME_BOOKWORM_CHROOT"
fi
CHROOT_WORK="/build/mame-oricatmos"
WORK="${1:-$CHROOT$CHROOT_WORK}"
OUT="${2:-/data/vms/streamhost/assets/oricatmos/mame/oricatmos}"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(($(nproc) > 12 ? 10 : 4))}"
# MAME 0.289 (tag mame0289) — the latest stable release at build time.
MAME_ORIC_BASE=f34f02505e32c1993c6a782b6814232cbfc74e36

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

# Shared compiler cache at <chroot>/ccache, outside every build tree, so a
# migration wave pays for the MAME core once instead of six times
# (mame-ccache.sh explains why the hash survives the different tree names).
mame_ccache_prepare "$CHROOT"

say "building MAME 0.289 (oric.cpp subtarget) in $SUITE with $JOBS jobs"
chroot "$CHROOT" /bin/bash -s -- "$CHROOT_WORK" "$UPSTREAM" "$MAME_ORIC_BASE" "$JOBS" <<'EOS'
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
git remote set-url origin "$upstream"
git fetch -q --depth=1 origin "$base"
git reset -q --hard "$base"
git clean -qfd
# NOWERROR: the pinned release does not build warning-clean under the chroot's
# GCC (12 on bookworm, 14 on trixie — a newer one only warns MORE, so this stays
# necessary). USE_QTDEBUG=0: the SDL kiosk never opens the Qt debugger and the
# chroot has no Qt.
MAME_MAKE_CC_ARGS=(OVERRIDE_CC=gcc OVERRIDE_CXX=g++)
# shellcheck disable=SC1091
if [ -r /ccache/env.sh ]; then . /ccache/env.sh; fi
nice -n 10 make SUBTARGET=oricatmos SOURCES=src/mame/tangerine/oric.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 "${MAME_MAKE_CC_ARGS[@]}" -j"$jobs"
EOS

[ -x "$WORK/mame/oricatmos" ] || {
  echo "MAME build completed without an oricatmos binary" >&2
  exit 1
}
mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/oricatmos" "$OUT"

say "done"
sha256sum "$OUT"
cat <<EOF

Binary: $OUT
Source: MAME 0.289 (tag mame0289) commit $MAME_ORIC_BASE
Drivers: src/mame/tangerine/oric.cpp only (oric1, orica, prav8d, telstrat, ...)
EOF
