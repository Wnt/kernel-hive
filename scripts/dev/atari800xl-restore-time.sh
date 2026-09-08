#!/bin/bash
set -x
RIG=/data/vms/sandbox/atari800xl-golden/rig
BIN=/data/vms/streamhost/assets/atari800xl/mame-native/atari800xl
ROMS=/data/vms/streamhost/assets/atari800xl/mame-native/roms
DISK=/data/vms/streamhost/assets/atari800xl/media/hive.atr
CTLPY=/data/vms/sandbox/atari800xl-golden/repo/scripts/dev/atari800xl-ctl.py

for d in /proc/[0-9]*; do
  p="${d#/proc/}"
  [ -r "$d/environ" ] || continue
  if tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -qx "MAME_CTL_SOCK=$RIG/ctl.sock"; then
    kill -TERM "$p" 2>/dev/null
  fi
done
sleep 1

cd "$RIG"
export MAME_SHM_PATH="$RIG/fb.shm"
export MAME_SHM_SIZE=1024x768
export MAME_CTL_SOCK="$RIG/ctl.sock"
export MAME_NO_UI=1
export SDL_VIDEODRIVER=dummy
export MAME_CTL_KEY_HOLD=40
export MAME_CTL_KEY_GAP=40

T0=$(date +%s.%N)
nohup "$BIN" a800xlp \
  -rompath "$ROMS" -inipath "$RIG" -homepath "$RIG" \
  -cfg_directory "$RIG/cfg" -nvram_directory "$RIG/nvram" \
  -video shm -nofilter -sound none \
  -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  -state_directory "$RIG/sta" -state golden \
  -flop1 "$DISK" -ctrl1 joy \
  >"$RIG/mame_restore.log" 2>&1 &
echo $! > "$RIG/mame.pid"
for i in $(seq 1 40); do
  [ -S "$RIG/ctl.sock" ] && [ -s "$RIG/fb.shm" ] && break
  sleep 0.2
done
T1=$(date +%s.%N)
python3 "$CTLPY" "$RIG/ctl.sock" SHOT "$RIG/restored_menu.png"
T2=$(date +%s.%N)
echo "RESTORE_SOCK_READY $(python3 -c "print($T1-$T0)")"
echo "RESTORE_SHOT_ELAPSED $(python3 -c "print($T2-$T0)")"
python3 "$CTLPY" "$RIG/ctl.sock" PING
cat "$RIG/mame_restore.log"
