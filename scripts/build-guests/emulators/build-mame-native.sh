#!/bin/bash
# =============================================================================
# build-guests/emulators/build-mame-native.sh <station> — HOST-NATIVE MAME for
# a de-bridged station: the spike's build-mame-atarist.sh, generalized per the
# conversion brief (docs/lab/DEBRIDGE-CONVERSION-BRIEF.md §4 step 2).
#
# One engine, per-station stanzas under native.d/<station>.sh. A stanza sets:
#
#   NATIVE_DRIVER         machine the exhibit runs (dragon32)
#   NATIVE_SUBTARGET      MAME SUBTARGET= — also names the emitted binary
#   NATIVE_SOURCES        SOURCES= for the narrow driver build
#   NATIVE_GEOM           the station's published surface (WxH); the drawshm
#                         gate publishes at THIS size, because a converted
#                         station keeps its registry geometry — mind the
#                         800x600 stations when their stanzas arrive
#   NATIVE_MAME_ARGS      array; flags the machine needs to reach its scene
#                         (dragon32: -ext "" — DRAGONDOS otherwise)
#   NATIVE_EXTRA_PATCHES  array; e.g. mame-irix-skip-warnings.patch for
#                         MACHINE_NOT_WORKING drivers whose nag panel would
#                         otherwise BE the exhibit. dragon32 is status=good
#                         and takes none.
#   native_stage_roms <romdir>                 populate the rompath, hash-gated
#   native_boot_gate <bin> <romdir> <gatedir>  FRAMEBUFFER proof the machine
#                                              reaches its documented scene
#
# Base patches are the conversion planes and nothing else: ctlsock (input +
# checkpoint verbs; its module object is created unconditionally and is inert
# without MAME_CTL_SOCK) and drawshm (frames; inert without MAME_SHM_PATH).
# The spike-only pointer patches (ptr-tags, st-fastmouse) are NOT here — all
# nine campaign stations are keyboard-only, and the ST keeps its own builder.
#
# NO CHROOT, NO SUITE ASSERTION, unlike the bridge-era per-tile builders: the
# binary this emits runs on the host and only on the host. That is the whole
# point — mpf2/kc854's bookworm ABI chroots are exactly what conversion
# retires. The ccache is the trixie chroot's, shared with every other MAME
# build on this box (host gcc-14 and the chroot's are byte-identical, so
# objects interchange; mame-ccache.sh explains why the hash survives the
# tree name).
#
# PIN: tag mame0289 == the commit every MAME station ships. A version bump
# re-opens romset revalidation fleet-wide; it is not this script's call.
#
# Usage:
#   build-mame-native.sh <station> [work-dir] [output-binary]
#   MAME_CCACHE=0 ... # cold compile   JOBS=8 ... # cap parallelism
# Concurrent agents: pass your own work-dir; the default is stable on purpose
# so a rebuild is incremental.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/bridge-suite.sh"
# shellcheck disable=SC1091
. "$HERE/mame-ccache.sh"

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "$*" >&2
  exit 1
}

STATION="${1:?usage: build-mame-native.sh <station> [work-dir] [output-binary]}"
STANZA="$HERE/native.d/$STATION.sh"
[ -f "$STANZA" ] || die "no conversion stanza for '$STATION': $STANZA"
NATIVE_EXTRA_PATCHES=()
NATIVE_MAME_ARGS=()
# shellcheck disable=SC1090
. "$STANZA"
for v in NATIVE_DRIVER NATIVE_SUBTARGET NATIVE_SOURCES NATIVE_GEOM; do
  [ -n "${!v:-}" ] || die "$STANZA does not set $v"
done
declare -F native_stage_roms >/dev/null || die "$STANZA does not define native_stage_roms"
declare -F native_boot_gate >/dev/null || die "$STANZA does not define native_boot_gate"

WORK="${2:-/data/vms/soltest/BUILD-native-$STATION}"
OUT="${3:-/data/vms/streamhost/assets/$STATION/mame-native/$NATIVE_SUBTARGET}"
ROMS="$(dirname "$OUT")/roms"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
MAME_TAG=mame0289
MAME_BASE=f34f02505e32c1993c6a782b6814232cbfc74e36
PATCHDIR="$HERE/../patches"
PATCHES=(mame-ctlsock.patch mame-drawshm.patch "${NATIVE_EXTRA_PATCHES[@]}")
for p in "${PATCHES[@]}"; do
  [ -f "$PATCHDIR/$p" ] || die "missing patch: $PATCHDIR/$p"
done

# ---------------------------------------------------------------------------
# 1. source tree, pinned and patched
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
cd "$WORK"
if [ ! -d mame/.git ]; then
  say "cloning MAME (--filter keeps a big repo bearable)"
  git clone -q --filter=blob:none "$UPSTREAM" mame
fi
cd mame
git fetch -q --tags origin
git checkout -q "$MAME_TAG"
git reset -q --hard "$MAME_TAG"
git clean -qfd # NOT -x: keeps build objects, so a rebuild is minutes
[ "$(git rev-parse HEAD)" = "$MAME_BASE" ] ||
  die "tag $MAME_TAG is not commit $MAME_BASE (upstream tag moved?)"
# Dry-run each patch IMMEDIATELY BEFORE applying it, never all-then-all: a
# stack may be dependent, so a dry-run of the whole list against the unpatched
# tree would report failures that are not real (irix-mame-stack.sh's rule).
for p in "${PATCHES[@]}"; do
  patch -p1 --dry-run -f <"$PATCHDIR/$p" >/dev/null 2>&1 ||
    die "$p does not apply to $MAME_TAG (after the patches before it)"
  patch -p1 -f <"$PATCHDIR/$p" >/dev/null
  echo "  applied $p"
done

# ---------------------------------------------------------------------------
# 2. build
# ---------------------------------------------------------------------------
CACHE="$(bridge_mame_chroot_for trixie)/ccache"
mame_ccache_prepare_host "$CACHE" "$WORK"
CC_BEFORE="$(mame_ccache_counters "$CACHE")"

say "building MAME $MAME_TAG (SUBTARGET=$NATIVE_SUBTARGET) on the host with $JOBS jobs"
nice -n 5 make SUBTARGET="$NATIVE_SUBTARGET" SOURCES="$NATIVE_SOURCES" \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 "${MAME_MAKE_CC_ARGS[@]}" -j"$JOBS"

[ -x "$WORK/mame/$NATIVE_SUBTARGET" ] || die "build completed without a $NATIVE_SUBTARGET binary"
mame_ccache_report "$CC_BEFORE" "$(mame_ccache_counters "$CACHE")"

mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/$NATIVE_SUBTARGET" "$OUT"
"$OUT" -listxml "$NATIVE_DRIVER" >/dev/null 2>&1 ||
  die "the built binary does not know driver $NATIVE_DRIVER"

# ---------------------------------------------------------------------------
# 3. rompath, then the two framebuffer gates
# ---------------------------------------------------------------------------
say "staging the $STATION rompath"
native_stage_roms "$ROMS"

say "boot gate: the machine must reach its documented scene on the framebuffer"
native_boot_gate "$OUT" "$ROMS" "$WORK/gate"

# The generic size gate stays even though a stanza's boot gate may already read
# the mapping: every stanza gets the byte-count discipline (64 + w*h*4 at the
# station's PUBLISHED geometry) whether or not its scene proof does.
say "drawshm gate: -video shm must publish $NATIVE_GEOM"
SHMDIR="$WORK/shmgate"
rm -rf "$SHMDIR"
mkdir -p "$SHMDIR"
printf 'skip_warnings 1\n' >"$SHMDIR/ui.ini"
(cd "$SHMDIR" && MAME_SHM_PATH="$SHMDIR/fb.shm" MAME_SHM_SIZE="$NATIVE_GEOM" \
  "$OUT" "$NATIVE_DRIVER" -rompath "$ROMS" "${NATIVE_MAME_ARGS[@]}" \
  -video shm -sound none -nothrottle -str 8 -skip_gameinfo \
  -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
  >"$SHMDIR/mame.log" 2>&1) || die "MAME -video shm exited non-zero; see $SHMDIR/mame.log"
GW="${NATIVE_GEOM%x*}"
GH="${NATIVE_GEOM#*x}"
SHMBYTES="$(stat -c %s "$SHMDIR/fb.shm" 2>/dev/null || echo 0)"
[ "$SHMBYTES" = "$((64 + GW * GH * 4))" ] ||
  die "drawshm published $SHMBYTES bytes, expected $((64 + GW * GH * 4)); see $SHMDIR/mame.log"

say "done"
sha256sum "$OUT"
cat <<EOF

Station: $STATION (host-native conversion)
Binary:  $OUT
Source:  MAME $MAME_TAG ($MAME_BASE), SOURCES=$NATIVE_SOURCES
Patches: ${PATCHES[*]}
Rompath: $ROMS
Shm:     $SHMDIR/fb.shm — $SHMBYTES bytes = 64 + ${GW}x${GH}x4
Run it:  $OUT $NATIVE_DRIVER -rompath $ROMS ${NATIVE_MAME_ARGS[*]} -video shm
         with MAME_SHM_PATH/MAME_SHM_SIZE + MAME_CTL_SOCK for the daemon
EOF
