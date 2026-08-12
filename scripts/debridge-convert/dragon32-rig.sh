#!/bin/bash
# De-bridging conversion rig, dragon32 (the TEMPLATE station): the host-native
# MAME side. No QEMU, no guest Debian, no X server — frames into a shared
# mapping (`-video shm`), input back over the ctlsock socket, audio out
# through a named FIFO the streamhost daemon clocks (the irix tile's audio
# contract, x11-runtime.sh §audio).
#
# NOT A STATION. Namespaced under /data/vms/soltest/debridge-dragon32; the live
# dragon32 kiosk keeps serving untouched. Kill ONLY through the guard
# (`stop` below wraps `clone-guard kill-pidfile`).
#
# The env that is NOT a free choice:
#   MAME_SHM_SIZE=1024x768  the station's published surface. A converted
#                           station keeps its registry geometry.
#   -ext ""                 THE flag. Without it the driver's default
#                           dragon_fdc cartridge boots DRAGONDOS 1.0 instead
#                           of Microsoft BASIC (see native.d/dragon32.sh).
#   -throttle -frameskip 0  a live exhibit runs at the machine's own pace.
#   SDL_DISKAUDIOFILE       SDL's disk "audio driver" writes the mixed s16
#                           stereo 48 kHz stream to a path; pointed at a FIFO
#                           it becomes a live pipe. The daemon
#                           (SH_AUDIO_SOURCE=fifo) is the CLOCK on the far
#                           end; a resident holder keeps both FIFO ends open
#                           so neither side's open() can hang the other.
#
#   usage: dragon32-rig.sh [start|stop|status]
set -euo pipefail
D=/data/vms/soltest/debridge-dragon32
M=/data/vms/streamhost/assets/dragon32/mame-native/dragon
ROMS=/data/vms/streamhost/assets/dragon32/mame-native/roms
AFIFO="$D/audio.fifo"
ACT="${1:-start}"

running() {
  [ -f "$D/mame.pid" ] &&
    [ "$(readlink -f "/proc/$(cat "$D/mame.pid")/exe" 2>/dev/null)" = "$M" ]
}

case "$ACT" in
  status)
    if running; then
      echo "dragon32 rig MAME RUNNING pid=$(cat "$D/mame.pid")"
    else
      echo "dragon32 rig MAME not running"
    fi
    ;;
  stop)
    clone-guard kill-pidfile "$D/mame.pid"
    if [ -f "$D/afifo-holder.pid" ]; then
      kill "$(cat "$D/afifo-holder.pid")" 2>/dev/null || true
      rm -f "$D/afifo-holder.pid"
    fi
    echo "dragon32 rig MAME stopped"
    ;;
  start)
    [ -x "$M" ] || {
      echo "no host-native binary at $M — run build-mame-native.sh dragon32 first" >&2
      exit 1
    }
    if running; then
      echo "dragon32 rig MAME already running pid=$(cat "$D/mame.pid")" >&2
      exit 0
    fi
    mkdir -p "$D/cfg" "$D/nvram" "$D/sta"
    rm -f "$D/mame.pid" "$D/ctl.sock"
    [ -p "$AFIFO" ] || { rm -f -- "$AFIFO" && mkfifo "$AFIFO"; }
    if [ ! -f "$D/afifo-holder.pid" ] || ! kill -0 "$(cat "$D/afifo-holder.pid")" 2>/dev/null; then
      # Resident FIFO holder: keeps a read-write end open forever, so MAME's
      # (SDL's) blocking open() succeeds whichever side comes up first and a
      # daemon restart never delivers SIGPIPE. ~0.3 s of audio can pool in
      # the pipe while no daemon reads; the daemon drains it on attach.
      # stdio detached: an inherited ssh stdout would hold the session open
      # for the holder's whole life (observed 2026-08-12).
      sleep infinity 3<>"$AFIFO" >/dev/null 2>&1 &
      echo $! >"$D/afifo-holder.pid"
    fi

    export MAME_SHM_PATH="$D/fb.shm"
    export MAME_SHM_SIZE=1024x768
    export MAME_CTL_SOCK="$D/ctl.sock"
    export SDL_DISKAUDIOFILE="$AFIFO"
    export SDL_DISKAUDIODELAY=0
    export SDL_VIDEODRIVER=dummy
    unset DISPLAY

    # Instant-restore: once a golden savestate is baked (ctlsock SAVEST after
    # the operator-approved scene), every start RESTORES it — the QEMU fleet's
    # `-loadvm golden`, translated to MAME (the irix pattern, minus the CHD
    # pairing a ROM-only machine does not have). The state dir is ALWAYS
    # pinned: MAME's default resolves relative to the launch cwd, which for a
    # remote start is nowhere near the rig.
    STARG=(-state_directory "$D/sta")
    [ -f "$D/sta/golden.sta" ] && STARG+=(-state golden)

    nohup "$M" dragon32 \
      -rompath "$ROMS" -inipath "$D" -homepath "$D" \
      -cfg_directory "$D/cfg" -nvram_directory "$D/nvram" \
      -ext "" \
      -video shm -nofilter \
      -sound sdl -audiodriver disk -samplerate 48000 \
      -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
      "${STARG[@]}" \
      >"$D/mame.log" 2>&1 &
    echo $! >"$D/mame.pid"
    for _ in $(seq 1 40); do
      [ -S "$D/ctl.sock" ] && break
      sleep 0.5
    done
    echo "dragon32 rig mame pid=$(cat "$D/mame.pid") shm=$D/fb.shm ctl=$D/ctl.sock audio=$AFIFO state=${STARG[*]:-<cold boot>}"
    grep -m1 'ctlsock: setup' "$D/mame.log" || true
    ;;
  *)
    echo "usage: dragon32-rig.sh [start|stop|status]" >&2
    exit 2
    ;;
esac
