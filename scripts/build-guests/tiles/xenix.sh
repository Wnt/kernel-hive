#!/bin/bash
# Tier 1 builder scaffold for xenix — replace every TODO before promotion.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
OS_ID="xenix"
TILE_DIR="xenix"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
# shellcheck disable=SC2317 # scaffold hook becomes reachable when TODO flow is filled
qmp() { python3 "$LABQMP" "$QMP" "$@"; }

# --- MEDIA PROVENANCE (no bits in the repo — URL + hash only) ---------------
# The station ships a PRE-INSTALLED disk, not a floppy install:
#   https://archive.org/download/sco-xenix-386-master/SCO%20Xenix%20386%20Master.zip
#   sha256 cd5756f07e1ef3b099ff29609c89c2f09baa9aae59d287ba486f2bbd4426545f
#   326021752 bytes; member "Master/Xenix Master-disk1.vdi" (133169152 bytes)
#   -> qemu-img convert -O qcow2 -> /data/gallery-guests/Xenix/xenix.qcow2
# Pristine install set (provenance only, NOT used to build the golden):
#   WinWorld "386 2.3.4q (3.5)" 7z, sha256
#     773e01a5cb737902331886f9050df47d6c2ac329bdb9d1f83daa5824693328db  (386PS/MCA build — does not boot under QEMU)
#   archive.org sco-xenix-386-and-extras RAR, sha256
#     8ebfc5aac3900382761a99533029ecf89b1a01a47f4e29bb1e5fcfe491e202e9
# The guest REQUIRES -enable-kvm; under TCG every exec dies "no stack space".
log "TODO: resolve latest stable media, verify its publisher checksum, and stage it atomically"
log "TODO: launch a namespaced LiveCD/scratch VM using the final pinned device set"
log "TODO: drive the ready fixture with labqmp, then run scripts/lib/golden-verify.sh"
die "scaffold only: fill the Tier 1 builder for $TILE_DIR"
