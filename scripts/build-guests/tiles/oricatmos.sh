#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/oricatmos.sh — build the Oric Atmos (1984) streamhost tile as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running MAME's `orica` driver, emulating an
#         Oric Atmos that boots its ROM straight to the Oric Extended BASIC V1.1
#         banner. streamhost captures the Linux framebuffer + AC97 audio exactly
#         like every other bridge tile (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE EXHIBIT ------------------------------------------------------------
#   Oric Atmos: 6502A at 1 MHz, 48 KB RAM (37631 BASIC bytes free), 40x28 text
#   or a 240x200 HIRES bitmap, eight colours set by control codes that occupy
#   the cell they act on, and an AY-3-8912 that Oric BASIC drives with four
#   ready-made noises — ZAP, PING, SHOOT and EXPLODE. Keyboard-only: the real
#   machine's other ports were tape, printer and an expansion bus, so the tile
#   ships --pointer none --input-backend disabled and X runs with -nocursor.
#
#   The golden is the machine's OWN untouched power-on screen. Nothing is typed
#   into it and nothing is curated: the Plus/4 add proved the opposite wrong on
#   the exhibit floor (a visitor arriving inside an application with no idea
#   what it was), and the interaction lives in the SPA's on-screen keyboard and
#   its registry demoProgram instead.
#
# ---- MEDIA ------------------------------------------------------------------
#   ONE 16 KB ROM: `basic11b.rom`, sha1 9451a1a0…, the Atmos's Extended BASIC
#   V1.1. Preservation-source (Tangerine and Oric Products are both long gone);
#   the bits are never committed — see docs/lab/ASSETS-MANIFEST.md for the
#   fetch URL, the measured hashes and the licence class. The builder fetches it
#   from the pinned archive.org item if it is not already staged, and verifies
#   the containing zip by sha256 AND the extracted ROM by sha1 before use.
#
# ---- TRAPS THIS TILE PAID FOR (all measured on this box, 2026-08-09) --------
#   * -verifyroms IS NOT A GATE for a BIOS-selectable computer driver. `orica`
#     offers 25 BIOS variants and the set here holds exactly one, so verifyroms
#     reports "bad" while the pinned BIOS is present and hash-perfect. The gate
#     below is instead: ask the SHIPPED BINARY, via its own -listxml, which sha1
#     it demands for bios `ver11`, and compare that with the staged file. That
#     survives a MAME version bump; a filename never does.
#   * THE RED NAG SCREEN does not apply here, but it was checked rather than
#     assumed: `orica` is <driver status="good" emulation="good"
#     savestate="supported"/>, asserted below against the shipped binary, and
#     then confirmed by looking at the framebuffer.
#   * -bios IS PINNED EXPLICITLY. Relying on MAME's default BIOS choice is how
#     the dragon32 recon ended up booting the wrong ROM entirely.
#   * MAME'S UI KEYS ARE OFF because the driver emulates a full 59-key keyboard,
#     so a visitor pressing Tab gets the Oric's own key, not MAME's menu. That
#     is MAME's documented behaviour for full-keyboard drivers and is why this
#     tile needs no UI lockout, unlike a partial-keyboard arcade driver.
#   * THE X ROOT IS FORCED TO 800x600 by the launcher, and the size was chosen
#     by MEASUREMENT, not by taste. The bridge base's .xinitrc asks for
#     1024x768 and does not always get it (observed here: the root stayed at
#     the 1280x800 default), so the launcher asks again — but 1024x768 is also
#     the wrong answer on this box. MAME's software blit dominates its cost,
#     and a 6502 at 1 MHz cannot make the frame rate back:
#
#       X root      -prescale 2 -nofilter, 8 s, box at load ~75
#       1280x800    ~35%   (the mode the root defaults to)
#       1024x768     53%
#        800x600     83%
#        640x480     97%
#
#     800x600 is 4:3, which is the shape the Atmos drew on a television, so
#     -keepaspect still fills the captured frame edge to edge with no black
#     surround, and 240x224 scaled 2.7x is more resolution than the machine
#     has. c64/vic20/pet2001/cbm2 land on the same mode for the same reason.
#     Do not force MAME's -resolution to 240x224: that is the pixel count, not
#     the picture's shape (the MPF-II trap).
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the
# oricatmos tile dir; refuses to run while streamhost@oricatmos is active.
#
# Usage: oricatmos.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=oricatmos
VMID=234
UDP=54131
SSH_PORT=5834
WEB_PORT=8134
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/oricatmos
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=768

STAGING=/data/assets-staging/oricatmos
ROM="$STAGING/basic11b.rom"
ROM_SHA1=9451a1a09d8f75944dbd6f91193fc360f1de80ac
ROM_SHA256=ed28568574716eef5d7c0fde2568d7a47a6e4b1fbca81daff3be05e45723466d
# Merged MAME 0.224 set: `orica` is a clone of `oric1`, so its BIOS variants sit
# in the PARENT's zip under an `orica/` prefix. Pinned by the zip's own sha256.
ROM_ZIP_URL="https://archive.org/download/MAME_0.224_ROMs_merged/oric1.zip"
ROM_ZIP_SHA256=9a9b227ea8f234ba99a9309fbddbf5506ae6333fbc357a5a3e8ab20f7f22b093
ROM_ZIP_MEMBER=orica/basic11b.rom
MAME=/data/vms/streamhost/assets/oricatmos/mame/oricatmos

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
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

log() { echo "[oricatmos $(date +%H:%M:%S)] $*"; }
die() {
  echo "[oricatmos] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The kiosk launcher. MAME runs FULLSCREEN with its own aspect correction on a
# 4:3 root, which reconstructs the picture the Atmos drew on a television.
# -prescale 2 renders 480x448 before the final scale and measured FASTER than
# both prescale 1 and prescale 3; -nofilter keeps the text crisp. stdout may safely go to a log here — the VICE segfault that forbids it
# on the Commodore tiles (docs/guests/vic20.md) is a VICE bug, not a MAME one.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Oric Atmos (1984) ROM BASIC kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/oricatmos.sh for the flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_VIDEODRIVER=x11
export SDL_AUDIODRIVER=alsa
# 800x600: 4:3 like the machine's television picture, and measured 1.6x cheaper
# to blit than 1024x768 on this box. The base .xinitrc's own xrandr does not
# always take, so ask again here.
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
# X AUTO-REPEAT OFF. Every key this exhibit ever sees is a SYNTHETIC press and
# release pair injected over QMP, so X's typematic repeat can only do harm: if
# the release is delivered late (this box runs 30+ emulators), X starts
# repeating and MAME floods the Oric with the held key. Measured here on
# 2026-08-09: with repeat on, the demo listing's line 40 came out as
# PRINT "ORIC ATMOS 19999999999 -- one late release, eleven nines.
xset r off 2>/dev/null || true
sleep 2
exec /opt/oricatmos/mame/oricatmos orica \
  -bios ver11 \
  -rompath /opt/oricatmos/roms \
  -inipath /opt/oricatmos \
  -cfg_directory /opt/oricatmos/cfg \
  -nvram_directory /opt/oricatmos/cfg \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit —
# the core pointer would otherwise sit frozen mid-screen) and every byte of
# console/X-log text kept off the visible VT. The captured framebuffer IS the
# exhibit. Overlays the bridge base's stock /home/bridge/.bash_profile.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (oricatmos overlay).
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

stage_rom() {
  if [ -s "$ROM" ] && [ "$(sha1sum "$ROM" | awk '{print $1}')" = "$ROM_SHA1" ]; then
    log "ROM already staged and hash-verified: $ROM"
    return 0
  fi
  install -d -m 0750 "$STAGING"
  local tmpzip="$STAGING/.oric1.zip.$$"
  log "fetching the pinned preservation set member from archive.org"
  curl -4 -fsSL -o "$tmpzip" "$ROM_ZIP_URL" ||
    die "could not fetch $ROM_ZIP_URL (stage $ROM by hand if the item has moved)"
  [ "$(sha256sum "$tmpzip" | awk '{print $1}')" = "$ROM_ZIP_SHA256" ] || {
    rm -f "$tmpzip"
    die "fetched zip does not match its pinned sha256"
  }
  python3 - "$tmpzip" "$ROM_ZIP_MEMBER" "$STAGING/.basic11b.rom.$$" <<'PY'
import sys, zipfile
src, member, dst = sys.argv[1:4]
with zipfile.ZipFile(src) as z, open(dst, "wb") as out:
    out.write(z.read(member))
PY
  [ "$(sha1sum "$STAGING/.basic11b.rom.$$" | awk '{print $1}')" = "$ROM_SHA1" ] ||
    die "extracted $ROM_ZIP_MEMBER does not match the MAME sha1 pin"
  chmod 0640 "$STAGING/.basic11b.rom.$$"
  mv -f "$STAGING/.basic11b.rom.$$" "$ROM"
  rm -f "$tmpzip"
  (cd "$STAGING" && sha256sum basic11b.rom >MANIFEST.sha256 && sha256sum -c MANIFEST.sha256 >/dev/null)
  [ "$(sha256sum "$ROM" | awk '{print $1}')" = "$ROM_SHA256" ] ||
    die "staged ROM does not match its recorded sha256"
  log "ROM staged and hash-verified: $ROM"
}

# THE ROMSET GATE. Ask the binary we actually ship what it wants, rather than
# trusting a filename or -verifyroms (which reports "bad" here purely because 24
# of the 25 BIOS variants are absent, and which we log for the record only).
assert_romset_against_binary() {
  local want
  want=$(guest "/opt/oricatmos/mame/oricatmos -listxml orica" |
    sed -n 's/.*name="basic11b.rom" bios="ver11".*sha1="\([0-9a-f]*\)".*/\1/p' | head -1) ||
    die "the shipped binary could not list the orica driver"
  [ -n "$want" ] || die "the shipped binary does not know bios ver11 / basic11b.rom for orica"
  [ "$want" = "$ROM_SHA1" ] ||
    die "shipped MAME wants sha1 $want for orica:ver11, staged ROM is $ROM_SHA1"
  guest "/opt/oricatmos/mame/oricatmos -listxml orica | grep -q '<driver status=\"good\"'" ||
    die "the shipped binary no longer marks orica 'good' — check for a red nag panel by frame"
  log "romset gate: shipped binary demands sha1 $want for orica:ver11, staged ROM matches"
  log "romset gate: driver status good (no MAME 'system doesn't work' panel expected)"
  guest "/opt/oricatmos/mame/oricatmos -rompath /opt/oricatmos/roms -verifyroms orica 2>&1 | tail -2" ||
    true
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
    -name streamhost-oricatmos \
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

# Pixel census helpers. The Atmos paints a WHITE page with black ink, filling a
# 4:3 root edge to edge, and the framebuffer is EXACTLY two colours.
#
# THE FIRST VERSION OF THIS PREDICATE WAS TOO WEAK AND IT SHOWED. Measured at
# 800x600 (480000 px):
#
#   bare X root / dead MAME       paper 0        ink 480000
#   MAME up, Oric screen CLEARED  paper 463299   ink 16701   <- the black status
#                                                               bar alone, 800x21
#   the banner, fully painted     paper 456272   ink 23728
#
# An ink floor of 8000 accepted the middle row: the builder's second wait passed
# on a screen holding nothing but the status bar and the cursor, eight seconds
# before the ROM printed its banner, and only luck put a real banner in the
# golden. Hence BOTH a floor above the status bar AND a requirement that two
# CONSECUTIVE polls agree, which no transient boot screen survives.
paper_px() { ppmhist "$EVIDENCE/$1.ppm" | awk '$1 > 180 && $2 > 180 && $3 > 180 { s += $5 } END { print s + 0 }'; }
ink_px() { ppmhist "$EVIDENCE/$1.ppm" | awk '$1 + $2 + $3 < 300 { s += $5 } END { print s + 0 }'; }

ORIC_MIN_PAPER=${ORIC_MIN_PAPER:-350000}
ORIC_MIN_INK=${ORIC_MIN_INK:-21000}
wait_for_banner() {
  local name=$1
  local streak=0
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      local paper ink
      paper=$(paper_px "$name")
      ink=$(ink_px "$name")
      if [ "$paper" -gt "$ORIC_MIN_PAPER" ] && [ "$ink" -gt "$ORIC_MIN_INK" ]; then
        streak=$((streak + 1))
        if [ "$streak" -ge 2 ]; then
          log "banner ready and steady (paper=$paper ink=$ink)"
          return 0
        fi
      else
        streak=0
      fi
    fi
    sleep 2
  done
  die "no steady Oric Atmos BASIC banner after 180 seconds"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# Keyboard proof runs AFTER the bake, against the RESTORED fixture, so nothing
# it types can ever reach the golden. It types a BASIC line and RETURN and
# requires the answer to appear as new ink: an assertion that only says "the
# framebuffer changed" would also pass on a blinking cursor.
keyboard_proof() {
  local before after
  before=$(ink_px golden-restored)
  python3 "$TILE_DIR/type-line.py" "$QMP" 'print 6502*7'
  sleep 3
  capture keyboard-print
  after=$(ink_px keyboard-print)
  [ "$after" -gt "$((before + 300))" ] ||
    die "keyboard proof left the screen unchanged (ink $before -> $after)"
  log "keyboard proof: PRINT 6502*7 echoed and answered (ink $before -> $after)"
  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_banner golden-restored-after-keyboard
}

read -r -d '' TYPE_PY <<'EOS' || true
#!/usr/bin/env python3
"""Type one BASIC line + RETURN into this tile's QEMU over QMP, at the tile's
own SH_KEY_MIN_HOLD_MS/GAP_MS pacing (80/80 -- bisected, see the tile.env
fixture). Explicit press/release pairs, never `send-key hold-time`: QEMU
releases that asynchronously and back-to-back calls overlap and lose keys."""

import json
import socket
import sys
import time

HOLD = GAP = 0.08
PLAIN = {" ": "spc", "*": None, "+": None}
SHIFT = {"*": "8", "+": "equal", "$": "4", "(": "9", ")": "0"}

qmp, text = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(60)
s.connect(qmp)
f = s.makefile("rwb")
f.readline()


def cmd(execute, **args):
    payload = {"execute": execute}
    if args:
        payload["arguments"] = args
    f.write((json.dumps(payload) + "\n").encode())
    f.flush()
    while True:
        msg = json.loads(f.readline())
        if "return" in msg or "error" in msg:
            return msg


cmd("qmp_capabilities")


def key(qcode, down):
    cmd(
        "input-send-event",
        events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}],
    )


def chord(ch):
    if ch.isalnum():
        return [ch.lower()]
    if ch in SHIFT:
        return ["shift", SHIFT[ch]]
    if ch == " ":
        return ["spc"]
    raise SystemExit("unmappable character %r" % ch)


for ch in list(text) + ["\n"]:
    keys = ["ret"] if ch == "\n" else chord(ch)
    for k in keys:
        key(k, True)
    time.sleep(HOLD)
    for k in reversed(keys):
        key(k, False)
    time.sleep(GAP)
EOS

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -x "$MAME" ] ||
  die "missing pinned MAME 0.289 oric binary: $MAME (build it with scripts/build-guests/emulators/build-mame-oricatmos.sh)"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
printf '%s\n' "$TYPE_PY" >"$TILE_DIR/type-line.py"
stage_rom

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
  # The distro package supplies the SDL/X11/ALSA runtime the pinned binary links
  # against; its own MAME 0.251 is never launched.
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get -qq install -y mame >/dev/null
    install -d -m 755 /opt/oricatmos/roms /opt/oricatmos/mame /opt/oricatmos/cfg"
  guest "cat > /opt/oricatmos/mame/oricatmos && chmod 755 /opt/oricatmos/mame/oricatmos" <"$MAME"
  python3 - "$ROM" <<'PY' | guest "cat > /opt/oricatmos/roms/orica.zip && chmod 644 /opt/oricatmos/roms/orica.zip"
import sys, zipfile
buf = __import__("io").BytesIO()
with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[1], "basic11b.rom")
sys.stdout.buffer.write(buf.getvalue())
PY
  assert_romset_against_binary
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge oricatmos 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 8
  wait_for_banner cold-boot-banner
fi

# One clean cold boot with the quiet console in force, then bake THAT screen.
# Never bake a framebuffer that has carried verification output: the mpf2 add
# shipped one and restored for ever after to a scrolled screen with the banner
# gone.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 8
wait_for_banner ready-before-golden
guest "pgrep -x oricatmos >/dev/null" || die "MAME exited after the cold boot"
bake_golden
sleep 3
wait_for_banner golden-restored
keyboard_proof

log "PASS: Oric Atmos Extended BASIC V1.1 banner, keyboard path, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
