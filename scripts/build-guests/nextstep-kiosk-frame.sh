#!/bin/bash
# nextstep-kiosk-frame.sh — runs beside Previous in the bridge kiosk.
#
# Two jobs, both forced on us by there being NO WINDOW MANAGER here:
#
#  1. INPUT. Nobody ever calls XSetInputFocus, so the X input focus stays None
#     and SDL3 hands Previous no key events at all; and because the pointer is
#     already inside the window when it is mapped, no EnterNotify is generated
#     either, so SDL never acquires a mouse focus. Focus the window by hand,
#     then walk the pointer out of it and back in to force the Enter.
#
#  2. GEOMETRY. SDL3 centres the window against the display's usable bounds and
#     lands the 1120x832 NeXT screen at +16+12 on a 1120x832 root, clipping
#     16 px off the right edge and 12 px off the bottom — which cuts the Dock
#     and breaks the 1:1 host-pixel/guest-pixel mapping. Nothing honours the
#     requested position, so move it from outside. Previous DESTROYS AND
#     RE-CREATES its window on a mode change, with a NEW window id, so the id
#     has to be re-resolved on every pass — an earlier version cached it once
#     and silently kept re-anchoring a window that no longer existed.
export DISPLAY=${DISPLAY:-:0}
# startx leaves one cookie per session in ~/.Xauthority and the client picks
# the wrong one after a few kiosk restarts, so this watcher silently could not
# open the display and never anchored anything. Use the running server's own
# auth file instead.
# shellcheck disable=SC2012 # xinit's own fixed-format name, newest wins
SRVAUTH=$(ls -t /tmp/serverauth.* 2>/dev/null | head -1)
[ -n "$SRVAUTH" ] && export XAUTHORITY="$SRVAUTH"
LOG=/tmp/nextstep-frame.log
exec >>"$LOG" 2>&1
echo "=== frame watcher $(date -Is) DISPLAY=$DISPLAY"
seen=""
while :; do
  W=$(xdotool search --class previous 2>/dev/null | tail -1)
  if [ -n "$W" ]; then
    if [ "$W" != "$seen" ]; then
      echo "$(date -Is) window=$W (new)"
      xdotool windowfocus "$W" || true
      xdotool mousemove 1119 831
      sleep 0.4
      xdotool mousemove 560 416
      seen=$W
    fi
    eval "$(xwininfo -id "$W" 2>/dev/null |
      awk '/Absolute upper-left X/{print "AX="$4} /Absolute upper-left Y/{print "AY="$4}')"
    if [ "${AX:-0}" != 0 ] || [ "${AY:-0}" != 0 ]; then
      echo "$(date -Is) re-anchoring $W from +$AX+$AY"
      xdotool windowmove "$W" 0 0 || true
    fi
  fi
  sleep 2
done
