#!/bin/bash
# Native restart profile: no QEMU vmstate or writable shared disk.
bootrec_scaffold_msxturbor() {
  BR_BOOT_KIND="restart"
  BR_CANVAS_W=640
  BR_CANVAS_H=480
  BR_FPS=60
  BR_HAS_AUDIO=1
  BR_DISKS=""
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=3000
  BR_MAX_MS=180000
}
