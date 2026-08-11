#!/bin/bash
# Case-arm values for recording the OpenVMS checkpoint-resume path on a clone.
bootrec_scaffold_openvms() {
  BR_BOOT_KIND="vmstate"
  BR_CANVAS_W=1600
  BR_CANVAS_H=900
  BR_FPS=30
  BR_HAS_AUDIO=0
  BR_DISKS="openvms-community.qcow2 OVMF_VARS.qcow2"
  BR_DETECT_TIER=1
  BR_CF_THRESHOLD="0.001"
  BR_SETTLE_MS=3000
  BR_MAX_MS=30000
}
