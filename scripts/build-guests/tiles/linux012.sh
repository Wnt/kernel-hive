#!/bin/bash
# Builder for linux012 — Linux 0.12 (Jan 1992), two-floppy boot.
#
# Fetches the 2004 oldlinux.org repackaged raw floppy images (the SAME bytes
# named in docs/lab/integration-seeds/linux012.md), verifies their hash, and
# stages immutable copies under assets/linux012/.
#
# MEASURED 2026-09-20: the upstream directory the seed doc named
# (Linux-0.12/images/) only carries the .Z-compressed originals; the raw
# "-20040306" repackaged images the seed asked for live one level up, under
# Linux.old/images/ (not Linux.old/Linux-0.12/images/). Both were fetched and
# hashed during bring-up; the -20040306 pair is the one the runtime uses.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OS_ID="linux012"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/${OS_ID}}"
BASE_URL="${BASE_URL:-https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images}"
BOOT_NAME="${BOOT_NAME:-bootimage-0.12-20040306}"
ROOT_NAME="${ROOT_NAME:-rootimage-0.12-20040306}"
BOOT_SHA256="${BOOT_SHA256:-1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425}"
ROOT_SHA256="${ROOT_SHA256:-4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$WORK" "$ASSETS"

for pair in "$BOOT_NAME:$BOOT_SHA256" "$ROOT_NAME:$ROOT_SHA256"; do
  name="${pair%%:*}"
  want_sha="${pair##*:}"
  dest="$WORK/$name"
  if [ ! -f "$dest" ]; then
    log "fetching $name"
    curl -fL --retry 3 -o "$dest" "$BASE_URL/$name" ||
      die "could not fetch $name from $BASE_URL — check the mirror layout (seed doc's Linux-0.12/images/ path 404s; images/ at the Linux.old root is correct as of 2026-09-20)"
  fi
  got_sha="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$got_sha" = "$want_sha" ] ||
    die "$name sha256 mismatch: got $got_sha want $want_sha"
done

# The boot floppy image as shipped (150016 bytes / 293 sectors) is shorter
# than a standard 1.44M floppy. MEASURED: QEMU's floppy geometry probe/track
# wrap over a short raw image leaves the classic Linux 0.12 boot chain in an
# indeterminate state after the "Loading........." stage (a BIOS SVGA-mode
# prompt is on screen waiting for a keypress the headless boot never sends).
# Zero-padding to the full 1.44M floppy size (2880*512) does not change the
# bytes the guest reads, only what a short-file EOF read returns, and it is
# what let the SVGA-mode prompt respond to injected keys in this wave's rig.
# Kept as a build step (not hand-patched) so it reproduces from the pinned
# source bytes every time.
BOOT_RAW="$WORK/$BOOT_NAME"
BOOT_PADDED="$WORK/boot-padded.img"
cp -f "$BOOT_RAW" "$BOOT_PADDED"
truncate -s 1474560 "$BOOT_PADDED"

cp -f "$BOOT_PADDED" "$ASSETS/boot.img"
cp -f "$WORK/$ROOT_NAME" "$ASSETS/root.img"
sha256sum "$ASSETS/boot.img" "$ASSETS/root.img" | tee "$ASSETS/MANIFEST.sha256"

cat >&2 <<'EOF'
SMOKE (proven manually in this wave's sandbox, NOT yet automated here):
 qemu-system-i386 -m 8 \
   -drive file=boot.img,format=raw,if=floppy,index=0,readonly=on \
   -drive file=root.img,format=raw,if=floppy,index=1,readonly=on \
   -boot a -display none -vga std -qmp unix:qmp.sock,server=on,wait=off

STATUS 2026-09-20 (see docs/lab/LINUX012-WAVE.md): boot reaches
"Press <RETURN> to see SVGA-modes available or any other key to continue."
then, after a keypress, "Insert root floppy and press ENTER". The CPU keeps
executing past that point (EIP moves, real work happening) but the visible
framebuffer scene has NOT been proven to reach a root shell yet in this
wave. Root cause under active investigation: injected QMP send-key events do
not reliably clear the classic Linux 0.12 keyboard-flush loop (IN AL,0x60 /
CMP AL,0x82) on the first try; multiple distinct keys have been needed.
EOF
