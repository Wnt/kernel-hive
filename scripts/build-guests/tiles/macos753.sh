#!/bin/bash
# macos753 — Mac OS 7.5.3 on a Motorola 68040 Quadra 800 (qemu-system-m68k).
#
# THE FIRST FOREIGN-ARCHITECTURE QEMU STATION IN THE FLEET, so this builder does
# two things no other builder here does: it builds its own QEMU, and it drives a
# guest that has NO absolute pointer and NO command line whatsoever. Every state
# below is reached by clicking, and every click is closed-loop against the
# framebuffer (scripts/install-vision/adb_pointer.py).
#
# PROVENANCE OF THIS SCRIPT: the recipe encoded here was performed step by step
# against a live clone on 2026-08-16, and every coordinate, timing and hash is
# taken from that run — including the ones that cost a rebuild to learn. The
# script itself has NOT yet been executed end to end in one pass; the shipped
# checkpoint came from the interactive run. Treat the first `--all` run as a
# verification of this file, keep its evidence, and fix what drifts.
#
# --------------------------------------------------------------------------
# THE FOUR TRAPS, in the order they bite
# --------------------------------------------------------------------------
# 1. `-boot d` DOES NOTHING on q800. The boot device is a PRAM patch: write
#    ffff + ~(scsi_id + 32) big-endian at offset 120. HD is SCSI 6, CD is 3.
# 2. QEMU REFUSES TO START without an audiodev bound to the machine — the Apple
#    Sound Chip is not optional ("Initializing audio stream failed").
# 3. Apple HD SC Setup's surface verify runs at ~145 KB/s under TCG and scales
#    with the WHOLE DRIVE. A 2 GB image takes ~4 hours. So the disk is created
#    SMALL, initialized, and only then grown — see `phase_disk`.
# 4. `savevm` REFUSES while the PRAM is a raw if=mtd drive ("Device 'mtd0' is
#    writable but does not support snapshots"). It must be qcow2.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
VISION="$REPO/scripts/install-vision"
# shellcheck source=/dev/null
. "$REPO/scripts/build-guests/lib/media-cache.sh"

OS_ID="macos753"
WORK="${WORK:-/data/vms/sandbox/build-$OS_ID}"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
EVIDENCE="$WORK/evidence"
QEMU_PREFIX="${QEMU_PREFIX:-/opt/qemu-m68k}"
QEMU="$QEMU_PREFIX/bin/qemu-system-m68k"
FORK_URL="${FORK_URL:-https://github.com/Wnt/qemu.git}"
FORK_BRANCH="${FORK_BRANCH:-kernel-hive}"

ROM_SHA=05ad753fb594e656cf078023ec189e09e2a7655a780de993b75b8c51ed6b09ca
ROM_URL=https://archive.org/download/800_20250604/800.ROM
CD_ZIP_SHA=b65d41bd44d9b5543e124f51aa9507749a834d5e06857dd441a203e50a9e19dc
CD_ZIP_URL="https://archive.org/download/Macintosh-68K-PPC-System-7.5.3-Bootable-ISO/System753%20691-1079-A.zip"

# Disk sizing: created small so trap 3 costs minutes, grown after the driver
# partition exists. 1900M keeps the boot partition under the 2 GB limit that
# Mac OS 7.5.x imposes, with room for apps and games.
INIT_MB=300
FINAL_MB=1900
GEOMETRY=1152x870x8

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
pointer() { python3 "$VISION/adb_pointer.py" --qmp "$QMP" --extent 1200 "$@"; }
shot() { pointer shot "$EVIDENCE/$1.png" >/dev/null; }

# Every kill routes through the guard; never pkill, never a bare kill.
kill_guest() {
  [ -f "$PIDFILE" ] || return 0
  clone-guard kill-pidfile "$PIDFILE" || die "clone-guard refused the kill"
  sleep 2
}

# A clean guest shutdown, which is NOT optional: an unclean stop makes the next
# cold boot open on "This computer may not have been shut down properly", and a
# checkpoint baked then captures THE DIALOG as the exhibit's opening scene.
guest_shutdown() {
  log "guest: Special -> Shut Down"
  pointer menu 231 10 260 140 >/dev/null
  sleep 30
  kill_guest
}

launch() {
  local boot_scsi="$1" extra="${2:-}"
  rm -f "$QMP" "$PIDFILE"
  python3 - "$WORK/pram.qcow2" "$boot_scsi" <<'PY'
import subprocess, sys, tempfile, os
pram, scsi = sys.argv[1], int(sys.argv[2])
# PRAM boot selection (trap 1). Written through qemu-nbd so the qcow2 stays a
# qcow2 -- `qemu-img dd` writes a RAW image and would destroy the header.
value = (~(scsi + 32)) & 0xFFFF
patch = bytes([0xFF, 0xFF, (value >> 8) & 0xFF, value & 0xFF])
subprocess.run(["qemu-nbd", "--disconnect", "/dev/nbd0"], capture_output=True)
subprocess.run(["qemu-nbd", "-c", "/dev/nbd0", "-f", "qcow2", pram], check=True)
try:
    with open("/dev/nbd0", "r+b") as fh:
        fh.seek(120)
        fh.write(patch)
        fh.flush()
        os.fsync(fh.fileno())
finally:
    subprocess.run(["qemu-nbd", "--disconnect", "/dev/nbd0"], check=True)
PY
  # shellcheck disable=SC2086 # $extra must word-split into flags (or vanish)
  nohup "$QEMU" \
    -name "build-$OS_ID" \
    -accel tcg -m 128 \
    -M q800,audiodev=snd0 -cpu m68040 \
    -audiodev none,id=snd0 \
    -bios "$WORK/800.ROM" \
    -g "$GEOMETRY" \
    -display none -serial null \
    -drive file="$WORK/pram.qcow2",format=qcow2,if=mtd \
    -device scsi-hd,scsi-id=6,drive=hd0 \
    -drive file="$WORK/disk.qcow2",format=qcow2,cache=writeback,aio=threads,if=none,id=hd0 \
    $extra \
    -qmp unix:"$QMP",server=on,wait=off -pidfile "$PIDFILE" \
    >"$WORK/qemu.log" 2>&1 &
  for _ in $(seq 1 60); do
    [ -S "$QMP" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] || die "QEMU did not come up; see $WORK/qemu.log"
}

cdrom_args() {
  printf -- '-device scsi-cd,scsi-id=3,drive=cd0 -drive file=%s,format=raw,cache=writeback,if=none,media=cdrom,id=cd0' \
    "$WORK/macos753.iso"
}

# --------------------------------------------------------------------------
phase_qemu() {
  [ -x "$QEMU" ] && {
    log "qemu-system-m68k already at $QEMU"
    return 0
  }
  log "building qemu-system-m68k from $FORK_URL@$FORK_BRANCH"
  local src="$WORK/qemu-src"
  [ -d "$src" ] || git clone -q --branch "$FORK_BRANCH" --depth 1 "$FORK_URL" "$src"
  mkdir -p "$src/build"
  (cd "$src/build" && ../configure \
    --target-list=m68k-softmmu --enable-slirp --enable-dbus-display \
    --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
    --disable-opengl --disable-werror --disable-tools --prefix="$QEMU_PREFIX" \
    >"$WORK/configure.log" 2>&1) || die "configure failed; see $WORK/configure.log"
  (cd "$src/build" && nice -n 15 ninja qemu-system-m68k >"$WORK/ninja.log" 2>&1) ||
    die "build failed; see $WORK/ninja.log"
  install -Dm755 "$src/build/qemu-system-m68k" "$QEMU"
  # The fork's fast-poll patch must survive on a non-x86 target; it is
  # arch-neutral (ui/console.c + ui/dbus-listener.c) but assume nothing.
  strings "$QEMU" | grep -q SH_DBUS_UPDATE_MS ||
    die "built binary carries no SH_DBUS_UPDATE_MS: the fork patch did not apply"
  "$QEMU" -M help | grep -q '^q800' || die "built binary has no q800 machine"
  log "built and verified $QEMU"
}

phase_media() {
  mkdir -p "$WORK" "$EVIDENCE"
  media_cache_require "sha256:$ROM_SHA" "$WORK/800.ROM" "quadra800-rom" "$ROM_URL" ||
    die "Quadra 800 ROM unavailable"
  local zip="$WORK/system753.zip"
  media_cache_require "sha256:$CD_ZIP_SHA" "$zip" "macos753-cd" "$CD_ZIP_URL" ||
    die "Mac OS 7.5.3 CD unavailable"
  [ -f "$WORK/macos753.iso" ] || {
    unzip -o -q "$zip" -d "$WORK/iso"
    mv "$WORK/iso/System753 691-1079-A.iso" "$WORK/macos753.iso"
  }
  log "media staged"
}

# Phase A: the driver partition. Apple HD SC Setup is involved for exactly one
# reason -- it writes the Apple_Driver43 partition the ROM needs in order to
# boot the disk at all. Its own partitioning is discarded in phase_grow.
phase_init_disk() {
  log "creating a ${INIT_MB}M disk (small ON PURPOSE -- trap 3)"
  rm -f "$WORK/disk.qcow2" "$WORK/pram.qcow2"
  qemu-img create -q -f qcow2 "$WORK/disk.qcow2" "${INIT_MB}M"
  qemu-img create -q -f qcow2 "$WORK/pram.qcow2" 256
  launch 3 "$(cdrom_args)"
  sleep 75
  shot a0-cd-desktop
  log "Disk Tools -> Apple HD SC Setup (select + Command-O; double-clicks are unreliable over ADB)"
  pointer open 207 143 >/dev/null
  sleep 6
  pointer open 63 163 >/dev/null
  sleep 12
  shot a1-hdsc
  pointer click 244 113 >/dev/null # Initialize
  sleep 3
  pointer click 430 195 >/dev/null # confirm Init
  log "initializing (~4 min at ${INIT_MB}M; this is the surface verify)"
  sleep 260
  pointer key m a c i n t o s h >/dev/null # volume name, then accept
  pointer key ret >/dev/null
  sleep 8
  shot a2-initialized
  guest_shutdown
}

# Phase B: grow the image and extend the Apple Partition Map over the new space,
# then let Finder's INSTANT erase lay HFS across all of it. This is what buys
# a 1900 MB volume for the cost of initializing 300 MB.
phase_grow() {
  log "growing to ${FINAL_MB}M and extending the partition map"
  qemu-img resize "$WORK/disk.qcow2" "${FINAL_MB}M"
  qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
  qemu-nbd -c /dev/nbd0 -f qcow2 "$WORK/disk.qcow2"
  python3 - <<'PY' || {
import os, struct
fh = open("/dev/nbd0", "r+b")
data = bytearray(fh.read(64 * 512))
total = os.lseek(fh.fileno(), 0, os.SEEK_END) // 512
os.lseek(fh.fileno(), 0, os.SEEK_SET)
assert data[0:2] == b"ER", "no Apple driver descriptor: phase_init_disk did not run"
struct.pack_into(">I", data, 4, total)          # sbBlkCount
hfs = free = None
for i in range(1, 20):
    entry = data[i * 512:(i + 1) * 512]
    if entry[0:2] != b"PM":
        continue
    kind = entry[48:80].split(b"\x00")[0]
    if kind == b"Apple_HFS":
        hfs = i
    elif kind == b"Apple_Free":
        free = i
start = struct.unpack(">I", data[hfs * 512 + 8:hfs * 512 + 12])[0]
count = total - start
struct.pack_into(">I", data, hfs * 512 + 12, count)   # pmPartBlkCnt
struct.pack_into(">I", data, hfs * 512 + 84, count)   # pmDataCnt
if free is not None:
    data[free * 512:(free + 1) * 512] = b"\x00" * 512
for i in range(1, 20):
    if data[i * 512:i * 512 + 2] == b"PM":
        struct.pack_into(">I", data, i * 512 + 4, 3)  # pmMapBlkCnt
fh.write(bytes(data))
fh.flush()
os.fsync(fh.fileno())
fh.close()
print(f"HFS partition -> {count} blocks ({count * 512 / 1048576:.0f} MB)")
PY
    qemu-nbd --disconnect /dev/nbd0
    die "partition map patch failed"
  }
  sync
  qemu-nbd --disconnect /dev/nbd0
  launch 3 "$(cdrom_args)"
  sleep 80
  log "Special -> Erase Disk (instant: no surface scan)"
  pointer click 1110 52 >/dev/null
  pointer menu 231 10 260 91 >/dev/null
  sleep 3
  shot b1-erase-dialog
  pointer click 451 232 >/dev/null
  sleep 20
  shot b2-erased
}

phase_install() {
  log "Easy Install (~90 s once it starts copying)"
  pointer open 78 92 >/dev/null # System Software Installers
  sleep 6
  pointer open 94 213 >/dev/null # Install System Software
  sleep 25
  pointer key ret >/dev/null # Continue
  sleep 12
  pointer key ret >/dev/null # Install
  sleep 150
  shot c1-installed
  pointer key ret >/dev/null # Quit the installer
  sleep 6
  guest_shutdown
}

# Phase D: the settings the EXHIBIT depends on, not cosmetics.
#   * "Very Slow" mouse tracking is the only NON-accelerated setting Mac OS
#     offers; 1:1 pointing is unreachable under any other one.
#   * 32-bit addressing defaults OFF, which caps usable RAM at 8 MB of 128.
phase_configure() {
  launch 6
  sleep 80
  shot d0-first-boot
  log "Mouse control panel -> Very Slow tracking, slowest double-click"
  pointer open 1110 52 >/dev/null
  sleep 6
  pointer open 38 95 >/dev/null
  sleep 6
  pointer open 359 95 >/dev/null
  sleep 8
  pointer key m o u s e >/dev/null
  pointer chord o >/dev/null
  sleep 8
  pointer click 131 131 >/dev/null # Very Slow
  pointer click 186 188 >/dev/null # slowest double-click
  shot d1-mouse
  local gain
  gain=$(pointer gain)
  log "measured pointer $gain (station ships SH_CURSOR_SCALE from this)"
  echo "$gain" >"$EVIDENCE/pointer-gain.txt"
  case "$gain" in
    *cursor_scale=2.7*) : ;;
    *) log "WARNING: cursor_scale drifted from the shipped 2.7778 — update station.env.fixture" ;;
  esac
  pointer chord w >/dev/null
  sleep 2
  guest_shutdown
}

# Phase E: the checkpoint, on the PRODUCTION device set (dbus display + dbus
# audio), because a checkpoint is only valid for the device set it was baked on.
phase_checkpoint() {
  log "baking the checkpoint on the production device set"
  cp "$WORK/disk.qcow2" "$WORK/macos753-golden.qcow2"
  cp "$WORK/pram.qcow2" "$WORK/pram-golden.qcow2"
  rm -f "$QMP" "$PIDFILE"
  SH_DBUS_UPDATE_MS=4 nohup "$QEMU" \
    -name "build-$OS_ID-golden" \
    -accel tcg -m 128 \
    -M q800,audiodev=snd0 -cpu m68040 \
    -bios "$WORK/800.ROM" -g "$GEOMETRY" \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -drive file="$WORK/pram-golden.qcow2",format=qcow2,if=mtd \
    -device scsi-hd,scsi-id=6,drive=hd0 \
    -drive file="$WORK/macos753-golden.qcow2",format=qcow2,cache=writeback,aio=threads,if=none,id=hd0 \
    -qmp unix:"$QMP",server=on,wait=off -pidfile "$PIDFILE" \
    >"$WORK/golden.log" 2>&1 &
  for _ in $(seq 1 60); do
    [ -S "$QMP" ] && break
    sleep 0.5
  done
  sleep 90
  # The scene must be verified BEFORE it is frozen: if the previous stop was
  # unclean this frame is the improper-shutdown dialog, and baking it would
  # make that dialog the exhibit.
  shot e0-scene
  python3 - "$EVIDENCE/e0-scene.png" <<'PY' || die "scene is not the quiet desktop — refusing to bake"
import sys
import cv2
frame = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
# A dialog is a big bright rectangle in the middle of a grey desktop. The quiet
# scene has none: the central half of the screen is uniform desktop grey.
h, w = frame.shape
mid = frame[h // 4:3 * h // 4, w // 4:3 * w // 4]
bright = (mid > 200).mean()
print(f"central bright fraction {bright:.3f}")
sys.exit(0 if bright < 0.05 else 1)
PY
  python3 "$REPO/scripts/lib/labqmp.py" "$QMP" savevm golden ||
    die "savevm failed (is the PRAM a raw if=mtd drive? see trap 4)"
  log "checkpoint baked; proving the restore on the framebuffer"
  pointer click 1110 52 >/dev/null
  pointer chord o >/dev/null
  sleep 8
  shot e1-dirty
  python3 "$REPO/scripts/lib/labqmp.py" "$QMP" loadvm golden || die "loadvm failed"
  sleep 5
  shot e2-restored
  local dirty restored
  dirty=$(compare -metric AE "$EVIDENCE/e0-scene.png" "$EVIDENCE/e1-dirty.png" null: 2>&1 || true)
  restored=$(compare -metric AE "$EVIDENCE/e0-scene.png" "$EVIDENCE/e2-restored.png" null: 2>&1 || true)
  log "dirty=$dirty px  restored=$restored px"
  [ "${dirty:-0}" -gt 10000 ] || die "the dirty step changed nothing: the restore proof is vacuous"
  [ "${restored:-1}" -eq 0 ] || die "restore is not framebuffer-identical ($restored px differ)"
  kill_guest
  log "DONE: $WORK/macos753-golden.qcow2 + $WORK/pram-golden.qcow2"
}

main() {
  local phases=("$@")
  [ "${#phases[@]}" -eq 0 ] && phases=(--all)
  case "${phases[0]}" in
    --all)
      phase_qemu
      phase_media
      phase_init_disk
      phase_grow
      phase_install
      phase_configure
      phase_checkpoint
      ;;
    --qemu) phase_qemu ;;
    --media) phase_media ;;
    --disk)
      phase_init_disk
      phase_grow
      ;;
    --install) phase_install ;;
    --configure) phase_configure ;;
    --checkpoint) phase_checkpoint ;;
    *) die "usage: $0 [--all|--qemu|--media|--disk|--install|--configure|--checkpoint]" ;;
  esac
}

main "$@"
