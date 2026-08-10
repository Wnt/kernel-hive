#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/cbm2.sh — build the Commodore CBM 610 (1982) streamhost tile as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running VICE `xcbm2 -model 610`, emulating
#         a PAL Commodore CBM 610 that boots its ROM straight to
#         "*** commodore basic 128, v4.0 ***  ready." in green on black at 80
#         columns. streamhost captures the Linux framebuffer + AC97 audio
#         exactly like every other bridge tile (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHY THIS TILE IS CHEAP -------------------------------------------------
#   Same argument as vic20.sh and plus4.sh: VICE is already in the frozen bridge
#   base (bridge-base.sh builds the whole family from source for the c64 tile)
#   and it BUNDLES the Commodore ROMs. A CBM 610 needs no disk, no cartridge and
#   no licensed media of any kind — it boots to BASIC from ROM with zero media
#   attached. So: no staged asset, no checksum gate, no check-assets.sh row.
#
# ---- THE EXHIBIT ------------------------------------------------------------
#   The CBM-II / B-series was Commodore's business machine and its forgotten
#   flop. A MOS 6509 at 2 MHz — a 6502 that can bank-switch a full megabyte
#   through two I/O registers — 128 KB of RAM, an 80x25 green CRTC screen, and
#   "BASIC 128", which shares its number with the Commodore 128 of 1985 and
#   nothing else whatsoever. Keyboard-only exhibit: --pointer none,
#   --input-backend disabled, X started with -nocursor.
#
#   IT LOOKS LIKE A PET, AND THAT IS THE POINT AND THE RISK. Its cold screen is
#   a green 80-column CBM BASIC banner, as the cbm8032 tile's is. What separates
#   them is not the frame but the machine behind it: a 6509 with a banked
#   megabyte instead of a 6502 with 32 KB, a detached low-profile box instead of
#   an all-in-one, and a market — small business — that Commodore reached for
#   and missed. The placard (registry/posters/cbm2.md) and the museum blurb both
#   carry that distinction explicitly; see docs/guests/cbm2.md for the honest
#   statement of the near-duplicate risk.
#
# ---- WINDOW GEOMETRY: MEASURED, NOT GUESSED (2026-08-09, recon clone) -------
#   There is no window manager, so an SDL window larger than the X root is
#   silently CLIPPED and mispositioned — and on THIS machine the clipping is
#   invisible to the eye, because the emulated screen is black and so is the
#   bare X root. The measurement was therefore taken with `xsetroot -solid
#   magenta` under the window, so the window's true rectangle could be read off
#   the framebuffer:
#
#     root       flags          window            verdict
#     1024x768   (none)         704x528 centred   fits, 69% x 69% of the root
#     1024x768   -CRTCdsize     1408x1056         CLIPPED — banner sliced in
#                                                 half at y=0, left edge lost
#     1280x1024  -CRTCdsize     1408x1056         CLIPPED horizontally
#     1920x1080  -CRTCdsize     1408x1056 centred fits, 73% x 98%
#     800x600    (none)         704x528 centred   fits, 88% x 88%  <-- SHIPPED
#
#   So the doubled window needs a 1600x1200-or-larger root, which would make
#   this the largest capture in the fleet — four times the pixel area of every
#   other bridge tile (c64/vic20/plus4 all run 800x600) — to enlarge glyphs that
#   are already only 8 px wide because the machine draws 80 columns. The native
#   window on an 800x600 root gives the same 88% fill as a doubled window on a
#   1600x1200 root at a quarter of the encode cost, so this tile drops
#   -CRTCdsize rather than growing the root.
#
# ---- TWO TRAPS INHERITED FROM THE VIC-20 ADD (both handled below) -----------
#   * VICE 3.9 SEGFAULTS whenever its stdout is not a terminal (vice_banner() ->
#     log_message(" ") -> strlen(NULL)) and prints nothing at all. The kiosk
#     profile therefore leaves stdout on tty1 and NEVER redirects startx to a
#     file. The visible symptom is X dying a second after it starts and
#     getty@tty1 looping into start-limit-hit, with nothing naming the emulator.
#     See docs/guests/vic20.md for the gdb backtrace.
#   * VICE's `make install` SKIPS ROM data files; the emulator then segfaults on
#     startup with no output. The installed CBM-II tree happened to be complete
#     on this base (the only diff against the source tree was Makefiles and gtk3
#     keymaps) — repair and ASSERT anyway, because the assertion is what makes a
#     future incomplete tree fail loudly here instead of silently at boot.
#
# ---- KEY PACING -------------------------------------------------------------
#   SH_KEY_MIN_HOLD_MS=80 / SH_KEY_MIN_GAP_MS=80 — four PAL frames each way, the
#   figure BISECTED on this box for the vic20 tile
#   (scripts/dev/emu-key-pacing-bisect.py: 40/40 corrupted one line in 22 under
#   host scheduling stalls, 80/80 none in 22). Same emulator, same 50 Hz frame,
#   same host, so the same numbers. Two frames is a floor, not an answer.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the cbm2
# tile dir; refuses to run while streamhost@cbm2 is active.
#
# Usage: cbm2.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=cbm2
VMID=226
UDP=54111
SSH_PORT=5826
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/cbm2
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
PROBE="$TILE_DIR/fb-probe.py"
MEM=768

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,80p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[cbm2 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[cbm2] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The kiosk launcher. 800x600 root, native (undoubled) window — see the geometry
# table in the header for the four roots that were measured to get here. No
# -CRTCborders flag exists for the CRTC chip, so the border comes as the machine
# drew it.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore CBM 610 (PAL) ROM BASIC kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/cbm2.sh for the flag rationale and the measured
# window geometry: the native window is 704x528 and is centred by SDL on the
# 800x600 root (88% fill); -CRTCdsize would make it 1408x1056 and be silently
# clipped by every root this fleet uses.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
exec xcbm2 \
  -model 610 \
  -sounddev alsa \
  -pal
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit),
# console kept quiet. Overlays the bridge base's stock .bash_profile.
#
# DO NOT REDIRECT startx's OUTPUT TO A FILE — VICE 3.9 segfaults in
# vice_banner() whenever its stdout is not a terminal, before printing a byte.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (cbm2 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit). stdout MUST stay on tty1: VICE 3.9
# segfaults in vice_banner() when its stdout is not a terminal.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# The readiness predicate needs POSITION, not just brightness: this screen is
# green-on-black inside a black window on a black root, so "there are lit
# pixels" cannot distinguish a correctly placed window from a clipped one.
# fb-probe.py reports the lit-green pixel count and the bounding box of the lit
# pixels, and the assertions below use both.
read -r -d '' PROBE_PY <<'EOS' || true
#!/usr/bin/env python3
"""Report `count minrow maxrow mincol maxcol` for the lit green pixels of a P6 PPM.

Green-on-black is the CBM 610's only palette, so "lit" is simply a green
channel well above both others. The bounding box is what proves the emulator's
window is where it is supposed to be rather than clipped against the X root.
"""

import sys

data = open(sys.argv[1], "rb").read()
parts = data.split(b"\n", 3)
if parts[0] != b"P6":
    raise SystemExit("not a P6 PPM: %s" % sys.argv[1])
width, height = map(int, parts[1].split())
px = parts[3]

count = 0
minrow, maxrow, mincol, maxcol = height, -1, width, -1
for y in range(height):
    base = y * width * 3
    for x in range(width):
        i = base + x * 3
        if px[i + 1] > 96 and px[i] < 96 and px[i + 2] < 96:
            count += 1
            if y < minrow:
                minrow = y
            if y > maxrow:
                maxrow = y
            if x < mincol:
                mincol = x
            if x > maxcol:
                maxcol = x
print(count, minrow, maxrow, mincol, maxcol)
EOS

# ROM repair. bridge-base.sh records the trap: VICE's `make install` skips some
# ROM data files and the emulator then segfaults on startup with NO output at
# all (it bit the C64 tile on the BASIC ROM and the VIC-20 on basic-901486-01).
# The CBM-II tree was measured complete on this base, so the copy below is
# expected to be a no-op — the ASSERTION is the deliverable. A CBM 610 is a
# 128 KB low-profile model, which VICE resolves through rom128l.vrs to exactly
# these three images; a 710 would take chargen-901232-01 instead.
repair_cbm2_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/CBM-II
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/CBM-II
    cp -n "$src"/*.bin /usr/local/share/vice/CBM-II/ 2>/dev/null || true
    cp -n "$src"/*.vrs "$src"/*.vkm /usr/local/share/vice/CBM-II/ 2>/dev/null || true
    for r in basic-901242+3-04a.bin kernal-901244-04a.bin chargen-901237-01.bin rom128l.vrs; do
      [ -s "/usr/local/share/vice/CBM-II/$r" ] || { echo "missing CBM-II ROM: $r" >&2; exit 1; }
    done' ||
    die "could not complete the CBM-II ROM set in the guest (610 = BASIC 128 + KERNAL + low-profile chargen)"
  log "CBM-II ROM set complete (BASIC 128 + KERNAL + chargen + rom128l.vrs)"
}

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
    -name streamhost-cbm2 \
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
  rm -f "$ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$name.png"
  log "framebuffer proof: $EVIDENCE/$name.png"
}

# Ready = the BASIC banner and its "ready." are painted, AND they are painted
# where the un-clipped 704x528 window puts them. Measured on the recon clone at
# the shipped geometry: count 456, bounding box rows 100..178, cols 80..342 (the
# count breathes with the blinking cursor, so the floor is generous). The
# position bounds are what catch a clipped window: with -CRTCdsize on a 1024x768
# root the same banner started at row 0, column 0.
CBM2_MIN_GREEN=${CBM2_MIN_GREEN:-250}
probe() { python3 "$PROBE" "$EVIDENCE/$1.ppm"; }
wait_for_basic() {
  local name=$1
  local green minrow maxrow mincol maxcol
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      read -r green minrow maxrow mincol maxcol < <(probe "$name")
      if [ "$green" -ge "$CBM2_MIN_GREEN" ] &&
        [ "$minrow" -ge 60 ] && [ "$minrow" -le 140 ] &&
        [ "$mincol" -ge 40 ] && [ "$maxcol" -le 760 ]; then
        log "ready: green=$green rows=$minrow..$maxrow cols=$mincol..$maxcol"
        return 0
      fi
    fi
    sleep 2
  done
  die "no un-clipped CBM 610 BASIC framebuffer after 180 seconds"
}

# Type one character through QMP with the tile's production pacing (80 ms hold,
# 80 ms gap = four PAL frames each), so the proof exercises what the SPA does.
send_key() {
  local qcode=$1
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep 0.08
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep 0.08
  } | socat - UNIX-CONNECT:"$QMP" >>"$EVIDENCE/keyboard-qmp.jsonl"
}

# Prove the PS/2 keyboard path reaches the emulated 6509: type PRINT 3, RETURN,
# and require the printed text to extend DOWN the screen. A pixel-COUNT test
# would not do here — measured on the clone, the count barely moves (456 -> 454)
# because the blinking cursor gives back what the new lines add — but the lit
# bounding box grows from rows 100..178 to 100..226 as BASIC echoes the line,
# prints " 3" and paints a second "ready.". A proof that cannot fail is not a
# proof, so the assertion is on that growth and not on "something changed".
keyboard_proof() {
  local bg bminrow bmaxrow bmincol bmaxcol
  local ag aminrow amaxrow amincol amaxcol k
  read -r bg bminrow bmaxrow bmincol bmaxcol < <(probe golden-restored)
  : >"$EVIDENCE/keyboard-qmp.jsonl"
  for k in p r i n t spc 3 ret; do send_key "$k"; done
  sleep 3
  capture keyboard-print3
  read -r ag aminrow amaxrow amincol amaxcol < <(probe keyboard-print3)
  [ "$amaxrow" -ge $((bmaxrow + 30)) ] ||
    die "PRINT 3 did not extend the BASIC screen (maxrow $bmaxrow -> $amaxrow)"
  log "keyboard proof: rows $bminrow..$bmaxrow -> $aminrow..$amaxrow (green $bg -> $ag, cols $bmincol..$bmaxcol -> $amincol..$amaxcol)"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# The guest must have real headroom with VICE running, or the kiosk will start
# reclaiming under the streamhost capture load. Measured at -m 768 on the recon
# clone: MemAvailable 418 MB with xcbm2 (RSS 148 MB) and Xorg (RSS 70 MB) up.
CBM2_MIN_AVAIL_MB=${CBM2_MIN_AVAIL_MB:-200}
assert_guest_memory() {
  local avail
  avail=$(guest "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo") ||
    die "could not read guest MemAvailable"
  [ "$avail" -ge "$CBM2_MIN_AVAIL_MB" ] ||
    die "guest MemAvailable ${avail}MB < ${CBM2_MIN_AVAIL_MB}MB at -m $MEM; raise MEM to 1024 and re-bake"
  log "guest MemAvailable ${avail}MB at -m ${MEM} (floor ${CBM2_MIN_AVAIL_MB}MB)"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$PROBE_PY" >"$PROBE"

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
  guest "command -v xcbm2 >/dev/null" ||
    die "xcbm2 missing from the bridge base (rebuild it with bridge-base.sh)"
  repair_cbm2_roms
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge xcbm2 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_basic cold-boot-basic
  assert_guest_memory
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the very state SPA reset will restore for ever after. NOTHING IS TYPED BEFORE
# THE BAKE: the fixture is the machine's own untouched power-on screen, which is
# the lesson the plus4 tile learned the hard way (its first golden rested inside
# an application and dropped visitors into the middle of it).
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 6
wait_for_basic ready-before-golden
guest "pgrep -x xcbm2 >/dev/null" || die "xcbm2 exited after cold boot"
assert_guest_memory
bake_golden
sleep 3
wait_for_basic golden-restored

# Keyboard proof runs AFTER the bake, against the restored fixture, so nothing
# it types can ever reach the golden.
keyboard_proof
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_basic golden-restored-after-keyboard

log "PASS: CBM 610 BASIC 128 ready, keyboard path, quiet console, golden snapshot"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
