#!/bin/bash
# =============================================================================
# stations/lisa/lisa-inner.sh — what runs INSIDE the lisa station's sandbox.
#
# x11-runtime.sh starts this as PID 2 of a systemd-nspawn container with a
# private PID, mount, network and USER namespace (the container's root is the
# unprivileged host uid range 200000+; see the launcher for the exact shape).
# In here: start the pinned Xvfb whose socket directory is bound out to the
# host for the daemon, start LisaEm on it, place the window so the root IS the
# Lisa video, click the ROM's ProFile icon, then wait on LisaEm.
#
# Paths are the container's:
#   $LISA_ASSETS  the station assets (read-only, bound at its host path so the
#             host sees LisaEm's exe under assets/lisa/): lisaem/, lib/, rom/
#   /work     this launch's writable dir: profile.dc42, home/, logs
#   /tmp/.X11-unix  bound to $BASE/x11 on the host (the daemon's door)
# Env from the launcher: LISA_DISPLAY (:93), LISA_GEOM (720x498),
#   LISA_BOOT_CLICK (1), LISA_ASSETS, LISA_ROM ($LISA_ASSETS/rom/lisaboot-revH.rom)
# =============================================================================
set -euo pipefail
DISP="${LISA_DISPLAY:?}"
GEOM="${LISA_GEOM:-720x498}"
ASSETS="${LISA_ASSETS:?}"
ROM="${LISA_ROM:-$ASSETS/rom/lisaboot-revH.rom}"
BIN="$ASSETS/lisaem/usr/local/bin/lisaem"
HOMEDIR=/work/home
log() { echo "$(date -u +%FT%TZ) lisa-inner: $*"; }

# Xvfb: -nolisten tcp; the abstract socket stays inside this netns, the
# filesystem socket lands in the bound-out directory.
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -nolisten local >/work/xvfb.log 2>&1 &
XPID=$!
for _ in $(seq 1 60); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    log "Xvfb died:"
    cat /work/xvfb.log
    exit 1
  }
  sleep 0.25
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  log "no X socket after 15 s"
  exit 1
}
chmod 777 /tmp/.X11-unix 2>/dev/null || true

mkdir -p "$HOMEDIR/.config/gtk-3.0"
cat >"$HOMEDIR/.config/gtk-3.0/gtk.css" <<'CSS'
/* lisa station: collapse the wx menubar so the Lisa video sits at the top of
   the captured root (docs/lab/LISA-WAVE.md). */
menubar, menubar > menuitem, menubar > menuitem > label { min-height: 0px; min-width: 0px; padding: 0px; margin: 0px; border: 0px; font-size: 1px; }
menubar { opacity: 0; }
CSS
sed -e "s|^ROMFILE=.*|ROMFILE=$ROM|" \
  -e "s|^path=.*|path=/work/profile.dc42|" \
  -e "s|^dirpath=.*|dirpath=$HOMEDIR|" \
  "$ASSETS/lisaem.conf.template" >"$HOMEDIR/lisaem.conf"

export DISPLAY="$DISP" HOME="$HOMEDIR" XDG_CONFIG_HOME="$HOMEDIR/.config"
export LD_LIBRARY_PATH="$ASSETS/lib" GCONV_PATH="$ASSETS/lib/gconv:/usr/lib/x86_64-linux-gnu/gconv"
export NO_AT_BRIDGE=1 GTK_A11Y=none
"$BIN" -s- -z 1.0 -o- -p -c "$HOMEDIR/lisaem.conf" >/work/lisaem.log 2>&1 &
LPID=$!

main_window() {
  local w wd
  for w in $(xdotool search --name . 2>/dev/null); do
    wd="$(xwininfo -id "$w" 2>/dev/null | awk '/Width:/{print $2}')"
    [ "${wd:-0}" -gt 500 ] && {
      echo "$w"
      return 0
    }
  done
  return 1
}
W=""
for _ in $(seq 1 60); do
  kill -0 "$LPID" 2>/dev/null || {
    log "LisaEm died at launch:"
    tail -20 /work/lisaem.log
    exit 1
  }
  W="$(main_window || true)"
  [ -n "$W" ] && break
  sleep 0.5
done
[ -n "$W" ] || {
  log "no LisaEm window after 30 s"
  exit 1
}
# 720 wide puts the video at x=0; y=-42 hides the 2 px collapsed menubar and the
# 40 px band under it. NEVER a negative X: GDK then drops every button event.
xdotool windowsize "$W" "${GEOM%x*}" 800
xdotool windowmove -- "$W" 0 -42
log "LisaEm pid $LPID window $W placed; root $GEOM on $DISP"

if [ "${LISA_BOOT_CLICK:-1}" = 1 ]; then
  sleep 4
  xdotool mousemove 55 93 mousedown 1 sleep 0.15 mouseup 1
  log "ProFile boot click sent"
fi

trap 'kill -TERM "$LPID" "$XPID" 2>/dev/null; exit 0' TERM INT
wait "$LPID" || true
log "LisaEm exited"
kill -TERM "$XPID" 2>/dev/null || true
