#!/bin/bash
# =============================================================================
# build-guests/emulators/build-es40.sh <station>... — the es40 AlphaServer ES40
# emulator for the two Alpha stations, w2kalpha and tru64, from a PINNED commit
# on the published fork.
#
# WHY THIS EXISTS. Until this script, es40 was the ONLY emulator in the lab with
# no builder: the build was a sentence in a doc (`cd es40src/src && make -j6`)
# run by hand in a scratch directory. The two deployed binaries drifted one
# commit apart in OPPOSITE directions (w2kalpha had a savestate verb tru64
# lacked; tru64 had a pointer-gain fix w2kalpha lacked), neither corresponded to
# any published commit, and BOTH advertised the same stale `ES40_GIT_COMMIT`
# hash — the provenance mechanism existed and lied. See
# docs/lab/ES40-FORK-BRIEF.md.
#
# ONE BUILD SERVES BOTH STATIONS. The binary is byte-identical for w2kalpha and
# tru64 — everything that differs between them is launcher environment
# (ES40_TILE_NAME, ES40_POINTER_GAIN, ports, disks), not compiled code. So this
# script compiles ONCE and installs the same product to each station named on
# the command line. Naming both stations in one run is the supported way to
# converge them.
#
# PROVENANCE IS THE POINT. `configure.ac` declares ES40_GIT_COMMIT as an
# AC_ARG_VAR, so passing it explicitly at configure time bakes the TRUE pin into
# the binary — no reliance on configure guessing from a `git rev-parse` that a
# stale config.h can outlive. The gate then runs the built binary and asserts
# the hash it PRINTS is the pin. That is what makes the recorded provenance a
# fact rather than a claim.
#
# THE SAVESTATE CAVEAT, which is the real risk of ever running this script.
# An es40 savestate is a per-component `fwrite(&state, sizeof(state))` dump
# guarded by magic + version: it is bound to STRUCT LAYOUT, not to the binary.
# es40 has NO binary/savestate guard — it just loads. Crossing commits that only
# touch GUI-layer code (ctlsock registers no saved component) is proven safe and
# keeps each station's golden. A future commit that changes ANY saved
# component's struct WILL orphan both goldens SILENTLY, costing a cold re-bake.
# Read the fork's log before moving ES40_FORK_PIN.
#
# THE SYSROOT IS NOT OPTIONAL AND IS NOT IN THIS REPO. es40 needs SDL3, libpcap
# and pipewire's .pc file (SDL3's pkg-config wants it); labhost has none of them
# installed and deliberately so. They live in a private tree, staged once, never
# installed on the host. Its libdir is also the RUNPATH, matching how both
# production binaries are linked; each station additionally carries a mirror of
# those libraries under <assets>/root/ which its launcher puts on
# LD_LIBRARY_PATH. The install gate below runs the binary under exactly that
# station LD_LIBRARY_PATH, so "the station can actually execute this binary" is
# checked here and not at 03:00 on the gallery floor.
#
# INSTALL IS BACKED UP, NEVER CLOBBERED. Any binary already in place is moved
# aside to es40.bak-<UTC stamp> before the new one lands, and its sha256 is
# recorded in the provenance file. Rollback is a `mv` back.
#
# NOTHING IS RESTARTED. Installing a binary is not deploying it: the running
# emulator holds the old inode and keeps running until the station is restarted,
# which is a station decision. Restart with `systemctl restart streamhost@<x>`
# — which STOPS THE GUEST — deliberately, after reading the station's doc.
#
# Usage:
#   build-es40.sh <station>...          # e.g. build-es40.sh w2kalpha tru64
#   build-es40.sh --no-install <station>...   # build + gate, install nothing
#   JOBS=8 WORK=<dir> ES40_SYSROOT=<dir> ...
# Concurrent agents: pass your own WORK.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "$*" >&2
  exit 1
}

# The pin. 19678ad is the ack-honesty fix: MOVEA was acked OK and then silently
# dropped while the per-connection corner-home paced, which discarded EVERY move
# from a one-shot client (one process per verb is one connection per verb). It
# now latches the target, applies it after the home even if the client has hung
# up, and broadcasts `EV MOVEA <seq> applied <x> <y>`. It also gives this
# wholly lab-authored ctlsock.h the GPL header it never had. Its parent 0a7af85
# is the SAVEST verb, the only way to checkpoint a station while it is being
# served (pumps.py owns es40's first serial socket, so the SRM menu never sees
# the keystrokes). Both are ctlsock-only: GUI layer, no saved component, so the
# goldens survive — see THE SAVESTATE CAVEAT above.
ES40_FORK_URL="${ES40_FORK_URL:-https://github.com/Wnt/es40.git}"
ES40_FORK_BRANCH=main
ES40_FORK_PIN=19678adacaede9be2d8266935c6220d9df37e0b1
SUBMODULE="$REPO_ROOT/third_party/es40"

# Headers and .pc files to compile against; its libdir is also the RUNPATH.
SYSROOT="${ES40_SYSROOT:-/data/vms/soltest/ALPHA-nt/root}"
LIBDIR="$SYSROOT/usr/lib/x86_64-linux-gnu"

ASSETS_ROOT="${ES40_ASSETS_ROOT:-/data/vms/streamhost/assets}"
JOBS="${JOBS:-$(nproc)}"

INSTALL=1
STATIONS=()
for a in "$@"; do
  case "$a" in
    --no-install) INSTALL=0 ;;
    -*) die "unknown option: $a" ;;
    *) STATIONS+=("$a") ;;
  esac
done
[ "${#STATIONS[@]}" -gt 0 ] || die "usage: build-es40.sh [--no-install] <station>... (w2kalpha tru64)"

WORK="${WORK:-/data/vms/sandbox/BUILD-es40}"
SRC="$WORK/es40src"

[ -d "$LIBDIR" ] || die "no es40 build sysroot at $SYSROOT
  es40 needs SDL3, libpcap and pipewire's .pc, none of which are installed on
  labhost. Stage them into a private tree and pass ES40_SYSROOT=<dir>."
for pc in sdl3.pc libpcap.pc; do
  [ -f "$LIBDIR/pkgconfig/$pc" ] || die "sysroot $SYSROOT has no $pc — es40's configure will not find its deps"
done

# ---------------------------------------------------------------------------
# 1. source: the published fork at the pin
# ---------------------------------------------------------------------------
mkdir -p "$WORK"
# SOURCE SELECTION, and why it is not a plain `git clone` from the submodule.
# The submodule is the durability record and the thing .gitmodules pins, so it
# is the preferred source: it makes this build reproducible with no network.
# But this script runs as root on labhost against checkouts a normal user owns,
# and git's ownership check then refuses the submodule's gitdir. That check is
# deliberately NOT satisfiable from `-c safe.directory=` or the GIT_CONFIG_*
# environment on clone's source path (only system/global config counts, by
# design) — so there is no in-script way to whitelist it, and mutating labhost's
# global git config to work around it would be a side effect this build has no
# business having.
#
# So: try the submodule, and if it is unreadable say EXACTLY why and clone the
# same branch from the published fork instead. This is not a silent fallback to
# a different thing — both paths are the same repository, and the pin assertion
# below runs identically either way, so the product is the same commit or the
# build dies. What changes is only whether the network was needed.
if [ ! -d "$SRC/.git" ]; then
  CLONED=""
  if [ -e "$SUBMODULE/.git" ]; then
    say "cloning from the checked-out third_party/es40 submodule"
    # --no-hardlinks is not optional on the box: /data/kernel-hive and /data/vms
    # are separate filesystems, and a plain --local clone dies with
    # "failed to create link ... Invalid cross-device link".
    if git clone -q --local --no-hardlinks "$SUBMODULE" "$SRC" 2>"$WORK/clone.log"; then
      CLONED=submodule
    else
      rm -rf "$SRC"
      echo "  the submodule is present but this user cannot read it as a git repository:" >&2
      sed 's/^/    /' "$WORK/clone.log" >&2
      echo "  falling back to the published fork over the network; the pin is asserted either way." >&2
    fi
  fi
  if [ -z "$CLONED" ]; then
    say "cloning the published fork $ES40_FORK_URL ($ES40_FORK_BRANCH)"
    git clone -q --branch "$ES40_FORK_BRANCH" "$ES40_FORK_URL" "$SRC" ||
      die "could not clone $ES40_FORK_URL, and the submodule was not usable either.
  Check out the submodule (git submodule update --init third_party/es40) as the
  user running this build, or restore network access."
  fi
fi
# $SRC is created by this script, but it may be owned by whoever ran a previous
# build, so its own ownership check still has to be satisfied. That one IS
# reachable from -c, because it is the repository git operates ON, not a clone
# source.
GIT=(git -c "safe.directory=$SRC" -C "$SRC")
"${GIT[@]}" fetch -q origin "+$ES40_FORK_BRANCH:refs/remotes/origin/pin" 2>/dev/null ||
  "${GIT[@]}" fetch -q origin 2>/dev/null || true
"${GIT[@]}" checkout -q "$ES40_FORK_PIN" 2>/dev/null ||
  die "the pinned commit $ES40_FORK_PIN is not in $SRC — is the submodule stale?"
[ "$("${GIT[@]}" rev-parse HEAD)" = "$ES40_FORK_PIN" ] ||
  die "source tree is not at the pin $ES40_FORK_PIN"
# es40 carries its own nested asmjit submodule; the JIT build needs it.
"${GIT[@]}" submodule update --init --recursive -q ||
  die "could not check out es40's nested third_party/asmjit submodule"
echo "  source: $SRC at $ES40_FORK_PIN ($ES40_FORK_BRANCH)"

# ---------------------------------------------------------------------------
# 2. configure — and this is where the honest provenance is made
# ---------------------------------------------------------------------------
[ -x "$SRC/configure" ] || (cd "$SRC" && ./autogen.sh >"$WORK/autogen.log" 2>&1) ||
  die "autogen.sh failed; see $WORK/autogen.log"
# ALWAYS re-run configure, never reuse a config.h from a previous pin. Doing
# exactly that is how both production binaries came to advertise a commit hash
# four pins out of date.
say "configure --enable-asmjit, baking ES40_GIT_COMMIT=$ES40_FORK_PIN"
(
  cd "$SRC" && ./configure --enable-asmjit \
    ES40_GIT_COMMIT="$ES40_FORK_PIN" \
    CC="ccache gcc" CXX="ccache g++" \
    CXXFLAGS="-g -O3" \
    CPPFLAGS="-I$SYSROOT/usr/include" \
    LDFLAGS="-L$LIBDIR -Wl,-rpath,$LIBDIR" \
    PKG_CONFIG_PATH="$LIBDIR/pkgconfig" >"$WORK/configure.log" 2>&1
) || {
  tail -25 "$WORK/configure.log" >&2
  die "configure failed; see $WORK/configure.log"
}
grep -q "define ES40_GIT_COMMIT \"$ES40_FORK_PIN\"" "$SRC/src/config.h" ||
  die "configure did not bake the pin into src/config.h — the provenance would lie again"

# ---------------------------------------------------------------------------
# 3. build. Clean first: one fork commit added a virtual to CDisk, and stale
#    objects across it are vtable-broken — a class of corruption that shows up
#    as a guest crash, not a link error.
# ---------------------------------------------------------------------------
say "building es40 with $JOBS jobs (clean rebuild)"
(cd "$SRC/src" && make clean >/dev/null 2>&1) || true
(cd "$SRC/src" && nice -n 5 make -j"$JOBS" >"$WORK/make.log" 2>&1) || {
  tail -40 "$WORK/make.log" >&2
  die "make failed; see $WORK/make.log"
}
BIN="$SRC/src/es40"
[ -x "$BIN" ] || die "make produced no binary at $BIN"

# ---------------------------------------------------------------------------
# 4. the provenance gate: the binary must SAY it is the pin.
# ---------------------------------------------------------------------------
say "provenance gate: the built binary must report the pin it was built from"
VERSION_LINE="$(LD_LIBRARY_PATH="$LIBDIR" "$BIN" --version 2>&1 | head -1)" ||
  die "the built binary would not run under the sysroot; see $WORK/make.log"
case "$VERSION_LINE" in
  *"$ES40_FORK_PIN"*) ;;
  *) die "the binary reports '$VERSION_LINE', which does not carry the pin $ES40_FORK_PIN.
  This is the exact defect this builder exists to prevent — do not install it." ;;
esac
FEATURES="$(LD_LIBRARY_PATH="$LIBDIR" "$BIN" --version 2>&1 | sed -n 2p)"
for feat in AsmJit SDL PCap; do
  case "$FEATURES" in
    *"$feat"*) ;;
    *) die "the binary lacks the $feat feature ($FEATURES) — a dependency was silently not found at configure time" ;;
  esac
done
BIN_SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"
echo "  $VERSION_LINE"
echo "  $FEATURES"
echo "  sha256 $BIN_SHA"

if [ "$INSTALL" = 0 ]; then
  say "done (--no-install): binary left at $BIN"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. install per station, backing up whatever is there now.
# ---------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
for station in "${STATIONS[@]}"; do
  DEST_DIR="$ASSETS_ROOT/$station"
  [ -d "$DEST_DIR" ] || die "no asset directory for station '$station' at $DEST_DIR"
  STATION_LIBDIR="$DEST_DIR/root/usr/lib/x86_64-linux-gnu"
  [ -d "$STATION_LIBDIR" ] || die "station $station has no library mirror at $STATION_LIBDIR
  Its launcher puts that directory on LD_LIBRARY_PATH; without it the station cannot start es40."

  say "$station: install gate — run the binary under the STATION's own LD_LIBRARY_PATH"
  # This is the check that "it built" cannot make: the station does not run the
  # binary against the build sysroot, it runs it against its own library mirror.
  LD_LIBRARY_PATH="$STATION_LIBDIR" "$BIN" --version >/dev/null 2>&1 ||
    die "$station cannot execute the new binary with LD_LIBRARY_PATH=$STATION_LIBDIR
  $(LD_LIBRARY_PATH="$STATION_LIBDIR" "$BIN" --version 2>&1 | head -3)"
  echo "  runs under $STATION_LIBDIR"

  OLD_SHA="(none — no binary was installed)"
  if [ -e "$DEST_DIR/es40" ]; then
    OLD_SHA="$(sha256sum "$DEST_DIR/es40" | cut -d' ' -f1)"
    cp -a "$DEST_DIR/es40" "$DEST_DIR/es40.bak-$STAMP"
    echo "  backed up the running binary to es40.bak-$STAMP (sha256 $OLD_SHA)"
  fi
  # Write beside, then rename: an atomic replace never leaves a half-copied
  # binary where the launcher expects one.
  install -m 0755 "$BIN" "$DEST_DIR/es40.tmp-$STAMP"
  mv -f "$DEST_DIR/es40.tmp-$STAMP" "$DEST_DIR/es40"
  (cd "$DEST_DIR" && sha256sum es40 >es40.sha256)
  {
    echo "built:      $STAMP on $(hostname)"
    echo "station:    $station"
    echo "fork:       $ES40_FORK_URL $ES40_FORK_BRANCH ($ES40_FORK_PIN)"
    echo "builder:    scripts/build-guests/emulators/build-es40.sh"
    echo "configure:  --enable-asmjit CXXFLAGS='-g -O3' ES40_GIT_COMMIT=$ES40_FORK_PIN"
    echo "sysroot:    $SYSROOT (SDL3, libpcap, pipewire .pc; also the RUNPATH)"
    echo "reports:    $VERSION_LINE"
    echo "features:   $FEATURES"
    echo "sha256:     $BIN_SHA"
    echo "replaced:   $OLD_SHA"
    echo "rollback:   mv $DEST_DIR/es40.bak-$STAMP $DEST_DIR/es40  (then restart the station)"
    echo "why:        docs/lab/ES40-FORK-BRIEF.md"
  } >"$DEST_DIR/es40.provenance.txt"
  echo "  installed $DEST_DIR/es40"
done

cat <<EOF

Stations: ${STATIONS[*]}
Source:   $ES40_FORK_URL $ES40_FORK_BRANCH @ $ES40_FORK_PIN
Binary:   sha256 $BIN_SHA
Reports:  $VERSION_LINE

NOTHING WAS RESTARTED. The running emulator still holds the old inode. Each
station picks the new binary up only on its next start:
  systemctl restart streamhost@<station>     # this STOPS THE GUEST
Then prove it on the FRAMEBUFFER, never a log: the golden restores, and a
one-shot MOVEA lands where it says.
EOF
