#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/c64.sh — build the Commodore 64 + GEOS deskTop streamhost tile
# as a thin overlay on the shared bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk that runs VICE `x64sc` full-screen emulating
#         a Commodore 64 auto-booting the GEOS 2.0 deskTop. streamhost captures
#         the Linux framebuffer + AC97 audio (the C64 SID routed through ALSA).
# TYPE  : "emulator bridge" tile (see streamhost/docs/BRIDGE.md). Overlay + a per-tile
#         /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * GEOS needs VICE **TRUE DRIVE emulation** (`-truedrive`) or the deskTop
#     hangs on the 1541 — this is the single most important launch flag.
#   * VICE is the SDL2 build from source (x64sc); it is NOT in Debian. It bundles
#     the C64 KERNAL/BASIC/CHARGEN ROMs, so only the GEOS.D64 disk is supplied.
#   * The tile boots straight into GEOS by auto-`-loadvm golden` (same pattern as
#     the alpine tile): the golden INTERNAL snapshot (RAM+devices) restores the
#     already-running GEOS deskTop with no boot/keypresses.
#   * ACCEPTANCE is a REAL framebuffer screenshot of the GEOS deskTop + a measured
#     non-silent SID wav — never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by pidfile,
# idempotent, --force to rebuild the overlay. Touches ONLY the c64 tile dir.
#
# Usage:  c64.sh [--force] [--bake] [-h]
#   --bake  bake the golden of the ALREADY RUNNING tile and prove it restores
#           (lib/bridge-bake-golden). Boot it under its OWN qemu-streamhost.sh
#           first: a golden taken under a different device set will not loadvm.
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=c64
VMID=214
UDP=54114
SSH_PORT=5814
WEB_PORT=8114
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/tiles/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
MEDIA="/opt/bridge/media/GEOS.D64"
MOUSE_MEDIA="/opt/bridge/media/GEOS-1351.D64"

FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --force)
    FORCE=1
    shift
    ;;
  --bake)
    exec "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-bake-golden" "$QMP" "$OVERLAY"
    ;;
  -h | --help)
    sed -n '2,43p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[c64 $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The C64/GEOS kiosk launcher (overlaid onto the base's /etc/bridge/launch.sh).
# VERIFIED FLAGS (VICE 3.9 SDL2 — many "obvious" flags do NOT exist):
#   -drive8truedrive     TRUE DRIVE emulation on drive 8 — REQUIRED or GEOS hangs.
#                        (there is NO global -truedrive in 3.9; it is per-drive.)
#   -autostart-handle-tde keep true-drive ON during autostart (else GEOS breaks).
#   -VICIIdsize          double-size window (~768x544), centred on the black root.
#   -sounddev alsa       SID -> ALSA default -> AC97 (hw:0,0) -> QEMU dbus audiodev.
#   -autostart <d64>     attach to drive 8 + boot it.
#   -mouse               enable SDL mouse input/grab (Mouse=1).
#   -controlport1device 1351
#                        attach VICE's proportional 1351 model to C64 control port 1
#                        (JoyPort1Device=Mouse (1351)).
# Do NOT use -sdl2 / -fullscreen / -VICIIfull: -sdl2 and -fullscreen are INVALID,
# and -VICIIfull (SDL real-fullscreen mode-switch) renders BLACK in the captured
# std-VGA framebuffer. A double-size WINDOW on the bare-X root captures correctly.
# SDL_RENDER_DRIVER=software avoids GL issues on the GPU-less host.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# C64 + GEOS deskTop kiosk launcher (bridge tile). See c64.sh header for flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
# VICE's SDL window is a fixed 719x544 at -VICIIdsize and cannot grow (real
# fullscreen renders black in std-VGA capture -- see amstradcpc.sh). Drop the X
# root to the smallest mode that still contains it so the captured frame is
# mostly picture instead of black border.
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
exec x64sc -mouse -controlport1device 1351 \
  -sounddev alsa -drive8truedrive -autostart-handle-tde -VICIIdsize \
  -autostart /opt/bridge/media/GEOS-1351.D64
EOS

# ---- boot the tile QEMU (exact device set; conditional -loadvm golden) -------
boot_tile() {
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
  sleep 0.5
  rm -f "$QMP" "$PID"
  local LOADVM=""
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
  nohup qemu-system-x86_64 \
    -name streamhost-${TILE} -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m ${MEM} -smp 2 -cpu host -rtc base=localtime \
    -drive file="${OVERLAY}",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
    -usb \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 -device e1000,netdev=n0 \
    $LOADVM \
    -qmp unix:${QMP},server=on,wait=off -pidfile ${PID} \
    >"${TILE_DIR}/qemu.log" 2>&1 &
  for i in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  log "tile booted (loadvm='${LOADVM:-<none: cold>}')"
}

# ---- main -------------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || {
  echo "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <this tile's suite in registry/bridge-suites.json>)"
  exit 1
}
mkdir -p "$TILE_DIR"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 0 ]; then
  log "overlay exists: $OVERLAY (use --force to recreate — DESTROYS the golden snapshot)"
else
  log "creating thin overlay on the frozen bridge base ..."
  rm -f "$OVERLAY"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

# 1. cold boot (no golden yet) and install the C64 kiosk launcher
if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for i in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  log "preparing GEOS boot disk with COMM 1351 as the only input driver ..."
  guest "cp -f '$MEDIA' '$MOUSE_MEDIA'; /usr/local/bin/c1541 '$MOUSE_MEDIA' -delete joystick >/tmp/c64-geos-1351.log 2>&1"
  guest "/usr/local/bin/c1541 '$MOUSE_MEDIA' -list 2>&1 | grep -qi 'comm 1351'" || {
    echo "COMM 1351 input driver missing from $MOUSE_MEDIA" >&2
    exit 1
  }
  if guest "/usr/local/bin/c1541 '$MOUSE_MEDIA' -list 2>&1 | grep -qi 'joystick'"; then
    echo "JOYSTICK input driver still present in $MOUSE_MEDIA" >&2
    exit 1
  fi
  log "installing /etc/bridge/launch.sh (VICE 1351 on port 1, true-drive) ..."
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh"
  [ -f "$MEDIA" ] || guest "test -f $MEDIA" || {
    echo "GEOS.D64 missing in base ($MEDIA)"
    exit 1
  }
  guest "test -f '$MOUSE_MEDIA'" || {
    echo "GEOS 1351 disk missing ($MOUSE_MEDIA)"
    exit 1
  }
  # Disk checkpoint before the getty-restart below drives the guest; see
  # lib/bridge-coldboot. Needs the VM stopped, so stop this build's own
  # boot_tile() and cold-boot it again — the getty-restart still re-applies.
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null
  for i in $(seq 1 40); do
    { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; } || break
    sleep 0.25
  done
  rm -f "$QMP" "$PID"
  "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile
  boot_tile
  log "waiting for guest ssh ..."
  for i in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  # restart X so it lands on GEOS unattended (kiosk re-runs launch.sh).
  # reset-failed clears getty's start-limit if a prior bad launcher looped it.
  guest "pkill -u bridge x64sc 2>/dev/null; sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  log "GEOS deskTop loads via true-drive in ~60-90s. VERIFY via framebuffer:"
  log "   python3 /root/cdrv.py $QMP dump /tmp/c64.ppm   (convert->png->look: GEOS deskTop?)"
  log "and prove SID non-silent (separate VICE run dumping a tone to wav; see docs/guests/c64.md)."
  log "Then BAKE the golden fixture (with the GEOS deskTop showing):"
  log "   $0 --bake   # savevm + assert it landed + loadvm + assert it runs"
  log "Re-run this script after baking to boot straight into the golden fixture (-loadvm golden)."
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT, web $WEB_PORT)"
