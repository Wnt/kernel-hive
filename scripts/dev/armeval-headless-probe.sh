#!/usr/bin/env bash
# Headless MAME probe, ARMEVAL-armbasic angle.
# usage: probe.sh <tag> <snap-frames-csv> <run-seconds> <keyfile|-> [mame args...]
# keyfile lines: "<frame> <text to emu.keypost>"
set -euo pipefail
R=/data/vms/soltest/ARMEVAL-armbasic
MAME=/data/vms/streamhost/assets/bbcmicro/mame/bbcb
# The hash/ dir is MAME's software lists, and it lives in the build tree of the
# bbcb binary above -- i.e. in whichever suite chroot armeval is built for
# (registry/bridge-suites.json, docs/lab/BRIDGE-TRIXIE-MIGRATION.md). Derive it
# rather than hardcoding bookworm, so the probe follows the tile when it moves.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../build-guests/lib/bridge-suite.sh"
HASHPATH="$(bridge_mame_chroot_for "$(bridge_suite_for armeval)")/build/mame-bbcb/mame/hash"
TAG=$1
FRAMES=$2
SECS=$3
KEYS=$4
shift 4
OUT=$R/shots/$TAG
rm -rf "$OUT"
mkdir -p "$OUT/snap"
printf 'skip_warnings 1\n' >"$OUT/ui.ini"
{
  echo 'local want = {}'
  echo "for f in string.gmatch(\"$FRAMES\", \"[^,]+\") do want[tonumber(f)] = true end"
  echo 'local kq = {}'
  if [ "$KEYS" != "-" ]; then
    while read -r fr txt; do
      [ -z "$fr" ] && continue
      echo "kq[$fr] = \"$txt\""
    done <"$KEYS"
  fi
  cat <<'LUA'
local dbg = io.open("lua.log", "w")
local n = 0
_G.probe_sub = emu.add_machine_frame_notifier(function ()
  n = n + 1
  if n == 1 then
    local ok, err = pcall(function () manager.machine.natkeyboard.in_use = true end)
    dbg:write(string.format("natkbd in_use ok=%s err=%s\n", tostring(ok), tostring(err)))
    dbg:flush()
  end
  if kq[n] then
    local ok, err = pcall(function () manager.machine.natkeyboard:post_coded(kq[n]) end)
    dbg:write(string.format("post f=%d ok=%s err=%s\n", n, tostring(ok), tostring(err)))
    dbg:flush()
  end
  if want[n] then
    manager.machine.video:snapshot()
    dbg:write(string.format("snap f=%d\n", n))
    dbg:flush()
  end
end)
LUA
} >"$OUT/probe.lua"
cd "$OUT"
"$MAME" "$@" \
  -rompath "$R/roms" \
  -hashpath "$HASHPATH" \
  -video none -sound none -nothrottle -str "$SECS" \
  -skip_gameinfo \
  -homepath "$OUT" -cfg_directory "$OUT/cfg" -nvram_directory "$OUT/nvram" \
  -snapshot_directory "$OUT/snap" -inipath "$OUT" \
  -autoboot_script "$OUT/probe.lua" >"$OUT/mame.log" 2>&1 || true
find "$OUT/snap" -name '*.png' | sort
