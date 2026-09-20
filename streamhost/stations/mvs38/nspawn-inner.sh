#!/bin/bash
# =============================================================================
# stations/mvs38/nspawn-inner.sh — PID 2 INSIDE the mvs38 container.
#
# IBM OS/VS2 MVS 3.8j on an emulated IBM System/370 under Hercules (the TK5
# distribution). There is no QEMU, no MAME and no checkpoint here: the exhibit
# is a mainframe emulator plus one 3270 terminal, and reset = relaunch from the
# pristine TK5 DASD volumes.
#
# This script is only the STATION PROLOGUE. The outer launcher already staged
# /work/tk5 (symlinks to the read-only TK5 tree for the inert parts, real
# copies of the DASD volumes and the spool/log directories). This script sets
# the TK5 environment and the x3270 keymap and then execs the lane's shared
# engine, docs/lab/record-wave/shared-terminal-runtime.sh, which owns Xvfb, the
# hidden emulator, the two-condition readiness gate and the visitor client.
#
# TWO TK5 FACTS THE STATION DEPENDS ON (docs/lab/MVS38-WAVE.md):
#
#  * TK5CONS MUST stay `intcons`. conf/tk5.cnf includes conf/${TK5CONS}.cnf,
#    and the `intcons` variant puts the MVS operator console on device
#    0009 3215-C — an INTEGRATED console that writes to the Hercules log. The
#    first 3270 client to reach CNSLPORT therefore lands on 00C0, a VTAM local
#    terminal, and the operator console never competes for it or appears on
#    screen. `extcons` (what TK5's own start_herc sets) would put the operator
#    console on 3270 device 0010 and MUST NOT be used here.
#  * TK5 bundles its OWN SDL Hyperion Hercules under hercules/linux/64. Debian's
#    hercules 3.13 will not run this configuration; the bundled binary needs
#    both PATH and LD_LIBRARY_PATH, or it dies on `libherc.so: cannot open
#    shared object file`.
#
# CNSLPORT (stock 3270) and the Hercules HTTP server (8038) bind the
# CONTAINER's own loopback behind --private-network, so they claim nothing on
# the host and are unreachable from labhost.
# =============================================================================
set -euo pipefail

WORK=/work
TK5="$WORK/tk5"
PORT="${MVS38_PORT:-3270}"
FONT="${MVS38_FONT:-3270-20}"
MODEL="${MVS38_MODEL:-3279-2-E}"
TITLE="${MVS38_WINTITLE:-MVS 3.8j}"

[ -x "$TK5/hercules/linux/64/bin/hercules" ] || {
  echo "mvs38-inner: no executable Hercules under $TK5 (outer launcher did not stage work/)" >&2
  exit 1
}
[ -x "$WORK/x3270-session.sh" ] || {
  echo "mvs38-inner: no $WORK/x3270-session.sh (outer launcher did not stage it)" >&2
  exit 1
}
[ -w "$TK5/dasd" ] || {
  echo "mvs38-inner: $TK5/dasd is not writable — MVS cannot IPL onto a read-only volume" >&2
  exit 1
}

# --- the visitor keyboard.
#
# EVERY 3270 AID KEY A VISITOR NEEDS IS ON THE FACE OF THE SPA'S ON-SCREEN
# KEYBOARD (spa/src/ui/keyboard, family `tn3270`), and the mapping is written
# HERE rather than inherited from x3270's defaults so that the two ends are one
# committed contract. Nothing here is a hidden host shortcut: the station is
# driven over XTEST and there is no host keyboard in front of it.
#
# The keysyms are chosen from what Xvfb's stock pc105 map actually carries —
# F1..F12, Pause, Escape, Home, End, Insert, and Alt+digit — so no exotic
# keycode has to be synthesised. PF13..PF24 ride Shift+F1..F12, which is how a
# real 3279 keyboard did it too.
cat >"$WORK/kh.keymap" <<'KEYMAP'
<Key>F1: PF(1)
<Key>F2: PF(2)
<Key>F3: PF(3)
<Key>F4: PF(4)
<Key>F5: PF(5)
<Key>F6: PF(6)
<Key>F7: PF(7)
<Key>F8: PF(8)
<Key>F9: PF(9)
<Key>F10: PF(10)
<Key>F11: PF(11)
<Key>F12: PF(12)
Shift<Key>F1: PF(13)
Shift<Key>F2: PF(14)
Shift<Key>F3: PF(15)
Shift<Key>F4: PF(16)
Shift<Key>F5: PF(17)
Shift<Key>F6: PF(18)
Shift<Key>F7: PF(19)
Shift<Key>F8: PF(20)
Shift<Key>F9: PF(21)
Shift<Key>F10: PF(22)
Shift<Key>F11: PF(23)
Shift<Key>F12: PF(24)
Alt<Key>1: PA(1)
Alt<Key>2: PA(2)
Alt<Key>3: PA(3)
<Key>Pause: Clear()
<Key>Escape: Reset()
<Key>Home: Home()
<Key>End: EraseEOF()
<Key>Insert: ToggleInsert()
<Key>Return: Enter()
<Key>KP_Enter: Enter()
<Key>Tab: Tab()
Shift<Key>Tab: BackTab()
<Key>BackSpace: Erase()
<Key>Delete: Delete()
Ctrl<Key>a: Attn()
Ctrl<Key>d: Dup()
Ctrl<Key>f: FieldMark()
Ctrl<Key>s: SysReq()
KEYMAP

export KH_TERM_DISPLAY="${SH_X11_DISPLAY:?}"
export KH_TERM_GEOM="${MVS38_GEOM:-1024x768}"
export KH_TERM_WORK="$WORK"
export KH_TERM_EMULATOR_CWD="$TK5"
# Finding 2 of the shared runtime: never a pipe or a FIFO on the hidden
# emulator's stdin. `-d` is Hercules' daemon mode — no curses console, the
# whole operator log on stdout, which is exactly the stream the readiness gate
# below reads.
export KH_TERM_EMULATOR_STDIN=/dev/null
# `env` and not a bare VAR=val prefix: the shared runtime runs this through
# `bash -lc "exec $EMU_CMD"`, and `exec` takes the first word as the program —
# an assignment prefix there is treated as the command name and the launch dies
# with "PATH=...: No such file or directory". MEASURED 2026-09-20.
export KH_TERM_EMULATOR_CMD="env \
PATH=$TK5/hercules/linux/64/bin:/usr/bin:/bin \
LD_LIBRARY_PATH=$TK5/hercules/linux/64/lib:$TK5/hercules/linux/64/lib/hercules \
HERCULES_RC=scripts/ipl.rc TK5CONS=intcons CNSLPORT=$PORT \
hercules -d -f conf/tk5.cnf"
export KH_TERM_READY_PORT="$PORT"
# Finding 1: the port is not the gate. MEASURED 2026-09-20 — CNSLPORT listens
# 8 s after exec, TSO will not accept a logon until 47 s.
export KH_TERM_READY_LOG_RE='IKT005I TCAS IS INITIALIZED'
export KH_TERM_READY_TIMEOUT_S="${MVS38_READY_TIMEOUT_S:-420}"
# The museum surface: one x3270 on the VTAM local terminal 00C0, wrapped by
# x3270-session.sh, which also drives the TSO logon so the exhibit rests on the
# ISPF primary option menu rather than on a static Hercules device logo. No
# window manager runs, so x3270 maps itself at its natural size and the rest of
# the root window stays black; the outer launcher centres it once it is mapped.
#
# THE x3270 OPTIONS LIVE IN x3270-session.sh, and three of them are measured
# facts rather than taste (2026-09-20):
#
#  * The resources use LOOSE binding (`*menuBar`) and the app keeps its default
#    instance name. `-name 'MVS 3.8j'` with `x3270.menuBar: false` was tried
#    first and silently did nothing — `-name` REPLACES the resource instance
#    name, so every `x3270.*` resource stopped matching and the station came up
#    with x3270's File/Options menu bar across the top of the frame. That menu
#    bar is host chrome a visitor cannot click (this station publishes no
#    pointer) and it crops the 24x80 screen.
#  * The font is bounded by the root window, not chosen for looks: a 3270 is a
#    fixed 80 columns, so the emulator font's cell width must be at most
#    1024/80 = 12.8 px or x3270 maps itself wider than the framebuffer and the
#    right-hand columns are simply not in the stream. MEASURED in a scratch
#    container, 3279-2-E with the menu bar off:
#      3270gt32 1461x816 · 3270gt24 1141x614 · 3270-20 821x513
#      3270gt16  741x412 · 3270gt12  581x311 · 3270    741x361
#    3270-20 is the largest that fits 1024x768, and the first two do not.
#  * x3270 finds a keymap ONLY as a resource. `-keymap /work/kh.keymap` and
#    `-keymap kh` with the file at $HOME/.x3270/kh both answer
#    `Cannot find keymap`; `-keymap kh` plus a `*keymap.kh:` resource whose
#    value is the table above with literal \n separators is accepted.
export KH_TERM_CLIENT_CMD="exec $WORK/x3270-session.sh"

exec "$WORK/shared-terminal-runtime.sh"
