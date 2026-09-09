#!/bin/bash
# Case-arm values for recording the ravynos live-ISO station on a clone.
# Filled from the 2026-09-01 bring-up; no clip recorded, and none recommended --
# a cold boot stops at the LoginWindow and never reaches the golden's desktop.
# See ravynos-zero-input-prep.md; the live arm is in bootrec-tiles.conf.
bootrec_scaffold_ravynos() {
  BR_BOOT_KIND="vmstate" # resetMode=loadvm; golden vmstate lives in the carrier qcow2
  BR_CANVAS_W=1280       # fixed at boot by OVMF's EFI GOP; the guest cannot change it
  BR_CANVAS_H=800
  BR_FPS=30
  BR_HAS_AUDIO=1
  BR_AUDIO_RATE=48000
  BR_AUDIO_CH=2
  # Both writable disks, carrier FIRST: the read-only live ISO cannot hold a
  # vmstate, so ravynos-golden.qcow2 carries it and OVMF_VARS.qcow2 is the UEFI
  # variable store. Reordering lands the RAM image in the 528 KiB varstore.
  BR_DISKS="ravynos-golden.qcow2 OVMF_VARS.qcow2"
  # Tier 3: a zero-input run has no settling desktop, only a LoginWindow that
  # never changes again (~95-110 s in), and the desktop behind it carries an
  # unhideable menu-bar clock. No record driver -- the login is supervised.
  BR_DETECT_TIER=3
  BR_TIER3_TIMER_MS=130000
  BR_MAX_MS=210000
}
