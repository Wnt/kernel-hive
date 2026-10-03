#!/bin/bash
# Host-native legacy launcher contract: mame.pid is the emulator pid.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
ASSETS="${MSXTURBOR_ASSETS:-/data/vms/streamhost/assets/msxturbor}"
BIN="${MSXTURBOR_BIN:-$ASSETS/openmsx/bin/openmsx}"
PROFILE="${MSX_PROFILE:-view}"
case "$PROFILE" in
  view) DISK=3 ;;
  dos) DISK=2 ;;
  *)
    echo 'MSX_PROFILE must be view or dos' >&2
    exit 1
    ;;
esac
# The surrounding runtime/clone guard stops the old process before relaunch.
if [[ -s "$D/mame.pid" ]] && kill -0 "$(cat "$D/mame.pid")" 2>/dev/null; then
  echo 'Refusing to replace a running openMSX instance' >&2
  exit 1
fi
WORK="$D/work"
rm -rf -- "$WORK"
mkdir -p "$WORK/profile/systemroms" "$WORK/disks" "$WORK/tmp"
cp "$ASSETS/media/fs-a1gt_firmware.rom" "$ASSETS/media/fs-a1gt_kanjifont.rom" "$WORK/profile/systemroms/"
for n in 1 2 3; do cp --reflink=auto "$ASSETS/media/disk$n.dsk" "$WORK/disks/disk$n.dsk"; done
chmod u+w "$WORK/disks/"*.dsk
if [[ "$PROFILE" == dos ]]; then
  # Keep the original DOS kernel and utilities; replace only the throwaway
  # copy's autoexec so this profile rests at a prompt instead of TOOL's menu.
  printf 'PATH \\UTILS\r\n' >"$WORK/dos-autoexec.bat"
  mcopy -o -i "$WORK/disks/disk2.dsk" "$WORK/dos-autoexec.bat" ::AUTOEXEC.BAT
fi
SHM="${SH_SHM_PATH:-$D/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$D/ctl.sock}"
FIFO="${SH_AUDIO_FIFO:-$D/audio.fifo}"
rm -f -- "$SHM" "$CTL" "$FIFO"
mkfifo -m 600 "$FIFO"
export TMPDIR="$WORK/tmp"
export OPENMSX_HOME="$WORK/profile"
export OPENMSX_USER_DATA="$WORK/profile"
export OPENMSX_SYSTEM_DATA="${MSXTURBOR_SHARE:-$ASSETS/openmsx/share}"
export OPENMSX_SHM_PATH="$SHM" OPENMSX_AUDIO_FIFO="$FIFO"
export LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=1
export SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=dummy MSX_PROFILE="$PROFILE"
# stdin XML belongs only to the adapter. The Unix input socket is mode 0600.
setsid nohup python3 "$D/adapter.py" "$CTL" "$D/mame.pid" \
  "$BIN" -control stdio -machine Panasonic_FS-A1GT \
  -diska "$WORK/disks/disk$DISK.dsk" -script "$D/boot.tcl" \
  >"$D/openmsx.log" 2>&1 </dev/null &
echo $! >"$D/adapter.pid"
