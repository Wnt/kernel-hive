#!/bin/bash
# Builder for chokanji — 超漢字 / B-right/V (BTRON3, Ken Sakamura's TRON project).
#
# There is no OS install to automate: the operator-provided archive.org set
# "chokanji" bundles the community "QEMU-CKJ" port, whose qemuckj/mc.img is a
# pre-installed, ready-to-boot B-right/V disk. This builder is therefore a
# deterministic REPACK, not an install:
#   1. resolve chokanji.zip from the media archive by its sha256 pin (fetching
#      it from archive.org only on a cold cache — media_cache_require);
#   2. extract qemuckj/mc.img (a raw ex-VMware disk) out of the nested archives;
#   3. convert it to the canonical qcow2 the station launcher boots;
#   4. framebuffer smoke-test: boot the production device set headless and prove
#      the Cirrus console is NOT blank (the BTRON desktop actually painted).
# The `golden` snapshot is baked separately on the box via the station launcher
# (savevm golden into chokanji.qcow2, resetMode=loadvm) — see docs/guests/chokanji.md.
#
# Idempotent, fail-fast, namespaced; stops only its own QEMU by pidfile.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/../lib/media-cache.sh"

OS_ID="chokanji"
OUT_DIR="${GUESTS_ROOT:-/data/gallery-guests}/Chokanji"
OUT="$OUT_DIR/chokanji.qcow2"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
FORCE="${FORCE:-0}"

# chokanji.zip — the whole operator-provided media set (archive.org item 'chokanji').
ZIP_SHA256="sha256:b8fd99a928d5564e53b58d2b8853b05f799a3fc32ba09cee0714a66c675039df"
ZIP_URL="https://archive.org/download/chokanji/chokanji.zip"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
cleanup() { [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true; }
trap cleanup EXIT

if [ -s "$OUT" ] && [ "$FORCE" != 1 ]; then
  log "$OUT already present — nothing to do (FORCE=1 to rebuild)"
  exit 0
fi

command -v unar >/dev/null || die "unar (The Unarchiver) is required to open the nested rar/7z"
mkdir -p "$WORK" "$OUT_DIR"

log "resolving media set from the archive (sha256 pin)…"
media_cache_require "$ZIP_SHA256" "$WORK/chokanji.zip" \
  "chokanji.zip — 超漢字/Chokanji-V + B-right/V + QEMU-CKJ (archive.org 'chokanji')" \
  "$ZIP_URL" || die "cannot obtain chokanji.zip"

log "extracting qemuckj/mc.img…"
rm -rf "$WORK/x"
unar -q -f -o "$WORK/x" "$WORK/chokanji.zip" >/dev/null || die "unzip failed"
unar -q -f -o "$WORK/x/qemuckj" "$WORK/x/chokanji/qemuckj.7z" >/dev/null || die "qemuckj.7z extract failed"
MC="$(find "$WORK/x" -name mc.img -print -quit)"
[ -s "$MC" ] || die "mc.img not found after extraction"

# strings sanity: this really is the BTRON/B-right kernel, not some other image
strings -n 6 "$MC" | grep -qi "B-right/V Kernel" || die "mc.img is not a B-right/V disk (kernel banner absent)"

log "converting mc.img -> $OUT (qcow2)…"
# -S 0: this source is a sparse ex-VMware raw disk; zero-run detection produced an
# empty qcow2 on this ZFS store, so copy every block explicitly.
rm -f "$OUT"
qemu-img convert -S 0 -f raw -O qcow2 "$MC" "$OUT" || die "qemu-img convert failed"
qemu-img compare -f raw "$MC" -F qcow2 "$OUT" >/dev/null || die "qcow2 does not match source disk"
log "disk built: $(qemu-img info "$OUT" | awk -F': ' '/virtual size/{print $2}')"

# --- framebuffer smoke-test: prove the BTRON desktop paints (not a blank Cirrus) ---
log "framebuffer smoke-test…"
cleanup
sleep 0.3
rm -f "$QMP" "$PIDFILE"
nohup qemu-system-x86_64 \
  -name "build-$OS_ID" \
  -enable-kvm -m 256 -smp 1 \
  -machine pc-i440fx-11.0,vmport=off -cpu host \
  -rtc base=localtime -boot c -vga cirrus \
  -drive file="$OUT",format=qcow2,if=ide \
  -display none \
  -qmp "unix:$QMP,server=on,wait=off" \
  -pidfile "$PIDFILE" >"$WORK/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$QMP" ] && break
  sleep 0.5
done
[ -S "$QMP" ] || die "QMP socket never appeared"
sleep 45
python3 - "$QMP" "$WORK/smoke.png" <<'PY' || die "framebuffer smoke-test FAILED (blank or no console)"
import socket, json, sys
sock, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX); s.connect(sock); s.settimeout(15)
f = s.makefile('rwb', buffering=0); f.readline()
def cmd(c, a=None):
    m = {"execute": c}
    if a: m["arguments"] = a
    f.write((json.dumps(m) + "\n").encode())
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r: return r
cmd("qmp_capabilities")
if "error" in cmd("screendump", {"filename": out, "format": "png"}): sys.exit(1)
from PIL import Image
im = Image.open(out).convert("RGB")
colors = im.getcolors(maxcolors=1 << 20) or []
# a painted BTRON desktop has thousands of distinct colours; a blank console a handful
sys.exit(0 if len(colors) > 200 else 1)
PY
log "framebuffer smoke-test PASSED — BTRON desktop painted ($WORK/smoke.png)"
cleanup
log "done: $OUT (bake 'golden' on the box via the station launcher — see docs/guests/chokanji.md)"
