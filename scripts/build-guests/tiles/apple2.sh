#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/apple2.sh — build the Apple //e + Apple GEOS deskTop streamhost
# station as a thin overlay on the shared bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk that runs LinApple 2.3.0 `linapple` full-screen
#         emulating an Apple //e (enhanced) auto-booting the Apple GEOS deskTop off a
#         ProDOS hard-disk image. streamhost captures the Linux framebuffer + AC97
#         audio (the Apple II 1-bit speaker routed through ALSA).
# TYPE  : "emulator bridge" station (see streamhost/docs/BRIDGE.md). Overlay + a per-station
#         /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# EMULATOR USED : LinApple (NOT MAME).
#   The frozen bridge base's LinApple build had FAILED for two reasons; both are
#   FIXED here, inside the overlay (the base stays frozen):
#     1. PNG->XPM asset step needs ImageMagick `convert`  -> apt install imagemagick
#        (already present in the current base; kept in the dep list for a clean rebuild).
#     2. The "Video.o g++ error" was really a MISSING SDL1.2 dev header: LinApple 2.3.0
#        is an SDL1.2 app (`#include <SDL_image.h>`), and the base only carries SDL2
#        (for VICE). Installing libsdl1.2-dev + libsdl-image1.2-dev fixes Video.o;
#        Disk.cpp then needs libzip-dev (`#include <zip.h>`). With those three the
#        build completes clean and `make install` drops /usr/local/bin/linapple.
#   LinApple bundles the //e ROM (compiled into inc/resource.h) AND a correct
#   AppleMouse firmware (Pascal signature $Cn05=38/$Cn07=18/$Cn0B=01/$Cn0C=20 plus
#   the $CnFB=D6 ID byte GEOS checks). No external ROM is required (unlike the
#   MAME fallback, which would need apple2e.zip).
#
# ---- LINAPPLE KIOSK PATCH (assets/apple2/linapple-kiosk.patch, 2026-07-12) ---
#   Three stock-LinApple bugs broke this station and are patched in-guest before
#   the build (browser-stream verified fixes):
#   1. Frame.cpp: ALL mouse-card input was gated behind a click-to-capture
#      (SDL_WM_GrabInput) step - the first click was eaten, and grab+hidden
#      cursor puts SDL1.2 into warp-based relative mode, which is broken with
#      the absolute usb-tablet -> the GEOS arrow never tracked and the cursor
#      "disappeared after one click" in the UI. Patched: when the mouse card
#      is active, motion + buttons feed it directly (no grab, no capture) and
#      the host X cursor is hidden over the window (GEOS draws its own arrow).
#   2. MouseInterface.cpp: GEOS's mouse driver is DELTA-based - each poll it
#      READs the card, treats (pos - centre) as a movement delta in Apple
#      screen pixels, then re-homes the card to (16384,16384). Stock LinApple
#      (a) mis-scaled MOUSE_POS writes (the 16384 re-home became 533122, far
#      outside the clamps) and (b) fed absolute positions, which a delta
#      consumer turns into arrow-flies-to-a-corner. Patched: MOUSE_POS/HOME/
#      INIT clamp instead of scale, and host motion feeds exact correction
#      deltas against a mirrored arrow-position estimate (pin-sync to the
#      top-left corner on driver init) -> true absolute 1:1 tracking.
#   3. Video.cpp: CopySource blanked every other scanline for all video types
#      >= TV-emu (incl. the monochrome modes) - through the 1.8x window scale
#      and H.264 encode that turned into heavy moire striping. Patched: solid
#      lines (no scanline blanking).
#   NOTE ALSO: the stock linapple.conf template has "Clock Enable = 4", which
#   inserts a ProDOS clock-card ROM into slot 4 AFTER MemInitialize - right on
#   top of the mouse card's ROM + IO handlers. That was the root cause of
#   GEOS's "No mouse card found" / dead arrow since the first bake. The conf
#   sed below moves the clock to free slot 5 (printer=1 SSC=2 mouse=4 disk=6
#   HDD=7). With the mouse card visible, GEOS also finds its VBL interrupt
#   source: NO boot dialogs appear any more.
#
# APPLE GEOS MEDIA : the ProDOS hard-disk image "GEOS-mouse supported by APPLEWIN.hdv"
#   from the Asimov Apple II archive (Breadbox released Apple GEOS as freeware, 2003).
#   Volume /BIGWON. Boots ProDOS -> GEOS deskTop straight from slot 7.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * With the clock card moved off slot 4 (see above), GEOS finds the mouse
#     card AND its VBL interrupt source: a cold boot goes STRAIGHT to the
#     deskTop with NO dialogs. If you ever see "No interrupt source found" or
#     "Input driver error: No mouse card found", slot 4 is occupied by
#     something else again - fix that, don't dismiss-and-bake.
#   * The golden INTERNAL snapshot (RAM+devices) restores the already-running GEOS
#     deskTop with no //e boot, no ProDOS load, no keypresses (same pattern as c64).
#   * ACCEPTANCE is a REAL framebuffer screenshot of the GEOS deskTop + a measured
#     non-silent speaker wav (the Apple //e power-on beep: PEAK=8191, RMS_1s~3400)
#     - never disk/log inference.
#   * POINTER-WEDGE WATCHDOG (added 2026-07-12): after multi-day continuous runtime
#     the kiosk Xorg can stop applying tablet events (kernel still receives EV_ABS
#     on the tablet evdev node while the X core pointer freezes; top suspect is
#     systemd-logind pausing the libinput fd without a resume). A baked-in guest
#     watchdog (assets/apple2/pointer-watchdog.py + pointer-watchdog.service)
#     detects a clear multi-sample freeze and restarts the kiosk - the recovery
#     proven to clear the wedge. (Its post-restart Return+space presses are
#     no-ops now that cold boots show no dialogs.)
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by pidfile,
# idempotent, --force to rebuild the overlay. Touches ONLY the apple2 station dir.
#
# Usage:  apple2.sh [--force] [--bake] [-h]     (run ON labhost, as root)
#   --bake  capture the checkpoint of the ALREADY RUNNING station and prove it restores
#           (lib/bridge-bake-golden). Boot it under its OWN qemu-streamhost.sh
#           first: a checkpoint taken under a different device set will not loadvm.
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=apple2
VMID=217
UDP=54117
SSH_PORT=5817
WEB_PORT=8117
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/stations/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
HDV="/opt/bridge/media/geos.hdv"
CONF="/opt/bridge/media/linapple.conf"
ASSETS_DIR="${ASSETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../assets/apple2}"
# Asimov mirror; GEOS-mouse HDV is the AppleWin-tailored (== LinApple) mouse build.
#
# SINGLE MIRROR + FATAL HASH GATE. mirrors.apple2.org.za is the only source this
# station has, so the two pins below are what turns "the mirror served something" into
# "the mirror served THIS". Both are sha256 measured on the LIVE apple2 overlay
# 2026-08-10 (`labctl exec apple2 sha256sum /opt/bridge/media/…`); the HDV inside the
# zip is dated 2009-12-05, 1 327 616 B, ProDOS volume /BIGWON. Recorded in
# docs/lab/ASSETS-MANIFEST.md §2 with its licence class (Breadbox freed Apple GEOS in
# 2003) and covered by check-assets.sh.
#   The `file … ProDOS` assertion below is KEPT, and is a different question: the
#   hash says "this is the right file", `file` says "this is a sane one", and a
#   substituted-but-valid ProDOS image fails the first while passing the second.
GEOS_URL="https://mirrors.apple2.org.za/ftp.apple.asimov.net/images/masters/other_os/gui/geos/GEOS-mouse%20supported%20by%20APPLEWIN.hdv.zip"
GEOS_ZIP_SHA=64b7bef2440e2f0424586a893c641b566901403ad3ce6b3b5adaab573ae23e35
GEOS_HDV_SHA=5aba89dda3450abf17b8cc05d9de98149abe0bb072e5b01cc29b7fff995fc681

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
    sed -n '2,63p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[apple2 $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The Apple //e/GEOS kiosk launcher (overlaid onto the base's /etc/bridge/launch.sh).
# LinApple config lives at /opt/bridge/media/linapple.conf and is picked up as
# ./linapple.conf because the launcher cd's into /opt/bridge/media first.
#   Fullscreen=0 -> WINDOW on the bare-X root: real SDL fullscreen renders BLACK in
#     the captured std-VGA framebuffer (same gotcha as VICE -VICIIfull on the c64 station).
#   Mouse in slot 4=1 (GEOS is mouse-driven) + Soundcard Type=1 (Mockingboard OFF -
#     it shares slot 4 with the mouse; Apple II tones use the built-in SPEAKER anyway).
#   Video Emulation=7 (Monochrome WHITE) - GEOS draws a 1-bit 560x192 double-hi-res
#     desktop; "Color Standard" (1) rainbow-fringes every glyph edge with NTSC
#     artifact colors, and mono GREEN (6) puts the whole signal into the H.264
#     chroma planes, which 4:2:0 subsampling halves -> muddy/smeared text in the
#     browser stream. WHITE is pure luma (survives 4:2:0 crisply) and is period
#     authentic: GEOS is a 1-bit B/W desktop, commonly run on white-phosphor
#     monitors (browser-stream compared 6 vs 7, 2026-07-12).
#   Clock Enable=5 - the template default is slot 4, which CLOBBERS the mouse
#     card ROM/IO (see LINAPPLE KIOSK PATCH note above). Slot 5 is free.
#   SDL audio -> ALSA default (hw:0,0) -> AC97 -> QEMU dbus audiodev -> streamhost.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Apple //e + Apple GEOS deskTop kiosk launcher (kiosk apple2).
# See apple2.sh header for flag rationale. LinApple 2.3.0, bundles the //e ROM.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_VIDEODRIVER=x11
export SDL_VIDEO_CENTERED=1
export SDL_AUDIODRIVER=alsa
cd /opt/bridge/media   # so LinApple loads ./linapple.conf and finds geos.hdv
exec linapple
EOS

# Pointer-wedge watchdog unit (script: assets/apple2/pointer-watchdog.py -> guest
# /opt/bridge/pointer-watchdog.py). Detects the "kernel gets EV_ABS but the X
# pointer is frozen" wedge and restarts the kiosk; see the script's docstring.
read -r -d '' WDUNIT <<'EOS' || true
[Unit]
Description=apple2 kiosk pointer-wedge watchdog (restarts kiosk when Xorg stops applying tablet events)
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /opt/bridge/pointer-watchdog.py
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOS

# ---- boot the station QEMU (exact device set; conditional -loadvm golden) -------
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

# 1. cold boot (no golden yet) and provision LinApple + GEOS inside the overlay
if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for i in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done

  log "installing LinApple build deps into the overlay (SDL1.2 + libzip + imagemagick) ..."
  guest "DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1; \
         DEBIAN_FRONTEND=noninteractive apt-get install -y \
           imagemagick libsdl1.2-dev libsdl-image1.2-dev libcurl4-openssl-dev \
           zlib1g-dev libzip-dev unzip xdotool >/dev/null 2>&1; echo deps-ok"

  log "applying the LinApple kiosk patch (GEOS mouse tracking + no scanline blanking) ..."
  guest "cd /usr/local/src/linapple && patch -p1 -N" <"${ASSETS_DIR}/linapple-kiosk.patch"

  log "building LinApple from /usr/local/src/linapple (fixes the base's failed build) ..."
  guest "cd /usr/local/src/linapple && make >/tmp/linapple-build.log 2>&1 && make install >>/tmp/linapple-build.log 2>&1 && \
         test -x /usr/local/bin/linapple && echo linapple-built || { tail -20 /tmp/linapple-build.log; exit 1; }"

  log "fetching the Apple GEOS mouse HDV (freeware, Asimov mirror; sha256-gated) ..."
  guest "cd /opt/bridge/media && \
         curl -fsSL -o geos-mouse.hdv.zip '${GEOS_URL}' && \
         echo '${GEOS_ZIP_SHA}  geos-mouse.hdv.zip' | sha256sum -c - && \
         unzip -o geos-mouse.hdv.zip >/dev/null && \
         cp 'GEOS-mouse supported by APPLEWIN.hdv' geos.hdv && \
         echo '${GEOS_HDV_SHA}  geos.hdv' | sha256sum -c - && \
         file geos.hdv | grep -q ProDOS && echo geos-hdv-ok"

  log "writing LinApple config (HDD-boot GEOS, mouse slot 4, clock slot 5, mono white, windowed 1.8x) ..."
  guest "cp /usr/local/etc/linapple/linapple.conf ${CONF} && sed -i -E \
     -e 's|^[[:space:]]*Harddisk Enable =.*|\tHarddisk Enable = 1|' \
     -e 's|^[[:space:]]*Harddisk Image 1 =.*|\tHarddisk Image 1 = ${HDV}|' \
     -e 's|^[[:space:]]*Mouse in slot 4 =.*|\tMouse in slot 4 = 1|' \
     -e 's|^[[:space:]]*Soundcard Type =.*|\tSoundcard Type = 1|' \
     -e 's|^[[:space:]]*Boot at Startup =.*|\tBoot at Startup = 1|' \
     -e 's|^[[:space:]]*Fullscreen =.*|\tFullscreen = 0|' \
     -e 's|^[[:space:]]*Screen factor =.*|\tScreen factor = 1.8|' \
     -e 's|^[[:space:]]*Video Emulation =.*|\tVideo Emulation = 7|' \
     -e 's|^[[:space:]]*Clock Enable =.*|\tClock Enable = 5|' \
     ${CONF} && chown bridge:bridge ${HDV} ${CONF} && chmod 664 ${HDV} ${CONF} && chmod 775 /opt/bridge/media && echo conf-ok"

  log "installing /etc/bridge/launch.sh (Apple //e / GEOS) ..."
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh"

  log "installing the in-guest pointer-wedge watchdog (self-heals the multi-day Xorg input wedge) ..."
  guest "cat > /opt/bridge/pointer-watchdog.py && chmod 755 /opt/bridge/pointer-watchdog.py" \
    <"${ASSETS_DIR}/pointer-watchdog.py"
  printf '%s\n' "$WDUNIT" | guest "cat > /etc/systemd/system/pointer-watchdog.service && \
    systemctl daemon-reload && systemctl enable --now pointer-watchdog.service && \
    systemctl is-active pointer-watchdog && echo watchdog-ok"

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

  # restart X so it lands on the GEOS deskTop unattended (kiosk re-runs launch.sh).
  guest "pkill -u bridge linapple 2>/dev/null; sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true

  log "GEOS boots in ~30-45s STRAIGHT to the deskTop (no dialogs - mouse card + its"
  log "VBL interrupt are found now that the clock card is in slot 5). VERIFY via fb:"
  log "  S=$QMP"
  log "  python3 /root/cdrv.py \$S dump /tmp/apple2.ppm; pnmtopng /tmp/apple2.ppm > /tmp/apple2.png  # LOOK: GEOS deskTop?"
  log "  # any 'No interrupt source' / 'No mouse card' dialog => slot 4 is clobbered again: FIX, don't dismiss"
  log "VERIFY the GEOS arrow tracks the abs pointer (move + screendump, then IN-BROWSER):"
  log "  python3 /root/cdrv.py \$S abs 16000 12000; sleep 2; python3 /root/cdrv.py \$S dump /tmp/a.ppm  # arrow ~ (500,375)"
  log "Prove the speaker is non-silent (a cold //e boot beep) — separate capture:"
  log "  python3 /root/qmp_hmp.py \$S 'wavcapture /tmp/boot.wav snd0 44100 16 2'"
  log "  # (restart the kiosk so LinApple cold-boots -> Apple //e power-on beep), then:"
  log "  python3 /root/qmp_hmp.py \$S 'stopcapture 0'   # measure PEAK/RMS with numpy (silence=0)"
  log "Then BAKE the golden fixture (with the CLEAN GEOS deskTop showing, dialogs gone):"
  log "  $0 --bake   # savevm + assert it landed + loadvm + assert it runs"
  log "Emit + start the tile (bridge device set; see qemu-streamhost.sh in ${TILE_DIR}):"
  log "  bash /data/vms/streamhost/scripts/streamhost-station.sh --tile apple2 --vmid ${VMID} \\"
  log "     --udp ${UDP} --pointer abs --audio on --audio-dev ac97 --input-dev usb \\"
  log "     --mem ${MEM} --smp 2 --cpu host --vga std --fps 60"
  log "  # then hand-patch qemu-streamhost.sh to the ide overlay + e1000 hostfwd + conditional -loadvm golden"
  log "  bash ${TILE_DIR}/qemu-streamhost.sh && systemctl start streamhost@${TILE}"
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT, web $WEB_PORT)"
