#!/usr/bin/env bash
#===============================================================================
# build-guests/tiles/helenos.sh — reproduce the HelenOS Kernel Hive station from source
#===============================================================================
#
# GUEST : helenos
# OS    : HelenOS 0.14.1 "Aladar" (rev b3af08117), IA-32, BSD, built 2024-03-28
# MODEL : LIVE ISO. Boots directly to the compositor GUI. A small qcow2 disk is
#         attached only as a VM-state container for the production 'golden'
#         snapshot; the guest itself remains RAM-backed and read-only.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh Proxmox host w/ the gallery infra)
#   1. Re-DOWNLOADS the source ISO from the real upstream URL (www.helenos.org).
#   2. Creates a fresh 128 MiB qcow2 VM-state container (not a guest filesystem).
#   3. No install automation is needed — the ISO auto-boots to the compositor
#      with ZERO keystrokes (no bootloader prompt, no login). See "AUTOMATION".
#   4. No era-software injection — the live ISO already ships the compositor,
#      Terminal, taskbar + clock. There is nothing to add to a read-only medium.
#   5. Boots the exact production device set, framebuffer-gates on the blue
#      compositor + focused Terminal at '/ #', then runs `savevm golden`.
#   6. Atomically installs the verified state container as the station golden.
#
# AUTOMATION HONESTY
#   FULLY AUTOMATED — end to end, zero human interaction.
#   HelenOS's live ISO has no bootloader menu to dismiss, no installer, and no
#   login prompt: the kernel boots, ~20-30 s of text driver-init log scrolls,
#   then it AUTO-SWITCHES to the compositor desktop. Nothing to sendkey, no
#   answer file, no vncdotool clicks. This is the easiest guest in the gallery.
#
# IDEMPOTENT / RE-RUNNABLE
#   - ISO download is skipped if the file already exists with the exact expected
#     byte size (re-fetched otherwise). Pass FORCE_DOWNLOAD=1 to always refetch.
#   - Every invocation bakes a new container from an empty qcow2. The existing
#     golden is replaced only after the new internal snapshot is verified.
#   - The bake always tears QEMU down via monitor `quit` (or its pidfile) —
#     NEVER pkill-by-name. Safe to run repeatedly.
#
# HYGIENE (per gallery rules)
#   - Namespaced work dir: $OUT_DIR  (data/gallery-guests/HelenOS)
#   - Unique monitor socket + pidfile in the HelenOS output directory.
#   - Kills ONLY this script's own QEMU, by monitor `quit` then pidfile TERM.
#     Never touches other guests, CT 110, VM 900/920, or the macOS fan-out VMIDs.
#
# NEKO-QEMU PRODUCTION ARGS (what CT 110 actually serves — see end of script).
#===============================================================================

set -euo pipefail

#------------------------------------------------------------------------------
# Parameters (all overridable from the environment)
#------------------------------------------------------------------------------
KEY="${KEY:-helenos}"
GUEST_NAME="${GUEST_NAME:-HelenOS}"

# On-host storage root for gallery guests (ZFS dataset data/gallery-guests).
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
OUT_DIR="${OUT_DIR:-${GUESTS_ROOT}/${GUEST_NAME}}"

# Source ISO — real upstream release (verified 302 http -> https, 25792512 bytes,
# byte-for-byte identical to the ISO on the dry-run box).
ISO_VERSION="${ISO_VERSION:-0.14.1}"
ISO_ARCH="${ISO_ARCH:-ia32}"
ISO_NAME="${ISO_NAME:-HelenOS-${ISO_VERSION}-${ISO_ARCH}.iso}"
ISO_URL="${ISO_URL:-https://www.helenos.org/releases/${ISO_NAME}}"
ISO_EXPECTED_BYTES="${ISO_EXPECTED_BYTES:-25792512}" # sanity size check
ISO_PATH="${OUT_DIR}/${ISO_NAME}"

# Guest hardware: pinned to the production launcher's savevm-sensitive device set.
RAM_MB="${RAM_MB:-512}"
MACHINE="${MACHINE:-pc-i440fx-11.0}"
CPU_MODEL="${CPU_MODEL:-qemu32}"
VGA="${VGA:-std}" # Bochs VBE, 1024x768 software fb

# Golden-bake harness — unique, namespaced files (hygiene).
TILE_DIR="${TILE_DIR:-/data/vms/streamhost/tiles/${KEY}}"
GOLDEN_DISK="${GOLDEN_DISK:-${TILE_DIR}/golden.qcow2}"
GOLDEN_SIZE="${GOLDEN_SIZE:-128M}"
GOLDEN_TMP="${GOLDEN_DISK}.bake.$$"
PIDFILE="${OUT_DIR}/verify-qemu.pid"
MONSOCK="${OUT_DIR}/verify-monitor.sock"
QLOG="${OUT_DIR}/verify-qemu.log"
BAKE_TIMEOUT="${BAKE_TIMEOUT:-120}" # framebuffer-gated; typical KVM boot is ~35s
SHOT_PPM="${OUT_DIR}/gui-desktop.ppm"
SHOT_PNG="${OUT_DIR}/gui-desktop.png"

# The production launcher uses the x86_64 system binary with -cpu qemu32.
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

log() { printf '\033[1;36m[helenos]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[helenos][warn]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[helenos][err]\033[0m %s\n' "$*" >&2
  exit 1
}

#------------------------------------------------------------------------------
# Teardown — monitor `quit` first (clean), then pidfile TERM. NEVER pkill.
#------------------------------------------------------------------------------
mon() {
  # Send one HMP command to the QEMU monitor over its unix socket.
  # `-monitor unix:` speaks HMP; screendump/quit are HMP verbs.
  local cmd="$1"
  if command -v socat >/dev/null 2>&1; then
    printf '%s\n' "$cmd" | socat - "UNIX-CONNECT:${MONSOCK}" >/dev/null 2>&1 || return 1
  elif command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-U'; then
    printf '%s\n' "$cmd" | nc -U -q1 "${MONSOCK}" >/dev/null 2>&1 || return 1
  else
    return 2
  fi
}

teardown() {
  # Preferred: ask QEMU to quit via its monitor.
  mon "quit" 2>/dev/null || true
  sleep 1
  # Fallback: TERM the exact pid we recorded (pidfile only — never by name).
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
  fi
  rm -f "$MONSOCK"
}
cleanup() {
  teardown
  rm -f "$GOLDEN_TMP"
}
trap cleanup EXIT

#==============================================================================
# STEP 1 — prepare namespaced work dir
#==============================================================================
log "output dir: ${OUT_DIR}"
mkdir -p "$OUT_DIR"

#==============================================================================
# STEP 2 — (re)download the source ISO from the REAL upstream URL
#==============================================================================
need_dl=1
if [[ -f "$ISO_PATH" && "${FORCE_DOWNLOAD:-0}" != "1" ]]; then
  have="$(stat -c%s "$ISO_PATH" 2>/dev/null || stat -f%z "$ISO_PATH" 2>/dev/null || echo 0)"
  if [[ "$have" == "$ISO_EXPECTED_BYTES" ]]; then
    log "ISO present and correct size (${have} bytes) — skipping download"
    need_dl=0
  else
    warn "ISO present but size ${have} != expected ${ISO_EXPECTED_BYTES} — refetching"
  fi
fi

if [[ "$need_dl" == "1" ]]; then
  log "downloading ${ISO_URL}"
  tmp="${ISO_PATH}.part"
  rm -f "$tmp"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$ISO_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$tmp" "$ISO_URL"
  else
    die "need curl or wget to download the ISO"
  fi
  got="$(stat -c%s "$tmp" 2>/dev/null || stat -f%z "$tmp" 2>/dev/null || echo 0)"
  [[ "$got" == "$ISO_EXPECTED_BYTES" ]] ||
    warn "downloaded size ${got} != expected ${ISO_EXPECTED_BYTES} (upstream may have re-spun; continuing)"
  mv -f "$tmp" "$ISO_PATH"
  log "saved ${ISO_PATH} (${got} bytes)"
fi

#==============================================================================
# STEP 3 — create a fresh snapshot container
#   HelenOS still runs read-only from the LiveCD. This empty disk is attached
#   only because QEMU savevm needs a writable qcow2 in which to store VM state.
#==============================================================================
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
mkdir -p "$TILE_DIR"
rm -f "$GOLDEN_TMP"
qemu-img create -q -f qcow2 "$GOLDEN_TMP" "$GOLDEN_SIZE"
log "fresh VM-state container: ${GOLDEN_TMP} (${GOLDEN_SIZE})"

#==============================================================================
# STEP 4 — install / input automation : NONE NEEDED (fully unattended)
#   No bootloader prompt, no installer, no login. The compositor auto-starts.
#   There is no answer file / autounattend / sendkey / vncdotool sequence to
#   encode — the recipe is literally "boot the ISO and wait ~40 s".
#==============================================================================
log "no install/keystroke automation needed — GUI auto-starts"

#==============================================================================
# STEP 5 — era software injection : N/A
#   The live ISO already ships the compositor, Terminal, taskbar + clock. The
#   medium is read-only, so nothing is (or can be) injected.
#==============================================================================

#==============================================================================
# STEP 6 — framebuffer-gated golden bake
#   Boot the exact production device set headless, poll real framebuffer dumps
#   until the cyan desktop and focused white Terminal at '/ #' are present,
#   then savevm. This rejects boot logs and half-painted compositor frames.
#==============================================================================
frame_is_ready() {
  python3 - "$1" <<'PYFRAME'
import sys

with open(sys.argv[1], "rb") as f:
    data = f.read()
parts = data.split(b"\n", 3)
if len(parts) != 4 or parts[0] != b"P6" or parts[1] != b"1024 768" or parts[2] != b"255":
    raise SystemExit(1)
pixels = parts[3]
if len(pixels) != 1024 * 768 * 3:
    raise SystemExit(1)

def rgb(x, y):
    i = (y * 1024 + x) * 3
    return pixels[i], pixels[i + 1], pixels[i + 2]

# Right/lower desktop must be predominantly HelenOS compositor blue.
blue = 0
for y in range(40, 730, 4):
    for x in range(660, 1010, 4):
        r, g, b = rgb(x, y)
        blue += b > g > r and b - r > 35

# The focused Terminal body is a large near-white panel. Its banner and the
# '/ #' prompt leave dark/red ink in the top 220 rows once Bdsh is ready.
white = 0
ink = 0
for y in range(28, 500, 4):
    for x in range(4, 640, 4):
        r, g, b = rgb(x, y)
        white += r > 220 and g > 220 and b > 220
for y in range(28, 220):
    for x in range(2, 300):
        r, g, b = rgb(x, y)
        ink += (r < 80 and g < 80 and b < 80) or (r > 120 and g < 100 and b < 100)

raise SystemExit(0 if blue > 12000 and white > 15000 and ink > 500 else 1)
PYFRAME
}

command -v "$QEMU_BIN" >/dev/null 2>&1 || die "qemu not found ($QEMU_BIN)"
rm -f "$MONSOCK" "$PIDFILE" "$QLOG" "$SHOT_PPM"

log "booting exact production device set (${MACHINE}, ${CPU_MODEL}, ${RAM_MB} MiB)"
"$QEMU_BIN" \
  -name "$KEY-golden-bake" \
  -enable-kvm -m "$RAM_MB" -smp 1 \
  -machine "$MACHINE" -cpu "$CPU_MODEL" \
  -rtc base=localtime \
  -cdrom "$ISO_PATH" -boot d \
  -vga "$VGA" \
  -display none \
  -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 \
  -usb -device usb-tablet \
  -drive "file=${GOLDEN_TMP},format=qcow2,if=ide,index=0,media=disk" \
  -monitor "unix:${MONSOCK},server=on,wait=off" \
  -pidfile "$PIDFILE" \
  >"$QLOG" 2>&1 &

for _ in $(seq 1 40); do
  [[ -S "$MONSOCK" && -s "$PIDFILE" ]] && break
  sleep 0.5
done
[[ -S "$MONSOCK" && -s "$PIDFILE" ]] || die "QEMU monitor/pidfile did not appear"
log "qemu pid $(cat "$PIDFILE") — framebuffer-gating for at most ${BAKE_TIMEOUT}s"

ready=0
for _ in $(seq 1 "$BAKE_TIMEOUT"); do
  kill -0 "$(cat "$PIDFILE")" 2>/dev/null || die "QEMU exited during boot; see ${QLOG}"
  rm -f "$SHOT_PPM"
  mon "screendump ${SHOT_PPM}" || true
  if [[ -s "$SHOT_PPM" ]] && frame_is_ready "$SHOT_PPM"; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == "1" ]] || die "blue compositor + Terminal '/ #' framebuffer did not arrive"
log "VERIFIED: blue compositor desktop and focused Terminal at '/ #'"

# Let the terminal/cursor settle, refresh the retained proof, then snapshot.
sleep 2
rm -f "$SHOT_PPM"
mon "screendump ${SHOT_PPM}" || die "could not capture final framebuffer"
for _ in $(seq 1 20); do
  [[ -s "$SHOT_PPM" ]] && break
  sleep 0.25
done
[[ -s "$SHOT_PPM" ]] && frame_is_ready "$SHOT_PPM" || die "final framebuffer failed desktop gate"
mon "savevm golden" || die "savevm golden failed"
log "savevm golden completed"

# Close QEMU so qemu-img can safely inspect the container, then install it.
teardown
qemu-img snapshot -l "$GOLDEN_TMP" | awk 'NR > 2 {print $2}' | grep -qx golden ||
  die "fresh container has no internal 'golden' snapshot"
mv -f "$GOLDEN_TMP" "$GOLDEN_DISK"
chmod 0644 "$GOLDEN_DISK"
log "installed fresh golden: ${GOLDEN_DISK}"

if command -v pnmtopng >/dev/null 2>&1; then
  pnmtopng "$SHOT_PPM" >"$SHOT_PNG" 2>/dev/null && log "proof PNG: ${SHOT_PNG}"
else
  log "proof PPM: ${SHOT_PPM}"
fi
trap - EXIT

#==============================================================================
# DONE — deliverable + neko-qemu production args
#==============================================================================
cat <<EOF

[helenos] BUILD COMPLETE
  Boot medium              : ${ISO_PATH}
  Fresh golden             : ${GOLDEN_DISK} (internal snapshot: golden)
  GUI proof (framebuffer)  : ${SHOT_PPM}${SHOT_PNG:+ / ${SHOT_PNG}}

  ---- neko-qemu PRODUCTION args (what CT 110 serves) --------------------------
  # 32-bit guest under the x86_64 binary via -cpu qemu32; swap the audio
  # backend for the one neko pipes to WebRTC (pa or pipewire).
  qemu-system-x86_64 \\
    -machine pc-i440fx-11.0 \\
    -enable-kvm -cpu qemu32 \\
    -m 512 \\
    -vga std \\
    -device intel-hda -device hda-output,audiodev=snd0 \\
    -audiodev pa,id=snd0,out.buffer-length=100000,out.latency=50000 \\
    -boot d \\
    -cdrom ${ISO_NAME} \\
    -usb -device usb-tablet \\
    -drive file=/data/vms/streamhost/tiles/helenos/golden.qcow2,if=ide,index=0,media=disk \\
    -rtc base=localtime
  # neko station row (compose docker-compose.gallery-guests.yml : helenos):
  #   QEMU_MACHINE=pc-i440fx-11.0 QEMU_VGA=std QEMU_MEM=512
  #   QEMU_SOUND="-device intel-hda -device hda-output,audiodev=snd"
  #   GUEST_CDROM=/guests/HelenOS/${ISO_NAME} GUEST_BOOT=d
  #   QEMU_EXTRA="-enable-kvm -cpu qemu32"
  -----------------------------------------------------------------------------
EOF
