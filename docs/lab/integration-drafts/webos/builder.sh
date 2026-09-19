#!/bin/bash
# DRAFT ONLY: unpack preserved webOS SDK OVA, inventory hardware, convert VMDK to qcow2.
set -euo pipefail
WORK="${WORK:-/data/vms/build-webos}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/webos}"
OVA_SOURCE="${OVA_SOURCE:-}"
mkdir -p "$WORK/unpack" "$ASSETS"
[ -n "$OVA_SOURCE" ] || { echo "set OVA_SOURCE to acquired webOS SDK emulator OVA" >&2; exit 2; }
case "$OVA_SOURCE" in
  http://*|https://*) curl -fL --retry 3 -o "$WORK/webos.ova" "$OVA_SOURCE" ;;
  *) cp -f "$OVA_SOURCE" "$WORK/webos.ova" ;;
esac
sha256sum "$WORK/webos.ova" | tee "$WORK/MANIFEST.sha256"
tar -xf "$WORK/webos.ova" -C "$WORK/unpack"
OVF="$(find "$WORK/unpack" -maxdepth 1 -name '*.ovf' -print -quit)"
VMDK="$(find "$WORK/unpack" -maxdepth 1 -name '*.vmdk' -print -quit)"
[ -f "$OVF" ] && [ -f "$VMDK" ] || { echo "OVA missing OVF/VMDK" >&2; exit 1; }
cp -f "$OVF" "$ASSETS/appliance.ovf"
qemu-img info "$VMDK" | tee "$WORK/vmdk-info.txt"
qemu-img convert -p -f vmdk -O qcow2 "$VMDK" "$ASSETS/webos-seed.qcow2"
sha256sum "$ASSETS/webos-seed.qcow2" >>"$WORK/MANIFEST.sha256"
command -v xmllint >/dev/null && xmllint --format "$OVF" >"$WORK/appliance.pretty.ovf" || cp "$OVF" "$WORK/appliance.pretty.ovf"
echo "READ appliance.pretty.ovf and record RAM/CPU/disk-controller/NIC/display before final launcher." >&2
