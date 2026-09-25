#!/bin/bash
# =============================================================================
# stations/nokia9300/nokia9300-inner.sh — what runs INSIDE the nokia9300
# station's sandbox: PID 2 of the systemd-nspawn container x11-runtime.sh
# starts (private PID, mount, network and USER namespace; the container's root
# is the unprivileged host uid NOKIA_UID_BASE — see the launcher).
#
# In here: the pinned Xvfb whose socket directory is bound out to the host for
# the daemon, then EKA2L1 on it in a SUPERVISED LOOP. Every launch starts from
# a fresh copy of the golden data dir (/golden, read-only), and when the
# emulator exits by itself — EKA2L1 closes when the app it was told to --run
# exits, and a host crash ends it too — it is relaunched from the golden again.
# Without the loop the exhibit would freeze on its last frame: the daemon's X
# capture keeps serving the last picture of a display that went quiet, and
# nothing else notices.
#
# GEOMETRY (measured 2026-09-24 on the dev box; docs/guests/nokia9300.md).
# EKA2L1 draws the 640x200 Series 80 screen into a native GL child window of
# its Qt display widget, scaled by the widget's WIDTH (mult = widget_w / 640,
# src/emu/qt/src/mainwindow.cpp). A display widget of exactly 1280x400 is
# therefore an exact 2x nearest-neighbour picture — all 128000 2x2 blocks of a
# captured Desk frame were uniform — and moving the top-level so that widget
# sits at root (0,0) of a 1280x400 root makes the captured root the phone
# screen and nothing else: the Qt menubar and status bar hang off the top and
# bottom edges of the root. The widget is FOUND, never assumed — its offsets
# depend on the Qt style and fonts of this container (a 22 px menubar plus a
# 9 px layout margin on the dev box) — so place() reads the GL child's parent
# and corrects the top-level by the difference. Two timing traps:
#   1. the GL surface is resized LAZILY, on the next present, and Desk only
#      presents when its screen changes: a window placed after the first guest
#      frame keeps the old-size picture until something repaints. So the first
#      placement happens the moment the window exists (~0.5 s after exec, 4.4 s
#      at host load 96), well before Desk's first frame (~2 s, 11 s at load 96);
#   2. EKA2L1 binds Ctrl+F to its own fullscreen toggle, which re-lays the
#      window out: keeper() re-places whenever the widget leaves 0,0,WxH.
# Both go away with agent B2's kiosk flags (no menubar, fixed geometry) —
# pass them in NOKIA_EMU_ARGS once the fork has them.
#
# INPUT. Keys arrive over XTEST from the daemon. There is no window manager,
# so X focus would stay PointerRoot; place() pins focus to the top-level with
# `xdotool windowfocus` (the its/vax43bsd trap), and EKA2L1 itself gives Qt
# focus to its display widget at app launch. No pointer: a Nokia 9300 has none.
#
# Paths are the container's:
#   $NOKIA_EMU_DIR  the EKA2L1 build, read-only, bound at its HOST path so the
#                   host's /proc/<pid>/exe names the real binary: eka2l1_qt +
#                   compat/ patch/ resources/ scripts/ (EKA2L1 copies those into
#                   its data dir at every start)
#   /golden         the golden XDG data root, read-only: EKA2L1/config.yml and
#                   EKA2L1/data/{devices.yml,roms/rae-6/SYM.ROM,drives/{c,d,e,z}}
#   /work           this launch's writable dir: xdg/ (the live data dir),
#                   config/ cache/ run/ home/, emulator.log, xvfb.log
#   /tmp/.X11-unix  bound to the host's socket dir (the daemon's door)
# Env from the launcher: NOKIA_DISPLAY, NOKIA_GEOM, NOKIA_EMU_DIR, NOKIA_DEVICE,
#   NOKIA_APP, NOKIA_EMU_ARGS, NOKIA_LOG_FILTER, NOKIA_WINDOW_TITLE
# Tools the rootfs must carry: Xvfb (with its own xkbcomp and xkb-data),
#   xdotool and xwininfo (x11-utils).
# =============================================================================
# Deliberately not -e: the supervision loop must outlive a failed xdotool call
# on a window that vanished mid-query.
set -uo pipefail

DISP="${NOKIA_DISPLAY:?}"
GEOM="${NOKIA_GEOM:-1280x400}"
GW="${GEOM%x*}"
GH="${GEOM#*x}"
EMU_DIR="${NOKIA_EMU_DIR:?}"
BIN="$EMU_DIR/eka2l1_qt"
DEVICE="${NOKIA_DEVICE:-RAE-6}"
APP="${NOKIA_APP:-0x101f8e4f}"
TITLE="${NOKIA_WINDOW_TITLE:-Symbian OS emulator}"
read -r -a EXTRA <<<"${NOKIA_EMU_ARGS:-}"
LOG_CAP_BYTES=$((64 * 1024 * 1024))
log() { echo "$(date -u +%FT%TZ) nokia9300-inner: $*"; }

XPID=""
EPID=""
KPID=""
shutdown() {
  [ -n "$KPID" ] && kill -KILL "$KPID" 2>/dev/null
  # EKA2L1 ignores SIGTERM (measured by agents S and F1): KILL it.
  [ -n "$EPID" ] && kill -KILL "$EPID" 2>/dev/null
  [ -n "$XPID" ] && kill -TERM "$XPID" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

# --- Xvfb: GLX for EKA2L1's OpenGL display path (Mesa llvmpipe) ---------------
# The joystick keysyms of the keymap contract (F13..F17, agent K1 v1) are not
# in a stock keymap: xkeyboard-config's inet(evdev) gives keycodes 191..195
# XF86Tools/XF86Launch5..8. A runtime remap does NOT stick on Xvfb 21.1 —
# measured 2026-09-24 on trixie and on Ubuntu 24.04: xmodmap and an xkbcomp
# upload both exit 0 and change nothing, even for a plain letter — so the
# server starts from its own copy of the XKB data with those five keys rebound
# (-xkbdir; proven on labhost the same day). The daemon resolves keysym ->
# keycode once, at its own startup, from this server's map.
XKB=/work/xkb
rm -rf "$XKB"
cp -R /usr/share/X11/xkb "$XKB"
sed -i -E 's/^(    key <FK1([3-7])> +\{ +\[ +)XF86[A-Za-z0-9]+( +\])/\1F1\2\3/' "$XKB/symbols/inet"
# The other keysyms keymap contract v3 injects (K1's station-xmodmap.txt): the
# characters of the UK and Nordic 9300 layouts a US keymap lacks, bound to
# named keys a stock keymap leaves empty. Only the keysym matters — xdotool and
# the daemon both resolve keysym -> keycode from the live map — so these are
# K1's keysyms, not K1's keycode numbers (93 has no XKB name at all).
sed -i -E '/^    key <FK17> +\{ +\[ +F17/a\
    key <I183> { [ EuroSign ] };\
    key <AB11> { [ sterling ] };\
    key <JPCM> { [ adiaeresis, Adiaeresis ] };\
    key <I120> { [ odiaeresis, Odiaeresis ] };\
    key <AE13> { [ aring, Aring ] };\
    key <I149> { [ ae, AE ] };\
    key <I154> { [ oslash, Ooblique ] };' "$XKB/symbols/inet"
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISP#:}"
# -ardelay 65000: every key is an injected press/release pair, and X's own
# autorepeat on a late release floods (ADD-NEW-OS-PLAYBOOK §5.1, the Oric
# lesson); EKA2L1 generates the Series 80 repeats itself and drops X's.
Xvfb "$DISP" -xkbdir "$XKB" -ardelay 65000 -screen 0 "${GEOM}x24" -nolisten tcp -ac \
  +extension GLX +render -noreset >/work/xvfb.log 2>&1 &
XPID=$!
for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    log "Xvfb died:"
    cat /work/xvfb.log
    exit 1
  }
  sleep 0.1
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  log "no X socket after 10 s"
  exit 1
}
export DISPLAY="$DISP"
# The socket appears before the server answers requests: retry for up to 5 s.
# Dump ONCE into a variable: `xkbcomp | grep -q` under pipefail reports a
# failure whenever grep exits early and xkbcomp takes SIGPIPE (measured: a
# false "missing" on a keymap that had every key).
kmap=missing
for _ in $(seq 1 50); do
  dump="$(xkbcomp "$DISP" - 2>/dev/null || true)"
  if grep -Eq 'key <FK13> *\{ *\[ *F13 *\]' <<<"$dump" &&
    grep -Eq 'key <I183> *\{ *\[ *EuroSign *\]' <<<"$dump"; then
    kmap=ok
    break
  fi
  sleep 0.1
done
if [ "$kmap" = ok ]; then
  log "keymap: F13..F17 (joystick) + EuroSign sterling ä ö å æ ø bound (keymap contract v3)"
else
  log "WARNING — F13/EuroSign not in the server's keymap: joystick and extra characters are dead"
fi

# B2's kiosk frontend (--kiosk ...) sizes and places its own window at the
# requested geometry; then the Qt-window placement below is not needed.
KIOSK=0
case " ${EXTRA[*]} " in *" --kiosk"*) KIOSK=1 ;; esac
kiosk_window() { xdotool search --onlyvisible --classname eka2l1_qt 2>/dev/null | head -1; }

export HOME=/work/home XDG_DATA_HOME=/work/xdg XDG_CONFIG_HOME=/work/config
export XDG_CACHE_HOME=/work/cache XDG_RUNTIME_DIR=/work/run QT_QPA_PLATFORM=xcb

# --- the data dir: a fresh copy of the golden for every launch ----------------
fresh_data() {
  rm -rf /work/xdg /work/config /work/cache /work/run /work/home
  mkdir -p /work/xdg /work/config /work/cache /work/run /work/home || return 1
  chmod 700 /work/run
  # -R, not -a: the golden's host owners are unmapped inside this user
  # namespace, and a failed ownership copy would fail the whole relaunch.
  cp -R /golden/. /work/xdg/ || return 1
  chmod -R u+w /work/xdg
  if [ -n "${NOKIA_LOG_FILTER:-}" ] && [ -f /work/xdg/EKA2L1/config.yml ]; then
    sed -i "s|^log-filter:.*|log-filter: \"$NOKIA_LOG_FILTER\"|" /work/xdg/EKA2L1/config.yml
  fi
}

# --- window placement ------------------------------------------------------------
wgeom() { # wgeom <window> -> "absx absy width height"
  xwininfo -id "$1" 2>/dev/null |
    awk '/Absolute upper-left X:/ {x = $4} /Absolute upper-left Y:/ {y = $4}
         /^ *Width:/ {w = $2} /^ *Height:/ {h = $2}
         END {if (h != "") print x, y, w, h}'
}
top_window() { xdotool search --name "$TITLE" 2>/dev/null | head -1; }
display_widget() {
  # EKA2L1's gl_x11_render_window is the only unnamed, classless window on
  # this display; the Qt display widget is its parent.
  local gl
  gl="$(xwininfo -root -tree 2>/dev/null | awk '/\(has no name\): \(\)/ {print $1; exit}')"
  [ -n "$gl" ] || return 1
  xwininfo -children -id "$gl" 2>/dev/null | awk '/Parent window id:/ {print $4; exit}'
}
placed() {
  local p
  p="$(display_widget)" && [ -n "$p" ] && [ "$(wgeom "$p")" = "0 0 $GW $GH" ]
}
place() {
  local w p px py pw ph wx wy ww wh
  w="$(top_window)"
  p="$(display_widget)"
  [ -n "$w" ] && [ -n "$p" ] || return 1
  read -r px py pw ph <<<"$(wgeom "$p")"
  read -r wx wy ww wh <<<"$(wgeom "$w")"
  [ -n "${ph:-}" ] && [ -n "${wh:-}" ] || return 1
  if [ "$pw" != "$GW" ] || [ "$ph" != "$GH" ]; then
    xdotool windowsize "$w" $((ww + GW - pw)) $((wh + GH - ph)) 2>/dev/null || return 1
    # Qt re-lays its widgets out asynchronously.
    for _ in $(seq 1 30); do
      read -r px py pw ph <<<"$(wgeom "$p")"
      [ "$pw" = "$GW" ] && [ "$ph" = "$GH" ] && break
      sleep 0.1
    done
    read -r wx wy ww wh <<<"$(wgeom "$w")"
  fi
  if [ "$px" != 0 ] || [ "$py" != 0 ]; then
    xdotool windowmove -- "$w" $((wx - px)) $((wy - py)) 2>/dev/null || return 1
    for _ in $(seq 1 30); do
      read -r px py pw ph <<<"$(wgeom "$p")"
      [ "$px" = 0 ] && [ "$py" = 0 ] && break
      sleep 0.1
    done
  fi
  xdotool windowfocus "$w" 2>/dev/null || true
  [ "$px $py $pw $ph" = "0 0 $GW $GH" ]
}
cap_log() { # truncate a runaway log in place (both writers append)
  local f="$1"
  [ -f "$f" ] && [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt "$LOG_CAP_BYTES" ] &&
    : >"$f" && log "truncated $f at ${LOG_CAP_BYTES} B"
}
keeper() {
  while sleep "${NOKIA_KEEPER_S:-2}"; do
    cap_log /work/emulator.log
    cap_log /work/xdg/EKA2L1/EKA2L1.log
    cap_log /work/eka2l1.log
    [ "$KIOSK" = 1 ] && continue
    [ -e /work/.placing ] && continue
    [ -n "$(top_window)" ] || continue
    placed && continue
    if place; then
      log "keeper: display widget re-placed at 0,0 ${GEOM}"
    else
      log "keeper: WARNING — re-place failed"
    fi
  done
}

# --- the supervised emulator ----------------------------------------------------
fast=0
while :; do
  fresh_data || {
    log "could not copy the golden data dir — retrying in 10 s"
    sleep 10
    continue
  }
  [ -f /work/emulator.log ] && mv -f /work/emulator.log /work/emulator.log.1
  # EKA2L1 truncates its --log-file at start: keep the previous run's (a crash's
  # panic lines are otherwise gone the moment the loop relaunches).
  [ -f /work/eka2l1.log ] && mv -f /work/eka2l1.log /work/eka2l1.log.1
  : >/work/.placing
  t0="$(date +%s)"
  "$BIN" --device "$DEVICE" --run "$APP" "${EXTRA[@]}" >/work/emulator.log 2>&1 &
  EPID=$!
  log "EKA2L1 pid $EPID: --device $DEVICE --run $APP ${EXTRA[*]}"
  ok=0
  # Up to 60 s: the window took 4.4 s to appear at host load 96.
  for _ in $(seq 1 600); do
    kill -0 "$EPID" 2>/dev/null || break
    if [ "$KIOSK" = 1 ]; then
      w="$(kiosk_window)"
      if [ -n "$w" ] && [ "$(wgeom "$w")" = "0 0 $GW $GH" ]; then
        xdotool windowfocus "$w" 2>/dev/null || true
        ok=1
        break
      fi
    elif place; then
      ok=1
      break
    fi
    sleep 0.1
  done
  rm -f /work/.placing
  if [ "$ok" = 1 ]; then
    log "display placed $(($(date +%s) - t0)) s after exec (kiosk=$KIOSK): the ${GEOM} root is the 640x200 screen at 2x"
    : >/work/placed
  else
    log "WARNING — display widget not placed; the captured root shows window chrome"
  fi
  if [ -z "$KPID" ]; then
    keeper &
    KPID=$!
  fi
  wait "$EPID"
  rc=$?
  EPID=""
  up=$(($(date +%s) - t0))
  if [ -e /work/reset-requested ] || [ "$rc" = 0 ]; then
    # A RESET, not a crash: reset-tile.sh (the Restore button, the daemon's
    # auto-reset) touches /work/reset-requested (SH_RESET_CTL_MARK) and sends
    # `ekactl quit`. EKA2L1 acks `OK bye` and then usually segfaults on the way
    # out (rc 139, measured 2026-09-25), so the exit code cannot tell a reset
    # from a crash; the marker does. Relaunch at once and never count it toward
    # the back-off, or three quick Restore presses would earn a visitor 60 s of
    # black.
    rm -f /work/reset-requested
    log "EKA2L1 quit for a reset (rc=$rc after ${up} s) — relaunching from the golden"
    fast=0
    sleep 0.3
    continue
  fi
  log "EKA2L1 exited rc=$rc after ${up} s — relaunching from the golden"
  tail -5 /work/emulator.log 2>/dev/null
  if [ "$up" -lt 20 ]; then fast=$((fast + 1)); else fast=0; fi
  if [ "$fast" -ge 3 ]; then
    log "three exits within 20 s in a row — backing off 60 s"
    sleep 60
    fast=0
  fi
  sleep 2
done
