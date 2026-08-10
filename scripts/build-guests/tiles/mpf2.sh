#!/usr/bin/env bash
# Build the Multitech Microprofessor II (MPF-II, 1982) streamhost tile as a thin
# overlay on the frozen bridge base, with an INTERNAL 'golden' qcow2 snapshot —
# the same fixture pattern as its 1980s bridge siblings c64/apple2/atarist/amiga.
# Proof artifacts are real QEMU framebuffer dumps.
#
# RESET (resetMode=loadvm): restore the golden snapshot (X + MAME already at the
# BASIC prompt), then reset-tile.sh sends the registry-declared postRestoreKeys
# (scroll_lock, f3, scroll_lock) so MAME soft-resets the emulated MPF-II and the
# ROM genuinely re-runs its power-on — banner and 1-bit speaker beep included.
# MAME disables its UI keys while emulating a full keyboard, hence the scroll_lock
# (UI-toggle) sandwich; the exhibit keyboard is otherwise untouched.
#
# NOTHING LINUX MAY EVER BE VISIBLE. The overlay quiets the whole cold-boot path:
# GRUB output goes to serial, the kernel boots quiet with console=ttyS0 only, and
# the kiosk profile clears tty1 and redirects the X log to a file. X itself is
# started with -nocursor (keyboard-only exhibit: the core pointer would otherwise
# sit frozen mid-screen; xsetroot -cursor_name none only ever hid the ROOT window).
#
# The MPF-II is a 6502-based Apple II ish-clone with an incompatible memory map
# and keyboard matrix. It boots to Applesoft-clone BASIC at a 560x192 composite
# display (2.92:1 frame), scaled 2x/3x integer only, 6-colour artifact palette
# (black, white, blue, orange, purple, yellow). No pointing device — keyboard
# only, full 8x8 matrix with 48 chiclet keys.
#
# ROM: mpf_ii.rom (16 KB, CRC32 8780189f, SHA1 92378b0db561632b58a9b36a85f8fb00796198bb)
# Emulator: MAME mpf2 (clone of tk2000, working, parent driver tk2000.cpp in
# src/mame/apple/tk2000.cpp).
#
# Usage: mpf2.sh [--force]
set -euo pipefail

TILE=mpf2
VMID=220
UDP=54124
SSH_PORT=5820
WEB_PORT=8120
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/mpf2
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=1536
ROM=/data/assets-staging/mpf2/mpf_ii.rom
ROM_SHA1=92378b0db561632b58a9b36a85f8fb00796198bb
MAME=/data/vms/streamhost/assets/mpf2/mame/mpf2

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[mpf2 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[mpf2] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# MPF-II is strictly keyboard-driven. MAME runs FULLSCREEN on the bridge base's
# stock 1024x768 X root (set by ~/.xinitrc, same as every sibling bridge tile)
# with its normal aspect correction on, so the exhibit is a TV-shaped picture
# that fills the frame. Forcing `-resolution` to the raw doubled pixel count
# (1120x384) instead pinned a 2.92:1 strip in the middle of a large black root:
# that number is the composite PIXEL count, not the picture's shape — the real
# machine drew a roughly 4:3 image on a television, which is what keepaspect
# reconstructs.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Multitech Microprofessor II (MPF-II, 1982) BASIC kiosk launcher.
# 560x192 composite output @ ~60 Hz, 6-colour artifact palette, drawn
# fullscreen with aspect correction (TV-shaped picture, no black surround).
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
exec /opt/mpf2/mame/mpf2 mpf2 \
  -rompath /opt/mpf2/roms \
  -inipath /opt/mpf2 \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor, and no console/X-log text
# on the visible VT. Overlays the bridge base's stock /home/bridge/.bash_profile.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (mpf2 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit, the pointer would sit frozen mid-screen)
# and keep every byte of console/X-log text off the visible VT: the captured
# framebuffer IS the exhibit.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

# Quiet every text-producing stage of a cold boot (GRUB -> kernel -> agetty).
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
  printf '%s\n' "$PROFILE" |
    guest "cat > /home/bridge/.bash_profile && chown bridge:bridge /home/bridge/.bash_profile"
}

# Bake the INTERNAL golden snapshot (RAM+devices) of X + MAME at the BASIC prompt.
bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
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

boot_tile() {
  stop_qemu
  local LOADVM=""
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish)
  nohup qemu-system-x86_64 \
    -name streamhost-mpf2 \
    -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb \
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

capture() {
  local name=$1
  local ppm="$EVIDENCE/$name.ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$name.png"
  log "framebuffer proof: $EVIDENCE/$name.png"
}

wait_for_mpf2_boot() {
  local name=$1
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      # The patched MAME must honour ui.ini's skip_warnings. The known-problems
      # dialog is mostly RGB 191/114/37 in QEMU's screendump and is never a
      # valid golden state.
      local warning_pixels pixels_nonblack
      warning_pixels=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 == 191 && $2 == 114 && $3 == 37 { print $5; found = 1 } END { if (!found) print 0 }')
      pixels_nonblack=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 != 0 || $2 != 0 || $3 != 0 { sum += $5 } END { print sum + 0 }')
      [ "$warning_pixels" -eq 0 ] && [ "$pixels_nonblack" -gt 100 ] && return 0
    fi
    sleep 2
  done
  die "no warning-free MPF-II framebuffer after 180 seconds"
}

keyboard_proof() {
  local base_hash proof_hash
  base_hash=$(sha256sum "$EVIDENCE/ready-before-golden.ppm" | awk '{print $1}')

  # Type PTRON and Return. A changed framebuffer digest proves that the PS/2
  # keyboard path reached the emulated MPF-II, without assuming a palette count.
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    # Type P
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"p"}}}]}}\n'
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"p"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.10
    # Type T
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"t"}}}]}}\n'
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"t"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.10
    # Type R
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"r"}}}]}}\n'
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"r"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.10
    # Type O
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"o"}}}]}}\n'
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"o"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.10
    # Type N
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"n"}}}]}}\n'
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"n"}}}]}}\n'
    sleep 0.05
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"shift"}}}]}}\n'
    sleep 0.10
    # Type RETURN
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"ret"}}}]}}\n'
    sleep 0.10
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"ret"}}}]}}\n'
  } | socat - UNIX-CONNECT:"$QMP" >"$EVIDENCE/keyboard-qmp.jsonl"
  sleep 2
  capture keyboard-ptron-run
  proof_hash=$(sha256sum "$EVIDENCE/keyboard-ptron-run.ppm" | awk '{print $1}')
  [ "$proof_hash" != "$base_hash" ] ||
    die "keyboard proof did not change the MPF-II framebuffer"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -s "$ROM" ] || die "missing staged ROM: $ROM"
[ -x "$MAME" ] || die "missing MPF-II MAME 0.289 binary: $MAME (build with scripts/build-guests/emulators/build-mame-mpf2.sh)"
[ "$(sha1sum "$ROM" | awk '{print $1}')" = "$ROM_SHA1" ] ||
  die "staged ROM SHA1 does not match MPF-II pin"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this new tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
NEW_OVERLAY=0
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
  NEW_OVERLAY=1
fi

if [ "$NEW_OVERLAY" -eq 1 ]; then
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
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update
    # The distro package supplies SDL/X11 runtime libraries; its MAME binary
    # is never launched because the pinned host-built binary replaces it.
    apt-get install -y mame zip
    install -d -m 755 /opt/mpf2/roms /opt/mpf2/mame
    printf 'skip_warnings 1\n' > /opt/mpf2/ui.ini"
  install -m 755 "$MAME" /tmp/mpf2
  guest "cat > /opt/mpf2/mame/mpf2 && chmod 755 /opt/mpf2/mame/mpf2" </tmp/mpf2
  rm -f /tmp/mpf2
  guest "cat > /opt/mpf2/roms/mpf_ii.rom &&
    chmod 644 /opt/mpf2/roms/mpf_ii.rom &&
    cd /opt/mpf2/roms &&
    zip -q -j mpf2.zip mpf_ii.rom &&
    /opt/mpf2/mame/mpf2 -rompath /opt/mpf2/roms -verifyroms mpf2" <"$ROM"
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge mame 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_mpf2_boot cold-boot-basic
  keyboard_proof
fi

# One clean cold boot with the quiet console in force, then bake the golden
# snapshot from the state SPA reset will restore for ever after.
stop_qemu
boot_tile
sleep 6
wait_for_mpf2_boot cold-reset-basic
guest "pgrep -x mpf2 >/dev/null || pgrep -x mame >/dev/null" ||
  die "MAME exited after cold reset"
bake_golden
sleep 3
wait_for_mpf2_boot golden-restored

log "PASS: MPF-II BASIC prompt ready, keyboard path, quiet console, golden snapshot"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
