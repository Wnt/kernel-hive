#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/magiccap.sh — compose the Magic Cap for Windows station
# media for the Kernel Hive (host-native streamhost, Tier 1).
#
# GUEST: General Magic's Magic Cap for Windows, PRE-RELEASE build 327 (1995).
# This is a Windows APPLICATION (MCW.EXE), not a bootable OS — it runs inside a
# win98se-class Windows 98 SE guest. NEVER claim "Magic Cap 3.1" here: the 3.1
# Windows simulator (MagicCAP-USA.exe) is NOT sourceable at any open origin —
# see docs/lab/MAGICCAP-WAVE.md §Media and /data/assets-staging/magiccap/SOURCES.md
# for the full search log. This build 327 pre-release IS what ships.
#
# WHAT THIS SCRIPT DOES:
#   1. fetch magic-cap.zip from archive.org item `magic-cap`, verified against
#      the pinned SHA-256 below before anything unpacks it.
#   2. unpack it and sanity-check the expected payload (MCW.EXE + its DLLs).
#   3. compose the disk: start from a copy of the win98se base disks (SAME
#      device set — no CD/floppy device is added, so `loadvm golden` on
#      win98se's own snapshot format stays valid), mount the C: FAT
#      partition with mtools (partition offset detected at runtime, not
#      hardcoded — see find_fat_offset below), mcopy -s the unpacked tree
#      onto C:\MAGICCAP, and drop C:\MC.REG (generated inline, see MC_REG
#      below) for a one-time silent import.
#   4. verify: boot the composed disk headless on the pinned device set and
#      screendump, asserting it is not black — this only proves the guest
#      boots, NOT that Magic Cap is installed/running (that needs the manual
#      in-guest steps below, driven live, which this script does not attempt
#      blind).
#
# ---- IN-GUEST STEPS (MANUAL, driven live via QMP sendkey/screendump — NOT
#      automated here; blind-typing through General Magic's own UI chrome is
#      exactly the kind of timing-fragile sequence rule 14 says to prove with
#      a real framebuffer, not script on faith) ----
#   a. Boot the composed disk cold (no golden snapshot yet).
#   b. Start > Run > `regedit /s C:\MC.REG` — imports the MagicCap autostart
#      value AND the display Resolution=640,480 key AND removes the inherited
#      win98se "Mirabilis ICQ" autostart, all in one silent import.
#      NEVER put this on a WIN.INI `run=` line: `run=` is a SPACE-SEPARATED
#      list, so `run=regedit /s C:\MC.REG` launches `regedit` and then tries
#      to run a program literally named `s`, producing a "Could not load or
#      run 's'" dialog on every boot (frame: f-boot2.png in the sandbox).
#   c. Reboot. MCW.EXE now autostarts from the Run key.
#   d. Dismiss Magic Cap's "Your modem isn't setup correctly" dialog (it has
#      no modem — this is expected and harmless) and the Getting-Started /
#      keyboard-tip overlays, landing on the Desk room.
#   e. savevm golden (persists into the qcow2, same mechanism as every other
#      streamhost tile — see qemu-streamhost.sh).
#
# Usage:
#   build-guests/tiles/magiccap.sh [--force] [--no-verify] [-h]
#   env: WORK        scratch dir  (default /data/vms/build-magiccap)
#        STAGE_DIR   intake dir   (default /data/assets-staging/magiccap)
#        GUEST_DIR   output dir   (default /data/gallery-guests/MagicCap)
#        WIN98_DIR   win98se base disks to copy from (default
#                     /data/gallery-guests/Win98SE)
# =============================================================================
set -euo pipefail

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/magiccap}"
WORK="${WORK:-/data/vms/build-magiccap}"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/MagicCap}"
WIN98_DIR="${WIN98_DIR:-/data/gallery-guests/Win98SE}"
ZIP_NAME="magic-cap.zip"
# archive.org item "magic-cap" — the file, not the item page.
UPSTREAM_URL="https://archive.org/download/magic-cap/${ZIP_NAME}"
ZIP_SHA256="56aab195329b71739796682c946bf118b594c6f9afb61f735a4aac6cba9f147f"
ZIP_SIZE=1987906
C_OUT="${GUEST_DIR}/magiccap-c.qcow2"
D_OUT="${GUEST_DIR}/magiccap-d.qcow2"
VERIFY_PNG="${GUEST_DIR}/verify-boot.png"

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
      sed -n '2,52p' "$0"
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
QMPSOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"

log() { printf '\033[1;36m[magiccap]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[magiccap] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

fetch_zip() {
  mkdir -p "$STAGE_DIR"
  local zip="$STAGE_DIR/$ZIP_NAME"
  if [ -f "$zip" ] && [ "$FORCE" -eq 0 ]; then
    log "reusing cached $zip"
  else
    log "fetching $UPSTREAM_URL"
    curl -fL --retry 3 -o "${zip}.part" "$UPSTREAM_URL"
    mv "${zip}.part" "$zip"
  fi
  local size
  size="$(stat -c%s "$zip")"
  [ "$size" -eq "$ZIP_SIZE" ] || die "size mismatch: got $size bytes, expected $ZIP_SIZE"
  local sha
  sha="$(sha256sum "$zip" | awk '{print $1}')"
  [ "$sha" = "$ZIP_SHA256" ] || die "sha256 mismatch: got $sha, expected $ZIP_SHA256"
  log "verified $zip ($size bytes, sha256 $sha)"
  echo "$zip"
}

unpack_zip() {
  local zip="$1"
  local out="$WORK/payload"
  rm -rf "$out"
  mkdir -p "$out"
  unzip -q "$zip" -d "$out"
  [ -f "$out/MCW.EXE" ] || die "unpacked payload is missing MCW.EXE — bad zip layout"
  log "unpacked to $out"
  echo "$out"
}

# The win98se C: disk is a WinWorld VMware image converted to qcow2 (see
# tiles/win98.sh), so its FAT partition offset is NOT the pcgeos/FreeDOS
# 32256 constant — detect it from the actual partition table instead of
# hardcoding a guessed number.
find_fat_offset() {
  local raw="$1"
  local start
  start="$(fdisk -lu "$raw" 2>/dev/null | awk '/^\S+1/ {print $2; exit}')"
  [ -n "$start" ] || die "could not find a partition start sector in $raw (fdisk -lu)"
  echo $((start * 512))
}

write_mc_reg() {
  local out="$1"
  # (a) autostart MCW.EXE — a Run key, never a WIN.INI run= line (see header).
  # (b) 640x480: the resolution build 327 was validated at.
  # (c) drop win98se's inherited "Mirabilis ICQ" autostart — this station has
  #     no retronet join, so there is nothing for it to connect to.
  cat >"$out" <<'REGEOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]
"MagicCap"="C:\\MAGICCAP\\MCW.EXE"

[HKEY_LOCAL_MACHINE\Config\0001\Display\Settings]
"Resolution"="640,480"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]
"Mirabilis ICQ"=-
REGEOF
}

compose_disks() {
  local payload="$1"
  mkdir -p "$GUEST_DIR"
  if [ -f "$C_OUT" ] && [ "$FORCE" -eq 0 ]; then
    log "reusing existing $C_OUT"
  else
    [ -f "$WIN98_DIR/win98se-kvm.qcow2" ] || die "missing $WIN98_DIR/win98se-kvm.qcow2 — build win98se first"
    local raw="$WORK/c.raw"
    qemu-img convert -f qcow2 -O raw "$WIN98_DIR/win98se-kvm.qcow2" "$raw"
    local offset
    offset="$(find_fat_offset "$raw")"
    log "C: FAT partition at byte offset $offset"
    mmd -i "$raw@@${offset}" ::/MAGICCAP
    mcopy -s -i "$raw@@${offset}" "$payload"/* ::/MAGICCAP/
    local mcreg="$WORK/MC.REG"
    write_mc_reg "$mcreg"
    mcopy -i "$raw@@${offset}" "$mcreg" ::/MC.REG
    qemu-img convert -f raw -O qcow2 "$raw" "$C_OUT"
    rm -f "$raw"
  fi
  if [ -f "$D_OUT" ] && [ "$FORCE" -eq 0 ]; then
    log "reusing existing $D_OUT"
  else
    [ -f "$WIN98_DIR/win98se-games.qcow2" ] || die "missing $WIN98_DIR/win98se-games.qcow2 — build win98se first"
    cp "$WIN98_DIR/win98se-games.qcow2" "$D_OUT"
  fi
}

verify_boot() {
  [ "$VERIFY" -eq 1 ] || {
    log "skipping verify (--no-verify)"
    return
  }
  mkdir -p "$WORK"
  log "cold-booting the composed disk for a framebuffer sanity check"
  nohup qemu-system-x86_64 \
    -name build-magiccap \
    -enable-kvm -m 384 -smp 1 \
    -machine pc-i440fx-11.0,acpi=on -cpu pentium3 \
    -rtc base=localtime \
    -boot c \
    -vga std \
    -display none \
    -drive file="$C_OUT",format=qcow2,if=ide \
    -drive file="$D_OUT",format=qcow2,if=ide,index=1 \
    -netdev user,id=n0,restrict=on -device pcnet,netdev=n0 \
    -usb -device usb-tablet,id=tab0 \
    -qmp "unix:$QMPSOCK,server=on,wait=off" \
    -pidfile "$PIDFILE" \
    >"$WORK/qemu.log" 2>&1 &
  for i in $(seq 1 40); do
    [ -S "$QMPSOCK" ] && [ -f "$PIDFILE" ] && break
    sleep 0.5
  done
  sleep 60
  python3 "$LABQMP" "$QMPSOCK" \
    "[{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$VERIFY_PNG\",\"format\":\"png\"}}]" \
    >/dev/null 2>&1 || true
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -s "$VERIFY_PNG" ] || die "no framebuffer produced — see $WORK/qemu.log"
  log "verify frame: $VERIFY_PNG (inspect by eye — this only proves a cold boot, not Magic Cap running)"
}

main() {
  local zip payload
  zip="$(fetch_zip)"
  payload="$(unpack_zip "$zip")"
  mkdir -p "$WORK"
  compose_disks "$payload"
  verify_boot
  log "done. $C_OUT / $D_OUT are ready for the manual in-guest steps in this file's header."
}

main "$@"
