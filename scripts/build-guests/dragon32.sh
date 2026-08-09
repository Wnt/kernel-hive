#!/usr/bin/env bash
# =============================================================================
# build-guests/dragon32.sh — build the Dragon 32 (1982) streamhost tile as a
# thin overlay on the frozen bridge base (scripts/build-guests/bridge-base.sh).
#
# GUEST : a captured Debian-12 X kiosk running MAME's `dragon32` driver, resting
#         at the machine's own untouched power-on screen.
# TYPE  : "emulator bridge" tile, the same shape as mpf2 — overlay + per-tile
#         /etc/bridge/launch.sh + an INTERNAL qcow2 `golden` snapshot
#         (resetMode=loadvm).
#
# ---- THE TRAP THAT IS THE WHOLE JOB ON THIS TILE ----------------------------
#   `mame dragon32` with no slot options does NOT boot Microsoft BASIC. The
#   driver's `ext` cartridge slot defaults to `dragon_fdc`, so the machine comes
#   up in DragonDOS and paints
#
#       DRAGONDOS 1.0
#       OK
#
#   — a disk operating system for hardware this exhibit does not have, on a
#   machine famous for the three lines it prints instead.
#
#   Worse, the obvious tool points the WRONG WAY. `-verifyroms dragon32` fails
#   with `ddos10.rom NOT FOUND (tried in dragon_fdc dragon32)`: it verifies the
#   DEFAULT slot configuration, so it DEMANDS the very ROM that produces the
#   wrong screen. Measured here 2026-08-09, MAME 0.276 and 0.289 alike:
#   `mame dragon32` cannot run at all, `mame dragon32 -ext ""` prints the
#   Microsoft BASIC banner and exits 0.
#
#   So: the slot is emptied with `-ext ""`, `-verifyroms` is NEVER used as a
#   gate, and the romset is gated instead on the sha1 of the ROM entries this
#   configuration actually pins, taken from the SHIPPED binary's own
#   `-listxml dragon32`. That last word matters: 0.276 declares one 16 KB
#   `d32.rom` and 0.289 declares the same bits as two 8 KB halves named after
#   their chips, so a romset assembled against the wrong version's FILENAMES
#   does not load at all. The final arbiter is the frame, and the frame is read
#   rather than eyeballed (below), so the assertion can fail.
#
# ---- WHAT THE GOLDEN RESTS AT -----------------------------------------------
#   Nothing is curated and nothing is typed before the bake. The fixture is the
#   screen the machine chose for itself:
#
#       (C) 1982 DRAGON DATA LTD
#       16K BASIC INTERPRETER 1.0
#       (C) 1982 BY MICROSOFT
#
#       OK
#
#   dark green on the MC6847's bright green page. That is the Plus/4 lesson
#   applied before it could be repeated (see plus4.sh): a golden baked inside an
#   application drops a visitor into the middle of something. The affordances go
#   in the SPA's on-screen keyboard AROUND an honest idle screen.
#
# ---- HOW THE SCREEN IS ASSERTED ---------------------------------------------
#   Two independent tests, both of which must pass on every capture.
#
#   1. OCR (tesseract on the thresholded dump): MICROSOFT + DATA + "1.0" must be
#      present, DRAGONDOS absent. The first two alone already exclude the
#      DragonDOS screen ("DRAGONDOS 1.0 / OK"). The token list is short on
#      purpose — tesseract mangles this blocky font differently between MAME
#      builds ("16K"->"16E", "BASIC"->"EFASIC", "DRAGON"->"DRAGOHW" on 0.289) —
#      and a gate resting on a glyph it happens to read today fails a correct
#      exhibit tomorrow.
#   2. Structure, which no OCR touches: text-coloured pixels in the top band.
#      The banner puts 71 characters in three rows (measured 6376 px);
#      DragonDOS puts 13 in one (~1170).
#
#   A whole-frame histogram would not do: both screens are the same two greens.
#
# ---- MAME BINARY PROVENANCE -------------------------------------------------
#   Debian 12 packages MAME 0.251 and the lab host's 0.276 is not a Debian 12
#   binary, so this tile ships MAME 0.289 built in the Bookworm chroot by
#   scripts/build-guests/build-mame-dragon32.sh — the same upstream commit mpf2
#   ships, so the gallery runs one MAME version and not two. Unlike mpf2's it is
#   PRISTINE upstream: dragon32 is `<driver status="good" emulation="good">` and
#   never raises MAME's red "THIS SYSTEM DOESN'T WORK" panel, so there is no
#   patch to justify. The subtarget build is also markedly cheaper than the
#   distro's full binary on the same frame — measured in the kiosk, ~48 % of a
#   vCPU against ~110 %, and 170 MB RSS against 322 MB — which is why the tile
#   fits in 768 MB and why its keys survive a busy host. The distro `mame`
#   package stays installed for its SDL/X11 runtime libraries only.
#
# ---- GEOMETRY ---------------------------------------------------------------
#   The Dragon draws 372x293 at 49.97 Hz PAL (MC6847 + its overscan border).
#   MAME runs fullscreen with aspect correction on the bridge base's stock
#   1024x768 X root, exactly as mpf2 does: 1024x768 is 4:3, so the picture fills
#   the root and the dark-green surround is the Dragon's OWN border. Do NOT pin
#   `-resolution 372x293`: that is the pixel count, not the picture's shape, and
#   it strands a small strip in a black root (mpf2 made that mistake first).
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the dragon32 tile dir; refuses to
# run while streamhost@dragon32 is active.
#
# Usage: dragon32.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=dragon32
VMID=233
UDP=54130
SSH_PORT=5833
WEB_PORT=8133
BRIDGE_BASE=/data/vms/bridge/bridge-base.qcow2
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/dragon32
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=768

# The whole romset for `dragon32 -ext ""` is 16 KB: the Dragon monitor plus
# Microsoft 16K Extended Color BASIC. This is the staged blob as fetched.
ROM_DIR=/data/assets-staging/dragon32
ROM="$ROM_DIR/d32.rom"
ROM_SHA1=f2dab125673e653995a83bf6b793e3390ec7f65a
ROM_SHA256=fc0e900bfec6b52f0f80ba1e65a4712808d2a411b5b00496639ef1a2152351f1
ROM_URL="https://archive.org/download/MAME_0.224_ROMs_merged/dragon32.zip/d32.rom"
# ...and how MAME 0.289 wants those same 16 KB presented. ASSEMBLE BY SHA1, NOT
# BY FILENAME: 0.276 declares one 16 KB `d32.rom`, and 0.289 declares the SAME
# bits as two 8 KB halves under their chip designations at offsets 0 and 0x2000.
# A romset built from the older name loads in neither. The halves below were
# verified to be exactly `dd`-split from the staged blob (2026-08-09).
ROM_HALF0_NAME=dragon_data_ltd_1-0.ic18
ROM_HALF0_SHA1=9fbba5128b8a53c65ee0586c10513a0a6fb05a7d
ROM_HALF1_NAME=dragon_data_ltd_1-1.ic17
ROM_HALF1_SHA1=7088d75995cc2ec80a7eed9b9cc3d62f0f820a43
MAME=/data/vms/streamhost/assets/dragon32/mame/dragon

# The words tesseract reads correctly off this blocky 8x12 font in EVERY
# observed run. It mangles more of the banner than one would like -- "16K" has
# come back as "16E", "BASIC" as "EFASIC", "INTERPRETER" as "INTERFRETER" and
# even "DRAGON" as "DRAGOHW" -- and which glyphs it mangles is not stable
# between MAME builds, so the gate uses only the tokens that have never moved.
# All must be present; DRAGONDOS must not be. Note that MICROSOFT and DATA alone
# already exclude the DragonDOS screen, which reads "DRAGONDOS 1.0 / OK".
WANT_TOKENS=("MICROSOFT" "DATA" "1.0")
REJECT_TOKEN="DRAGONDOS"
# Structural half of the same assertion, immune to OCR: text-coloured pixels in
# the top band of the frame. The BASIC banner puts 71 characters in the first
# three rows and measures 6376 such pixels (~90 px per character); DragonDOS
# puts 13 characters in one row, i.e. about 1170. 3000 sits between them with
# room on both sides.
TEXT_RGB="0 124 0"
MIN_BANNER_INK=${MIN_BANNER_INK:-3000}

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,96p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[dragon32 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[dragon32] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# ---------------------------------------------------------------------------
# The kiosk launcher. `-ext ""` is the single most important character in this
# file; see the header. `-skip_gameinfo` only suppresses the info screen — it
# would NOT suppress a red "doesn't work" panel, which is why the driver status
# was checked rather than assumed.
# ---------------------------------------------------------------------------
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Dragon 32 (1982) Microsoft Extended Color BASIC kiosk launcher (bridge tile).
# See scripts/build-guests/dragon32.sh for the flag rationale.
#
#   -ext ""      EMPTY the cartridge/expansion slot. Without this the driver
#                defaults to `dragon_fdc` and the machine boots DRAGONDOS, not
#                BASIC. This is the exhibit.
#   -keepaspect  372x293 PAL frame drawn as the 4:3 picture a television showed,
#                filling the stock 1024x768 X root.
#   -prescale 2  load-bearing, not cosmetic: dropped, the captured root goes
#                BLACK while MAME keeps running (measured on a clone).
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
exec /opt/dragon32/mame/dragon dragon32 \
  -rompath /opt/dragon32/roms \
  -inipath /opt/dragon32 \
  -ext "" \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit),
# and no console/X-log text on the visible VT. Unlike the VICE tiles, MAME is
# perfectly happy with a non-tty stdout, so the X log goes to a file (VICE 3.9
# would segfault here — see docs/guests/vic20.md).
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (dragon32 overlay). Start X with NO core pointer cursor
# (-nocursor: the Dragon's only input is its keyboard, and a frozen arrow in the
# middle of the exhibit is worse than none) and keep every byte of console/X-log
# text off the visible VT: the captured framebuffer IS the exhibit.
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
    -name streamhost-dragon32 \
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
}

# Digits only. Tesseract is markedly better at this font when it cannot reach
# for letters: the answer "21" comes back as "el" under a free alphabet and as
# "21" with the whitelist, on the very same dump. Used by the keyboard proof.
screen_digits() {
  local name=$1
  convert "$EVIDENCE/$name.ppm" -colorspace Gray -threshold 40% -negate \
    "$EVIDENCE/$name-ocr.png"
  tesseract "$EVIDENCE/$name-ocr.png" - --psm 6 \
    -c tessedit_char_whitelist=0123456789 2>/dev/null | tr -d '\r'
}

# Read the emulated Dragon's text off the QEMU framebuffer. Threshold at 40% of
# full scale: the MC6847's bright-green page sits at luma ~117 and its dark-green
# text at ~34, so 40% (102) separates them; 50% swallows the page as well and
# tesseract then sees nothing at all (measured on this tile's own dump).
screen_text() {
  local name=$1
  convert "$EVIDENCE/$name.ppm" -colorspace Gray -threshold 40% -negate \
    "$EVIDENCE/$name-ocr.png"
  tesseract "$EVIDENCE/$name-ocr.png" - --psm 6 2>/dev/null | tr -d '\r'
}

# The build's central assertion: this is the Microsoft BASIC banner and NOT the
# DragonDOS screen the default slot configuration produces.
banner_ink() {
  local name=$1
  convert "$EVIDENCE/$name.ppm" -crop 1024x230+0+60 +repage "$EVIDENCE/$name-top.ppm"
  ppmhist "$EVIDENCE/$name-top.ppm" 2>/dev/null |
    awk -v want="$TEXT_RGB" '$1" "$2" "$3 == want { print $5; found = 1 }
      END { if (!found) print 0 }'
}

assert_basic_banner() {
  local name=$1 text token ink
  ink=$(banner_ink "$name")
  [ "${ink:-0}" -ge "$MIN_BANNER_INK" ] || return 1
  text=$(screen_text "$name" | tr '[:lower:]' '[:upper:]')
  for token in "${WANT_TOKENS[@]}"; do
    case "$text" in
      *"$token"*) ;;
      *) return 1 ;;
    esac
  done
  case "$text" in
    *"$REJECT_TOKEN"*)
      die "framebuffer shows $REJECT_TOKEN: the ext slot is populated, so this is
    the disk operating system and not Microsoft BASIC. The launcher lost its
    -ext \"\" — see the header of $0."
      ;;
  esac
  return 0
}

wait_for_basic() {
  local name=$1
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null && assert_basic_banner "$name"; then
      log "framebuffer proof: $EVIDENCE/$name.png (Microsoft BASIC banner, OCR-verified)"
      return 0
    fi
    sleep 2
  done
  capture "$name" 2>/dev/null || true
  die "no Dragon 32 Microsoft BASIC framebuffer after 180 s; last banner ink was
$(banner_ink "$name" 2>/dev/null) px (need >= $MIN_BANNER_INK) and OCR read:
$(screen_text "$name" 2>/dev/null)"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# ---------------------------------------------------------------------------
# Media: one ROM, fetched by SHA rather than trusted by filename. MAME renames
# ROM files between versions and moves parent/clone splits, so the identity that
# matters is the hash; the URL is only where a copy happened to be found.
# ---------------------------------------------------------------------------
stage_rom() {
  if [ -s "$ROM" ] && [ "$(sha1sum "$ROM" | awk '{print $1}')" = "$ROM_SHA1" ]; then
    log "ROM already staged and hash-correct: $ROM"
    return 0
  fi
  install -d -m 0750 "$ROM_DIR"
  log "fetching d32.rom from the preservation source"
  curl -sSL --fail -o "$ROM.tmp" "$ROM_URL" ||
    die "could not fetch $ROM_URL (stage $ROM by hand and re-run)"
  [ "$(sha1sum "$ROM.tmp" | awk '{print $1}')" = "$ROM_SHA1" ] ||
    die "fetched d32.rom SHA1 does not match the MAME pin $ROM_SHA1"
  [ "$(sha256sum "$ROM.tmp" | awk '{print $1}')" = "$ROM_SHA256" ] ||
    die "fetched d32.rom SHA256 does not match the recorded intake hash"
  mv -f "$ROM.tmp" "$ROM"
  sha256sum "$ROM" >"$ROM_DIR/MANIFEST.sha256"
  log "staged $ROM ($(stat -c%s "$ROM") bytes)"
}

# Gate on the sha1 of the ROM entry the SHIPPED binary declares for this driver.
# NOT on -verifyroms: that verifies the default slot set and demands ddos10.rom,
# i.e. it insists on the configuration that boots the wrong screen.
assert_rom_pin() {
  local name sha
  for pair in "$ROM_HALF0_NAME:$ROM_HALF0_SHA1" "$ROM_HALF1_NAME:$ROM_HALF1_SHA1"; do
    name=${pair%:*}
    sha=${pair#*:}
    guest "/opt/dragon32/mame/dragon -listxml dragon32 2>/dev/null |
      grep -q 'name=\"$name\".*sha1=\"$sha\"'" ||
      die "the shipped MAME binary does not pin $name at $sha — the romset and
    the binary disagree. Re-derive both names and hashes from
    '<machine name=\"dragon32\">' in its own '-listxml dragon32'; they moved
    once already between 0.276 and 0.289."
  done
  log "romset gated against the shipped binary: $ROM_HALF0_NAME + $ROM_HALF1_NAME"
}

# ---------------------------------------------------------------------------
# Keyboard proof, run AFTER the bake against the restored fixture so nothing it
# types can reach the golden. It types PRINT 3*7 and requires the ANSWER: "the
# framebuffer changed" would pass with every shifted key wrong, and '*' is the
# interesting case — the Dragon puts it on SHIFT+the key a PC labels '-', so a
# US-layout '*' (SHIFT+8) lands '(' and BASIC answers ?SN ERROR.
# ---------------------------------------------------------------------------
send_key_chord() {
  local mod=$1 qcode=$2
  python3 - "$QMP" "$mod" "$qcode" <<'PY'
import json, socket, sys, time

qmp, mod, qcode = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
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


def key(code, down):
    cmd("input-send-event", events=[
        {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": code}}}
    ])


# Explicit press/release pairs at the tile's own shipped pacing (80 ms each way):
# QEMU's `send-key hold-time` releases on its own timer and overlapping calls
# lose characters, which makes the instrument lossier than the thing measured.
if mod:
    key(mod, True)
    time.sleep(0.08)
key(qcode, True)
time.sleep(0.08)
key(qcode, False)
time.sleep(0.08)
if mod:
    key(mod, False)
    time.sleep(0.08)
PY
}

keyboard_proof() {
  # PRINT 3*7 -> 21.  '*' is SHIFT + the key a PC labels '-' (KEYCODE_MINUS in
  # the driver's matrix carries ':' unshifted and '*' shifted).
  for k in p r i n t spc 3; do send_key_chord "" "$k"; done
  send_key_chord shift minus
  send_key_chord "" 7
  send_key_chord "" ret
  sleep 2
  capture keyboard-print-3x7
  # The answer must be its OWN line reading exactly 21. The typed line above it
  # comes back as "347" (tesseract reads this font's '*' as a 4), so a substring
  # match would be no assertion at all -- and the digit whitelist is not
  # optional: without it the same dump reads the answer as "el".
  if screen_digits keyboard-print-3x7 | grep -qx '21'; then
    log "keyboard proof: PRINT 3*7 answered 21 (shifted keys reach the matrix)"
  else
    die "keyboard proof failed; the Dragon did not answer 21. OCR read:
$(screen_text keyboard-print-3x7)"
  fi
  hmp "loadvm golden" >/dev/null
  sleep 3
  wait_for_basic golden-restored-after-keyboard
}

# ---------------------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing frozen bridge base: $BRIDGE_BASE"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -x "$MAME" ] ||
  die "missing pinned MAME 0.289 binary: $MAME
    (build it with scripts/build-guests/build-mame-dragon32.sh)"
command -v tesseract >/dev/null ||
  die "tesseract is required: the build reads the Dragon's banner off the
    framebuffer, and a pixel histogram cannot tell BASIC from DragonDOS"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
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

  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    # The distro package supplies the SDL2/X11 runtime libraries the pinned
    # binary links against; its own MAME 0.251 is never launched.
    apt-get install -y -qq mame
    install -d -m 755 /opt/dragon32/roms /opt/dragon32/mame"
  install -m 755 "$MAME" /tmp/dragon32-mame
  guest "cat > /opt/dragon32/mame/dragon && chmod 755 /opt/dragon32/mame/dragon" \
    </tmp/dragon32-mame
  rm -f /tmp/dragon32-mame
  guest "ldd /opt/dragon32/mame/dragon | grep -q 'not found' &&
    { ldd /opt/dragon32/mame/dragon | grep 'not found'; exit 1; } || true" ||
    die "the pinned MAME binary has unresolved libraries in the Debian 12 kiosk"
  # Assemble the romset in the guest from the staged blob. One member, named as
  # the shipped binary's -listxml says, zipped as MAME's loader expects.
  guest "cat > /opt/dragon32/roms/d32.rom && chmod 644 /opt/dragon32/roms/d32.rom" <"$ROM"
  guest "set -e
    cd /opt/dragon32/roms
    dd if=d32.rom of=$ROM_HALF0_NAME bs=8192 count=1 status=none
    dd if=d32.rom of=$ROM_HALF1_NAME bs=8192 skip=1 count=1 status=none
    echo '$ROM_HALF0_SHA1  $ROM_HALF0_NAME' | sha1sum -c - >/dev/null
    echo '$ROM_HALF1_SHA1  $ROM_HALF1_NAME' | sha1sum -c - >/dev/null
    python3 -c \"import zipfile
z = zipfile.ZipFile('dragon32.zip', 'w', zipfile.ZIP_DEFLATED)
z.write('$ROM_HALF0_NAME')
z.write('$ROM_HALF1_NAME')
z.close()\"
    [ -s dragon32.zip ]" ||
    die "could not assemble /opt/dragon32/roms/dragon32.zip from the staged blob
    (the two 8 KB halves must hash to the driver's own pins)"
  assert_rom_pin

  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
fi

# DO NOT prove the kiosk by restarting getty@tty1 in place. X is already running
# on vt1 from the base image's placeholder session; `systemctl restart
# getty@tty1` starts the new X on the NEXT free VT while the console keeps
# showing vt1, and the capture goes BLACK even though `pgrep dragon` is happy.
# The same shape bites the other way round: an X server started from an ssh
# session takes vt1's scanout but NOT its keyboard, so the exhibit looks perfect
# and every keystroke is silently discarded — that cost an hour here, and a
# key-pacing bisect reported a flawless 0 ms as passing before a deliberate
# negative control caught it. Cold-boot the whole VM instead; it is the state a
# visitor gets anyway.

# The cold boot with the quiet console in force, then bake THAT screen.
# Bake from a cold boot, never from a framebuffer that has carried verification
# output: the mpf2 add shipped a golden with two prompts stacked on it and had
# to re-bake.
stop_qemu
boot_tile
sleep 8
wait_for_basic ready-before-golden
guest "pgrep -x dragon >/dev/null" || die "MAME exited after the cold boot"
assert_rom_pin

bake_golden
sleep 3
wait_for_basic golden-restored
keyboard_proof

log "PASS: Dragon 32 Microsoft BASIC banner (OCR-verified), keyboard path, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
