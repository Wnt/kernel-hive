#!/usr/bin/env bash
# Track A install rig: Xvfb + MAME/IRIX on a WRITABLE working CHD, with the
# install agent and an ISO in the emulated SCSI CD-ROM.
#
#   irix-apps-launch.sh [iso-basename]      e.g. irix-apps-launch.sh apps2003.iso
#
# Namespaced to /data/vms/soltest/irix-apps (own pidfiles, own command file), and
# its X display is ALLOCATED by xvfb-alloc rather than hand-picked: a rig can no
# longer half-start on a display another rig owns and silently screenshot it.
# The display it got is printed and recorded in $D/display (irix-apps-shot.sh
# reads it).
# It never references the production tiles tree and never opens the golden
# /data/vms/soltest/irix-mame/irix65.chd for writing.
set -u

D="${IRIX_APPS_DIR:-/data/vms/soltest/irix-apps}"
ASSETS="${IRIX_ASSETS:-/data/vms/soltest/irix-mame}" # roms/, uicfg/, nvram/ (read-only)
MAME_BIN="${IRIX_MAME:-/data/vms/soltest/mame-build/mame/sgi}"

GEOM="${IRIX_GEOMETRY:-1280x1024x24}"
CHD="${IRIX_APPS_CHD:-$D/work.chd}"
CMD="$D/irix_cmd"
AGENT="$D/irix-apps-agent.lua"
ISO="${1:-}"

XVFB_ALLOC_LIB="${XVFB_ALLOC_LIB:-/usr/local/bin/xvfb-alloc}"
[ -f "$XVFB_ALLOC_LIB" ] || XVFB_ALLOC_LIB="$(dirname "$0")/../../lib/xvfb-alloc.sh"
# shellcheck disable=SC1090,SC1091 # resolved at run time (box copy or repo copy)
source "$XVFB_ALLOC_LIB" || {
  echo "FATAL: cannot source xvfb-alloc ($XVFB_ALLOC_LIB)" >&2
  exit 1
}

[ -f "$CHD" ] || {
  echo "FATAL: $CHD missing - run make-work-chd.sh first" >&2
  exit 1
}
case "$CHD" in /data/vms/soltest/*) ;; *)
  echo "FATAL: refusing to write outside the clone root: $CHD" >&2
  exit 1
  ;;
esac

bash "$D/irix-apps-kill.sh" >/dev/null 2>&1 || true
mkdir -p "$D/nvram" "$D/snap" "$D/logs"
[ -d "$D/nvram/indy_4610" ] || cp -r "$ASSETS/nvram/." "$D/nvram/" # eaddr + monitor=h
: >"$CMD"
: >"$CMD.agent.log"

# The rig outlives this script, so the allocator's exit-release is off: the
# display is owned by $D/xvfb.pid until irix-apps-kill.sh releases it. Pin one
# with IRIX_APPS_DISPLAY=:NN if you must — it will fail loudly if it is taken,
# never attach to whoever has it.
alloc=(--screen "$GEOM" --no-trap --tag irix-apps
  --pidfile "$D/xvfb.pid" --log "$D/logs/xvfb.log")
[ -n "${IRIX_APPS_DISPLAY:-}" ] && alloc+=(--display "${IRIX_APPS_DISPLAY#:}")
xvfb_alloc "${alloc[@]}" || exit 1
DISP="$XVFB_DISPLAY"
printf '%s\n' "$DISP" >"$D/display"

cdargs=()
if [ -n "$ISO" ]; then
  iso_path="$D/media/$ISO"
  [ -f "$iso_path" ] || {
    echo "FATAL: no such ISO $iso_path" >&2
    exit 1
  }
  cdargs=(-cdrm1 "$iso_path")
fi

# CPU partitioning contract: this rig lives on physical cores 4-7 only.
# 0,1,8,9 belong to the perf-benchmark agent; 2,10 to the live tile.
CPUS="${IRIX_APPS_CPUS:-4,5,6,7,12,13,14,15}"

DISPLAY="$DISP" SDL_VIDEODRIVER=x11 IRIX_CMD="$CMD" nohup \
  taskset -c "$CPUS" \
  "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
  -hard1 "$CHD" "${cdargs[@]}" \
  -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
  -snapshot_directory "$D/snap" \
  -skip_gameinfo -video soft -sound none -mouse -background_input \
  -autoboot_script "$AGENT" -autoboot_delay 0 \
  >"$D/logs/mame.log" 2>&1 &
P=$!
echo "$P" >"$D/mame.pid"
sleep 5
if [ -e "/proc/$P" ]; then
  echo "install rig up: mame pid=$P display=$DISP chd=$CHD cd=${ISO:-none}"
  echo "drive it with: $D/irix-apps-cmd.sh <verb> ...   shot: $D/irix-apps-shot.sh out.png"
else
  echo "MAME FAILED:" >&2
  cat "$D/logs/mame.log" >&2
  exit 1
fi
