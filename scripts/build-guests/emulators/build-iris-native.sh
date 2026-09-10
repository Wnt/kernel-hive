#!/bin/bash
# =============================================================================
# build-guests/emulators/build-iris-native.sh — HOST-NATIVE Iris for the
# de-bridged `indyr4400` station (docs/lab/IRIS-DEBRIDGE-BRIEF.md, stream A).
#
# WHAT CHANGES FROM THE BRIDGE BUILDER. scripts/build-guests/tiles/indyr4400.sh
# builds iris to be COPIED INTO A DEBIAN KIOSK, which is why it has two paths:
# a bookworm debootstrap chroot (so the binary links against the frozen kiosk's
# glibc 2.36) and, on the trixie suite, a direct host build. This script has one
# path and no chroot at all, because the binary it emits runs ON THE HOST and
# only on the host — deleting the kiosk is the whole point of the conversion
# (AGENTS.md rule 13). It also retires one of the last bookworm ABI chroot
# customers.
#
# WHAT THE FORK ADDS. `Wnt/iris` is `techomancer/iris` (BSD-3) plus the three
# knob-gated planes a host-native station needs, none of which upstream has:
#
#   frames   src/shmpub.rs — a rex3::Renderer installed on the NO-WINDOW branch
#            that composites with the CPU SwCompositor and publishes IFB1 into
#            $IRIS_SHM_PATH. Upstream installs a renderer in exactly one place
#            (src/ui.rs, windowed only), so with no window nothing composites
#            at all and `--ci`'s "rendering to offscreen buffer" banner is not
#            true.
#   input    a mamectl/1 listener on $IRIS_CTL_SOCK driving Ps2::push_kb /
#            push_mouse_input (stream C).
#   reset    the snapshot stack's ci_rollback/ci_restore exposed on that same
#            socket (stream D).
#
# Every one is gated on its own env knob, so with the knobs unset this binary
# is behaviourally identical to upstream at $IRIS_COMMIT and the live station
# can keep running off it until cutover.
#
# THE ENV THE STATION MUST SET (measured on the iris-a rig, 2026-09-10):
#
#   IRIS_SHM_PATH=<station>/run/fb.shm   frames; unset = no frame plane at all
#   IRIS_SHM_GEOMETRY=1280x1024          REQUIRED. The VC2 decode settles at
#                                        1282x1024 and the registry declares
#                                        1280x1024; the consumer has no crop
#                                        knob, so the crop is decided here.
#                                        The two discarded columns are real
#                                        right-edge overscan, NOT black padding.
#   IRIS_CTL_SOCK=<station>/run/ctl.sock input (mamectl/1)
#   SH_SHM_DAMAGE=0                      station-side: the producer publishes a
#                                        REAL scanline band, so the daemon must
#                                        not re-derive one
#
# And the flag: --no-window, NOT --ci. --ci also swaps the SCC serial backends
# and redirects every overlay=true disk to /tmp/iris-ci-<pid>-scsiN.overlay,
# which makes EVERY launch a cold first boot -- on IRIX that is the ~7-minute
# autoconfig relink and the reboot after it, every single time. Measured: 247 s
# from the relink notice to the graphical login on the first launch, and 0 s on
# the next one once the COW overlay was station-local. The ci control socket is
# still available alongside --no-window by naming it with --ci-socket.
#
# THE TOOLCHAIN IS PINNED ON THE FORK, NOT HERE. Upstream's rust-toolchain.toml
# says `channel = "nightly"` with no date — a MOVING input, and in this lab the
# emulator binary is one third of every checkpoint (golden + binary + device set
# are ONE combination, rule 6), so an unpinned compiler makes a rebuild
# unreproducible and can orphan saved state. The fork pins a dated nightly and
# rustup honours it automatically from the checkout; this script only records
# which one it actually used.
#
# FEATURES: lightning,rex-jit,chd,jitv2.
#   jitv2   the measured 4x CPU win (a fixed workload: 8.4 s -> 1.95 s) and it
#           boots IRIX; the old 43d2715 wedge is gone.
#   chd     the disk backend the golden bake needs.
#   The set is part of the provenance triple: iris's own snapshot.toml records
#   the cargo feature list and REFUSES a restore that does not match it, so
#   changing this line invalidates every golden.
#
# HYGIENE: touches only its own work dir and the output path. No chroot, no
# mounts, no station directory, no kills. Idempotent; --force re-clones.
#
# Usage:
#   build-iris-native.sh [output-binary] [work-dir]
#   IRIS_COMMIT=<sha> ...   # override the pin (records what it built)
#   FORCE=1 ...             # re-clone instead of fetching into an existing tree
#   JOBS=8 ...              # cap parallelism
# Concurrent agents: pass your own work-dir; the default is stable on purpose so
# a rebuild is incremental.
# =============================================================================
set -euo pipefail

IRIS_REPO="${IRIS_REPO:-https://github.com/Wnt/iris}"
# Pinned. The fork branch kh-native; bump deliberately, never by drift.
IRIS_COMMIT="${IRIS_COMMIT:-kh-native}"
IRIS_FEATURES="${IRIS_FEATURES:-lightning,rex-jit,chd,jitv2}"

OUT="${1:-/data/vms/streamhost/assets/indyr4400/iris}"
WORK="${2:-/data/vms/sandbox/iris-native-build}"
FORCE="${FORCE:-0}"

say() { printf '\n== [iris-native %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() {
  echo "build-iris-native: $*" >&2
  exit 1
}

command -v cargo >/dev/null || die "no cargo on this host — install rustup"
command -v git >/dev/null || die "no git on this host"

case "$OUT" in
  /data/vms/streamhost/stations/*)
    die "refusing to write into a live station dir: $OUT (assets live under /data/vms/streamhost/assets/)"
    ;;
esac

# ---- source ----------------------------------------------------------------
if [ "$FORCE" = 1 ]; then rm -rf "$WORK"; fi
if [ -d "$WORK/.git" ]; then
  say "fetching $IRIS_REPO into existing tree $WORK"
  git -C "$WORK" remote set-url origin "$IRIS_REPO"
  git -C "$WORK" fetch --quiet --tags origin
else
  say "cloning $IRIS_REPO -> $WORK"
  rm -rf "$WORK"
  git clone --quiet "$IRIS_REPO" "$WORK"
fi
git -C "$WORK" checkout --quiet --detach "origin/$IRIS_COMMIT" 2>/dev/null ||
  git -C "$WORK" checkout --quiet --detach "$IRIS_COMMIT" ||
  die "cannot check out $IRIS_COMMIT"
SHA="$(git -C "$WORK" rev-parse HEAD)"
say "building iris ${SHA:0:7} features=$IRIS_FEATURES"

# ---- build -----------------------------------------------------------------
(
  cd "$WORK"
  # Keep this build's artifacts local so two concurrent emulator builds cannot
  # fight over one target tree. NOTE: `unset CARGO_TARGET_DIR` is NOT enough on
  # this box -- /root/.cargo/config.toml sets `[build] target-dir` to the shared
  # streamhost tree, and a config value applies precisely when the env var is
  # absent. It has to be SET, because the env wins over the config file.
  # (scripts/build-guests/tiles/indyr4400.sh's build_iris_native unsets it and
  # then installs from ./target/release/iris, which on this box is a path that
  # does not exist.)
  export CARGO_TARGET_DIR="$WORK/target"
  # rustup reads the fork's pinned rust-toolchain.toml from this directory and
  # installs the dated nightly if it is missing. Record what it resolved to.
  say "toolchain: $(rustc --version) (pin: $(grep -oP 'channel\s*=\s*"\K[^"]+' rust-toolchain.toml))"
  if [ -n "${JOBS:-}" ]; then
    cargo build --release --features "$IRIS_FEATURES" -j "$JOBS"
  else
    cargo build --release --features "$IRIS_FEATURES"
  fi
)

BIN="$WORK/target/release/iris"
[ -x "$BIN" ] || die "cargo reported success but $BIN is missing"

# The frame plane is the reason this builder exists; a binary without it would
# start, log nothing unusual, and stream a black screen forever. Assert the
# symbol is in there before installing it.
# Substring, not a whole-line match: rustc packs string literals end to end with
# no NUL between them, so IRIS_SHM_PATH shares a `strings` line with its
# neighbours and `grep -x` finds nothing in a binary that has it.
strings -a "$BIN" | grep -q 'IRIS_SHM_PATH' ||
  die "$BIN has no IRIS_SHM_PATH knob — that is upstream, not the fork"

install -d -m 0755 "$(dirname "$OUT")"
# Write beside the target and rename: a station may be running off $OUT, and
# overwriting a live binary in place makes /proc/<pid>/exe read "(deleted)",
# which is exactly what breaks the launcher's kill sweep.
install -m 0755 "$BIN" "$OUT.new"
mv -f "$OUT.new" "$OUT"

say "installed $OUT"
printf '  commit    %s\n' "$SHA"
printf '  features  %s\n' "$IRIS_FEATURES"
printf '  toolchain %s\n' "$(cd "$WORK" && rustc --version)"
printf '  md5       %s\n' "$(md5sum "$OUT" | cut -d' ' -f1)"
printf '  size      %s bytes\n' "$(stat -c %s "$OUT")"
