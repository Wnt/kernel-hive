#!/usr/bin/env bash
# Build the pristine OpenVMS x86-64 Community disk lineage.
#
# The Community Package is pre-installed: this builder verifies and preserves
# the raw zip, extracts its descriptor + flat VMDK pair, converts the descriptor
# to qcow2, and creates a snapshot-capable pristine OVMF varstore. Golden login
# and framebuffer curation are deliberately a separate clone-only stage.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OS_ID="openvms"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/OpenVMS}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
SOURCE_ZIP="${SOURCE_ZIP:-$GUEST_DIR/community_2026.zip}"
SOURCE_URL="${SOURCE_URL:-https://events.vmssoftware.com/hubfs/VMS%20-%20Files/community_2026.zip}"
SOURCE_SHA256="ceae51ded68e96861e7211b30ef837e8d101eb5d3a3ddb78c13d5d7619ddfb83"
VMDK_NAME="X86_V923-comm-2026.vmdk"
FLAT_NAME="X86_V923-comm-2026-flat.vmdk"
OUT_DISK="$GUEST_DIR/openvms-community.qcow2"
OUT_VARS="$GUEST_DIR/OVMF_VARS.qcow2"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd}"
BROWSER_UA="${BROWSER_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/126 Safari/537.36}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --source-zip=*) SOURCE_ZIP="${arg#*=}" ;;
    --source-url=*) SOURCE_URL="${arg#*=}" ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
hash_of() { sha256sum "$1" | awk '{print $1}'; }
build_decwindows_bridge() {
  local args=()
  [ "$FORCE" -eq 0 ] || args+=(--force)
  [ -x "$HERE/../stages/openvms-decwindows-bridge.sh" ] ||
    die "DECwindows bridge builder missing: $HERE/openvms-decwindows-bridge.sh"
  "$HERE/../stages/openvms-decwindows-bridge.sh" "${args[@]}"
}

command -v curl >/dev/null || die "curl not found"
command -v unzip >/dev/null || die "unzip not found"
command -v qemu-img >/dev/null || die "qemu-img not found"
mkdir -p "$GUEST_DIR" "$WORK/extracted"

if [ ! -s "$SOURCE_ZIP" ]; then
  part="$SOURCE_ZIP.part.$$"
  log "staged archive absent; downloading with a browser user-agent"
  curl -fL --retry 3 --retry-delay 2 -A "$BROWSER_UA" -o "$part" "$SOURCE_URL" ||
    die "download failed"
  [ "$(hash_of "$part")" = "$SOURCE_SHA256" ] || {
    rm -f "$part"
    die "downloaded archive SHA-256 mismatch"
  }
  mv "$part" "$SOURCE_ZIP"
fi

[ "$(hash_of "$SOURCE_ZIP")" = "$SOURCE_SHA256" ] ||
  die "archive SHA-256 mismatch: $SOURCE_ZIP"
log "archive SHA-256 verified; raw zip remains at $SOURCE_ZIP"

if [ "$FORCE" -eq 0 ] && [ -s "$OUT_DISK" ] && [ -s "$OUT_VARS" ]; then
  qemu-img check -q "$OUT_DISK" || die "existing qcow2 failed qemu-img check"
  qemu-img check -q "$OUT_VARS" || die "existing varstore failed qemu-img check"
  build_decwindows_bridge
  log "outputs already present and valid; pass --force to rebuild"
  exit 0
fi

unzip -t "$SOURCE_ZIP" >/dev/null || die "zip integrity test failed"
unzip -o "$SOURCE_ZIP" "$VMDK_NAME" "$FLAT_NAME" -d "$WORK/extracted" >/dev/null ||
  die "VMDK extraction failed"
VMDK="$WORK/extracted/$VMDK_NAME"
FLAT="$WORK/extracted/$FLAT_NAME"
[ -s "$VMDK" ] && [ -s "$FLAT" ] || die "expected VMDK pair missing after extraction"
[ -s "$OVMF_VARS_TEMPLATE" ] || die "OVMF vars template missing: $OVMF_VARS_TEMPLATE"

disk_tmp="$GUEST_DIR/.openvms-community.qcow2.tmp.$$"
vars_tmp="$GUEST_DIR/.OVMF_VARS.qcow2.tmp.$$"
trap 'rm -f "$disk_tmp" "$vars_tmp"' EXIT

log "converting pre-installed VMDK descriptor + flat extent to qcow2"
qemu-img convert -p -f vmdk -O qcow2 "$VMDK" "$disk_tmp" ||
  die "system disk conversion failed"
qemu-img check -q "$disk_tmp" || die "converted system disk failed qemu-img check"

log "creating snapshot-capable pristine OVMF varstore"
qemu-img convert -f raw -O qcow2 "$OVMF_VARS_TEMPLATE" "$vars_tmp" ||
  die "OVMF varstore conversion failed"
qemu-img check -q "$vars_tmp" || die "converted varstore failed qemu-img check"

mv -f "$disk_tmp" "$OUT_DISK"
mv -f "$vars_tmp" "$OUT_VARS"
trap - EXIT

log "done: $OUT_DISK"
log "done: $OUT_VARS"
build_decwindows_bridge
log "next: copy both to a namespaced clone, boot the pinned device set, and bake golden"
