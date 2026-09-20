#!/bin/bash
# =============================================================================
# stations/vision/x11-runtime.sh — host-native PCE launcher for the `vision`
# station: VisiCorp Visi On 1.0 (December 1983) on an IBM 5160 XT, SANDBOXED.
# Started by ensure-station-x11.sh inside the streamhost@vision BindsTo scope;
# the daemon captures the X root (SH_CAPTURE=x11) and drives XTEST.
#
# THE SHAPE. PCE (hampa.ch, GPL) is an ordinary X11 application: it opens a
# window, reads the keyboard and mouse from X, and has no headless mode and no
# shm export. It is therefore a HOST APPLICATION under the operator's rule of
# 2026-09-09 (the medley incident) and runs inside a systemd-nspawn container
# with a private PID, mount, network, IPC, UTS and USER namespace:
#   * root filesystem: $ASSETS/rootfs, a full debootstrap minbase trixie built
#     by scripts/build-guests/tiles/vision.sh --rootfs and uid-shifted ONCE at
#     build time (so --private-users-ownership=off here costs nothing at every
#     launch). It carries Xvfb, xdotool and the station's own PCE build under
#     /opt/pce — nothing of labhost's /usr is bound in, because the payload
#     needs packages labhost does not have;
#   * user namespace: the container's uid 0 is host uid $VISION_UID_BASE
#     (2162688), so "root" inside cannot mount a host filesystem, read a host
#     file it was not handed, or signal a host process;
#   * writable: only $BASE/work (this launch's disk images, the PCE monitor
#     FIFOs, logs) and $BASE/x11 (the Xvfb socket directory, bound to the
#     container's /tmp/.X11-unix). The host symlinks /tmp/.X11-unix/X<n> to the
#     socket FILE in there so the daemon's DISPLAY=:<n> reaches the sandboxed
#     server. It must point at the FILE, not the directory — a directory
#     symlink silently gives the daemon no display (VISION-WAVE.md §Traps).
#   * read-only: $ASSETS at its own host path, for the ROMs and the pristine
#     disk set.
#
# FINDING PCE'S HOST PID (this differs from lisa, and the difference bites).
# lisa's LisaEm lives in a bound-in assets directory, so /proc/<pid>/exe of the
# sandboxed process reads as a HOST path and a path prefix is enough to identify
# it. PCE lives INSIDE the rootfs, at /opt/pce/bin/pce-ibmpc, so its
# /proc/<pid>/exe reads as the CONTAINER path — measured on the first launch of
# this launcher, 2026-09-13. A bare path match would therefore also match any
# other PCE on the box. So this launcher matches on the exe (rule 5: never a
# cmdline grep) AND requires the process to be a descendant of THIS launch's
# nspawn pid, which no other station's PCE can be.
#
# WHY THE DISK IMAGES LIVE IN THE WRITABLE BIND, NOT IN --bind-ro. PCE writes
# .psi floppy images back on eject, and Visi On's installer (VINSTALL) writes
# to BOTH the hard disk and the Application Manager floppy. A read-only media
# bind makes PCE fail the write-back and the guest sees a dead drive. The
# pristine copies live under $ASSETS/disk (read-only); every launch copies them
# fresh into $BASE/work.
#
# COPY PROTECTION. VOAPP1 (Visi On Application Manager disk 1) is the KEY DISK:
# it must be in drive A: whenever Visi On starts, and its protection lives in
# the flux, which is why the station ships .psi (PCE's own format, written by
# PCE's `psi` tool from the TransCopy .TC dump) and not a plain sector image.
#
# RESET = RELAUNCH: kill the container (its nspawn pid, verified through
# /proc/<pid>/exe), copy hd0.pbi + VOAPP1.psi + VOAPP2.psi fresh from the
# pristine set and cold-boot the XT again. PCE's ibmpc has no save state.
#
# Per-station knobs (station.env, the systemd EnvironmentFile):
#   SH_STATION              station id == station dir name
#   SH_X11_DISPLAY          the pinned Xvfb display (:94)
#   VISION_ASSETS           /data/vms/streamhost/assets/vision (rootfs, disk, rom, pce.cfg)
#   VISION_GEOM             Xvfb screen, default 1280x800 — measured: PCE's CGA
#                           window at scale 2 with its 4/3 aspect correction is
#                           exactly 1280x800, so the root IS the PCE window
#   VISION_UID_BASE         host uid the container's uid 0 maps to (2162688)
#   VISION_BASE             override for $BASE on a rig (unset in production)
#   VISION_AUTOSTART        1 = type VISION at the C:\> prompt (default)
#   VISION_STANDBY_DELAY_S  settle before the standby freeze (default 120)
#   SH_IDLE_PAUSE_PIDFILE/_SECS  the daemon's freezer; also arms standby here
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${VISION_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${VISION_ASSETS:-/data/vms/streamhost/assets/vision}"
ROOTFS="$ASSETS/rootfs"
BIN="$ASSETS/rootfs/opt/pce/bin/pce-ibmpc"
GEOM="${VISION_GEOM:-1280x800}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
UIDBASE="${VISION_UID_BASE:-2162688}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name every native launcher uses
NSPAWN_PIDFILE="$BASE/nspawn.pid"
INNER="$BASE/vision-inner.sh"
[ -f "$INNER" ] || INNER="$(dirname "$0")/vision-inner.sh"
WORK="$BASE/work"
X11DIR="$BASE/x11"
MACHINE="vision-${TILE}"
# the pristine set the tile builder stages; every launch starts from these
PRISTINE="$ASSETS/disk"

[ -x "$BIN" ] || {
  echo "vision[$TILE]: no pce-ibmpc at $BIN — run scripts/build-guests/tiles/vision.sh" >&2
  exit 1
}
[ -f "$ROOTFS/etc/os-release" ] && [ -x "$ROOTFS/usr/bin/Xvfb" ] || {
  echo "vision[$TILE]: no sandbox rootfs at $ROOTFS — run tiles/vision.sh --rootfs" >&2
  exit 1
}
for f in hd0.pbi VOAPP1.psi VOAPP2.psi; do
  [ -f "$PRISTINE/$f" ] || {
    echo "vision[$TILE]: no pristine $f at $PRISTINE — run tiles/vision.sh --compose" >&2
    exit 1
  }
done
[ -f "$ASSETS/pce.cfg" ] || {
  echo "vision[$TILE]: no pce.cfg at $ASSETS — run tiles/vision.sh --compose" >&2
  exit 1
}
[ -f "$INNER" ] || {
  echo "vision[$TILE]: no vision-inner.sh next to the launcher" >&2
  exit 1
}

# --- reap by /proc/<pid>/exe: the container's pce-ibmpc and its nspawn --------
# is $1 a descendant of $2? walks PPid out of /proc/<pid>/status.
is_descendant_of() {
  local p="$1" root="$2" n=0
  while [ "$p" != 1 ] && [ -n "$p" ] && [ "$n" -lt 32 ]; do
    [ "$p" = "$root" ] && return 0
    p="$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)" || return 1
    n=$((n + 1))
  done
  return 1
}
# WHY THIS HAS A FAST PATH. The reap ladder below calls station_emu_pids up to 40
# times, and the loop underneath readlink()s /proc/<pid>/exe for EVERY process on
# labhost -- a box that routinely runs 100+ guests. Measured 2026-09-13: a
# relaunch spent minutes there, long enough that `labctl reset vision` returned a
# frozen frame to the visitor and the coordinator filed it as "reset is broken".
# Two short-circuits fix it without weakening rule 5 (resolve by /proc/<pid>/exe,
# never a cmdline grep):
#   1. the pid we recorded at launch, verified by exe AND descent, is almost
#      always the answer -- check it first, O(1);
#   2. if the nspawn pid is gone there can be no container process left: PCE runs
#      inside that nspawn's PID namespace, which is torn down with its pid 1.
station_emu_pids() {
  local d p exe np
  np="$(cat "$NSPAWN_PIDFILE" 2>/dev/null || true)"
  [ -n "$np" ] || return 0
  kill -0 "$np" 2>/dev/null || return 0
  p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$p" ]; then
    exe="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    if [ "$exe" = /opt/pce/bin/pce-ibmpc ] && is_descendant_of "$p" "$np"; then
      printf '%s\n' "$p"
      return 0
    fi
  fi
  # One find over /proc/*/exe, never a readlink fork per PID: the per-PID form
  # measured 13.4 s at 1322 PIDs under load and could not finish inside the
  # unit's 90 s start-pre. Still /proc/<pid>/exe, never a cmdline grep.
  for p in $(find /proc -mindepth 2 -maxdepth 2 -name exe -lname /opt/pce/bin/pce-ibmpc \
    -printf '%h\n' 2>/dev/null | sed 's#^/proc/##' | grep -E '^[0-9]+$' | grep -vx "$$"); do
    is_descendant_of "$p" "$np" || continue
    printf '%s\n' "$p"
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
  echo "vision[$TILE]: previous pce-ibmpc still alive after SIGKILL:" \
    "$(station_emu_pids | tr '\n' ' ')— refusing to start a second one" >&2
  exit 1
}
rm -f "$PIDFILE" "$NSPAWN_PIDFILE"

# --- the relaunch trap: nspawn's leftover unix-export mount -------------------
# systemd-nspawn mounts a per-machine tmpfs at /run/systemd/nspawn/unix-export/
# <machine> and refuses to start if one is already there ("Mount point ...
# exists already, refusing"). Its teardown is ASYNCHRONOUS: it happens a beat
# after the container's pids are gone, so reap_previous can return true while
# the mount is still up. Since reset = relaunch on this station, that race is
# the second launch, every time — measured 2026-09-13, the relaunch died at the
# nspawn line while the first launch's own teardown was still in flight. Wait
# for it, then clear it by force.
UNIX_EXPORT="/run/systemd/nspawn/unix-export/$MACHINE"
for _ in $(seq 1 40); do
  [ -e "$UNIX_EXPORT" ] || break
  sleep 0.25
done
if [ -e "$UNIX_EXPORT" ]; then
  umount "$UNIX_EXPORT" 2>/dev/null || true
  rmdir "$UNIX_EXPORT" 2>/dev/null || true
fi
if [ -e "$UNIX_EXPORT" ]; then
  echo "vision[$TILE]: $UNIX_EXPORT will not go away — another container owns $MACHINE" >&2
  exit 1
fi

# --- fresh work copies, owned by the container's root -------------------------
# hd0.pbi carries the installed Visi On; VOAPP1.psi is the key disk that must be
# in A: at every start; VOAPP2.psi rides in B: so the Services window can install
# the other titles without a disk swap. All three are writable: PCE writes .psi
# back on eject and Visi On writes its own state to C:.
rm -rf "$WORK" "$X11DIR"
mkdir -p "$WORK" "$X11DIR"
for f in hd0.pbi VOAPP1.psi VOAPP2.psi; do
  cp --reflink=auto "$PRISTINE/$f" "$WORK/$f"
done
# @ASSETS@ -> this station's asset path: the ROM `load` lines need an absolute
# path inside the container, and the assets are bound at their own host path.
sed "s|@ASSETS@|$ASSETS|g" "$ASSETS/pce.cfg" >"$WORK/pce.cfg"
cp "$INNER" "$WORK/inner.sh"
chmod 755 "$WORK/inner.sh"
chown -R "$UIDBASE:$UIDBASE" "$WORK" "$X11DIR"
chmod 1777 "$X11DIR"

# --- the sandbox --------------------------------------------------------------
nohup systemd-nspawn --quiet --register=no --keep-unit --as-pid2 \
  --machine="$MACHINE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" \
  --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$ASSETS" --bind="$WORK:/work" --bind="$X11DIR:/tmp/.X11-unix" \
  --setenv=VISION_DISPLAY="$DISP" --setenv=VISION_GEOM="$GEOM" \
  --setenv=VISION_ASSETS="$ASSETS" \
  --setenv=VISION_AUTOSTART="${VISION_AUTOSTART:-1}" \
  --kill-signal=SIGTERM --console=pipe \
  /bin/bash /work/inner.sh >"$BASE/pce.log" 2>&1 </dev/null &
echo $! >"$NSPAWN_PIDFILE"

# --- the daemon's door: /tmp/.X11-unix/X<n> -> the sandbox's socket FILE -------
SOCK="$X11DIR/X${DISP#:}"
for _ in $(seq 1 80); do
  [ -S "$SOCK" ] && break
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "vision[$TILE]: the sandbox died at launch — tail of pce.log:" >&2
    tail -20 "$BASE/pce.log" >&2
    exit 1
  }
  sleep 0.25
done
[ -S "$SOCK" ] || {
  echo "vision[$TILE]: no X socket at $SOCK after 20 s" >&2
  exit 1
}
mkdir -p /tmp/.X11-unix
HOSTSOCK="/tmp/.X11-unix/X${DISP#:}"
if [ -e "$HOSTSOCK" ] && [ ! -L "$HOSTSOCK" ]; then
  echo "vision[$TILE]: $HOSTSOCK exists and is not our symlink — another X server owns $DISP" >&2
  exit 1
fi
ln -sfn "$SOCK" "$HOSTSOCK"

# --- PCE's HOST pid for the pidfile (the daemon's freezer needs it) -----------
PPID_EMU=""
for _ in $(seq 1 120); do
  PPID_EMU="$(station_emu_pids | head -1)"
  [ -n "$PPID_EMU" ] && break
  kill -0 "$(cat "$NSPAWN_PIDFILE")" 2>/dev/null || {
    echo "vision[$TILE]: the sandbox died before PCE started — tail of pce.log:" >&2
    tail -20 "$BASE/pce.log" >&2
    exit 1
  }
  sleep 0.25
done
[ -n "$PPID_EMU" ] || {
  echo "vision[$TILE]: pce-ibmpc did not appear in 30 s — tail of pce.log:" >&2
  tail -20 "$BASE/pce.log" >&2
  exit 1
}
echo "$PPID_EMU" >"$PIDFILE"
echo "vision[$TILE]: sandbox nspawn pid=$(cat "$NSPAWN_PIDFILE") pce-ibmpc pid=$PPID_EMU (host uid $UIDBASE) display=$DISP root=$GEOM (cold boot of the 5160 from a fresh disk set)"

# --- standby: freeze at the scene once the boot has settled -------------------
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${VISION_STANDBY_DELAY_S:-120}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = /opt/pce/bin/pce-ibmpc ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "vision[$TILE]: standby — frozen at the scene (pid $p; first session wakes it)"
  ) &
fi
