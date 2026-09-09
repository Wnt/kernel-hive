#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/sculpt.sh
#
# Genode Sculpt OS 25.04 — the microkernel "component graph" desktop
# (Leitzentrale). Tier 1 (QEMU/KVM, x86-64). There is nothing to compile: the
# guest is the official Genode Labs release disk image, downloaded from origin
# and composed into a writable qcow2. This composer fetches the pinned image,
# verifies its publisher sha256, and produces the station disk.
#
#   media : https://genode.org/files/sculpt/sculpt-25-04.img
#   size  : 33,923,072 bytes
#   sha256: 54e8bd5f3b7c5ebf0fac84aa2c103d8bb8efa62ef6bcb5a08f2cad42cc29c366
#
# NOTE: dark-launched / VIEWABLE only as of 2026-09-09. Interactive pointer
# injection into this fresh image is unproven — see docs/lab/SCULPT-WAVE.md.
# Do NOT bake a golden here until the pointer transport is raced and proven.
###############################################################################
set -euo pipefail

OS_ID="sculpt"
URL="https://genode.org/files/sculpt/sculpt-25-04.img"
SHA256="54e8bd5f3b7c5ebf0fac84aa2c103d8bb8efa62ef6bcb5a08f2cad42cc29c366"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
OUT="${OUT:-/data/gallery-guests/Sculpt}"
IMG="$WORK/sculpt-25-04.img"
DISK="$OUT/sculpt.qcow2"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$WORK" "$OUT"

if [ ! -f "$IMG" ]; then
  log "fetching $URL"
  curl -fsSL -o "$IMG.part" "$URL" || die "download failed"
  mv "$IMG.part" "$IMG"
fi

log "verifying publisher sha256"
have="$(sha256sum "$IMG" | awk '{print $1}')"
[ "$have" = "$SHA256" ] || die "sha256 mismatch: got $have want $SHA256"

log "composing writable station disk $DISK (4 GiB)"
qemu-img convert -f raw -O qcow2 "$IMG" "$DISK.tmp"
qemu-img resize -q "$DISK.tmp" 4G
mv "$DISK.tmp" "$DISK"

log "done: $DISK"
log "framebuffer-verify: boot with streamhost/stations/sculpt/qemu-streamhost.sh"
log "                    (SCULPT_NO_GOLDEN=1) and screendump the Leitzentrale."
