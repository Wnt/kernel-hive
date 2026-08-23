#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf.
# Fill this function on clones, then move its assignments into bootrec_load_tile.
bootrec_scaffold_chokanji() {
  BR_BOOT_KIND="vmstate" # resetMode=loadvm: golden vmstate lives inside chokanji.qcow2
  BR_CANVAS_W=800        # Cirrus GD5446 800x600 (the disk's configured mode)
  BR_CANVAS_H=600
  BR_FPS=30
  BR_HAS_AUDIO=0 # no audio device wired
  BR_DISKS="/data/gallery-guests/Chokanji/chokanji.qcow2"
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
