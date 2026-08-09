#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/kc854.sh — build the KC 85/4 (VEB Mikroelektronik "Wilhelm
# Pieck" Mühlhausen, 1988) streamhost tile as a thin overlay on the frozen
# bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 X kiosk running a purpose-built MAME `kc85_4`
#         that boots CAOS 4.2 from ROM. streamhost captures the Linux
#         framebuffer + AC97 audio like every other bridge tile
#         (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE MACHINE ------------------------------------------------------------
#   East Germany's flagship educational/home computer: a U880 (East Germany's
#   unlicensed Z80 clone) at 1 773 447 Hz — MAME's KC85_4_CLOCK, from
#   src/mame/ddr/kc.h — with 64 KB of main RAM and 64 KB of dedicated screen
#   memory, 320x256 at 50.080411 Hz, two module slots plus an expansion
#   connector, and CAOS: its own operating system, in ROM, which puts a menu of
#   its commands on the screen at power-on. The KC 85 line from Mühlhausen and
#   Robotron's Z9001 / KC 85/1 / KC 87 are DIFFERENT, incompatible machines
#   that share only the "KC" (Kleincomputer) prefix — see
#   registry/posters/kc854.md.
#
# ---- THREE TRAPS THIS BUILD PAYS FOR ----------------------------------------
#
#   1. THE ROMSET MUST BE ASSEMBLED BY SHA1, NEVER BY FILENAME.
#      `mame -listxml kc85_4` wants five ROMs, one of which is `basic_c0.854`
#      (sha1 c2e3af55...). In the merged preservation set that byte-identical
#      dump is stored as `kc85_3/basic_c0.853` and there is NO member called
#      `basic_c0.854` anywhere in the archive — measured, not assumed
#      (2026-08-09). A filename-driven assembly silently produces a set with no
#      BASIC in it. This script indexes every member of the staged zip by SHA1,
#      asks the SHIPPED binary what kc85_4 wants, and emits a fresh zip.
#
#   2. `-verifyroms` IS NOT THE GATE; THE PINNED BIOS ENTRIES ARE.
#      kc85_4 is BIOS-selectable (caos42 / caos41), so verifyroms complains
#      about whichever alternative BIOS is absent even when the set is perfect.
#      This script asserts the SHA1 of the three ROMs the tile actually pins —
#      caos__c0.854, caos__e0.854 (both CAOS 4.2) and basic_c0.854 — and treats
#      verifyroms as advisory output only.
#
#   3. THE RED NAG SCREEN.
#      `mame -listxml kc85_4` reports driver status="preliminary", so stock MAME
#      opens with a full-screen red "THIS SYSTEM DOESN'T WORK" panel that
#      -skip_gameinfo does NOT suppress and that a headless -video none probe
#      never renders. Shipping that is shipping an error message as an exhibit.
#      The pinned binary carries mame-irix-skip-warnings.patch, which makes
#      ui.ini's `skip_warnings 1` apply to the panel, so the kiosk never has to
#      post a dismissal key and the golden is a genuinely untouched boot screen.
#      wait_for_caos() below asserts the panel's own red is absent from the
#      frame, so a regression here fails the build instead of shipping.
#
# ---- X ROOT AND EMULATOR WINDOW ---------------------------------------------
#   The KC 85/4 draws 320x256 at 50.08 Hz onto a 4:3 television. 320x256 is the
#   PIXEL count, not the picture's shape, so -resolution is NOT forced to it
#   (the mpf2 add proved what that costs: a narrow strip in a black root). MAME
#   runs fullscreen with -keepaspect on the bridge base's stock 1024x768 root,
#   which reconstructs the 4:3 picture and fills the captured frame.
#
# ---- KEY PACING -------------------------------------------------------------
#   MAME samples the emulated keyboard matrix once per emulated frame; at
#   50.08 Hz that is 19.97 ms, so the frame-derived floor is 40/40. The VIC-20
#   add showed that floor is not enough on THIS box — the residual loss is a
#   host scheduling stall, not frame quantisation — so the shipped values are
#   BISECTED here with scripts/dev/emu-key-pacing-bisect.py, not derived.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the kc854
# tile dir; refuses to run while streamhost@kc854 is active.
#
# Usage: kc854.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=kc854
VMID=235
UDP=54132
SSH_PORT=5835
BRIDGE_BASE=/data/vms/bridge/bridge-base.qcow2
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/kc854
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=768
# Staged preservation source: the merged MAME romset zip for the kc85_2 family
# (see docs/lab/ASSETS-MANIFEST.md). Never redistributed from this repo.
SRC_ZIP=/data/assets-staging/kc854/kc85_2.zip
SRC_ZIP_SHA256=ed5b8a567232beb89a5f78fea4066160aec2ba0f2a67555439c20785d6a096ab
MAME=/data/vms/streamhost/assets/kc854/mame/kc85
# The three ROMs the tile pins: CAOS 4.2 (the default BIOS) plus HC-BASIC.
PIN_C0_SHA1=774fc2496a59b77c7c392eb5aa46420e7722797e
PIN_E0_SHA1=4300f7ff813c1fb2d5c928dbbf1c9e1fe52a9577
PIN_BASIC_SHA1=c2e3af55c79e049e811607364f88c703b0285e2e

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,72p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[kc854 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[kc854] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# -bios caos42 is PINNED rather than left to the driver default: the default is
# a property of the MAME revision, and a silent flip to CAOS 4.1 would change
# the exhibit's boot screen without changing anything in this repo.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# KC 85/4 (CAOS 4.2) kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/kc854.sh for the flag rationale.
# 320x256 @ 50.08 Hz, drawn FULLSCREEN with aspect correction on the stock
# 1024x768 X root, so the captured frame is the 4:3 picture the machine drew
# on a television rather than a 320x256 strip in a black surround.
sleep 2
exec /opt/kc854/mame/kc85 kc85_4 \
  -bios caos42 \
  -rompath /opt/kc854/roms \
  -inipath /opt/kc854 \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile. -nocursor because the KC 85/4 is a keyboard-only
# exhibit (its pointing device options were a light pen and a joystick module,
# neither of which the gallery streams); the X core pointer would otherwise sit
# frozen in the middle of the captured frame. Redirecting stdout to a log file
# is safe here — that is a VICE 3.9 fault (docs/guests/vic20.md), not a MAME
# one — and it keeps MAME's own chatter off the visible VT.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (kc854 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit) and keep every byte of console/X-log text
# off the visible VT: the captured framebuffer IS the exhibit.
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

# Assemble kc85_4.zip BY SHA1, IN THE GUEST, against the binary that will
# actually run it. Doing it in the guest is the point: "verified against the
# MAME you ship" is only true if the -listxml that names the wanted (name,
# sha1) pairs came out of that same executable.
assemble_romset() {
  guest 'set -e
    install -d -m 755 /opt/kc854/roms /opt/kc854/mame /opt/kc854/src
    command -v python3 >/dev/null || { echo "guest has no python3" >&2; exit 1; }'
  install -m 755 "$MAME" /tmp/kc854-mame.$$
  guest "cat > /opt/kc854/mame/kc85 && chmod 755 /opt/kc854/mame/kc85" </tmp/kc854-mame.$$
  rm -f /tmp/kc854-mame.$$
  guest "cat > /opt/kc854/src/merged.zip" <"$SRC_ZIP"
  guest "cat > /opt/kc854/assemble-romset.py" <<'PYEOS'
#!/usr/bin/env python3
"""Emit /opt/kc854/roms/kc85_4.zip from a merged preservation zip, BY SHA1.

MAME renames ROM files between releases and moves dumps between a parent's zip
and a clone's subdirectory: the dump this driver calls `basic_c0.854` is stored
in the merged set as `kc85_3/basic_c0.853`, and nothing called `basic_c0.854`
exists in the archive at all. Names are therefore untrustworthy and content is
not, so every member is indexed by SHA1 and the wanted set is taken from the
shipping binary's own -listxml.
"""

import hashlib
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

MERGED, MAME, OUT = sys.argv[1], sys.argv[2], sys.argv[3]

xml = subprocess.run(
    [MAME, "-listxml", "kc85_4"], check=True, capture_output=True, text=True
).stdout
root = ET.fromstring(xml)
machine = next(m for m in root.iter("machine") if m.get("name") == "kc85_4")
wanted = {}
for rom in machine.findall("rom"):
    sha1, name = rom.get("sha1"), rom.get("name")
    if sha1 and name and rom.get("status") != "nodump":
        wanted[name] = sha1.lower()
if not wanted:
    sys.exit("the shipping binary lists no kc85_4 ROMs")

by_sha1 = {}
with zipfile.ZipFile(MERGED) as z:
    for info in z.infolist():
        if info.is_dir():
            continue
        blob = z.read(info)
        by_sha1.setdefault(hashlib.sha1(blob).hexdigest(), blob)

missing = sorted(n for n, s in wanted.items() if s not in by_sha1)
if missing:
    sys.exit(f"merged source has no dump for: {', '.join(missing)}")

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as out:
    for name, sha1 in sorted(wanted.items()):
        out.writestr(name, by_sha1[sha1])
        print(f"{sha1}  {name}")
PYEOS
  guest "python3 /opt/kc854/assemble-romset.py /opt/kc854/src/merged.zip \
    /opt/kc854/mame/kc85 /opt/kc854/roms/kc85_4.zip" ||
    die "could not assemble kc85_4.zip by SHA1 from the staged merged set"

  # Gate on the SHA1 of the BIOS entries this tile pins, not on -verifyroms:
  # kc85_4 is BIOS-selectable, so verifyroms reports "bad" for whichever
  # alternative BIOS is absent even when the shipped set is hash-perfect.
  # shellcheck disable=SC2016 # $z/$want/$got are the GUEST python's, by design
  guest "python3 - /opt/kc854/roms/kc85_4.zip \
      $PIN_C0_SHA1 $PIN_E0_SHA1 $PIN_BASIC_SHA1 <<'PYEOS'
import hashlib, sys, zipfile
zp, want = sys.argv[1], dict(zip(('caos__c0.854', 'caos__e0.854', 'basic_c0.854'), sys.argv[2:5]))
with zipfile.ZipFile(zp) as z:
    have = {n: hashlib.sha1(z.read(n)).hexdigest() for n in z.namelist()}
for name, sha1 in want.items():
    got = have.get(name)
    if got != sha1:
        sys.exit(f'pinned ROM {name}: expected {sha1}, found {got}')
print('pinned CAOS 4.2 + HC-BASIC ROMs verified by sha1')
PYEOS" || die "the assembled romset does not match the tile's pinned ROM SHA1s"

  # Advisory only. Printed so a future reader can see WHAT verifyroms objects
  # to (the absent caos41 alternative), rather than rediscovering that it lies.
  guest "/opt/kc854/mame/kc85 -rompath /opt/kc854/roms -verifyroms kc85_4 || true" |
    sed 's/^/[kc854 verifyroms] /' || true
  # skip_warnings is what the patched binary honours to suppress the red
  # "THIS SYSTEM DOESN'T WORK" panel this preliminary driver would otherwise
  # show for ever.
  guest "printf 'skip_warnings 1\n' > /opt/kc854/ui.ini"
  log "romset assembled by sha1 and pinned ROMs verified against the shipping binary"
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
    -name streamhost-kc854 \
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

# Pixel predicates over a ppmhist row's R/G/B columns. Held in variables so the
# "do not expand these" exemption is stated once, at the definition.
# shellcheck disable=SC2016 # awk field references; bash must NOT expand them
BRIGHT_PRED='$1 > 96 && $2 > 96 && $3 > 96'
# shellcheck disable=SC2016 # awk field references; bash must NOT expand them
NAG_RED_PRED='$1 > 140 && $2 < 90 && $3 < 90'

# Count pixels in a PPM matching an awk predicate over $1/$2/$3 (R/G/B).
hist_count() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk "$2 { sum += \$5 } END { print sum + 0 }"
}

# READINESS PREDICATE. CAOS 4.2 paints a turquoise/white command menu on a black
# page, so a live emulated KC fills a wide band of the 1024x768 root with bright
# pixels while a bare X root, a dead MAME or a still-booting Linux leaves it
# black. The second half is the trap guard: MAME's "THIS SYSTEM DOESN'T WORK"
# panel is a large field of its own red, and this driver is `preliminary`, so
# without the patched binary that panel IS the screen. Requiring bright pixels
# AND no red panel is a predicate that can fail both ways.
KC854_MIN_BRIGHT=${KC854_MIN_BRIGHT:-20000}
KC854_MAX_NAG=${KC854_MAX_NAG:-2000}
wait_for_caos() {
  local name=$1
  local bright nag
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      bright=$(hist_count "$name" "$BRIGHT_PRED")
      nag=$(hist_count "$name" "$NAG_RED_PRED")
      if [ "$bright" -gt "$KC854_MIN_BRIGHT" ] && [ "$nag" -lt "$KC854_MAX_NAG" ]; then
        log "CAOS ready (bright=$bright, nag-red=$nag)"
        return 0
      fi
    fi
    sleep 2
  done
  die "no warning-free CAOS framebuffer after 180 s (bright=${bright:-?}, nag-red=${nag:-?})"
}

# Type a paced key sequence through ONE persistent QMP connection, with the
# tile's PRODUCTION hold/gap. A connection per key was tried first and is a
# WORSE instrument than the thing it measures: a socat-per-key proof dropped the
# 'a' out of "basic" while a single-connection run at the same 80/80 lost 0 of
# 12 thirty-two-character lines. streamhost's own input path holds one
# connection open, so this is also the more faithful proof.
KC854_HOLD_MS=${KC854_HOLD_MS:-80}
KC854_GAP_MS=${KC854_GAP_MS:-80}
type_paced() {
  python3 - "$QMP" "$KC854_HOLD_MS" "$KC854_GAP_MS" "$@" <<'PYEOS'
import json, socket, sys, time

qmp, hold, gap = sys.argv[1], int(sys.argv[2]) / 1000.0, int(sys.argv[3]) / 1000.0
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
for qcode in sys.argv[4:]:
    cmd("input-send-event", events=[{"type": "key", "data": {"down": True, "key": {"type": "qcode", "data": qcode}}}])
    time.sleep(hold)
    cmd("input-send-event", events=[{"type": "key", "data": {"down": False, "key": {"type": "qcode", "data": qcode}}}])
    time.sleep(gap)
PYEOS
}

# Prove the PS/2 keyboard path reaches the emulated KC, and prove the ONE thing
# about this machine's keyboard a visitor meets first: its UNSHIFTED letter row
# produces UPPER case. MAME's src/mame/ddr/kc_keyb.cpp declares PORT_CHAR('B')
# PORT_CHAR('b') — in that order — for all 26 letters, so shift gives LOWER
# case, the opposite of every later convention. Typing the CAOS command `basic`
# with NO shift can therefore only work if that inversion is real: HC-BASIC
# CLEARS the menu and asks "MEMORY END ?", collapsing the bright-pixel count to
# a fraction of the menu screen's.
#
# An earlier draft asserted only "the framebuffer changed", which a single
# stray character at the prompt also satisfies. It passed nothing and would
# have hidden the very drop that exposed the socat-per-key instrument above.
keyboard_proof() {
  local menu_bright basic_bright attempt
  menu_bright=$(hist_count ready-before-golden "$BRIGHT_PRED")
  for attempt in 1 2 3; do
    type_paced b a s i c ret
    sleep 3
    capture "keyboard-basic-$attempt"
    basic_bright=$(hist_count "keyboard-basic-$attempt" "$BRIGHT_PRED")
    if [ "$basic_bright" -lt $((menu_bright / 2)) ]; then
      cp "$EVIDENCE/keyboard-basic-$attempt.png" "$EVIDENCE/keyboard-basic.png"
      cp "$EVIDENCE/keyboard-basic-$attempt.ppm" "$EVIDENCE/keyboard-basic.ppm"
      log "keyboard proof: unshifted 'basic'+RETURN started HC-BASIC on attempt $attempt (menu=$menu_bright basic=$basic_bright)"
      return 0
    fi
    log "attempt $attempt did not reach HC-BASIC (bright=$basic_bright); clearing the line and retrying"
    type_paced ret
    sleep 2
  done
  die "unshifted 'basic' never started HC-BASIC in 3 attempts (menu=$menu_bright last=$basic_bright)"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

[ -f "$BRIDGE_BASE" ] || die "missing frozen bridge base: $BRIDGE_BASE"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -s "$SRC_ZIP" ] ||
  die "missing staged romset: $SRC_ZIP (see docs/lab/ASSETS-MANIFEST.md)"
[ "$(sha256sum "$SRC_ZIP" | awk '{print $1}')" = "$SRC_ZIP_SHA256" ] ||
  die "staged romset SHA256 does not match the recorded pin"
[ -x "$MAME" ] ||
  die "missing pinned MAME binary: $MAME (build it with build-mame-kc854.sh)"
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
  # The distro package is installed for its SDL/X11 runtime dependencies only;
  # its own MAME binary is never launched, because the pinned build replaces it.
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y mame" || die "could not install the SDL/X11 runtime in the guest"
  assemble_romset
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge kc85 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_caos cold-boot-caos
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the very state SPA reset will restore for ever after. THE GOLDEN IS THE
# MACHINE'S OWN UNTOUCHED POWER-ON SCREEN: CAOS 4.2's command menu, which is
# both the KC's honest idle state and its own launcher. Nothing is typed before
# the bake — the mpf2 add shipped a golden that still carried its verification
# output and had to be re-baked, and the Plus/4's first golden rested inside an
# application and dropped visitors into the middle of it.
stop_qemu
boot_tile
sleep 8
wait_for_caos ready-before-golden
guest "pgrep -x kc85 >/dev/null" || die "MAME exited after cold boot"
guest "awk '/MemAvailable/ {print \"guest MemAvailable: \" \$2 \" kB\"}' /proc/meminfo"
bake_golden
sleep 3
wait_for_caos golden-restored

# Keyboard proof runs AFTER the bake, against the restored fixture, so nothing
# it types can ever reach the golden.
keyboard_proof
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_caos golden-restored-after-keyboard

log "PASS: KC 85/4 CAOS 4.2 menu fixture, keyboard path, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
