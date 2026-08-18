#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf.
# Fill this function on clones, then move its assignments into bootrec_load_tile.
bootrec_scaffold_rhapsody() {
  BR_BOOT_KIND="vmstate" # loadvm golden once the checkpoint exists (install phase: cold disk boot)
  BR_CANVAS_W=800        # DR2 x86 default VGA mode; confirm on the installed desktop
  BR_CANVAS_H=600
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="rhapsody-golden.qcow2" # one disk holds volume + vmstate
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
