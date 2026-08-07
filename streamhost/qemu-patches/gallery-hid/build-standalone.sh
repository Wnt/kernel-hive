#!/bin/bash
# Apply gallery-hid to an already assembled/configured pinned QEMU source tree
# and build only the standalone system binary plus its qtest.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 QEMU_SOURCE OUTPUT_DIR" >&2
  exit 2
fi

SOURCE="$(readlink -f "$1")"
OUTPUT="$(readlink -m "$2")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$SOURCE/build/build.ninja" ] || {
  echo "configured QEMU build directory missing: $SOURCE/build" >&2
  exit 1
}
mkdir -p "$OUTPUT"
install -D -m 0644 "$HERE/gallery-hid-proto.h" \
  "$SOURCE/include/hw/misc/gallery-hid.h"
install -D -m 0644 "$HERE/gallery-hid-pci.c" \
  "$SOURCE/hw/misc/gallery-hid-pci.c"
install -D -m 0644 "$HERE/tests/gallery-hid-test.c" \
  "$SOURCE/tests/qtest/gallery-hid-test.c"

if ! grep -q '^config GALLERY_HID$' "$SOURCE/hw/misc/Kconfig"; then
  git -C "$SOURCE" apply --unidiff-zero "$HERE/qemu-wiring.patch"
fi

ionice -c2 -n7 nice -n15 ninja -C "$SOURCE/build" \
  qemu-system-x86_64 tests/qtest/gallery-hid-test
install -m 0755 "$SOURCE/build/qemu-system-x86_64" \
  "$OUTPUT/qemu-system-x86_64"
install -m 0755 "$SOURCE/build/tests/qtest/gallery-hid-test" \
  "$OUTPUT/gallery-hid-test"
mkdir -p "$OUTPUT/pc-bios"
cp -a "$SOURCE/pc-bios/." "$OUTPUT/pc-bios/"

sha256sum "$OUTPUT/qemu-system-x86_64" "$OUTPUT/gallery-hid-test" \
  >"$OUTPUT/SHA256SUMS"
printf 'qemu_source=%s\n' "$SOURCE" >"$OUTPUT/build-metadata.txt"
printf 'qemu_commit=%s\n' "$(git -C "$SOURCE/../qemu" rev-parse HEAD 2>/dev/null || true)" \
  >>"$OUTPUT/build-metadata.txt"
printf 'built_utc=%s\n' "$(date -u +%FT%TZ)" >>"$OUTPUT/build-metadata.txt"
