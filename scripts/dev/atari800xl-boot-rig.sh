#!/bin/bash
set -x
RIG=/data/vms/sandbox/atari800xl-golden/rig
BIN=/data/vms/streamhost/assets/atari800xl/mame-native/atari800xl
ROMS=/data/vms/streamhost/assets/atari800xl/mame-native/roms
DISK=/data/vms/streamhost/assets/atari800xl/media/hive.atr
rm -rf "$RIG"
mkdir -p "$RIG/cfg" "$RIG/nvram" "$RIG/sta"
printf 'skip_warnings 1\n' > "$RIG/ui.ini"
cd "$RIG"
export MAME_SHM_PATH="$RIG/fb.shm"
export MAME_SHM_SIZE=1024x768
export MAME_CTL_SOCK="$RIG/ctl.sock"
export MAME_NO_UI=1
export SDL_VIDEODRIVER=dummy
export MAME_CTL_KEY_HOLD=40
export MAME_CTL_KEY_GAP=40
nohup "$BIN" a800xlp \
  -rompath "$ROMS" -inipath "$RIG" -homepath "$RIG" \
  -cfg_directory "$RIG/cfg" -nvram_directory "$RIG/nvram" \
  -video shm -nofilter -sound none \
  -skip_gameinfo -throttle -frameskip 0 -noautoframeskip \
  -state_directory "$RIG/sta" \
  -flop1 "$DISK" -ctrl1 joy \
  >"$RIG/mame.log" 2>&1 &
echo $! > "$RIG/mame.pid"
for i in $(seq 1 40); do
  [ -S "$RIG/ctl.sock" ] && [ -s "$RIG/fb.shm" ] && break
  sleep 0.5
done
echo "pid=$(cat $RIG/mame.pid)"
ls -la "$RIG"
cat "$RIG/mame.log" | tail -20
