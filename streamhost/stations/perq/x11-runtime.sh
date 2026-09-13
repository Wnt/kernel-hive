#!/bin/bash
# =============================================================================
# stations/perq/x11-runtime.sh — launcher for the Three Rivers PERQ 1 station
# (POS G.7), CONTAINED. Started by ensure-station-x11.sh inside the
# streamhost@perq BindsTo scope; the daemon captures the X root
# (SH_CAPTURE=x11) and drives XTEST (SH_INPUT_BACKEND=x11test, absolute).
#
# THE SHAPE. PERQemu (github.com/skeezicsb/PERQemu, GPLv3, C# on Mono 6 +
# SDL2) is a stock host application with a command console on stdin, so it
# runs under the operator's host-application rule (2026-09-09, the medley
# incident): inside a systemd-nspawn container built on the lisa/medley shape —
#   * root filesystem: $ASSETS/rootfs, a debootstrap minbase trixie tree with
#     mono-runtime, libsdl2, Xvfb and the audit tools, uid-shifted ONCE by
#     scripts/build-guests/tiles/perq.sh --rootfs into the range $UIDBASE..
#     +65535 (2359296 = 36*65536 for perq; accent has its own), mounted
#     read-only (so /proc/<pid>/exe of the sandboxed mono reads as the host
#     path $ASSETS/rootfs/usr/bin/mono-sgen and the reaper below can find it);
#   * the release tree $ASSETS/perqemu bound read-only at /opt/perqemu (the
#     tree ships /opt/perqemu and /work as empty mount points);
#   * writable: only $BASE/work (this launch's PERQemu working dir with a
#     fresh copy of the disk image, tmp, logs) and $SOCKDIR (the Xvfb socket
#     directory, bound over the container's /tmp/.X11-unix; the host symlinks
#     /tmp/.X11-unix/X<n> to it so the daemon's DISPLAY=:<n> reaches in);
#   * --private-network (lo only), capabilities dropped, @mount filtered,
#     no new privileges — the audit block is in docs/lab/PERQ-WAVE.md §Sandbox.
# perq-inner.sh (PID 2 inside) starts Xvfb, composes work/perq and execs
# `mono PERQemu.exe boot.scr`; its header explains the 768x1048 root (the
# PERQ's 768x1024 portrait screen at (0,0) plus the 24 lines PERQemu insists
# on) and why stdin must NOT be a TTY.
#
# RESET = RELAUNCH: kill the container (nspawn pid verified through
# /proc/<pid>/exe), copy the pristine disk image fresh and cold-boot. POS G.7
# reaches its shell prompt ~40 s after power-on. PERQemu has no save state.
#
# Per-station knobs (station.env, the systemd EnvironmentFile):
#   SH_STATION            station id == station dir name
#   SH_X11_DISPLAY        the pinned Xvfb display (:98)
#   PERQ_ASSETS           /data/vms/streamhost/assets/perq (perqemu/, rootfs/)
#   PERQ_DISK             disk image under $PERQ_ASSETS/perqemu/Disks (g7.prqm)
#   PERQ_BOOTCHAR         PERQemu `bootchar` before `go` ("" = POS, z = Accent)
#   PERQ_GEOM             Xvfb screen, default 768x1048
#   PERQ_UID_BASE         host uid the container's uid 0 maps to (2359296)
#   PERQ_ROOTFS           override for the container tree (default $ASSETS/rootfs)
#   PERQ_BASE             override for $BASE on a rig (unset in production)
#   PERQ_X11_SOCKDIR      host dir bound over /tmp/.X11-unix (default /run/streamhost/x11/$TILE)
#   PERQ_STANDBY_DELAY_S  settle before the standby freeze (default 120)
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${PERQ_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${PERQ_ASSETS:-/data/vms/streamhost/assets/perq}"
RELEASE="$ASSETS/perqemu"
ROOTFS="${PERQ_ROOTFS:-$ASSETS/rootfs}"
DISK="${PERQ_DISK:-g7.prqm}"
BOOTCHAR="${PERQ_BOOTCHAR:-}"
GEOM="${PERQ_GEOM:-768x1048}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
UIDBASE="${PERQ_UID_BASE:-2359296}"
SOCKDIR="${PERQ_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name every native launcher uses
XPIDFILE="$BASE/xvfb.pid"
NSPAWN_PIDFILE="$BASE/nspawn.pid"
INNER="$(dirname "$(readlink -f "$0")")/perq-inner.sh"
WORK="$BASE/work"
MACHINE="kh-$TILE"
XSOCK="/tmp/.X11-unix/X${DISP#:}"
MONO="$ROOTFS/usr/bin/mono-sgen"

[ -f "$RELEASE/PERQemu.exe" ] || {
  echo "perq[$TILE]: no PERQemu.exe at $RELEASE — run scripts/build-guests/tiles/perq.sh" >&2
  exit 1
}
[ -f "$RELEASE/Disks/$DISK" ] || {
  echo "perq[$TILE]: no disk image $RELEASE/Disks/$DISK" >&2
  exit 1
}
[ -x "$MONO" ] && [ -x "$ROOTFS/usr/bin/Xvfb" ] || {
  echo "perq[$TILE]: no container rootfs at $ROOTFS — run scripts/build-guests/tiles/perq.sh --rootfs" >&2
  exit 1
}
[ "$(stat -c %u "$ROOTFS")" = "$UIDBASE" ] || {
  echo "perq[$TILE]: rootfs $ROOTFS is owned by uid $(stat -c %u "$ROOTFS"), not the container base $UIDBASE" >&2
  exit 1
}
[ -f "$INNER" ] || {
  echo "perq[$TILE]: missing $INNER" >&2
  exit 1
}

# --- reap by /proc/<pid>/exe: this station's sandboxed mono, then its nspawn ---
station_emu_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    [ "$exe" = "$MONO" ] && printf '%s\n' "$p"
  done
}
station_nspawn_pid() {
  local p
  p="$(cat "$NSPAWN_PIDFILE" 2>/dev/null || true)"
  case "$p" in '' | *[!0-9]*) return 1 ;; esac
  [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$(readlink -f "$(command -v systemd-nspawn)")" ] || return 1
  grep -q -- "--machine=$MACHINE" "/proc/$p/cmdline" 2>/dev/null || return 1
  echo "$p"
}
reap_previous() {
  local p
  if p="$(station_nspawn_pid)"; then
    kill -TERM "$p" 2>/dev/null || true
  fi
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_emu_pids)" ] && ! station_nspawn_pid >/dev/null && return 0
    sleep 0.25
  done
  for p in $(station_emu_pids) $(station_nspawn_pid || true); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  sleep 0.5
  [ -z "$(station_emu_pids)" ]
}
reap_previous || {
  echo "perq[$TILE]: previous PERQemu still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$XPIDFILE" "$NSPAWN_PIDFILE"

# --- host side of the X socket ------------------------------------------------
mkdir -p "$SOCKDIR"
chown "$UIDBASE:$UIDBASE" "$SOCKDIR"
chmod 1777 "$SOCKDIR"
rm -f "$SOCKDIR/X${DISP#:}"
if [ -e "$XSOCK" ] && [ ! -L "$XSOCK" ]; then
  echo "perq[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state: work/ is the only writable bind -----------------
rm -rf "$WORK"
mkdir -p "$WORK"
chown "$UIDBASE:$UIDBASE" "$WORK"
# The inner script travels as an emit aux file (root, 0600 in the station dir);
# the container's mapped root could not read it, so it is installed into work/.
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$WORK/inner.sh"

# --- the sandbox (docs/lab/PERQ-WAVE.md §Sandbox carries the audit) --------------
nohup systemd-nspawn --quiet --register=no --keep-unit --as-pid2 \
  --machine="$MACHINE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --read-only --tmpfs=/var/tmp \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$RELEASE:/opt/perqemu" --bind="$WORK:/work" --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=PERQ_DISPLAY="$DISP" --setenv=PERQ_GEOM="$GEOM" --setenv=PERQ_ASSETS=/opt/perqemu \
  --setenv=PERQ_DISK="$DISK" --setenv=PERQ_BOOTCHAR="$BOOTCHAR" \
  --kill-signal=SIGTERM --console=pipe \
  /work/inner.sh >"$BASE/perqemu.log" 2>&1 </dev/null &
echo $! >"$NSPAWN_PIDFILE"

# --- PERQemu's HOST pid for the pidfile (the daemon's freezer needs it) ---------
MPID=""
for _ in $(seq 1 120); do
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "perq[$TILE]: the sandbox died at launch — tail of perqemu.log:" >&2
    tail -20 "$BASE/perqemu.log" >&2
    exit 1
  }
  MPID="$(station_emu_pids | head -1)"
  if [ -n "$MPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q '"PERQ"'; then
    break
  fi
  sleep 0.5
done
[ -n "$MPID" ] || {
  echo "perq[$TILE]: PERQemu did not appear in 60 s — tail of perqemu.log:" >&2
  tail -20 "$BASE/perqemu.log" >&2
  exit 1
}
echo "$MPID" >"$PIDFILE"
XV=""
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$MPID/ns/pid" 2>/dev/null)" ] || continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "perq[$TILE]: pid=$MPID xvfb=${XV:-?} nspawn=$(cat "$NSPAWN_PIDFILE") display=$DISP root=$GEOM disk=$DISK bootchar='${BOOTCHAR:-none}' uidbase=$UIDBASE (contained cold boot from a fresh disk copy)"

# --- standby: freeze at the scene once the boot has settled --------------------
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${PERQ_STANDBY_DELAY_S:-120}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    [ "$(readlink "/proc/$p/exe" 2>/dev/null)" = "$MONO" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "perq[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
