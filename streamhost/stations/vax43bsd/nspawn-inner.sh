#!/bin/bash
# =============================================================================
# stations/vax43bsd/nspawn-inner.sh — PID 2 INSIDE the vax43bsd container.
#
# 4.3BSD (Berkeley, June 1986) on an emulated DEC VAX-11/780 under Open SIMH.
# There is no QEMU, no MAME and no checkpoint here: the exhibit is a simulator
# process plus one terminal, and reset = relaunch from the pristine seed disk.
#
# This script is only the STATION PROLOGUE. It stages the writable disk, writes
# the simulator's ini file and then execs the lane's shared engine,
# docs/lab/record-wave/shared-terminal-runtime.sh, which owns Xvfb, the hidden
# emulator, the two-condition readiness gate and the visitor client.
#
# Writable state is /work only. The outer launcher copied the pristine RA81
# there before this script ran, and the ini below attaches THAT copy — the seed
# in assets/media is bound read-only, so nothing a visitor types can reach it.
#
# The DZ11 telnet listener is the visitor line. It lives on the container's own
# loopback behind --private-network, so it needs no host port claim and is
# unreachable from labhost.
# =============================================================================
set -euo pipefail

WORK=/work
ASSETS="${VAX43BSD_ASSETS:?VAX43BSD_ASSETS required}"
PORT="${VAX43BSD_PORT:-10023}"
COLS="${VAX43BSD_COLS:-80}"
ROWS="${VAX43BSD_ROWS:-24}"
FONTSIZE="${VAX43BSD_FONTSIZE:-14}"
XOFF="${VAX43BSD_XOFF:-+32+96}"

[ -f "$WORK/ra81.dsk" ] || {
  echo "vax43bsd-inner: no writable disk at $WORK/ra81.dsk (outer launcher did not seed work/)" >&2
  exit 1
}

# --- the simulator config. Written here, not taken from the read-only assets,
# because it attaches the WORK copy of the disk and the per-launch DZ port.
#
# Device set, frozen for the first release (docs/lab/VAX43BSD-WAVE.md):
#   rq0  RA81, the work copy   (root ra0a, /usr ra0h, /home ra0g)
#   ts   TS11, 43.tap read-only (kernel probes ts0; mt/tar work in the guest)
#   dz   DZ11, 8 lines, 7-bit, telnet listener — tty00..tty07, the visitor line
#   everything else disabled; no Ethernet — this station is an island on purpose
#
# The `expect` pair is finding 3 of the shared runtime: SIMH answers the 4.2BSD
# standalone boot prompt itself, so no pty/expect supervisor sits between the
# container's init and the simulator, and `KHBOOTREADY` is the readiness token
# finding 1 demands.
cat >"$WORK/boot.ini" <<CONF
set quiet
set rq0 ra81
att rq0 $WORK/ra81.dsk
set rq1 disable
set rq2 disable
set rq3 disable
set rp disable
set rl disable
set tq disable
set tu disable
set lpt disable
att -r ts $ASSETS/media/43.tap
set tti 7b
set tto 7b
set dz lines=8
set dz 7b
att dz $PORT
set cpu idle=32v
load -o $ASSETS/media/boot42 0
d r10 9
d r11 0
expect "Boot\r\n: " send "ra(0,0)vmunix\r"; go
expect "login: " echo KHBOOTREADY; go
run 2
CONF

# The museum surface: one xterm on the DZ line. `telnet -E` is deliberate: it
# drops one line of chrome AND removes the `^]` escape, so a visitor cannot
# fall out of the exhibit into a telnet command prompt.
# The museum surface: one xterm on the DZ line. No window manager runs, so
# xterm maps itself at exactly this size and offset and the rest of the root
# window stays black. 80x24 is not a taste call — 4.3BSD's termcap `vt100` is
# a fixed 24x80 and telnet to a DZ line carries no window-size negotiation, so
# any other row count makes full-screen programs (vi, more) draw wrong.
export KH_TERM_DISPLAY="${SH_X11_DISPLAY:?}"
export KH_TERM_GEOM="${VAX43BSD_GEOM:-1024x768}"
export KH_TERM_WORK="$WORK"
export KH_TERM_EMULATOR_CWD="$WORK"
export KH_TERM_EMULATOR_STDIN=/dev/null
export KH_TERM_EMULATOR_CMD="$ASSETS/bin/vax780 $WORK/boot.ini"
export KH_TERM_READY_PORT="$PORT"
export KH_TERM_READY_LOG_RE='KHBOOTREADY'
export KH_TERM_READY_TIMEOUT_S="${VAX43BSD_READY_TIMEOUT_S:-300}"
export KH_TERM_CLIENT_CMD="exec xterm -display '${SH_X11_DISPLAY}' \
-geometry '${COLS}x${ROWS}${XOFF}' \
-fa 'DejaVu Sans Mono' -fs '${FONTSIZE}' \
-bg black -fg '#33ff66' -cr '#33ff66' -b 0 -bw 0 +sb \
-title '4.3BSD console' -xrm 'xterm*backarrowKey: false' \
-xrm 'xterm*metaSendsEscape: true' \
-e telnet -E 127.0.0.1 ${PORT}"

exec "$WORK/shared-terminal-runtime.sh"
