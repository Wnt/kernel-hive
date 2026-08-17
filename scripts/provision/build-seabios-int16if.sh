#!/bin/bash
# build-seabios-int16if.sh — build the patched SeaBIOS ROM that the win311
# station boots with, from source, and install it on labhost.
#
#   RUN ON labhost (gcc + make + python3 + git; ~1 min).
#   Output: /data/vms/streamhost/firmware/bios-256k-int16if.bin (+ .sha256,
#           .provenance.txt), consumed by the win311 launcher's `-bios`.
#
# WHY: stock SeaBIOS returns from INT 16h "check keystroke" (AH=01h/11h) via
# iretw with the IF the caller pushed. The IBM AT BIOS does STI + RET 2 there,
# so real hardware always hands IF=1 back. MS-DOS 6 POWER.EXE (loaded by the
# rtts WfW 3.11 base for CPU idling) chains INT 16h with `pushf; call far`
# while IF is clear and returns to ITS caller with RETF 2 — so under SeaBIOS
# the caller gets IF=0. WfW 3.11's keyboard driver polls INT 16h/AH=01 through
# the VMM on key edges and the VMM copies the returned flags back into the
# protected-mode System VM: the guest keeps running with interrupts disabled,
# and an app that never yields (SkiFree's PeekMessage loop) never lets anything
# re-enable them. Root-cause write-up and repro:
# docs/lab/win311-interrupts-disabled-freeze.md.
#
# The patch is streamhost/qemu-patches/seabios/0001-*.patch. The SeaBIOS
# release is pinned to the one pve-qemu-kvm ships prebuilt (rel-1.17.0), so
# the only delta against /usr/share/kvm/bios-256k.bin is that patch. Build
# config = QEMU's roms/config.seabios-256k.
#
# The ROM contents are part of the vmstate ("pc.bios" RAM block): a station
# whose golden was baked on the stock ROM keeps RUNNING the stock ROM after
# `loadvm golden`, whatever `-bios` says. Re-bake from a COLD boot after
# switching (docs/lab/win311-interrupts-disabled-freeze.md § Fix).
set -euo pipefail

SEABIOS_REPO="${SEABIOS_REPO:-https://github.com/coreboot/seabios.git}"
SEABIOS_REF="${SEABIOS_REF:-rel-1.17.0}"
SEABIOS_COMMIT="${SEABIOS_COMMIT:-b52ca86e094d19b58e2304417787e96b940e39c6}"
WORK="${WORK:-/data/vms/soltest/BUILD-seabios-int16if.$$}"
DEST_DIR="${DEST_DIR:-/data/vms/streamhost/firmware}"
DEST_NAME="${DEST_NAME:-bios-256k-int16if.bin}"
JOBS="${JOBS:-$(nproc)}"
NICE_LEVEL="${NICE_LEVEL:-15}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${PATCH_DIR:-$HERE/../../streamhost/qemu-patches/seabios}"

log() { printf '[build-seabios-int16if] %s\n' "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

for t in git make gcc python3 sha256sum; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done
[ -d "$PATCH_DIR" ] || die "patch dir not found: $PATCH_DIR (run from a repo checkout)"
mapfile -t PATCHES < <(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' | sort)
[ "${#PATCHES[@]}" -gt 0 ] || die "no patches in $PATCH_DIR"

mkdir -p "$WORK"
log "work dir $WORK"
if [ ! -d "$WORK/seabios/.git" ]; then
  log "cloning $SEABIOS_REPO @ $SEABIOS_REF"
  git clone -q --branch "$SEABIOS_REF" --depth 1 "$SEABIOS_REPO" "$WORK/seabios"
fi
cd "$WORK/seabios"
HEAD_COMMIT="$(git rev-parse HEAD)"
[ "$HEAD_COMMIT" = "$SEABIOS_COMMIT" ] ||
  die "SeaBIOS $SEABIOS_REF resolved to $HEAD_COMMIT, expected $SEABIOS_COMMIT (pin drift — check pve's prebuilt rel first)"
git config user.email "build@example.com"
git config user.name "kernel-hive build"
for p in "${PATCHES[@]}"; do
  log "applying $(basename "$p")"
  git am -q "$p" || die "git am failed for $p (see $WORK/seabios/.git/rebase-apply)"
done
grep -q 'regs->flags |= F_IF' src/kbd.c || die "patch did not land in src/kbd.c"

# QEMU's roms/config.seabios-256k, verbatim.
printf 'CONFIG_QEMU=y\nCONFIG_ROM_SIZE=256\nCONFIG_ATA_DMA=n\n' >.config
make olddefconfig PYTHON=python3 >/dev/null 2>&1 || make oldnoconfig PYTHON=python3 >/dev/null
log "building (nice $NICE_LEVEL, -j$JOBS)"
nice -n "$NICE_LEVEL" make -j"$JOBS" PYTHON=python3 >"$WORK/build.log" 2>&1 ||
  die "build failed — see $WORK/build.log"
[ -s out/bios.bin ] || die "out/bios.bin missing"
SIZE="$(stat -c %s out/bios.bin)"
[ "$SIZE" -eq 262144 ] || die "unexpected ROM size $SIZE (want 262144)"
VERSION_STR="$(strings out/bios.bin | grep -m1 -E '^rel-' || true)"

mkdir -p "$DEST_DIR"
install -m 0644 out/bios.bin "$DEST_DIR/$DEST_NAME.tmp"
mv -f "$DEST_DIR/$DEST_NAME.tmp" "$DEST_DIR/$DEST_NAME"
(cd "$DEST_DIR" && sha256sum "$DEST_NAME" >"$DEST_NAME.sha256")
{
  echo "built:      $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname)"
  echo "seabios:    $SEABIOS_REPO $SEABIOS_REF ($HEAD_COMMIT)"
  echo "version:    ${VERSION_STR:-unknown}"
  echo "config:     CONFIG_QEMU=y CONFIG_ROM_SIZE=256 CONFIG_ATA_DMA=n (qemu roms/config.seabios-256k)"
  for p in "${PATCHES[@]}"; do echo "patch:      $(basename "$p") sha256=$(sha256sum "$p" | cut -d' ' -f1)"; done
  echo "why:        docs/lab/win311-interrupts-disabled-freeze.md"
} >"$DEST_DIR/$DEST_NAME.provenance.txt"
log "installed $DEST_DIR/$DEST_NAME ($SIZE bytes, ${VERSION_STR:-?})"
cat "$DEST_DIR/$DEST_NAME.sha256" >&2
log "build tree left at $WORK (rm -rf it when done)"
