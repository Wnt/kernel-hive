#!/bin/bash
# =============================================================================
# stations/indyr4400/nspawn-inner.sh — PID 2 INSIDE the indyr4400 container.
#
# Started by x11-runtime.sh as the command of `systemd-nspawn --as-pid2`, so
# this script IS the container's payload. Everything it can see is what the
# launcher bound in: the host's /usr read-only, the Iris binary and the IRIX
# disk read-only at their host paths, /work read-write, /run's two socket paths,
# and — in shm mode — the fb.shm mapping. It runs as the container's root, which
# is an unprivileged uid on the host (--private-users), with CAP_SYS_ADMIN
# dropped, the mount syscalls filtered and no route off `lo`.
#
# It execs Iris in its own place, so Iris is PID 2 and its exit ends the
# container — which is what makes "reset = relaunch" one kill from outside.
#
# TWO MODES, the same as the launcher's:
#
#   shm  no X server, no DISPLAY, no window. `--ci` WITHOUT `--ci-display` is
#        Iris's own no-window branch and — unlike `--headless`, which omits
#        REX3 entirely and has no framebuffer at all (src/machine.rs:516) —
#        it keeps REX3 alive, which is the whole point. The fork's frame and
#        input planes gate on IRIS_SHM_PATH / IRIS_CTL_SOCK, not on --ci, so
#        those knobs are what actually arm them; --ci-socket additionally gives
#        stream D its restore verbs and replaces the bridge era's two-hop
#        ssh-into-kiosk-then-telnet exec channel with serial-send/wait-serial.
#
#   x11  a pinned Xvfb and Iris as an ordinary winit window on it. THE WINIT
#        FOCUS TRAP travels with this mode: there is no window manager, so
#        nothing calls XSetInputFocus, the X focus stays PointerRoot, and winit
#        (unlike SDL) DROPS key events for a window it does not consider
#        focused. The pointer keeps working — winit takes it from XI2 raw
#        device events, which ignore focus — so the exhibit looks alive with a
#        silently dead keyboard. Focus the window explicitly, exactly as the
#        bridge's launch.sh had to.
#        `xset r off`: every key here is an injected press/release pair and a
#        late release makes X's typematic repeat hammer the held key (the Oric
#        Atmos failure).
# =============================================================================
set -euo pipefail

CAPTURE="${SH_CAPTURE:-shm}"
BIN="${IRIS_BIN:?}"
WORK="${IRIS_WORK:-/work}"
GEOM="${IRIS_GEOM:-1280x1024}"
CFG="$WORK/iris.toml"

cd "$WORK"
[ -f "$CFG" ] || {
  echo "iris-inner: no $CFG" >&2
  exit 1
}

if [ "$CAPTURE" = shm ]; then
  # Belt and braces: a stray DISPLAY would let winit open a window on someone
  # else's server and the daemon would map an empty file forever.
  unset DISPLAY
  exec "$BIN" --config "$CFG" --noaudio --ci --ci-socket "${IRIS_CI_SOCK:?}"
fi

DISP="${SH_X11_DISPLAY:?}"
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X${DISP#:}"
# The X root is sized to the emulated XL framebuffer exactly, so the capture is
# 1:1 with no window-manager resampling — the bridge's rule, and the reject
# criteria in docs/lab/MIGRATION-WAVE-BRIEF.md still apply to the result.
Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac \
  >"$WORK/xvfb.log" 2>&1 &
XPID=$!
for _ in $(seq 1 120); do
  [ -S "/tmp/.X11-unix/X${DISP#:}" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    echo "iris-inner: Xvfb died:" >&2
    cat "$WORK/xvfb.log" >&2
    exit 1
  }
  sleep 0.25
done
[ -S "/tmp/.X11-unix/X${DISP#:}" ] || {
  echo "iris-inner: no X socket after 30 s" >&2
  exit 1
}

export DISPLAY="$DISP"
xset s off -dpms s noblank 2>/dev/null || true
xset r off 2>/dev/null || true
xsetroot -solid black 2>/dev/null || true
(
  for _ in $(seq 1 180); do
    W="$(xdotool search --class iris 2>/dev/null | head -1)"
    if [ -n "$W" ]; then
      xdotool windowfocus "$W" 2>/dev/null && break
    fi
    sleep 1
  done
) &

exec "$BIN" --config "$CFG" --noaudio
