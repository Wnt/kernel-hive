#!/usr/bin/env bash
# Build a Linux proof/guest VM whose PVE-owned QEMU exposes streamhost's D-Bus
# display and a dedicated second QMP socket. Run this script on the PVE host.
#
# Required:
#   VMID=990 TILE=pve-linux-proof ISO_VOLUME=isos:iso/alpine.iso ./linux.sh
# or:
#   VMID=990 TILE=pve-linux-proof DISK_IMAGE=/path/disk.qcow2 ./linux.sh
#
# The VMID must be unused and >= 900. Known gallery/infra IDs are blocked here;
# macOS 925 and Windows 11 900 use their separate gated builders.
set -euo pipefail

VMID="${VMID:?set VMID to a fresh, namespaced VMID >= 900}"
TILE="${TILE:?set TILE to the streamhost tile directory name}"
VM_NAME="${VM_NAME:-pve-tile-${TILE}}"
STORAGE="${STORAGE:-data}"
ISO_VOLUME="${ISO_VOLUME:-}"
DISK_IMAGE="${DISK_IMAGE:-}"
MEMORY="${MEMORY:-1024}"
CORES="${CORES:-2}"
VGA="${VGA:-std}"
AUDIO="${AUDIO:-off}"
TILES_ROOT="${TILES_ROOT:-/data/vms/streamhost/tiles}"
TILE_DIR="${TILES_ROOT}/${TILE}"

case "$VMID" in '' | *[!0-9]*)
  echo "invalid VMID: $VMID" >&2
  exit 2
  ;;
esac
[ "$VMID" -ge 900 ] || {
  echo "VMID must be >= 900" >&2
  exit 2
}
case "$VMID" in
  900 | 925 | 950)
    echo "VMID $VMID is reserved for a gated exhibit or lab infrastructure" >&2
    exit 2
    ;;
esac
case "$TILE" in
  '' | *[!a-zA-Z0-9_-]*)
    echo "invalid TILE: $TILE" >&2
    exit 2
    ;;
esac
case "$VGA" in std | vmware | qxl) ;; *)
  echo "VGA must be std, vmware, or qxl" >&2
  exit 2
  ;;
esac
case "$AUDIO" in on | off) ;; *)
  echo "AUDIO must be on or off" >&2
  exit 2
  ;;
esac
if [ -n "$ISO_VOLUME" ] && [ -n "$DISK_IMAGE" ]; then
  echo "set only one of ISO_VOLUME or DISK_IMAGE" >&2
  exit 2
fi
if [ -z "$ISO_VOLUME" ] && [ -z "$DISK_IMAGE" ]; then
  echo "set ISO_VOLUME (PVE volume ID) or DISK_IMAGE (host path)" >&2
  exit 2
fi
if qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID already exists; refusing to modify it" >&2
  exit 1
fi
[ ! -S "$TILE_DIR/qmp.sock" ] || {
  echo "live QMP already exists: $TILE_DIR/qmp.sock" >&2
  exit 1
}
[ -z "$DISK_IMAGE" ] || [ -f "$DISK_IMAGE" ] || {
  echo "disk image missing: $DISK_IMAGE" >&2
  exit 1
}
[ -z "$ISO_VOLUME" ] || pvesm path "$ISO_VOLUME" >/dev/null

install -d -m 0755 "$TILE_DIR"
qm create "$VMID" --name "$VM_NAME" --ostype l26 --memory "$MEMORY" \
  --cores "$CORES" --sockets 1 --cpu host --vga "$VGA" --tablet 1

if [ -n "$ISO_VOLUME" ]; then
  qm set "$VMID" --ide2 "${ISO_VOLUME},media=cdrom" --boot 'order=ide2'
else
  qm disk import "$VMID" "$DISK_IMAGE" "$STORAGE" --format raw --target-disk ide0
  qm set "$VMID" --boot 'order=ide0'
fi

DISPLAY_ARG="dbus,p2p=on"
AUDIO_ARGS=""
if [ "$AUDIO" = "on" ]; then
  DISPLAY_ARG="dbus,p2p=on,audiodev=snd0"
  AUDIO_ARGS=" -audiodev dbus,id=snd0 -device intel-hda -device hda-output,audiodev=snd0"
fi
PVE_ARGS="-display ${DISPLAY_ARG} -qmp unix:${TILE_DIR}/qmp.sock,server=on,wait=off${AUDIO_ARGS}"
qm set "$VMID" --args "$PVE_ARGS"

# This exact output is the PVE mode's device ledger. Keep its lines in the
# registry entry's runtime.qemu.deviceSetSummary instead of inventing a launcher.
CONFIG_LEDGER="$TILE_DIR/pve-qm-config.txt"
qm config "$VMID" | tee "$CONFIG_LEDGER"
python3 - "$CONFIG_LEDGER" <<'PY'
import json, sys
print("runtime.qemu.deviceSetSummary = " + json.dumps(open(sys.argv[1]).read().splitlines(), indent=2))
PY
echo "created PVE VM $VMID for tile $TILE (not started)"
echo "dedicated streamhost QMP: $TILE_DIR/qmp.sock"
