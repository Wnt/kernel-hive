#!/bin/bash
# Case arm for scripts/coldboot/bootrec-tiles.conf (redhat62 — Red Hat Linux 6.2 "Zoot").
# Modelled on the redstar2 arm: one external qcow2 carrying the internal "golden"
# snapshot; a cold boot is LILO -> kernel 2.2.14 -> runlevel 5 -> inittab
# `x:5:respawn:/bin/su - gallery -c startx` -> GNOME 1.0 + Enlightenment at
# 1024x768x16 on cirrus. Move these assignments into bootrec_load_tile.
bootrec_scaffold_redhat62() {
  BR_BOOT_KIND="vmstate"
  BR_CANVAS_W=1024
  BR_CANVAS_H=768
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_EXTERNAL_DISKS=("/data/gallery-guests/RedHat62/redhat62.qcow2|redhat62.qcow2")
  BR_GOLDEN_DISK="redhat62.qcow2"
  # Measured 2026-09-03 on the smoke rig under KVM: power-on to a settled GNOME
  # desktop in 93 s (fb-wait --settle 12; LILO default linux-up, no fsck).
  BR_DETECT_TIER=3
  BR_TIER3_TIMER_MS=120000
  BR_MAX_MS=180000
}
