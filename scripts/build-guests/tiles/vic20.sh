#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/vic20.sh — build the Commodore VIC-20 (1980) streamhost station as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running VICE `xvic` emulating a PAL VIC-20
#         that boots its ROM straight to the "**** CBM BASIC V2 ****" screen.
#         streamhost captures the Linux framebuffer + AC97 audio exactly like
#         every other kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY THIS TILE IS CHEAP -------------------------------------------------
#   * VICE is ALREADY in the frozen bridge base: bridge-base.sh builds it from
#     source for the c64 station and `make install` ships the whole family, so
#     /usr/local/bin/xvic is present with no new emulator build.
#   * VICE BUNDLES the Commodore ROMs (which is exactly why Debian cannot ship
#     it), and the VIC-20 needs nothing else — no disk, no cartridge, no
#     licensed media. The exhibit is the ROM, and the ROM is already there.
#   * Therefore: no staged asset, no checksum gate, no check-assets.sh row.
#
# ---- THE EXHIBIT ------------------------------------------------------------
#   PAL VIC-20: 6502 at 1.108 MHz, 5 KB RAM (3583 BASIC bytes free), 22x23
#   characters, 16 colours, VIC-I sound. Keyboard-only — the real machine's only
#   other input was a joystick — so X runs with -nocursor and the station ships
#   --pointer none --input-backend disabled.
#
# ---- KEY PACING -------------------------------------------------------------
#   VICE samples the emulated keyboard matrix once per emulated PAL frame
#   (50 Hz, 20 ms). Playbook §5.1: pace the release->press GAP from the frame
#   period with two frames of margin -> SH_KEY_MIN_HOLD_MS=40, GAP=40 (the same
#   values amstradcpc uses, and for the same 50 Hz reason).
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the vic20
# station dir; refuses to run while streamhost@vic20 is active.
#
# Usage: vic20.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=vic20
VMID=221
UDP=54085
SSH_PORT=5821
WEB_PORT=8121
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/vic20
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=1536

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,42p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[vic20 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[vic20] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# VICE's SDL window is a fixed size and cannot grow (SDL real fullscreen,
# -VICfull, renders BLACK under std-VGA capture — see amstradcpc.sh), so the
# same trick the c64 station uses applies: shrink the X root to the smallest
# advertised mode that still contains the window. A PAL VIC-20 at -VICdsize
# with normal borders is ~568x568, which 640x480 does NOT contain vertically —
# 800x600 is the smallest mode that does, and it leaves the picture filling
# most of the captured frame.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore VIC-20 (PAL) ROM BASIC kiosk launcher (kiosk).
# See scripts/build-guests/tiles/vic20.sh for the flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
exec xvic \
  -sounddev alsa \
  -VICdsize \
  -VICborders 0 \
  -pal
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit —
# the core pointer would otherwise sit frozen mid-screen), and the console kept
# quiet. Overlays the bridge base's stock .bash_profile.
#
# DO NOT REDIRECT startx's OUTPUT TO A FILE. mpf2's overlay does
# (`exec startx -- -nocursor >$HOME/startx.log 2>&1`) and that is safe for MAME,
# but VICE 3.9 SEGFAULTS AT STARTUP WITH NO OUTPUT WHENEVER ITS STDOUT IS NOT A
# TERMINAL: vice_banner() -> log_message(" ") -> log_helper() hands a NULL string
# to log_archdep(), and strlen(NULL) kills it before the emulator prints a single
# byte (gdb backtrace, 2026-08-08). The visible symptom is X dying a second after
# it starts and getty@tty1 looping into start-limit-hit — nothing whatsoever
# points at VICE. The stock base profile and the c64 station both leave stdout on
# tty1, which is exactly why they work; do the same here. X's own log still goes
# to /var/log/Xorg.0.log, and once X owns the display no VT text is captured.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (vic20 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit). stdout MUST stay on tty1: VICE 3.9
# segfaults in vice_banner() when its stdout is not a terminal.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
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

# bridge-base.sh already records the trap this hits: VICE's `make install` SKIPS
# some ROM data files and the emulator then SEGFAULTS on startup with NO output
# at all. The C64 station hit it on the C64 BASIC ROM; the frozen base's
# /usr/local/share/vice/VIC20 is missing basic-901486-01.bin in exactly the same
# way, which is why an unrepaired xvic dies instantly and takes X down with it
# (the visible symptom is getty@tty1 looping into start-limit-hit). Repair from
# the source tree the base retains, and assert the three ROMs a PAL VIC-20
# actually needs rather than trusting the copy.
repair_vic20_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/VIC20
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/VIC20
    cp -n "$src"/*.bin /usr/local/share/vice/VIC20/ 2>/dev/null || true
    for r in basic-901486-01.bin kernal.901486-07.bin chargen-901460-03.bin; do
      [ -s "/usr/local/share/vice/VIC20/$r" ] || { echo "missing VIC20 ROM: $r" >&2; exit 1; }
    done' ||
    die "could not complete the VIC20 ROM set in the guest"
  log "VIC20 ROM set complete (BASIC + KERNAL + chargen)"
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
    -name streamhost-vic20 \
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

# The VIC-20 draws a WHITE paper inside a CYAN border, so a live emulated
# VIC-I fills a large part of the 800x600 root with bright pixels while a bare
# X root (or a dead xvic) leaves it black. Requiring a big bright-pixel count
# distinguishes the two without pinning VICE's exact palette entries.
VIC20_MIN_BRIGHT=${VIC20_MIN_BRIGHT:-100000}
wait_for_vic20_boot() {
  local name=$1
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      local bright
      bright=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 > 96 && $2 > 96 && $3 > 96 { sum += $5 } END { print sum + 0 }')
      [ "$bright" -gt "$VIC20_MIN_BRIGHT" ] && return 0
    fi
    sleep 2
  done
  die "no VIC-20 BASIC framebuffer after 180 seconds"
}

# Type one character through QMP with the station's production pacing (40 ms hold,
# 40 ms gap = two PAL frames each), so the proof exercises what the UI does.
send_key() {
  local qcode=$1
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep 0.04
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep 0.04
  } | socat - UNIX-CONNECT:"$QMP" >>"$EVIDENCE/keyboard-qmp.jsonl"
}

# Prove the PS/2 keyboard path reaches the emulated VIC-20: type PRINT 3 and
# RETURN, then require a changed framebuffer digest. (A digest comparison makes
# no assumption about glyph rendering; the visible result is the BASIC answer.)
keyboard_proof() {
  local base_hash proof_hash k
  base_hash=$(sha256sum "$EVIDENCE/ready-before-golden.ppm" | awk '{print $1}')
  : >"$EVIDENCE/keyboard-qmp.jsonl"
  for k in p r i n t spc 3 ret; do send_key "$k"; done
  sleep 2
  capture keyboard-print3
  proof_hash=$(sha256sum "$EVIDENCE/keyboard-print3.ppm" | awk '{print $1}')
  [ "$proof_hash" != "$base_hash" ] ||
    die "keyboard proof did not change the VIC-20 framebuffer"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
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
  guest "command -v xvic >/dev/null" ||
    die "xvic missing from the bridge base (rebuild it with bridge-base.sh)"
  repair_vic20_roms
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge xvic 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_vic20_boot cold-boot-basic
fi

# One clean cold boot with the quiet console in force, then bake the golden
# snapshot from the very state UI reset will restore for ever after. Bake from
# an UNTOUCHED cold boot: the mpf2 add shipped a golden carrying its own
# verification output and had to be re-baked.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 6
wait_for_vic20_boot ready-before-golden
guest "pgrep -x xvic >/dev/null" || die "xvic exited after cold boot"
bake_golden
sleep 3
wait_for_vic20_boot golden-restored

# Keyboard proof runs AFTER the bake, against the restored fixture, so nothing
# it types can ever reach the golden.
keyboard_proof
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_vic20_boot golden-restored-after-keyboard

log "PASS: VIC-20 BASIC ready, keyboard path, quiet console, golden snapshot"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
