#!/bin/bash
# SymbOS cold boot uses a fresh copy of the immutable floppy, not a savestate.
bootrec_symbos() {
  BR_BOOT_KIND="restart"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="runtime.dsk"
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
