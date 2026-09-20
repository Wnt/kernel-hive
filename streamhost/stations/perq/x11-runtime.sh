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
# RESET = RELAUNCH, AND THE RELAUNCH DRIVES THE LOGIN. PERQemu 0.9.5 has no
# save state and CRIU cannot checkpoint this container (docs/guests/perq.md
# §Reset carries the failing criu output), so reset = kill the container, copy
# the pristine disk fresh, cold-boot, and then answer POS's date and name
# prompts from the launcher so the station lands on the GOLDEN SCENE — the POS
# shell — instead of a login prompt nobody answers. See bring_to_scene below.
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
#   PERQ_SCENE            "off" skips the login drive + standby (bring-up rigs)
#   PERQ_SCENE_PTR_X/_Y   where the cursor rests on the scene (default 384,524)
#   PERQ_STANDBY_DELAY_S  settle after the scene before the freeze (default 5)
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
# Every process descended from $1, host-wide, by walking ppid in /proc/<pid>/stat.
# This is what scopes the reaper to THIS launch's own container.
station_descendants() {
  # The ppid table is read ONCE (`ps` is one fork) and walked in awk. MEASURED:
  # a fork-per-ancestor-step version (one awk per hop, up to 12 hops per pid,
  # ~3000 pids, called 40x by reap_previous) never returned on a box at load 60
  # and wedged the launch for minutes. Parsing /proc/<pid>/stat by hand is the
  # other trap — comm may contain spaces and parentheses.
  local root="$1"
  ps -eo pid=,ppid= | awk -v root="$root" '
    { ppid[$1] = $2 }
    END {
      for (p in ppid) {
        q = p
        for (h = 0; h < 24; h++) {
          q = ppid[q]
          if (q == root) { print p; break }
          if (q <= 1) break
        }
      }
    }
  '
}
station_emu_pids() {
  # MEASURED 2026-09-13: an exact `$exe = $MONO` (the host ROOTFS path) never
  # matches. systemd-nspawn's --directory pivots into a NEW mount namespace,
  # so /proc/<pid>/exe read from the host's own namespace cannot be resolved
  # back through the container's (now-disconnected) vfsmount tree — the
  # kernel falls back to the bare in-namespace path ("/usr/bin/mono-sgen"),
  # not the host-visible one the launcher's own header claims. So match the
  # exe BASENAME, and scope it by DESCENT from this launch's own nspawn pid.
  #
  # The scope is not hygiene. The earlier version scoped by a cmdline grep for
  # /work/perq/PERQemu.exe — the in-container path, which is byte-identical for
  # `accent`, for a bring-up rig and for the live station. MEASURED the same
  # day: a rig launched at 14:49 and the live station's own relaunch at 14:54
  # each reaped the OTHER's PERQemu; the live station was left with a running
  # mono whose PERQ had powered off, publishing 200% CPU of uninitialised
  # video RAM to visitors. A pid-descent scope cannot do that.
  local n p exe
  n="$(cat "$NSPAWN_PIDFILE" 2>/dev/null || true)"
  case "$n" in '' | *[!0-9]*) return 0 ;; esac
  for p in $(station_descendants "$n"); do
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)" || continue
    case "${exe% (deleted)}" in
      "$MONO" | */mono-sgen | mono-sgen) printf '%s\n' "$p" ;;
    esac
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
  local p n
  # The emulator first, the supervisor second: station_emu_pids resolves its
  # scope THROUGH the nspawn pid, so killing the supervisor first would leave
  # the reaper blind to the mono it is meant to reap.
  n="$(station_nspawn_pid || true)"
  for p in $(station_emu_pids); do
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  [ -n "$n" ] && kill -TERM "$n" 2>/dev/null || true
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
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q '"PERQ '; then
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
# One find for the Xvfb basename over /proc/*/exe instead of a readlink fork
# per PID (see station_emu_pids above); the ns/pid check still runs per
# candidate, but there are only ever a handful of Xvfb processes.
for p in $(find /proc -mindepth 2 -maxdepth 2 -name exe -lname '*/Xvfb' \
  -printf '%h\n' 2>/dev/null | sed 's#^/proc/##'); do
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$MPID/ns/pid" 2>/dev/null)" ] || continue
  XV="$p"
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "perq[$TILE]: pid=$MPID xvfb=${XV:-?} nspawn=$(cat "$NSPAWN_PIDFILE") display=$DISP root=$GEOM disk=$DISK bootchar='${BOOTCHAR:-none}' uidbase=$UIDBASE (contained cold boot from a fresh disk copy)"

# --- the scene, then standby --------------------------------------------------
# RESET IS A RELAUNCH and a relaunch is a COLD BOOT: POS G.7 comes up at
# `Enter time as HH:MM or full date:` and then `Please enter your name:`, and
# NOTHING answers either one. Before this block a reset therefore handed the
# next visitor a login prompt, not the exhibit — the golden scene is the POS
# shell (`sys:User>Guest>` in the status line, the `>` prompt, the arrow
# cursor on the page), which is also the hero frame. So the launcher drives the
# two Returns itself and only then freezes.
#
# Every wait here is on the FRAMEBUFFER, never a fixed sleep (rule 14): the
# same `sleep 2` guess measurably cost two of ten pointer readbacks on this
# machine. `cksum` of the raw xwd dump is the cheapest settle test that needs
# nothing but x11-utils, which this launcher already requires for xwininfo.
# The dump is CROPPED past the POS status line before it is hashed: once a user
# is logged in, that line carries a clock that ticks every second, so a hash of
# the whole root NEVER settles and every wait runs to its timeout. Rows 0..31
# are the black band above the PERQ window plus that status line; rows 1036..
# are the 24 dead lines at the bottom.
fb_settle() { # fb_settle <stable-seconds> <timeout-seconds>
  local want="$1" limit="$2" last="" same=0 i=0 now
  while [ "$i" -lt "$limit" ]; do
    now="$(xwd -root -silent -display "$DISP" 2>/dev/null | convert xwd:- -crop 768x1004+0+32 +repage ppm:- 2>/dev/null | cksum)" || now=""
    if [ -n "$now" ] && [ "$now" = "$last" ]; then
      same=$((same + 1))
      [ "$same" -ge "$want" ] && return 0
    else
      same=0
    fi
    last="$now"
    i=$((i + 1))
    sleep 1
  done
  return 1
}
fb_hash() { xwd -root -silent -display "$DISP" 2>/dev/null | convert xwd:- -crop 768x1004+0+32 +repage ppm:- 2>/dev/null | cksum; }
fb_change() { # fb_change <timeout-seconds>: return once the page repaints
  local limit="$1" base i=0
  base="$(fb_hash)"
  while [ "$i" -lt "$limit" ]; do
    sleep 1
    [ "$(fb_hash)" != "$base" ] && return 0
    i=$((i + 1))
  done
  return 1
}
bring_to_scene() {
  local t0 t1
  t0="$(date +%s)"
  fb_settle 6 180 || {
    echo "perq[$TILE]: scene — the boot never settled; leaving the guest where it is" >&2
    return 1
  }
  # XTEST delivers to the FOCUSED window and there is no window manager here,
  # so focus is PointerRoot: the pointer must be inside the PERQ window or the
  # Returns go to the root and vanish. It also leaves the cursor mid-page,
  # which is where the hero frame has it.
  # xdotool has NO global -display flag: `xdotool -display :98 key Return` is an
  # unknown command, and with the error swallowed the launcher reported a scene
  # it had never reached (measured). It reads $DISPLAY, so set it.
  export DISPLAY="$DISP"
  xdotool mousemove "${PERQ_SCENE_PTR_X:-384}" "${PERQ_SCENE_PTR_Y:-524}" || true
  xdotool key --delay 120 Return || true # date prompt: accept the default
  fb_settle 4 60 || true
  xdotool key --delay 120 Return || true # name prompt: empty name logs in as Guest
  # TWO repaints follow, ~20 s apart on this machine: `Initializing for user:
  # Guest / Reading profile file >Default.Profile`, and only then the `>` shell
  # prompt. A settle alone fires in the quiet gap BETWEEN them and freezes the
  # station mid-login (measured) — wait for each repaint, then settle.
  # THREE repaints follow, and the gaps between them are long: `Initializing for
  # user: Guest`, `Reading profile file >Default.Profile`, and ~20 s later the
  # `>` shell prompt. Counting them is brittle — measured, both a `settle 8` and
  # a count of two repaints froze the station one paint short of the prompt. So
  # wait for the whole login to go quiet for longer than its longest internal
  # gap. The clock in the status line is cropped out of the hash, so "quiet"
  # here really is quiet.
  fb_settle 25 180 || true
  t1="$(date +%s)"
  echo "perq[$TILE]: scene — POS shell reached $((t1 - t0)) s after the window appeared"
}
if [ "${PERQ_SCENE:-on}" != off ]; then
  (
    bring_to_scene || true
    # standby: freeze AT THE SCENE, not at whatever the boot happened to reach.
    if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
      sleep "${PERQ_STANDBY_DELAY_S:-5}"
      p="$(cat "$PIDFILE" 2>/dev/null || true)"
      [ -n "$p" ] || exit 0
      case "$(readlink "/proc/$p/exe" 2>/dev/null)" in "$MONO" | */mono-sgen | mono-sgen) ;; *) exit 0 ;; esac
      kill -STOP "$p" 2>/dev/null &&
        echo "perq[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
    fi
  ) &
fi
