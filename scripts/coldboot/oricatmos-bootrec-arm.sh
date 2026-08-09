#!/bin/bash
# Reference copy of the `oricatmos)` case arm that LIVES IN
# scripts/coldboot/bootrec-tiles.conf. The conf is the file record-boot.sh
# reads; this one exists so the arm can be diffed and reviewed on its own.
# Keep the two in step, or delete this file rather than let it rot.
bootrec_scaffold_oricatmos() {
  BR_BOOT_KIND="bridge"
  BR_CANVAS_W=800
  BR_CANVAS_H=600
  BR_FPS=30
  BR_HAS_AUDIO=1
  BR_AUDIO_RATE=48000
  BR_AUDIO_CH=2
  BR_HOSTFWD_ORIG=5834
  BR_HOSTFWD_CLONE=6834
  BR_DISKS="overlay.qcow2" # the frozen bridge base stays read-only
  BR_DETECT_TIER=3
  BR_TIER3_TIMER_MS=45000
  BR_MAX_MS=90000
  BR_EMU_SSH_PORT=6834
  BR_EMU_SSH_KEY="/data/vms/bridge/bridge_key"
  # Exact process name only: the MAME subtarget binary is called `oricatmos`,
  # so `pkill -f oricatmos` would match the recording shell itself.
  BR_EMU_PREP_CMD="systemctl stop getty@tty1; pkill -u bridge -x oricatmos 2>/dev/null || true"
  BR_EMU_BOOT_CMD="systemctl start getty@tty1"
}
