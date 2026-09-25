#!/bin/bash
# =============================================================================
# tiles/nokia9300.sh — stage the host-native nokia9300 station: EKA2L1, the
# Symbian HLE emulator (our fork github.com/Wnt/EKA2L1, branch
# s80-integration, GPL-3), running the Nokia 9300 Communicator's OWN firmware
# (RAE-6, fw 5.22 of 2005-11-16: Symbian OS 7.0s, Series 80 v2). Three outputs,
# ONE combination with the launcher (streamhost/stations/nokia9300/x11-runtime.sh):
#
#   $OUT/eka2l1/      the emulator build: eka2l1_qt + compat/ patch/ resources/
#                     scripts/, made by scripts/build-guests/emulators/
#                     build-eka2l1.sh (pinned fork commit, a trixie build root
#                     under systemd-nspawn, the shared ccache, mold). This
#                     script only calls it with the station's paths.
#   $OUT/rootfs/      the container runtime root that builder makes with
#                     --rootfs (Qt 6 + Mesa runtime closure, Xvfb, xdotool,
#                     x11-utils), uid-shifted to the station's own base.
#   $STATION/golden/  the device data dir — EKA2L1/config.yml and
#                     EKA2L1/data/{devices.yml, roms/rae-6/SYM.ROM,
#                     drives/{c,d,e,z}} — hash-gated against the ledger below.
#                     NEVER in git (Nokia firmware); staged on the box under
#                     $MEDIA. The golden is agent F1's working data dir of
#                     2026-09-24 (the dev-box run that first painted Desk,
#                     Documents, Sheet and Web; agent I2's proof base) plus:
#                     C:\System\SharedData\10000865.ini — the ROM's own default
#                     with LanguageSelectionDone=1, so Startup's first-boot
#                     language wizard (which captures the application keys and
#                     Menu until it completes) never greets a visitor; the four
#                     Series 80 UI TrueType fonts (swabiu/swabru/swariu/swarru
#                     from the S80 DP2.0 SDK's Z: drive) in Z:\system\fonts —
#                     both dumps lack them and the UI falls back to a serif;
#                     machine-uid 0x101F8DDB (the 9300's own) in devices.yml;
#                     config.yml keyboard-layout-index 6 (Nordic, the keyboard
#                     the station's drawing shows) and UPnP off; agent B6's
#                     Desk first-boot state (Shortcuts.dat, desk.ini,
#                     SharedData 101f8e4f.ini); agent L1's Helsinki files in
#                     C:\System\Data (Wldsvr.dat home city Helsinki +120 min,
#                     LOCALE.D00 European date / 24 h / EU summer time,
#                     nitzlookup.db) — the guest wrote them after Clock ›
#                     Change city; without Wldsvr.dat the ROM's New York home
#                     city returns after the first Telephone/Calendar start.
#
# Usage — as root on labhost (debootstrap + systemd-nspawn), e.g. from CT950:
#   scripts/dev/labrun -c 'bash <repo>/scripts/build-guests/tiles/nokia9300.sh --build --rootfs --golden'
#   --build    build + install the emulator (incremental; a cold build is ~25 min
#              — run it detached and poll build-eka2l1.sh's log)
#   --rootfs   also create/top up the runtime root (implies --build)
#   --golden   install the golden data dir from $MEDIA after the hash gate
# env: OUT STATION MEDIA UIDBASE, plus build-eka2l1.sh's own (WORK, JOBS,
#   EKA2L1_FORK_BRANCH, EKA2L1_FORK_PIN).
# =============================================================================
set -euo pipefail

OS_ID=nokia9300
HERE="$(cd "$(dirname "$0")" && pwd)"
EMU_BUILDER="$HERE/../emulators/build-eka2l1.sh"
OUT="${OUT:-/data/vms/streamhost/assets/nokia9300}"
STATION="${STATION:-/data/vms/streamhost/stations/nokia9300}"
MEDIA="${MEDIA:-/data/assets-staging/symbian-s80/nokia9300-golden/xdg}"
# 40 x 65536: `kh-claim uidbase 2621440`, clear of CT 950/951's subuid range
# and of every other contained station (lisa 200000, medley 1966080, ...).
UIDBASE="${UIDBASE:-2621440}"
# The fork commit the station runs — ONE combination with the golden and the
# launch flags: s80-integration (agent I2) = every Series 80 branch of the wave
# merged — window server, app buttons (B1), the ROM's own key tables (K1), the
# museum kiosk frontend + control socket (B2), Desk content (B6), third app
# (B4), HLE DOS (B5), Opera home (N7), icon masks (A1), clock faces (A2).
export EKA2L1_FORK_BRANCH="${EKA2L1_FORK_BRANCH:-s80-integration}"
export EKA2L1_FORK_PIN="${EKA2L1_FORK_PIN:-17801342fdf672ce5a9cc01a37d8ad9aa27ca933}"

# The golden ledger (measured 2026-09-24, docs/guests/nokia9300.md §Golden).
# TREE = sha256 of `find . -type f -print0 | LC_ALL=C sort -z | xargs -0
# sha256sum` run inside $MEDIA.
GOLDEN_FILES=3259
GOLDEN_BYTES=68736107
GOLDEN_TREE_SHA=0462324993200ba2b0e7bf79381cf6bc770f7cc9b1397183b07dd5c462bd8440
ROM_REL=EKA2L1/data/roms/rae-6/SYM.ROM
ROM_BYTES=17825792
ROM_SHA=ca4b0bc929519b046994c8501b0135b688d8d7910d6669f4791805e3ab373596

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

BUILD=0
ROOTFS=0
GOLDEN=0
for a in "$@"; do
  case "$a" in
    --build) BUILD=1 ;;
    --rootfs)
      BUILD=1
      ROOTFS=1
      ;;
    --golden) GOLDEN=1 ;;
    *) die "unknown argument $a (usage: nokia9300.sh [--build] [--rootfs] [--golden])" ;;
  esac
done
[ "$BUILD$GOLDEN" != 00 ] || die "nothing to do — pass --build, --rootfs and/or --golden"

# ---------------------------------------------------------------------------
# the emulator (+ runtime root): delegated to the fork's builder
# ---------------------------------------------------------------------------
if [ "$BUILD" = 1 ]; then
  [ -f "$EMU_BUILDER" ] ||
    die "no $EMU_BUILDER — the EKA2L1 builder lands with agent D1's branch (eka2l1-builder)"
  args=()
  [ "$ROOTFS" = 1 ] && args+=(--rootfs)
  log "EKA2L1: OUT=$OUT RUNROOT=$OUT/rootfs UIDBASE=$UIDBASE ${args[*]}"
  RUNROOT="$OUT/rootfs"
  export OUT RUNROOT UIDBASE
  bash "$EMU_BUILDER" "${args[@]}"
  [ -x "$OUT/eka2l1/eka2l1_qt" ] || die "the builder finished but $OUT/eka2l1/eka2l1_qt is missing"
  if [ "$ROOTFS" = 1 ]; then
    [ "$(stat -c %u "$OUT/rootfs")" = "$UIDBASE" ] ||
      die "$OUT/rootfs is owned by uid $(stat -c %u "$OUT/rootfs"), not the station base $UIDBASE"
    for t in Xvfb xkbcomp xdotool xwininfo; do
      [ -x "$OUT/rootfs/usr/bin/$t" ] || die "the runtime root has no /usr/bin/$t"
    done
  fi
fi

# ---------------------------------------------------------------------------
# the golden data dir: hash gate, then an atomic swap that keeps the previous
# ---------------------------------------------------------------------------
if [ "$GOLDEN" = 1 ]; then
  [ -f "$MEDIA/$ROM_REL" ] || die "no golden data dir at $MEDIA (stage it on the box first)"
  [ "$(stat -c %s "$MEDIA/$ROM_REL")" = "$ROM_BYTES" ] || die "SYM.ROM size mismatch"
  [ "$(sha256sum "$MEDIA/$ROM_REL" | cut -d' ' -f1)" = "$ROM_SHA" ] || die "SYM.ROM sha256 mismatch"
  n="$(find "$MEDIA" -type f | wc -l)"
  b="$(find "$MEDIA" -type f -printf '%s\n' | awk '{s += $1} END {print s}')"
  t="$(cd "$MEDIA" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  [ "$n" = "$GOLDEN_FILES" ] && [ "$b" = "$GOLDEN_BYTES" ] && [ "$t" = "$GOLDEN_TREE_SHA" ] ||
    die "golden ledger mismatch: $n files / $b B / tree $t (want $GOLDEN_FILES / $GOLDEN_BYTES / $GOLDEN_TREE_SHA)"
  log "golden gate ok: $n files, $b B, tree $t"
  mkdir -p "$STATION"
  rm -rf "$STATION/golden.new"
  cp -a "$MEDIA" "$STATION/golden.new"
  chmod -R a+rX "$STATION/golden.new"
  if [ -d "$STATION/golden" ]; then
    rm -rf "$STATION/golden.prev"
    mv "$STATION/golden" "$STATION/golden.prev"
  fi
  mv "$STATION/golden.new" "$STATION/golden"
  log "installed $STATION/golden (previous kept as golden.prev when there was one)"
fi
