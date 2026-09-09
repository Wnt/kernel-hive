#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/pcgeos.sh — from-scratch build of the PC/GEOS Ensemble
# station media for the Kernel Hive (host-native streamhost, Tier 1).
#
# GUEST: PC/GEOS Ensemble (GeoWorks Ensemble lineage; the bluewaysw
#        open-source build, Apache-2.0, https://github.com/bluewaysw/pcgeos)
#        booted from the fleet FreeDOS 1.3 disk via loader.exe.
#
# WHAT THIS SCRIPT DOES:
#   1. fetch pcgeos-ensemble_nc.zip from the CI-latest release into
#      <STAGE_DIR>, verified against the pinned SHA-256 below (CI-latest is a
#      moving upstream tag; the hash, not the tag, is the pin).
#   2. compose the disk: qemu-img convert the fleet FreeDOS disk to raw,
#      unzip the ensemble payload, patch geos.ini ([mouse] left as shipped — see below,
#      screenBlanker off, drop the Lights Out Launcher autostart entry, drop the
#      truetype.geo font driver -- it #GPs (KR-11) under KVM when GeoWrite opens a document),
#      mcopy -s the ensemble dir onto the FAT16 partition (offset 32256) as
#      ::/ENSEMBLE, rewrite FDAUTO.BAT so `call \MENU.BAT` becomes
#      `cd \ENSEMBLE` + `loader`, convert back to qcow2.
#   3. verify: boot the composed disk headless on the pinned device set,
#      screendump after ~35s, assert it is not black/text-mode, keep the
#      frame as verify-desktop.png.
#
# Usage:
#   build-guests/tiles/pcgeos.sh [--force] [--no-verify] [-h]
#   env: WORK        scratch dir  (default /data/vms/build-pcgeos)
#        STAGE_DIR   intake dir   (default /data/assets-staging/pcgeos)
#        GUEST_DIR   output dir   (default /data/gallery-guests/PCGEOS)
# =============================================================================
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/pcgeos}"
WORK="${WORK:-/data/vms/build-pcgeos}"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/PCGEOS}"
OUT_NAME="pcgeos.qcow2"
ZIP_NAME="pcgeos-ensemble_nc.zip"
UPSTREAM_URL="https://github.com/bluewaysw/pcgeos/releases/download/CI-latest/${ZIP_NAME}"
# CI-latest is a moving tag; this hash is the pin, recorded in
# /data/assets-staging/pcgeos/MANIFEST.sha256 by the coordinator's spine work.
ZIP_SHA256="77587fb5b61783f65031296ddfa147273f4d398e00c40f5e5e9bfeaf37dc2bb2"
FREEDOS_QCOW2="/data/gallery-guests/FreeDOS/freedos.qcow2"
PART_OFFSET=32256
DISK_BYTES=536870912 # 512 MiB, matches the fleet freedos disk

FORCE=0
VERIFY=1
while [ $# -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h | --help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
OUT_PATH="${GUEST_DIR}/${OUT_NAME}"
QMPSOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"
VERIFY_PNG="${GUEST_DIR}/verify-desktop.png"

log() { printf '\033[1;36m[pcgeos]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[pcgeos] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

stop_qemu() {
  local p=""
  [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    python3 - "$LABQMP" "$QMPSOCK" <<'PY' 2>/dev/null || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("labqmp", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
try:
    with mod.QMPClient(sys.argv[2], timeout=5, connect_timeout=5) as c:
        c.execute("quit")
except Exception:
    pass
PY
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
    sleep 1
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$QMPSOCK"
}
cleanup() { stop_qemu; }
trap cleanup EXIT

for c in curl python3 sha256sum qemu-img unzip mcopy mdel mtype qemu-system-x86_64; do
  command -v "$c" >/dev/null 2>&1 || die "need $c"
done
[ -f "$LABQMP" ] || die "missing $LABQMP"
[ -f "$FREEDOS_QCOW2" ] || die "missing base disk $FREEDOS_QCOW2 (build tiles/freedos.sh first)"

mkdir -p "$WORK" "$GUEST_DIR"
install -d -m 0750 "$STAGE_DIR"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# =============================================================================
# (1) FETCH + PIN-VERIFY the ensemble zip
# =============================================================================
ZIP_PATH="${STAGE_DIR}/${ZIP_NAME}"
if [ "$FORCE" = 1 ] || [ ! -s "$ZIP_PATH" ] || [ "$(sha_of "$ZIP_PATH")" != "$ZIP_SHA256" ]; then
  log "fetching ${UPSTREAM_URL}"
  curl -fL --retry 3 -o "${ZIP_PATH}.part" "$UPSTREAM_URL"
  mv "${ZIP_PATH}.part" "$ZIP_PATH"
fi
[ "$(sha_of "$ZIP_PATH")" = "$ZIP_SHA256" ] || die "sha256 mismatch for $ZIP_PATH (got $(sha_of "$ZIP_PATH"), want $ZIP_SHA256)"
log "zip verified: $ZIP_PATH ($(stat -c%s "$ZIP_PATH") bytes)"

if [ "$FORCE" = 0 ] && [ -s "$OUT_PATH" ]; then
  log "output already present at $OUT_PATH, skipping compose (use --force to rebuild)"
else
  # ===========================================================================
  # (2) COMPOSE the disk
  # ===========================================================================
  rm -rf "$WORK/ens" "$WORK/disk.raw" "$WORK/disk.qcow2"
  mkdir -p "$WORK/ens"
  log "unzipping ensemble payload"
  unzip -q "$ZIP_PATH" -d "$WORK/ens"
  ENS_DIR="$WORK/ens"
  [ -f "$ENS_DIR/geos.ini" ] || ENS_DIR="$(find "$WORK/ens" -maxdepth 2 -iname geos.ini -exec dirname {} \; | head -1)"
  [ -f "$ENS_DIR/geos.ini" ] || die "geos.ini not found after unzip"

  log "patching geos.ini"
  python3 - "$ENS_DIR/geos.ini" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path, encoding="latin-1").read()
# [mouse] is left as the zip ships it (device "Basebox Mouse", driver "Abs. coord.
# Wheel Mouse"): under QEMU with CTMOUSE loaded it moves the pointer 1:1 and is
# what the kh-ramabs absolute pointer was derived against. The "Generic Mouse" /
# genmouse.geo entry the first ledger prescribed does NOT move the pointer here
# (measured 2026-09-03: five relative moves, cursor never left 320,134).
text = re.sub(r"(?im)^screenBlanker\s*=.*$", "screenBlanker = false", text, count=1)
# truetype.geo raises a general-protection fault (System Error KR-11) under KVM
# the moment GeoWrite opens a document (2026-09-03, docs/guests/pcgeos.md);
# GEOS's own Nimbus outline fonts render fine without it.
text = text.replace("font = {\n  truetype.geo\n}\n", "")
text = "\n".join(
    line for line in text.splitlines()
    if "lights out launcher" not in line.lower()
)
open(path, "w", encoding="latin-1").write(text + "\n")
PY
  grep -A2 '^\[mouse\]' "$ENS_DIR/geos.ini" | grep -q "Basebox Mouse" || die "geos.ini [mouse] is not the zip default"
  grep -qi "screenBlanker = false" "$ENS_DIR/geos.ini" || die "geos.ini screenBlanker patch failed"
  if grep -q "truetype.geo" "$ENS_DIR/geos.ini"; then die "geos.ini still loads truetype.geo"; fi
  grep -qi "lights out launcher" "$ENS_DIR/geos.ini" && die "geos.ini still has Lights Out Launcher"

  log "converting base FreeDOS disk to raw scratch"
  qemu-img convert -f qcow2 -O raw "$FREEDOS_QCOW2" "$WORK/disk.raw"
  [ "$(stat -c%s "$WORK/disk.raw")" = "$DISK_BYTES" ] || die "unexpected disk size: $(stat -c%s "$WORK/disk.raw")"

  export MTOOLS_SKIP_CHECK=1
  MCOPY_DISK="${WORK}/disk.raw@@${PART_OFFSET}"

  log "copying ENSEMBLE onto the FAT16 partition"
  mcopy -s -i "$MCOPY_DISK" "$ENS_DIR" "::/ENSEMBLE"

  log "rewriting FDAUTO.BAT"
  mtype -t -i "$MCOPY_DISK" "::/FDAUTO.BAT" >"$WORK/fdauto.bat.orig" 2>/dev/null || die "could not read FDAUTO.BAT"
  python3 - "$WORK/fdauto.bat.orig" "$WORK/fdauto.bat.new" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8", errors="replace").read().replace("\r\n", "\n").split("\n")
out = []
replaced = False
for line in lines:
    if line.strip().lower() == r"call \menu.bat":
        out.append(r"cd \ENSEMBLE")
        out.append("loader")
        replaced = True
    else:
        out.append(line)
if not replaced:
    raise SystemExit("call \\MENU.BAT line not found in FDAUTO.BAT")
text = "\r\n".join(l for l in out if l != "" or True)
if not text.endswith("\r\n"):
    text += "\r\n"
open(dst, "w", newline="").write(text)
PY
  mdel -i "$MCOPY_DISK" "::/FDAUTO.BAT"
  mcopy -i "$MCOPY_DISK" "$WORK/fdauto.bat.new" "::/FDAUTO.BAT"
  mtype -t -i "$MCOPY_DISK" "::/FDAUTO.BAT" | grep -qi '^cd \\ENSEMBLE' || die "FDAUTO.BAT rewrite did not stick"

  log "converting composed disk to qcow2"
  qemu-img convert -f raw -O qcow2 "$WORK/disk.raw" "$WORK/disk.qcow2"
  mv "$WORK/disk.qcow2" "$OUT_PATH"
  log "output: $OUT_PATH ($(stat -c%s "$OUT_PATH") bytes)"
fi

[ "$VERIFY" = 1 ] || {
  log "skipping verify (--no-verify)"
  exit 0
}

# =============================================================================
# (3) VERIFY: boot on the pinned device set, screendump, assert desktop
# =============================================================================
log "verify: booting composed disk headless"
rm -f "$QMPSOCK" "$PIDFILE"
SCRATCH="$WORK/verify.qcow2"
qemu-img create -f qcow2 -F qcow2 -b "$OUT_PATH" "$SCRATCH" >/dev/null

nohup qemu-system-x86_64 \
  -name build-pcgeos-verify \
  -enable-kvm -m 64 -smp 2 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0 \
  -drive file="$SCRATCH",format=qcow2,if=ide \
  -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -qmp "unix:${QMPSOCK},server=on,wait=off" \
  -pidfile "$PIDFILE" \
  >"$WORK/qemu.log" 2>&1 &

for _ in $(seq 1 40); do
  [ -S "$QMPSOCK" ] && [ -f "$PIDFILE" ] && break
  sleep 0.5
done
[ -S "$QMPSOCK" ] || die "qemu did not come up, see $WORK/qemu.log"

log "waiting ~35s for the desktop"
sleep 35

python3 - "$LABQMP" "$QMPSOCK" "$VERIFY_PNG" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("labqmp", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
with mod.QMPClient(sys.argv[2], timeout=10, connect_timeout=10) as c:
    c.screendump(sys.argv[3])
PY
[ -s "$VERIFY_PNG" ] || die "screendump did not produce $VERIFY_PNG"

PNG_SIZE="$(stat -c%s "$VERIFY_PNG")"
log "verify frame: $VERIFY_PNG ($PNG_SIZE bytes)"
[ "$PNG_SIZE" -gt 102400 ] || die "verify frame too small ($PNG_SIZE bytes) — looks like text mode or black screen"

log "build-guests/tiles/pcgeos.sh done: $OUT_PATH, verify frame $VERIFY_PNG"
