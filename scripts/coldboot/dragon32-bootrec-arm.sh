#!/bin/bash
# Reference copy of the `dragon32)` arm that now lives in
# scripts/coldboot/bootrec-tiles.conf. Kept for the same reason the c128/cbm2/
# gt40/pdp11 copies are: the conf file is a single 600-line case statement, and
# a per-station file is where a reviewer can see one station's capture parameters and
# the reasoning behind them without reading the whole thing.
#
# Bridge kind: the emulator cold-boots per visit, so record the kiosk restart
# and SKIP savevm/verify. Nothing is curated into this station's fixture, so the
# clip's last frame is the golden's first frame.
bootrec_scaffold_dragon32() {
  BR_BOOT_KIND="bridge"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=1
  BR_AUDIO_RATE=48000
  BR_AUDIO_CH=2
  BR_HOSTFWD_ORIG=5833
  BR_HOSTFWD_CLONE=6833
  # The shared bridge base is read-only; only the overlay is writable.
  BR_DISKS="overlay.qcow2"
  BR_DETECT_TIER=3
  BR_TIER3_TIMER_MS=45000
  BR_MAX_MS=90000
  BR_EMU_SSH_PORT=6833
  BR_EMU_SSH_KEY="/data/vms/bridge/bridge_key"
  # `dragon`, not `mame`: the station ships a MAME SUBTARGET=dragon build installed
  # as /opt/dragon32/mame/dragon.
  BR_EMU_PREP_CMD="systemctl stop getty@tty1; pkill -u bridge -x dragon 2>/dev/null || true"
  BR_EMU_BOOT_CMD="systemctl start getty@tty1"
}
