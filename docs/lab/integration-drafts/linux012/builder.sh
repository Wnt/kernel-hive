#!/bin/bash
# DRAFT ONLY: fetch/stage the historical Linux 0.12 two-floppy image set.
set -euo pipefail
WORK="${WORK:-/data/vms/build-linux012}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/linux012}"
BASE_URL="${BASE_URL:-https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/Linux-0.12/images}"
BOOT_NAME="${BOOT_NAME:-bootimage-0.12-20040306}"
ROOT_NAME="${ROOT_NAME:-rootimage-0.12-20040306}"
mkdir -p "$WORK" "$ASSETS"
for n in "$BOOT_NAME" "$ROOT_NAME"; do
  if ! curl -fL --retry 3 -o "$WORK/$n" "$BASE_URL/$n"; then
    echo "direct file $n not found; select the equivalent raw/.Z image from $BASE_URL and set BOOT_NAME/ROOT_NAME" >&2
    exit 2
  fi
done
cp -f "$WORK/$BOOT_NAME" "$ASSETS/boot.img"
cp -f "$WORK/$ROOT_NAME" "$ASSETS/root.img"
sha256sum "$ASSETS/boot.img" "$ASSETS/root.img" | tee "$ASSETS/MANIFEST.sha256"
cat >&2 <<'EOF'
SMOKE:
 qemu-system-i386 -accel tcg -m 4M    -drive file=boot.img,format=raw,if=floppy,index=0    -drive file=root.img,format=raw,if=floppy,index=1 -boot a
EOF
