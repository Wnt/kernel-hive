#!/bin/bash
# =============================================================================
# stations/amix/x11-runtime.sh — host-native FS-UAE launcher for the Amiga
# UNIX (AMIX) station. Started by ensure-station-x11.sh inside the
# streamhost@amix BindsTo scope.
#
# Same shape as stations/amigaos35/x11-runtime.sh (stock FS-UAE under a pinned
# Xvfb, SH_CAPTURE=x11, XTEST input), with three deliberate differences:
#
#   1. The machine is an Amiga 3000 (68030 + MMU + 68882) with Kickstart 2.04
#      r37.175, not an A4000/040 — AMIX needs the 030 MMU.
#   2. The pointer is ABSOLUTE THROUGH THE GUEST'S OWN X SERVER (the board's
#      X -tiga server, on the same TCP :6000 the redirect targets). amigaos35
#      gets its 1:1 pointer from the UAE mousehack, an AmigaOS-level trap;
#      AMIX drives the Amiga mouse hardware itself, so host motion (abs or
#      rel XTEST) arrives as accelerated relative deltas and is never 1:1.
#      Instead the A2065 Ethernet card runs on slirp and this launcher adds a
#      LOOPBACK-ONLY redirect 127.0.0.1:<6000+N> -> 10.0.2.15:6000 (the
#      patched uae_slirp_redir binds 127.0.0.1, never the LAN); the daemon
#      (SH_X11TEST_MOTION=warp, SH_X11WARP_DISPLAY=127.0.0.1:N) warps the
#      guest pointer with XWarpPointer and reads it back with XQueryPointer.
#      Buttons and keys still ride XTEST into this Xvfb; a button edge is
#      held until the guest confirmed the warp. Fail-closed: the guest has
#      no default route, and the redirect is bound to loopback.
#   3. There is NO statefile. Reset is a cold boot of a fresh work disk copied
#      from the golden (~2 min to the OPEN LOOK desktop). The guest must be
#      halted with /sbin/shutdown before a golden is re-baked, or every boot
#      pays a full UFS fsck.
#
# Per-station knobs from station.env:
#   SH_STATION            amix
#   SH_X11_DISPLAY        the pinned display — daemon connects here
#   SH_X11WARP_DISPLAY    127.0.0.1:N — the guest X server's loopback redirect
#   FSUAE_NATIVE_BIN      assets/amix/fsuae-native/bin/fs-uae
#   FSUAE_NATIVE_KICK     Kickstart 2.04 r37.175 (A3000) path
#   FSUAE_NATIVE_GEOM     WxH of window AND X screen (1024x768: the A2410 board)
#   FSUAE_NATIVE_STANDBY_DELAY_S  settle before the standby freeze
#   SH_IDLE_PAUSE_PIDFILE/_SECS   the daemon's freezer; also arms standby
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="/data/vms/streamhost/stations/$TILE"
BIN="${FSUAE_NATIVE_BIN:?FSUAE_NATIVE_BIN not set in station.env}"
KICK="${FSUAE_NATIVE_KICK:?FSUAE_NATIVE_KICK not set}"
GEOM="${FSUAE_NATIVE_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
WARP="${SH_X11WARP_DISPLAY:?SH_X11WARP_DISPLAY not set (127.0.0.1:N, the guest X redirect)}"
X_PORT=$((6000 + ${WARP##*:}))
GUEST_X="10.0.2.15:6000" # the guest's X11R4 server on the slirp A2065 (static, in the golden)
case "$WARP" in
  127.0.0.1:*) ;;
  *)
    echo "fsuae-native[$TILE]: SH_X11WARP_DISPLAY=$WARP is not loopback — refusing" >&2
    exit 1
    ;;
esac
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim

[ -x "$BIN" ] || {
  echo "fsuae-native[$TILE]: no binary at $BIN — run FSUAE_STATION=amix build-fsuae-native.sh" >&2
  exit 1
}
[ -f "$KICK" ] || {
  echo "fsuae-native[$TILE]: no Kickstart at $KICK" >&2
  exit 1
}

# Reap by /proc/<pid>/exe scoped to this station's asset dir; strip the
# " (deleted)" suffix; SIGCONT before TERM (a SIGSTOPped emulator never runs
# to handle TERM); refuse to start over a survivor.
ASSET_DIR="$(dirname "$(dirname "$(readlink -f "$BIN")")")"

station_emu_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    case "$exe" in
      "$ASSET_DIR"/*) printf '%s\n' "$p" ;;
    esac
  done
}

reap_previous() {
  local p
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_emu_pids)" ] && return 0
    sleep 0.25
  done
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  sleep 0.5
  [ -z "$(station_emu_pids)" ]
}

reap_previous || {
  echo "fsuae-native[$TILE]: previous emulator(s) still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second publisher" >&2
  exit 1
}
rm -f "$PIDFILE"

# --- Xvfb: pinned display, atomically claimed -------------------------------
XPID="$(cat "$BASE/xvfb.pid" 2>/dev/null || true)"
if [ -n "$XPID" ] && [ "$(readlink "/proc/$XPID/exe" 2>/dev/null)" = "$(command -v Xvfb)" ] &&
  [ -S "/tmp/.X11-unix/X${DISP#:}" ]; then
  : # our Xvfb from a previous launch is still good
else
  # shellcheck source=/dev/null
  source /usr/local/bin/xvfb-alloc 2>/dev/null || source "$(dirname "$0")/../../scripts/lib/xvfb-alloc.sh"
  xvfb_alloc --display "${DISP#:}" --screen "${GEOM}x24" --pidfile "$BASE/xvfb.pid" --no-trap
  [ ":${XVFB_DISPLAY#:}" = ":${DISP#:}" ] || {
    echo "fsuae-native[$TILE]: allocator gave $XVFB_DISPLAY, wanted $DISP" >&2
    exit 1
  }
fi

# --- fresh work disk from the golden ----------------------------------------
# UFS carries no dirty flag we can repair from the host, so the golden must
# have been captured from a CLEANLY HALTED guest; a golden taken from a killed
# emulator makes every visitor's boot run fsck (~4 min instead of ~2).
mkdir -p "$BASE/work"
GOLD_HDF="$BASE/disk/amix-system.hdf.golden"
[ -f "$GOLD_HDF" ] || {
  echo "fsuae-native[$TILE]: no golden HDF at $GOLD_HDF" >&2
  exit 1
}
rm -f "$BASE/work/amix-system.hdf"
cp --reflink=auto --sparse=always "$GOLD_HDF" "$BASE/work/amix-system.hdf"

export DISPLAY="$DISP"
export LIBGL_ALWAYS_SOFTWARE=1 # no GPU: llvmpipe or FS-UAE gets no GL context
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=null # audio plane is off for this station; null device
W="${GEOM%x*}" H="${GEOM#*x}"

# COLOUR: the A2410 (TIGA) board, which the guest's `X -tiga` drives at
# 1024x768 PseudoColor. In RTG mode FS-UAE shows the board surface 1:1 in a
# window of the same size (no zoom modes apply, no stretch) -- the sweep in
# docs/guests/amix.md measured the capture identity-mapped at this geometry.
# No --stretch: the board surface is already window-sized. zoom=640x512 only
# governs the chipset console the visitor sees during the ~90 s boot (the
# default 692x540 crop would draw it scaled; the pinned crop is the console's
# own rectangle) -- it has no effect once the board owns the display.
nohup "$BIN" \
  --amiga_model=A3000 \
  --kickstart_file="$KICK" \
  --motherboard_ram=16384 \
  --hard_drive_0="$BASE/work/amix-system.hdf" \
  --hard_drive_0_type=rdb \
  --hard_drive_0_controller=scsi6 \
  --fullscreen=0 --window_width="$W" --window_height="$H" \
  --uae_gfxcard_type=A2410 --uae_gfxcard_size=2 \
  --zoom=640x512 \
  --automatic_input_grab=0 --initial_input_grab=0 \
  --floppy_drive_volume=0 \
  --uae_a2065=slirp \
  --uae_slirp_redir="tcp:${X_PORT}:${GUEST_X##*:}:${GUEST_X%%:*}" \
  --stdout=1 \
  >"$BASE/fs-uae.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 40); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || {
    echo "fsuae-native[$TILE]: fs-uae died at launch — tail of fs-uae.log:" >&2
    tail -20 "$BASE/fs-uae.log" >&2
    exit 1
  }
  grep -aq "uae_start" "$BASE/fs-uae.log" 2>/dev/null && break
  sleep 0.5
done
echo "fsuae-native[$TILE]: pid=$(cat "$PIDFILE") display=$DISP geom=$GEOM x11warp=127.0.0.1:$X_PORT (cold boot, no statefile)"

# x11warp CHECK, not configuration: the golden carries the X access state
# (`10.0.2.15 amix` / `10.0.2.2 slirphost` in /etc/inet/hosts, so rc.inet's
# `ifconfig aen0 \`uname -n\`` brings the A2065 up, and `xhost +slirphost` in
# /etc/kh-xsession). There is no exec channel into this guest, so nothing can
# be repaired at runtime: a refusal is a STALE GOLDEN and says so. Verified
# from the host with a bare X11 setup handshake over the redirect — 12 bytes
# out, first reply byte is success (1) or refusal (0) — never by logging in.
# X11R4 listens BEFORE kh-xsession has run xhost, so a refusal only counts
# once it has persisted for 30 s; a single refused probe is the boot window.
(
  n=0
  refused=0
  while [ "$n" -lt 400 ]; do
    rc=$(python3 -c '
import socket, struct, sys
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3)
    s.sendall(struct.pack(">ccHHHHH", b"B", b"\0", 11, 0, 0, 0, 0))
    print(0 if s.recv(8)[:1] == b"\1" else 1)
except Exception:
    print(2)
' "$X_PORT")
    if [ "$rc" = 0 ]; then
      echo "$(date -u +%FT%TZ) x11warp ok: guest X reachable on 127.0.0.1:$X_PORT, access granted"
      exit 0
    fi
    if [ "$rc" = 1 ]; then
      refused=$((refused + 1))
      if [ "$refused" -ge 30 ]; then
        echo "$(date -u +%FT%TZ) x11warp STALE GOLDEN: guest X refused the slirp peer for ${refused}s; re-bake disk/amix-system.hdf.golden (docs/guests/amix.md)"
        exit 1
      fi
    else
      refused=0
    fi
    n=$((n + 1))
    sleep 1
  done
  echo "$(date -u +%FT%TZ) x11warp TIMED OUT: guest X never answered on 127.0.0.1:$X_PORT (boot is ~2 min; a full fsck ~4)"
  exit 1
) >>"$BASE/x11warp-check.log" 2>&1 &

# Standby: freeze once the booted scene has settled; the daemon owns the
# steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${FSUAE_NATIVE_STANDBY_DELAY_S:-150}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "fsuae-native[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
