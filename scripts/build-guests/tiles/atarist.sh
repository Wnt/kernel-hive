#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/atarist.sh — build the Atari ST + EmuTOS GEM-desktop streamhost
# station as a thin overlay on the shared bridge base (build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk that runs Hatari (WINDOWED) emulating an
#         Atari ST that boots EmuTOS straight to the GEM desktop. streamhost
#         captures the Linux framebuffer + AC97 audio (the ST YM2149 routed
#         through ALSA).
# TYPE  : "emulator bridge" station (see streamhost/docs/BRIDGE.md). Overlay + a per-station
#         /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * Hatari MUST run WINDOWED (--window). Real SDL fullscreen (--fullscreen)
#     renders BLACK in the captured std-VGA framebuffer (same trap as VICE's
#     -VICIIfull on the c64 station).
#   * mono monitor (--monitor mono) gives the crisp ST-high 640x400 GEM desktop;
#     --zoom 1.6 scales it to 1024x640 so it FILLS the framebuffer width, centred
#     on the 1024x768 black bare-X root (small top/bottom black bands).
#   * Hatari (SDL2) bundles nothing but the machine; EmuTOS is supplied as
#     etos1024k.img (already in the base's /opt/bridge/media/). A read/write
#     GEMDOS folder is mounted as C: and carries curated PD/freeware/shareware
#     applications plus EMUDESK.INF shortcuts; no commercial ROMs/software.
#   * The station boots straight into the GEM desktop by auto-`-loadvm golden` (same
#     pattern as the alpine/c64 stations): the golden INTERNAL snapshot (RAM+devices)
#     restores the already-running desktop in ~6 s (EmuTOS cold boot is ~30-40 s).
#   * ACCEPTANCE is a REAL framebuffer screenshot of the GEM desktop + a measured
#     non-silent YM2149 wav — never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by pidfile,
# idempotent, --force to rebuild the overlay. Touches ONLY the atarist station dir.
#
# Usage:  atarist.sh [--force] [--bake] [-h]
#
#   --bake  bake the golden snapshot of the ALREADY RUNNING station and prove it
#           restores (lib/bridge-bake-golden). Run it once the acceptance below
#           has passed on a real screenshot, with the station up under its own
#           streamhost/stations/atarist/qemu-streamhost.sh — NOT under this
#           script's boot_tile: a golden taken under a device set that differs
#           from the launcher's will not loadvm, and that only surfaces later,
#           at the first visitor reset. EmuTOS has no machine-checkable "the
#           GEM desktop is up" signal (unlike the CPC/GT40 builders' pixel
#           gates), so the bake stays operator-triggered rather than slept-for.
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=atarist
VMID=216
UDP=54116
SSH_PORT=5816
WEB_PORT=8116
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/stations/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
MEDIA="/opt/bridge/media/etos1024k.img"
APP_MEDIA="/opt/bridge/media/atarist-apps"
APP_CACHE="${TILE_DIR}/assets/atarist-apps"
APP_WORK="${TILE_DIR}/app-build"

# ---- THE FIVE APP ARCHIVES: FRAGILE SOURCES, FATAL HASHES -------------------
# Every one of these is gated on the sha256 below and the build dies on a
# mismatch, which is the easy half. The hard half is that the SOURCES are three
# small sites and none of them is an archive:
#   * exxosforum.co.uk (Floppyshop PD library) — needs a two-step PHP cookie
#     handshake (DL_CAP2.php then dl.php), so it cannot even be curl'd naively,
#     let alone mirrored. Supplies ART-3488 (AIM 3.1) and UTL-3762 (GEMBench).
#   * eckhardkruse.net — the author's own site. Supplies Ballerburg + sources.
#   * atarimania.com/pgedump.awp?id=31902 — an opaque numeric id, not a filename.
#     Supplies Pacman for GEM 0.2.5.
# The only copies that exist on labhost are the build cache at $APP_CACHE, which
# is inside a STATION directory rather than an asset location. They are declared in
# docs/lab/ASSETS-MANIFEST.md §2 and checked by check-assets.sh; they are pending
# population into the shared media cache. Do not clean $APP_CACHE.
AIM_ZIP=ART-3488.zip
AIM_SHA=a5b245ae886aaeedc7d98a0d7ae774c75c214faa567f5b3f88321c89a210e147
GEMBENCH_ZIP=UTL-3762.zip
GEMBENCH_SHA=74bce9ec2c7ec4d0da144887e0a5848bde3feff165e4cdabde52c3a395824567
BALLER_ZIP=baller.zip
BALLER_SHA=8bcb4214cc6a30c02413f73923cabcf65437b9294f6148f3018f01bac9115d45
BALLER_SRC_ZIP=baller_sources.zip
BALLER_SRC_SHA=63fb6c5aa14f4f912e4d5cff61f42fa35951932d0635b185e14da434212ed593
PACMAN_ZIP=pacman_for_gem_0_25.zip
PACMAN_SHA=6f33a9e7371f9fb6bd635dd6d67250e1c5adc6c0b44b609e726e0fed84f5fe3e

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
    sed -n '2,44p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[atarist $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

check_asset() {
  printf '%s  %s\n' "$2" "$1" | sha256sum -c - >/dev/null
}

fetch_asset() {
  local url=$1 name=$2 sha=$3
  local dst="${APP_CACHE}/${name}"
  if [ -f "$dst" ] && check_asset "$dst" "$sha"; then return; fi
  rm -f "${dst}.part"
  log "fetching ${name} ..."
  nice -n15 curl -fL --retry 3 --connect-timeout 15 "$url" -o "${dst}.part"
  check_asset "${dst}.part" "$sha"
  mv "${dst}.part" "$dst"
}

fetch_floppyshop_asset() {
  local name=$1 sha=$2
  local dst="${APP_CACHE}/${name}" cookie="${APP_WORK}/floppyshop.cookies"
  if [ -f "$dst" ] && check_asset "$dst" "$sha"; then return; fi
  rm -f "${dst}.part" "$cookie"
  log "fetching Floppyshop ${name} ..."
  nice -n15 curl -fsSL -c "$cookie" \
    "https://www.exxosforum.co.uk/atari/PDL/FLOPPYSHOP/DL_CAP2.php?file=${name}" -o /dev/null
  nice -n15 curl -fL --retry 3 -b "$cookie" \
    "https://www.exxosforum.co.uk/atari/PDL/FLOPPYSHOP/dl.php?file=${name}" -o "${dst}.part"
  check_asset "${dst}.part" "$sha"
  mv "${dst}.part" "$dst"
}

prepare_apps() {
  command -v curl >/dev/null && command -v unzip >/dev/null && command -v tar >/dev/null || {
    echo "atarist apps require curl, unzip, and tar on the box" >&2
    exit 1
  }
  mkdir -p "$APP_CACHE" "$APP_WORK"
  fetch_floppyshop_asset "$AIM_ZIP" "$AIM_SHA"
  fetch_floppyshop_asset "$GEMBENCH_ZIP" "$GEMBENCH_SHA"
  fetch_asset "https://www.eckhardkruse.net/atari_st/download/baller.zip" "$BALLER_ZIP" "$BALLER_SHA"
  fetch_asset "https://www.eckhardkruse.net/atari_st/download/baller_sources.zip" "$BALLER_SRC_ZIP" "$BALLER_SRC_SHA"
  fetch_asset "https://www.atarimania.com/pgedump.awp?id=31902" "$PACMAN_ZIP" "$PACMAN_SHA"

  rm -rf "${APP_WORK}/extract" "${APP_WORK}/gemdos"
  mkdir -p "${APP_WORK}/extract/aim" "${APP_WORK}/extract/gembench" \
    "${APP_WORK}/extract/baller" "${APP_WORK}/extract/pacman" \
    "${APP_WORK}/gemdos/APPS/AIM" "${APP_WORK}/gemdos/APPS/GEMBNCH" \
    "${APP_WORK}/gemdos/APPS/BALLER" "${APP_WORK}/gemdos/APPS/PACMAN" \
    "${APP_WORK}/gemdos/ORIGINAL"
  nice -n15 unzip -q "${APP_CACHE}/${AIM_ZIP}" -d "${APP_WORK}/extract/aim"
  nice -n15 unzip -q "${APP_CACHE}/${GEMBENCH_ZIP}" -d "${APP_WORK}/extract/gembench"
  nice -n15 unzip -q "${APP_CACHE}/${BALLER_ZIP}" -d "${APP_WORK}/extract/baller"
  nice -n15 unzip -q "${APP_CACHE}/${PACMAN_ZIP}" -d "${APP_WORK}/extract/pacman"
  cp -a "${APP_WORK}/extract/aim/ART-3488/." "${APP_WORK}/gemdos/APPS/AIM/"
  cp -a "${APP_WORK}/extract/gembench/UTL-3762/GBNCH403/." "${APP_WORK}/gemdos/APPS/GEMBNCH/"
  cp -a "${APP_WORK}/extract/baller/." "${APP_WORK}/gemdos/APPS/BALLER/"
  cp -a "${APP_WORK}/extract/pacman/PACMAN.025/." "${APP_WORK}/gemdos/APPS/PACMAN/"
  cp "${APP_CACHE}/${AIM_ZIP}" "${APP_CACHE}/${GEMBENCH_ZIP}" \
    "${APP_CACHE}/${BALLER_ZIP}" "${APP_CACHE}/${BALLER_SRC_ZIP}" \
    "${APP_CACHE}/${PACMAN_ZIP}" "${APP_WORK}/gemdos/ORIGINAL/"

  # EmuDesk reads EMUDESK.INF from C:. CRLF is required. #X creates desktop
  # launchers; #G's final field binds F1..F4 and starts in each app directory.
  sed 's/$/\r/' >"${APP_WORK}/gemdos/EMUDESK.INF" <<'INF'
#R 02
#E 1A E0 00 00 60
#Q 41 40 43 40 43 40
#W 00 00 02 06 26 0C 00 @
#W 00 00 02 08 26 0C 00 @
#W 00 00 02 0A 26 0C 00 @
#W 00 00 02 0D 26 0C 00 @
#M 00 02 01 FF A DISK A@ @
#M 02 02 01 FF B DISK B@ @
#M 04 02 00 FF C APPS C@ @
#F FF 07 @ *.*@
#N FF 07 @ *.*@
#D FF 02 @ *.*@
#Y 06 FF *.GTP@ @
#G 06 FF *.APP@ @
#G 06 FF *.PRG@ @
#P 06 FF *.TTP@ @
#F 06 FF *.TOS@ @
#G 06 FF C:\APPS\AIM\AIM.PRG@ *.@ 101 @
#G 06 FF C:\APPS\BALLER\BALLER.PRG@ *.@ 102 @
#G 06 FF C:\APPS\PACMAN\PACMAN.APP@ *.@ 103 @
#G 06 FF C:\APPS\GEMBNCH\GEMBENCH.PRG@ *.@ 104 @
#X 00 00 06 FF   C:\APPS\AIM\AIM.PRG@ AIM 3.1@
#X 02 00 06 FF   C:\APPS\BALLER\BALLER.PRG@ BALLERBURG@
#X 04 00 06 FF   C:\APPS\PACMAN\PACMAN.APP@ PACMAN GEM@
#X 06 00 06 FF   C:\APPS\GEMBNCH\GEMBENCH.PRG@ GEMBENCH@
#T 00 08 03 FF   TRASH@ @
#O 0E 08 04 FF   PRINTER@ @
INF
  sed 's/$/\r/' >"${APP_WORK}/gemdos/README.TXT" <<'README'
Curated redistributable Atari ST applications (original archives in ORIGINAL):
AIM 3.1 image manager/paint package - public domain package (ART-3488)
Ballerburg - public domain by author Eckhard Kruse
Pacman for GEM 0.2.5 - freeware; original archive redistribution permitted
GEMBench 4.03 - unregistered redistributable shareware (UTL-3762)
Desktop shortcuts and keys: F1 AIM, F2 Ballerburg, F3 Pacman, F4 GEMBench.
See docs/guests/atarist.md in the streamhost build tree for URLs and SHA-256.
README
  check_asset "${APP_WORK}/gemdos/ORIGINAL/${AIM_ZIP}" "$AIM_SHA"
  check_asset "${APP_WORK}/gemdos/ORIGINAL/${GEMBENCH_ZIP}" "$GEMBENCH_SHA"
  check_asset "${APP_WORK}/gemdos/ORIGINAL/${BALLER_ZIP}" "$BALLER_SHA"
  check_asset "${APP_WORK}/gemdos/ORIGINAL/${BALLER_SRC_ZIP}" "$BALLER_SRC_SHA"
  check_asset "${APP_WORK}/gemdos/ORIGINAL/${PACMAN_ZIP}" "$PACMAN_SHA"
}

# The Atari ST / EmuTOS kiosk launcher (overlaid onto the base's /etc/bridge/launch.sh).
# VERIFIED FLAGS (Hatari 2.5.0, trixie; identical geometry to 2.4.1 on bookworm):
#   --tos <img>        the EmuTOS ROM image (etos1024k.img).
#   --machine st       plain Atari ST (EmuTOS 1024k targets ST/STe).
#   --monitor mono     ST-high mono (640x400) — the crisp classic GEM desktop.
#   --window / -w      WINDOWED. Do NOT use --fullscreen: real SDL fullscreen
#                      renders BLACK in the captured std-VGA framebuffer.
#   --zoom 1.6         640x400 -> 1024x640: fills the framebuffer width, centred
#                      on the 1024x768 black bare-X root.
#   --statusbar 0 --drive-led 0 --borders 0   clean desktop (no chrome/overscan).
#   --sound 48000 --ym-mixing model           YM2149 -> SDL/ALSA default -> AC97.
# SDL_RENDER_DRIVER=software avoids GL on the GPU-less host (same as the c64 station).
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Atari ST + EmuTOS GEM desktop kiosk launcher (kiosk). See atarist.sh header.
# Hatari 2.5.0, WINDOWED (real fullscreen renders BLACK in the captured std-VGA fb).
# mono monitor -> ST-high 640x400 GEM desktop; --zoom 1.6 -> 1024x640 (fills width).
# YM2149 sound: SDL audio -> ALSA default -> AC97 (hw:0,0) -> QEMU dbus audiodev.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
export SDL_VIDEO_CENTERED=1
exec hatari \
  --tos /opt/bridge/media/etos1024k.img \
  --harddrive /opt/bridge/media/atarist-apps --gemdos-drive C --protect-hd off \
  --machine st --monitor mono \
  --window --zoom 1.6 --statusbar 0 --drive-led 0 --borders 0 \
  --sound 48000 --ym-mixing model --sound-sync off --frameskips 0
EOS

# ---- boot the station QEMU (exact device set; conditional -loadvm golden) -------
# NOTE: the exact device set MUST match the golden bake or -loadvm golden fails.
# -m 1536, -vga std, AC97 audiodev, usb-tablet, e1000 hostfwd — identical to c64.
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

# 1. cold boot (no golden yet) and install the Atari ST kiosk launcher
if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for i in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  log "preparing curated Atari ST application drive ..."
  prepare_apps
  nice -n15 tar -C "${APP_WORK}/gemdos" -cf - . | guest \
    "rm -rf '$APP_MEDIA'; mkdir -p '$APP_MEDIA'; tar -C '$APP_MEDIA' -xf -; chown -R bridge:bridge '$APP_MEDIA'"
  guest "test -f '$APP_MEDIA/EMUDESK.INF' && test -f '$APP_MEDIA/APPS/PACMAN/pacman.app'"
  log "installing /etc/bridge/launch.sh (Hatari + EmuTOS + GEMDOS C:, windowed) ..."
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh"
  guest "test -f $MEDIA" || {
    echo "etos1024k.img missing in base ($MEDIA)"
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
  # restart X so it lands on the GEM desktop unattended (kiosk re-runs launch.sh).
  # reset-failed clears getty's start-limit if a prior bad launcher looped it.
  guest "pkill -u bridge hatari 2>/dev/null; pkill -u bridge xterm 2>/dev/null; sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  log "EmuTOS boots to the GEM desktop in ~30-40s. VERIFY four app icons via framebuffer:"
  log "   python3 /root/cdrv.py $QMP dump /tmp/atarist.ppm   (convert->png->look: GEM desktop?)"
  log "then launch F3 (Pacman for GEM) and capture its graphical UI."
  log "Also prove YM2149 non-silent (see AUDIO VERIFY below / docs/guests/atarist.md)."
  log "Then BAKE the golden fixture, with the GEM desktop showing and the tile up"
  log "under its OWN launcher (device set must match the bake or -loadvm fails):"
  log "   bash ${TILE_DIR}/qemu-streamhost.sh && $0 --bake"
  log "Re-run this script after baking to boot straight into the golden fixture (-loadvm golden)."
fi

# =============================================================================
# AUDIO VERIFY (manual, run once during the prove — NOT part of the auto path).
# Route the guest ALSA default to a WAV *tee* whose slave is the real AC97 card
# (hw:0,0), so the capture is REAL-TIME PACED (a null slave has NO clock and
# balloons the wav to multiple GB — it filled the guest / and inflated the
# overlay; ALWAYS use a hw:0,0 slave). EmuTOS emits a YM2149 keyclick on every
# ST key, so inject keys via QMP send-key while capturing, then measure RMS/peak.
#
#   guest: cp /etc/asound.conf /etc/asound.conf.bak
#   guest: cat > /etc/asound.conf <<'A'
#          pcm.!default { type file
#              slave.pcm { type plug slave.pcm "hw:0,0" }
#              file "/tmp/ym.wav"; format "wav" }
#          ctl.!default { type hw card 0 }
#          A
#   guest: rm -f /tmp/ym.wav; systemctl restart getty@tty1     # kiosk boots w/ tee
#   sleep 25   # EmuTOS boot
#   box:   for i in $(seq 1 60); do for k in a s d; do \
#            python3 /root/cdrv.py '"$QMP"' key $k; done; done   # YM keyclicks
#   guest: systemctl stop getty@tty1    # kill hatari (NO respawn) -> flush wav
#   box:   scp .../tmp/ym.wav ; measure PEAK/RMS with numpy over raw PCM past the
#          'data' chunk (the streamed ALSA wav header frame-count is NOT
#          backpatched, so python's wave module reports 0 frames — read raw).
#   guest: cp /etc/asound.conf.bak /etc/asound.conf; rm -f /etc/asound.conf.bak /tmp/ym.wav
#   guest: systemctl start getty@tty1   # normal audio path back for the golden
# Measured on the prove: PEAK=18170, RMS_overall=1426, RMS_loudest1s=2127 (0=silence).
# =============================================================================

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT, web $WEB_PORT)"
