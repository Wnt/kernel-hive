#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/amiga.sh — build the Commodore Amiga 500 + Workbench 1.3 streamhost
# tile as a thin overlay on the shared bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk that runs FS-UAE (WINDOWED) emulating a REAL
#         Commodore Amiga 500 (Motorola 68000) auto-booting Workbench 1.3 off a
#         Kickstart 1.3 ROM. streamhost captures the Linux framebuffer + AC97 audio
#         (the Amiga Paula chip routed through OpenAL -> ALSA -> AC97).
# TYPE  : "emulator bridge" tile (see streamhost/docs/BRIDGE.md). Overlay + a per-tile
#         /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# DISTINCT FROM the 'amigaos' tile: that tile is native AROS-on-x86 (aros-pc-i386.iso
# booted directly by QEMU). THIS tile is the genuine 68000 Amiga 500 running the real
# Commodore Kickstart/Workbench under a software emulator — different CPU, different OS.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * FS-UAE is NOT baked into the frozen bridge base (the base predates this tile);
#     this script `apt-get install -y fs-uae` INTO THE OVERLAY. (bridge-base.sh has
#     also been updated to bake fs-uae + the media in on a from-scratch NVMe rebuild.)
#   * The Kickstart ROM + Workbench ADF are copyrighted media that are free to use in
#     this private collection; we just don't re-distribute the binaries via the GitHub
#     repo. They are NEVER committed (.gitignore: *.adf, *.rom, Kickstart*.rom, kick*.rom);
#     this script FETCHES them at build time from history-preservation archives and verifies
#     md5. Provenance is recorded in /opt/bridge/media/amiga/PROVENANCE (guest).
#   * FS-UAE renders via OpenGL; the host has NO GPU, so launch.sh forces llvmpipe
#     software GL (LIBGL_ALWAYS_SOFTWARE=1). Real-fullscreen renders BLACK in the
#     captured std-VGA framebuffer (same trap as VICE/C64) -> run WINDOWED (fullscreen=0,
#     fixed 720x568 window) on the bare-X root, which the framebuffer captures correctly.
#   * Paula audio -> OpenAL (forced to the ALSA backend, ALSOFT_DRIVERS=alsa) -> ALSA
#     default (hw:0,0) -> QEMU AC97 -> streamhost dbus audiodev. The AC97 card MUST be
#     in the device set or audio is silent.
#   * The tile boots straight into the Workbench desktop by auto-`-loadvm golden` (same
#     pattern as c64/alpine): the golden INTERNAL snapshot (RAM+devices) restores the
#     already-running desktop with no Amiga boot / floppy load / keypresses.
#   * ACCEPTANCE is a REAL framebuffer screenshot of the Workbench desktop + a measured
#     non-silent Paula wav — never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by pidfile,
# idempotent, --force to rebuild the overlay. Touches ONLY the amiga tile dir.
#
# Usage:  amiga.sh [--force] [-h]
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=amiga
VMID=218
UDP=54118
SSH_PORT=5818
WEB_PORT=8118
BRIDGE_BASE="/data/vms/bridge/bridge-base.qcow2"
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/tiles/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
MEDIA_DIR="/opt/bridge/media/amiga" # inside the guest overlay

# Media (copyrighted; free to use in this private collection — fetched at build time,
# NEVER committed to the GitHub repo).
KICK_URL="https://archive.org/download/commodore-amiga-firmware/Kickstart%20v1.3%20r34.005%20%281987-12%29%28Commodore%29%28A500-A1000-A2000-CDTV%29%5B%21%5D.zip"
KICK_MD5="82a21c1890cae844b3df741f2762d48d" # A500 Kickstart 1.3 rev 34.005, 256 KiB
WB_URL="https://amigamuseum.emu-france.info/Fichiers/ADF/Installation,%20Kickstars,%20Workbench%20Tutorials%20&%20Promotional/Workbench%201.3%20%2834.20%29%20-%20Boot%20%28Commodore%29%20%281988%29.zip"
WB_MD5="d10f4907697c4eafcf976b4ef6ea829b" # Workbench 1.3 (34.20) Boot disk, 880 KiB ADF

FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --force)
    FORCE=1
    shift
    ;;
  -h | --help)
    sed -n '2,52p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[amiga $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The Amiga/Workbench kiosk launcher (overlaid onto the base's /etc/bridge/launch.sh).
# VERIFIED FS-UAE 3.1.66 config (passed as --key=value; no config-file needed):
#   --amiga_model=A500                 real A500 (68000, OCS, 512K chip).
#   --kickstart_file=<kick13.rom>      Kickstart 1.3 (fs-uae verifies the ROM checksum).
#   --floppy_drive_0=<workbench13.adf> boot the Workbench 1.3 disk in DF0:.
#   --floppy_drive_volume=100          authentic drive-click sound (audible on boot;
#                                      this is the guaranteed non-silent audio source).
#   --fullscreen=0 --window_width/height  WINDOWED (real-fullscreen renders BLACK in capture).
#   --automatic_input_grab=0 --initial_input_grab=0  don't grab the pointer (streamhost drives it).
#   LIBGL_ALWAYS_SOFTWARE=1            llvmpipe software GL (GPU-less host).
#   ALSOFT_DRIVERS=alsa                force OpenAL to ALSA (deterministic Paula->ALSA->AC97).
# The stderr redirect MUST go to a bridge-writable path (/tmp): redirecting to a
# root-owned dir (e.g. /var/log) makes bash fail the exec and the X session dies in ~1.7s.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Amiga 500 + Workbench 1.3 kiosk launcher (bridge tile). See amiga.sh header for rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export LIBGL_ALWAYS_SOFTWARE=1     # GPU-less host: llvmpipe software OpenGL for FS-UAE
export SDL_VIDEODRIVER=x11
export ALSOFT_DRIVERS=alsa
M=/opt/bridge/media/amiga
exec fs-uae \
  --amiga_model=A500 \
  --kickstart_file="$M/kick13.rom" \
  --floppy_drive_0="$M/workbench13.adf" \
  --floppy_drive_volume=100 \
  --floppy_drive_volume_empty=100 \
  --floppy_drive_speed=100 \
  --fullscreen=0 \
  --window_width=720 --window_height=568 \
  --automatic_input_grab=0 \
  --initial_input_grab=0 \
  --fade_out_duration=0 \
  --audio_frequency=48000 2> /tmp/fs-uae.err
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
    -name streamhost-${TILE} -enable-kvm -m ${MEM} -smp 2 -cpu host -rtc base=localtime \
    -drive file="${OVERLAY}",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
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

# ---- fetch + verify the Kickstart ROM and Workbench ADF INTO THE GUEST -------
fetch_media() {
  log "fetching Kickstart 1.3 ROM + Workbench 1.3 ADF into the guest (verified md5) ..."
  guest "bash -s" <<REMOTE
set -e
M=${MEDIA_DIR}; mkdir -p "\$M"; cd "\$M"
command -v unzip >/dev/null || { apt-get update >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1; }
if [ ! -f kick13.rom ] || [ "\$(md5sum kick13.rom | cut -d' ' -f1)" != "${KICK_MD5}" ]; then
  curl -sSL --max-time 180 -o k.zip "${KICK_URL}"
  unzip -o k.zip >/dev/null; mv -f Kickstart*A500*\[!\].rom kick13.rom 2>/dev/null || mv -f Kickstart*.rom kick13.rom
  rm -f k.zip
fi
if [ ! -f workbench13.adf ] || [ "\$(md5sum workbench13.adf | cut -d' ' -f1)" != "${WB_MD5}" ]; then
  curl -sSL --max-time 240 -o w.zip "${WB_URL}"
  unzip -o w.zip >/dev/null; mv -f Workbench*Boot*.adf workbench13.adf 2>/dev/null || mv -f *.adf workbench13.adf
  rm -f w.zip
fi
K=\$(md5sum kick13.rom | cut -d' ' -f1); W=\$(md5sum workbench13.adf | cut -d' ' -f1)
[ "\$K" = "${KICK_MD5}" ] || { echo "KICK md5 mismatch: \$K"; exit 1; }
[ "\$W" = "${WB_MD5}" ]   || { echo "WB md5 mismatch: \$W"; exit 1; }
cat > "\$M/PROVENANCE" <<PV
Amiga 500 tile media (copyrighted; free to use in this private collection — NOT committed to the GitHub repo).
kick13.rom      : Kickstart 1.3 rev 34.005 (A500/A1000/A2000/CDTV), md5 ${KICK_MD5}.
                  SRC: ${KICK_URL}
workbench13.adf : Workbench 1.3 (34.20) Boot disk (Commodore 1988), md5 ${WB_MD5}.
                  SRC: ${WB_URL}
PV
echo "media OK: kick=\$K wb=\$W"
REMOTE
}

# ---- main -------------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || {
  echo "missing bridge base: $BRIDGE_BASE (run bridge-base.sh first)"
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

# 1. cold boot (no golden yet): install fs-uae + media + the Amiga kiosk launcher
if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for i in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  # FS-UAE is NOT in the frozen base — install it into the overlay.
  if ! guest "command -v fs-uae >/dev/null"; then
    log "installing fs-uae into the overlay ..."
    guest "export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1; apt-get install -y fs-uae >>/tmp/apt.log 2>&1; command -v fs-uae"
  fi
  fetch_media
  log "installing /etc/bridge/launch.sh (Amiga 500 / Workbench 1.3, FS-UAE windowed) ..."
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh"
  # restart X so it lands on the Workbench desktop unattended (kiosk re-runs launch.sh).
  # reset-failed clears getty's start-limit if a prior bad launcher looped it.
  guest "pkill -u bridge fs-uae 2>/dev/null; sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  log "Workbench 1.3 boots in ~60-90s (KS insert-disk -> startup-sequence -> LoadWB). VERIFY via framebuffer:"
  log "   python3 /root/qmp_hmp.py $QMP 'screendump /tmp/amiga.ppm'  (pnmtopng -> png -> look: Workbench desktop w/ disk icons?)"
  log "and prove Paula non-silent (tee ALSA default -> wav during a boot run, measure RMS; see docs/guests/amiga500.md)."
  log "Then BAKE the golden fixture (with the CLEAN Workbench desktop showing, CLI window closed):"
  log "   python3 /root/qmp_hmp.py $QMP 'savevm golden'"
  log "   python3 /root/qmp_hmp.py $QMP 'loadvm golden'   # verify restore lands on the desktop"
  log "Re-run this script after baking to boot straight into the golden fixture (-loadvm golden)."
  log "Emit + start the tile:"
  log "   /data/vms/streamhost/scripts/streamhost-tile.sh --tile amiga --vmid ${VMID} --udp ${UDP} \\"
  log "       --pointer abs --audio on --audio-dev ac97 --input-dev usb --mem ${MEM} --smp 2 --cpu host --vga std --fps 60"
  log "   # then replace qemu-streamhost.sh with the bridge device set (ide overlay, e1000 hostfwd ${SSH_PORT}, conditional -loadvm golden)"
  log "   bash ${TILE_DIR}/qemu-streamhost.sh ; systemctl start streamhost@${TILE}"
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT, web $WEB_PORT)"
