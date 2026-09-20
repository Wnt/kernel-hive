#!/bin/bash
# =============================================================================
# stations/its/x11-runtime.sh — launcher for the MIT ITS station, CONTAINED.
# Started by ensure-station-x11.sh inside the streamhost@its BindsTo scope.
#
# ITS is the MIT Incompatible Timesharing System running on an emulated
# DEC PDP-10 (KS10) under SIMH, built from source by the maintained
# github.com/PDP-10/its tree (scripts/build-guests/tiles/its.sh pins the
# commit). There is no QEMU, no checkpoint and no MAME here: the exhibit is a
# simulator process plus one terminal, and reset = relaunch from the pristine
# built disk.
#
# CONTAINMENT (docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md, the proven
# medley/vision shape): SIMH, Xvfb and the visitor's xterm all run inside a
# systemd-nspawn container — own PID/mount/IPC/UTS/user namespaces
# (--private-users: root inside is host uid ITS_UIDBASE), --private-network so
# the DZ11 telnet port is reachable only from inside, a --volatile=overlay
# throwaway root over a minimal Debian tree, the built ITS tree bound
# READ-ONLY at its host path, work/ the only writable bind, CAP_SYS_ADMIN &
# friends dropped, mount syscalls filtered, no-new-privileges. A visitor who
# reaches DDT (ITS has no protection between users — that is the exhibit) is
# still inside all of that.
#
# The X socket lives in a host directory bound over the container's
# /tmp/.X11-unix, with /tmp/.X11-unix/X<n> on the host a symlink to it, so
# capture (SH_CAPTURE=x11), XTEST input, `labctl shot` and xdotool are
# unchanged.
#
# Pidfile contract (ensure-station-x11.sh / stop-station-x11.sh, idle.rs):
#   mame.pid   the SIMH pdp10 HOST-visible pid — the daemon SIGSTOP/SIGCONTs it
#   xvfb.pid   the container's Xvfb, host pid
#   nspawn.pid the systemd-nspawn supervisor (reaped so no container lingers)
#
# Per-station knobs from station.env: SH_STATION, SH_X11_DISPLAY, ITS_ASSETS,
# ITS_GEOM, ITS_PORT, ITS_COLS/ROWS/FONTSIZE, ITS_ROOTFS, ITS_UIDBASE,
# ITS_X11_SOCKDIR, ITS_STANDBY_DELAY_S.
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${ITS_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${ITS_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${ITS_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PORT="${ITS_PORT:-10004}"
TREE="${ITS_TREE:-$ASSETS/tree}"
ROOTFS="${ITS_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${ITS_UIDBASE:-2424832}"
SOCKDIR="${ITS_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
SEED="${ITS_SEED_DISK:-$TREE/out/simh/rp0.dsk}"
BIN="$TREE/tools/simh/BIN/pdp10"
HERE="$(dirname "$(readlink -f "$0")")"
INNER="$HERE/nspawn-inner.sh"
SHARED="$HERE/shared-terminal-runtime.sh"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
XSOCK="/tmp/.X11-unix/X${DISP#:}"

[ -x "$BIN" ] || {
  echo "its[$TILE]: no SIMH pdp10 at $BIN — run scripts/build-guests/tiles/its.sh" >&2
  exit 1
}
[ -f "$SEED" ] || {
  echo "its[$TILE]: no built ITS disk at $SEED" >&2
  exit 1
}
[ -x "$ROOTFS/usr/bin/xterm" ] || {
  echo "its[$TILE]: no container rootfs at $ROOTFS — run scripts/build-guests/tiles/its.sh --rootfs" >&2
  exit 1
}
for f in "$INNER" "$SHARED"; do
  [ -f "$f" ] || {
    echo "its[$TILE]: missing $f" >&2
    exit 1
  }
done

# --- reap: the simulator by exe (scoped to this station's asset tree, which
# is bound at its host path inside the container so /proc/<pid>/exe agrees),
# then any supervisor left over. SIGCONT before TERM — a SIGSTOPped simulator
# never handles TERM. Refuse to start over a survivor.
# Resolve by /proc/<pid>/exe (AGENTS.md rule 5 — never a cmdline grep), but in
# ONE fork instead of one `readlink` per pid. MEASURED 2026-09-20 by vax43bsd
# on a loaded box: the per-pid loop cost 13.4 s per scan at 1322 PIDs, the
# launcher calls it once to reap and once per wait iteration, and the unit's
# 90 s start-pre timeout then killed every restart. `find -lname` matches the
# same symlink target, including a "... (deleted)" exe, in ~0.05 s.
station_vm_pids() {
  find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$TREE/tools/*" \
    -printf '%h\n' 2>/dev/null |
    sed 's#^/proc/##' |
    grep -E '^[0-9]+$' |
    grep -vx "$$" || true
}
pidfile_alive() { # $1 pidfile $2 expected exe basename
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
  echo "its[$TILE]: previous simulator still alive after SIGKILL:" \
    "$(station_vm_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$XPIDFILE" "$NPIDFILE"

# --- host side of the X socket dir, owned by the container's root.
mkdir -p "$SOCKDIR"
chown "$UIDBASE:$UIDBASE" "$SOCKDIR"
chmod 1777 "$SOCKDIR"
rm -f "$SOCKDIR/X${DISP#:}"
if [ -e "$XSOCK" ] && [ ! -L "$XSOCK" ]; then
  echo "its[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state: work/ is the only writable bind and holds the
# ONLY disk the simulator ever attaches. Everything a visitor writes in ITS
# lands here and is wiped on the next launch; the built seed stays read-only.
rm -rf "$BASE/work"
mkdir -p "$BASE/work"
cp --reflink=auto "$SEED" "$BASE/work/rp0.dsk"
chown -R "$UIDBASE:$UIDBASE" "$BASE/work"
chmod 0644 "$BASE/work/rp0.dsk"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$BASE/work/nspawn-inner.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$SHARED" "$BASE/work/shared-terminal-runtime.sh"

nohup systemd-nspawn \
  --quiet --register=no --keep-unit --as-pid2 \
  --machine="kh-$TILE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$TREE" \
  --bind="$BASE/work:/work" \
  --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=SH_X11_DISPLAY="$DISP" --setenv=ITS_GEOM="$GEOM" \
  --setenv=ITS_TREE="$TREE" --setenv=ITS_PORT="$PORT" \
  --setenv=ITS_COLS="${ITS_COLS:-80}" --setenv=ITS_ROWS="${ITS_ROWS:-30}" \
  --setenv=ITS_FONTSIZE="${ITS_FONTSIZE:-21}" \
  --setenv=ITS_XOFF="${ITS_XOFF:-+0+0}" \
  --setenv=ITS_READY_LOG_RE="${ITS_READY_LOG_RE:-SYSTEM JOB USING THIS CONSOLE}" \
  --setenv=ITS_READY_TIMEOUT_S="${ITS_READY_TIMEOUT_S:-300}" \
  --setenv=HOME=/work --setenv=TERM=vt100 \
  --kill-signal=SIGTERM --console=pipe \
  /work/nspawn-inner.sh \
  >"$BASE/its.log" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

# ITS boots from the built disk in ~20-40 s; the xterm maps once the DZ11 line
# answers. Wait on the real thing: the simulator pid, the X socket, and the
# visitor window actually mapped.
SPID=""
for _ in $(seq 1 "${ITS_LAUNCH_TIMEOUT_S:-360}"); do
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    echo "its[$TILE]: container died at launch — tail of its.log:" >&2
    tail -30 "$BASE/its.log" >&2
    exit 1
  }
  SPID="$(station_vm_pids | head -1)"
  if [ -n "$SPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "MIT ITS"; then
    break
  fi
  SPID=""
  sleep 1
done
[ -n "$SPID" ] || {
  echo "its[$TILE]: no ITS terminal window — tail of its.log:" >&2
  tail -30 "$BASE/its.log" >&2
  tail -40 "$BASE/work/emulator.log" 2>/dev/null >&2 || true
  exit 1
}
# --- pin X input focus. MEASURED by vax43bsd 2026-09-20 and it applies
# verbatim here: no window manager runs in the container, so X input focus is
# PointerRoot and keystrokes reach the xterm only while the pointer happens to
# be over it. The daemon drives this station with XTEST KEYS ONLY (there is no
# pointer in a 1967 timesharing exhibit — stream.pointer.present=false), and it
# never moves a pointer, so without an explicit XSetInputFocus a visitor's ^Z
# would land on the root window and vanish. `xdotool windowfocus` pins it once,
# for good. This is a bring-up action on the station's own display, not a
# shortcut offered to the visitor.
#
# --- and then open the session. ITS does not greet a terminal that connects to
# a DZ line: the system's own boot chatter goes to the PDP-10 CONSOLE, not to
# line 0, so a visitor who arrives after bring-up would be looking at an empty
# black terminal with no way to tell a working exhibit from a broken one. ^Z is
# what opens a session on ITS — it is the documented way to log in, the first
# thing the upstream README tells a human to type once
# 'SYSTEM JOB USING THIS CONSOLE' has appeared — so the launcher types it once
# here, on the station's own display, to bring the rest scene up to a live DDT
# prompt. It stays on the on-screen keyboard as well, because a visitor who
# logs out or wants a second job needs it.
#
# The gate is LIT PIXELS, not the keystroke: an early ^Z that reaches the line
# before ITS is listening is simply lost, and "did the screen change" is too
# weak because telnet's own chrome arrives asynchronously in the same window.
# Baseline settles first, then ^Z is re-sent until the DDT banner is actually
# on the framebuffer.
export DISPLAY="$DISP"
nlit() {
  xwd -display "$DISP" -root -silent 2>/dev/null |
    convert xwd:- -colorspace Gray -threshold 25% -format '%[fx:int(mean*w*h)]' info: 2>/dev/null || echo 0
}
WIN="$(xdotool search --name 'MIT ITS' 2>/dev/null | head -1 || true)"
if [ -n "$WIN" ]; then
  xdotool windowfocus "$WIN" 2>/dev/null || true
  base=-1
  prev=-1
  same=0
  for _ in $(seq 1 60); do
    sleep 0.5
    base="$(nlit)"
    if [ "$base" -gt 0 ] && [ "$base" = "$prev" ]; then
      same=$((same + 1))
      [ "$same" -ge 4 ] && break
    else
      same=0
    fi
    prev="$base"
  done
  want=$((base + ${ITS_LOGIN_LIT_PX:-400}))
  got="$base"
  for _ in $(seq 1 "${ITS_LOGIN_TRIES:-20}"); do
    xdotool key --clearmodifiers ctrl+z 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8; do
      sleep 0.5
      got="$(nlit)"
      [ "$got" -ge "$want" ] && break 2
    done
  done
  if [ "$got" -ge "$want" ]; then
    echo "its[$TILE]: ITS session open on the framebuffer ($base -> $got lit px)"
  else
    echo "its[$TILE]: WARNING — no ITS session banner (lit px $base -> $got, wanted $want); the rest scene may open black" >&2
  fi
else
  echo "its[$TILE]: WARNING — no window named 'MIT ITS' to focus; typing may vanish" >&2
fi

echo "$SPID" >"$PIDFILE"
XV=""
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$SPID/ns/pid" 2>/dev/null)" ] || continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "its[$TILE]: pdp10=$SPID xvfb=${XV:-?} nspawn=$(cat "$NPIDFILE") display=$DISP geom=$GEOM port=$PORT uidbase=$UIDBASE (contained relaunch from the pristine built disk)"

# Standby: freeze the simulator once the login screen has settled; the daemon
# owns the steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first
# session. A frozen PDP-10 costs no core between visitors.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${ITS_STANDBY_DELAY_S:-30}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "its[$TILE]: standby — frozen at the ITS terminal (pid $p; first session wakes it)"
  ) &
fi
