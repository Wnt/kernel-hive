#!/bin/bash
# =============================================================================
# build-guests/emulators/build-mame-atarist.sh — the Atari ST MAME binary for
# the de-bridging spike, built HOST-NATIVE, plus the ROM path it needs and a
# framebuffer gate that proves the machine reaches the GEM desktop.
#
# WHAT THIS IS FOR. The spike runs ONE MAME ST binary two ways — inside the
# Debian bridge kiosk (tier 2) and on the bare host (tier 3, the irix shape) —
# and measures the latency difference. The Atari ST is the machine that makes
# that comparison worth anything: a real WIMP desktop with a MOUSE, booting from
# ROM with no disk install, so the arms differ only in where the emulator runs.
#
# WHY THERE IS NO CHROOT HERE, unlike build-mame-{bbcb,zx81,kc854,…}.sh. Those
# build inside an ABI-matched chroot because the bridge guest was bookworm while
# the host was trixie. Since the 2026-08-10 migration the atarist suite IS
# trixie (registry/bridge-suites.json) and so is the host: same glibc 2.41, same
# gcc 14, byte-identical compiler binaries. One host build therefore serves both
# arms, and the assertion below FAILS THE BUILD if that ever stops being true
# rather than shipping a binary that dies in the guest with GLIBC_2.xx not
# found. Proven 2026-08-10: this binary's six probe framebuffers are md5-
# identical run on the host and run inside a trixie bridge guest.
#
# PIN: tag `mame0289` == f34f02505e32c1993c6a782b6814232cbfc74e36, the same
# release every other MAME tile ships. A version bump would re-open the romset
# revalidation problem that makes sinclairql/zxspectrum the hardest tiles in the
# fleet, for no gain the spike can use.
#
# SOURCES is the single file src/mame/atari/atarist.cpp, not the directory. The
# bbcb builder takes a directory because the BBC driver is split across four
# files; the ST is not — atarist.cpp is the only driver file, and its devices
# (atarist_v, ataristb, stkbd, stmmu, stvideo) come in through the dependency
# walker off its own #includes. src/mame/atari/ holds 179 .cpp files, nearly all
# of them unrelated Atari ARCADE drivers, so the directory form would be the
# opposite of narrow. 36 ST-family machines result; the tile wants `st`.
#
# TWO ROMS, AND ONLY ONE OF THEM IS CLEAN:
#   * TOS — EmuTOS, GPLv2, no Atari copyright material. The 192 KB image, NOT
#     the etos1024k.img the bridge base already carries for hatari: MAME's ST
#     maps a 0x30000 TOS region, so the 1 MB image cannot be loaded at all.
#     Placed as tos100.bin; MAME warns WRONG CHECKSUM and runs, which is why the
#     skip-warnings patch below is not optional.
#   * IKBD — the 4 KB HD6301 keyboard-controller firmware, `keyboard.u1`. It is
#     Atari's, there is no free reimplementation as a 6301 image (the open IKBD
#     projects either run this same ROM or reimplement the behaviour on other
#     silicon), and MAME 0.289's ST has no HLE keyboard path: without it the
#     machine refuses to start, and with a placeholder it boots to a desktop
#     whose mouse and keyboard are dead. So the ST-on-MAME exhibit is NOT
#     licence-clean the way the hatari one is — hatari HLEs the IKBD in C and
#     needs no such ROM. This is the same category as the Amiga Kickstart the
#     bridge base already fetches: copyrighted, freely fetchable at a pinned
#     URL, hash-gated, and NEVER committed to this repo.
#
# The warning-suppression patch is the one the IRIX/BBC/KC builds already use.
# Every ST machine in 0.289 is MACHINE_NOT_WORKING, so the startup WARNINGS
# stage always fires, `-skip_gameinfo` does not suppress it, and an unpatched
# binary makes the exhibit a red panel for ever. `skip_warnings` is a UI option:
# it goes in ui.ini, and `-skip_warnings` on the command line is rejected.
#
# Usage:
#   build-mame-atarist.sh [work-dir] [output-binary]
#   MAME_CCACHE=0 build-mame-atarist.sh          # no cache, cold compile
#   JOBS=8 build-mame-atarist.sh                 # cap parallelism on a busy box
# Concurrent agents: pass your own work-dir. The default is stable on purpose so
# a rebuild is incremental, which means two runs would share a tree.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/bridge-suite.sh"
# shellcheck disable=SC1091
. "$HERE/mame-ccache.sh"

SUITE="$(bridge_suite_for atarist)"
WORK="${1:-/data/vms/soltest/BUILD-atarist-mame}"
OUT="${2:-/data/vms/streamhost/assets/atarist-mame/mame/atarist}"
STAGING="${ASSET_STAGING:-/data/assets-staging}/atarist-mame"
ROMS="$WORK/roms"
UPSTREAM="${MAME_GIT_URL:-https://github.com/mamedev/mame.git}"
JOBS="${JOBS:-$(nproc)}"
MAME_TAG=mame0289
MAME_ATARIST_BASE=f34f02505e32c1993c6a782b6814232cbfc74e36
PATCH="$HERE/../patches/mame-irix-skip-warnings.patch"

# EmuTOS 1.4, the latest stable release. The bridge base carries 1.3's 1024k
# image for hatari; these are different files for different ROM windows, not a
# version conflict to reconcile.
EMUTOS_URL="https://sourceforge.net/projects/emutos/files/emutos/1.4/emutos-192k-1.4.zip/download"
EMUTOS_ZIP_SHA=59abac06a2d29b0864c5a7cfb2af65f022c337aed34188e174a9a08cc737e4bc
EMUTOS_IMG=etos192us.img
EMUTOS_IMG_SHA=8fbbf8b44fc3e34281eaf8cda5265510e9af9ccda0e3e409111648060d244cfc
# Pinned at a COMMIT, not a branch: the sha256 gate would catch a swap anyway,
# but a moving `master` turns that catch into a build failure nobody expects.
IKBD_URL="https://raw.githubusercontent.com/harbaum/ikbd/efa010982a264275d33f477d202a25b21d4a07bd/rom/IKBD.ROM"
IKBD_SHA=b2c5c61bac3dbd563206ddf4a4bca14db6d95575fe6892e59fff621e5205311f

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "$*" >&2
  exit 1
}

# fetch_pinned <url> <dest> <sha256> — fetch once into the staging dir and gate
# on the hash every run, so a mirror that starts serving something else is a
# build failure and not a silently different exhibit.
fetch_pinned() {
  local url="$1" dest="$2" want="$3" have
  if [ ! -f "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    curl -fsSL --retry 3 --max-time 300 -o "$dest" "$url" ||
      die "could not fetch $(basename "$dest") from $url"
  fi
  have="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$have" = "$want" ] || die "$dest sha256 $have, expected $want"
}

# ---------------------------------------------------------------------------
# 0. the premise: host and bridge guest must be the same Debian generation
# ---------------------------------------------------------------------------
WANT_DEB="$(bridge_debian_version_for "$SUITE")"
HAVE_DEB="$(cut -d. -f1 </etc/debian_version 2>/dev/null || true)"
[ "$HAVE_DEB" = "$WANT_DEB" ] || {
  echo "atarist is on suite '$SUITE' (Debian $WANT_DEB) but this host is Debian '${HAVE_DEB:-?}'." >&2
  echo "  A host-native build only serves both spike arms while those agree." >&2
  echo "  Build in the suite's chroot instead: $(bridge_mame_chroot_for "$SUITE")" >&2
  exit 1
}
[ -f "$PATCH" ] || die "missing warning-suppression patch: $PATCH"

# ---------------------------------------------------------------------------
# 1. source tree, pinned and patched
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
install -m 644 "$PATCH" "$WORK/mame-skip-warnings.patch"
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
[ "$(git rev-parse HEAD)" = "$MAME_ATARIST_BASE" ] ||
  die "tag $MAME_TAG is not commit $MAME_ATARIST_BASE (upstream tag moved?)"
patch -p1 --dry-run -f <../mame-skip-warnings.patch >/dev/null 2>&1 ||
  die "warning-suppression patch does not apply to $MAME_TAG"
patch -p1 -f <../mame-skip-warnings.patch >/dev/null

# ---------------------------------------------------------------------------
# 2. build
# ---------------------------------------------------------------------------
CACHE="$(bridge_mame_chroot_for "$SUITE")/ccache"
mame_ccache_prepare_host "$CACHE" "$WORK"
CC_BEFORE="$(mame_ccache_counters "$CACHE")"

say "building MAME $MAME_TAG (SUBTARGET=atarist) on the host with $JOBS jobs"
nice -n 5 make SUBTARGET=atarist SOURCES=src/mame/atari/atarist.cpp \
  NOWERROR=1 USE_QTDEBUG=0 REGENIE=1 "${MAME_MAKE_CC_ARGS[@]}" -j"$JOBS"

[ -x "$WORK/mame/atarist" ] || die "build completed without an atarist binary"
mame_ccache_report "$CC_BEFORE" "$(mame_ccache_counters "$CACHE")"

mkdir -p "$(dirname "$OUT")"
install -m 755 "$WORK/mame/atarist" "$OUT"
"$OUT" -listxml st >/dev/null 2>&1 || die "the built binary does not know driver st"

# ---------------------------------------------------------------------------
# 3. ROM path
# ---------------------------------------------------------------------------
say "staging the ST rompath"
fetch_pinned "$EMUTOS_URL" "$STAGING/emutos-192k-1.4.zip" "$EMUTOS_ZIP_SHA"
fetch_pinned "$IKBD_URL" "$STAGING/keyboard.u1" "$IKBD_SHA"
if [ ! -f "$STAGING/$EMUTOS_IMG" ]; then
  (cd "$STAGING" && unzip -o -q emutos-192k-1.4.zip &&
    find . -name "$EMUTOS_IMG" -exec cp {} "$STAGING/$EMUTOS_IMG" \;)
fi
[ -f "$STAGING/$EMUTOS_IMG" ] || die "EmuTOS zip fetched but $EMUTOS_IMG not found inside it"
have="$(sha256sum "$STAGING/$EMUTOS_IMG" | cut -d' ' -f1)"
[ "$have" = "$EMUTOS_IMG_SHA" ] || die "$EMUTOS_IMG sha256 $have, expected $EMUTOS_IMG_SHA"
mkdir -p "$ROMS/st"
install -m 644 "$STAGING/$EMUTOS_IMG" "$ROMS/st/tos100.bin"
install -m 644 "$STAGING/keyboard.u1" "$ROMS/st/keyboard.u1"

# ---------------------------------------------------------------------------
# 4. framebuffer gate — the binary must reach the GEM desktop, not a log line
# ---------------------------------------------------------------------------
# The ST-medium GEM desktop background is a 50% dither of pure #00FF00 and
# covers ~28% of the frame. EmuTOS's boot screen and the MACHINE_NOT_WORKING
# warnings panel carry ZERO lime pixels, and so does a black or stalled frame,
# so "at least 15% lime" separates the desktop from every way this can fail.
say "boot gate: 35 s headless run, snapshot at the desktop"
GATE="$WORK/gate"
rm -rf "$GATE"
mkdir -p "$GATE/snap"
printf 'skip_warnings 1\n' >"$GATE/ui.ini"
cat >"$GATE/gate.lua" <<'LUA'
local n = 0
_G.gate_sub = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n == 1800 then manager.machine.video:snapshot() end
end)
LUA
(cd "$GATE" && "$OUT" st -rompath "$ROMS" \
  -video none -sound none -nothrottle -str 32 -skip_gameinfo \
  -homepath . -cfg_directory ./cfg -nvram_directory ./nvram \
  -snapshot_directory ./snap -inipath . -autoboot_script ./gate.lua \
  >"$GATE/mame.log" 2>&1) || die "MAME exited non-zero; see $GATE/mame.log"
SHOT="$(find "$GATE/snap" -name '*.png' | sort | head -1)"
[ -n "$SHOT" ] || die "boot gate produced no snapshot; see $GATE/mame.log"
# Two `convert` calls rather than one `read -r W H`: ImageMagick prints -format
# output with NO trailing newline, so `read` hits EOF, returns 1, and `set -e`
# kills the build silently right where it was about to say whether the exhibit
# works. A gate that dies without a word is worse than no gate.
W="$(convert "$SHOT" -format '%w' info:-)"
H="$(convert "$SHOT" -format '%h' info:-)"
LIME="$(convert "$SHOT" -format '%c' histogram:info:- |
  awk '/#00FF00/ { gsub(/:/, "", $1); print $1; exit }')"
LIME="${LIME:-0}"
awk -v l="$LIME" -v n="$((W * H))" 'BEGIN { exit !(n > 0 && l / n >= 0.15) }' || {
  echo "boot gate FAILED: only $LIME/$((W * H)) lime pixels in $SHOT" >&2
  echo "  the machine did not reach the GEM desktop — look at that PNG, not the log." >&2
  exit 1
}

say "done"
sha256sum "$OUT"
cat <<EOF

Binary:  $OUT
Source:  MAME $MAME_TAG ($MAME_ATARIST_BASE), SOURCES=src/mame/atari/atarist.cpp
Patch:   $(basename "$PATCH")
Rompath: $ROMS  (st/tos100.bin = EmuTOS 1.4 192k, st/keyboard.u1 = Atari IKBD)
Gate:    $SHOT — $LIME/$((W * H)) lime pixels, GEM desktop reached
Run it:  $OUT st -rompath $ROMS -inipath <dir-with-ui.ini> -skip_gameinfo
EOF
