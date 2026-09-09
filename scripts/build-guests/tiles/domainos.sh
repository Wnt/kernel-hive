#!/bin/bash
# Build the domainos station: Apollo DN3500 running Domain/OS SR10.4.1, host-
# native on MAME's dn3500 driver, pinned to mame0276 (native.d/domainos.sh —
# see its header for why, and docs/lab/DOMAINOS-WAVE.md "wall 1").
#
# Three things this script does, in order:
#   1. stage the boot ROMs (bitsavers.org/bits/Apollo/firmware)
#   2. build the station binary via build-mame-native.sh domainos
#   3. compose the STATION DISK from the pristine Domain/OS 10.4.1 winchester
#      image: the pristine image halts at the boot ROM's "more than 14 days
#      since last shutdown" CALENDAR check, and the fix (proven this wave,
#      docs/lab/DOMAINOS-WAVE.md wall 2) is to boot it ONCE in Service mode
#      and answer the CALENDAR program. That output disk, not the pristine
#      one, is what the station ships.
#
# Usage: domainos.sh [--no-gate]
#   SKIP_BUILD=1   don't run build-mame-native.sh (use an already-built binary)
#   SKIP_CALENDAR=1  don't run the CALENDAR compose step (leave the pristine
#                    disk unconverted -- the station cannot boot without it)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OS_ID="domainos"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/$OS_ID/roms}"
MEDIA_STAGE_DIR="${MEDIA_STAGE_DIR:-/data/vms/sandbox/domainos/media}"
INSTALL_DIR="${INSTALL_DIR:-/data/vms/streamhost/assets/$OS_ID/media}"
WORK="${WORK:-/data/vms/build-domainos-media}"
BUILD_WORK="${BUILD_WORK:-/data/vms/sandbox/BUILD-native-domainos276}"
BINARY="${BINARY:-/data/vms/streamhost/assets/$OS_ID/mame-native/domainos}"
GATE=1
[[ "${1:-}" == "--no-gate" ]] && GATE=0

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# ------------------------------------------------------------- ROM staging ---
# Origin bitsavers.org/bits/Apollo/firmware (browsable directory, no UA block
# encountered live 2026-09-09, but a UA header is set anyway -- some bitsavers
# mirrors 403 a bare-curl UA). The boot PROM and the 3C505 card's five-file
# firmware set (packed as 3c505.zip on bitsavers; unpacked here). Filenames on
# bitsavers are UPPERCASE; stage-romset.py matches by SHA1 content against
# MAME's own -listxml, not by filename, so casing here is cosmetic --
# kept lowercase to match the wave's roms-flat staging directory.
UA="Mozilla/5.0 (X11; Linux x86_64) kernel-hive-lab/1.0"
BASE_URL="https://bitsavers.org/bits/Apollo/firmware"

# name-in-staging -> (source URL, sha256). 3500_boot is a direct file; the
# other five come out of 3c505.zip (fetched once, unpacked into place).
BOOT_SHA256="7f1028f990027eead992204003dc85a6f411484e8a851af677db5dbe4a630584"
declare -A ZIP_SHA256=(
  ["0729-12_a.3h"]="ae898709d39eb5ce2eb44d5213fc53b942737df233d384215c7d119d9376c178"
  ["0729-62_a.3f"]="a831b805d03af895cbf4868bf1c17f8af0b195eafd795215e7eb1882002eb82f"
  ["3000_3c505_010728-00.bin"]="9983cc0274a4b1976a7278da80790f15561a44a0d23a9a4c88e8fbfd7436df8d"
  ["3com.9h"]="0b53f3bea9b0d9900c684ce162c6cfad5150add23c953e1b890dc9c363adab9b"
  ["apollo.9h"]="3e6a3270f5b0676c1cea9f5e52371990873272cbb400ffc571ab9404770b7e23"
)
# Fallback copy if bitsavers is unreachable from this box (the sandbox media
# dir the wave already populated) -- same content, same hashes, verified.
FALLBACK_DIR="${DOMAINOS_ROM_FALLBACK:-/data/vms/sandbox/domainos/media/roms-flat}"

verify_sha256() {
  local f="$1" want="$2" got
  got="$(sha256sum "$f" | awk '{print $1}')"
  [[ "$got" == "$want" ]]
}

stage_one_rom() {
  local dest="$1" want_sha="$2" url="$3" fallback_name="$4"
  if [[ -f "$dest" ]] && verify_sha256 "$dest" "$want_sha"; then
    log "already staged, sha256 matches: $(basename "$dest")"
    return 0
  fi
  if [[ -n "$url" ]] && curl -fsSL -A "$UA" -o "$dest.part" "$url" 2>/dev/null &&
    verify_sha256 "$dest.part" "$want_sha"; then
    mv "$dest.part" "$dest"
    log "fetched from bitsavers: $(basename "$dest")"
    return 0
  fi
  rm -f "$dest.part"
  log "bitsavers unreachable or hash mismatch for $(basename "$dest") -- falling back to staged copy"
  local fb="$FALLBACK_DIR/$fallback_name"
  [[ -f "$fb" ]] || die "no fallback either: $fb"
  verify_sha256 "$fb" "$want_sha" || die "fallback copy $fb has the wrong sha256"
  cp -f "$fb" "$dest"
}

stage_roms() {
  mkdir -p "$STAGE_DIR"
  stage_one_rom "$STAGE_DIR/3500_boot_12191_7.bin" "$BOOT_SHA256" \
    "$BASE_URL/3500_BOOT_12191_7.bin" "3500_boot_12191_7.bin"

  # The 3c505 set: try the zip once, unpack whatever members are missing;
  # each member is independently hash-verified before it is trusted.
  local need=0 name
  for name in "${!ZIP_SHA256[@]}"; do
    if [[ ! -f "$STAGE_DIR/$name" ]] || ! verify_sha256 "$STAGE_DIR/$name" "${ZIP_SHA256[$name]}"; then
      need=1
    fi
  done
  if [[ "$need" == 1 ]]; then
    local zip="$WORK/3c505.zip"
    mkdir -p "$WORK"
    if curl -fsSL -A "$UA" -o "$zip" "$BASE_URL/3c505.zip" 2>/dev/null; then
      local tmp="$WORK/3c505-unpack"
      rm -rf "$tmp"
      mkdir -p "$tmp"
      unzip -o -q "$zip" -d "$tmp" || log "3c505.zip did not unpack cleanly"
      for name in "${!ZIP_SHA256[@]}"; do
        [[ -f "$STAGE_DIR/$name" ]] && verify_sha256 "$STAGE_DIR/$name" "${ZIP_SHA256[$name]}" && continue
        if [[ -f "$tmp/$name" ]] && verify_sha256 "$tmp/$name" "${ZIP_SHA256[$name]}"; then
          cp -f "$tmp/$name" "$STAGE_DIR/$name"
          log "fetched from bitsavers 3c505.zip: $name"
        fi
      done
    else
      log "bitsavers 3c505.zip unreachable"
    fi
    # Anything still missing/wrong falls back to the staged flat copies.
    for name in "${!ZIP_SHA256[@]}"; do
      [[ -f "$STAGE_DIR/$name" ]] && verify_sha256 "$STAGE_DIR/$name" "${ZIP_SHA256[$name]}" && continue
      local fb="$FALLBACK_DIR/$name"
      [[ -f "$fb" ]] || die "no fallback for $name: $fb"
      verify_sha256 "$fb" "${ZIP_SHA256[$name]}" || die "fallback copy $fb has the wrong sha256"
      cp -f "$fb" "$STAGE_DIR/$name"
      log "used staged fallback: $name"
    done
  else
    log "3c505 set already staged, all sha256 match"
  fi
  (cd "$STAGE_DIR" && sha256sum -- * >MANIFEST.sha256) || true
}

# --------------------------------------------------------------- binary ---
build_binary() {
  if [[ "${SKIP_BUILD:-0}" == 1 ]]; then
    log "SKIP_BUILD=1 -- not running build-mame-native.sh"
    [[ -x "$BINARY" ]] || die "SKIP_BUILD=1 but no binary at $BINARY"
    return 0
  fi
  DOMAINOS_ROM_STAGING="$STAGE_DIR" JOBS="${JOBS:-6}" \
    "$REPO/scripts/build-guests/emulators/build-mame-native.sh" domainos "$BUILD_WORK" "$BINARY"
}

# ------------------------------------------------- CALENDAR disk compose ---
# The pristine winchester image domain_os_10.4.1.awd halts Normal-mode boot
# at the boot ROM's 14-day CALENDAR check. Fix (proven, docs/lab/DOMAINOS-
# WAVE.md wall 2): boot it ONCE in Service mode (apollo_config mask 1 value
# 0) and run CALENDAR through the MD prompt -- the MD does baud recognition
# on the first Return, so Return must be pressed 2-3 times before typing
# lands. This mirrors /data/vms/sandbox/domainos/cal276b/t.lua, the exact
# recipe that produced the proven disk.awd this wave.
PRISTINE_AWD="$MEDIA_STAGE_DIR/domainos.awd"
PRISTINE_SHA256="9f9ae29c56e456e2520d9107ea2fc30eb8f0dae2d46f6475cc7aa3a92db1f917"
PRISTINE_BYTES=348701760

compose_calendar_disk() {
  [[ -f "$PRISTINE_AWD" ]] || die "pristine winchester image missing: $PRISTINE_AWD"
  [[ "$(stat -c %s "$PRISTINE_AWD")" == "$PRISTINE_BYTES" ]] ||
    die "pristine winchester image is the wrong size (not $PRISTINE_BYTES bytes)"
  verify_sha256 "$PRISTINE_AWD" "$PRISTINE_SHA256" ||
    die "pristine winchester image sha256 mismatch"
  [[ -x "$BINARY" ]] || die "no station binary at $BINARY -- build first"

  local calwork="$WORK/cal"
  rm -rf "$calwork"
  mkdir -p "$calwork/cfg" "$calwork/nvram"
  cp -f "$PRISTINE_AWD" "$calwork/disk.awd"
  printf 'skip_warnings 1\n' >"$calwork/ui.ini"
  cat >"$calwork/apollo_config.cfg" <<'CFG'
<?xml version="1.0"?>
<mameconfig version="10">
	<system name="dn3500">
		<input>
			<port tag=":apollo_config" type="CONFIG" mask="1" defvalue="0" value="0"/>
		</input>
	</system>
</mameconfig>
CFG
  mkdir -p "$calwork/cfg"
  cp -f "$calwork/apollo_config.cfg" "$calwork/cfg/dn3500.cfg"

  # Adapted from /data/vms/sandbox/domainos/cal276b/t.lua (proven this wave):
  # wait ~32s for the MD '>' prompt, press Return 2-3 times (baud
  # recognition), then EX CALENDAR, W, N, Y answering its questions.
  cat >"$calwork/t.lua" <<'LUAEOF'
local function snap() manager.machine.video:snapshot() end
local P = manager.machine.ioport.ports
local function bymask(port,mask) for _,f in pairs(P[port].fields) do if f.mask==mask then return f end end end
local function key(port,name) for _,f in pairs(P[port].fields) do if f.name==name then return f end end end
local ret = bymask(":kbd:keyboard1",0x20000000)
local sp = key(":kbd:keyboard2","Space")
local function press(f,t,g) if not f then print("NILKEY") return end f:set_value(1); emu.wait(t or 0.25); f:set_value(0); emu.wait(g or 0.35) end
local function typ(s) for i=1,#s do local c=s:sub(i,i)
  if c==" " then press(sp) elseif c=="\n" then press(ret,0.3,0.8)
  else local u=c:upper(); press(key(":kbd:keyboard1",u) or key(":kbd:keyboard2",u)) end
end end
emu.wait(32)
for i=1,3 do press(ret,0.3,1.5) end
typ("EX CALENDAR\n"); emu.wait(25)
typ("W\n"); emu.wait(8); snap()
typ("N\n"); emu.wait(6); snap()
typ("Y\n"); emu.wait(8); snap()
typ("\n"); emu.wait(6); snap()
typ("Y\n"); emu.wait(8); snap()
typ("\n"); emu.wait(10); snap()
emu.wait(1)
manager.machine:soft_reset()
LUAEOF

  log "running CALENDAR once in Service mode (emulated ~2 min) ..."
  (
    cd "$calwork" &&
      "$BINARY" dn3500 -rompath "$STAGE_DIR" -isa1 wdc -isa2 ctape -isa3 3c505 \
        -disk1 disk.awd -sound none -nothrottle -seconds_to_run 120 -skip_gameinfo \
        -homepath . -cfg_directory ./cfg -nvram_directory ./nvram -inipath . \
        -autoboot_script t.lua \
        >"$calwork/mame.log" 2>&1
  ) || die "CALENDAR compose run exited non-zero; see $calwork/mame.log"

  mkdir -p "$INSTALL_DIR/nvram"
  cp -f "$calwork/disk.awd" "$INSTALL_DIR/disk.awd"
  cp -rf "$calwork/nvram/." "$INSTALL_DIR/nvram/"
  log "station disk composed: $INSTALL_DIR/disk.awd ($(stat -c %s "$INSTALL_DIR/disk.awd") bytes)"
}

mkdir -p "$WORK"
stage_roms
build_binary
if [[ "${SKIP_CALENDAR:-0}" == 1 ]]; then
  log "SKIP_CALENDAR=1 -- not composing the station disk (pristine disk left unconverted)"
else
  compose_calendar_disk
fi

log "done"
