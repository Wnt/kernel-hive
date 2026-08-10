#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/star.sh — build the Xerox Star 8010 "Dandelion" +
# Pilot / ViewPoint 2.0 streamhost tile as a thin overlay on the shared bridge
# base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 bare-X kiosk running Darkstar — a C#/mono
#         emulator of the REAL Xerox 8010 "Dandelion" workstation — booting
#         Pilot and ViewPoint 2.0 off a 1990 rigid-disk image. streamhost
#         captures the Linux framebuffer exactly like every other tile.
#         SILENT exhibit: the 8010 has no sound hardware and Darkstar emulates
#         none.
# TYPE  : "emulator bridge" tile (see streamhost/docs/BRIDGE.md). Overlay + a
#         per-tile /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# SIBLING, NOT DUPLICATE, of the `daybreak` tile: that is the 1985 Xerox 6085
# under Dwarf/Draco (Java). THIS is the 1981 8010 itself — the first machine
# ever sold with a desktop, icons, folders and a mouse — under a different
# emulator, from different media.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * Mono is NOT in the frozen bridge base; this script apt-installs
#     `mono-complete mono-xbuild nuget libgdiplus` INTO THE OVERLAY and BUILDS
#     Darkstar there from a pinned upstream commit. Darkstar is .NET Framework
#     4.5 WinForms with an SDL2 surface embedded via SDL_CreateWindowFrom, so
#     Mono's WinForms X11 driver is a hard dependency — dotnet/CoreCLR cannot
#     run it.
#   * THREE Linux fixes are needed, not the two the upstream notes imply:
#       1. delete the bundled Windows `SDL2.dll`;
#       2. add `SDL2-CS.dll.config` with a dllmap to `libSDL2-2.0.so.0`;
#       3. Darkstar resolves its IOP PROM / CP microcode paths RELATIVE TO THE
#          CWD, so it must be started from `D/bin/Release`. `-rompath` is not a
#          tree root — it REPLACES the whole `IOP/PROM` prefix — so do not pass
#          it.
#   * The Xerox software is TIME-LOCKED ("Product Factoring"). The TOD clock
#     must read December 1997 or the boot stalls at MP 7800 indefinitely; a
#     1990 TOD was measured stalling for >12 minutes, twice. star.cfg pins
#     1997/12/01 and the perpetual ViewPoint 2.0 / Services 11.0 option key
#     published by the emulator's own readme.
#   * The X root is a CUSTOM 1088x860 mode — exactly the Star's own display —
#     and launch.sh moves the 1091x915 WinForms window to (0,-29) so the
#     emulator's System Menu and System Status bars sit off-screen and the
#     captured framebuffer is the Star screen and nothing else.
#   * X runs with `-nocursor`: Darkstar draws the Star's own cursor into its
#     framebuffer, so the X core pointer would be a second, wrong arrow.
#   * POINTER IS RELATIVE, and that is correct rather than a compromise.
#     Darkstar has no absolute path at all: DWindow-IO computes
#     `dx = x - DisplayBox.Width/2`, feeds IOP.Mouse.MouseMove(dx,dy) and warps
#     the host pointer back to the centre. So the tile runs the same
#     `SH_POINTER=rel` / no-usb-tablet / `vmport=off` device set as c64, qnx and
#     nt351: streamhost differences the absolute browser sample and injects
#     bounded, paced PS/2 deltas. `xset m 1 0` disables X pointer acceleration
#     so a browser delta reaches Darkstar 1:1 — WITHOUT it every delta is
#     scaled by X and the Star cursor overshoots.
#   * The first boot is 22 MINUTES and INTERACTIVE (five carriage returns
#     through the Pilot Set Time Utility, then one NEXT to wake the logged-off
#     screen, then Desktop Creation and a logon). It is NOT scripted here: it is
#     driven once at bake time, framebuffer-verified at every step, and then
#     frozen into the golden. Printed at the end of this run and written up in
#     docs/guests/star.md.
#   * `xdotool windowclose` is NOT a clean exit for Darkstar and SILENTLY
#     DISCARDS the disk image — the image is written only from
#     Program.cs -> system.Shutdown() -> _hardDrive.Save(). For this tile that
#     is moot (the golden is a QEMU RAM+device snapshot), but any script that
#     wants the .img must drive System -> Exit and wait for the process to go.
#   * ACCEPTANCE is a REAL framebuffer screenshot of the ViewPoint desktop —
#     never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by
# pidfile, idempotent, --force to rebuild the overlay. Touches ONLY the star
# tile dir.
#
# Usage:  star.sh [--force] [-h]
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=star
VMID=240
UDP=54138
SSH_PORT=5840
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/tiles/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
MEM=1536
MEDIA_DIR="/opt/star" # inside the guest overlay

# Darkstar: BSD-2-Clause on Josh Dersch's code. The repo ALSO ships Xerox bits
# (the Dandelion IOP PROM dumps 537P030xx.bin and the CP microcode), which are
# Xerox-copyright preservation material — no separate ROM hunt is needed and no
# ROM is ever committed here.
DARKSTAR_REPO="https://github.com/livingcomputermuseum/Darkstar.git"
DARKSTAR_COMMIT="7ab55ff3d5c1802e7e69561a04b3e845ef92b53e" # 2026-04-08

# Media (fetched at build time, sha256-verified, NEVER committed).
HD_URL="https://bitsavers.org/bits/Xerox/8010/8010_hd_images.zip"
HD_SHA="d9fb11362229ba7b9dbb7500f2240f9c1e9cdaa9f37bb4431221174483ca438e"
VP_IMG="ViewPoint-2.0-11-9-1990-18-38.img"
VP_SHA="a7ead97a18d748debd769e5d2358f05ece24f10a5421e9fbc73b598e4a7f7020"

FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --force)
    FORCE=1
    shift
    ;;
  -h | --help)
    sed -n '2,74p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[star $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }

# ---- boot the tile QEMU (exact device set; conditional -loadvm golden) -------
# NO usb-tablet and vmport=off: the Star's mouse is relative, so QEMU must
# present the plain PS/2 mouse and must not let the VMware-mouse handler absorb
# the REL events first (the c64 lesson, docs/guests/c64.md).
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
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  log "tile booted (loadvm='${LOADVM:-<none: cold>}')"
}

# ---- build Darkstar INSIDE the overlay --------------------------------------
build_darkstar() {
  log "cloning + building Darkstar ${DARKSTAR_COMMIT:0:8} in the overlay ..."
  guest "bash -s" <<REMOTE
set -e
M=${MEDIA_DIR}; mkdir -p "\$M"; cd "\$M"
if [ ! -d Darkstar/.git ]; then
  git clone -q ${DARKSTAR_REPO} Darkstar
fi
cd Darkstar
git fetch -q origin || true
git checkout -q ${DARKSTAR_COMMIT}
nuget restore D.sln >/tmp/nuget.log 2>&1 || { tail -20 /tmp/nuget.log; exit 1; }
xbuild /p:Configuration=Release D.sln >/tmp/xbuild.log 2>&1 || { tail -30 /tmp/xbuild.log; exit 1; }
R=\$M/Darkstar/D/bin/Release
[ -f "\$R/Darkstar.exe" ] || { echo "no Darkstar.exe after build"; exit 1; }
# Linux fixes 1 + 2: the bundled Windows SDL2.dll must go, and SDL2-CS needs a
# dllmap to the system libSDL2 or it dies with DllNotFoundException.
rm -f "\$R/SDL2.dll"
cat > "\$R/SDL2-CS.dll.config" <<'CFG'
<configuration>
  <dllmap dll="SDL2.dll" target="libSDL2-2.0.so.0"/>
</configuration>
CFG
echo "darkstar built OK: \$(ls -l "\$R/Darkstar.exe" | awk '{print \$5}') bytes"
REMOTE
}

# ---- fetch + verify the ViewPoint 2.0 rigid-disk image ----------------------
fetch_media() {
  log "fetching the bitsavers 8010 hard-disk images (verified sha256) ..."
  guest "bash -s" <<REMOTE
set -e
M=${MEDIA_DIR}; mkdir -p "\$M/run"; cd "\$M"
if [ ! -f 8010_hd_images.zip ] || [ "\$(sha256sum 8010_hd_images.zip | cut -d' ' -f1)" != "${HD_SHA}" ]; then
  curl -sSL --max-time 900 -o 8010_hd_images.zip "${HD_URL}"
  got=\$(sha256sum 8010_hd_images.zip | cut -d' ' -f1)
  [ "\$got" = "${HD_SHA}" ] || { echo "sha256 mismatch for the 8010 pack: \$got"; exit 1; }
fi
if [ ! -f "\$M/run/vp20.img" ]; then
  unzip -o -q 8010_hd_images.zip "${VP_IMG}"
  got=\$(sha256sum "${VP_IMG}" | cut -d' ' -f1)
  [ "\$got" = "${VP_SHA}" ] || { echo "sha256 mismatch for ${VP_IMG}: \$got"; exit 1; }
  # The work image is what Darkstar boots and writes back to; the pristine
  # extract stays beside it so a rebuild never re-downloads 14 MB.
  cp -f "${VP_IMG}" "\$M/run/vp20.img"
fi
cat > "\$M/PROVENANCE" <<PV
Xerox Star 8010 "Dandelion" tile media. Fetched at build time; NEVER committed.
8010_hd_images.zip : bitsavers pack of three Dandelion rigid-disk images
                     (ViewPoint 2.0, XDE 5.0, Interlisp-D Harmony).
                     sha256 ${HD_SHA}   SRC: ${HD_URL}
${VP_IMG}
                   : the ViewPoint 2.0 / Services 11.0 Pilot volume this tile
                     boots. XEROX-COPYRIGHT preservation material: Xerox never
                     released ViewPoint or Pilot and there is no licence grant.
                     Streamed as pixels only; no download affordance.
Darkstar           : ${DARKSTAR_REPO} @ ${DARKSTAR_COMMIT}
                     BSD-2-Clause on the emulator code. The repo also carries
                     Xerox-copyright Dandelion IOP PROM dumps and CP microcode,
                     which are preservation material on the same footing.
PV
echo "media OK: \$(sha256sum "\$M/run/vp20.img" | cut -d' ' -f1)"
REMOTE
}

# ---- Darkstar configuration, kiosk launcher, cursor-free X session ----------
install_config() {
  log "writing star.cfg, /etc/bridge/launch.sh and the -nocursor kiosk profile ..."
  guest "cat > ${MEDIA_DIR}/run/star.cfg" <<PROPS
# Xerox 8010 "Dandelion" running Pilot + ViewPoint 2.0 — gallery tile.
MemorySize = 0x400
HostID = 0x0000aa012345
HardDriveImage = ${MEDIA_DIR}/run/vp20.img
DisplayScale = 1
SlowPhosphor = true
# THE TIME LOCK. Xerox "Product Factoring" expires this software; a 1990 TOD
# stalls the boot at MP 7800 for >12 minutes. December 1997 is the date the
# emulator's published perpetual option keys are cut for. Do not change it.
TODSetMode = SpecificDateAndTime
TODDateTime = 1997/12/01 09:00:00
# Rigid (not DiagnosticRigid): skips the long power-on memory diagnostic.
AltBootMode = Rigid
Start = true
PROPS

  guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh" <<'EOS'
#!/bin/bash
# Xerox Star 8010 kiosk launcher: Darkstar on mono. See star.sh for rationale.
#
# Three non-obvious steps, each paid for once (docs/guests/star.md):
#  * a CUSTOM 1088x860 X mode — the Star's own display, exactly — and the
#    1091x915 WinForms window moved to (0,-29) so Darkstar's System Menu and
#    System Status bars fall outside the captured framebuffer. What streamhost
#    captures is then the Star screen and nothing else.
#  * no window manager runs here, so nothing assigns the X input focus. Keys
#    must reach the WinForms TOP-LEVEL window; the SDL child window lands
#    nothing, because Darkstar embeds SDL with SDL_CreateWindowFrom and handles
#    keys on the form.
#  * X pointer ACCELERATION is off -- but NOT via `xset m`, which under
#    libinput reports "acceleration 1/1 threshold 0" while the device happily
#    goes on applying its own adaptive profile. The real switch is the
#    xorg.conf.d InputClass this script installs. Measured before it existed:
#    ~1.8x on medium moves, so the Star cursor overshot every target.
#  * X AUTOREPEAT is off. Darkstar wants a ~300 ms key hold, X repeats after
#    660 ms, and Pilot does its own repeat -- leave autorepeat on and a
#    deliberate hold enters the character several times.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_VIDEODRIVER=x11
export SDL_RENDER_DRIVER=software
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$OUT" ]; then
  xrandr --newmode star 76.0 1088 1144 1256 1424 860 861 864 891 -hsync +vsync 2>/dev/null || true
  xrandr --addmode "$OUT" star 2>/dev/null || true
  xrandr --output "$OUT" --mode star 2>/dev/null || true
fi
xsetroot -solid black 2>/dev/null || true
xset -r 2>/dev/null || true
cd /opt/star/Darkstar/D/bin/Release || exit 1
mono ./Darkstar.exe -config /opt/star/run/star.cfg >/tmp/darkstar.log 2>&1 &
DPID=$!
for _ in $(seq 1 120); do
  WID=$(xdotool search --name '^Darkstar$' 2>/dev/null | head -1)
  if [ -n "$WID" ]; then
    xdotool windowmove "$WID" 0 -29 2>/dev/null || true
    xdotool windowfocus "$WID" 2>/dev/null || true
    # ARM THE MOUSE. Darkstar does not track the pointer until the display has
    # been clicked once ("Click on the display to capture mouse/keyboard" in its
    # status bar): that click turns on the SDL grab and the relative-motion path
    # the whole tile depends on. Do it here, with real dwell, so the capture is
    # already armed inside the golden and no visitor spends their first click
    # buying it. NOTE the other half of the same switch: EITHER Alt key RELEASES
    # the capture, which is why the tile remaps both Alt scancodes away
    # (SH_KEY_REMAP in tile.env.fixture).
    sleep 3
    xdotool mousemove 544 430 2>/dev/null || true
    xdotool mousedown 1 2>/dev/null || true
    sleep 0.4
    xdotool mouseup 1 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$DPID"
EOS

  # THE POINTER ACCELERATION FIX, and it is not `xset`. The Star's mouse is
  # relative: streamhost differences the browser's absolute sample and injects
  # bounded PS/2 deltas, and Darkstar turns host pointer motion into
  # IOP.Mouse.MouseMove deltas. Anything in between that rescales a delta makes
  # the Star cursor overshoot -- measured at ~1.8x before this file existed.
  # Under libinput the core pointer control reports "acceleration: 1/1
  # threshold: 0" while the DEVICE still applies its own adaptive profile, so
  # `xset m 1 0` looks like it worked and does nothing. Only the driver option
  # turns it off.
  guest "cat > /etc/X11/xorg.conf.d/20-star-pointer.conf" <<'PTR'
Section "InputClass"
    Identifier  "star-flat-pointer"
    MatchIsPointer "on"
    Driver      "libinput"
    Option      "AccelProfile" "flat"
    Option      "AccelSpeed" "0"
EndSection
PTR

  # Kiosk session profile: X with NO core pointer cursor. Darkstar paints the
  # Star's own cursor into its framebuffer, so the X arrow would be a second,
  # wrong pointer sitting in the captured frame.
  guest "cat > /home/bridge/.bash_profile; chown bridge:bridge /home/bridge/.bash_profile" <<'EOS'
# Bridge kiosk session (star overlay). X starts with NO core pointer cursor:
# Darkstar draws the Star's own cursor, and the X arrow would double it.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

  # stardrv: the bake-time / operator driver, baked into the overlay so the
  # timings Darkstar needs live WITH the tile instead of in someone's shell
  # history. See docs/guests/star.md.
  guest "cat > /usr/local/bin/stardrv; chmod +x /usr/local/bin/stardrv" <<'DRV'
#!/bin/bash
# Drive the Xerox Star 8010 kiosk (Darkstar) from inside the guest.
#   stardrv key <key>...      each key: press, hold, release, gap
#   stardrv shift <key>       one shifted key, modifier led and held
#   stardrv rel <dx> <dy>     walk the pointer by (dx,dy) in <=50 px steps
#   stardrv click [<dx> <dy>] optional walk, then a 400 ms button-1 dwell
#   stardrv adjust            a 400 ms button-3 (ADJUST) dwell
# Everything here is dwell. A ~12 ms XTEST press lands NOTHING in Pilot; keys go
# to the WinForms TOP-LEVEL window (the SDL child lands nothing); the modifier
# is a key and gets its own lead. Pointer moves are RELATIVE nudges around the
# DisplayBox centre, walked in small steps because the Star drops large deltas.
set -u
export DISPLAY=:0 XAUTHORITY=/home/bridge/.Xauthority
HOLD=${STAR_HOLD:-0.30}
GAP=${STAR_GAP:-0.35}
LEAD=${STAR_LEAD:-0.60}
DWELL=${STAR_DWELL:-0.40}
STEP=50
CX=544
CY=430
focus() {
  W=$(xdotool search --name '^Darkstar$' | head -1)
  [ -n "$W" ] || { echo "no Darkstar window" >&2; exit 1; }
  xdotool windowfocus "$W"
  sleep 0.3
}
case "${1:-}" in
key)
  shift
  focus
  for k in "$@"; do
    xdotool keydown "$k"; sleep "$HOLD"; xdotool keyup "$k"; sleep "$GAP"
  done
  ;;
shift)
  focus
  xdotool keydown Shift_L; sleep "$LEAD"
  xdotool keydown "$2"; sleep 0.45; xdotool keyup "$2"
  sleep 0.3; xdotool keyup Shift_L
  ;;
rel)
  dx=$2; dy=$3
  while [ "$dx" -ne 0 ] || [ "$dy" -ne 0 ]; do
    if [ "$dx" -gt "$STEP" ]; then sx=$STEP; elif [ "$dx" -lt -"$STEP" ]; then sx=-$STEP; else sx=$dx; fi
    if [ "$dy" -gt "$STEP" ]; then sy=$STEP; elif [ "$dy" -lt -"$STEP" ]; then sy=-$STEP; else sy=$dy; fi
    xdotool mousemove $((CX + sx)) $((CY + sy)); sleep 0.12
    dx=$((dx - sx)); dy=$((dy - sy))
  done
  ;;
click)
  [ $# -lt 3 ] || "$0" rel "$2" "$3"
  xdotool mousedown 1; sleep "$DWELL"; xdotool mouseup 1
  ;;
adjust) xdotool mousedown 3; sleep "$DWELL"; xdotool mouseup 3 ;;
*) sed -n '2,8p' "$0"; exit 2 ;;
esac
DRV
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
  if ! guest "command -v mono >/dev/null"; then
    log "installing mono + the Darkstar build chain into the overlay ..."
    guest "export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1; apt-get install -y mono-complete mono-xbuild nuget libgdiplus libsdl2-2.0-0 git unzip xdotool x11-utils x11-xserver-utils xinput >>/tmp/apt.log 2>&1; mono --version | head -1"
  fi
  build_darkstar
  fetch_media
  install_config
  guest "systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  cat <<NEXTSTEPS

[star] The kiosk is starting Darkstar. From here the route is MANUAL, takes
about 25 minutes, and every step must be checked against a real framebuffer
screenshot — MP codes are not a progress bar and a still screen is not a dead
machine.

  shot() { python3 /root/qmp_hmp.py $QMP "screendump /tmp/s.ppm"; pnmtopng /tmp/s.ppm > /tmp/s.png; }

  1. ~5 min   -> the Pilot Set Time Utility 2.0 banner, after the MP code walks
                0910 -> 7600 -> 7700 -> 7800. MP 7600 sits for 6-8 minutes on a
                blank white page with zero disk I/O; that is SLOW, not hung.
  2. FIVE carriage returns answer the whole Set Time dialogue (time-zone
     offset, minute offset, first/last day of DST, "change the time? N").
     Every key needs a ~300 ms hold on the WinForms TOP-LEVEL window.
  3. ~14 min  -> MP 8000 and the bouncing-keyboard LOGGED-OFF screen.
  4. Home (= Xerox NEXT) wakes it onto the Workstation Administration desktop.
  5. Desktop Creation -> name it (the shipped image already owns
     user:star:xerox, so pick another), password, arm Administrator, Start.
     The machine logs itself out.
  6. Home again -> the real Logon Option Sheet -> log on as the user you made.
  7. The ICONIC ViewPoint user desktop: grey stipple, "NNNNN Free Disk Pages"
     with a Help button, and the Directory icon bottom-right.

Then BAKE the golden with that desktop showing, and CHECK WHAT IT RESTORES INTO
(a golden baked while the VM was stopped restores PAUSED, which looks perfect
and is dead):

   python3 /root/qmp_hmp.py $QMP 'savevm golden'
   python3 /root/qmp_hmp.py $QMP 'loadvm golden'
   python3 /root/qmp_hmp.py $QMP 'info status'    # must say 'running'

Re-run this script afterwards to boot straight into the fixture. Emit + start:

   /data/vms/streamhost/scripts/streamhost-tile.sh --tile ${TILE} --vmid ${VMID} --udp ${UDP} \\
       --pointer rel --audio off --fps 30 \\
       --launcher-file  <repo>/streamhost/tiles/${TILE}/qemu-streamhost.sh \\
       --env-append-file <repo>/streamhost/tiles/${TILE}/tile.env.fixture
   bash ${TILE_DIR}/qemu-streamhost.sh && systemctl start streamhost@${TILE}
   labctl gen

NEXTSTEPS
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT)"
