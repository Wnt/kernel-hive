#!/bin/bash
# Tier 1 builder for minix2 — Minix 2.0.4 (Tanenbaum), QEMU text console.
#
# Produces: $OUT/minix2.qcow2 — a pristine, pre-installed Minix 2.0.4 root disk.
# NO checkpoint is baked here; the golden `savevm golden` is taken by the wave
# lead on the station's own launcher device set (AGENTS.md rule 6).
#
# PROVENANCE. Minix 2.0.4 ships as an install floppy set, not as a disk image,
# and installing it from ROOT.MNX/USR.MNX under QEMU hits an unresolved floppy
# wall (see docs/lab/MINIX2-WAVE.md §Walls). The museum therefore ships Al
# Woodhull's own pre-installed image from the official 2.0.4 distribution site;
# the pristine install set is fetched too, and this script ASSERTS that the
# Bochs package's root.img/usr.img are byte-identical to the official
# ROOT.MNX/USR.MNX. That assertion is the whole provenance argument: if it ever
# fails, the pre-installed image is no longer the official distribution.
#
# ROMs/media bits are NEVER committed — only these URLs and hashes.
set -euo pipefail

OS_ID="minix2"
OUT="${OUT:-/data/gallery-guests/Minix2}"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
DL="$WORK/dl"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

BOCHS_URL="https://minix1.woodhull.com/pub/demos-2.0/BochsImage/mx204bx01.zip"
BOCHS_SHA="a658d057856676455f1b231943a2c9f198ddca61b0667f5e3395259ac376099a"
BOCHS_SIZE=7179269

# official 2.0.4 install set — primary origin, with the minix3.org archive as a
# second origin that carries the publisher's own md5list.
OFFICIAL_BASE="https://minix1.woodhull.com/current/2.0.4"
OFFICIAL_BASE_ALT="http://download.minix3.org/previous-versions/Intel-2.0.4"
ROOT_SHA="f7fcafb3c32d95b136fb43302605eb95e4231e5daa73244fac456ab013cbe9c8"
USR_SHA="c5a9b0e8cd6afe8322bf14d2a00dea193668dfb0b329d057f5b97ecb7f7ea465"
IMG_SHA="012dc3b9d1b0ee28760c0b9f5f62e7e1dda9e117a922d6eb81d38e5dc5a9c79e"
IMG_SIZE=52428800 # 50 MiB flat raw, CHS 200/16/32 baked into its partition table

fetch() { # url dest sha256
  local url="$1" dest="$2" want="$3"
  if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$want" ]; then
    log "have $(basename "$dest")"
    return 0
  fi
  log "fetch $url"
  curl -fsSL --retry 3 -m 900 -o "$dest.part" "$url" || return 1
  local got
  got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || {
    rm -f "$dest.part"
    die "sha256 mismatch for $url: got $got want $want"
  }
  mv "$dest.part" "$dest"
}

mkdir -p "$DL" "$OUT"

# 1. pre-installed image
fetch "$BOCHS_URL" "$DL/mx204bx01.zip" "$BOCHS_SHA" || die "cannot fetch $BOCHS_URL"
[ "$(stat -c %s "$DL/mx204bx01.zip")" = "$BOCHS_SIZE" ] || die "mx204bx01.zip size changed"
rm -rf "$WORK/x"
mkdir -p "$WORK/x"
unzip -q -o "$DL/mx204bx01.zip" -d "$WORK/x"
IMG="$(find "$WORK/x" -name minix.img -print -quit)"
[ -n "$IMG" ] || die "minix.img not found in mx204bx01.zip"
[ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$IMG_SHA" ] || die "minix.img sha256 changed"
[ "$(stat -c %s "$IMG")" = "$IMG_SIZE" ] || die "minix.img is not $IMG_SIZE bytes"

# 2. official install set — fetched for provenance, and to assert the identity below
for pair in "i386/ROOT.MNX:$ROOT_SHA" "i386/USR.MNX:$USR_SHA"; do
  rel="${pair%%:*}"
  sha="${pair##*:}"
  mkdir -p "$DL/$(dirname "$rel")"
  fetch "$OFFICIAL_BASE/$rel" "$DL/$rel" "$sha" ||
    fetch "$OFFICIAL_BASE_ALT/$rel" "$DL/$rel" "$sha" ||
    die "cannot fetch $rel from either origin"
done

# 3. THE provenance assertion
PKG_ROOT="$(find "$WORK/x" -name root.img -print -quit)"
PKG_USR="$(find "$WORK/x" -name usr.img -print -quit)"
[ -n "$PKG_ROOT" ] && [ -n "$PKG_USR" ] || die "root.img/usr.img missing from the Bochs package"
cmp -s "$PKG_ROOT" "$DL/i386/ROOT.MNX" || die "package root.img differs from official ROOT.MNX — provenance broken"
cmp -s "$PKG_USR" "$DL/i386/USR.MNX" || die "package usr.img differs from official USR.MNX — provenance broken"
log "provenance OK: package floppies are byte-identical to the official 2.0.4 set"

# 4. convert to the station disk
qemu-img convert -f raw -O qcow2 "$IMG" "$OUT/minix2.qcow2.tmp"
mv "$OUT/minix2.qcow2.tmp" "$OUT/minix2.qcow2"
log "wrote $OUT/minix2.qcow2 ($(stat -c %s "$OUT/minix2.qcow2") bytes on disk, 50 MiB virtual)"

# 5. framebuffer boot verification — the ONLY proof that the disk boots.
#    Cold boot stops at the Minix boot monitor 2.19 menu, which waits for a key;
#    '=' starts Minix. Geometry MUST be the image's own CHS or at_wini reads garbage.
if [ "${SKIP_VERIFY:-0}" = "1" ]; then
  log "SKIP_VERIFY=1 — not booting"
  exit 0
fi
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
V="$WORK/verify"
rm -rf "$V"
mkdir -p "$V"
cp "$OUT/minix2.qcow2" "$V/disk.qcow2"
setsid qemu-system-x86_64 \
  -name "build-minix2-verify" \
  -enable-kvm -m 32 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off -cpu host \
  -rtc base=localtime -vga std -display none -boot c \
  -drive file="$V/disk.qcow2",format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,unit=0,cyls=200,heads=16,secs=32 \
  -qmp unix:"$V/qmp.sock",server=on,wait=off \
  -pidfile "$V/qemu.pid" >"$V/qemu.log" 2>&1 &
disown || true
for _ in $(seq 1 40); do
  [ -S "$V/qmp.sock" ] && break
  sleep 0.5
done
[ -S "$V/qmp.sock" ] || die "verify VM did not open its QMP socket"
trap 'kill "$(cat "$V/qemu.pid" 2>/dev/null)" 2>/dev/null || true' EXIT
python3 "$REPO/scripts/dev/fb-wait.py" --qmp "$V/qmp.sock" --settle 3 --timeout 90 --out "$V/monitor.png" >&2
python3 "$REPO/scripts/dev/qmp-type.py" --qmp "$V/qmp.sock" --keys equal >/dev/null
python3 "$REPO/scripts/dev/fb-wait.py" --qmp "$V/qmp.sock" --settle 8 --timeout 180 --out "$V/login.png" >&2
log "framebuffer verification frames: $V/monitor.png (boot monitor) $V/login.png (login prompt)"
log "done"
