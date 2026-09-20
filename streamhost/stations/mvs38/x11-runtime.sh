#!/bin/bash
# =============================================================================
# stations/mvs38/x11-runtime.sh — launcher for the MVS 3.8j station, CONTAINED.
# Started by ensure-station-x11.sh inside the streamhost@mvs38 BindsTo scope.
#
# IBM OS/VS2 MVS 3.8j (1981 service level) on an emulated IBM System/370 under
# Hercules, packaged as the TK5 distribution. No QEMU, no MAME, no checkpoint:
# the exhibit is a mainframe emulator plus one 3270 terminal, and reset =
# relaunch from the pristine TK5 DASD volumes.
#
# CONTAINMENT (docs/lab/record-wave/HOST-APP-CONTAINER-CONTRACT.md, the proven
# medley/vision/lisa/perq/vax43bsd shape): Hercules, Xvfb and the visitor's
# x3270 all run inside a systemd-nspawn container — own PID/mount/IPC/UTS/user
# namespaces, --private-users so root inside is host uid MVS38_UIDBASE,
# --private-network so Hercules' stock CNSLPORT 3270 and its HTTP port 8038
# bind the CONTAINER's loopback and claim nothing on the host,
# --volatile=overlay throwaway root over a minimal Debian tree, the TK5 tree
# and the container rootfs bound READ-ONLY at their host paths, work/ the only
# writable bind, CAP_SYS_ADMIN & friends dropped, mount syscalls filtered,
# no-new-privileges. MVS 3.8j is 1981 software with no security model worth the
# name — the containment, not the guest, is the security boundary.
#
# The X socket lives in a host directory bound over the container's
# /tmp/.X11-unix, with /tmp/.X11-unix/X<n> on the host a symlink to it, so
# capture (SH_CAPTURE=x11), XTEST input, `labctl shot` and xdotool are unchanged.
#
# Pidfile contract (ensure-station-x11.sh / stop-station-x11.sh, idle.rs):
#   mame.pid   the Hercules HOST-visible pid — the daemon SIGSTOP/SIGCONTs it
#   xvfb.pid   the container's Xvfb, host pid
#   nspawn.pid the systemd-nspawn supervisor (reaped so no container lingers)
# =============================================================================
set -euo pipefail

TILE="${SH_STATION:?SH_STATION not set — run under streamhost@<tile>}"
BASE="${MVS38_BASE:-/data/vms/streamhost/stations/$TILE}"
ASSETS="${MVS38_ASSETS:-/data/vms/streamhost/assets/$TILE}"
GEOM="${MVS38_GEOM:-1024x768}"
DISP="${SH_X11_DISPLAY:?SH_X11_DISPLAY not set}"
PORT="${MVS38_PORT:-3270}"
ROOTFS="${MVS38_ROOTFS:-$ASSETS/rootfs}"
UIDBASE="${MVS38_UIDBASE:-2097152}"
SOCKDIR="${MVS38_X11_SOCKDIR:-/run/streamhost/x11/$TILE}"
TK5="$ASSETS/tk5"
BIN="$TK5/hercules/linux/64/bin/hercules"
HERE="$(dirname "$(readlink -f "$0")")"
INNER="$HERE/nspawn-inner.sh"
SHARED="$HERE/shared-terminal-runtime.sh"
SESSION="$HERE/x3270-session.sh"
LOGO="$HERE/herclogo.txt"
PASSFILE="${MVS38_TSO_PASS_FILE:-$ASSETS/tso.pass}"
PIDFILE="$BASE/mame.pid" # the x11-runtime pidfile name, not a MAME claim
XPIDFILE="$BASE/xvfb.pid"
NPIDFILE="$BASE/nspawn.pid"
XSOCK="/tmp/.X11-unix/X${DISP#:}"
WINTITLE="${MVS38_WINTITLE:-MVS 3.8j}"
FONT="${MVS38_FONT:-3270-20}"
MVS38_FONT_FILE="$FONT.pcf.gz"

# The TK5 zip carries NO exec bits (docs/lab/MVS38-WAVE.md): after `unzip`,
# hercules and every TK5 script is mode 0644 and the first launch dies with
# "Permission denied". The builder chmods them; this is the guard that the
# staged tree really did get that treatment.
[ -x "$BIN" ] || {
  echo "mvs38[$TILE]: no executable Hercules at $BIN (TK5 zip ships mode 0644 — the builder must chmod +x)" >&2
  exit 1
}
[ -f "$TK5/conf/tk5.cnf" ] || {
  echo "mvs38[$TILE]: no TK5 config at $TK5/conf/tk5.cnf" >&2
  exit 1
}
[ -f "$TK5/dasd/tk5res.390" ] || {
  echo "mvs38[$TILE]: no MVSRES volume at $TK5/dasd/tk5res.390" >&2
  exit 1
}
[ -x "$ROOTFS/usr/bin/x3270" ] || {
  echo "mvs38[$TILE]: no container rootfs at $ROOTFS" >&2
  exit 1
}
# xfonts-x3270-misc is a *Recommends* of x3270 and debootstrap --variant=minbase
# skips Recommends, so this tree can look complete and still have no 3270 font
# at all — x3270 then dies at startup (docs/lab/MVS38-WAVE.md).
[ -f "$ROOTFS/usr/share/fonts/X11/misc/$MVS38_FONT_FILE" ] || {
  echo "mvs38[$TILE]: no 3270 fonts in $ROOTFS (install xfonts-x3270-misc explicitly)" >&2
  exit 1
}
for f in "$INNER" "$SHARED" "$SESSION" "$LOGO"; do
  [ -f "$f" ] || {
    echo "mvs38[$TILE]: missing $f" >&2
    exit 1
  }
done

# --- reap: Hercules by exe (scoped to this station's asset dir, which is bound
# at its host path inside the container so /proc/<pid>/exe agrees), then any
# supervisor left over. SIGCONT before TERM — a SIGSTOPped emulator never
# handles TERM. Refuse to start over a survivor.
#
# Resolve by /proc/<pid>/exe (AGENTS.md rule 5 — never a cmdline grep), but in
# ONE fork instead of one `readlink` per pid. MEASURED 2026-09-20 on a loaded
# box: the per-pid loop cost 13.4 s per scan at 1322 PIDs, the launcher calls it
# once to reap and once per wait iteration, and the unit's 90 s start-pre
# timeout then killed every restart (the medley incident in
# docs/lab/MVS38-WAVE.md). `find -lname` matches the same symlink target,
# including a "... (deleted)" exe, in ~0.05 s.
station_vm_pids() {
  find /proc -mindepth 2 -maxdepth 2 -name exe -lname "$TK5/hercules/*" \
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
  # systemd-nspawn leaves /run/systemd/nspawn/unix-export/<machine> mounted if
  # the container dies without its supervisor reaping it, and the NEXT start
  # then refuses outright:
  #   Mount point '/run/systemd/nspawn/unix-export/kh-mvs38' exists already
  # MEASURED 2026-09-20 — one uncleanly-stopped container wedges every restart
  # of the station from then on, which is exactly the shape of failure a
  # visitor would see as a permanently dead exhibit. Clear it here, but only
  # once nothing of ours is alive.
  local ux="/run/systemd/nspawn/unix-export/kh-$TILE"
  if [ -z "$(station_vm_pids)" ] && [ -d "$ux" ]; then
    umount "$ux" 2>/dev/null || true
    rmdir "$ux" 2>/dev/null || true
  fi
  sleep 0.5
  [ -z "$(station_vm_pids)" ]
}

reap_previous || {
  echo "mvs38[$TILE]: previous Hercules still alive after SIGKILL:" \
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
  echo "mvs38[$TILE]: $XSOCK exists and is not our symlink — display $DISP is someone else's" >&2
  exit 1
fi
mkdir -p /tmp/.X11-unix
ln -sfn "$SOCKDIR/X${DISP#:}" "$XSOCK"

# --- pristine per-launch state. work/tk5 is a HYBRID tree: the inert 254 MB of
# it (the Hercules build, the docs, the optional Packages) are SYMLINKS into the
# read-only bind, and only what MVS actually writes is copied. The copy is the
# 270 MB of DASD volumes, and on this ZFS it is a block clone — MEASURED
# 2026-09-20: `cp -a` of dasd/ is ~1.2 s and costs no space
# (zpool feature@block_cloning = active). That is the whole reset cost.
rm -rf "$BASE/work"
mkdir -p "$BASE/work/tk5"
# read-only by nature: nothing under these is written by a running MVS.
for d in hercules doc Packages jcl ctca_demo local_scripts; do
  [ -e "$TK5/$d" ] && ln -sfn "$TK5/$d" "$BASE/work/tk5/$d"
done
# herclogo.txt is OURS, not TK5's. Hercules paints this file on a 3270 the
# moment it connects and before the guest writes anything, and the stock TK5
# copy fills the top of it with $(VERSION), $(HOSTNAME), $(HOSTOS),
# $(HOSTARCH), $(HOSTNUMCPUS) and $(LPARNAME) — the emulator's version and the
# LABHOST's name, kernel and core count, on the museum's own framebuffer. The
# committed replacement keeps TK5's artwork and credits and the two facts that
# belong to the emulated machine (device number and subchannel), and states
# nothing about the host.
install -m 0444 "$LOGO" "$BASE/work/tk5/herclogo.txt"
# written by MVS, by JES2 or by the TK5 scripts — real copies, every launch.
for d in dasd log prt pch rdr tape conf scripts local_conf unattended; do
  [ -e "$TK5/$d" ] && cp -a "$TK5/$d" "$BASE/work/tk5/$d"
done
chown -R "$UIDBASE:$UIDBASE" "$BASE/work"
chmod -R u+rwX "$BASE/work/tk5/dasd" "$BASE/work/tk5/log" "$BASE/work/tk5/prt" \
  "$BASE/work/tk5/pch" "$BASE/work/tk5/rdr" "$BASE/work/tk5/tape"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$INNER" "$BASE/work/nspawn-inner.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$SHARED" "$BASE/work/shared-terminal-runtime.sh"
install -m 0755 -o "$UIDBASE" -g "$UIDBASE" "$SESSION" "$BASE/work/x3270-session.sh"
# The TSO password is box-local and NEVER in the repository (the playbook's
# rule: no real credential in tracked source, docs, screenshots or logs). With
# no such file the station still comes up — x3270-session.sh leaves the
# terminal at the VTAM screen and says so — so a fresh clone is degraded, not
# broken.
if [ -s "$PASSFILE" ]; then
  install -m 0600 -o "$UIDBASE" -g "$UIDBASE" "$PASSFILE" "$BASE/work/tso.pass"
else
  echo "mvs38[$TILE]: no TSO password at $PASSFILE — the exhibit will rest on the" \
    "VTAM screen instead of the ISPF primary option menu" >&2
fi

nohup systemd-nspawn \
  --quiet --register=no --keep-unit --as-pid2 \
  --machine="kh-$TILE" --uuid="$(printf '%032x' "$UIDBASE")" \
  --directory="$ROOTFS" --volatile=overlay \
  --private-users="$UIDBASE:65536" --private-users-ownership=off \
  --private-network \
  --drop-capability=CAP_SYS_ADMIN,CAP_SYS_MODULE,CAP_SYS_RAWIO,CAP_SYS_PTRACE,CAP_MKNOD,CAP_NET_ADMIN,CAP_NET_RAW,CAP_SYS_BOOT,CAP_SYS_TIME,CAP_AUDIT_WRITE,CAP_AUDIT_CONTROL,CAP_SYS_CHROOT,CAP_SETFCAP,CAP_LINUX_IMMUTABLE \
  --no-new-privileges=yes \
  --system-call-filter='~@mount' \
  --bind-ro="$TK5" \
  --bind="$BASE/work:/work" \
  --bind="$SOCKDIR:/tmp/.X11-unix" \
  --setenv=SH_X11_DISPLAY="$DISP" \
  --setenv=MVS38_ASSETS="$ASSETS" \
  --setenv=MVS38_GEOM="$GEOM" \
  --setenv=MVS38_PORT="$PORT" \
  --setenv=MVS38_FONT="$FONT" \
  --setenv=MVS38_MODEL="${MVS38_MODEL:-3279-2-E}" \
  --setenv=MVS38_WINTITLE="$WINTITLE" \
  --setenv=MVS38_READY_TIMEOUT_S="${MVS38_READY_TIMEOUT_S:-420}" \
  --setenv=HOME=/work --setenv=TERM=vt100 \
  --kill-signal=SIGTERM --console=pipe \
  /work/nspawn-inner.sh \
  >"$BASE/mvs38.log" 2>&1 </dev/null &
echo $! >"$NPIDFILE"

# MVS 3.8j reaches `IKT005I TCAS IS INITIALIZED` — the point at which TSO will
# accept a logon — 47 s after Hercules exec (MEASURED 2026-09-20, box at load
# 139). The CNSLPORT listener is open at +8 s and means nothing; see
# docs/lab/record-wave/shared-terminal-runtime.sh finding 1. Wait on the real
# things: the Hercules pid, the X socket, and the 3270 window actually mapped —
# never on a guessed sleep.
HPID=""
for _ in $(seq 1 "${MVS38_LAUNCH_TIMEOUT_S:-480}"); do
  kill -0 "$(cat "$NPIDFILE")" 2>/dev/null || {
    echo "mvs38[$TILE]: container died at launch — tail of mvs38.log:" >&2
    tail -40 "$BASE/mvs38.log" >&2
    tail -60 "$BASE/work/emulator.log" 2>/dev/null >&2 || true
    exit 1
  }
  HPID="$(station_vm_pids | head -1)"
  if [ -n "$HPID" ] && [ -S "$SOCKDIR/X${DISP#:}" ] &&
    xwininfo -root -tree -display "$DISP" 2>/dev/null | grep -q "$WINTITLE"; then
    break
  fi
  HPID=""
  sleep 1
done
[ -n "$HPID" ] || {
  echo "mvs38[$TILE]: no 3270 window — tail of mvs38.log:" >&2
  tail -40 "$BASE/mvs38.log" >&2
  tail -60 "$BASE/work/emulator.log" 2>/dev/null >&2 || true
  exit 1
}

# --- focus, and wait for the VTAM screen to actually paint.
#
# No window manager runs in the container, so X input focus is PointerRoot and
# keystrokes reach x3270 only while the pointer happens to be over it. The
# daemon drives this station with XTEST keys and never moves a pointer (there is
# none in the exhibit), so without an explicit XSetInputFocus a visitor's typing
# would land on the root window and vanish. `xdotool windowfocus` pins it once,
# for good. [PROVEN on vax43bsd 2026-09-20, same container shape.]
#
# Unlike a getty on a tty line, VTAM PUSHES its logon panel to a 3270 the
# instant the session binds, so no wake keystroke is needed. What IS needed is
# the proof that the panel arrived: bring-up gates on the lit-pixel count
# settling above an empty-screen floor, so the station never reports ready on a
# black 3270.
export DISPLAY="$DISP"
nlit() {
  xwd -display "$DISP" -root -silent 2>/dev/null |
    convert xwd:- -colorspace Gray -threshold 25% -format '%[fx:int(mean*w*h)]' info: 2>/dev/null || echo 0
}
WIN="$(xdotool search --name "$WINTITLE" 2>/dev/null | head -1 || true)"
if [ -n "$WIN" ]; then
  xdotool windowfocus "$WIN" 2>/dev/null || true
  # Centre it. x3270 sizes itself from the 3270 font — a 24x80 screen in
  # 3270-20 is not a size the launcher can predict — and with no window manager
  # in the container nothing else will place it, so it would otherwise sit at
  # +0+0 with the black root filling the bottom right of every frame.
  read -r WW WH < <(xdotool getwindowgeometry --shell "$WIN" 2>/dev/null |
    sed -n 's/^WIDTH=//p;s/^HEIGHT=//p' | paste -sd' ')
  if [ -n "${WW:-}" ] && [ -n "${WH:-}" ]; then
    RW="${GEOM%x*}"
    RH="${GEOM#*x}"
    X=$(((RW - WW) / 2))
    Y=$(((RH - WH) / 2))
    [ "$X" -lt 0 ] && X=0
    [ "$Y" -lt 0 ] && Y=0
    xdotool windowmove "$WIN" "$X" "$Y" 2>/dev/null || true
    echo "mvs38[$TILE]: 3270 window ${WW}x${WH} centred at +${X}+${Y} on $GEOM"
  fi
fi
# TWO INDEPENDENT GATES, and they are deliberately NOT the same check.
#
#  * work/logon.ok is the IDENTITY gate. x3270-session.sh writes it only after
#    x3270's own Ascii() shows `ISPF primary option menu` — the destination,
#    read out of the 3270 data stream, where one screen is distinguishable
#    from the next.
#  * the lit-pixel floor is the FRAMEBUFFER gate: proof that the X root this
#    station publishes actually carries a painted screen, and not that the
#    logon merely happened somewhere the visitor cannot see.
#
# The floor is NOT a second identity check, because on this station a pixel
# count cannot be one. MEASURED 2026-09-20 on this display:
#     ISPF primary option menu   32512
#     Hercules device logo       27811   <- only 17% below the destination
#     blank 3270 + a message      5747..6575
#     BLANK 3270 under x3270's menu bar  25765
# That last line is the first build of this station: a 6000-px floor passed
# with 25765 lit pixels that were entirely File/Options MENU BAR over a
# completely blank 3270 — the "landed, then showed a black screen" failure.
# A floor of 20000 separates any painted screen from every blank one by more
# than 3x, and logon.ok is what says WHICH painted screen it is. The bad frame
# above would still clear the floor; it would never have had logon.ok.
FLOOR="${MVS38_PANEL_LIT_PX:-20000}"
got=0
prev=-1
same=0
for _ in $(seq 1 "${MVS38_PANEL_TRIES:-600}"); do
  sleep 0.5
  [ -f "$BASE/work/logon.ok" ] || continue
  got="$(nlit)"
  if [ "$got" -ge "$FLOOR" ]; then
    if [ "$got" = "$prev" ]; then
      same=$((same + 1))
      [ "$same" -ge 4 ] && break
    else
      same=0
    fi
  fi
  prev="$got"
done
if [ "$got" -ge "$FLOOR" ]; then
  echo "mvs38[$TILE]: ISPF primary option menu on the framebuffer ($got lit px, floor $FLOOR)"
else
  echo "mvs38[$TILE]: WARNING — the rest scene is not the ISPF menu (lit px $got," \
    "wanted $FLOOR; logon.ok $([ -f "$BASE/work/logon.ok" ] && echo present || echo absent))" >&2
fi

echo "$HPID" >"$PIDFILE"
XV=""
for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ "$(readlink "/proc/$p/ns/pid" 2>/dev/null)" = "$(readlink "/proc/$HPID/ns/pid" 2>/dev/null)" ] || continue
  case "$(readlink "/proc/$p/exe" 2>/dev/null)" in */Xvfb) XV="$p" ;; esac
done
[ -n "$XV" ] && echo "$XV" >"$XPIDFILE"
echo "mvs38[$TILE]: hercules=$HPID xvfb=${XV:-?} nspawn=$(cat "$NPIDFILE") display=$DISP geom=$GEOM cnslport=$PORT uidbase=$UIDBASE (contained relaunch from the pristine TK5 DASD)"

# Standby: freeze Hercules once the logon panel has settled; the daemon owns
# the steady state via SH_IDLE_PAUSE_PIDFILE and SIGCONTs on the first session.
# A frozen System/370 costs no core between visitors.
if [ -n "${SH_IDLE_PAUSE_PIDFILE:-}" ] && [ "${SH_IDLE_PAUSE_SECS:-60}" != 0 ]; then
  (
    sleep "${MVS38_STANDBY_DELAY_S:-45}"
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] || exit 0
    exe="$(readlink "/proc/$p/exe" 2>/dev/null)"
    [ "${exe% (deleted)}" = "$BIN" ] || exit 0
    kill -STOP "$p" 2>/dev/null &&
      echo "mvs38[$TILE]: standby — frozen at the TSO logon panel (pid $p; first session wakes it)"
  ) &
fi
