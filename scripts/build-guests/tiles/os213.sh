#!/bin/bash
# Builder for os213 — IBM OS/2 1.30.2 Standard Edition with Presentation Manager.
#
# Fetches and verifies the pinned install media, then stops. The OS/2 1.3
# installer is an interactive 10-floppy sequence with no unattended answer file,
# so the disk is composed once by an agent driving the installer over QMP
# (`blockdev-change-medium` per disk + scripts/dev/fb-wait.py between prompts) —
# see docs/guests/os213.md §Install recipe and docs/lab/OS213-WAVE.md. This
# script exists so the media provenance is reproducible and the hashes are
# checked before anyone spends an hour on an install.
#
# NEVER commit the media bits. Only the URL and the sha256 live here.
set -euo pipefail

OS_ID="os213"
STAGING="${STAGING:-/data/assets-staging/$OS_ID}"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# --- pinned media -------------------------------------------------------------
# IBM OS/2 1.30.2 Standard Edition, 10 x 1.44 MB floppy images, 7z archive.
# archive.org item: https://archive.org/details/OS2_1x_collection
# (mirrored from WinWorld; abandonware/preservation class — see
#  /data/assets-staging/os213/SOURCES.md for the full licence posture.)
IBM_SE_URL="https://archive.org/download/OS2_1x_collection/IBM%20OS2%201.30.2%20Standard%20Edition%20%283.5-1.44mb%29.7z"
IBM_SE_FILE="IBM_OS2_1.30.2_Standard_Edition_144mb.7z"
IBM_SE_SHA256="f43c3dacbb1f4ab81906a25b5d7ca35ef302826640ee7b5116a75a893f8e48a6"
IBM_SE_BYTES="8293261"

# Per-floppy sha256 of the extracted set. These are what the install actually
# consumes, and the ones to re-check before a rebake.
read -r -d '' FLOPPY_SHA256 <<'SUMS' || true
b2f74e9503b9e238b89e7dd458ca0b38a2a938972604f0fd4b878b5bcb35e88c  Install.img
bb0c89ae528d1ee02d2a40dccae15de023c674b9553015485bbf793ed4fc9bc0  Disk01.img
097381d4be2f37f5a2e3e0154e599ed321bf6b5ab9b124996730c9c9556e005e  Disk02.img
540d948a696c114035e105fbe4f37005a77195414c0b9d6406cc8f5f13b6ea2e  Disk03.img
cba74d454cd9e6bdcdc7b487cf363cd8b5dd2c6b66f59e69a088a7ae496ec04c  Disk04.img
65ab0e8b5ca8b0034201e51950f8166e2b75bb21156056aea87fe5ef305ec406  Disk05.img
55b31f38030ce8d5c596958026fa6ed52b704ccb0110dca0d6ec775d468b4b43  Driver1.img
6312459c574ae1140edb1c8f9be1a9480b8abe49b84aa24c270f5b7e58e4c762  Driver2.img
8b5566c40c307597effe130e13ce2e0462e4701d6c264f94256f3aeddb727f76  Driver3.img
3c8454ba8c2ec0fb14a916aa9719219213c8d89341d56af4882f990249502f3f  Driver4.img
SUMS

# The Microsoft OS/2 1.30.1 Server preinstalled VMDK is deliberately NOT used.
# It boots, prints its banner, then TRAPs (a truncated `TRA` and a dead
# framebuffer) on every device set raced on 2026-09-13 — isapc and i440fx, 8 and
# 16 MB, with and without -icount. Kept in SOURCES.md as a documented dead end.

mkdir -p "$STAGING"
cd "$STAGING"

if [ ! -f "$IBM_SE_FILE" ]; then
  log "fetching $IBM_SE_FILE"
  curl -fSL --retry 3 -o "$IBM_SE_FILE.part" "$IBM_SE_URL"
  mv "$IBM_SE_FILE.part" "$IBM_SE_FILE"
fi

got_bytes="$(stat -c %s "$IBM_SE_FILE")"
[ "$got_bytes" = "$IBM_SE_BYTES" ] || die "$IBM_SE_FILE is $got_bytes bytes, expected $IBM_SE_BYTES"
echo "$IBM_SE_SHA256  $IBM_SE_FILE" | sha256sum -c - || die "$IBM_SE_FILE failed its sha256"
log "media verified: $IBM_SE_FILE ($got_bytes bytes)"

mkdir -p ibm-1.30.2-se-floppies
if [ ! -f "ibm-1.30.2-se-floppies/Install.img" ]; then
  command -v 7z >/dev/null || die "7z not found (labhost: apt install p7zip-full)"
  7z x -y -o"ibm-1.30.2-se-floppies" "$IBM_SE_FILE" >/dev/null
fi

cd ibm-1.30.2-se-floppies
printf '%s\n' "$FLOPPY_SHA256" | sha256sum -c - || die "a floppy image failed its sha256"
log "all 10 floppy images verified"

log "media is staged and verified at $STAGING"
log "the install itself is interactive: see docs/guests/os213.md §Install recipe"
