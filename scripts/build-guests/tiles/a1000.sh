#!/bin/bash
# =============================================================================
# tiles/a1000.sh — stage the Amiga 1000 floppy set + Kickstart ROM for the
# host-native FS-UAE station (no QEMU, no HDF, no installer, no xdotool: this
# is a floppy-boot station — see docs/lab/A1000-WAVE.md).
#
# What this script does (fully automated: media gate + byte-copy stage):
#   * media gate — every input hash-checked against MANIFEST.sha256 in the
#     media dir (see docs/lab/ASSETS-MANIFEST.md);
#   * stage the Kickstart 1.2 r33.180 ROM and the A1000 bootstrap ROM into
#     the station's own assets dir (fsuae-native reads FSUAE_NATIVE_KICK /
#     the bootstrap path from there, same layout as amix/amigaos35);
#   * byte-copy Workbench 1.2 Disk 1 and the (GB) Extras Disk 2 into $OUT as
#     wb12.adf / extras12.adf — the station launcher (x11-runtime.sh) copies
#     $BASE/disk/wb12.adf and $BASE/disk/extras12.adf from there; staging
#     into the live station dir under /data/vms/streamhost/stations/a1000/
#     is the golden stream's job, not this script's.
#
# No emulation happens here. FS-UAE itself is built by
# build-fsuae-native.sh (FSUAE_STATION=a1000), a separate step.
# =============================================================================
set -euo pipefail

OS_ID=a1000
ASSETS="${ASSETS:-/data/vms/sandbox/a1000/media}"
OUT="${OUT:-/data/gallery-guests/A1000}"
ROM_OUT="${ROM_OUT:-/data/vms/streamhost/assets/a1000}"

KICK_SRC="Kickstart v1.2 r33.180 (1986-10)(Commodore)(A500-A1000-A2000)[!].rom"
BOOTSTRAP_SRC="Amiga 1000 ROM Bootstrap (1985)(Commodore)(A1000)[!].rom"
WB_SRC="Workbench v1.2 rev 33.56 (1987)(Commodore)(A500)(Disk 1 of 2)(Workbench).adf"
EXTRAS_SRC="Workbench v1.2 rev 33.56 (1987)(Commodore)(A500)(GB)(Disk 2 of 2)(Extras).adf"

KICK_BYTES=262144
BOOTSTRAP_BYTES=65536
ADF_BYTES=901120

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

report() {
  local path="$1"
  local size
  size="$(stat -c%s "$path")"
  log "staged $path  ${size} bytes  $(sha256sum "$path" | cut -d' ' -f1)"
}

[ "${1:-}" = --check-assets ] && {
  check_assets
  exit 0
}
check_assets

mkdir -p "$ROM_OUT" "$OUT"

[ -f "$ASSETS/$KICK_SRC" ] || die "missing $KICK_SRC in $ASSETS"
[ -f "$ASSETS/$BOOTSTRAP_SRC" ] || die "missing $BOOTSTRAP_SRC in $ASSETS"
[ -f "$ASSETS/$WB_SRC" ] || die "missing $WB_SRC in $ASSETS"
[ -f "$ASSETS/$EXTRAS_SRC" ] || die "missing $EXTRAS_SRC in $ASSETS"

[ "$(stat -c%s "$ASSETS/$KICK_SRC")" = "$KICK_BYTES" ] || die "$KICK_SRC is not $KICK_BYTES bytes"
[ "$(stat -c%s "$ASSETS/$BOOTSTRAP_SRC")" = "$BOOTSTRAP_BYTES" ] || die "$BOOTSTRAP_SRC is not $BOOTSTRAP_BYTES bytes"
[ "$(stat -c%s "$ASSETS/$WB_SRC")" = "$ADF_BYTES" ] || die "$WB_SRC is not $ADF_BYTES bytes"
[ "$(stat -c%s "$ASSETS/$EXTRAS_SRC")" = "$ADF_BYTES" ] || die "$EXTRAS_SRC is not $ADF_BYTES bytes"

install -m 0644 "$ASSETS/$KICK_SRC" "$ROM_OUT/kick12-r33.180.rom"
install -m 0644 "$ASSETS/$BOOTSTRAP_SRC" "$ROM_OUT/a1000-bootstrap.rom"
install -m 0644 "$ASSETS/$WB_SRC" "$OUT/wb12.adf"
install -m 0644 "$ASSETS/$EXTRAS_SRC" "$OUT/extras12.adf"

log "stage complete."
report "$ROM_OUT/kick12-r33.180.rom"
report "$ROM_OUT/a1000-bootstrap.rom"
report "$OUT/wb12.adf"
report "$OUT/extras12.adf"
