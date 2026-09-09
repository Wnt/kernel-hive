#!/bin/bash
# =============================================================================
# stations/medley/x11-runtime.sh — launcher for the Interlisp Medley station,
# CONTAINED. Started by ensure-station-x11.sh inside the streamhost@medley
# BindsTo scope.
#
# THIS IS NOT AN EMULATED MACHINE. Medley is the Xerox D-machine Lisp
# environment kept alive by the Interlisp project (github.com/Interlisp/medley,
# MIT); `maiko` is its byte-code VM and renders the Lisp display into an X
# window. The Lisp Exec a visitor types into can open files and spawn Unix
# subprocesses (library UNIXCOMM), so on 2026-09-09 — when maiko ran as root on
# labhost in the host namespaces — the station was one typed form away from a
# root shell on the hypervisor and the operator deactivated it. Since then the
# Lisp side runs inside a systemd-nspawn container (docs/guests/medley.md
# §Security lists the requirements and the Exec-typed proofs):
#
#   * own PID/mount/IPC/UTS/user namespaces (--private-users: root inside is
#     uid MEDLEY_UIDBASE outside); --private-network: only `lo`;
#   * a throwaway root (--volatile=overlay over a minimal Debian tree built
#     by scripts/build-guests/tiles/medley.sh); the Medley tree and maiko
#     bound READ-ONLY at their host paths, `work/` the only writable bind;
#   * CAP_SYS_ADMIN & friends dropped, mount syscalls filtered, no new privs.
#
# The station's own Xvfb runs INSIDE the container (nspawn-inner.sh). Its
# socket directory is a host directory bound over the container's
# /tmp/.X11-unix, and the host gets a symlink /tmp/.X11-unix/X<n> to that
# socket — so the daemon's x11 capture (GetImage, no MIT-SHM), XTEST input,
# `labctl shot` and xdotool all connect exactly as before. The X server is the
# only thing the Lisp side can talk to, and only over the X protocol.
#
# RESET = RELAUNCH, as before: kill the pidfile-owned maiko (verified through
# /proc/<pid>/exe — bound at the same path, the host sees the same exe path),
# the stub init exits with it and takes Xvfb down, wipe work/, start again from
# the pristine release sysout (~2 s to the Exec).
#
# Pidfile contract (ensure-station-x11.sh / stop-station-x11.sh, idle.rs):
#   mame.pid   maiko's HOST-visible pid — the daemon SIGSTOP/SIGCONTs it
#              (SH_IDLE_PAUSE_PROC_MATCH still matches its cmdline);
#   xvfb.pid   the container's Xvfb, host pid;
#   nspawn.pid the systemd-nspawn supervisor (not part of the old contract;
#              reap_previous kills it too so a leaked container never lingers).
#
# Per-station knobs from station.env:
#   SH_STATION, SH_X11_DISPLAY, MEDLEY_ASSETS, MEDLEY_GEOM, MEDLEY_SYSOUT,
#   MEDLEY_GREET, MEDLEY_MEM, MEDLEY_STANDBY_DELAY_S — as before;
#   MEDLEY_ROOTFS   the container tree (default $ASSETS/rootfs)
#   MEDLEY_UIDBASE  first host uid of the container's uid range (default
#                   1966080 = 30*65536, must be a multiple of 65536; CT 950/951's subuid range starts at 100000)
#   MEDLEY_X11_SOCKDIR  host dir bound over the container's /tmp/.X11-unix
#                   (default /run/streamhost/x11/$TILE)
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${MEDLEY_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${MEDLEY_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${MEDLEY_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
MEM="${MEDLEY_MEM:-256}"
SYSOUT="${MEDLEY_SYSOUT:-$ASSETS/medley/loadups/full.sysout}"
GREET="${MEDLEY_GREET:-$ASSETS/medley/greetfiles/MEDLEYDIR-INIT}"
ROOTFS="${MEDLEY_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${MEDLEY_UIDBASE:-1966080}"
SOCKDIR="${MEDLEY_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
BIN="$ASSETS/maiko/linux.x86_64/ldex"
INNER="$(dirname "$(readlink -f "$0")")/nspawn-inner.sh"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
XSOCK="/tmp/.X11-unix/X${DISP#:}"

[ -x "$BIN" ] || {
  echo "medley[$TILE]: no maiko at $BIN — run scripts/build-guests/tiles/medley.sh" >&2
  exit 1
}
[ -f "$SYSOUT" ] || {
  echo "medley[$TILE]: no sysout at $SYSOUT" >&2
  exit 1
}
[ -x "$ROOTFS/usr/bin/Xvfb" ] || {
  echo "medley[$TILE]: no container rootfs at $ROOTFS — run scripts/build-guests/tiles/medley.sh --rootfs" >&2
  exit 1
}
[ -f "$INNER" ] || {
  echo "medley[$TILE]: missing $INNER" >&2
  exit 1
}

# --- reap: maiko (by exe, scoped to this station's asset dir), then any
# supervisor left over. SIGCONT before TERM (a SIGSTOPped VM never handles
# TERM); refuse to start over a survivor.
station_vm_pids() {
  local d p exe
  for d in /proc/[0-9]*; do
    [ -d "$d" ] || continue
    p="${d#/proc/}"
    [ "$p" = "$$" ] && continue
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    exe="${exe% (deleted)}"
    case "$exe" in
      "$ASSETS"/maiko/*) printf '%s\n' "$p" ;;
    esac
  done
}
pidfile_alive() { # $1 pidfile $2 exe basename expected
  local p exe
  p="$(cat "$1" 2>/dev/null || true)"
  case "$p" in '' | *[!0-9]*) return 1 ;; esac
  exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || return 1
  [ "$(basename "${exe% (deleted)}")" = "$2" ] && printf '%s\n' "$p"
}
reap_previous() {
  local p
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for _ in $(seq 1 40); do
    [ -z "$(station_vm_pids)" ] && break
    sleep 0.25
  done
  for p in $(station_vm_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done
  # the supervisor follows its payload; give it a moment, then insist
  if p="$(pidfile_alive "$NPIDFILE" systemd-nspawn)"; then
    for _ in $(seq 1 20); do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
  fi
  sleep 0.5
  [ -z "$(station_vm_pids)" ]
}

reap_previous || {
  echo "medley[$TILE]: previous maiko still alive after SIGKILL:" \
    "$(station_vm_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$XPIDFILE" "$NPIDFILE"

# --- host side of the X socket: the dir the container's Xvfb writes into,
# owned by the container's root; the display's canonical socket path on the
# host is a symlink to it, so every X client on the host is unchanged.
mkdir -p "$SOCKDIR"
chown "$UIDBASE:$UIDBASE" "$SOCKDIR"
chmod 1777 "$SOCKDIR"
rm -f "$SOCKDIR/X${DISP#:}"
if [ -e "$XSOCK" ] && [ ! -L "$XSOCK" ]; then
  echo "medley[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state: work/ is the only writable bind; the sysout
# is opened read-only by maiko and SaveVM/LOGOUT would write LDEDESTSYSOUT,
# which lives in work/ and is wiped on every launch.
rm -rf "$BASE/work"
mkdir -p "$BASE/work"
chown "$UIDBASE:$UIDBASE" "$BASE/work"
# The inner script travels as an emit aux file (root-owned, 0600 in the
# station dir), which the container's mapped root could neither read nor
# execute — so it is copied into work/ with the container's ownership.
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$BASE/work/nspawn-inner.sh"

# --- the container. --as-pid2: nspawn's stub init is PID 1 and reaps;
# nspawn-inner.sh is PID 2, starts Xvfb and execs maiko, so maiko's exit ends
# the container. --keep-unit: stays in the caller's (BindsTo) scope, so
# `systemctl stop streamhost@<tile>` sweeps it. --private-users with a FIXED
# base so work/ and the socket dir can be pre-owned; the tree itself was
# shifted into that range ONCE by the builder (ownership=chown cannot be
# combined with a volatile root), so ownership=off here. --volatile=overlay:
# a tmpfs upper over the read-only tree, nothing persists. The Medley tree and
# maiko are bound at their host paths so /proc/<pid>/exe and the cmdline the
# idle freezer matches on read the same from the host.
nohup systemd-nspawn \
  --quiet --register=no --keep-unit --as-pid2 \
  --machine="kh-$TILE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$ASSETS/maiko" --bind-ro="$ASSETS/medley" \
  --bind="$BASE/work:/work" \
  --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=SH_X11_DISPLAY="$DISP" --setenv=MEDLEY_GEOM="$GEOM" \
  --setenv=MEDLEY_MEM="$MEM" --setenv=MEDLEY_BIN="$BIN" \
  --setenv=HOME=/work --setenv=LOGINDIR=/work \
  --setenv=MEDLEYDIR="$ASSETS/medley" \
  --setenv=LDEDESTSYSOUT=/work/lisp.virtualmem \
  --setenv=LDEINIT="$GREET" --setenv=LDESRCESYSOUT="$SYSOUT" \
  --setenv=LDEKBDTYPE=X \
  --kill-signal=SIGTERM --console=pipe \
  /work/nspawn-inner.sh \
  >"$BASE/maiko.log" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

# maiko maps its window within ~1 s of exec; the Exec is drawn by ~2 s.
MPID=""
for _ in $(seq 1 60); do
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    echo "medley[$TILE]: container died at launch — tail of maiko.log:" >&2
    tail -20 "$BASE/maiko.log" >&2
    exit 1
  }
  MPID="$(station_vm_pids | head -1)"
  if [ -n "$MPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "Medley Interlisp"; then
    break
  fi
  sleep 0.5
done
[ -n "$MPID" ] || {
  echo "medley[$TILE]: no maiko after 30 s — tail of maiko.log:" >&2
  tail -20 "$BASE/maiko.log" >&2
  exit 1
}
echo "$MPID" >"$PIDFILE"
# the container's Xvfb: same PID namespace as maiko, exe Xvfb
XV=""
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$MPID/ns/pid" 2>/dev/null)" ] || continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "medley[$TILE]: pid=$MPID xvfb=${XV:-?} nspawn=$(cat "$NPIDFILE") display=$DISP geom=$GEOM sysout=$(basename "$SYSOUT") uidbase=$UIDBASE (contained relaunch, no statefile)"

# Standby: freeze once the booted scene has settled; the daemon owns the
# steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${MEDLEY_STANDBY_DELAY_S:-30}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "medley[$TILE]: standby — frozen at the Exec (pid $p; first session wakes it)"
  ) &
fi
