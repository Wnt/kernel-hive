#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf.
# Filled by the golden stream 2026-09-03 (KDE 3.3.2 desktop 1024x768x16 restored from vmstate).
bootrec_scaffold_freebsd411() {
  BR_BOOT_KIND="vmstate" # loadvm golden on disk.qcow2 (the only block device)
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="disk.qcow2" # the only writable disk; carries the golden vmstate
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
