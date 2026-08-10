#!/bin/bash
# De-bridging spike ARM B (tier 3): the SAME MAME Atari ST binary arm A runs
# inside the kiosk, running HOST-NATIVE with no QEMU, no X server and no window.
# Frames go straight into a shared-memory mapping (`-video shm`, the drawshm OSD
# render module) that streamhost reads with SH_CAPTURE=shm; input comes back in
# over the ctlsock control socket (SH_INPUT_BACKEND=mamesock). This is the irix
# tile's shape, minus the parts that are IRIX's own.
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
#   MAME_CTL_SCREEN          the clamp surface MOVEA targets are clipped to.
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
# ARM A INHERITS THE SAME CEILING and needs no setting: it is the same emulator,
# and MAME's SDL input path feeds the same 8-bit axis, so a browser-driven jump
# is throttled there identically. That is why the probe walks the pointer in
# both arms instead of teleporting it.
export MAME_CTL_MOVE_STEP=1
export MAME_CTL_MOVE_WINDOW=8
export MAME_CTL_SCREEN=1024x768
export SDL_VIDEODRIVER=dummy
unset DISPLAY

nohup "$M" st \
  -rompath "$ROMS" -inipath "$D" -homepath "$D" \
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
