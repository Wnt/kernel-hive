#!/bin/bash
# =============================================================================
# stations/lisa/x11-runtime.sh — host-native LisaEm launcher for the Apple Lisa
# (Lisa Office System 3.1) station, SANDBOXED. Started by ensure-station-x11.sh
# inside the streamhost@lisa BindsTo scope; the daemon captures the X root
# (SH_CAPTURE=x11) and drives XTEST (SH_INPUT_BACKEND=x11test, absolute).
#
# THE SHAPE. LisaEm 2.0 is an ordinary wxGTK application: no headless mode, no
# shm export, no control socket. Its menus and GTK dialogs are HOST user
# interface, so it runs under the operator's rule for host applications
# (2026-09-09, the medley incident): inside a systemd-nspawn container with a
# private PID, mount, network and user namespace —
#   * root filesystem: $ASSETS/rootfs, a read-only skeleton with the host's
#     /usr, /etc/fonts, /etc/ld.so.cache and /etc/alternatives bound in
#     read-only, plus $ASSETS itself at its own path (so /proc/<pid>/exe of
#     the sandboxed LisaEm reads as the host path and the daemon's
#     SH_IDLE_PAUSE_PROC_MATCH keeps working); nothing else of the host is
#     visible (no /data beyond the assets, no /etc secrets, no devices, no
#     host interfaces — only lo); capabilities dropped and @mount filtered
#     exactly as the medley sandbox does;
#   * user namespace: the container's uid range is the unprivileged host range
#     200000..265535, so "root" inside is host uid 200000 and cannot mount a
#     host filesystem, read a host file it was not handed, or signal a host
#     process;
#   * writable: only $BASE/work (this launch's ProFile copy, LisaEm's config,
#     logs) and $BASE/x11 (the Xvfb socket directory, bound to the container's
#     /tmp/.X11-unix); the host symlinks /tmp/.X11-unix/X<n> to it so the
#     daemon's DISPLAY=:<n> reaches the sandboxed server.
# lisa-inner.sh (PID 2 inside) starts Xvfb, LisaEm, places the window and
# clicks the ROM's ProFile icon; its header explains the geometry (720x498
# root == the aspect-corrected Lisa video; collapsed GTK menubar; the window
# moved to y=-42 — never a negative X, GDK then drops button events).
#
# LIBRARIES. The AppImage assumes GTK 3 on the host; labhost has none. The
# station carries the seven missing objects under $ASSETS/lib
# (tiles/lisa.sh stages them from CT950). Nothing is installed on labhost.
#
# RESET = RELAUNCH: kill the container (its nspawn pid, verified through
# /proc/<pid>/exe), copy the golden ProFile image fresh and cold-boot. LOS 3.1
# reaches the desktop ~120-150 s after the boot click at the emulated 5 MHz.
# LisaEm has no save state.
#
# Per-station knobs (station.env, the systemd EnvironmentFile):
#   SH_STATION            station id == station dir name
#   SH_X11_DISPLAY        the pinned Xvfb display (:93)
#   LISA_ASSETS           /data/vms/streamhost/assets/lisa (binary, libs, ROM, rootfs)
#   LISA_GEOM             Xvfb screen, default 720x498
#   LISA_BOOT_CLICK       1 = click the ProFile icon at the ROM menu (default)
#   LISA_UID_BASE         host uid the container's uid 0 maps to (200000)
#   LISA_BASE             override for $BASE on a rig (unset in production)
#   LISA_STANDBY_DELAY_S  settle before the standby freeze (default 200)
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${LISA_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${LISA_ASSETS:-/data/vms/streamhost/assets/lisa}"
BIN="$ASSETS/lisaem/usr/local/bin/lisaem"
ROOTFS="$ASSETS/rootfs"
GEOM="${LISA_GEOM:-720x498}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
UIDBASE="${LISA_UID_BASE:-200000}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name every native launcher uses
NSPAWN_PIDFILE="$BASE/nspawn.pid"
GOLD="$BASE/disk/lisa-profile.dc42.golden"
INNER="$BASE/lisa-inner.sh"
[ -f "$INNER" ] || INNER="$(dirname "$0")/lisa-inner.sh"
WORK="$BASE/work"
X11DIR="$BASE/x11"
MACHINE="lisa-${TILE}"

[ -x "$BIN" ] || {
  echo "lisa[$TILE]: no LisaEm at $BIN — run scripts/build-guests/tiles/lisa.sh" >&2
  exit 1
}
[ -d "$ROOTFS/usr" ] && [ -f "$ROOTFS/etc/os-release" ] || {
  echo "lisa[$TILE]: no sandbox rootfs skeleton at $ROOTFS — run tiles/lisa.sh" >&2
  exit 1
}
[ -f "$GOLD" ] || {
  echo "lisa[$TILE]: no golden ProFile image at $GOLD" >&2
  exit 1
}
[ -f "$INNER" ] || {
  echo "lisa[$TILE]: no lisa-inner.sh next to the launcher" >&2
  exit 1
}

# --- reap by /proc/<pid>/exe: the container's LisaEm and its nspawn --------
station_emu_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    case "$exe" in
      "$ASSETS"/lisaem/*) printf '%s\n' "$p" ;;
    esac
  done
}
station_nspawn_pid() {
  local p
  p="$(cat "$NSPAWN_PIDFILE" 2>/dev/null || true)"
  [ -n "$p" ] || return 1
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
  echo "lisa[$TILE]: previous LisaEm still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$NSPAWN_PIDFILE"

# --- fresh work copies, owned by the container's root --------------------------
rm -rf "$WORK" "$X11DIR"
mkdir -p "$WORK" "$X11DIR" "$BASE/disk"
cp --reflink=auto "$GOLD" "$WORK/profile.dc42"
chown -R "$UIDBASE:$UIDBASE" "$WORK" "$X11DIR"
chmod 1777 "$X11DIR"
cp "$INNER" "$WORK/inner.sh"
chmod 755 "$WORK/inner.sh"

# --- the sandbox --------------------------------------------------------------
nohup systemd-nspawn --quiet --register=no --keep-unit --as-pid2 \
  --machine="$MACHINE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --read-only \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro=/usr --bind-ro=/etc/fonts --bind-ro=/etc/ld.so.cache --bind-ro=/etc/alternatives \
  --bind-ro="$ASSETS" --bind="$WORK:/work" --bind="$X11DIR:/tmp/.X11-unix" \
  --setenv=LISA_DISPLAY="$DISP" --setenv=LISA_GEOM="$GEOM" --setenv=LISA_ASSETS="$ASSETS" \
  --setenv=LISA_BOOT_CLICK="${LISA_BOOT_CLICK:-1}" \
  --kill-signal=SIGTERM --console=pipe \
  /bin/bash /work/inner.sh >"$BASE/lisaem.log" 2>&1 </dev/null &
echo $! >"$NSPAWN_PIDFILE"

# --- the daemon's door: /tmp/.X11-unix/X<n> -> the sandbox's socket ------------
SOCK="$X11DIR/X${DISP#:}"
for _ in $(seq 1 80); do
  [ -S "$SOCK" ] && break
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "lisa[$TILE]: the sandbox died at launch — tail of lisaem.log:" >&2
    tail -20 "$BASE/lisaem.log" >&2
    exit 1
  }
  sleep 0.25
done
[ -S "$SOCK" ] || {
  echo "lisa[$TILE]: no X socket at $SOCK after 20 s" >&2
  exit 1
}
mkdir -p /tmp/.X11-unix
HOSTSOCK="/tmp/.X11-unix/X${DISP#:}"
if [ -e "$HOSTSOCK" ] && [ ! -L "$HOSTSOCK" ]; then
  echo "lisa[$TILE]: $HOSTSOCK exists and is not our symlink — another X server owns $DISP" >&2
  exit 1
fi
ln -sfn "$SOCK" "$HOSTSOCK"

# --- LisaEm's HOST pid for the pidfile (the daemon's freezer needs it) -------
LPID=""
for _ in $(seq 1 120); do
  LPID="$(station_emu_pids | head -1)"
  [ -n "$LPID" ] && break
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "lisa[$TILE]: the sandbox died before LisaEm started — tail of lisaem.log:" >&2
    tail -20 "$BASE/lisaem.log" >&2
    exit 1
  }
  sleep 0.25
done
[ -n "$LPID" ] || {
  echo "lisa[$TILE]: LisaEm did not appear in 30 s — tail of lisaem.log:" >&2
  tail -20 "$BASE/lisaem.log" >&2
  exit 1
}
echo "$LPID" >"$PIDFILE"
echo "lisa[$TILE]: sandbox nspawn pid=$(cat "$NSPAWN_PIDFILE") lisaem pid=$LPID (host uid $UIDBASE) display=$DISP root=$GEOM (cold boot from a fresh ProFile copy)"

# --- standby: freeze at the scene once the boot has settled ------------------
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${LISA_STANDBY_DELAY_S:-200}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$(readlink -f "$BIN")" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "lisa[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
