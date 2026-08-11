#!/usr/bin/env bash
# irix-serial-rig.sh — namespaced IRIX/MAME clone with the serial exec channel
# wired, for BAKING and VERIFYING the golden that carries irixagent.pl.
#
# Everything lives under /data/vms/soltest/irix-serial/<name>/ — never the
# production station tree — and every kill goes through clone-guard. The golden is
# never opened: each boot gets its own `cp --reflink=always` copy (0.13 s for
# 2.24 GB), because MAME opens an uncompressed CHD O_RDWR and runs as root.
#
#   irix-serial-rig.sh boot   <name> [--chd PATH] [--capture x11|shm]
#                                    [--display N] [--console] [--wait SECS]
#   irix-serial-rig.sh pts    <name>          # host end of the agent line
#   irix-serial-rig.sh exec   <name> "<cmd>"  # labctl-exec equivalent
#   irix-serial-rig.sh ping   <name> [--agent-src PATH]   # which agent is baked?
#   irix-serial-rig.sh console <name> "<line>"  # blind line on the ttyd1 getty
#   irix-serial-rig.sh shot   <name> [out.png]
#   irix-serial-rig.sh halt   <name>          # clean IRIX halt (bake-safe)
#   irix-serial-rig.sh stop   <name>
#
# SERIAL WIRING (see streamhost/guest-agents/irix/README.md)
#   ioc2:rs232a == IRIX /dev/ttyd2 — the agent line. `pty` endpoint: MAME opens
#     /dev/ptmx once and the host opens the slave as often as it likes. The
#     `socket.` endpoint CANNOT be used: MAME closes its listener after the
#     first accept and never re-accepts (verified 2026-08-03), so a one-shot
#     exec client would work exactly once per MAME run.
#   ioc2:rs232b == IRIX /dev/ttyd1 — the `console` getty from /etc/inittab t1.
#     Only wired with --console (the bake's install channel); production leaves
#     it unpopulated, exactly as the exhibit ships today.
#   Both host ends are ptys, so both slaves are put in raw -echo at boot: a pts
#     defaults to ECHO ON, which would bounce every byte the guest sends back
#     into the guest.
set -u

ROOT="${IRIX_SERIAL_ROOT:-/data/vms/soltest/irix-serial}"
ASSETS="${IRIX_ASSETS:-/data/vms/streamhost/assets/irix}"
MAME_BIN="${IRIX_MAME:-$ASSETS/mame/sgi}"
AGENT_SRC="${IRIX_AGENT:-$ASSETS/irixagent.lua}"
EXEC_CLIENT="${IRIX_EXEC_CLIENT:-/root/irixexec.py}"

die() {
  echo "irix-serial-rig: $*" >&2
  exit 1
}
log() { echo "$(date '+%F %T') $*"; }

[ -x /usr/local/bin/clone-guard ] || die "clone-guard missing"
# shellcheck source=/dev/null
. /usr/local/bin/clone-guard

CMDNAME="${1:-}"
[ -n "$CMDNAME" ] || die "usage: see header"
shift
NAME="${1:-}"
[ -n "$NAME" ] || die "missing <name>"
shift
case "$NAME" in
  */* | .*) die "clone name must be a plain identifier" ;;
esac
D="$ROOT/$NAME"

CHD="$ASSETS/irix65-apps-v3.chd"
CAPTURE=x11
DISPNUM=170
CONSOLE=0
WAIT=600
while [ $# -gt 0 ]; do
  case "$1" in
    --chd)
      CHD="$2"
      shift 2
      ;;
    --capture)
      CAPTURE="$2"
      shift 2
      ;;
    --display)
      DISPNUM="$2"
      shift 2
      ;;
    --console)
      CONSOLE=1
      shift
      ;;
    --wait)
      WAIT="$2"
      shift 2
      ;;
    *) break ;;
  esac
done
DISP=":$DISPNUM"
XSOCK="/tmp/.X11-unix/X$DISPNUM"

# The host ends of the rs232 slots, one per line, in MAME's device-creation
# order (rs232a first, then rs232b). MAME never prints a slave name (dipty.cpp
# only stores it), so they are scraped out of the emulator's own fd table: every
# fd pointing at /dev/ptmx, ascending, whose fdinfo carries the pts index.
find_pts() {
  local p f idx
  p="$(cat "$D/mame.pid" 2>/dev/null || true)"
  [ -n "$p" ] && [ -e "/proc/$p" ] || return 1
  for f in $(printf '%s\n' /proc/"$p"/fd/* | sort -t/ -k5 -n); do
    [ "$(readlink "$f" 2>/dev/null || true)" = /dev/ptmx ] || continue
    idx="$(awk '/^tty-index:/ { print $2 }' "/proc/$p/fdinfo/$(basename "$f")" 2>/dev/null || true)"
    [ -n "$idx" ] || continue
    echo "/dev/pts/$idx"
  done
}

agent_pts() { find_pts | sed -n 1p; }
console_pts() { find_pts | sed -n 2p; }

start_mame() {
  local ser=(-ioc2:rs232a pty) vid disp
  # The retry loop calls this again after a failed boot: without this the old
  # emulator survives, keeps drawing into the same Xvfb and holds its own pair
  # of ptys, and everything downstream talks to the wrong one.
  clone_guard_kill_pidfile "$D/mame.pid"
  [ "$CONSOLE" = 1 ] && ser+=(-ioc2:rs232b pty)
  if [ "$CAPTURE" = shm ]; then
    vid=(-video none)
    disp=(env -u DISPLAY -u SDL_VIDEODRIVER "IRIX_SHM_PATH=$D/fb.shm")
    rm -f -- "$D/fb.shm"
  else
    vid=(-video soft -mouse -background_input)
    disp=(env "DISPLAY=$DISP" SDL_VIDEODRIVER=x11)
  fi
  rm -f -- "$D/disk.chd"
  cp --reflink=always -- "$CHD" "$D/disk.chd"
  chmod 644 -- "$D/disk.chd"
  : >"$D/cmd"
  "${disp[@]}" "IRIX_CMD=$D/cmd" setsid \
    "$MAME_BIN" indy_4610 -bios b10 -rompath "$ASSETS/roms" -gio64_gfx xl24 \
    -hard1 "$D/disk.chd" "${ser[@]}" \
    -nvram_directory "$D/nvram" -inipath "$ASSETS/uicfg" \
    -skip_gameinfo "${vid[@]}" -sound none -frameskip "${IRIX_FRAMESKIP:-6}" \
    -autoboot_script "$D/irixagent.lua" -autoboot_delay 0 \
    </dev/null >"$D/mame.log" 2>&1 &
  echo "$!" >"$D/mame.pid"
  sleep 5
  [ -e "/proc/$(cat "$D/mame.pid")" ] || {
    cat "$D/mame.log" >&2
    die "MAME did not start"
  }
}

# Non-black framebuffer == the guest is drawing. Never infer from logs.
fb_bright() {
  if [ "$CAPTURE" = shm ]; then
    python3 "${IRIX_FBSTAT:-/data/vms/streamhost/tiles/irix/fbstat.py}" "$D/fb.shm" 2>/dev/null
  else
    DISPLAY="$DISP" import -window root "$D/.watch.png" 2>/dev/null || return 1
    identify -format '%[fx:max(mean.r,max(mean.g,mean.b))]' "$D/.watch.png" 2>/dev/null
  fi
}

cmd_boot() {
  [ -f "$CHD" ] || die "missing golden $CHD"
  [ -f "$MAME_BIN" ] || die "missing MAME $MAME_BIN"
  mkdir -p "$D/nvram"
  cp -f "$AGENT_SRC" "$D/irixagent.lua"
  cp -r "$ASSETS/nvram/." "$D/nvram/"
  if [ "$CAPTURE" != shm ]; then
    rm -f -- "$XSOCK"
    setsid Xvfb "$DISP" -screen 0 1280x1024x24 -nolisten tcp </dev/null >"$D/xvfb.log" 2>&1 &
    echo "$!" >"$D/xvfb.pid"
    for _ in $(seq 1 40); do
      [ -S "$XSOCK" ] && break
      sleep 0.25
    done
    [ -S "$XSOCK" ] || die "Xvfb $DISP did not come up"
  fi
  # A cold boot hangs on a permanently black framebuffer often enough that the
  # production launcher carries a watchdog for it; the only recovery is a
  # relaunch, so the rig retries too.
  local attempt
  for attempt in 1 2 3; do
    start_mame
    log "boot attempt $attempt/3 ($NAME capture=$CAPTURE chd=$CHD console=$CONSOLE)"
    if ! wait_paint; then
      log "framebuffer stayed black — relaunching"
      continue
    fi
    agent_pts >"$D/serial.pts"
    [ -s "$D/serial.pts" ] || die "could not find the MAME pty"
    find_pts | while read -r p; do stty -F "$p" raw -echo; done
    # A painted framebuffer only means MAME is alive — the PROM splash paints at
    # ~10 s and the login prompt is four minutes later. Readiness is the CHANNEL
    # answering: the console getty replying to a newline (--console, the bake),
    # or the agent replying to a PING (a baked golden being verified).
    if wait_ready; then
      log "ready. agent line: $(cat "$D/serial.pts")   dir: $D"
      return 0
    fi
    log "no answer on the serial line — relaunching"
  done
  die "$NAME never became ready"
}

# The framebuffer stops being black once the PROM splash paints, ~10 s in.
wait_paint() {
  local t0 m
  t0=$(date +%s)
  while [ $(($(date +%s) - t0)) -lt "${IRIX_PAINT_WAIT:-120}" ]; do
    sleep 10
    m="$(fb_bright || echo 0)"
    awk -v m="$m" 'BEGIN { exit !(m > 0.3) }' 2>/dev/null && return 0
  done
  return 1
}

# The console getty is up at runlevel 2, MINUTES before xdm paints the login
# chooser — and typing a whole agent into the console while the rest of the boot
# is still running has twice left the guest wedged on a black framebuffer.
# So console mode also waits for the chooser, by CONTENT: the measured signature
# is mean 0.654-0.659 / sd 0.226-0.231 (a bare X root is 0.578/0.157), from the
# same table irix-park-desktop.sh uses.
wait_login_screen() {
  local t0 m sd
  [ "$CAPTURE" = x11 ] || return 0
  t0=$(date +%s)
  while [ $(($(date +%s) - t0)) -lt "${IRIX_LOGIN_WAIT:-420}" ]; do
    if DISPLAY="$DISP" import -window root "$D/.watch.png" 2>/dev/null; then
      m="$(identify -format '%[fx:mean]' "$D/.watch.png" 2>/dev/null || echo 0)"
      sd="$(identify -format '%[fx:standard_deviation]' "$D/.watch.png" 2>/dev/null || echo 0)"
      if awk -v m="$m" -v s="$sd" 'BEGIN { exit !(m > 0.60 && s > 0.20) }'; then
        log "login chooser painted after $(($(date +%s) - t0))s (mean=$m sd=$sd)"
        return 0
      fi
    fi
    sleep 15
  done
  log "WARNING: the login chooser never painted; the guest may still be booting"
  return 0
}

wait_ready() {
  local t0 pts probe
  t0=$(date +%s)
  pts="$(console_pts)"
  while [ $(($(date +%s) - t0)) -lt "$WAIT" ]; do
    if [ "$CONSOLE" = 1 ]; then
      # Nothing runs on ttyd1 until init starts the t1 getty, so ANY byte back
      # is the signal. (What it says is unreadable anyway: the kernel's own
      # writes overrun MAME's SCC — see the PACING note in irixagent.pl.)
      : >"$D/.console-probe"
      timeout 6 cat "$pts" >"$D/.console-probe" 2>/dev/null &
      probe=$!
      sleep 1
      printf '\r' >"$pts"
      # `wait $probe`, never a bare `wait` — the Xvfb this script also
      # backgrounded would otherwise be waited on, i.e. for ever.
      wait "$probe" 2>/dev/null || true
      if [ -s "$D/.console-probe" ]; then
        log "console getty answered after $(($(date +%s) - t0))s"
        wait_login_screen
        return 0
      fi
    else
      if cmd_exec "echo READY" --timeout 15 2>/dev/null | grep -q READY; then
        log "agent answered after $(($(date +%s) - t0))s"
        return 0
      fi
    fi
    sleep 10
  done
  return 1
}

cmd_pts() {
  find_pts
}

cmd_exec() {
  [ $# -ge 1 ] || die 'usage: exec <name> "<cmd>"'
  IRIX_SERIAL_PTS="$(agent_pts)" python3 "$EXEC_CLIENT" "$D" "$@"
}

# Banner + the checksum the agent computed over its OWN source, which is the
# only way to see which version a golden actually carries without mounting it.
# With an --agent-src the client exits 126 when the guest is running something
# other than that file.
cmd_ping() {
  IRIX_SERIAL_PTS="$(agent_pts)" python3 "$EXEC_CLIENT" "$D" --ping "$@"
}

# Blind line into the ttyd1 getty/login shell (the bake's install channel).
# Deliberately dumb: no capture, no framing — the console is only used to type
# the agent in ONCE, after which everything goes through `exec`.
cmd_console() {
  [ $# -ge 1 ] || die 'usage: console <name> "<line>"'
  local pts
  pts="$(console_pts)"
  [ -n "$pts" ] || die "no console pty (boot with --console)"
  printf '%s\r' "$1" >"$pts"
  sleep "${IRIX_CONSOLE_DELAY:-0.4}"
}

cmd_shot() {
  local out="${1:-/tmp/irix-$NAME.png}"
  [ "$CAPTURE" = shm ] && die "shot needs --capture x11 (shm mode has no X server)"
  DISPLAY="$DISP" import -window root "$out" || die "screendump failed"
  echo "$out"
}

# Clean IRIX shutdown, so the baked disk.chd carries a CLEAN XFS log and the
# next boot does not replay one. `shutdown` is detached (it kills the agent on
# its way down, so there is nobody left to answer), and the halt is confirmed by
# the channel GOING SILENT — not by a timer.
cmd_halt() {
  local t0
  cmd_exec "/etc/shutdown -y -i0 -g0" --detach --timeout 30 || true
  log "shutdown -i0 sent; waiting for the agent to stop answering"
  t0=$(date +%s)
  while [ $(($(date +%s) - t0)) -lt 240 ]; do
    sleep 10
    cmd_exec "echo up" --timeout 15 >/dev/null 2>&1 || {
      log "agent silent after $(($(date +%s) - t0))s — the guest is going down"
      break
    }
  done
  # IRIX unmounts and syncs after the last process dies; give it room, then take
  # the emulator down by pidfile through the guard.
  sleep 60
  [ "$CAPTURE" = shm ] || DISPLAY="$DISP" import -window root "$D/halted.png" 2>/dev/null || true
  clone_guard_kill_pidfile "$D/mame.pid"
  clone_guard_kill_pidfile "$D/xvfb.pid"
  rm -f -- "$XSOCK"
  log "baked image: $D/disk.chd  md5 $(md5sum "$D/disk.chd" | awk '{ print $1 }')"
}

cmd_stop() {
  clone_guard_kill_pidfile "$D/mame.pid"
  clone_guard_kill_pidfile "$D/xvfb.pid"
  rm -f -- "$XSOCK"
  log "stopped $NAME"
}

case "$CMDNAME" in
  boot) cmd_boot "$@" ;;
  pts) cmd_pts "$@" ;;
  exec) cmd_exec "$@" ;;
  ping) cmd_ping "$@" ;;
  console) cmd_console "$@" ;;
  shot) cmd_shot "$@" ;;
  halt) cmd_halt "$@" ;;
  stop) cmd_stop "$@" ;;
  *) die "unknown subcommand '$CMDNAME'" ;;
esac
