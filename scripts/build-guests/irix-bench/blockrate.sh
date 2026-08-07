#!/bin/bash
# blockrate.sh — how many DRC blocks per second is this MAME compiling?
#
# WHY IT WORKS. drcbex64.cpp generate() calls osd_get_cache_line_size() once per
# compiled block, and on Linux that is an fopen/fscanf/fclose of sysfs. In the
# IRIX workload the emulator opens no other file, so its openat count IS its
# block-compile rate. Verified with three uprobes on the SHIPPED binary:
# code_compile_block == drcbe_x64::generate == osd_get_cache_line_size ==
# syscalls:sys_enter_openat, all 12832 in the same 20 s window.
#
# Every compile-side claim on this project has lacked a block-rate meter. This
# is one, it costs nothing (a tracepoint counter, not ptrace), and it works on
# the production binary with no rebuild.
#
# CAVEAT: once mame-osd-cache-line-size-memo.patch is in the binary, the openat
# proxy is gone by construction — the whole point of the patch. Against a
# memoized binary use the uprobe form instead (--probe), which counts
# code_compile_block itself.
#
#   blockrate.sh <pid> [seconds]            openat proxy (stock binary)
#   blockrate.sh --probe <binary> <pid> [s] uprobe on code_compile_block
#
# DO NOT use `strace -c` for this: its ptrace stops cost 30-100 us apiece and
# distort both the rate and the share.
set -u

usage() {
  sed -n '2,24p' "$0" >&2
  exit 2
}

if [ "${1:-}" = "--probe" ]; then
  BIN=${2:-}
  PID=${3:-}
  SECS=${4:-30}
  [ -n "$BIN" ] && [ -n "$PID" ] || usage
  T=/sys/kernel/tracing
  # mips3_device::code_compile_block, by raw ELF offset. `perf probe` cannot
  # resolve these names itself — it parses the C++ `::` as a line number.
  OFF=$(readelf -sW "$BIN" | awk '/ _ZN12mips3_device18code_compile_blockEhj$/ {print $2; exit}')
  [ -n "$OFF" ] || {
    echo "blockrate: no code_compile_block symbol in $BIN (stripped?)" >&2
    exit 1
  }
  NAME="blockrate_$$"
  echo "p:$NAME/ccb $BIN:0x$OFF" >>$T/uprobe_events || exit 1
  # Remove only OUR probes. Truncating uprobe_events wholesale also removes
  # probes belonging to other agents on this shared box.
  trap 'echo "-:'"$NAME"'/ccb" >>'"$T"'/uprobe_events 2>/dev/null' EXIT
  perf stat -x, -e "$NAME:ccb,cycles,task-clock" -p "$PID" -- sleep "$SECS"
  exit 0
fi

PID=${1:-}
SECS=${2:-30}
[ -n "$PID" ] || usage
perf stat -x, -e syscalls:sys_enter_openat,syscalls:sys_enter_read,cycles,task-clock \
  -p "$PID" -- sleep "$SECS"
