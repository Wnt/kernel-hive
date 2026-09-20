#!/bin/bash
# DRAFT ONLY: early PowerPC Mac OS X media + blank disk.
set -euo pipefail
WORK="${WORK:-/data/vms/build-macosx}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/macosx}"
INSTALL_ISO="${INSTALL_ISO:-}"
mkdir -p "$WORK" "$ASSETS/media"
[ -n "$INSTALL_ISO" ] || {
  echo "set INSTALL_ISO to acquired Jaguar/Panther PPC media" >&2
  exit 2
}
cp -f "$INSTALL_ISO" "$ASSETS/media/install-cd1.iso"
sha256sum "$ASSETS/media/install-cd1.iso" | tee "$ASSETS/MANIFEST.sha256"
qemu-img create -f qcow2 "$WORK/macosx.qcow2" 8G
cat >&2 <<'EOF'
ASSISTED FIRST INSTALL:
  /opt/qemu-ppc/bin/qemu-system-ppc -M mac99,via=pmu -cpu g4 -m 512     -g 1024x768x32 -drive file=<disk>,format=qcow2 -cdrom <iso> -boot d
Automate only after Finder/Aqua, first reboot and input are proven.
EOF
