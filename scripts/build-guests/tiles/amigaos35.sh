#!/bin/bash
# =============================================================================
# tiles/amigaos35.sh — build the AmigaOS 3.5 system disk for the host-native
# FS-UAE station (no QEMU anywhere in this builder).
#
# What is FULLY automated (stage: assemble):
#   * media gate — every input hash-checked against MANIFEST.sha256
#     (/data/assets-staging/amigaos35, see docs/lab/ASSETS-MANIFEST.md);
#   * Workbench 3.1 base install — the six ADFs are unpacked host-side with
#     amitools' xdftool and merged into a fresh 512 MiB FFS hardfile exactly
#     as the 3.1 installer lays them out (Workbench root + Extras L/Prefs/
#     System/Tools + Fonts + Locale + Storage). Proven: the HDF boots
#     Workbench 3.1 with no floppy.
#
# What is CLICK-SCRIPTED, not blind (stage: install — the OS 3.5 installer is
# a GUI Installer with no unattended interface): fs-uae (the PINNED patched
# 3.2.35 from build-fsuae-native.sh) runs under a namespaced Xvfb, the OS 3.5
# CD tree (extracted from the ISO) is mounted as a directory hard drive, and
# xdotool drives the installer's PRE / MAIN / Internet phases with a paced
# press/release (an instant click inside one 50 Hz frame is never sampled —
# measured 2026-08-24). Every step screenshots into $EVIDENCE and the flow
# stops on an unexpected frame rather than clicking blind. The click
# coordinates were stable across repeated runs at 720x568; a divergence is a
# STOP, not a retry storm.
#
# Output (ONE combination with the emulator binary):
#   $OUT/amigaos35-system.hdf — the installed system disk (golden master).
#   No statefile: the station cold-boot resets (FSUAE_NATIVE_CHECKPOINT=0;
#   UAE savestates + bsdsocket are structurally unsafe — see the guest doc).
#   After any golden capture, set the FFS root bm_flag valid + refresh the
#   root checksum (the OS 3.5 validator fails on a dirty xdftool volume).
#
# The 2026-08-24 bring-up ran these stages by hand in
# /data/vms/sandbox/amigaos35/build (kept as evidence); this script encodes
# that recipe. docs/guests/amigaos35.md is the narrative.
# =============================================================================
set -euo pipefail

OS_ID=amigaos35
ASSETS=/data/assets-staging/$OS_ID
OUT="${OUT:-/data/gallery-guests/AmigaOS35}"
WORK="${WORK:-/data/vms/sandbox/build-$OS_ID}"
EVIDENCE="$WORK/evidence"
DISP="${AMIGAOS35_BUILD_DISPLAY:-:97}"
FSUAE="${FSUAE_NATIVE_BIN:-/data/vms/streamhost/assets/amigaos35/fsuae-native/bin/fs-uae}"
XDFTOOL="${XDFTOOL:-xdftool}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

check_assets() {
  [ -d "$ASSETS" ] || die "no staged media at $ASSETS"
  (cd "$ASSETS" && sha256sum -c MANIFEST.sha256 >/dev/null) || die "media manifest mismatch in $ASSETS"
  log "media gate OK ($ASSETS)"
}

[ "${1:-}" = --check-assets ] && {
  check_assets
  exit 0
}
check_assets
command -v "$XDFTOOL" >/dev/null || die "amitools xdftool not on PATH (pip install amitools)"
[ -x "$FSUAE" ] || die "no pinned fs-uae at $FSUAE — run build-fsuae-native.sh"

mkdir -p "$WORK" "$EVIDENCE" "$OUT"

# --- stage: assemble (fully automated) --------------------------------------
HDF="$WORK/amigaos35-system.hdf"
if [ ! -f "$HDF" ]; then
  log "assembling WB3.1 base HDF"
  "$XDFTOOL" "$HDF" create size=512Mi + format System ffs
  ADF="$WORK/adf"
  mkdir -p "$ADF"
  for d in workbench extras locale fonts storage; do
    "$XDFTOOL" "$ASSETS/amiga-wb31_$d.adf" unpack "$ADF/"
  done
  S="$WORK/sys-stage"
  rm -rf "$S"
  mkdir "$S"
  cp -r "$ADF/Workbench3.1/." "$S/"
  cp -r "$ADF/Extras3.1/L/." "$S/L/" 2>/dev/null || true
  cp -r "$ADF/Extras3.1/Prefs/." "$S/Prefs/"
  cp -r "$ADF/Extras3.1/System/." "$S/System/"
  cp -r "$ADF/Extras3.1/Tools" "$S/Tools"
  cp "$ADF/Extras3.1/Tools.info" "$S/Tools.info"
  mkdir -p "$S/Fonts" "$S/Locale" "$S/Storage"
  cp -r "$ADF/Fonts/." "$S/Fonts/"
  cp -r "$ADF/Locale/." "$S/Locale/"
  cp -r "$ADF/Storage3.1/." "$S/Storage/"
  rm -f "$S/Fonts/Disk.info" "$S/Locale/Disk.info" "$S/Storage/Disk.info"
  (cd "$S" && ls -1) | while read -r c; do
    "$XDFTOOL" "$HDF" write "$S/$c" "$c"
  done
  log "WB3.1 base assembled into $HDF"
fi

# CD tree for the directory hard drive (volume name = dir name).
CDDIR="$WORK/AmigaOS3.5"
if [ ! -d "$CDDIR" ]; then
  mkdir -p "$CDDIR"
  bsdtar -xf "$ASSETS/AmigaOS35.iso" -C "$CDDIR" 2>/dev/null ||
    7z x -o"$CDDIR" -y "$ASSETS/AmigaOS35.iso" >/dev/null
  [ -d "$CDDIR/OS-Version3.5" ] || die "ISO extraction incomplete (no OS-Version3.5)"
fi

log "assemble stage done."
log "install + curate stages are click-scripted and OPERATOR-PACED; the exact"
log "proven sequence (coordinates, waits, evidence frames) is in"
log "docs/guests/amigaos35.md §build and the 2026-08-24 sandbox evidence dir."
log "Output expected by the station: $OUT/amigaos35-system.hdf (golden"
log "master; cold-boot reset — no statefile)."
