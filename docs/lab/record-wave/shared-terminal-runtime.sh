#!/bin/bash
# =============================================================================
# Shared inner runtime for terminal-fronted host emulators.
#
# Users: vax43bsd (SIMH VAX-11/780), mvs38 (Hercules), multics (DPS8M),
# its (SIMH KS10). Runs as the command of `systemd-nspawn --as-pid2` inside
# the station's container; the station's own nspawn-inner.sh is a short
# prologue that stages writable media, writes the emulator's config and then
# `exec`s THIS file with the KH_TERM_* contract set.
#
# STATUS 2026-09-20: PROVEN END TO END BY vax43bsd (docs/lab/VAX43BSD-WAVE.md).
# This file is no longer a draft. Claims are tagged:
#   [PROVEN]  measured on labhost, with the measurement quoted
#   [INHERIT] proven earlier by medley/vision/perq/lisa and re-checked
#   [ASSUMED] still a design guess — DO NOT relay as fact
#
# -----------------------------------------------------------------------------
# FINDING 1 — A TCP PORT PROBE IS NOT A READINESS GATE. [PROVEN, three stations]
# -----------------------------------------------------------------------------
# The telnet/3270 listener belongs to the SIMULATOR, not to the guest OS. It
# binds seconds after exec and then lies for the whole of the guest's boot.
# Measured independently on three emulator families:
#
#   mvs38   (Hercules/TK5)  CNSLPORT listening  +8 s · TCAS initialised  +47 s
#   multics (DPS8M)         TCP/6180 open       +4 s · answering service +52 s
#   vax43bsd (SIMH VAX780)  DZ11 listener       +0 s · login: on tty00   +53 s
#
# SIMH is the extreme case: `att dz <port>` binds while the ini file is still
# being read, i.e. 53 seconds before there is a getty behind it. A visitor
# client started on the port alone attaches to a dead line and the exhibit
# opens on a blank terminal that never answers.
#
# So the gate is TWO conditions: the port answers AND the emulator's own
# console stream has printed the station's KH_TERM_READY_LOG_RE. Known-good:
#   vax43bsd (SIMH)        'KHBOOTREADY'   (SIMH `expect "login: " echo ...`)
#   mvs38    (Hercules)    'IKT005I TCAS IS INITIALIZED'
#   multics  (DPS8M)       'as_init_: Multics MR12.8; Answering Service'
#   its      (SIMH KS10)   TBD by that worker
#
# -----------------------------------------------------------------------------
# FINDING 2 — NEVER GIVE THE HIDDEN EMULATOR A PIPE OR A FIFO ON STDIN. [PROVEN]
# -----------------------------------------------------------------------------
# `dps8 MR12.8_boot.ini < fifo` prints as far as the FNP listen line and then
# sleeps forever: no CPU thread, no boot. /dev/null boots; a pty boots. The
# simulator console is the simulator's own input path — the same family as the
# PERQ needing a TTY as its clock (docs/lab/perq-station.md). Stdin is pinned
# explicitly below because a backgrounded `bash -lc` otherwise inherits
# whatever the OUTER launcher happened to have.
#
# -----------------------------------------------------------------------------
# FINDING 3 — A SIMH STATION NEEDS NO pty/expect SUPERVISOR. [PROVEN, vax43bsd]
# -----------------------------------------------------------------------------
# SIMH answers its own standalone-boot prompt from the ini file:
#
#     load -o boot42 0
#     d r10 9
#     d r11 0
#     expect "Boot\r\n: " send "ra(0,0)vmunix\r"; go
#     expect "login: " echo KHBOOTREADY; go
#     run 2
#
# Each rule halts the simulation, runs its action list and `go` resumes. That
# removes the Python/expect supervisor from the container entirely and leaves
# the simulator as the SINGLE supervised process, so the medley pidfile +
# `/proc/<pid>/exe` contract works unchanged — and it hands finding 1 its
# readiness token for free.
#
# -----------------------------------------------------------------------------
# FINDING 4 — IF YOU DRIVE AN OPERATOR CONSOLE, HANDSHAKE ON ITS PROMPT.
# -----------------------------------------------------------------------------
# [PROVEN, multics] system_control drops request text that arrives in the same
# write as the attention ESC. ESC -> wait for a NEW prompt in the console
# stream -> settle -> send. A single `printf '\033shut\r'` is silently lost.
# vax43bsd needs none of this: nothing drives its console (finding 3), so the
# simulator console goes straight to a logfile and is never on screen. Hiding
# the operator console then costs no cropping, no second X window and no
# window-manager trick.
#
# -----------------------------------------------------------------------------
# FINDING 5 — NO WINDOW MANAGER MEANS NO KEYBOARD. [PROVEN, vax43bsd]
# -----------------------------------------------------------------------------
# Nothing in these containers runs a window manager, so X input focus stays
# PointerRoot and the visitor client only receives keys while the pointer
# happens to be over it. A terminal station has no pointer to move, and the
# daemon types with XTEST, so without an explicit XSetInputFocus every visitor
# keystroke lands on the root window and vanishes with nothing in any log. The
# OUTER launcher must pin focus once, after the client window maps:
#
#     DISPLAY=$DISP xdotool windowfocus "$(xdotool search --name '<title>'|head -1)"
#
# (`xdotool key --window <id>` is NOT a substitute: it sends XSendEvent, which
# xterm ignores by default. It looked like it worked here because unrelated
# output arrived in the same second.)
#
# -----------------------------------------------------------------------------
# FINDING 6 — A GETTY BANNER IS A ONE-SHOT AT BOOT. [PROVEN, vax43bsd]
# -----------------------------------------------------------------------------
# 4.3BSD's getty prints `login:` when it OPENS the line, which on a SIMH DZ11
# is at boot, with nobody attached — into the void. A telnet connection does
# NOT re-trigger it: measured, a passive connect sat silent for 25 s on a line
# whose getty was alive and well. So readiness (findings 1 and 3) can be fully
# satisfied and the exhibit still opens on a BLACK SCREEN.
#
# Bring-up therefore sends one CR and then waits for the banner ITSELF, on the
# framebuffer — never for a fixed sleep, and never merely for "the screen
# changed", because the client's own connection chrome arrives asynchronously
# in the same window and will satisfy a change test on its own. The cheap exact
# gate is a lit-pixel count with a settled baseline:
#
#     nlit() { xwd -display "$DISP" -root -silent |
#       convert xwd:- -colorspace Gray -threshold 25% \
#         -format '%[fx:int(mean*w*h)]' info:; }
#
# MEASURED on vax43bsd's own root: client chrome alone 2958, chrome + the
# simulator's connect greeting + two banners 9148 — one banner is worth about
# 2000 and a blinking cursor about 90, so +1200 separates them with room to
# spare. Any sibling whose guest prints its prompt on line-open (that is most
# of them) needs this; one whose guest prompts on carrier does not.
#
# -----------------------------------------------------------------------------
# Required environment:
#   KH_TERM_DISPLAY=:N
#   KH_TERM_EMULATOR_CMD='command ...'   # starts the hidden emulator
#   KH_TERM_READY_PORT=N                 # loopback TCP port of the visitor line
#   KH_TERM_CLIENT_CMD='command ...'     # xterm/x3270; exec'd as the surface
# Optional:
#   KH_TERM_READY_LOG_RE='regex'         # finding 1 — effectively mandatory
#   KH_TERM_EMULATOR_STDIN=/dev/null     # finding 2 — never a pipe/FIFO
#   KH_TERM_GEOM=1024x768
#   KH_TERM_READY_TIMEOUT_S=300
#   KH_TERM_WORK=/work
#   KH_TERM_EMULATOR_CWD=/work
#
# Contract:
#   * Xvfb inside the container is the only published graphics surface.
#   * The emulator/operator console goes to a logfile and is never shown.
#   * The visitor client starts only after BOTH real probes succeed.
#   * If the hidden emulator exits, launch fails loudly with its log.
#   * Station-specific reset copies pristine mutable media into $KH_TERM_WORK
#     BEFORE invoking this file. [PROVEN, vax43bsd] snapshot that pristine
#     medium only from a guest that shut down cleanly (`sync; sync; /etc/halt`)
#     — a simulator killed at the console leaves the filesystem dirty, the
#     guest salvages it at the next boot AND REBOOTS ITSELF, and from outside
#     that is indistinguishable from a station in a boot loop.
# =============================================================================
set -euo pipefail

DISP="${KH_TERM_DISPLAY:?KH_TERM_DISPLAY required}"
GEOM="${KH_TERM_GEOM:-1024x768}"
EMU_CMD="${KH_TERM_EMULATOR_CMD:?KH_TERM_EMULATOR_CMD required}"
READY_PORT="${KH_TERM_READY_PORT:?KH_TERM_READY_PORT required}"
CLIENT_CMD="${KH_TERM_CLIENT_CMD:?KH_TERM_CLIENT_CMD required}"
READY_RE="${KH_TERM_READY_LOG_RE:-}"
EMU_STDIN="${KH_TERM_EMULATOR_STDIN:-/dev/null}"
TIMEOUT="${KH_TERM_READY_TIMEOUT_S:-300}"
WORK="${KH_TERM_WORK:-/work}"
EMU_CWD="${KH_TERM_EMULATOR_CWD:-$WORK}"
N="${DISP#:}"

mkdir -p "$WORK"
# [INHERIT] medley/perq/vision: the socket dir is a HOST directory bind-mounted
# over the container's /tmp/.X11-unix; it arrives owned by the host and X
# refuses to use it unless it is 1777.
chmod 1777 /tmp/.X11-unix 2>/dev/null || true
rm -f "/tmp/.X11-unix/X$N"

Xvfb "$DISP" -screen 0 "${GEOM}x24" -nolisten tcp -noreset -ac >"$WORK/xvfb.log" 2>&1 &
XPID=$!
EPID=""
# EPID is pre-initialised: the draft's trap referenced it before assignment,
# which under `set -u` turned an early Xvfb failure into an unbound-variable
# abort instead of the intended message.
trap 'kill -TERM ${EPID:-} "$XPID" 2>/dev/null || true' EXIT TERM INT

for _ in $(seq 1 240); do
  [ -S "/tmp/.X11-unix/X$N" ] && break
  kill -0 "$XPID" 2>/dev/null || {
    echo "kh-term: Xvfb died before its socket appeared" >&2
    cat "$WORK/xvfb.log" >&2
    exit 1
  }
  sleep .25
done
[ -S "/tmp/.X11-unix/X$N" ] || {
  echo "kh-term: no X socket for $DISP after 60 s" >&2
  exit 1
}
export DISPLAY="$DISP"

# Operator-controlled command from a committed station fixture; shell form is
# deliberate because Hercules/DPS8M/SIMH startup needs cd/env/redirection.
# Finding 2: stdin is pinned, never inherited.
(cd "$EMU_CWD" && exec bash -lc "exec $EMU_CMD") >"$WORK/emulator.log" 2>&1 <"$EMU_STDIN" &
EPID=$!

fail() {
  echo "kh-term: $1" >&2
  tail -120 "$WORK/emulator.log" >&2 || true
  exit 1
}

[ -n "$READY_RE" ] ||
  echo "kh-term: WARNING — no KH_TERM_READY_LOG_RE; a port probe alone is not readiness (finding 1)" >&2

deadline=$(($(date +%s) + TIMEOUT))
while :; do
  kill -0 "$EPID" 2>/dev/null || fail "hidden emulator exited before the terminal became ready"
  [ "$(date +%s)" -lt "$deadline" ] ||
    fail "terminal not ready after ${TIMEOUT}s (port $READY_PORT${READY_RE:+, log /$READY_RE/})"
  if nc -z 127.0.0.1 "$READY_PORT" 2>/dev/null; then
    # Finding 1: the port alone lies. Only the emulator's own log ends the wait.
    if [ -z "$READY_RE" ] || grep -qE "$READY_RE" "$WORK/emulator.log" 2>/dev/null; then
      break
    fi
  fi
  sleep .5
done

# The client is the museum surface, exec'd in this script's place so that its
# exit ends the container. No host or operator console is ever mapped into the
# capture.
exec bash -lc "$CLIENT_CMD"
