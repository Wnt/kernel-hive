#!/bin/bash
# =============================================================================
# build-guests/emulators/build-vice-native.sh <station> — HOST-NATIVE VICE for
# a de-bridged Commodore station. The VICE wave's answer to
# build-mame-native.sh, same shape: ONE engine, per-station stanzas under
# vice-native.d/<station>.sh, so the seven stations (vic20, plus4, pet2001,
# cbm8032, cbm2, c128, c64) share every line that is not machine-specific.
#
# A stanza sets:
#
#   VICE_EMU            the emulator binary the station runs (xvic, xpet, ...)
#   VICE_DATA_DIRS      data/ subdirectories the station needs staged (ROMs,
#                       palettes and the .vkm keymaps VICE resolves keysyms
#                       through). "common" and "DRIVES" are added always.
#   VICE_ROM_REQUIRED   array of <subdir>/<file> the gate must find, so a
#                       silently-empty ROM staging fails HERE and not at 03:00
#                       on the gallery floor
#   VICE_GATE_ARGS      array; the machine flags the exhibit runs with. THIS
#                       IS ALSO WHAT DECIDES THE PUBLISHED GEOMETRY — VICE has
#                       no MAME_SHM_SIZE equivalent: the surface IS the
#                       emulated screen times <CHIP>DoubleSize (and Filter).
#   VICE_GATE_SHM_CHIP  optional; which canvas publishes, for a machine that has
#                       more than one (x128: VICII + VDC). Unset means "whichever
#                       claims the mapping first", which is the only correct
#                       answer for a single-canvas machine and the WRONG one for
#                       the C128 — measured, not feared. Must match the station
#                       fixture's VICE_NATIVE_SHM_CHIP, or the gate measures a
#                       different screen than the exhibit publishes.
#   VICE_GATE_FLOOR     lit-pixel floor for the non-black boot gate
#   VICE_GATE_INK_FLOOR non-dominant-pixel floor for the same gate. A VIC-20
#                       power-on page is WHITE: "not black" passes on a frame
#                       that is one flat colour, so the scene needs a second,
#                       structural floor.
#   VICE_GATE_CYCLES    emulated cycles before the gate run exits
#   VICE_GEOM_EXPECT    optional WxH; when set the gate asserts the measured
#                       geometry matches, so a resource change cannot silently
#                       move a live station's surface
#   VICE_GATE_BBOX      optional y0:y1:x0:x1; when set the non-dominant pixels
#                       must all fall INSIDE that rectangle. cbm2's bridged
#                       builder gated on position for a reason worth keeping:
#                       a count alone cannot tell a correctly framed banner
#                       from one drawn at the wrong offset. Containment, not
#                       equality — the blinking cursor is inside the box on
#                       some frames and gone on others.
#   vice_stage_extra <outdir>   optional hook for media (c128's CP/M disk)
#
# ONE BUILD SERVES THE WAVE. `make install` takes prefix= on the command line
# (plain automake), so a second station can point the SAME work dir at its own
# output tree and skip the compile entirely — pass the same [work-dir] and a
# different station. The prefix baked into the binary at compile time is inert:
# the launcher and this gate both pass `-directory` explicitly.
#
# UNLIKE THE MAME BUILDER THERE ARE NO LOOSE PATCHES. Every kernel-hive change
# to VICE is a commit on the published fork (github.com/Wnt/vice, branch
# kernel-hive/integrated, ten commits on upstream tag 3.10.0), carried as the
# third_party/vice-kernel-hive submodule. Note the tag has NO leading `v`, and
# the VICE mirror tags every SVN revision as rNNNNN, so a --depth 1 clone will
# NOT contain it — this script never shallow-clones.
#
# Three things this build needs that the box does not ship, all satisfied
# INSIDE the work dir, never installed on labhost:
#   * dos2unix — a 3-line sed shim is all configure wants
#   * xa65     — Debian's package installs the assembler as `xa`, and VICE's
#                configure looks for `xa65`: hence `ln -sf xa bin/xa65`
#   * the ROMs — `make install` SKIPS data/*/ ROM files, so they are staged
#                from the source tree by hand (§stage) and gated by name
#
# NO CHROOT: the binary runs on the host and only on the host, which is the
# whole point of de-bridging.
#
# Usage:
#   build-vice-native.sh <station> [work-dir] [output-dir]
#   JOBS=8 ...   # cap parallelism
# Concurrent agents: pass your own work-dir.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "$*" >&2
  exit 1
}

# The pin. Ten commits on upstream tag 3.10.0 (4d283a2e7dd59b7e378524878e81
# ecc7826b700c): shmfb (3), vicectl (6) and the CRTC restore fix. The four from
# 2026-08-17 are the two key-order defects (a release outranks a deferred
# press; a modifier is a barrier in both directions), the checkpoint pair —
# CRTC canvas growth on restore, and SAVEST/LOADST from a CPU trap — and
# VICE_SHM_CHIP, which lets a two-canvas machine (x128: VICII + VDC) CHOOSE the
# published chip instead of racing for it.
VICE_FORK_URL="${VICE_FORK_URL:-https://github.com/Wnt/vice.git}"
VICE_FORK_BRANCH=kernel-hive/integrated
VICE_FORK_PIN=507cf3e8323ab11feec96258f78832060a558e79
SUBMODULE="$REPO_ROOT/third_party/vice-kernel-hive"

# ---------------------------------------------------------------------------
# Shared smoke gate for stanzas: run the station's own machine headless with
# the shm publisher on, MEASURE the published geometry (there is nothing to
# assert it against a priori — see VICE_GATE_ARGS above), and assert the
# mapping is the right size for that geometry and is not black.
#   vice_gate_nonblack <bin> <datadir> <gatedir>
# Sets GATE_GEOM / GATE_LIT for the caller to report.
# ---------------------------------------------------------------------------
vice_gate_nonblack() {
  local bin="$1" data="$2" gate="$3"
  rm -rf "$gate"
  # THE LANDMINE: a headless VICE whose stdout is not a tty segfaults in
  # vice_banner() (log_helper hands NULL colour-stripped strings to
  # log_archdep) unless its log file can be opened, and -logfile does not save
  # you because the banner runs FIRST. VICE creates $HOME/.cache and
  # $HOME/.config itself but NOT $HOME/.local/state. Every fresh HOME — a gate
  # dir here, a per-station dir in the launcher — walks straight into it.
  mkdir -p "$gate/home/.local/state/vice"
  # `-limitcycles` is how a headless run ends, and VICE reports reaching it as
  # an ERROR exit — so the exit status cannot be the gate. The log line is the
  # discriminator between "ran to the limit" and "died", and the mapping below
  # is the actual proof.
  # VICE_SHM_CHIP is exported only when the stanza asks for it: unset keeps the
  # publisher byte-identical to its pre-selector behaviour, which is what the
  # six single-canvas stations depend on.
  local chip=()
  [ -n "${VICE_GATE_SHM_CHIP:-}" ] && chip=("VICE_SHM_CHIP=$VICE_GATE_SHM_CHIP")
  (
    cd "$gate" &&
      env HOME="$gate/home" VICE_SHM_PATH="$gate/fb.shm" ${chip[@]+"${chip[@]}"} \
        "$bin" -directory "$data" +sound \
        -limitcycles "${VICE_GATE_CYCLES:-20000000}" \
        "${VICE_GATE_ARGS[@]}" >"$gate/vice.log" 2>&1
  ) || grep -q 'cycle limit reached' "$gate/vice.log" ||
    die "gate VICE died before the cycle limit; see $gate/vice.log"
  [ -s "$gate/fb.shm" ] || die "no shm mapping published; see $gate/vice.log"
  local out
  out=$(
    python3 - "$gate/fb.shm" <<'PY'
import struct
import sys

b = open(sys.argv[1], "rb").read()
magic, _v, w, h, stride, bpp = struct.unpack_from("<6I", b, 0)
if magic != 0x31424649:
    sys.exit("bad IFB1 magic in the shm mapping")
if bpp != 32:
    sys.exit("mapping is %d bpp, expected 32" % bpp)
want = 64 + h * stride
if len(b) != want:
    sys.exit("mapping is %d bytes, expected 64 + %d*%d = %d" % (len(b), h, stride, want))
if stride != w * 4:
    sys.exit("stride %d is not width %d * 4" % (stride, w))
lit = 0
hist = {}
for y in range(h):
    row = b[64 + y * stride : 64 + y * stride + w * 4]
    for x in range(0, w * 4, 4):
        if row[x] > 40 or row[x + 1] > 40 or row[x + 2] > 40:
            lit += 1
        px = row[x : x + 3]
        hist[px] = hist.get(px, 0) + 1
# Non-dominant pixels: everything that is not the single most common colour.
# A flooded frame - which "lit" alone cannot tell from a real scene, because a
# white VIC-20 page lights every pixel - has ~none.
dom = max(hist, key=hist.get)
nondom = (w * h) - hist[dom]
y0 = x0 = 1 << 30
y1 = x1 = -1
for y in range(h):
    row = b[64 + y * stride : 64 + y * stride + w * 4]
    for x in range(0, w * 4, 4):
        if row[x : x + 3] != dom:
            c = x // 4
            x0, x1 = min(x0, c), max(x1, c)
            y0, y1 = min(y0, y), max(y1, y)
print("%dx%d %d %d %d %d:%d:%d:%d" % (w, h, lit, nondom, len(hist), y0, y1, x0, x1))
PY
  ) || die "shm mapping unreadable or malformed; see $gate/vice.log"
  read -r GATE_GEOM GATE_LIT GATE_NONDOM GATE_COLOURS GATE_BBOX <<<"$out"
  [ "$GATE_LIT" -ge "${VICE_GATE_FLOOR:?stanza does not set VICE_GATE_FLOOR}" ] ||
    die "smoke gate: only $GATE_LIT lit pixel(s) on the published $GATE_GEOM surface (floor $VICE_GATE_FLOOR); see $gate/vice.log"
  [ "$GATE_NONDOM" -ge "${VICE_GATE_INK_FLOOR:?stanza does not set VICE_GATE_INK_FLOOR}" ] ||
    die "smoke gate: $GATE_NONDOM non-dominant pixel(s) on the $GATE_GEOM surface (floor $VICE_GATE_INK_FLOOR) —
  the frame is lit but FLAT, which is what a machine that never drew its scene looks like; see $gate/vice.log"
  if [ -n "${VICE_GEOM_EXPECT:-}" ] && [ "$GATE_GEOM" != "$VICE_GEOM_EXPECT" ]; then
    die "smoke gate: published geometry is $GATE_GEOM, the stanza expects $VICE_GEOM_EXPECT.
  VICE has no MAME_SHM_SIZE: the surface IS the emulated screen x <CHIP>DoubleSize,
  so a VICE_GATE_ARGS change moved a live station's stream. Re-measure deliberately."
  fi
  if [ -n "${VICE_GATE_BBOX:-}" ]; then
    IFS=: read -r wy0 wy1 wx0 wx1 <<<"$VICE_GATE_BBOX"
    IFS=: read -r gy0 gy1 gx0 gx1 <<<"$GATE_BBOX"
    if [ "$gy0" -lt "$wy0" ] || [ "$gy1" -gt "$wy1" ] || [ "$gx0" -lt "$wx0" ] || [ "$gx1" -gt "$wx1" ]; then
      die "smoke gate: the scene's ink sits at rows $gy0..$gy1 cols $gx0..$gx1, outside the
  expected band rows $wy0..$wy1 cols $wx0..$wx1. A pixel COUNT cannot tell a correctly
  framed banner from one drawn at the wrong offset; this is that check. See $gate/vice.log"
    fi
  fi
  echo "  smoke gate PASSED: ${GATE_GEOM} surface, $GATE_LIT lit (floor $VICE_GATE_FLOOR), $GATE_NONDOM non-dominant (floor $VICE_GATE_INK_FLOOR), $GATE_COLOURS colours, ink bbox $GATE_BBOX"
}

STATION="${1:?usage: build-vice-native.sh <station> [work-dir] [output-dir]}"
STANZA="$HERE/vice-native.d/$STATION.sh"
[ -f "$STANZA" ] || die "no conversion stanza for '$STATION': $STANZA"
VICE_GATE_ARGS=()
VICE_DATA_DIRS=()
VICE_ROM_REQUIRED=()
# shellcheck disable=SC1090
. "$STANZA"
[ -n "${VICE_EMU:-}" ] || die "$STANZA does not set VICE_EMU"
[ "${#VICE_DATA_DIRS[@]}" -gt 0 ] || die "$STANZA does not set VICE_DATA_DIRS"
[ "${#VICE_ROM_REQUIRED[@]}" -gt 0 ] || die "$STANZA does not set VICE_ROM_REQUIRED"

WORK="${2:-/data/vms/soltest/BUILD-vice-$STATION}"
OUT="${3:-/data/vms/streamhost/assets/$STATION/vice-native}"
JOBS="${JOBS:-$(nproc)}"
SRC="$WORK/vice-src"
BUILD="$WORK/build"

# ---------------------------------------------------------------------------
# 1. source: the published fork at the pin, never a shallow clone
# ---------------------------------------------------------------------------
mkdir -p "$WORK/bin"
if [ ! -d "$SRC/.git" ]; then
  if [ -e "$SUBMODULE/.git" ]; then
    say "cloning from the checked-out third_party/vice-kernel-hive submodule"
    # --no-hardlinks is not optional on the box: /data/kernel-hive and
    # /data/vms are separate filesystems, and a plain --local clone dies with
    # "failed to create link ... Invalid cross-device link".
    git clone -q --local --no-hardlinks "$SUBMODULE" "$SRC"
  else
    say "cloning the published fork (submodule not checked out: git submodule update --init third_party/vice-kernel-hive)"
    git clone -q --branch "$VICE_FORK_BRANCH" "$VICE_FORK_URL" "$SRC"
  fi
fi
git -C "$SRC" fetch -q origin "+$VICE_FORK_BRANCH:refs/remotes/origin/pin" 2>/dev/null ||
  git -C "$SRC" fetch -q origin 2>/dev/null || true
git -C "$SRC" checkout -q "$VICE_FORK_PIN" 2>/dev/null ||
  die "the pinned commit $VICE_FORK_PIN is not in $SRC — is the submodule stale?"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$VICE_FORK_PIN" ] ||
  die "source tree is not at the pin $VICE_FORK_PIN"
echo "  source: $SRC at $VICE_FORK_PIN ($VICE_FORK_BRANCH)"

# ---------------------------------------------------------------------------
# 2. the two build tools the box does not have, INSIDE the work dir
# ---------------------------------------------------------------------------
if [ ! -x "$WORK/bin/dos2unix" ]; then
  say "staging a dos2unix shim (configure wants the name, not the package)"
  cat >"$WORK/bin/dos2unix" <<'SHIM'
#!/bin/sh
for a in "$@"; do
  case "$a" in -*) continue ;; esac
  [ -f "$a" ] && sed -i 's/\r$//' "$a"
done
exit 0
SHIM
  chmod 755 "$WORK/bin/dos2unix"
fi
if [ ! -x "$WORK/bin/xa65" ]; then
  say "staging xa65 (unpacked into the work dir, never installed on labhost)"
  (cd "$WORK" && apt-get download xa65 >/dev/null 2>&1) ||
    die "apt-get download xa65 failed — VICE's 6502 assembler is required"
  (cd "$WORK" && dpkg-deb -x xa65_*.deb pkg && cp pkg/usr/bin/* bin/)
  # Debian ships the assembler as `xa`; VICE's configure looks for `xa65`.
  ln -sf xa "$WORK/bin/xa65"
fi
export PATH="$WORK/bin:$PATH"

# ---------------------------------------------------------------------------
# 3. build: headless UI only. No GTK, no SDL, no X — --enable-headlessui alone
#    is enough, and pulling SDL in would only add a second video port to keep
#    inert.
# ---------------------------------------------------------------------------
[ -x "$SRC/vice/configure" ] || (cd "$SRC/vice" && ./autogen.sh >"$WORK/autogen.log" 2>&1) ||
  die "autogen.sh failed; see $WORK/autogen.log"
mkdir -p "$BUILD"
if [ ! -f "$BUILD/Makefile" ]; then
  say "configure --enable-headlessui --prefix=$OUT"
  (cd "$BUILD" && "$SRC/vice/configure" --enable-headlessui --prefix="$OUT" >"$WORK/configure.log" 2>&1) ||
    die "configure failed; see $WORK/configure.log"
fi

say "building VICE with $JOBS jobs"
(cd "$BUILD" && nice -n 5 make -j"$JOBS" >"$WORK/make.log" 2>&1) ||
  die "make failed; see $WORK/make.log"

# The build must add no warnings OF OURS. Upstream 3.10.0 emits four
# (resid/filter8580new.cc, two 6510core.c #warnings, one curl attribute), and
# rewriting upstream to reach zero is not this campaign's job; every warning
# from a file the fork touches is.
say "warning gate: the fork's own files must compile clean"
OURWARN="$(grep -E '^(.*/)?(vicectl\.c|keymap\.c|crtc/crtc\.[ch]|crtc/crtc-snapshot\.c|arch/headless/[^:]*)(\.[ch])?:[0-9]+:[0-9]+: warning:' "$WORK/make.log" || true)"
[ -z "$OURWARN" ] || die "the fork's files produced warnings:
$OURWARN
  fix them on the fork (they are commits, not loose patches), then move the pin."
echo "  clean: no warnings from vicectl.c, keymap.c, src/crtc/ or src/arch/headless/"

say "installing to $OUT"
rm -rf "$OUT"
# prefix= on the command line, not just at configure time: that is what lets a
# shared work dir install a second station's tree without recompiling.
(cd "$BUILD" && make install prefix="$OUT" >"$WORK/install.log" 2>&1) || die "make install failed; see $WORK/install.log"
BIN="$OUT/bin/$VICE_EMU"
[ -x "$BIN" ] || die "make install produced no $VICE_EMU at $BIN"
# Belt and braces on the headless promise: an SDL or GTK link would mean the
# build picked up a windowed UI and the station would want a display.
if ldd "$BIN" | grep -Eq 'libSDL|libgtk'; then
  ldd "$BIN" | grep -E 'libSDL|libgtk' >&2
  die "the binary links SDL or GTK — this is not a headless build"
fi

# ---------------------------------------------------------------------------
# 4. ROMs. `make install` SKIPS data/*/ — the machine would segfault with no
#    output. Stage from the source tree and gate BY NAME.
# ---------------------------------------------------------------------------
say "staging the $STATION data tree (ROMs, palettes, .vkm keymaps)"
DATA="$OUT/share/vice"
mkdir -p "$DATA"
for d in common DRIVES "${VICE_DATA_DIRS[@]}"; do
  [ -d "$SRC/vice/data/$d" ] || die "no data/$d in the source tree"
  mkdir -p "$DATA/$d"
  find "$SRC/vice/data/$d" -maxdepth 1 -type f ! -name 'Makefile*' \
    -exec install -m 644 {} "$DATA/$d/" \;
done
for f in "${VICE_ROM_REQUIRED[@]}"; do
  [ -s "$DATA/$f" ] || die "required ROM/data file missing after staging: $DATA/$f"
done
echo "  staged: $(find "$DATA" -type f | wc -l) files under $DATA ($(du -sh "$DATA" | cut -f1))"
if declare -F vice_stage_extra >/dev/null; then
  say "stanza media hook"
  vice_stage_extra "$OUT"
fi

# ---------------------------------------------------------------------------
# 5. the framebuffer gate — the only proof the machine reacted
# ---------------------------------------------------------------------------
say "boot gate: the machine must publish a non-black scene into the mapping"
vice_gate_nonblack "$BIN" "$DATA" "$WORK/gate"

say "done"
sha256sum "$BIN"
cat <<EOF

Station:  $STATION (host-native VICE conversion)
Binary:   $BIN
Source:   github.com/Wnt/vice $VICE_FORK_BRANCH @ $VICE_FORK_PIN (5 commits on tag 3.10.0)
Data:     $DATA
Geometry: $GATE_GEOM  (MEASURED — VICE has no MAME_SHM_SIZE; the surface is the
          emulated screen x <CHIP>DoubleSize. Put this in the fixture desc.)
Run it:   HOME=<per-station> VICE_SHM_PATH=<fb.shm> VICE_CTL_SOCK=<ctl.sock> \\
          $BIN -directory $DATA ${VICE_GATE_ARGS[*]}
          (and mkdir -p \$HOME/.local/state/vice, or it segfaults in vice_banner)
EOF
