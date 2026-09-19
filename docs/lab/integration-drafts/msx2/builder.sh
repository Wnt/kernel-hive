#!/bin/bash
# DRAFT ONLY: build/stage openMSX plus chosen MSX2 ROMs and MSX-DOS2 media.
set -euo pipefail
WORK="${WORK:-/data/vms/build-msx2}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/msx2}"
OPENMSX_REPO="${OPENMSX_REPO:-https://github.com/openMSX/openMSX.git}"
OPENMSX_REF="${OPENMSX_REF:-master}"
MACHINE_ROMS="${MACHINE_ROMS:-}"
DOS2_ROM="${DOS2_ROM:-}"
DOS2_DISK="${DOS2_DISK:-}"
mkdir -p "$WORK" "$ASSETS/bin" "$ASSETS/share" "$ASSETS/media"
git clone "$OPENMSX_REPO" "$WORK/openmsx"
( cd "$WORK/openmsx"; git checkout "$OPENMSX_REF"; git rev-parse HEAD ) | tee "$WORK/openmsx.commit"
( cd "$WORK/openmsx"; ./configure; make -j"$(nproc)" )
# Exact install target varies by openMSX release; worker may replace this with DESTDIR install.
OPENMSX_BIN="$(find "$WORK/openmsx" -type f -name openmsx -perm -111 -print -quit)"
[ -n "$OPENMSX_BIN" ] || { echo "openmsx binary not found" >&2; exit 1; }
cp -f "$OPENMSX_BIN" "$ASSETS/bin/openmsx"
[ -n "$MACHINE_ROMS" ] && cp -a "$MACHINE_ROMS/." "$ASSETS/media/"
[ -n "$DOS2_ROM" ] && cp -f "$DOS2_ROM" "$ASSETS/media/msxdos2.rom"
[ -n "$DOS2_DISK" ] && cp -f "$DOS2_DISK" "$ASSETS/media/msxdos2.dsk"
find "$ASSETS" -type f -print0 | sort -z | xargs -0 sha256sum >"$ASSETS/MANIFEST.sha256"
cat >&2 <<'EOF'
LAB STEP:
  run the staged openMSX with a real MSX2 profile (start with Philips_NMS_8250);
  ensure the machine ROM set is discoverable through the pinned openMSX system-data path;
  prove -ext msxdos2 -diska msxdos2.dsk before choosing a demo application.
EOF
