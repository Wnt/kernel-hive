#!/bin/bash
# =============================================================================
# build-guests/tiles/c64basic.sh — the Commodore 64 at its BASIC V2 READY
# prompt, host-native VICE x64sc. Runs ON LABHOST as root.
#
#   c64basic.sh stage            copy the c64 station's x64sc + C64 data tree
#   c64basic.sh bake [--force]   capture sta/golden.vsf from a cold boot and
#                                prove it restores, then install it atomically
#   c64basic.sh all  [--force]   both (also what no argument does, which is
#                                how build-all.sh calls it; an existing golden
#                                is kept unless --force)
#
# ONE BINARY, TWO STATIONS. `c64` (GEOS) and `c64basic` run the SAME x64sc,
# byte for byte: stage copies it from the c64 asset tree and refuses unless
# the sha256 matches. The copy is not optional — the shared launcher reaps
# every process whose /proc/<pid>/exe lives under the station's OWN asset
# dir, so two stations pointing at one binary path would kill each other on
# every reset. To rebuild from source instead: build-vice-native.sh c64basic
# (stanza vice-native.d/c64basic.sh), which compiles the same fork pin.
#
# THE GOLDEN. A checkpoint, the binary that reads it and the machine args it
# was captured under are ONE combination (AGENTS.md rule 6). The bake runs the
# staged binary with the fixture's VICE_NATIVE_ARGS in a namespaced rig
# (/data/vms/sandbox/<KH_SESSION>/bake, killed through clone-guard), waits on
# the framebuffer for READY (fb-wait.py, never a sleep), takes `SAVEST` over
# vicectl, then restores it in a FRESH process exactly the way the launcher
# does (-moncommands undump + -initbreak ready) and compares the two frames.
# Only a restore that reproduces the captured frame is installed, under a temp
# name and then renamed; an existing golden is only replaced with --force, and
# the replaced one is kept as golden.vsf.prev. checkpoint-guard refuses relaunch stations, so
# this is the guard for this one.
# =============================================================================
set -euo pipefail
# labrun runs under umask 077; the station and asset trees are 755 like every other.
umask 022

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
ID=c64basic
SRC=/data/vms/streamhost/assets/c64/vice-native
OUT=/data/vms/streamhost/assets/$ID/vice-native
ST=/data/vms/streamhost/stations/$ID
FIXTURE="$REPO/streamhost/stations/$ID/station.env.fixture"
BAKE="/data/vms/sandbox/${KH_SESSION:?KH_SESSION not set — run under labrun from a wt.sh sandbox}/bake"
FBWAIT="$REPO/scripts/dev/fb-wait.py"

say() { printf '\n== %s\n' "$*"; }
die() {
  echo "c64basic: $*" >&2
  exit 1
}

stage() {
  say "stage: x64sc + C64 data from the c64 station"
  local want
  want="$(sha256sum "$SRC/bin/x64sc" | cut -d' ' -f1)"
  rm -rf "$OUT.new"
  mkdir -p "$OUT.new/bin" "$OUT.new/share/vice"
  install -m 755 "$SRC/bin/x64sc" "$SRC/bin/petcat" "$OUT.new/bin/"
  for d in common DRIVES C64; do
    cp -a "$SRC/share/vice/$d" "$OUT.new/share/vice/"
  done
  [ "$(sha256sum "$OUT.new/bin/x64sc" | cut -d' ' -f1)" = "$want" ] ||
    die "staged x64sc does not match the c64 station's ($want)"
  for f in C64/kernal-901227-03.bin C64/basic-901226-01.bin C64/chargen-901225-01.bin C64/gtk3_sym.vkm; do
    [ -s "$OUT.new/share/vice/$f" ] || die "missing $f after staging"
  done
  rm -rf "$OUT.old"
  [ -d "$OUT" ] && mv "$OUT" "$OUT.old"
  mv "$OUT.new" "$OUT"
  rm -rf "$OUT.old"
  echo "  x64sc sha256 $want (== c64)"
}

# The machine args the exhibit runs with, read from the fixture so the bake
# and the serve path are one command line.
machine_args() {
  local v
  v="$(sed -n 's/^VICE_NATIVE_ARGS=//p' "$FIXTURE" | tail -1)"
  [ -n "$v" ] || die "no VICE_NATIVE_ARGS in $FIXTURE"
  eval "ARGS=($v)"
}

rig_up() { # rig_up <dir> [restore.vsf]
  local d="$1" rest=()
  clone-guard assert-path "$d" >/dev/null
  mkdir -p "$d/home/.local/state/vice"
  cp -f "$OUT/bin/x64sc" "$d/x64sc" # a private copy: never under a station's asset dir
  rm -f "$d/ctl.sock" "$d/fb.shm"
  if [ -n "${2:-}" ]; then
    printf 'undump "%s"\nx\n' "$2" >"$d/restore.mon"
    rest=(-moncommands "$d/restore.mon" -initbreak ready)
  fi
  # env -C, not a (cd …) subshell: $! must be the emulator itself (env and
  # setsid both exec), or the guarded kill takes a wrapper and orphans VICE.
  env -C "$d" HOME="$d/home" VICE_SHM_PATH="$d/fb.shm" VICE_CTL_SOCK="$d/ctl.sock" \
    ${2:+VICE_SHM_HOLD_RESTORE=1} setsid "$d/x64sc" -directory "$OUT/share/vice" -sounddev dummy \
    ${rest[@]+"${rest[@]}"} "${ARGS[@]}" >"$d/vice.log" 2>&1 </dev/null &
  echo $! >"$d/vice.pid"
  # A cold boot must CHANGE (blank -> banner) and then settle; a restore with
  # VICE_SHM_HOLD_RESTORE publishes the restored scene as its first frame, so
  # it can only settle.
  local cond=(--change)
  [ -n "${2:-}" ] && cond=()
  python3 "$FBWAIT" --shm "$d/fb.shm" ${cond[@]+"${cond[@]}"} --settle 2 --timeout 60 --out "$d/frame.png" >&2
}

vicectl() { # vicectl <sock> <verb line>
  python3 - "$1" "$2" <<'PY'
import re, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sys.argv[1])
buf = b""
while b"\n" not in buf:
    buf += s.recv(256)
s.sendall(b"9 " + sys.argv[2].encode() + b"\n")
buf = b""
while not re.search(rb"^9 (OK|ERR).*$", buf, re.M):
    buf += s.recv(4096)
print(buf.decode().strip())
sys.exit(0 if b"9 OK" in buf else 1)
PY
}

bake() {
  local force="${1:-0}"
  [ -x "$OUT/bin/x64sc" ] || die "nothing staged at $OUT — run: $0 stage"
  if [ -f "$ST/sta/golden.vsf" ] && [ "$force" != 1 ]; then
    echo "  $ST/sta/golden.vsf exists and is kept; --force rebakes it (the old one becomes golden.vsf.prev)"
    return 0
  fi
  machine_args
  say "bake: cold boot ${ARGS[*]} -> READY"
  clone-guard kill-pidfile "$BAKE/cold/vice.pid" >/dev/null 2>&1 || true
  clone-guard kill-pidfile "$BAKE/restored/vice.pid" >/dev/null 2>&1 || true
  rm -rf "$BAKE"
  mkdir -p "$BAKE/cold" "$BAKE/restored"
  rig_up "$BAKE/cold"
  vicectl "$BAKE/cold/ctl.sock" "SAVEST $BAKE/golden.vsf"
  python3 "$REPO/scripts/shmshot.py" "$BAKE/cold/fb.shm" "$BAKE/captured.ppm"
  clone-guard kill-pidfile "$BAKE/cold/vice.pid" >/dev/null
  say "prove: restore in a FRESH process, the launcher's way"
  rig_up "$BAKE/restored" "$BAKE/golden.vsf"
  python3 "$REPO/scripts/shmshot.py" "$BAKE/restored/fb.shm" "$BAKE/restored.ppm"
  clone-guard kill-pidfile "$BAKE/restored/vice.pid" >/dev/null
  # Same geometry, and no more than the cursor cell differs (16x16 at double
  # size, blinking): anything larger is a restore that did not reproduce READY.
  python3 - "$BAKE/captured.ppm" "$BAKE/restored.ppm" <<'PY'
import sys
from PIL import Image, ImageChops
a, b = (Image.open(p).convert("RGB") for p in sys.argv[1:3])
if a.size != b.size:
    sys.exit(f"restore changed the geometry: {a.size} -> {b.size}")
diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
n = sum(1 for v in diff.getdata() if v)
print(f"  restore proof: {a.size[0]}x{a.size[1]}, {n} px differ (cursor cell is 256)")
if n > 400:
    sys.exit("restored frame does not match the captured READY screen")
PY
  say "install $ST/sta/golden.vsf"
  mkdir -p "$ST/sta"
  install -m 644 "$BAKE/golden.vsf" "$ST/sta/golden.vsf.new"
  [ -f "$ST/sta/golden.vsf" ] && mv -f "$ST/sta/golden.vsf" "$ST/sta/golden.vsf.prev"
  mv -f "$ST/sta/golden.vsf.new" "$ST/sta/golden.vsf"
  sha256sum "$ST/sta/golden.vsf" "$OUT/bin/x64sc"
  echo "  evidence: $BAKE/cold/frame.png $BAKE/restored/frame.png"
}

force=0
[ "${2:-}" = --force ] && force=1
case "${1:-}" in
  stage) stage ;;
  bake) bake "$force" ;;
  all | "")
    stage
    bake "$force"
    ;;
  *)
    sed -n '2,30p' "$0"
    exit 2
    ;;
esac
