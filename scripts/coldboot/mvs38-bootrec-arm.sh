#!/bin/bash
# Draft case arm for scripts/coldboot/bootrec-tiles.conf.
# Fill this function on clones, then move its assignments into bootrec_load_tile.
#
# mvs38 has NO vmstate and no writable qcow2: it is a host application in a
# container (Hercules + Xvfb + one x3270) and its cold boot IS the station's
# ordinary relaunch — work/tk5 is rebuilt from the read-only TK5 tree and MVS
# IPLs from scratch. There is nothing to clone, so BR_DISKS is empty.
#
# MEASURED 2026-09-20 at box load 45: Hercules exec -> `IKT005I TCAS IS
# INITIALIZED` 55 s, -> ISPF primary option menu on the framebuffer 103 s. The
# ceiling below is that plus room for a loaded box.
bootrec_scaffold_mvs38() {
  BR_BOOT_KIND="restart"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS=""
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.005"
  BR_SETTLE_MS=4000
  BR_MAX_MS=300000
}
