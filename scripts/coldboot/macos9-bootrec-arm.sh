#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf (macos9).
# Filled from the 2026-08-24 bring-up; boot video not yet recorded.
bootrec_scaffold_macos9() {
  BR_BOOT_KIND="vmstate"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="macos9-golden.qcow2" # the single IDE qcow2; vmstate lives in it
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  # Cold boot to the Finder desktop takes ~3.5 min under TCG.
  BR_MAX_MS=300000
}
