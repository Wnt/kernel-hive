#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/pcbsd.sh — fetch + stage PC-BSD 1.5.1 "Da Vinci" media
# for the neko+QEMU Kernel Hive station `pcbsd`.
#
# WHAT PC-BSD IS: FreeBSD 6.3-RELEASE + KDE 3.5.8, i386, released March 2008 —
# the last PC-BSD release before iXsystems' 7.x line. Licence BSD (base) / GPL
# (KDE components). Installer is PC-BSD's own graphical Qt wizard (PBI-based),
# NOT a text installer — there is no scripted/unattended path for 1.5.1.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED (archive.org pinned item + sha256).
#   (2) DISK CREATE .... FULLY AUTOMATED — fresh empty qcow2.
#   (3) INSTALL ........ MANUAL — graphical Qt wizard, no unattended path.
#       This script does NOT drive the installer. It prints the exact QEMU
#       command + wizard answers for a human (or a `golden`-stream agent
#       driving QMP by hand) to run.
#   (4) INPUT AUTOMATION NONE (by design — see above).
#   (5) FINAL IMAGE .... pcbsd.iso (pinned CD1) + pcbsd.qcow2 (empty until
#                         installed) in <GUEST_DIR>.
#   (6) VERIFY ......... sha256 of the fetched/staged ISO only. No boot proof
#                         here — that is the `golden` stream's job.
#   => automation: assisted.
#
# IDEMPOTENT / RE-RUNNABLE: skips the download if a valid, hash-matching ISO
# already exists at GUEST_DIR (override with --force). Prefers copying from
# the pre-staged /data/assets-staging/pcbsd/ (already hash-verified there)
# over re-fetching from archive.org.
#
# Usage:
#   build-guests/tiles/pcbsd.sh [--dir DIR] [--force] [-h]
#     --dir DIR   output/guest dir (default /data/gallery-guests/PCBSD)
#     --force     re-fetch/re-stage even if a valid pcbsd.iso is present
#     -h|--help   show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/PCBSD"
ISO_NAME="pcbsd.iso"
QCOW2_NAME="pcbsd.qcow2"
QCOW2_SIZE="8G"

# archive.org item pcbsd-1.5.1-x-86-cd-1, file PCBSD1.5.1-x86-CD1.iso — CD1
# alone installs the base system + KDE (CD2 was optional PBIs, not needed).
SRC_URL="https://archive.org/download/pcbsd-1.5.1-x-86-cd-1/PCBSD1.5.1-x86-CD1.iso"
ISO_SIZE_BYTES=688930816
ISO_SHA256="69aa17171e0afe45735c3bb16a398319fa82b3f30a3e1aa3a5d6f25ac4bee0a3"

# Pre-staged copy (already hash-verified once) — preferred source to avoid
# re-fetching 656 MiB from archive.org on every rebuild.
STAGED_ISO="/data/assets-staging/pcbsd/PCBSD1.5.1-x86-CD1.iso"
STAGED_MANIFEST="/data/assets-staging/pcbsd/MANIFEST.sha256"

FORCE="${FORCE:-0}"

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      GUEST_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
QCOW2_PATH="${GUEST_DIR}/${QCOW2_NAME}"

log() { printf '\033[1;36m[pcbsd]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[pcbsd] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

iso_valid() {
  [ -s "$1" ] || return 1
  [ "$(stat -c%s "$1" 2>/dev/null || stat -f%z "$1")" = "$ISO_SIZE_BYTES" ] || return 1
  [ "$(sha256_of "$1")" = "$ISO_SHA256" ]
}

mkdir -p "$GUEST_DIR"

# =============================================================================
# (1) STAGE the ISO — prefer the pre-staged, already-verified copy; else fetch.
# =============================================================================
if [ "$FORCE" = 0 ] && iso_valid "$ISO_PATH"; then
  log "valid pcbsd.iso already present -> $ISO_PATH (sha256 matches pin); skipping (use --force to redo)."
elif [ "$FORCE" = 0 ] && [ -f "$STAGED_ISO" ] && iso_valid "$STAGED_ISO"; then
  log "copying pre-staged, hash-verified ISO from $STAGED_ISO"
  install -m 0644 "$STAGED_ISO" "$ISO_PATH"
  iso_valid "$ISO_PATH" || die "copied ISO failed sha256 verification"
  log "staged -> $ISO_PATH"
else
  log "fetching PC-BSD 1.5.1 CD1 from archive.org:"
  log "  $SRC_URL"
  curl -fSL --retry 3 --retry-delay 3 -o "${ISO_PATH}.part" "$SRC_URL" ||
    die "download failed from $SRC_URL"
  mv "${ISO_PATH}.part" "$ISO_PATH"
  iso_valid "$ISO_PATH" || die "downloaded ISO failed sha256/size verification (expected $ISO_SIZE_BYTES bytes, sha256 $ISO_SHA256)"
  log "fetched + verified -> $ISO_PATH"
fi

if [ -f "$STAGED_MANIFEST" ]; then
  staged_hash="$(awk '{print $1}' "$STAGED_MANIFEST" | head -n1)"
  [ "$staged_hash" = "$ISO_SHA256" ] || log "WARNING: $STAGED_MANIFEST hash does not match the pin baked into this script — re-check the ledger."
fi

# =============================================================================
# (2) CREATE the empty install-target qcow2 (idempotent — never overwrites an
# already-installed disk; installation itself is the manual/assisted step).
# =============================================================================
if [ "$FORCE" = 0 ] && [ -s "$QCOW2_PATH" ]; then
  log "pcbsd.qcow2 already present -> $QCOW2_PATH; leaving it alone (use --force to recreate — DESTROYS any installed state)."
else
  command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found (needed to create $QCOW2_PATH)"
  log "creating empty ${QCOW2_SIZE} qcow2 -> $QCOW2_PATH"
  qemu-img create -f qcow2 "$QCOW2_PATH" "$QCOW2_SIZE" || die "qemu-img create failed"
fi

# =============================================================================
# (3) INSTALL is MANUAL — print the exact command + wizard answers.
# =============================================================================
cat <<EOF

============================================================================
PC-BSD 1.5.1 media staged.
  ISO (CD1, pinned)  : ${ISO_PATH}
  Install-target disk: ${QCOW2_PATH} (empty ${QCOW2_SIZE} qcow2)

This is an ASSISTED build: PC-BSD 1.5.1's installer is a graphical Qt wizard
with no unattended/scripted path. Run the installer BY HAND (or drive it via
QMP from the \`golden\` stream) with:

  qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host -m 1024 \\
    -smp 1 -vga std \\
    -drive if=ide,index=0,file=${QCOW2_PATH},format=qcow2 \\
    -drive if=ide,index=2,media=cdrom,file=${ISO_PATH} \\
    -usb -device usb-tablet \\
    -boot d

Wizard answers:
  - Language / keyboard : English / us
  - root password        : kernelhive
  - user account          : visitor / kernelhive
  - disk selection         : whole disk, ad0
  - components             : default (KDE 3.5.8 desktop)

After install completes and the installer reboots, remove -boot d / the
-cdrom line (or just \`-boot c\`) so the station boots off ${QCOW2_PATH}
directly — that is the runtime device set for station \`pcbsd\`.
============================================================================
EOF
