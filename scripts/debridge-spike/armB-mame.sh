#!/bin/bash
# De-bridging spike ARM B (tier 3): the SAME MAME Atari ST binary arm A runs
# inside the kiosk, running HOST-NATIVE with no QEMU, no X server and no window.
# Frames go straight into a shared-memory mapping (`-video shm`, the drawshm OSD
# render module) that streamhost reads with SH_CAPTURE=shm; input comes back in
# over the ctlsock control socket (SH_INPUT_BACKEND=mamesock). This is the irix
# station's shape, minus the parts that are IRIX's own.
#
# NOT A TILE. Namespaced under /data/vms/soltest/. Kill ONLY by pidfile, via
# `clone-guard kill-pidfile`.
#
# The env that is NOT a free choice:
#   MAME_SHM_SIZE=1024x768   must equal arm A's captured surface — the kiosk's
#                            bare-X root. Unequal arms measure resolution.
#   MAME_CTL_PTR_TAGS        the ST's mouse is :ikbd:MOUSEB/MOUSEX/MOUSEY, not
#   MAME_CTL_BTN_NAMES       the SGI Indy's PS/2 mouse the module defaults to.
#                            Without these the module comes up btns=0 axes=0 and
#                            every pointer verb is a silent no-op.
#   MAME_CTL_PTR_MOD=256     the ST's MOUSEX/MOUSEY ioports are 8-bit (mask
#                            255) where the SGI's are 16-bit. The engine writes
#                            a running total the guest differences, and MAME
#                            CLAMPS set_value to the field range -- so a total
#                            wrapping at 65536 saturates at 255 on the first
#                            homing slam and the cursor never moves again while
#                            every command is still acked.
#   MAME_CTL_SCREEN=79x52    the clamp surface MOVEA targets are clipped to --
#                            and on this machine that surface is COUNTS, not
#                            pixels. The ST's pointer is a quadrature encoder
#                            with no hardware cursor to read back, so streamhost
#                            runs SH_MAMESOCK_PTR_GRID and states targets on the
#                            79 x 52 count grid the GEM cursor can actually
#                            reach (measured; see the README's pointer section).
#                            Leaving this at 1024x768 would let a stale belief
#                            park 1000 counts from the truth == 8 s of drain.
#   -throttle -frameskip 0   identical to arm A, for the same reasons.
#   MAME_CTL_MOVE_STEP/WINDOW the emulated mouse's own delivery rate; see below.
set -e
D=/data/vms/soltest/debridge-7f3a/armB
M=/data/vms/streamhost/assets/atarist-mame/mame/atarist
ROMS=/data/vms/soltest/BUILD-atarist-mame/roms
mkdir -p "$D/cfg" "$D/nvram"
printf 'skip_warnings 1\n' >"$D/ui.ini"

if [ -f "$D/mame.pid" ] && kill -0 "$(cat "$D/mame.pid")" 2>/dev/null; then
  echo "armB MAME already running pid=$(cat "$D/mame.pid")" >&2
  exit 0
fi
rm -f "$D/mame.pid" "$D/ctl.sock"

export MAME_SHM_PATH="$D/fb.shm"
export MAME_SHM_SIZE=1024x768
export MAME_CTL_SOCK="$D/ctl.sock"
export MAME_CTL_PTR_TAGS=":ikbd:MOUSEB,:ikbd:MOUSEX,:ikbd:MOUSEY"
export MAME_CTL_BTN_NAMES="Mouse Button 1,Mouse Button 2,"
export MAME_CTL_PTR_MOD=256
# PACING, and this one is the machine talking. MAME emulates the ST mouse as a
# QUADRATURE encoder (src/mame/atari/stkbd.cpp): a 500 Hz tick reads the axis
# ioport, derives only a DIRECTION from the change and throws the MAGNITUDE
# away, then emits one step per 4 ticks. The guest therefore accepts at most 125
# counts per emulated second per axis, and a burst is DISCARDED rather than
# carried (unlike the SGI PS/2 mouse, whose carry patch exists for exactly this
# reason). The module's default 120 counts per 40 ms is 24x that budget, and the
# symptom is dead reckoning that silently undershoots by an order of magnitude
# while every command is acked. 1 count per 8 emulated ms == 125/s == the
# device's own rate, so every issued count lands and the belief stays true.
#
# ARM A INHERITS THE SAME CEILING -- same emulator, same 8-bit axis -- but it
# does NOT inherit "and therefore needs no setting", which this comment used to
# claim. Its axis arrives through MAME's own analog path at 6.4 (X) / 8.6 (Y)
# ioport counts per surface pixel, and the 8-bit field WRAPS: past ~20 px of
# motion in one emulated frame the latch read the direction backwards. That is
# ordinary pointer speed, and it is why arm A's pointer was reported inverted.
# It is fixed in MAME's own input configuration (armA-ptr-cfg.py: reverse="yes"
# sensitivity="1"), not here.
export MAME_CTL_MOVE_STEP=1
export MAME_CTL_MOVE_WINDOW=4
# QUADRATURE SENSOR (2026-08-11): the stkbd latches a DIRECTION once per 8 ms
# period and emits one cycle — magnitude is discarded, so a pacing beat or a
# reversal pair silently loses counts (measured: 5.6 counts adrift after a
# 5 s fast circle while the ikbd's value latch was exact; a consumed-value
# flow gate was tried first and made it WORSE, 12.8 counts). With the phase
# items named, the module's belief integrates EMITTED cycles — the ground
# truth of what the guest receives — and a settle corrector re-issues
# whatever merged away once the pipe has been quiet for three windows.
export MAME_CTL_QUAD_ITEMS="m_mouse_px,m_mouse_py,m_mouse_pc"
# FAST MOUSE (2026-08-11): mame-st-fastmouse.patch makes the stkbd quadrature
# tick env-tunable. 1000 Hz = 4 ms periods = 250 counts/s, twice stock — and
# still conservative against a real ST mouse (200 counts/inch). 1000 is the
# measured fidelity ceiling: at 2000 the emulated 6301 firmware drops a
# couple of counts per burst BELOW the module's emission sensor (constant
# +2-count Y skew the settle corrector cannot see), while at 1000 every
# fixture lands within 0.9 counts. MOVE_WINDOW=4 matches: exactly one issued
# count per device period.
export MAME_ST_MOUSE_HZ=1000
export MAME_CTL_SCREEN=81x52
export SDL_VIDEODRIVER=dummy
unset DISPLAY

# The atarist exhibit's apps, carried over from the hatari station's GEMDOS
# folder mount (which MAME has no equivalent for) as two 1.44 MB ST floppies:
# A: = AIM/PACMAN/BALLER + EMUDESK.INF, B: = GEMBNCH. The ORIGINAL/ tree is
# deliberately left out — pristine duplicates of the same programs.
FLOP=/data/vms/streamhost/assets/atarist-mame/floppies
FLOPARG=()
[ -f "$FLOP/apps1.st" ] && FLOPARG+=(-flop1 "$FLOP/apps1.st")
[ -f "$FLOP/apps2.st" ] && FLOPARG+=(-flop2 "$FLOP/apps2.st")

nohup "$M" st \
  -rompath "$ROMS" -inipath "$D" -homepath "$D" \
  ${FLOPARG[@]+"${FLOPARG[@]}"} \
  -cfg_directory "$D/cfg" -nvram_directory "$D/nvram" \
  -video shm -nofilter \
  -sound none -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  >"$D/mame.log" 2>&1 &
echo $! >"$D/mame.pid"
for _ in $(seq 1 40); do
  [ -S "$D/ctl.sock" ] && break
  sleep 0.5
done
echo "armB mame pid=$(cat "$D/mame.pid") shm=$D/fb.shm ctl=$D/ctl.sock"
grep -m1 'ctlsock: setup' "$D/mame.log" || true
