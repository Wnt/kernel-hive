#!/bin/bash
# =============================================================================
# stations/its/nspawn-inner.sh — PID 2 INSIDE the its container.
#
# MIT ITS (the Incompatible Timesharing System, MIT AI Lab, 1967) on an
# emulated DEC PDP-10 (KS10) under SIMH, built from source by the maintained
# github.com/PDP-10/its tree. No QEMU, no MAME and no checkpoint: the exhibit
# is a simulator process plus one terminal, and reset = relaunch from the
# pristine built disk.
#
# This script is only the STATION PROLOGUE. It checks the writable disk the
# outer launcher staged, writes the simulator's ini file and then execs the
# lane's shared engine, shared-terminal-runtime.sh (proven end to end by
# vax43bsd), which owns Xvfb, the hidden emulator, the two-condition readiness
# gate and the visitor client.
#
# Writable state is /work only. The outer launcher copied the pristine rp0.dsk
# there before this script ran, and the ini below attaches THAT copy — the
# built tree is bound read-only, so a visitor who reaches DDT (ITS has no
# protection between users; that is the exhibit) can never touch the seed.
#
# The DZ11 line 0 telnet listener is the visitor line. It lives on the
# container's own loopback behind --private-network, so it needs no host port
# claim and is unreachable from labhost.
# =============================================================================
set -euo pipefail

WORK=/work
TREE="${ITS_TREE:?ITS_TREE required}"
PORT="${ITS_PORT:-10004}"
COLS="${ITS_COLS:-80}"
ROWS="${ITS_ROWS:-31}"
FONTSIZE="${ITS_FONTSIZE:-14}"
XOFF="${ITS_XOFF:-+30+10}"

[ -f "$WORK/rp0.dsk" ] || {
  echo "its-inner: no writable disk at $WORK/rp0.dsk (outer launcher did not seed work/)" >&2
  exit 1
}

# --- the simulator config. Written here, not taken from the read-only tree,
# because the tree's own out/simh/boot attaches the SEED disk by a relative
# path; this one attaches the WORK copy and the per-launch DZ port.
#
# Device set, frozen for the first release (docs/lab/ITS-WAVE.md):
#   rp0  RP06, the work copy of the built ITS disk — the whole system
#   ch   the Chaosnet interface. NOT OPTIONAL, and this cost a boot to learn:
#        with `ch` absent ITS gets as far as the Salvager and then prints
#        "CHAOSNET INTERFACE NOT RESPONDING (CHECK THE BREAKER ON THE UNIBUS)",
#        BUGHALTs and drops into DDT. The 1967 kernel expects the hardware to
#        be there. It does not need a PEER to talk to — the peer below is never
#        reachable and ITS boots anyway, printing only "No host responded" when
#        it fails to set the clock from the network — it needs the INTERFACE to
#        answer. Both ports live on the container's own loopback behind
#        --private-network, so they claim nothing on the host.
#   dz   DZ11, 8 lines, 8-bit; line 0 is the visitor terminal
#   The upstream config's extra `at -u dz0 line=7` (VT52) and `line=6` (GT40)
#   listeners ARE dropped — this station publishes exactly ONE terminal.
#
# THE DSKDMP DANCE DOES APPLY. The generated out/simh/boot ends in `b rp0`, so
# it is tempting to conclude ITS boots unattended under EMULATOR=simh and that
# the upstream README's DSKDMP / ESC-G dialogue is a KLH10-only concern. It is
# not: `b rp0` loads DSKDMP, which prints " DSKDMP" and waits for a system name
# and then an ESC-G to start it. MEASURED 2026-09-20 — three variants:
#   `send "its\r"` alone            -> DSKDMP sits forever, no further output
#   two rules, ESC-G on a timer      -> the ESC raced the filename; DSKDMP read
#                                       "$", then "Gits", and answered FNF twice
#   `send delay=200000 "its\r\033G"` -> Salvager 261, then ITS in operation
# The last is what is used. Finding 3 of the shared runtime still holds and is
# the point: SIMH answers this dialogue ITSELF from the ini file, so there is
# still no pty/expect supervisor in the container and the simulator remains the
# single supervised process.
#
# READINESS (finding 1: a TCP port probe is not readiness — `at -u dz0` binds
# while this file is still being read, minutes before ITS exists). When the
# system is up it prints, on the PDP-10's OWN console:
#
#     DB ITS 1652 SYSTEM JOB USING THIS CONSOLE.
#
# That console is the simulator's stdout, which the shared runtime captures to
# work/emulator.log, so ITS_READY_LOG_RE matches it directly. The neighbouring
# "DB ITS 1652 IN OPERATION" line is NOT used even though it comes first and
# reads better: ITS prints a BEL inside it ("DB ITS 1652\a IN OPERATION\a"),
# so the obvious regex does not match it. The version number is skipped for the
# same reason it would be wrong to pin — it increments with each self-build.
cat >"$WORK/boot" <<CONF
set console wru=034
set cpu its
set cpu idle
set tim y2k
set ch enabled
set ch node=${ITS_CHAOS_NODE:-177002}
set ch peer=localhost:${ITS_CHAOS_PEER_PORT:-44041}
att ch ${ITS_CHAOS_PORT:-44042}
set dz 8b lines=8
at -u dz0 $PORT
set rp0 rp06
at rp0 $WORK/rp0.dsk
expect "DSKDMP" send delay=200000 "its\r\033G"; go
b rp0
CONF

# The museum surface: one xterm on the DZ line. `telnet -E` is deliberate —
# it drops a line of chrome AND removes the `^]` escape, so a visitor cannot
# fall out of the exhibit into a telnet command prompt. `^\` is likewise not
# offered on the on-screen keyboard: it would reach the SIMH `sim>` prompt.
export KH_TERM_DISPLAY="${SH_X11_DISPLAY:?}"
export KH_TERM_GEOM="${ITS_GEOM:-1024x768}"
export KH_TERM_WORK="$WORK"
export KH_TERM_EMULATOR_CWD="$WORK"
export KH_TERM_EMULATOR_STDIN=/dev/null
export KH_TERM_EMULATOR_CMD="$TREE/tools/simh/BIN/pdp10 $WORK/boot"
export KH_TERM_READY_PORT="$PORT"
export KH_TERM_READY_LOG_RE="${ITS_READY_LOG_RE:-SYSTEM JOB USING THIS CONSOLE}"
export KH_TERM_READY_TIMEOUT_S="${ITS_READY_TIMEOUT_S:-300}"
export KH_TERM_CLIENT_CMD="exec xterm -display '${SH_X11_DISPLAY}' \
-geometry '${COLS}x${ROWS}${XOFF}' \
-fa 'DejaVu Sans Mono' -fs '${FONTSIZE}' \
-bg black -fg white -cr white -b 0 -bw 0 +sb \
-title 'MIT ITS' -xrm 'xterm*backarrowKey: false' \
-xrm 'xterm*metaSendsEscape: true' \
-e telnet -E 127.0.0.1 ${PORT}"

exec "$WORK/shared-terminal-runtime.sh"
