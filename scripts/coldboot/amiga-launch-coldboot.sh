#!/bin/bash
# /etc/bridge/launch.sh (COLD-BOOT-ON-VISIT variant) — Amiga 500 / Workbench 1.3 kiosk.
#
# Replaces the plain `exec fs-uae ...` launcher with a SUPERVISOR so the streamhost
# visit/idle lifecycle can COLD-BOOT the Amiga per visit and power it off when idle,
# WITHOUT ever restarting the kiosk's X server or the streamhost capture:
#
#   * idle   (no emu-on flag)  -> FS-UAE not running; bare-X root is BLACK ("powered off").
#   * visit  (emu-on flag set) -> FS-UAE cold-starts from a FRESH ephemeral Workbench ADF,
#                                 so the visitor SEES the Kickstart 1.3 insert-disk hand,
#                                 HEARS the drive seek/click, then Workbench 1.3 loads.
#                                 Visitor changes are discarded (fresh ADF copy next boot).
#
# The flag is driven by `/usr/local/bin/amiga-emu {boot|stop}`, which the labhost-side
# streamhost session watcher (scripts/coldboot/amiga-coldboot-watch.sh) or the daemon
# idle.rs cmd-hook invokes over ssh. See scripts/amiga-tile-notes.md / docs/guests/amiga500.md.
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
export LIBGL_ALWAYS_SOFTWARE=1 # GPU-less host: llvmpipe software OpenGL for FS-UAE
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=alsa # OpenAL -> ALSA default (hw:0,0) -> QEMU AC97 -> streamhost
M=/opt/bridge/media/amiga
RUN="${XDG_RUNTIME_DIR}/amiga" # tmpfs; the ephemeral per-visit floppy lives here
FLAG="$RUN/emu-on"
mkdir -p "$RUN"
xset s off -dpms s noblank 2>/dev/null || true
xsetroot -solid black 2>/dev/null || true
# Supervisor loop: X stays up for the whole kiosk lifetime; FS-UAE comes and goes.
while true; do
  if [ -f "$FLAG" ]; then
    # COLD BOOT: fresh ephemeral Workbench floppy (pristine every visit).
    cp -f "$M/workbench13.adf" "$RUN/wb-session.adf"
    xsetroot -solid black 2>/dev/null || true
    fs-uae \
      --amiga_model=A500 \
      --kickstart_file="$M/kick13.rom" \
      --floppy_drive_0="$RUN/wb-session.adf" \
      --floppy_drive_volume=100 \
      --floppy_drive_volume_empty=100 \
      --floppy_drive_speed=100 \
      --fullscreen=0 \
      --window_width=720 --window_height=568 \
      --automatic_input_grab=0 \
      --initial_input_grab=0 \
      --fade_out_duration=0 \
      --audio_frequency=48000 2>/tmp/fs-uae.err
    # FS-UAE exited: idle-stop cleared the flag & killed it, OR a re-boot pkill'd it
    # (flag still set -> loop relaunches from a fresh ADF = another cold boot).
    xsetroot -solid black 2>/dev/null || true
  else
    sleep 0.5
  fi
done
