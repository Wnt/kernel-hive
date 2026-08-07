#!/bin/bash
# launch_tile.sh — generalized throwaway validation guest for streamhost.
# Namespaced, isolated, killed only by pidfile. NEVER touches live tiles / VM900 /
# CT112. Generalizes the original launch_vm951.sh.
#
# Usage:
#   run/launch_tile.sh <vmid> [--iso PATH | --disk PATH] [--pointer abs|rel]
#                      [--audio on|off] [--touch on|off] [--mem MB] [--smp N]
#
# It boots a QEMU with the streamhost display/input/audio wiring, so streamhost
# can attach to $R/qmp<vmid>.sock. Concurrent-build hygiene: unique VMID -> unique
# run dir, QMP sock, pidfile. Pick VMIDs 950+ for throwaway guests.
set -e

VMID="${1:?usage: launch_tile.sh <vmid> [flags]}"
shift || true
ISO=""
DISK=""
POINTER="abs"
AUDIO="on"
TOUCH="off"
MEM=1024
SMP=2
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)
      ISO="$2"
      shift 2
      ;;
    --disk)
      DISK="$2"
      shift 2
      ;;
    --pointer)
      POINTER="$2"
      shift 2
      ;;
    --audio)
      AUDIO="$2"
      shift 2
      ;;
    --touch)
      TOUCH="$2"
      shift 2
      ;;
    --mem)
      MEM="$2"
      shift 2
      ;;
    --smp)
      SMP="$2"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done
[ -z "$ISO" ] && [ -z "$DISK" ] && ISO=/data/isos/TinyCore.iso

R="/data/vms/streamhost/run${VMID}"
mkdir -p "$R"
QMP="$R/qmp${VMID}.sock"
PID="$R/qemu${VMID}.pid"
[ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
sleep 0.3
rm -f "$QMP" "$PID"

# --- input devices ---
#   virtio-keyboard : reliable key injection
#   virtio-tablet   : ABSOLUTE pointer (SetAbsPosition). Relative guests omit it.
#   virtio-multitouch-pci : MultiTouch.SendEvent (phone tiles)
INPUT=(-device virtio-keyboard-pci)
if [ "$POINTER" = "abs" ]; then INPUT+=(-device virtio-tablet-pci); fi
if [ "$TOUCH" = "on" ]; then INPUT+=(-device virtio-multitouch-pci); fi

# --- audio: dbus audiodev on the SAME p2p bus; forced 48k/stereo/s16 for Opus ---
# CRUCIAL: the dbus DISPLAY must reference the audiodev (audiodev=snd0) or the
# org.qemu.Display1.Audio object is never exported on the peer connection.
DISPLAY_ARG="dbus,p2p=on"
AUDIO_ARGS=()
if [ "$AUDIO" = "on" ]; then
  DISPLAY_ARG="dbus,p2p=on,audiodev=snd0"
  AUDIO_ARGS=(-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16
    -device intel-hda -device hda-output,audiodev=snd0)
fi

MEDIA=()
[ -n "$ISO" ] && MEDIA+=(-cdrom "$ISO" -boot d)
[ -n "$DISK" ] && MEDIA+=(-drive file="$DISK",if=virtio)

nohup qemu-system-x86_64 \
  -name "streamhost-tile${VMID}" \
  -enable-kvm -m "$MEM" -smp "$SMP" \
  "${MEDIA[@]}" \
  -vga std \
  -display "$DISPLAY_ARG" \
  "${AUDIO_ARGS[@]}" \
  "${INPUT[@]}" \
  -qmp unix:"$QMP",server=on,wait=off \
  -pidfile "$PID" \
  -nic none \
  >"$R/qemu${VMID}.log" 2>&1 &

echo "qemu ${VMID} launched (pointer=$POINTER audio=$AUDIO touch=$TOUCH); waiting for qmp+pid"
for i in $(seq 1 40); do
  [ -S "$QMP" ] && [ -f "$PID" ] && break
  sleep 0.5
done
echo "pid=$(cat "$PID" 2>/dev/null) qmp=$QMP"
ls -la "$QMP"
