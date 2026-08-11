#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/nextstep.sh — build the NeXTcube / NeXTSTEP 3.3 streamhost station
# as a thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running the **Previous** emulator (NeXT
#         hardware, SourceForge SVN trunk r1847 == release 4.4) as a NeXTcube:
#         Motorola 68040 at 25 MHz, 64 MB, ROM Rev 2.5 v66, MegaPixel 1120x832
#         2-bit greyscale display, booting NeXTSTEP 3.3 for m68k off a SCSI disk
#         image. streamhost captures the Linux framebuffer + AC97 audio exactly
#         like every other kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY PREVIOUS AND NOT QEMU (the route decision, made on evidence) -------
#   docs/guests/nextstep.md §1 has the full costing and the QEMU-10 dead end:
#   NeXTSTEP 3.3 for INTEL runs only on QEMU <= 0.9.x, while Previous emulates a
#   real NeXTcube, builds in ~9 min, boots a PRE-INSTALLED image, and ships the
#   ROM in its own source tree (src/Rev_2.5_v66.BIN).
#
# ---- WHAT IS BUILT INTO THE OVERLAY (the frozen base has none of it) --------
#   1. SDL3 3.4.14 from source. Previous 4.4 requires SDL3 >= 3.2 and Debian 12
#      only ships SDL2. `-DSDL_X11_XTEST=ON` needs libxtst-dev; without it cmake
#      fails with "Couldn't find dependency package for XTEST".
#   2. Previous r1847, cmake+make, ~9 min at -j2, plus one local patch (below).
#   3. The NeXTSTEP 3.3 disk image, fetched and sha256-verified at build time.
#
# ---- THE FIVE TRAPS, IN THE ORDER THEY BIT ----------------------------------
#   1. `panic: (Cpu 0) Root device is physically write protected.` NeXTSTEP
#      boots, finds the disk, and dies on its first write. The kiosk runs as
#      `bridge`, and a root-owned 0644 disk image opens read-only — the same
#      trap the pdp11 station hit with its MSCP pack. chown the image to `bridge`.
#   2. `SDL screen scale: 0.971`. With no window manager to answer, Previous
#      ASSUMES a decorated desktop (50 px top and bottom, 25 px each side) and
#      shrinks the emulated screen to fit, resampling 1120x832 down to 1088x808
#      — blurring a 1-bit-crisp Display PostScript UI and destroying the 1:1
#      pixel map the pointer depends on. Patched: see
#      ../patches/previous-wmless-window-borders.patch.
#   3. NO INPUT AT ALL, for hours. With no window manager nobody ever calls
#      XSetInputFocus, so the X focus stays None and SDL3 hands Previous no key
#      events; and with the pointer already inside the window when it is mapped
#      there is no EnterNotify either, so SDL never takes a mouse focus. A live
#      NeXTSTEP that ignores everything. Fixed by nextstep-kiosk-frame.sh.
#   4. STILL no input reaching the MACHINE, while Previous's own F12 menu
#      answered. Built with ENABLE_RENDERING_THREAD=0 (the default off macOS)
#      Previous queues guest key/mouse events on a ring buffer nothing drained:
#      `[Keymap]` never logged once at nTextLogLevel=5. Rebuilt with
#      -DENABLE_RENDERING_THREAD=1 the events go straight to Keymap_KeyDown /
#      Keymap_MouseMove. THE TILE MUST BE BUILT WITH THAT FLAG.
#   5. 135% of CPU in four llvmpipe threads, and a keystroke taking 5-33 s to
#      appear. SDL_RENDER_DRIVER=software was already set and the renderer really
#      was "software", but SDL3 still PRESENTED through an accelerated window
#      surface — llvmpipe, on a GPU-less host. SDL_FRAMEBUFFER_ACCELERATION=0
#      drops it to XPutImage: no llvmpipe thread, RSS 375 MB -> 106 MB, and the
#      same keystroke lands in 0.58 s. Do not remove that variable.
#
# ---- POINTER: ABSOLUTE, THROUGH THE MACHINE'S OWN TABLET --------------------
#   Previous also emulates a graphics tablet: src/tablet.c simulates a
#   SummaGraphics digitiser on the NeXT SCC serial port B, and sdlevent.c feeds
#   it the host's ABSOLUTE window coordinates whenever `[Tablet] nTabletType` is
#   non-zero AND the guest driver has enabled it — only otherwise does it fall
#   back to the relative kms_mouse_move(). NeXTSTEP 3.3 ships the matching driver
#   on the disk (/NextAdmin/InstallTablet.app, setuid root), so NOTHING is
#   compiled: this golden carries no m68k toolchain and does not need one.
#   So: nTabletType = 2 (SummaGraphics MM 1201), `-usb -device usb-tablet`,
#   SH_INPUT_BACKEND=dbus-abs, and a golden baked with the driver ATTACHED —
#   nextstep-tablet-install.py does that below and re-proves the 1:1 map.
#   `vmport=off` STAYS: QEMU's implicit VMware mouse would otherwise be a second
#   absolute pointer competing with the usb-tablet. The X root being EXACTLY
#   1120x832 at +0+0 is now LOAD-BEARING for that 1:1 map, not cosmetic.
#   The driver is a kernel server loaded at install time and does NOT survive a
#   COLD boot — which is precisely why the exhibit's reset model fits: `loadvm
#   golden` restores RAM and device state rather than booting. A cold boot lands
#   on the old relative path until the installer is run again.
#
# ---- KEY PACING: NOT APPLICABLE ---------------------------------------------
#   This is a GUI exhibit, not a type-in exhibit. There is no emulated keyboard
#   matrix sampled once per frame here — the NeXT keyboard is a serial device
#   polled by the KMS — so playbook 5.1's SH_KEY_MIN_HOLD_MS/GAP knobs are not
#   set and the station does not need the pacing canary binary.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the
# nextstep station dir; refuses to run while streamhost@nextstep is active.
#
# Usage: nextstep.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=nextstep
VMID=237
UDP=54134
SSH_PORT=5837
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/nextstep
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# -m 1536 / -smp 4 are measured, not guessed: at 1536 MB the guest still reports
# 957 MB MemAvailable with `previous` resident at 247 MB (host QEMU RSS 1.06 GB),
# and at -smp 2 the emulator ran at half real speed and its input queue backed up.
MEM=1536
SMP=4
# Overlay disk. The backing base is 6 GiB with ~2.6 GiB free, and the NeXTSTEP
# image alone is a 2 GB sparse file, so the overlay is grown before first boot.
DISK=16G
SDL3_VER=3.4.14
SDL3_SHA=30d4aa2b3037718142b32dffd4e72f917ebb6cc5227150e7bb9c45efb2153aeb
PREVIOUS_REV=1847 # SVN trunk r1847 == Previous 4.4, released 2026-07-06
NS_URL="https://archive.org/download/nextstep-3.3-hd-image-with-previous.-7z/Nextstep%203.3%20HD%20Image%20With%20Previous.7z"
NS_7Z_SHA=6940df2a00cc9cc1f8849667deeb7d30c6fb4aced2e31d44d719df32db059b47
NS_DD_SHA=6381423b066c33c24c9c9ec519086708b9cf3b2f11882fed5319cfb6a3422f1b
ROM_SHA=1b753890b67095b73e104c939ddf62eca9e7d0aedde5108e3893b0ed9d8000a4

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,120p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[nextstep $(date +%H:%M:%S)] $*"; }
die() {
  echo "[nextstep] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    -p "$SSH_PORT" root@127.0.0.1 "$@"
}
put() {
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -P "$SSH_PORT" "$1" "root@127.0.0.1:$2"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# NeXTcube (68040) / NeXTSTEP 3.3 kiosk launcher — kiosk 'nextstep'.
# Every flag's rationale is in scripts/build-guests/tiles/nextstep.sh.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_VIDEODRIVER=x11
# SDL_FRAMEBUFFER_ACCELERATION=0 is the expensive one to have found. The
# renderer was ALREADY "software", but SDL3 still presented it through an
# accelerated window surface — llvmpipe on this GPU-less host: four threads at
# 135% CPU, RSS 375 MB, and a keystroke taking 5-33 s to reach the screen. With
# the accelerated surface refused it is XPutImage, no llvmpipe thread, RSS
# 106 MB, and the same keystroke lands in 0.58 s.
export SDL_RENDER_DRIVER=software
export SDL_FRAMEBUFFER_ACCELERATION=0
export LIBGL_ALWAYS_SOFTWARE=1
LOG=/tmp/nextstep-launch.log
{
  echo "=== launch $(date -Is) DISPLAY=$DISPLAY"
  OUT=$(xrandr 2>&1 | awk '/ connected/{print $1; exit}')
  # The NeXT MegaPixel display is 1120x832 and no stock mode is that size. Make
  # the X root EXACTLY the emulated screen. DO NOT CHANGE THIS GEOMETRY: it is
  # load-bearing, not cosmetic. The absolute pointer is a straight 1:1 map from
  # this root to the NeXT tablet's coordinate space, so any other size silently
  # scales every visitor's click; it also keeps both cursors clamping together.
  xrandr --newmode 1120x832 76.00 1120 1184 1304 1488 832 835 845 852 -hsync +vsync 2>&1
  xrandr --addmode "$OUT" 1120x832 2>&1
  xrandr --output "$OUT" --mode 1120x832 2>&1
  xrandr 2>&1 | head -2
} >"$LOG" 2>&1
setsid nohup /usr/local/bin/nextstep-kiosk-frame.sh >/dev/null 2>&1 &
exec /usr/local/bin/previous 2>/tmp/previous.err
EOS

read -r -d '' PREVIOUS_CFG <<'EOS' || true
[Log]
nTextLogLevel = 1
nAlertDlgLogLevel = 0
bConfirmQuit = FALSE
bConsoleWindow = FALSE

[ConfigDialog]
bShowConfigDialogAtStartup = FALSE

[Screen]
nMode = 0
bFullScreen = FALSE
bShowStatusbar = FALSE
bShowTitlebar = FALSE

[Keyboard]
bSwapCmdAlt = FALSE
nKeymapType = 0

[Mouse]
bEnableAutoGrab = FALSE
bEnableMapToKey = FALSE
bEnableMacClick = FALSE
bUseRawMotion = FALSE
fLinScale = 1.333333
fExpScale = 1.0

[Tablet]
# 2 = SummaGraphics MM 1201. Non-zero is what makes Previous route the host's
# ABSOLUTE window coordinates to tablet_pen_move() once the guest driver is
# attached; 0 (the old value) forced the relative kms_mouse_move() path.
nTabletType = 2

[Sound]
bEnableMicrophone = FALSE
bEnableSound = TRUE

[Memory]
nMemoryBankSize0 = 16
nMemoryBankSize1 = 16
nMemoryBankSize2 = 16
nMemoryBankSize3 = 16
nMemorySpeed = 3

[Boot]
nBootDevice = 1
bEnableDRAMTest = FALSE
bEnablePot = FALSE
bEnableSoundTest = FALSE
bEnableSCSITest = FALSE
bLoopPot = FALSE
bVerbose = FALSE
bExtendedPot = FALSE
bVisible = TRUE

[HardDisk]
szImageName0 = /opt/bridge/media/nextstep/NS33_2GB.dd
nDeviceType0 = 1
bDiskInserted0 = TRUE
bWriteProtected0 = FALSE
nWriteProtection = 0

[MagnetoOptical]
bDriveConnected0 = FALSE
bDriveConnected1 = FALSE

[Floppy]
bDriveConnected0 = FALSE
bDriveConnected1 = FALSE

[Ethernet]
bEthernetConnected = TRUE
bTwistedPair = TRUE
nHostInterface = 0
bNetworkTime = FALSE

[ROM]
szRom040FileName = /opt/bridge/media/nextstep/Rev_2.5_v66.BIN
bUseCustomMac = FALSE

[Printer]
bPrinterConnected = FALSE

[System]
nMachineType = 1
bColor = FALSE
bTurbo = FALSE
bNBIC = TRUE
bADB = FALSE
nSCSI = 1
nRTC = 0
nCpuLevel = 4
nCpuFreq = 25
bCompatibleCpu = TRUE
bRealtime = TRUE
nDSPType = 2
bDSPMemoryExpansion = TRUE
n_FPUType = 68040
bCompatibleFPU = TRUE
bMMU = TRUE
EOS

read -r -d '' XORG_PTR <<'EOS' || true
# nextstep station: the exhibit is driven by ABSOLUTE coordinates that must reach
# the emulator unscaled (browser -> streamhost dbus-abs -> QEMU usb-tablet ->
# Xorg -> SDL -> Previous tablet.c -> the NeXT tabletdriver). Acceleration does
# not apply to an absolute device, but this stanza stays: it also covers the
# relative PS/2 pointer a COLD boot falls back to before the driver is attached,
# and any Xorg rescaling there would corrupt the install automation.
Section "InputClass"
    Identifier   "nextstep-flat-pointer"
    MatchIsPointer "on"
    Option       "AccelerationProfile" "-1"
    Option       "AccelSpeed" "0"
    Option       "AccelerationScheme" "none"
EndSection
EOS

stop_qemu() {
  if [ -S "$QMP" ]; then
    hmp quit >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      [ ! -S "$QMP" ] && break
      sleep 0.25
    done
  fi
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    die "QEMU still owns $PID; refusing to kill it (stop only this tile safely)"
  fi
  rm -f "$QMP" "$PID"
}

# boot_tile [cold] — `cold` refuses -loadvm even when a golden exists. Every boot
# in this script is COLD on purpose: `loadvm` restores the DISK as well as RAM, so
# a config written before it is silently thrown away, and the emulator comes back
# still running the settings the snapshot was taken with.
boot_tile() {
  stop_qemu
  local LOADVM=""
  if [ "${1:-}" != "cold" ]; then
    qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  fi
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish)
  nohup qemu-system-x86_64 \
    -name streamhost-nextstep \
    -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp "$SMP" -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device e1000,netdev=n0 \
    $LOADVM \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PID" \
    >"$TILE_DIR/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] && [ -f "$PID" ] || die "QEMU did not create its QMP socket/pidfile"
  log "QEMU started (loadvm='${LOADVM:-<none: cold boot>}')"
}

wait_ssh() {
  for _ in $(seq 1 60); do
    guest true 2>/dev/null && return 0
    sleep 3
  done
  die "bridge SSH did not become ready on port $SSH_PORT"
}

capture() {
  local name=$1
  hmp "screendump $EVIDENCE/$name.ppm" >/dev/null
  pnmtopng "$EVIDENCE/$name.ppm" >"$EVIDENCE/$name.png"
  log "framebuffer proof: $EVIDENCE/$name.png"
}

# Readiness predicate. A NeXTSTEP Workspace fills the whole 1120x832 root with
# mid-grey and paints a black Dock column down the right-hand edge; a bare X
# root is solid black, the boot panel is a small grey card on dark grey, and the
# ROM monitor / a panic is a WHITE page of text. Require BOTH: the window
# anchored edge to edge (nothing black outside it) and a large mid-grey area
# that is neither the white panic page nor the dark empty root.
ns_ready() {
  local name=$1 stats
  capture "$name" 2>/dev/null || return 1
  stats=$(
    python3 - "$EVIDENCE/$name.ppm" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
i = d.index(b'255\n') + 4
px = d[i:]
w, h = 1120, 832
grey = white = dark = 0
for o in range(0, w * h * 3, 3):
    v = px[o]
    if v > 200:
        white += 1
    elif v < 32:
        dark += 1
    elif 70 <= v <= 190:
        grey += 1
print(grey, white, dark)
PY
  ) || return 1
  # shellcheck disable=SC2086 # three space-separated counts, deliberately split
  set -- $stats
  local grey=$1 white=$2 dark=$3
  # >45% mid-grey, and not a white text page, and no big black border.
  [ "$grey" -gt 419000 ] && [ "$white" -lt 300000 ] && [ "$dark" -lt 60000 ]
}

wait_for_workspace() {
  local name=$1
  for _ in $(seq 1 60); do
    ns_ready "$name" && return 0
    sleep 10
  done
  die "no NeXTSTEP Workspace on the framebuffer after 600 seconds"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -f "$HERE/../patches/previous-wmless-window-borders.patch" ] ||
  die "missing patch: $HERE/previous-wmless-window-borders.patch"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
NEW_OVERLAY=0
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base and growing it to $DISK"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
  qemu-img resize "$OVERLAY" "$DISK" >/dev/null
  NEW_OVERLAY=1
fi

if [ "$NEW_OVERLAY" -eq 1 ]; then
  boot_tile
  log "waiting for bridge SSH"
  wait_ssh
  guest "growpart /dev/sda 1 >/dev/null 2>&1 || true; resize2fs /dev/sda1 >/dev/null 2>&1 || true
    df -h / | tail -1"

  log "installing build dependencies into the overlay"
  guest 'export DEBIAN_FRONTEND=noninteractive
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -x unattended-upgr >/dev/null || break; sleep 15
    done
    apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1
    apt-get install -y --no-install-recommends cmake subversion zlib1g-dev libpng-dev \
      p7zip-full libpcap-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev \
      libxi-dev libxfixes-dev libxss-dev libxtst-dev libxkbcommon-dev libasound2-dev \
      libgl1-mesa-dev libegl1-mesa-dev xdotool x11-utils >>/tmp/apt.log 2>&1
    command -v cmake svn 7z xdotool >/dev/null' ||
    die "could not install the build dependencies (see /tmp/apt.log in the guest)"

  # SDL3. Previous 4.4 needs >= 3.2; Debian 12 has SDL2 only. libxtst-dev above
  # is not optional: cmake aborts with "Couldn't find dependency package for
  # XTEST" without it.
  log "building SDL3 $SDL3_VER from source in the overlay (~2 min at -j2)"
  guest "set -e
    cd /usr/local/src
    [ -f SDL3-$SDL3_VER.tar.gz ] || curl -sSL --max-time 900 -o SDL3-$SDL3_VER.tar.gz \
      https://github.com/libsdl-org/SDL/releases/download/release-$SDL3_VER/SDL3-$SDL3_VER.tar.gz
    [ \"\$(sha256sum SDL3-$SDL3_VER.tar.gz | cut -d' ' -f1)\" = '$SDL3_SHA' ] || {
      echo 'SDL3 tarball sha256 mismatch'; exit 1; }
    [ -d SDL3-$SDL3_VER ] || tar xzf SDL3-$SDL3_VER.tar.gz
    cd SDL3-$SDL3_VER
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DSDL_WAYLAND=OFF -DSDL_X11=ON \
      -DSDL_ALSA=ON -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_TESTS=OFF \
      -DSDL_EXAMPLES=OFF -DSDL_SHARED=ON -DSDL_STATIC=OFF >/tmp/sdl3-cmake.log 2>&1
    cmake --build build -j2 >/tmp/sdl3-build.log 2>&1
    cmake --install build >/tmp/sdl3-install.log 2>&1
    ldconfig
    pkg-config --modversion sdl3" || die "SDL3 build failed"

  # Previous. ENABLE_RENDERING_THREAD=1 is REQUIRED — see trap 4 in the header.
  log "checking out and building Previous r$PREVIOUS_REV (~9 min at -j2)"
  put "$HERE/../patches/previous-wmless-window-borders.patch" /tmp/previous-borders.patch
  guest "set -e
    cd /usr/local/src
    [ -d previous-code ] || svn checkout -q -r $PREVIOUS_REV \
      svn://svn.code.sf.net/p/previous/code/trunk previous-code
    cd previous-code
    svn info | grep '^Revision:'
    grep -q 'top = bottom = 50' src/gui-sdl/sdlscreen.c &&
      patch -p0 < /tmp/previous-borders.patch
    grep -q 'top = bottom = left = right = 0' src/gui-sdl/sdlscreen.c || {
      echo 'wmless-window-borders patch did not apply'; exit 1; }
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_RENDERING_THREAD=1 \
      >/tmp/prev-cmake.log 2>&1
    grep -q 'Rendering thread :    Enabled' /tmp/prev-cmake.log || {
      echo 'ENABLE_RENDERING_THREAD did not take; guest input would be silently dead'
      exit 1; }
    cmake --build build -j2 >/tmp/prev-build.log 2>&1
    install -m 755 build/src/previous /usr/local/bin/previous
    /usr/local/bin/previous --version 2>&1 | head -1 || true" ||
    die "Previous build failed"

  # Media. The ROM ships inside the Previous source tree; only the disk image is
  # fetched. Neither is ever committed — see docs/lab/ASSETS-MANIFEST.md.
  log "staging the NeXT ROM and the NeXTSTEP 3.3 disk image (sha256-verified)"
  guest "set -e
    M=/opt/bridge/media/nextstep; mkdir -p \$M; cd \$M
    install -m 644 /usr/local/src/previous-code/src/Rev_2.5_v66.BIN \$M/Rev_2.5_v66.BIN
    [ \"\$(sha256sum \$M/Rev_2.5_v66.BIN | cut -d' ' -f1)\" = '$ROM_SHA' ] || {
      echo 'NeXT ROM sha256 mismatch'; exit 1; }
    if [ ! -f NS33_2GB.dd ] || \
       [ \"\$(sha256sum NS33_2GB.dd | cut -d' ' -f1)\" != '$NS_DD_SHA' ]; then
      curl -sSL --max-time 1800 -o ns33.7z '$NS_URL'
      [ \"\$(sha256sum ns33.7z | cut -d' ' -f1)\" = '$NS_7Z_SHA' ] || {
        echo '7z archive sha256 mismatch'; exit 1; }
      7z e -y ns33.7z 'Nextstep 3.3 HD Image With Previous/NS33_2GB.dd' >/dev/null
      rm -f ns33.7z
    fi
    [ \"\$(sha256sum NS33_2GB.dd | cut -d' ' -f1)\" = '$NS_DD_SHA' ] || {
      echo 'disk image sha256 mismatch'; exit 1; }
    fallocate --dig-holes NS33_2GB.dd 2>/dev/null || true
    # NeXTSTEP panics with 'Root device is physically write protected' unless the
    # kiosk user itself can write the image.
    chown bridge:bridge NS33_2GB.dd; chmod 644 NS33_2GB.dd
    install -d -m 700 -o bridge -g bridge /home/bridge/.config/previous
    cat > \$M/PROVENANCE <<PV
NeXTSTEP 3.3 tile media (copyrighted; free to RUN in this private collection,
NEVER re-distributed through the public GitHub repo).
Rev_2.5_v66.BIN : NeXT ROM Rev 2.5 v66 (68040 cube/station), sha256 $ROM_SHA
                  SRC: Previous source tree src/Rev_2.5_v66.BIN (SVN r$PREVIOUS_REV)
NS33_2GB.dd     : pre-installed NeXTSTEP 3.3 for m68k, sha256 $NS_DD_SHA
                  SRC: $NS_URL
PV
    ls -l \$M" || die "media staging failed"

  log "installing the kiosk launcher, the frame watcher, and previous.cfg"
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh"
  put "$HERE/../stages/nextstep-kiosk-frame.sh" /usr/local/bin/nextstep-kiosk-frame.sh
  # nstel.py is the only captured-output exec channel into NeXTSTEP itself:
  # Previous publishes a fixed SLIRP redirect from the kiosk's :42323 to the
  # NeXT's telnet port. The tablet install needs it; operators do too.
  put "$HERE/../nextstep-nstel.py" /usr/local/bin/nstel.py
  guest "chmod 755 /usr/local/bin/nextstep-kiosk-frame.sh /usr/local/bin/nstel.py"

  # First light. NeXTSTEP 3.3 runs its own first-boot Welcome panel (language +
  # keyboard) exactly once, on the very first boot of this disk image; RETURN
  # accepts the English/USA defaults and RETURN again confirms the alert. Both
  # are framebuffer-verified below by the Workspace predicate.
  guest "pkill -u bridge -x previous 2>/dev/null || true
    pkill -u bridge -f nextstep-kiosk-frame 2>/dev/null || true
    sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1"
  log "NeXTSTEP is booting (ROM POST + Mach kernel, ~4 minutes)"
  sleep 240
  capture first-light
  guest "export XAUTHORITY=\$(ls -t /tmp/serverauth.* | head -1) DISPLAY=:0
    xdotool key Return; sleep 12; xdotool key Return" || true
  wait_for_workspace cold-boot-workspace
fi

# Rewritten on EVERY run, not only for a new overlay: they carry the tablet
# settings, and an overlay built before those existed must pick them up.
if [ "$NEW_OVERLAY" -eq 0 ]; then
  log "refreshing previous.cfg and the Xorg pointer stanza"
  boot_tile cold
  wait_ssh
fi
printf '%s\n' "$PREVIOUS_CFG" |
  guest "cat > /home/bridge/.config/previous/previous.cfg &&
    chown -R bridge:bridge /home/bridge/.config"
printf '%s\n' "$XORG_PTR" | guest "cat > /etc/X11/xorg.conf.d/20-nextstep-pointer.conf"
put "$HERE/../nextstep-nstel.py" /usr/local/bin/nstel.py
guest "chmod 755 /usr/local/bin/nstel.py"

# One clean cold boot with everything in place, then bake the golden from the
# state the machine itself chose: its own Workspace, nothing curated, nothing
# typed. (The Plus/4 lesson: a golden baked inside an application drops a
# visitor into the middle of something they cannot name or leave.)
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile cold
wait_ssh
sleep 240
wait_for_workspace ready-before-golden
guest "pgrep -x previous >/dev/null" || die "the Previous emulator is not running"
guest "grep -q 'window=' /tmp/nextstep-frame.log" ||
  die "the frame watcher never found the Previous window (input and geometry would both be wrong)"

# Attach NeXTSTEP's own tablet driver and prove the 1:1 map BEFORE the snapshot.
# Since 2026-08-11 the installer persists an rc.local boot hook, so an installed
# disk cold-boots absolute and the installer short-circuits to a probe; the GUI
# dance runs once per fresh disk image (docs/guests/nextstep.md §4).
log "attaching the NeXTSTEP tablet driver (absolute pointer) before the bake"
python3 "$HERE/../nextstep-tablet-install.py" --dir "$TILE_DIR" --ssh-port "$SSH_PORT" \
  --key "$KEY" --evidence "$EVIDENCE" || die "the tablet driver did not attach"

qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && hmp "delvm golden" >/dev/null
hmp "savevm golden" >/dev/null
qemu-img snapshot -l "$OVERLAY" | grep -qw golden || die "savevm golden did not land"
capture golden-baked
hmp "loadvm golden" >/dev/null
sleep 8
ns_ready golden-restored || die "loadvm golden did not restore the Workspace"

log "PASS: NeXTSTEP 3.3 Workspace on a NeXTcube, anchored 1120x832, golden baked"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=$MEM smp=$SMP evidence=$EVIDENCE"
