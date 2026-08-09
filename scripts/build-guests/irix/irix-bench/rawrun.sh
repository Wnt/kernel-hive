#!/usr/bin/env bash
# rawrun.sh — run MAME with the IRIX tile's exact production command line, one
# flag at a time added or removed, and screendump the result. No launcher, no
# watchdogs, no netns: the point is the command line itself.
#
# This is the flag bisector. It is what turned "the fastram binary hangs in
# production but not in the rig" into "fastram plus `-ioc2:rs232a pty` stops
# IRIX at its own memory diagnostic" in one afternoon — a two-flag interaction
# no single-arm run would have found.
#
#   rawrun.sh <name> <binary> <cpus> <dump-seconds> [extra MAME args ...]
#
#   GOLDEN=<path>   golden to clone (default irix65-apps-v3.chd)
#   RAWRUN_ROOT=<dir>  work root, must be under /data/vms/soltest
#
# Example — the bisect that found the blocker:
#   rawrun.sh v7-fr  ./sgi.fastram 6,14 620 -ioc2:rs232a pty   # MEMDIAG
#   rawrun.sh v7-ctl ./sgi         6,14 620 -ioc2:rs232a pty   # chooser
#   rawrun.sh v7-frn ./sgi.fastram 6,14 620                    # chooser
#
# Read the verdict off the framebuffer signature, never off the log. The known
# table is in docs/lab/MEASUREMENT-METHODOLOGY.md.
set -u

N="${1:?name}"
BIN="${2:?binary}"
CPUS="${3:?cpus}"
T="${4:?dump seconds}"
shift 4

W="${RAWRUN_ROOT:?set RAWRUN_ROOT to a namespaced dir under /data/vms/soltest}"
case "$W" in
  /data/vms/soltest/*) : ;;
  *)
    echo "refusing to work outside /data/vms/soltest" >&2
    exit 1
    ;;
esac
A="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
G="${GOLDEN:-$A/irix65-apps-v3.chd}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
RIG="$(cd -- "$(dirname -- "$0")" && pwd)"
D="$W/$N"

rm -rf "$D"
mkdir -p "$D/nvram"
# reflink: the golden is immutable (444 + chattr +i) and MAME opens an
# uncompressed CHD O_RDWR regardless, so every run gets its own copy.
cp --reflink=auto -- "$G" "$D/disk.chd"
chmod 644 -- "$D/disk.chd"
cp -r "$A/nvram/." "$D/nvram/"
{
  md5sum "$BIN"
  md5sum "$G"
} >"$D/provenance.md5"

IRIX_SHM_PATH="$D/fb.shm" IRIX_CMD="$D/irix_cmd" \
  taskset -c "$CPUS" \
  "$A/glibc/ld-linux-x86-64.so.2" \
  --library-path "$A/glibc:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu" \
  "$BIN" indy_4610 -bios b10 -rompath "$A/roms" -gio64_gfx xl24 \
  -hard1 "$D/disk.chd" -nvram_directory "$D/nvram" -inipath "$A/uicfg" \
  -skip_gameinfo -video none -sound none -frameskip 6 \
  -autoboot_script "$A/irixagent.lua" -autoboot_delay 0 "$@" \
  >"$D/mame.log" 2>&1 &
echo $! >"$D/mame.pid"

sleep "$T"
python3 "$RIG/shmpng.py" "$D/fb.shm" "$D/shot.png" || echo "no frame published"
# Teardown is part of the run, not a courtesy. An orphaned MAME sits at 100% of
# a core and silently contaminates the next agent's core-pair claim.
"$CG" kill-pidfile "$D/mame.pid"
