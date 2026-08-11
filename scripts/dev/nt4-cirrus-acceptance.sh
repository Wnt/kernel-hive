#!/usr/bin/env bash
# Clone-only acceptance gate for the Windows NT 4.0 Cirrus hi-res candidate.
#
# The caller prepares a namespaced clone at a settled 1024x768x16bpp desktop
# and launches it cold with the dedicated patched QEMU. This script captures
# the pre-save framebuffer, replaces the old "golden" snapshot, and starts a
# fresh QEMU process with -loadvm golden before each of three adversarial runs.
# Every restored idle PPM must be byte-identical to the pre-save PPM. The gate
# also captures the visible Display Properties mode, proves the absolute
# pointer at five known screen fractions, scrolls a long Notepad document,
# drags the window across desktop icons, and moves a desktop icon.
#
# PASS is intentionally framebuffer-based. Inspect every generated PNG and the
# contact sheets; hashes alone cannot classify stale Cirrus redraw fragments.
#
# Usage:
#   EXPECT_OPTION=A-ISA scripts/dev/nt4-cirrus-acceptance.sh \
#     /data/vms/soltest/nt4-cirrus-UNIQ
set -euo pipefail

readonly CLONE_ROOT=/data/vms/soltest
readonly CDRV=/root/cdrv.py
readonly PATCHED_QEMU=${PATCHED_QEMU:-/data/vms/soltest/cvmstate-trace-20260728T084646Z-14233/qemu-fixed-clean}
readonly CLONE_LAUNCHER=${CLONE_LAUNCHER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nt4-cirrus-clone-launch.sh}
readonly EXPECT_OPTION=${EXPECT_OPTION:-A}
readonly SKIP_MODE_PROOF=${SKIP_MODE_PROOF:-0}
readonly RUNS=${RUNS:-3}

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 <nt4-cirrus-clone-dir>"
clone_dir=${1%/}
qmp_sock=$clone_dir/qmp.sock
pidfile=$clone_dir/qemu.pid
evidence_dir=$clone_dir/acceptance

case "$clone_dir/" in
  "$CLONE_ROOT"/nt4-cirrus-*/*) ;;
  *) die "refusing non-NT4-Cirrus clone path: $clone_dir" ;;
esac
case "$EXPECT_OPTION" in
  A | A-ISA | A-ISA-TCG | B) ;;
  *) die "EXPECT_OPTION must be A, A-ISA, A-ISA-TCG, or B" ;;
esac
[[ "$SKIP_MODE_PROOF" == 0 || "$SKIP_MODE_PROOF" == 1 ]] ||
  die "SKIP_MODE_PROOF must be 0 or 1"
case "$RUNS" in
  '' | *[!0-9]* | 0) die "RUNS must be a positive integer" ;;
esac

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone-guard assert-path "$clone_dir"
clone-guard assert-qmp "$qmp_sock"
[[ -x "$PATCHED_QEMU" ]] || die "patched QEMU is not executable: $PATCHED_QEMU"
[[ -x "$CLONE_LAUNCHER" ]] || die "clone launcher is not executable: $CLONE_LAUNCHER"
[[ -r "$CDRV" ]] || die "QMP input helper not readable: $CDRV"
[[ -S "$qmp_sock" ]] || die "QMP socket not found: $qmp_sock"
[[ -r "$pidfile" ]] || die "QEMU pidfile not readable: $pidfile"

qemu_pid=$(<"$pidfile")
qemu_argv=$(tr '\0' ' ' <"/proc/$qemu_pid/cmdline")
case "$qemu_argv" in
  "$PATCHED_QEMU -L /usr/share/kvm "*) ;;
  *) die "clone is not running the dedicated patched QEMU with its data path: $qemu_argv" ;;
esac
case "$qemu_argv" in
  *"/data/vms/streamhost/stations/"*) die "QEMU argv references a production tile" ;;
esac
case "$EXPECT_OPTION:$qemu_argv" in
  A:*"-machine pc-i440fx-11.0,hpet=off,vmport=on "*" -device cirrus-vga "*) ;;
  A-ISA:*"-machine pc-i440fx-11.0,hpet=off,vmport=on "*" -device isa-cirrus-vga"*) ;;
  A-ISA-TCG:*"-accel tcg "*" -machine pc-i440fx-11.0,hpet=off,vmport=on "*" -device isa-cirrus-vga"*) ;;
  B:*"-machine isapc "*" -device isa-cirrus-vga"*) ;;
  *) die "QEMU argv does not match expected Option $EXPECT_OPTION: $qemu_argv" ;;
esac

rm -rf "$evidence_dir"
mkdir -p "$evidence_dir"
printf '%s\n' "$qemu_argv" >"$evidence_dir/qemu-argv.txt"

cdrv() {
  python3 "$CDRV" "$qmp_sock" "$@"
}

key() {
  cdrv key "$@" >/dev/null
  sleep 0.20
}

type_text() {
  cdrv type "$1" >/dev/null
}

hmp() {
  python3 - "$qmp_sock" "$1" <<'PY'
import json
import socket
import sys

sock_path, command = sys.argv[1:]
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(sock_path)
    stream = sock.makefile("rwb", buffering=0)
    stream.readline()
    stream.write(b'{"execute":"qmp_capabilities"}\n')
    while "return" not in json.loads(stream.readline()):
        pass
    request = {
        "execute": "human-monitor-command",
        "arguments": {"command-line": command},
    }
    stream.write((json.dumps(request) + "\n").encode())
    while True:
        reply = json.loads(stream.readline())
        if "return" in reply:
            print(reply["return"], end="")
            break
        if "error" in reply:
            raise SystemExit(reply["error"])
PY
}

shot() {
  local stem=$1 ppm=$evidence_dir/$1.ppm png=$evidence_dir/$1.png
  cdrv dump "$ppm" >/dev/null
  pnmtopng "$ppm" >"$png"
  [[ -s "$png" ]] || die "empty framebuffer capture: $png"
}

assert_1024x768() {
  python3 - "$1" <<'PY'
import sys

with open(sys.argv[1], "rb") as fh:
    assert fh.readline().strip() == b"P6"
    line = fh.readline()
    while line.startswith(b"#"):
        line = fh.readline()
    assert line.split() == [b"1024", b"768"], line
PY
}

launch_fresh_golden() {
  local run=$1
  clone-guard kill-pidfile "$pidfile"
  env PATCHED_QEMU="$PATCHED_QEMU" \
    "$CLONE_LAUNCHER" "$clone_dir" "$EXPECT_OPTION" golden \
    >"$evidence_dir/run-$run-fresh-process-launch.txt"
  sleep 3
  shot "run-$run-00-idle"
  assert_1024x768 "$evidence_dir/run-$run-00-idle.ppm"
  cmp "$evidence_dir/loadvm-00-presave.ppm" "$evidence_dir/run-$run-00-idle.ppm" ||
    die "fresh-process run $run differs from the pre-save framebuffer"
  sleep 1
  shot "run-$run-00-idle-repeat"
  cmp "$evidence_dir/loadvm-00-presave.ppm" "$evidence_dir/run-$run-00-idle-repeat.ppm" ||
    die "fresh-process run $run is not stably byte-identical to the pre-save framebuffer"
}

open_run_dialog() {
  key ctrl esc
  key r
  sleep 0.5
  key ctrl a
}

prove_display_mode() {
  local run=$1
  open_run_dialog
  type_text "control.exe desk.cpl"
  key ret
  sleep 3
  # Select Settings by position because NT4 remembers the last CPL tab and
  # does not honor the modern desk.cpl `,,N` tab suffix.
  cdrv click 11450 4560 >/dev/null
  cdrv click 11450 4560 >/dev/null
  sleep 2
  shot "run-$run-01-display-settings-1024x768x65536"
  key esc
  sleep 1
}

prove_pointer_grid() {
  local run=$1 label x y
  [[ "$EXPECT_OPTION" == A || "$EXPECT_OPTION" == A-ISA || "$EXPECT_OPTION" == A-ISA-TCG ]] ||
    die "Option B pointer calibration must be exercised through streamhost dbus-rel"
  while read -r label x y; do
    cdrv abs "$x" "$y" >/dev/null
    sleep 0.4
    shot "run-$run-02-pointer-$label"
  done <<'EOF'
10-10 3277 3277
50-10 16384 3277
90-10 29490 3277
25-75 8192 24575
75-75 24575 24575
EOF
}

open_notepad_document() {
  local run=$1
  open_run_dialog
  type_text 'notepad.exe c:/winnt/system32/drivers/etc/services'
  key ret
  sleep 4
  shot "run-$run-03-notepad-open"
  for n in $(seq 1 10); do
    key pgdn
    shot "run-$run-04-pgdn-$(printf '%02d' "$n")"
  done
}

mouse_abs_drag() {
  local x1=$1 y1=$2 x2=$3 y2=$4 steps=$5
  python3 - "$qmp_sock" "$x1" "$y1" "$x2" "$y2" "$steps" <<'PY'
import json
import socket
import sys
import time

sock_path, x1, y1, x2, y2, steps = sys.argv[1:]
x1, y1, x2, y2, steps = map(int, (x1, y1, x2, y2, steps))
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(20)
    sock.connect(sock_path)
    stream = sock.makefile("rwb", buffering=0)
    stream.readline()
    stream.write(b'{"execute":"qmp_capabilities"}\n')
    while "return" not in json.loads(stream.readline()):
        pass

    def event(*events):
        request = {"execute": "input-send-event", "arguments": {"events": list(events)}}
        stream.write((json.dumps(request) + "\n").encode())
        while True:
            reply = json.loads(stream.readline())
            if "error" in reply:
                raise RuntimeError(reply["error"])
            if "return" in reply:
                return

    def move(x, y):
        event(
            {"type": "abs", "data": {"axis": "x", "value": x}},
            {"type": "abs", "data": {"axis": "y", "value": y}},
        )

    move(x1, y1)
    time.sleep(0.3)
    event({"type": "btn", "data": {"button": "left", "down": True}})
    for step in range(1, steps + 1):
        move(x1 + (x2 - x1) * step // steps, y1 + (y2 - y1) * step // steps)
        time.sleep(0.10)
    event({"type": "btn", "data": {"button": "left", "down": False}})
PY
}

drag_window_over_icons() {
  local run=$1
  # Maximize then restore so the system menu is guaranteed closed. The window
  # is staged at the right, then dragged left across the desktop icons.
  key alt spc
  key x
  sleep 1
  key alt spc
  key r
  sleep 1
  # Establish a deterministic right-side starting position without relying on
  # a first mouse drag: System Menu -> Move, then 40 keyboard steps right.
  key alt spc
  sleep 0.5
  key m
  sleep 0.5
  for _ in $(seq 1 40); do
    key right
  done
  key ret
  sleep 1
  cdrv click 19200 4267 >/dev/null
  sleep 0.5
  mouse_abs_drag 19200 4267 5120 9600 12 &
  local drag_pid=$!
  sleep 0.35
  shot "run-$run-05-window-drag-left-step-1"
  sleep 0.40
  shot "run-$run-05-window-drag-left-step-2"
  wait "$drag_pid"
  sleep 1
  shot "run-$run-06-window-drag-left-settled"

  shot "run-$run-07-window-drag-left-stable-1"
  sleep 1
  shot "run-$run-08-window-drag-left-stable-2"
}

move_desktop_icon() {
  local run=$1
  cdrv click 5120 9600 >/dev/null
  sleep 0.5
  key alt f4
  sleep 2
  shot "run-$run-09-icon-before"
  # My Briefcase starts around (36,245) at the canonical NT4 desktop. Move it
  # into open desktop space; loadvm restores the layout before the next run.
  mouse_abs_drag 1150 10450 7000 13500 12
  sleep 1
  shot "run-$run-10-icon-moved"
}

cdrv abs 32000 30000 >/dev/null
sleep 1
shot "loadvm-00-presave"
assert_1024x768 "$evidence_dir/loadvm-00-presave.ppm"
sleep 1
shot "loadvm-00-presave-repeat"
cmp "$evidence_dir/loadvm-00-presave.ppm" "$evidence_dir/loadvm-00-presave-repeat.ppm" ||
  die "pre-save framebuffer is not stable enough for a byte-identical loadvm gate"
hmp "delvm golden" >"$evidence_dir/loadvm-delvm-old-golden.txt"
hmp "savevm golden" >"$evidence_dir/loadvm-savevm-golden.txt"
sleep 1
shot "loadvm-01-postsave"
cmp "$evidence_dir/loadvm-00-presave.ppm" "$evidence_dir/loadvm-01-postsave.ppm" ||
  die "savevm changed the visible framebuffer"

for run in $(seq 1 "$RUNS"); do
  launch_fresh_golden "$run"
  if [[ "$SKIP_MODE_PROOF" == 0 ]]; then
    prove_display_mode "$run"
  fi
  prove_pointer_grid "$run"
  open_notepad_document "$run"
  drag_window_over_icons "$run"
  move_desktop_icon "$run"
  shot "run-$run-11-final"
done

launch_fresh_golden final

if command -v montage >/dev/null 2>&1; then
  montage "$evidence_dir"/run-*-02-pointer-*.png \
    -tile 5x3 -geometry +4+22 -set label '%f' \
    "$evidence_dir/pointer-grid-contact-sheet.png"
  montage "$evidence_dir"/run-*-04-pgdn-10.png \
    "$evidence_dir"/run-*-06-window-drag-left-settled.png \
    "$evidence_dir"/run-*-08-window-drag-right-settled.png \
    "$evidence_dir"/run-*-10-icon-moved.png \
    -tile 4x3 -geometry +4+22 -set label '%f' \
    "$evidence_dir/adversarial-contact-sheet.png"
fi

sha256sum "$evidence_dir"/*.ppm >"$evidence_dir/framebuffers.sha256"
printf '%s\n' \
  "CAPTURE COMPLETE: $evidence_dir" \
  "Option: $EXPECT_OPTION" \
  "Runs: $RUNS; skip mode proof: $SKIP_MODE_PROOF" \
  "Fresh-process -loadvm golden: every idle pair is byte-identical to loadvm-00-presave.ppm" \
  "Mandatory gate: inspect every run-*.png for stale/overlapping pixels." \
  "PASS only if the Settings frames (when enabled) prove 1024x768 and 65536 colors," \
  "all five pointer targets land 1:1 in every run, and every adversarial frame is clean."
