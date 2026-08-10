#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/daybreak.sh — build the Xerox 6085 "Daybreak" + ViewPoint
# 2.0.5 streamhost tile as a thin overlay on the shared bridge base
# (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 bare-X kiosk running Dwarf/Draco — a Java Mesa
#         architecture emulator — emulating a REAL Xerox 6085 (Daybreak/Dove)
#         workstation booting ViewPoint 2.0.5 off a Pilot rigid-disk image.
#         streamhost captures the Linux framebuffer exactly like every other
#         tile. SILENT exhibit: Dwarf emulates no Xerox sound hardware.
# TYPE  : "emulator bridge" tile (see streamhost/docs/BRIDGE.md). Overlay + a
#         per-tile /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# NOT the GlobalView-on-Windows-3.1 route an earlier feasibility study
# recommended: there is no second emulation layer and no Windows host here.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * Java is NOT in the frozen bridge base; this script apt-installs
#     `openjdk-17-jre` INTO THE OVERLAY. Dwarf's readme asks for Java 8; 17 runs
#     it unchanged, and 17 is what plain bookworm can reach.
#   * Media is fetched from upstream at build time and sha256-VERIFIED; the bits
#     are never committed (the repo is public). `dist.zip` is BSD-3-Clause;
#     `vp2.0.5.zdisk` is Xerox-copyright preservation material. Provenance is
#     written to /opt/bridge/media/daybreak/PROVENANCE in the guest and to
#     docs/lab/ASSETS-MANIFEST.md in the repo.
#   * The disk's ViewPoint "Software Options" are unlocked but BOUND to
#     processor id 10-00-FE-31-AB-21. Changing it re-locks every application, so
#     the emitted properties file pins it and says so.
#   * Dwarf ships ONLY a German keyboard map, and a loaded map has NO DEFAULTS
#     (every key absent from it is dead). This script writes a US map with the
#     Xerox Level-V block unchanged.
#   * NO WINDOW MANAGER runs in the kiosk, so launch.sh must set the X input
#     focus AND synthesise one click inside the Mesa screen. Without BOTH, Swing
#     never receives a key event and every keystroke is silently dropped — the
#     failure that was first misread as an "MP 8000 hang".
#   * The logon is the ONE manual step and is NOT scripted here: it is a
#     five-screen route through the ViewPoint Logon Option Sheet, verified by
#     framebuffer at each step, printed at the end of this run and written out
#     in docs/guests/daybreak.md. Bake the golden at the desktop it reaches.
#   * ACCEPTANCE is a REAL framebuffer screenshot of the ViewPoint desktop —
#     never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by
# pidfile, idempotent, --force to rebuild the overlay. Touches ONLY the daybreak
# tile dir.
#
# Usage:  daybreak.sh [--force] [--bake] [-h]
#   --bake  bake the golden of the ALREADY RUNNING tile and prove it restores
#           (lib/bridge-bake-golden). Boot it under its OWN qemu-streamhost.sh
#           first: a golden taken under a different device set will not loadvm.
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=daybreak
VMID=239
UDP=54139
SSH_PORT=5849
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/tiles/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
MEDIA_DIR="/opt/bridge/media/daybreak" # inside the guest overlay
DWARF_DIR="${MEDIA_DIR}/dwarf"

# Media (fetched at build time, sha256-verified, NEVER committed).
# PINNED TO A COMMIT, NOT TO `master`. Both URLs used to read `.../raw/master/...`
# against the fixed hashes below, and a moving ref plus a fixed hash is not a risk
# but a TIMER: the day devhawala pushes a new dist.zip the fetch succeeds, the hash
# check fails, and the build reports an integrity violation for what is really
# "upstream moved" — the old bytes then unreachable through that ref. A commit is
# immutable: the fetch returns exactly these bytes or 404s, and a 404 reads as the
# truth. Resolved 2026-08-10 via `git ls-remote`; both blobs re-fetched from it and
# re-hashed byte-identical. To advance it: re-resolve, record NEW measured hashes.
DWARF_COMMIT="c264af5e37f89d7aa0eec968aa23818bf5a89837"
DIST_URL="https://github.com/devhawala/dwarf/raw/${DWARF_COMMIT}/dist.zip"
DIST_SHA="67f84b77cbed6cba9d7d2485e84b8142e4fd2403243f8abd8f6e5a81ff6fcf75"
DISK_URL="https://github.com/devhawala/dwarf/raw/${DWARF_COMMIT}/disks-6085/vp2.0.5.zdisk"
DISK_SHA="02bdb53ba7f7896a914fe43b7ca19a620907d0fdbf0f55317b7d1f39aab3f872"

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
    sed -n '2,52p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[daybreak $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }

# ---- boot the tile QEMU (exact device set; conditional -loadvm golden) -------
boot_tile() {
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
  sleep 0.5
  rm -f "$QMP" "$PID"
  local LOADVM=""
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
  nohup qemu-system-x86_64 \
    -name streamhost-${TILE} -enable-kvm -m ${MEM} -smp 2 -machine pc-i440fx-11.0 -cpu host -rtc base=localtime \
    -drive file="${OVERLAY}",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 -device e1000,netdev=n0 \
    $LOADVM \
    -qmp unix:${QMP},server=on,wait=off -pidfile ${PID} \
    >"${TILE_DIR}/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  log "tile booted (loadvm='${LOADVM:-<none: cold>}')"
}

# ---- fetch + verify Dwarf and the ViewPoint disk INTO THE GUEST --------------
fetch_media() {
  log "fetching Dwarf dist.zip + the ViewPoint 2.0.5 Pilot disk (verified sha256) ..."
  guest "bash -s" <<REMOTE
set -e
M=${MEDIA_DIR}; mkdir -p "\$M"; cd "\$M"
command -v unzip >/dev/null || { apt-get update >/dev/null 2>&1; apt-get install -y unzip >/dev/null 2>&1; }
fetch() { # url sha out
  if [ -f "\$3" ] && [ "\$(sha256sum "\$3" | cut -d' ' -f1)" = "\$2" ]; then return 0; fi
  curl -sSL --max-time 600 -o "\$3" "\$1"
  got=\$(sha256sum "\$3" | cut -d' ' -f1)
  [ "\$got" = "\$2" ] || { echo "sha256 mismatch for \$3: \$got"; exit 1; }
}
fetch "${DIST_URL}" "${DIST_SHA}" dist.zip
fetch "${DISK_URL}" "${DISK_SHA}" vp2.0.5.zdisk
rm -rf dwarf && unzip -q dist.zip
mkdir -p dwarf/vp2.0.5/floppies
cp -f vp2.0.5.zdisk dwarf/vp2.0.5/vp2.0.5.zdisk
cat > "\$M/PROVENANCE" <<PV
Xerox 6085 "Daybreak" tile media. Fetched at build time; NEVER committed to the repo.
dist.zip        : Dwarf/Draco Mesa emulator, BSD-3-Clause (redistributable).
                  sha256 ${DIST_SHA}
                  SRC: ${DIST_URL}
vp2.0.5.zdisk   : ViewPoint 2.0.5 Pilot disk for the 6085. XEROX-COPYRIGHT
                  preservation material — the BSD licence on the emulator does
                  NOT cover it. Streamed as pixels only; no download affordance.
                  Software Options are unlocked but BOUND to processor id
                  10-00-FE-31-AB-21; changing it re-locks the applications.
                  sha256 ${DISK_SHA}
                  SRC: ${DISK_URL}
PV
echo "media OK"
REMOTE
}

# ---- the Dwarf configuration, keyboard map and kiosk launcher ---------------
install_config() {
  log "writing the Draco properties, the US keyboard map and /etc/bridge/launch.sh ..."
  guest "cat > ${DWARF_DIR}/vp2.0.5.properties" <<PROPS
# Draco (Xerox 6085 / Daybreak / Dove) running ViewPoint 2.0.5 — gallery tile.
# Derived from Dwarf's shipped vp2.0.5.properties sample.
boot = ./vp2.0.5/vp2.0.5.zdisk
# Dwarf writes disk changes as delta files on a clean stop; a loadvm-golden
# kiosk discards them anyway, so keep one and no more.
oldDeltasToKeep = 1
switches = dOy\\\\175\\\\350{|}
autostart = true
stopOnNetDebug = false
# Product factoring on this disk is unlocked but BOUND to this processor id.
# Changing it re-locks every ViewPoint application. Do not touch.
processorId = 10-00-FE-31-AB-21
title = Xerox 6085
# 19" large screen: 1152x861 monochrome (the 15" is 832x633).
largeScreen = true
keyboardMapFile = ./keyboard-maps/kbd_linux_en_US.map
resetKeysOnFocusLost = false
netHubPort = 3333
localTimeOffsetMinutes = 180
floppyDirectory = ./vp2.0.5/floppies
PROPS

  guest "cat > ${DWARF_DIR}/keyboard-maps/kbd_linux_en_US.map" <<'MAP'
#
# Dwarf keyboard mapping for a US (en_US) keyboard on Linux.
# Derived from the shipped kbd_linux_de_DE.map (Dwarf, BSD-3-Clause) by
# re-seating the letter/punctuation rows on a US layout; the Xerox Level-V
# special keys keep Dwarf's documented Ctrl!<letter> idiom unchanged.
#
# NOTE: when a keyboard map file is loaded there are NO DEFAULTS — any key not
# listed here is dead in the guest. Keep this in step with the SPA's
# 'xerox-dwarf' keyboard profile (spa/src/ui/keyboard/keyboardProfiles.ts).
#

# first row: `1234567890-=
VK_BACK_QUOTE : Bullet
VK_1 : One
VK_2 : Two
VK_3 : Three
VK_4 : Four
VK_5 : Five
VK_6 : Six
VK_7 : Seven
VK_8 : Eight
VK_9 : Nine
VK_0 : Zero
VK_MINUS : Dash
VK_EQUALS : Equal
VK_DELETE : Delete

# second row: qwertyuiop[]
VK_Q : Q
VK_W : W
VK_E : E
VK_R : R
VK_T : T
VK_Y : Y
VK_U : U
VK_I : I
VK_O : O
VK_P : P
VK_OPEN_BRACKET : LeftBracket
VK_CLOSE_BRACKET : RightBracket

# third row: asdfghjkl;'\
VK_A : A
VK_S : S
VK_D : D
VK_F : F
VK_G : G
VK_H : H
VK_J : J
VK_K : K
VK_L : L
VK_SEMICOLON : SemiColon
VK_QUOTE : Quote
VK_BACK_SLASH : DoubleQuote

# fourth row: zxcvbnm,./
VK_Z : Z
VK_X : X
VK_C : C
VK_V : V
VK_B : B
VK_N : N
VK_M : M
VK_COMMA : Comma
VK_PERIOD : Period
VK_SLASH : Slash

# fifth row
VK_ALT : Special
VK_SPACE : Space
VK_ALT_GRAPH : Expand

# others
VK_SHIFT : LeftShift
VK_TAB : ParaTab
VK_ENTER : NewPara
VK_BACK_SPACE : BS
VK_CAPS_LOCK : Lock

# function keys (ViewPoint text-property keys)
VK_F2 : Center
VK_F3 : Bold
VK_F4 : Italic
VK_F5 : Case
VK_F6 : Strikeout
VK_F7 : Underline
VK_F8 : SuperSub
VK_F9 : Smaller
VK_F10 : Margins
VK_F11 : Font

# Xerox Level-V special keys (Ctrl + letter)
VK_ESCAPE : Stop
Ctrl!VK_ESCAPE : Stop
Ctrl!VK_M : Move
Ctrl!VK_C : Copy
Ctrl!VK_S : Same
Ctrl!VK_O : Open
Ctrl!VK_P : Props
Ctrl!VK_F : Find
Ctrl!VK_H : Help
Ctrl!VK_U : Undo
Ctrl!VK_A : Again
Ctrl!VK_N : Next
MAP

  guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh" <<'EOS'
#!/bin/bash
# Xerox 6085 "Daybreak" kiosk launcher: Dwarf/Draco running ViewPoint 2.0.5.
#
# Two non-obvious steps, both paid for once (see docs/guests/daybreak.md):
#  * the X root is resized to a CUSTOM 1152x914 mode so the Dwarf frame
#    (1152x913: a 1152x861 Mesa screen + toolbar + status line) fills the
#    captured framebuffer edge to edge with no dead gutter;
#  * no window manager runs in the kiosk, so nothing assigns the X input focus
#    and nothing gives the Swing display panel the component focus. The launcher
#    therefore sets the input focus by hand AND synthesises one click inside the
#    Mesa screen. Without both, every keystroke is silently dropped -- including
#    the Ctrl+N (Xerox NEXT) that wakes the logged-off screen.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$OUT" ]; then
  xrandr --newmode daybreak 79.0 1152 1216 1336 1520 914 917 927 950 -hsync +vsync 2>/dev/null || true
  xrandr --addmode "$OUT" daybreak 2>/dev/null || true
  xrandr --output "$OUT" --mode daybreak 2>/dev/null || true
fi
xsetroot -solid grey20 2>/dev/null || true
cd /opt/bridge/media/daybreak/dwarf || exit 1
java -jar dwarf.jar -draco vp2.0.5 >/tmp/draco.log 2>&1 &
JPID=$!
for _ in $(seq 1 90); do
  WID=$(xdotool search --name 'Xerox 6085' 2>/dev/null | tail -1)
  if [ -n "$WID" ]; then
    xdotool windowfocus "$WID" 2>/dev/null || true
    xdotool mousemove 400 400 click 1 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$JPID"
EOS
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

if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  if ! guest "command -v java >/dev/null"; then
    log "installing openjdk-17-jre + xdotool into the overlay ..."
    guest "export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1; apt-get install -y openjdk-17-jre unzip xdotool x11-utils >>/tmp/apt.log 2>&1; java -version"
  fi
  fetch_media
  install_config
  # Disk checkpoint before the getty-restart below drives the guest; see
  # lib/bridge-coldboot. Needs the VM stopped, so stop this build's own
  # boot_tile() and cold-boot it again — the getty-restart still re-applies.
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null
  for _ in $(seq 1 40); do
    { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; } || break
    sleep 0.25
  done
  rm -f "$QMP" "$PID"
  "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile
  boot_tile
  log "waiting for guest ssh ..."
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  guest "systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  cat <<NEXTSTEPS

[daybreak] The kiosk is starting Draco. From here the route is MANUAL and every
step must be checked against a real framebuffer screenshot:

  shot() { python3 /root/qmp_hmp.py $QMP "screendump /tmp/db.ppm"; pnmtopng /tmp/db.ppm > /tmp/db.png; }

  1. ~90 s  -> the LOGGED-OFF screen: a small bouncing keyboard on black, '8000'
              in the status bar. MP 8000 is Pilot's normal run state, NOT a hang.
  2. Ctrl+N (the Xerox NEXT key; 400 ms hold) -> the Logon Option Sheet.
  3. Click the Name field, type 'guest'; click Password, type 'guest'.
     Every click and key needs ~400 ms dwell — a zero-length chord lands nothing.
  4. Click [Start] -> "the Clearinghouse is down" -> "Do you want a new Desktop
     created for you?" with YES selected. Click [Start] again.
  5. ~45 s  -> the ViewPoint DESKTOP: dithered grey desk, 'NNNNN Free Disk Pages'
              in the message area, a Directory icon bottom right.

Then BAKE the golden with that desktop showing:

   $0 --bake     # savevm + assert it landed + loadvm + assert it restores running

Re-run this script afterwards to boot straight into the fixture. Emit + start:

   /data/vms/streamhost/scripts/streamhost-tile.sh --tile ${TILE} --vmid ${VMID} --udp ${UDP} \\
       --pointer abs --audio off --fps 60 \\
       --launcher-file  <repo>/streamhost/tiles/${TILE}/qemu-streamhost.sh \\
       --env-append-file <repo>/streamhost/tiles/${TILE}/tile.env.fixture
   bash ${TILE_DIR}/qemu-streamhost.sh && systemctl start streamhost@${TILE}
   labctl gen

NEXTSTEPS
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT)"
