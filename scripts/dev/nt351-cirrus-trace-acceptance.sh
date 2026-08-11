#!/usr/bin/env bash
# Acceptance gate for a locally-built QEMU Cirrus BLT fix.
#
# The caller prepares and launches a namespaced clone whose internal "golden"
# snapshot is NT 3.51 at 1024x768x16bpp. This script refuses the system QEMU,
# restores that snapshot before every run, drives the adversarial PageDown,
# window-drag, open/close, and icon-move sequence three times, and captures raw
# QMP framebuffer evidence throughout. By default QEMU's qemu.log must contain
# "cirrus-blt:" records from the trace build; line ranges for each action are
# saved in trace-ranges.tsv. Set REQUIRE_BLT_TRACE=0 only when independently
# verifying a production package build that intentionally omits instrumentation.
#
# Usage:
#   QEMU_BIN=/data/vms/soltest/qcirrus-trace-UNIQ/build/qemu-system-i386-trace \
#     scripts/dev/nt351-cirrus-trace-acceptance.sh \
#     /data/vms/soltest/qcirrus-trace-UNIQ
#
# This gate is intentionally visual: PASS requires manual inspection of every
# PNG. Image hashes cannot reliably classify stale/overlapping glyphs.
set -euo pipefail

readonly CLONE_ROOT=/data/vms/soltest
readonly CDRV=/root/cdrv.py
readonly REQUIRE_BLT_TRACE=${REQUIRE_BLT_TRACE:-1}
readonly INSTALLED_QEMU=/opt/qemu-cirrusfix/bin/qemu-system-i386

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || die "usage: $0 <qcirrus-trace-clone-dir>"
clone_dir=${1%/}
qmp_sock=$clone_dir/qmp.sock
pidfile=$clone_dir/qemu.pid
qemu_log=$clone_dir/qemu.log
evidence_dir=$clone_dir/acceptance-trace
trace_ranges=$evidence_dir/trace-ranges.tsv
: "${QEMU_BIN:?set QEMU_BIN to the uniquely-named local patched binary}"
[[ "$REQUIRE_BLT_TRACE" == 0 || "$REQUIRE_BLT_TRACE" == 1 ]] ||
  die "REQUIRE_BLT_TRACE must be 0 or 1"

case "$clone_dir/" in
  "$CLONE_ROOT"/qcirrus-trace-*/*) ;;
  *) die "refusing non-trace clone path: $clone_dir" ;;
esac
case "$QEMU_BIN" in
  "$INSTALLED_QEMU") ;;
  "$clone_dir"/build/*) ;;
  *) die "QEMU_BIN must be the installed Cirrus-fix binary or inside this clone's build directory: $QEMU_BIN" ;;
esac

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone-guard assert-path "$clone_dir"
clone-guard assert-qmp "$qmp_sock"
[[ -x "$QEMU_BIN" ]] || die "patched QEMU is not executable: $QEMU_BIN"
[[ -S "$qmp_sock" ]] || die "QMP socket not found: $qmp_sock"
[[ -r "$CDRV" ]] || die "QMP input helper not readable: $CDRV"
[[ -r "$pidfile" ]] || die "QEMU pidfile not readable: $pidfile"
[[ -r "$qemu_log" ]] || die "QEMU log not readable: $qemu_log"

qemu_pid=$(<"$pidfile")
qemu_argv=$(tr '\0' ' ' <"/proc/$qemu_pid/cmdline")
case "$qemu_argv" in
  "$QEMU_BIN "*) ;;
  *) die "clone is not running the requested patched QEMU: $qemu_argv" ;;
esac
case "$qemu_argv" in
  *"/data/vms/streamhost/stations/"*) die "QEMU argv references a production tile" ;;
esac

mkdir -p "$evidence_dir"
printf 'run\taction\tfirst_log_line\tlast_log_line\n' >"$trace_ranges"

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

log_line_count() {
  wc -l <"$qemu_log"
}

record_trace_range() {
  local run=$1 action=$2 first=$3 last
  if [[ "$REQUIRE_BLT_TRACE" == 0 ]]; then
    printf '%s\t%s\t%s\t%s\n' "$run" "$action" n/a n/a >>"$trace_ranges"
    return
  fi
  last=$(log_line_count)
  printf '%s\t%s\t%s\t%s\n' "$run" "$action" "$((first + 1))" "$last" \
    >>"$trace_ranges"
}

reset_candidate_golden() {
  hmp "loadvm golden" >"$evidence_dir/loadvm-$1.txt"
  sleep 3
}

prove_mode() {
  local run=$1
  shot "run-$run-00-mode"
  python3 - "$evidence_dir/run-$run-00-mode.ppm" <<'PY'
import sys

with open(sys.argv[1], "rb") as fh:
    assert fh.readline().strip() == b"P6"
    line = fh.readline()
    while line.startswith(b"#"):
        line = fh.readline()
    assert line.split() == [b"1024", b"768"], line
PY

  # Program Manager Main group: Home selects File Manager, Right selects
  # Control Panel. Display Settings visibly proves both geometry and depth.
  key home
  key right
  key ret
  sleep 1
  key down
  for _ in 1 2 3 4 5; do
    key right
  done
  key ret
  sleep 2
  shot "run-$run-00b-display-settings-65536"
  cdrv key alt f4
  sleep 1
  cdrv key alt f4
  sleep 1
  for _ in 1 2 3 4 5 6 7 8 9; do
    key right
  done
}

open_readme_and_scroll() {
  local run=$1 first
  key down
  key right
  key right
  key ret
  sleep 5
  shot "run-$run-01-readme-loaded"
  first=$(log_line_count)
  for n in $(seq 1 10); do
    key pgdn 0.35
    shot "run-$run-02-pgdn-$(printf '%02d' "$n")"
  done
  record_trace_range "$run" pagedown-x10 "$first"
}

mouse_drag() {
  python3 - "$qmp_sock" "$1" "$2" "$3" <<'PY'
import json
import socket
import sys
import time

sock_path, dx, dy, steps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.settimeout(20)
    sock.connect(sock_path)
    stream = sock.makefile("rwb", buffering=0)
    stream.readline()
    stream.write(b'{"execute":"qmp_capabilities"}\n')
    while "return" not in json.loads(stream.readline()):
        pass

    def event(data):
        request = {"execute": "input-send-event", "arguments": {"events": [data]}}
        stream.write((json.dumps(request) + "\n").encode())
        while True:
            reply = json.loads(stream.readline())
            if "error" in reply:
                raise RuntimeError(reply["error"])
            if "return" in reply:
                return

    event({"type": "btn", "data": {"button": "left", "down": True}})
    for _ in range(steps):
        event({"type": "rel", "data": {"axis": "x", "value": dx}})
        event({"type": "rel", "data": {"axis": "y", "value": dy}})
        time.sleep(0.08)
    event({"type": "btn", "data": {"button": "left", "down": False}})
PY
}

place_pointer_on_write_title() {
  for _ in $(seq 1 16); do
    cdrv rel -100 -100
  done
  for _ in $(seq 1 8); do
    cdrv rel 40 7
  done
  sleep 1
}

drag_window_diagonally() {
  local run=$1 pass=$2 dx=$3 dy=$4 first n
  first=$(log_line_count)
  mouse_drag "$dx" "$dy" 10 &
  local drag_pid=$!
  for n in 1 2 3; do
    sleep 0.25
    shot "run-$run-03-drag-$pass-step-$n"
  done
  wait "$drag_pid"
  sleep 1
  shot "run-$run-04-drag-$pass-settled"
  record_trace_range "$run" "window-drag-$pass" "$first"
}

open_close_over_icons() {
  local run=$1 first
  first=$(log_line_count)
  cdrv key alt f4
  sleep 1
  shot "run-$run-05a-write-save-prompt"
  # Write treats the legacy README conversion as a document change. Discard it
  # so this closes Write instead of leaving the prompt up.
  cdrv key alt n
  sleep 2
  shot "run-$run-05-write-closed"
  key ret
  sleep 5
  shot "run-$run-06-write-reopened"
  cdrv key alt f4
  sleep 1
  cdrv key alt n
  sleep 2
  shot "run-$run-07-write-reclosed"
  record_trace_range "$run" open-close "$first"
}

move_icon() {
  local run=$1 first
  for _ in $(seq 1 16); do
    cdrv rel -100 -100
  done
  cdrv rel 38 55
  first=$(log_line_count)
  mouse_drag 8 7 10
  sleep 1
  shot "run-$run-08-icon-moved"
  record_trace_range "$run" icon-move "$first"
}

for run in 1 2 3; do
  reset_candidate_golden "$run"
  prove_mode "$run"
  open_readme_and_scroll "$run"
  place_pointer_on_write_title
  shot "run-$run-03-pointer-on-write-title"
  drag_window_diagonally "$run" 1 16 12
  drag_window_diagonally "$run" 2 -14 -10
  drag_window_diagonally "$run" 3 15 11
  open_close_over_icons "$run"
  move_icon "$run"
  shot "run-$run-09-final"
done

if [[ "$REQUIRE_BLT_TRACE" == 1 ]]; then
  grep -q '^cirrus-blt:' "$qemu_log" ||
    die "instrumented BLT records absent from $qemu_log"
fi

printf '%s\n' \
  "CAPTURE COMPLETE: $evidence_dir" \
  "Trace action ranges: $trace_ranges" \
  "BLT trace required: $REQUIRE_BLT_TRACE" \
  "Mandatory gate: inspect every run-*.png for stale/overlapping pixels." \
  "PASS only if all three Display Settings frames prove 1024x768x16 and every frame is clean."
