#!/usr/bin/env bash
# Low-resolution regression spot-check for the locally-built Cirrus QEMU.
set -euo pipefail

readonly CDRV=/root/cdrv.py

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 <qcirrus-trace-regression-clone-dir>"
clone_dir=${1%/}
qmp_sock=$clone_dir/qmp.sock
evidence_dir=$clone_dir/regression-640
: "${QEMU_BIN:?set QEMU_BIN to the locally-built patched binary}"

case "$clone_dir/" in
  /data/vms/soltest/qcirrus-trace-*/*) ;;
  *) die "refusing non-trace clone path: $clone_dir" ;;
esac
case "$QEMU_BIN" in
  "$clone_dir"/build/*) ;;
  *) die "QEMU_BIN must be inside this clone's build directory" ;;
esac

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone-guard assert-path "$clone_dir"
clone-guard assert-qmp "$qmp_sock"
[[ -S "$qmp_sock" ]] || die "QMP socket not found"
qemu_pid=$(<"$clone_dir/qemu.pid")
qemu_argv=$(tr '\0' ' ' <"/proc/$qemu_pid/cmdline")
case "$qemu_argv" in
  "$QEMU_BIN "*) ;;
  *) die "clone is not running the requested local QEMU: $qemu_argv" ;;
esac
mkdir -p "$evidence_dir"

cdrv() {
  python3 "$CDRV" "$qmp_sock" "$@"
}

key() {
  cdrv key "$1"
  sleep "${2:-0.20}"
}

shot() {
  local stem=$1 ppm=$evidence_dir/$1.ppm png=$evidence_dir/$1.png
  cdrv dump "$ppm"
  pnmtopng "$ppm" >"$png"
  [[ -s "$png" ]] || die "empty framebuffer capture: $png"
}

python3 /root/qmp_hmp.py "$qmp_sock" "loadvm golden" \
  >"$evidence_dir/loadvm-golden.txt"
sleep 3
shot "00-golden-desktop"
python3 - "$evidence_dir/00-golden-desktop.ppm" <<'PY'
import sys

with open(sys.argv[1], "rb") as fh:
    assert fh.readline().strip() == b"P6"
    line = fh.readline()
    while line.startswith(b"#"):
        line = fh.readline()
    assert line.split() == [b"640", b"480"], line
PY

# The 640x480 golden starts on Introducing Windows NT. This sequence opens the
# Read Me icon in the wrapped Main-group layout.
key down
key right
key right
key ret
sleep 5
shot "01-readme-open"
for n in $(seq 1 10); do
  key pgdn 0.30
done
shot "02-readme-pgdn10"
cdrv key alt f4
sleep 1
cdrv key alt n
sleep 2
shot "03-readme-closed"

printf '%s\n' \
  "REGRESSION CAPTURE COMPLETE: $evidence_dir" \
  "PASS only after visually confirming clean 640x480 desktop, Write, scroll, and close redraw."
