#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf.
# Fill this function on clones, then move its assignments into bootrec_load_tile.
bootrec_scaffold_ubuntu() {
  BR_BOOT_KIND="vmstate"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="/data/gallery-guests/Ubuntu/ubuntu.qcow2"
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
