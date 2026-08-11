#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/alto.sh — build the Xerox Alto II XM (1973) streamhost station
# as a thin overlay on the frozen bridge base
# (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running ContrAlto 2 (jdersch/Contralto2,
#         BSD-3-Clause, .NET 8 + Avalonia) as an Alto II XM, booted from the
#         Non-Programmer's Disk. streamhost captures the Linux framebuffer like
#         every other kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE DISPLAY, WHICH IS THE WHOLE REASON THIS TILE LOOKS DIFFERENT --------
#   The Alto's screen is PORTRAIT — a page standing up, 606x808 at 30 Hz, the
#   ancestor of every document window since. The feasibility study
#   (docs/lab/research/xerox-add.md §1.5) called the geometry the biggest risk,
#   because QEMU std-VGA wants a width that is a multiple of 8 and 606 is not.
#   The answer turned out to be in ContrAlto's own source: it renders a 608-wide
#   BITMAP (ALTO_DISPLAY_BITMAP_WIDTH, "rounded up so it's a nice even multiple
#   of 8 bits") around the 606 visible pixels. 608 IS a multiple of 8, so the
#   kiosk root is exactly 608x808 and the capture has NO letterbox, no painted
#   surround and no slop. bochs-drm does not advertise that mode; the launcher
#   adds it with an explicit xrandr modeline (there is no `cvt` in the guest).
#
# ---- TWO UPSTREAM PATCHES, BOTH REQUIRED ------------------------------------
#   patches/contralto2-wmless-kiosk.patch, applied to the pinned commit:
#     1. KioskMode = True crashes upstream before the first frame, and it is the
#        only switch that hides the Avalonia menu bar and status bar.
#     2. With no window manager nothing places the window (+10+10) and nothing
#        gives its display control keyboard focus — every keystroke was dropped
#        silently, which reads exactly like a dead emulator.
#   See docs/lab/research/xerox-build-log.md for how each was diagnosed.
#
# ---- ZERO EXTERNAL MEDIA ----------------------------------------------------
#   ContrAlto ships the Alto I and Alto II microcode PROMs AND eight Diablo disk
#   packs inside its own repository, and `dotnet publish` copies them into the
#   output tree. Nothing is downloaded, staged, hashed into
#   /data/assets-staging or committed — the gt40 story exactly. The pack this
#   exhibit boots is nonprog.dsk, the Non-Programmer's Disk: BRAVO.RUN,
#   DRAW.RUN, EMPRESS.RUN, Laurel.run, the Helvetica family and a shelf of
#   document templates. (xmsmall.dsk, which the study used, has neither Bravo
#   nor Draw and greets the visitor with a USER.CM warning.)
#
# ---- MEASUREMENTS THIS SCRIPT ENCODES (on labhost, 2026-08-10) --------------
#   * Key pacing: 20-character line, explicit press/release pairs — 16/16 ms
#     landed 15 of 20; 33/33, 66/66 and 120/120 all landed 20 of 20. One Alto
#     field is 33 ms, so the station ships two fields (66/66) in tile.env.
#   * MODIFIERS MUST LEAD. shift+letter in one event lost the capital every
#     time ("Bravo" -> "ravo"). The driver presses the modifier a full gap early.
#   * Absolute pointer, uncalibrated: requested (300,400) put the Alto cursor at
#     (302,402), (100,700) at (101,700), (600,800) at (602,802).
#   * Three buttons, proven with Bravo's own selection grammar at 400 ms dwell:
#     RED/left underlines one CHARACTER, YELLOW/middle the whole WORD,
#     BLUE/right EXTENDS the selection. (A middle click in DRAW does nothing —
#     that is a Draw fact, not a transport fault.)
#   * Cost: ~180 MB RSS inside the guest, ~170-190 % of a core while the Alto
#     runs. ThrottleSpeed = True holds it near real Alto speed.
#
# ---- THE FIXTURE: THE MACHINE'S OWN POWER-ON SCREEN -------------------------
#   The golden rests at the Alto Executive, untouched, exactly as a cold boot
#   leaves it — NOT inside Bravo. That is the call `plus4` made and then had to
#   reverse in 10ae428: a visitor who arrives mid-application has no idea what
#   it is, how they got there or how to leave. The choice of application belongs
#   in the exhibit UI, so the alto on-screen keyboard carries one-tap DRAW,
#   BRAVO, LAUREL and ? buttons and the Executive stays the honest empty state.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the alto station dir and its own
# host-side build tree; refuses to run while streamhost@alto is active.
#   Usage: alto.sh [--force] [--force-app] [-h]
# =============================================================================
set -euo pipefail

TILE=alto
VMID=243
UDP=54137
SSH_PORT=5843
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/alto
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
DRIVE="$TILE_DIR/alto-drive.py"
MEM=1024
X_MODE=608x808

# Host-side build tree. NOT in the station: the .NET SDK is ~350 MB of build-time
# tooling and only the ~150 MB self-contained publish output crosses into the
# guest, where it needs no runtime installed at all.
WORK=/data/gallery-guests/Alto
SRC="$WORK/src"
APP="$WORK/app"
SDK="$WORK/dotnet"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
PATCH="$REPO/scripts/build-guests/patches/contralto2-wmless-kiosk.patch"
# Tracked runtime sidecars (registry runtime.qemu.auxFiles).
SIDECAR="$REPO/streamhost/tiles/alto"

# ContrAlto 2, Josh Dersch's maintained successor to the Living Computers
# ContrAlto. There is no release tag, so the pin is a commit.
C2_REPO=https://github.com/jdersch/Contralto2.git
C2_COMMIT=e3681fbc30d129172b4c306aaee8c4e71ae1a458
# The exhibit's content, shipped in that tree. Asserted so a moved pin cannot
# silently change which Alto the visitor meets.
NONPROG_SHA256=2696bc0da29400430b1c829d8a0f6c3a67c1764380cdca5431a29fc0f97da289

FORCE=0
FORCE_APP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --force-app)
      FORCE_APP=1
      shift
      ;;
    -h | --help)
      sed -n '2,70p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[alto $(date +%H:%M:%S)] $*"; }
die() {
  echo "[alto] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 \
    -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }
# ALWAYS `cont` AFTER `loadvm`. HMP savevm stops the guest, writes the vmstate
# and resumes, so the state INSIDE the snapshot is "paused" and a bare loadvm
# hands you a frozen guest. The framebuffer still shows the restored screen, so
# every screen-based readiness check passes and then nothing you type has any
# effect — this build spent a run reporting "typing ? at the Executive produced
# no directory listing" when the Executive had simply not been running.
# ADD-NEW-OS-PLAYBOOK.md §5.1 says the same thing about idle-paused stations;
# labctl does it for you and a bare QMP harness must do it itself.
restore_golden() {
  hmp "loadvm golden" >/dev/null
  hmp cont >/dev/null 2>&1 || true
  sleep 4
}
drive() { python3 "$DRIVE" "$QMP" "$@"; }

# The kiosk launcher. The modeline is hardcoded because the bridge base has no
# `cvt`, and bochs-drm accepts an arbitrary mode as long as it is added first.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Xerox Alto II (ContrAlto 2) kiosk launcher — kiosk.
# See scripts/build-guests/tiles/alto.sh for the geometry and flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
xset s off -dpms s noblank 2>/dev/null || true
# Auto-repeat OFF. Every key this station sees is an injected press/release pair,
# and a late release on a loaded box makes X hammer the held key (the Oric
# lesson in ADD-NEW-OS-PLAYBOOK.md §5.1).
xset r off 2>/dev/null || true
# The Alto's own bitmap: 606 visible pixels inside a 608-wide row, 808 lines.
# 608 is a multiple of 8, so QEMU std-VGA takes it and nothing is letterboxed.
xrandr --newmode alto608x808 33.00 608 640 704 800 808 811 821 838 -hsync +vsync 2>/dev/null || true
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
if [ -n "$OUT" ]; then
  xrandr --addmode "$OUT" alto608x808 2>/dev/null || true
  xrandr --output "$OUT" --mode alto608x808 2>/dev/null || true
fi
xsetroot -solid black 2>/dev/null || true
cd /opt/bridge/alto/app
exec ./Contralto -config /opt/bridge/alto/alto.cfg -script /opt/bridge/alto/boot.script
EOS

# ContrAlto configuration. TwoKRom is the Alto II XM's 2K control ROM.
# KioskMode hides the menu and status bars (and only works at all with the
# patch). ThrottleSpeed holds the emulation near real Alto speed instead of
# free-running at whatever the host can manage.
read -r -d '' CFG <<'EOS' || true
SystemType = TwoKRom
HostAddress = 42
HostPacketInterfaceType = None
HostPacketInterfaceName = None
ThrottleSpeed = True
BootAddress = 0
BootFile = 0
AlternateBootType = Ethernet
KioskMode = True
AllowKioskExit = False
PauseWhenNotActive = False
FullScreenStretch = False
SlowPhosphorSimulation = False
DisplayScale = 1
EnablePrinting = false
PrintOutputPath = /tmp
Drive0Image = /opt/bridge/alto/disk/nonprog.dsk
EOS

# ContrAlto loads the pack but leaves the machine HALTED, so the exhibit presses
# its own start button through the emulator's script engine.
read -r -d '' BOOTSCRIPT <<'EOS' || true
2000ms Command start
EOS

# Kiosk session profile. -nocursor: the Alto draws its OWN cursor into its
# bitmap (ContrAlto warps it to the host pointer), so the X core pointer would
# be a second, wrong arrow one pixel away from the real one.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (alto overlay).
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# ---- measured regions of the 608x808 capture --------------------------------
# HEADER: the Executive's two banner lines ("-- XEROX Alto Executive/11 ...").
#         Present on the fixture, gone the moment Bravo or Draw takes the
#         screen, so it is both the ready detector and the "we left" detector.
# BODY:   everything below the banner, where typed commands and their output go.
# SEL:    the 4-pixel band directly under the line the pointer proof types into
#         Bravo, where its selection underline is drawn. Character, word and
#         extended selections are three clearly separated ink counts there.
#
# The Alto draws BLACK INK ON A PALE PAGE, so `ink` counts the text, and every
# threshold below is BOUNDED ABOVE as well as below. That is not decoration: a
# black screen measures 24320 in the header rect — the whole rectangle — and an
# unbounded "> 1500" detector declared a guest that had not started X yet
# "ready", then failed the geometry check one line later with a message about
# the wrong thing entirely.
RECT_HEADER="0 88 608 40"
RECT_BODY="0 135 608 620"
RECT_SEL="40 123 540 4"
# Measured on the fixture: banner 2346, empty body 260, body with the disk's
# directory listing 13050, Bravo's inverse-video command bar 12175, a black
# screen 24320.
INK_BANNER_MIN=1500
INK_BANNER_MAX=6000
INK_BODY_EMPTY_MAX=4000
INK_BODY_LISTING_MIN=8000
INK_BRAVO_BAR_MIN=8000
HOLD_MS=66
GAP_MS=66

build_contralto() {
  mkdir -p "$WORK"
  if [ ! -x "$SDK/dotnet" ]; then
    log "installing the pinned .NET 8 SDK into $SDK (build-time only)"
    curl -fSL -o "$WORK/dotnet-install.sh" https://dot.net/v1/dotnet-install.sh
    bash "$WORK/dotnet-install.sh" --channel 8.0 --install-dir "$SDK" >/dev/null
  fi
  [ -x "$SDK/dotnet" ] || die "the .NET 8 SDK did not install into $SDK"

  if [ ! -d "$SRC/.git" ]; then
    log "cloning ContrAlto 2"
    rm -rf "$SRC"
    git clone -q "$C2_REPO" "$SRC"
  fi
  git -C "$SRC" fetch -q --all 2>/dev/null || true
  git -C "$SRC" checkout -q -f "$C2_COMMIT"
  git -C "$SRC" clean -qfd
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$C2_COMMIT" ] ||
    die "the ContrAlto pin did not check out"

  [ -f "$PATCH" ] || die "missing $PATCH"
  (cd "$SRC" && patch -p1 --forward <"$PATCH") ||
    die "contralto2-wmless-kiosk.patch does not apply to $C2_COMMIT"

  log "publishing ContrAlto self-contained for linux-x64"
  rm -rf "$APP"
  env DOTNET_ROOT="$SDK" HOME="$WORK" DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 PATH="$SDK:$PATH" \
    dotnet publish "$SRC/Contralto/Contralto.csproj" -c Release -r linux-x64 \
    --self-contained true -o "$APP" >"$WORK/publish.log" 2>&1 ||
    {
      tail -30 "$WORK/publish.log" >&2
      die "dotnet publish failed"
    }
  [ -x "$APP/Contralto" ] || die "no Contralto binary in the publish output"
  [ -d "$APP/ROM/AltoII" ] || die "the publish output carries no Alto II microcode"
  echo "$NONPROG_SHA256  $APP/Disks/nonprog.dsk" | sha256sum -c - >/dev/null ||
    die "nonprog.dsk in the pinned tree is not the pack this exhibit was built on"
  log "ContrAlto ${C2_COMMIT:0:8} published ($(du -sh --apparent-size "$APP" | cut -f1)); nonprog.dsk hash verified"
}

install_app() {
  tar -C "$WORK" -cf - app |
    guest "rm -rf /opt/bridge/alto/app && mkdir -p /opt/bridge/alto &&
      tar -C /opt/bridge/alto -xf -"
  # The pack is COPIED out of the read-only publish tree: the Alto writes to its
  # own disk, and a rebuild must not inherit a previous visitor's edits.
  guest "mkdir -p /opt/bridge/alto/disk &&
    cp -f /opt/bridge/alto/app/Disks/nonprog.dsk /opt/bridge/alto/disk/nonprog.dsk"
  guest "[ -x /opt/bridge/alto/app/Contralto ] && [ -s /opt/bridge/alto/disk/nonprog.dsk ]" ||
    die "the ContrAlto tree did not land in the overlay"
  log "ContrAlto installed into the overlay (self-contained; no .NET in the guest)"
}

quiet_console() {
  guest "set -e
    sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0 quiet loglevel=0 vt.global_cursor_default=0\"|' /etc/default/grub
    sed -i 's|^GRUB_TIMEOUT=.*|GRUB_TIMEOUT=0|' /etc/default/grub
    sed -i 's|^GRUB_TERMINAL=.*|GRUB_TERMINAL=serial|' /etc/default/grub
    grep -q '^GRUB_TERMINAL=' /etc/default/grub || echo 'GRUB_TERMINAL=serial' >> /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
    mkdir -p /etc/systemd/system/getty@tty1.service.d
    printf '[Service]\nExecStart=\nExecStart=-/sbin/agetty --autologin bridge --noclear --noissue --nohints %%I \$TERM\n' \
      > /etc/systemd/system/getty@tty1.service.d/autologin.conf
    touch /home/bridge/.hushlogin && chown bridge:bridge /home/bridge/.hushlogin
    update-grub >/dev/null 2>&1
    systemctl daemon-reload"
}

sync_kiosk() {
  guest "mkdir -p /opt/bridge/alto"
  printf '%s\n' "$CFG" | guest "cat > /opt/bridge/alto/alto.cfg"
  printf '%s\n' "$BOOTSCRIPT" | guest "cat > /opt/bridge/alto/boot.script"
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  printf '%s\n' "$PROFILE" |
    guest "cat > /home/bridge/.bash_profile && chown bridge:bridge /home/bridge/.bash_profile"
}

restart_kiosk() {
  guest "for p in \$(pgrep -x Contralto); do kill \$p; done 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
}

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

# ALWAYS A COLD BOOT — never -loadvm golden, unlike the production launcher. An
# internal qcow2 snapshot carries the DISK as well as RAM, so restoring the
# golden silently reverts every guest-filesystem change made since the bake.
boot_tile() {
  stop_qemu
  nohup qemu-system-x86_64 \
    -name streamhost-alto \
    -enable-kvm -machine pc-i440fx-11.0 \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device e1000,netdev=n0 \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PID" \
    >"$TILE_DIR/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] && [ -f "$PID" ] || die "QEMU did not create its QMP socket/pidfile"
  log "QEMU cold-booted from the live overlay (no -loadvm)"
}

capture() {
  local ppm="$EVIDENCE/$1.ppm"
  rm -f "$ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$1.png"
  rm -f "$ppm"
  log "framebuffer proof: $EVIDENCE/$1.png"
}

# shellcheck disable=SC2086 # the RECT_* values are deliberate argument tuples
ink() { drive ink $1; }

# The Executive's banner is two dense lines of text across the full width. A
# black root, a crashed emulator and a halted Alto all measure ~0; Bravo and
# Draw both clear the banner, so this is also the "we left the Executive" test.
wait_for_executive() {
  local n
  for _ in $(seq 1 90); do
    n=$(ink "$RECT_HEADER" 2>/dev/null || echo 0)
    if [ "$n" -gt "$INK_BANNER_MIN" ] && [ "$n" -lt "$INK_BANNER_MAX" ]; then
      log "Alto Executive on screen ($n ink px in the banner)"
      return 0
    fi
    sleep 2
  done
  die "no Alto Executive banner after 180 seconds (last $n ink px; a black screen measures 24320 and Bravo's command bar 12175)"
}

verify_geometry() {
  guest "XAUTHORITY=/home/bridge/.Xauthority DISPLAY=:0 xwininfo -root -tree |
    grep -q 'Contralto\": (\"Contralto\" \"Contralto\")  608x808+0+0'" ||
    die "the ContrAlto window is not 608x808+0+0 (menu bar or offset would reach the capture)"
  guest "XAUTHORITY=/home/bridge/.Xauthority DISPLAY=:0 xdpyinfo |
    grep -q 'dimensions:    608x808 pixels'" ||
    die "the kiosk X root is not $X_MODE"
  log "geometry verified: ContrAlto 608x808+0+0 on a $X_MODE root, no chrome"
}

bake_golden() {
  if qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
    hmp "delvm golden" >/dev/null
  fi
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp cont >/dev/null 2>&1 || true
  log "golden snapshot baked"
}

# THE KEYBOARD PROOF, and it runs only AFTER the bake so nothing it types can
# reach the golden. `?` is the Executive's own "what can I run" command, so the
# assertion is the machine answering a real question rather than "the
# framebuffer changed": the body of the screen goes from empty to a full
# directory listing.
keyboard_proof() {
  local before after
  before=$(ink "$RECT_BODY")
  [ "$before" -lt "$INK_BODY_EMPTY_MAX" ] ||
    die "the fixture body is not empty before the keyboard proof ($before ink px)"
  drive type "$HOLD_MS" "$GAP_MS" "?"
  drive key "$HOLD_MS" ret
  sleep 8
  after=$(ink "$RECT_BODY")
  [ "$after" -gt "$INK_BODY_LISTING_MIN" ] ||
    die "typing ? at the Executive produced no directory listing ($after ink px)"
  log "keyboard proof: ? listed the disk ($before -> $after ink px in the body)"
  capture keyboard-proof-directory
}

# THE POINTER PROOF. Bravo is the only place on this disk where the three Alto
# buttons have distinct, visible meanings, and they are the machine's own
# grammar: RED selects a character, YELLOW a word, BLUE extends the selection.
# Running it here also proves the exhibit's headline command works.
pointer_proof() {
  local red yellow blue
  drive type "$HOLD_MS" "$GAP_MS" "Bravo"
  drive key "$HOLD_MS" ret
  # Bravo replaces the Executive's banner with a solid inverse-video command
  # bar, which is far MORE ink than the banner rather than less.
  for _ in $(seq 1 90); do
    [ "$(ink "$RECT_HEADER")" -gt "$INK_BRAVO_BAR_MIN" ] && break
    sleep 2
  done
  [ "$(ink "$RECT_HEADER")" -gt "$INK_BRAVO_BAR_MIN" ] ||
    die "Bravo never took the screen from the Executive"
  log "Bravo 7.5 loaded"
  drive type "$HOLD_MS" "$GAP_MS" "i"
  sleep 2
  drive type "$HOLD_MS" "$GAP_MS" "The Xerox Alto invented this screen"
  drive key "$HOLD_MS" esc
  sleep 4
  capture bravo-typed-line
  # The selection underline is drawn UNDER the typed line, so measure that band
  # only: one character, one word and a run of five words are three clearly
  # separated ink counts.
  drive abs 500 400
  sleep 1
  drive click 155 118 left 400
  sleep 1
  drive abs 500 400
  sleep 1
  red=$(ink "$RECT_SEL")
  drive click 155 118 middle 400
  sleep 1
  drive abs 500 400
  sleep 1
  yellow=$(ink "$RECT_SEL")
  drive click 260 118 right 400
  sleep 1
  drive abs 500 400
  sleep 1
  blue=$(ink "$RECT_SEL")
  capture bravo-blue-extended-selection
  [ "$yellow" -gt "$red" ] ||
    die "YELLOW (middle) did not select a wider run than RED (left): $yellow vs $red"
  [ "$blue" -gt "$yellow" ] ||
    die "BLUE (right) did not extend the selection past YELLOW: $blue vs $yellow"
  log "pointer proof: RED=$red YELLOW=$yellow BLUE=$blue underline px (char < word < extended)"
}

reset_proof() {
  restore_golden
  wait_for_executive
  local body
  body=$(ink "$RECT_BODY")
  [ "$body" -lt "$INK_BODY_EMPTY_MAX" ] ||
    die "loadvm golden did not clear the visitor's session ($body ink px in the body)"
  capture golden-restored
  log "reset proof: golden restore returned the untouched Executive ($body ink px)"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
install -m 755 "$SIDECAR/alto-drive.py" "$DRIVE"

build_contralto

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

boot_tile
log "waiting for bridge SSH"
ssh_ready=0
for _ in $(seq 1 40); do
  if guest true 2>/dev/null; then
    ssh_ready=1
    break
  fi
  sleep 3
done
[ "$ssh_ready" -eq 1 ] || die "bridge SSH did not become ready"

# Install when the guest does not already carry the tree, not merely when the
# overlay is new: a run that dies between creating the overlay and installing
# would otherwise leave every later run configuring an emulator that is not
# there. (It did, once — the first attempt lost its hostfwd port to a sibling
# build after the overlay was created.)
if [ "$FORCE_APP" -eq 1 ] || ! guest "[ -x /opt/bridge/alto/app/Contralto ]" 2>/dev/null; then
  install_app
fi

# Re-synced on EVERY run, not only on a fresh overlay: an edit to the launcher,
# the config or the kiosk profile is exactly what a re-run is for, and a change
# that only lands on a from-scratch rebuild is a trap (AGENTS.md).
sync_kiosk
quiet_console
restart_kiosk
sleep 10
wait_for_executive
verify_geometry
capture cold-boot-executive

# One clean cold boot with the quiet console in force, and bake THAT — nothing
# is typed and nothing is pointed at first. The mpf2 add shipped a golden
# carrying its own verification output and had to be re-baked.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 10
wait_for_executive
verify_geometry
guest "pgrep -x Contralto >/dev/null" || die "ContrAlto exited after the cold boot"
capture ready-before-golden
bake_golden
restore_golden
wait_for_executive
capture golden-restored-immediately

keyboard_proof
# The `?` listing is PAGED — it ends on the Executive's own "More?" prompt,
# which eats the next keystrokes instead of running them, so "Bravo" typed
# straight after it goes nowhere and the failure reads as "Bravo never took the
# screen". Restore rather than dismissing the pager: it puts the pointer proof
# on the same known-clean fixture a visitor gets, and it exercises the reset
# path one extra time on the way.
restore_golden
wait_for_executive
pointer_proof
reset_proof

log "PASS: Xerox Alto II XM live at the Executive, keyboard + three-button pointer proven"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT evidence=$EVIDENCE"
