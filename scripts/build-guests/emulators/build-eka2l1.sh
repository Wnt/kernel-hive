#!/bin/bash
# =============================================================================
# build-guests/emulators/build-eka2l1.sh — EKA2L1, the Symbian OS emulator, for
# the nokia9300 station (Series 80 v2, Symbian OS 7.0s, the REAL 9300 firmware),
# from a PINNED commit on the Wnt/EKA2L1 fork, compiled inside a Debian trixie
# build root and shipped with the runtime root the station's container uses.
#
# THE FORK AND THE PIN. github.com/Wnt/EKA2L1 (GPL-3; upstream eka2l1/eka2l1),
# branch s80-integration = upstream master 39858137e + every Series 80 branch
# of the 2026-09-24/25 wave, merged and proven on the nokia9300 station (the
# station's own pin lives in tiles/nokia9300.sh, which passes it in the env;
# this default follows it). A trial of another branch sets EKA2L1_FORK_BRANCH
# + EKA2L1_FORK_PIN in the env. The pin is checked out as a LOCAL BRANCH named after the fork branch:
# EKA2L1 bakes `git rev-parse --abbrev-ref HEAD` and `git log -1 --format=%h`
# into common/version.h AT CONFIGURE TIME and logs them at every start
# ("EKA2L1 v0.0.1 (<branch>-<sha>)"). So configure re-runs whenever the pin or
# the flags move (a stale generated header is how es40's binaries came to lie
# about their commit, docs/lab/ES40-FORK-BRIEF.md) and the gate asserts that the
# header and the binary both name the pin.
#
# TWO ROOTS, ONE USERLAND. labhost gets NOTHING installed (no Qt on the
# hypervisor). The build runs under systemd-nspawn in $BUILDROOT, a debootstrap
# trixie tree with the Qt 6 / SDL2 / GTK 3 / Pulse / ALSA -dev set upstream's CI
# installs (.github/workflows/build.yml, job build-desktop). The station runs
# the binary inside $RUNROOT, a minbase trixie tree with only the runtime
# closure + Xvfb (the perq/medley container shape: stations/perq/x11-runtime.sh).
# For every package that provides a library the binary links, the gate asserts
# the runtime root carries the SAME version as the build root: binary + runtime
# root are ONE combination (rule 6), exactly like a golden and its emulator.
#
# NETWORK. The fork's vendored uvw FetchContent-clones libuv from GitHub on every
# fresh configure; FETCHCONTENT_SOURCE_DIR_LIBUV points it at the pinned
# submodule, so configure and build run under --private-network. Only the git
# and apt steps touch the network. No -DCI=ON: that compiles out the api.github
# update check (update_dialog.cpp, BUILD_FOR_USER); the price is the debug log
# preset by default, which config.yml's log-filter overrides.
#
# CACHE (operator rule 2026-09-10: a cold rebuild is a bug). The shared trixie
# ccache (/data/vms/sandbox/trixie-chroot/ccache; scripts/dev/box-ccache-conf.sh)
# is bound at /ccache and the tree at /build/{src,build} with CCACHE_BASEDIR=/build,
# so the host path of $WORK never reaches a hash. The build root's gcc-14 is the
# trixie chroot's; compiler_check=content keeps a drifted compiler from ever
# taking a wrong hit. mold links (1.0 s vs 5.4 s for bfd, measured on CT950).
#
# OUTPUT (NOTHING is restarted; a running emulator keeps its old inode):
#   $OUT/eka2l1/        build/bin — eka2l1_qt + compat/ patch/ resources/ scripts/
#                       + eka2l1.provenance.txt + runtime-packages.txt
#   $OUT/eka2l1.prev/   the previous install; rollback is a mv back
#   $RUNROOT            with --rootfs: the container root, with mount points for
#                       $OUT/eka2l1 (bound read-only at its host path so
#                       /proc/<pid>/exe names the host path), /work and
#                       /tmp/.X11-unix; uid-shifted ONCE to $UIDBASE when set
#
# Usage — as root on labhost (debootstrap + systemd-nspawn), e.g. from CT950:
#   scripts/dev/labrun -c 'bash <repo>/scripts/build-guests/emulators/build-eka2l1.sh --rootfs'
#   --no-install   build + gates only (the package list lands in $WORK/logs)
#   --rootfs       also create/top up $RUNROOT and gate it
#   env: WORK BUILDROOT OUT RUNROOT UIDBASE JOBS EKA2L1_FORK_BRANCH EKA2L1_FORK_PIN
# A cold build is ~31 min on a loaded labhost (1842 s at load 140-180, -j16 nice
# 19; the incremental re-run is ~45 s): run it detached (setsid), poll the log.
# Re-running is incremental: roots are reused (apt only when the package list
# changed), configure only when the pin or the flags changed, ninja resumes.
# =============================================================================
set -euo pipefail

EKA2L1_FORK_URL="${EKA2L1_FORK_URL:-https://github.com/Wnt/EKA2L1.git}"
EKA2L1_FORK_BRANCH="${EKA2L1_FORK_BRANCH:-s80-integration}"
EKA2L1_FORK_PIN="${EKA2L1_FORK_PIN:-4ef4b2fb6d10de4c363b0007ca4376f597b1b23c}"

WORK="${WORK:-/data/vms/sandbox/BUILD-eka2l1}"
BUILDROOT="${BUILDROOT:-$WORK/buildroot}"
OUT="${OUT:-/data/vms/streamhost/assets/nokia9300}"
RUNROOT="${RUNROOT:-$OUT/rootfs}"
UIDBASE="${UIDBASE:-}"
JOBS="${JOBS:-16}"
CCACHE_HOST="${EKA2L1_CCACHE:-/data/vms/sandbox/trixie-chroot/ccache}"
MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
SUITE=trixie
SRC="$WORK/src"
BLD="$WORK/build"
LOGS="$WORK/logs"

# Upstream CI's build-desktop set with the trixie names (Ubuntu's libqt6svg6-dev
# is qt6-svg-dev here), plus the toolchain. Recommends ON, as CI installs them.
BUILD_PKGS=(build-essential cmake ninja-build git pkgconf ccache mold python3 file xz-utils
  libgtk-3-dev libpulse-dev libasound2-dev libsdl2-dev qt6-base-dev qt6-base-private-dev
  qt6-tools-dev qt6-tools-dev-tools qt6-l10n-tools qt6-svg-dev qt6-multimedia-dev)
# dlopened, so never in the NEEDED closure: Qt's xcb platform and SVG plugins,
# Mesa's GLX/EGL + llvmpipe (Xvfb has no GPU), Xvfb itself, a font for Qt's own
# dialogs, and the tools a station launcher and its sandbox audit run inside.
RUN_EXTRA=(qt6-qpa-plugins qt6-svg-plugins libglx-mesa0 libegl-mesa0 libgl1-mesa-dri
  xvfb xauth xdotool x11-utils x11-apps procps iproute2 util-linux fontconfig fonts-dejavu-core)
CMAKE_FLAGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  -DCMAKE_EXE_LINKER_FLAGS=-fuse-ld=mold
  -DEKA2L1_ENABLE_UNEXPECTED_EXCEPTION_HANDLER=ON
  -DEKA2L1_ENABLE_DISCORD_RICH_PRESENCE=OFF
  -DEKA2L1_BUILD_VULKAN_BACKEND=OFF
  -DFETCHCONTENT_SOURCE_DIR_LIBUV=/build/src/src/external/libuv)

say() { printf '\n== %s\n' "$*"; }
die() {
  printf 'build-eka2l1: %s\n' "$*" >&2
  exit 1
}

INSTALL=1
DO_ROOTFS=0
for a in "$@"; do
  case "$a" in
    --no-install) INSTALL=0 ;;
    --rootfs) DO_ROOTFS=1 ;;
    *) die "unknown argument $a (usage: build-eka2l1.sh [--no-install] [--rootfs])" ;;
  esac
done
[ "$(id -u)" = 0 ] && command -v systemd-nspawn >/dev/null && command -v debootstrap >/dev/null ||
  die "run as root on labhost (debootstrap + systemd-nspawn): scripts/dev/labrun -c 'bash $0 $*'"
[ -d "$CCACHE_HOST" ] || die "no shared ccache at $CCACHE_HOST (scripts/dev/box-ccache-conf.sh --check)"
mkdir -p "$WORK" "$LOGS"

# in_root <root> <nspawn options...> <command...> — a throwaway container on
# <root>; a root already uid-shifted (perq-style) is entered in its own range.
in_root() {
  local root="$1" owner users=()
  shift
  owner="$(stat -c %u "$root")"
  [ "$owner" = 0 ] || users=(--private-users="$owner:65536" --private-users-ownership=off)
  systemd-nspawn --quiet --register=no --console=pipe --as-pid2 -D "$root" "${users[@]}" "$@"
}
# in_build <command...> — in the build root: no network, tree at /build, cache at /ccache.
in_build() {
  in_root "$BUILDROOT" --private-network --bind="$WORK:/build" --bind="$CCACHE_HOST:/ccache" \
    --setenv=CCACHE_DIR=/ccache --setenv=CCACHE_BASEDIR=/build "$@"
}
# pkg_versions <root> <pkg>... — "pkg version" per line, from the root's own dpkg db.
pkg_versions() {
  local root="$1"
  shift
  dpkg-query --admindir="$root/var/lib/dpkg" -W -f='${Package} ${Version}\n' "$@"
}
# ccache_counters — "<direct> <preprocessed> <miss>" of the shared cache, for a delta.
ccache_counters() {
  CCACHE_DIR="$CCACHE_HOST" ccache --print-stats 2>/dev/null | awk '
    $1 == "direct_cache_hit" { d = $2 } $1 == "preprocessed_cache_hit" { p = $2 } $1 == "cache_miss" { m = $2 }
    END { printf "%d %d %d\n", d, p, m }'
}

# make_root <dir> <recommends 0|1> <pkg>... — debootstrap once, apt-get only when
# the package list changed (kept in <dir>/.kh-eka2l1-pkgs).
make_root() {
  local dir="$1" rec="$2" want norec="" log
  shift 2
  want="$*"
  log="$LOGS/$(basename "$dir").apt.log"
  [ "$rec" = 1 ] || norec=--no-install-recommends
  if [ ! -x "$dir/usr/bin/apt-get" ]; then
    say "debootstrap $SUITE minbase -> $dir"
    mkdir -p "$(dirname "$dir")"
    debootstrap --variant=minbase --include=ca-certificates "$SUITE" "$dir" "$MIRROR" \
      >"$LOGS/$(basename "$dir").debootstrap.log" 2>&1 || die "debootstrap failed: $LOGS/$(basename "$dir").debootstrap.log"
    printf 'deb %s %s main\ndeb %s %s-updates main\ndeb http://security.debian.org/debian-security %s-security main\n' \
      "$MIRROR" "$SUITE" "$MIRROR" "$SUITE" "$SUITE" >"$dir/etc/apt/sources.list"
  fi
  if [ "$(cat "$dir/.kh-eka2l1-pkgs" 2>/dev/null)" = "$want" ]; then
    echo "  $dir: package set unchanged ($# packages)"
    return 0
  fi
  say "apt-get install into $dir ($# packages)"
  in_root "$dir" /bin/bash -c "apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q $norec $want" \
    >"$log" 2>&1 || {
    tail -20 "$log" >&2
    die "apt-get failed in $dir: $log"
  }
  echo "$want" >"$dir/.kh-eka2l1-pkgs"
}

# ---------------------------------------------------------------------------
# 1. the build root, then the source at the pin
# ---------------------------------------------------------------------------
make_root "$BUILDROOT" 1 "${BUILD_PKGS[@]}"
if [ ! -d "$SRC/.git" ]; then
  say "cloning $EKA2L1_FORK_URL ($EKA2L1_FORK_BRANCH)"
  git clone -q --filter=blob:none --branch "$EKA2L1_FORK_BRANCH" "$EKA2L1_FORK_URL" "$SRC"
fi
GIT=(git -c "safe.directory=$SRC" -C "$SRC")
if [ "$("${GIT[@]}" rev-parse HEAD)" != "$EKA2L1_FORK_PIN" ] ||
  [ "$("${GIT[@]}" rev-parse --abbrev-ref HEAD)" != "$EKA2L1_FORK_BRANCH" ]; then
  "${GIT[@]}" cat-file -e "$EKA2L1_FORK_PIN^{commit}" 2>/dev/null ||
    "${GIT[@]}" fetch -q origin "$EKA2L1_FORK_BRANCH" ||
    die "cannot fetch $EKA2L1_FORK_BRANCH from $EKA2L1_FORK_URL"
  "${GIT[@]}" -c advice.detachedHead=false checkout -q -f -B "$EKA2L1_FORK_BRANCH" "$EKA2L1_FORK_PIN" ||
    die "the pin $EKA2L1_FORK_PIN is not on $EKA2L1_FORK_URL $EKA2L1_FORK_BRANCH"
fi
[ "$("${GIT[@]}" rev-parse HEAD)" = "$EKA2L1_FORK_PIN" ] || die "source tree is not at the pin"
"${GIT[@]}" submodule update --init --recursive --depth 1 --jobs 8 -q || die "submodule update failed"
# lupdate rewrites the tracked .ts catalogues during every build; anything else
# modified means the tree is no longer the pin, and the provenance would lie.
DIRTY="$("${GIT[@]}" status --porcelain --untracked-files=no --ignore-submodules=untracked |
  grep -v ' src/emu/qt/translations/[^/]*\.ts$' || true)"
[ -z "$DIRTY" ] || die "source tree has local changes beyond lupdate's .ts refresh:
$DIRTY"
echo "  source: $SRC at $EKA2L1_FORK_PIN (local branch $EKA2L1_FORK_BRANCH)"

# ---------------------------------------------------------------------------
# 2. configure (only when the pin or the flags moved) and build
# ---------------------------------------------------------------------------
STAMP="$EKA2L1_FORK_PIN ${CMAKE_FLAGS[*]}"
CONFIGURE_S=0
if [ ! -f "$BLD/build.ninja" ] || [ "$(cat "$BLD/.kh-configure" 2>/dev/null)" != "$STAMP" ]; then
  say "configure (Release, ccache, mold, libuv from the submodule, no network)"
  t=$SECONDS
  in_build nice -n 19 cmake -S /build/src -B /build/build "${CMAKE_FLAGS[@]}" >"$LOGS/configure.log" 2>&1 || {
    tail -25 "$LOGS/configure.log" >&2
    die "configure failed: $LOGS/configure.log"
  }
  CONFIGURE_S=$((SECONDS - t))
  echo "$STAMP" >"$BLD/.kh-configure"
fi
say "ninja -j$JOBS eka2l1_qt (nice 19, shared ccache)"
BEFORE="$(ccache_counters)"
t=$SECONDS
in_build nice -n 19 ninja -C /build/build -j"$JOBS" eka2l1_qt >"$LOGS/ninja.log" 2>&1 || {
  tail -30 "$LOGS/ninja.log" >&2
  die "ninja failed: $LOGS/ninja.log"
}
BUILD_S=$((SECONDS - t))
CACHE_LINE="$(awk -v b="$BEFORE" -v a="$(ccache_counters)" 'BEGIN {
  split(b, x, " "); split(a, y, " ")
  hit = (y[1] - x[1]) + (y[2] - x[2]); miss = y[3] - x[3]; n = hit + miss
  if (n <= 0) { print "no compiles this run (up to date)"; exit }
  printf "%d/%d compiles hit (%.1f%%), %d missed", hit, n, 100 * hit / n, miss }')"
echo "  configure ${CONFIGURE_S}s, build ${BUILD_S}s, ccache: $CACHE_LINE"

# ---------------------------------------------------------------------------
# 3. gates: provenance, then the runtime closure
# ---------------------------------------------------------------------------
BIN="$BLD/bin/eka2l1_qt"
[ -x "$BIN" ] || die "ninja finished without $BIN"
# The abbreviation length is git's choice at configure time (8 on this repo), so
# read what was baked and require it to be a prefix of the pin.
VERSION_H="$(find "$BLD" -path '*/common/version.h' -print -quit)"
SHORT="$(sed -n 's/^#define GIT_COMMIT_HASH "\([0-9a-f]*\)"$/\1/p' "$VERSION_H" | head -1)"
BAKED_BRANCH="$(sed -n 's/^#define GIT_BRANCH "\(.*\)"$/\1/p' "$VERSION_H" | head -1)"
[ "${#SHORT}" -ge 7 ] && [ "${EKA2L1_FORK_PIN#"$SHORT"}" != "$EKA2L1_FORK_PIN" ] &&
  [ "$BAKED_BRANCH" = "$EKA2L1_FORK_BRANCH" ] ||
  die "$VERSION_H names '$BAKED_BRANCH-$SHORT', not $EKA2L1_FORK_BRANCH-$EKA2L1_FORK_PIN — stale configure; the provenance would lie"
grep -aqF "$SHORT" "$BIN" || die "$BIN does not carry the pin $SHORT"
BIN_SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"
echo "  provenance ok: EKA2L1 v0.0.1 ($EKA2L1_FORK_BRANCH-$SHORT), sha256 $BIN_SHA"

# The Debian packages that own every library in the binary's NEEDED closure, as
# the BUILD root resolves it (ldd, readlink and dpkg all run inside it: a host
# readlink would resolve the root's symlinks against the host), with the build
# root's versions.
cat >"$LOGS/closure.sh" <<'EOS'
set -euo pipefail
ldd /build/build/bin/eka2l1_qt >/build/logs/buildroot-ldd.txt
awk '/=> \//{ print $3 }' /build/logs/buildroot-ldd.txt | while read -r l; do
  dpkg -S "$l" 2>/dev/null || dpkg -S "$(readlink -f "$l")" 2>/dev/null || echo "UNOWNED: $l"
done | grep -v '^diversion' | cut -d: -f1 | sort -u
EOS
mapfile -t CLOSURE < <(in_build /bin/bash /build/logs/closure.sh)
! grep -q 'not found' "$LOGS/buildroot-ldd.txt" || die "unresolved libraries in the build root: $LOGS/buildroot-ldd.txt"
[ "${#CLOSURE[@]}" -gt 0 ] && ! printf '%s\n' "${CLOSURE[@]}" | grep -q '^UNOWNED' ||
  die "the closure is empty or a linked library belongs to no package in the build root: $LOGS/buildroot-ldd.txt"
pkg_versions "$BUILDROOT" "${CLOSURE[@]}" >"$LOGS/runtime-packages.txt"
echo "  runtime closure: ${#CLOSURE[@]} packages ($(grep -c '=> /' "$LOGS/buildroot-ldd.txt") libraries)"

# ---------------------------------------------------------------------------
# 4. install beside, then swap; keep one previous tree for rollback
# ---------------------------------------------------------------------------
DEST="$OUT/eka2l1"
if [ "$INSTALL" = 1 ]; then
  say "install -> $DEST"
  mkdir -p "$OUT"
  rm -rf "$DEST.new"
  cp -a "$BLD/bin" "$DEST.new"
  cp "$LOGS/runtime-packages.txt" "$DEST.new/runtime-packages.txt"
  {
    echo "built:      $(date -u +%FT%TZ) on $(hostname -s)"
    echo "fork:       $EKA2L1_FORK_URL $EKA2L1_FORK_BRANCH ($EKA2L1_FORK_PIN)"
    echo "reports:    EKA2L1 v0.0.1 ($EKA2L1_FORK_BRANCH-$SHORT)"
    echo "sha256:     $BIN_SHA  eka2l1_qt"
    echo "builder:    scripts/build-guests/emulators/build-eka2l1.sh"
    echo "buildroot:  $BUILDROOT — debian $(cat "$BUILDROOT/etc/debian_version"), $(pkg_versions "$BUILDROOT" gcc-14 qt6-base-dev | tr '\n' ' ')"
    echo "configure:  ${CMAKE_FLAGS[*]}"
    echo "runtime:    runtime-packages.txt (${#CLOSURE[@]} packages; the station root must carry these exact versions)"
    echo "rollback:   mv $DEST.prev $DEST"
  } >"$DEST.new/eka2l1.provenance.txt"
  chmod -R a+rX "$DEST.new"
  if [ -d "$DEST" ]; then
    rm -rf "$DEST.prev"
    mv "$DEST" "$DEST.prev"
  fi
  mv "$DEST.new" "$DEST"
fi

# ---------------------------------------------------------------------------
# 5. --rootfs: the station's container root, the same archive state + closure
# ---------------------------------------------------------------------------
if [ "$DO_ROOTFS" = 1 ]; then
  [ "$INSTALL" = 1 ] || die "--rootfs needs the installed tree (drop --no-install)"
  make_root "$RUNROOT" 0 "${CLOSURE[@]}" "${RUN_EXTRA[@]}"
  say "gate: the runtime root carries the build root's versions"
  pkg_versions "$RUNROOT" "${CLOSURE[@]}" | diff -u "$LOGS/runtime-packages.txt" - >&2 ||
    die "version skew between $BUILDROOT and $RUNROOT (above) — rebuild one of them from the same archive state"
  # --read-only launches cannot create mount points (perq, measured)
  mkdir -p "$RUNROOT$DEST" "$RUNROOT/work" "$RUNROOT/tmp/.X11-unix"
  chmod 1777 "$RUNROOT/tmp/.X11-unix"
  say "gate: every library resolves inside the runtime root"
  in_root "$RUNROOT" --private-network --bind-ro="$DEST" /bin/bash -c \
    "ldd '$DEST/eka2l1_qt' /usr/lib/x86_64-linux-gnu/qt6/plugins/platforms/libqxcb.so" >"$LOGS/runroot-ldd.txt"
  ! grep -q 'not found' "$LOGS/runroot-ldd.txt" || die "unresolved libraries in $RUNROOT: $LOGS/runroot-ldd.txt"
  if [ -n "$UIDBASE" ] && [ "$(stat -c %u "$RUNROOT")" != "$UIDBASE" ]; then
    say "shift $RUNROOT to uid $UIDBASE (once; launches then run --private-users-ownership=off)"
    systemd-nspawn --quiet --register=no -D "$RUNROOT" \
      --private-users="$UIDBASE:65536" --private-users-ownership=chown /bin/true
  fi
  # The combination gate, media-free: in the station's own container shape
  # (read-only root, its uid range, no network) the binary must reach Qt, xcb,
  # a font and Xvfb, and draw EKA2L1's "No device installed" window. Its Xvfb
  # lives on the container's private /tmp, so no host display is involved.
  say "gate: EKA2L1 draws its window inside the runtime root"
  # shellcheck disable=SC2016 # expanded inside the container
  SMOKE='Xvfb :9 -screen 0 1024x768x24 -nolisten tcp -nolisten local >/tmp/xvfb.log 2>&1 &
X=$!
for _ in $(seq 1 80); do [ -S /tmp/.X11-unix/X9 ] && break; sleep 0.25; done
mkdir -p /tmp/h /tmp/d /tmp/c /tmp/k && mkdir -m 700 /tmp/r
export DISPLAY=:9 HOME=/tmp/h XDG_DATA_HOME=/tmp/d XDG_CONFIG_HOME=/tmp/c XDG_CACHE_HOME=/tmp/k XDG_RUNTIME_DIR=/tmp/r QT_QPA_PLATFORM=xcb
"$1/eka2l1_qt" >/tmp/eka2l1.log 2>&1 &
E=$! ok=0
for _ in $(seq 1 240); do
  xdotool search --name "No device installed" >/dev/null 2>&1 && { ok=1; break; }
  kill -0 "$E" 2>/dev/null || break
  sleep 0.5
done
kill -KILL "$E" 2>/dev/null; kill "$X" 2>/dev/null
[ "$ok" = 1 ] && echo "  EKA2L1 window up (uid $(id -u) in the container)" || { tail -20 /tmp/eka2l1.log; exit 1; }'
  in_root "$RUNROOT" --read-only --private-network --tmpfs=/tmp --bind-ro="$DEST" \
    /bin/bash -c "$SMOKE" smoke "$DEST" || die "EKA2L1 did not draw its window inside $RUNROOT"
fi

cat <<EOF

Fork:     $EKA2L1_FORK_URL $EKA2L1_FORK_BRANCH @ $EKA2L1_FORK_PIN
Binary:   $([ "$INSTALL" = 1 ] && echo "$DEST/eka2l1_qt" || echo "$BIN")  sha256 $BIN_SHA
Times:    configure ${CONFIGURE_S}s, build ${BUILD_S}s; ccache $CACHE_LINE
Runtime:  $([ "$DO_ROOTFS" = 1 ] && echo "$RUNROOT (uid $(stat -c %u "$RUNROOT"))" || echo "not built (--rootfs)")
NOTHING WAS RESTARTED. Prove it on the FRAMEBUFFER, never a log.
EOF
