#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/zx81.sh — build the Sinclair ZX81 (1981) streamhost station as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running a purpose-built MAME `zx81`
#         emulating a 1 KB ZX81 with the second-revision (`-bios 2nd`) ROM,
#         resting at the machine's own untouched power-on screen. streamhost
#         captures the Linux framebuffer + AC97 audio exactly like every other
#         kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE FIXTURE, AND WHY IT IS ALMOST NOTHING ------------------------------
#   A ZX81 that has just been switched on shows a WHITE field with one inverse
#   `K` in the bottom-left corner and nothing else. That is the whole screen —
#   no banner, no memory count, no copyright line. `K` means the machine is in
#   keyword mode: the next key pressed is not a letter but a whole BASIC
#   keyword (P prints PRINT). This is the fixture, untouched, because it is the
#   state the machine itself chose. (Plus/4 lesson: an earlier Plus/4 golden
#   rested inside its ROM office suite and had to be re-baked, because a
#   visitor arrived in the middle of an application with no idea how to leave.)
#
# ---- THE READINESS TRAP THIS MACHINE SETS -----------------------------------
#   Every other bridge builder gates readiness on "enough bright pixels"
#   (vic20: >100k bright px) or "enough ink" (pdp11: >12k green px). BOTH ARE
#   WRONG HERE, in opposite directions:
#     * bright-pixel test: a ZX81 that has crashed, been cleared, or is BLANKING
#       ITS DISPLAY WHILE IT COMPUTES (the machine's most famous behaviour — in
#       FAST mode the ULA stops generating a picture and hands the whole CPU to
#       BASIC) still fills the root with white. The test passes on a screen that
#       is not the fixture, and would happily bake it.
#     * ink test: the fixture's total ink is ONE character cell. Any threshold
#       high enough to reject a black root rejects the real idle screen too.
#   So the predicate here is GEOMETRIC, not photometric, and has four parts —
#   see zx81-frame.py. In summary: the picture must be a white field; there
#   must be an inverse-video block of about one character cell in the bottom-
#   left cursor box; there must be essentially NO ink anywhere else; and two
#   captures 3 s apart must agree exactly (the ZX81's `K` cursor does not
#   blink, so a frame that moves is not this fixture).
#   Each clause was validated against the negative it exists for — a black X
#   root, a mid-compute blank, and a screen with a typed line on it — and the
#   builder RUNS those negatives itself (see validate_predicate below), so a
#   predicate that has silently rotted into "return 0" fails the build.
#
# ---- THE MAME BINARY --------------------------------------------------------
#   Built from PINNED upstream source (MAME 0.289, commit f34f0250 — the same
#   commit mpf2 pins) as SUBTARGET=zx81 in the TRIXIE chroot, by
#   scripts/build-guests/emulators/build-mame-zx81.sh. The host's packaged MAME is
#   0.276 and the suite's own package would be whatever it froze; neither is a pin
#   anybody chose. Building keeps ONE MAME provenance across the collection. Since
#   the 2026-08-10 migration guest and host are both Debian 13, so the chroot is
#   about reproducibility rather than the ABI gap it used to bridge.
#   Unlike mpf2 there is NO patch: `-listxml zx81` reports status="good", so
#   this driver never raises MAME's full-screen red "THIS SYSTEM DOESN'T WORK"
#   panel. That is asserted from the shipped binary's own -listxml below, and
#   then proved on the frame, because a headless probe never sees that panel.
#
# ---- THE ROMSET: ASSEMBLED BY SHA1, AGAINST THE SHIPPED BINARY --------------
#   `-verifyroms zx81` IS NOT A GATE and this builder does not use it: the
#   driver has five BIOS entries (1st/2nd/3rd rev. plus two third-party Forth
#   ROMs) and reports "bad" whenever any of them is absent, however perfect the
#   one that is pinned. Instead the builder asks the SHIPPED binary for the
#   (name, sha1) pair belonging to bios `2nd`, assembles zx81.zip with exactly
#   that member name, and asserts the sha1 of what it wrote.
#   `-bios 2nd` (zx81a.rom, 8 KB, sha1 7b143ee9…) is the ROM almost every ZX81
#   actually shipped with. `-bios 3rd` (zx81b.rom) could not be sourced from
#   any preservation set and is not pursued: it is a later, rarer revision.
#   COPYRIGHT: the 1986 Amstrad permission that covers MAME's Spectrum ROMs
#   does NOT extend here. Amstrad bought the Spectrum and QL rights only;
#   Nine Stations Networks Ltd wrote the ZX80/ZX81 ROM and still holds it. The
#   ROM is therefore PRESERVATION SOURCE: staged on the box, hash-recorded in
#   docs/lab/ASSETS-MANIFEST.md, streamed as pixels, never committed, never
#   served, and with no download affordance anywhere in the station.
#
# ---- 1 KB, ON PURPOSE -------------------------------------------------------
#   MAME's zx81 defaults to `-ramsize 16K` (the RAM pack). This station pins
#   `-ramsize 1K`: the machine as sold, with about 750 bytes for a program once
#   the system variables are up. The 16 KB pack — and the wobble that lost you
#   your program — belongs on the placard, not in the fixture.
#
# ---- X ROOT AND THE EMULATOR WINDOW -----------------------------------------
#   MAME runs FULLSCREEN with aspect correction on the bridge base's stock
#   1024x768 X root, like mpf2. The ZX81's raster is 384x311 at 50.65 Hz, which
#   is a PIXEL count, not a picture shape; MAME's aspect correction reconstructs
#   the 4:3 television image, and 1024x768 is exactly 4:3, so the picture fills
#   the captured frame edge to edge with no black surround. Do NOT force
#   `-resolution 384x311` (the mpf2 trap: a strip in the middle of a black root).
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the zx81
# station dir; refuses to run while streamhost@zx81 is active.
#
# Usage: zx81.sh [--force] [--skip-negatives] [-h]
# =============================================================================
set -euo pipefail

TILE=zx81
VMID=231
UDP=54128
SSH_PORT=5831
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/zx81
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
FRAME_PY="$TILE_DIR/zx81-frame.py"
TYPE_PY="$TILE_DIR/type-qmp.py"
# 768 MB, verified rather than assumed: the build asserts guest MemAvailable
# stays above 200 MB with X + MAME at the fixture, and fails if it does not.
MEM=768

# PRESERVATION SOURCE. Second-revision ZX81 ROM, 8 KB. Copyright Nine Stations
# Networks Ltd (NOT covered by the Amstrad Spectrum/QL permission). Hashes
# measured on the box 2026-08-09; the single-member extraction form is the
# archive.org trick documented in the ADD-NEW-OS playbook §3.1.
ROM=/data/assets-staging/zx81/zx81a.rom
ROM_URL="https://archive.org/download/MAME_0.224_ROMs_merged/zx81.zip/zx81a.rom"
ROM_SHA1=7b143ee964e9ada89d1f9e88f0bd48d919184cfc
ROM_SHA256=14ad84f4243efcd41587ff46ab932d11087043e8d455a1ed2a227b9657828dfa
MAME=/data/vms/streamhost/assets/zx81/mame/zx81

FORCE=0
SKIP_NEG=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    --skip-negatives)
      SKIP_NEG=1
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

log() { echo "[zx81 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[zx81] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=30 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Sinclair ZX81 (1981) kiosk launcher (kiosk).
# See scripts/build-guests/tiles/zx81.sh for the rationale behind every flag.
# 384x311 raster at 50.655 Hz drawn FULLSCREEN with aspect correction on the
# bridge base's stock 1024x768 root, which is exactly 4:3 — the shape of the
# television the machine was designed to be plugged into.
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
exec /opt/zx81/mame/zx81 zx81 \
  -bios 2nd \
  -ramsize 1K \
  -rompath /opt/zx81/roms \
  -inipath /opt/zx81 \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit:
# the ZX81's only other input was a cassette recorder). Redirecting startx's
# output to a file is safe for MAME — it is NOT safe for the VICE stations, whose
# emulator segfaults when stdout is not a terminal (docs/guests/vic20.md).
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (zx81 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit) and keep every byte of console/X-log text
# off the visible VT: the captured framebuffer IS the exhibit.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

# Two host-side sidecars, tracked in the repo next to the launcher rather than
# buried in a heredoc here, because both outlive the build and are the tools an
# operator reaches for when the station misbehaves:
#   zx81-frame.py  the readiness predicate (see the header: a photometric test
#                  cannot tell this machine's idle screen from its blank one).
#   type-qmp.py    a QMP typist with EXPLICIT hold/gap pacing. `labctl type` is
#                  not a fair test of a guest keyboard — it drives QMP with no
#                  pacing and drops characters while printing "ok" — so the
#                  proof owns its typist and types at the station's declared rate.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../streamhost/tiles/zx81" && pwd)"

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

# boot_tile [cold] — resume the golden when one exists, unless `cold` is asked
# for, in which case boot Linux from POST (what a bake must always start from).
boot_tile() {
  stop_qemu
  local LOADVM=""
  if [ "${1:-}" != "cold" ]; then
    qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  fi
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish)
  nohup qemu-system-x86_64 \
    -name streamhost-zx81 \
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

wait_for_ssh() {
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && return 0
    sleep 3
  done
  die "bridge SSH did not become ready on 127.0.0.1:$SSH_PORT"
}

capture() {
  local ppm="$EVIDENCE/$1.ppm"
  rm -f "$ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$1.png"
}

measure() { python3 "$FRAME_PY" "$EVIDENCE/$1.ppm"; }
is_idle() { python3 "$FRAME_PY" "$EVIDENCE/$1.ppm" --assert idle; }
ink_out_of() { measure "$1" | sed -n 's/.*ink_out=\([0-9]*\).*/\1/p'; }

# Readiness: the geometric predicate above, PLUS the stability clause. The K
# cursor does not blink, so two frames 3 s apart must measure identically; a
# frame that is still moving is a boot, a scroll or a computation, not this
# fixture.
wait_for_k_cursor() {
  local name=$1 a b
  for _ in $(seq 1 60); do
    if capture "$name" 2>/dev/null && is_idle "$name" >/dev/null 2>&1; then
      a=$(measure "$name" | grep -E '^ink_box')
      sleep 3
      capture "$name"
      b=$(measure "$name" | grep -E '^ink_box')
      if [ "$a" = "$b" ] && is_idle "$name" >/dev/null 2>&1; then
        log "ZX81 idle fixture: $(measure "$name" | tr '\n' ' ')"
        return 0
      fi
    fi
    sleep 3
  done
  capture "$name" 2>/dev/null || true
  measure "$name" 2>&1 || true
  is_idle "$name" || true
  die "no ZX81 K-cursor fixture after 180 s (last frame $EVIDENCE/$name.png)"
}

send_keys() { python3 "$TYPE_PY" "$QMP" "$HOLD_MS" "$GAP_MS" "$@"; }

# A freshly RESTORED VM SWALLOWS THE FIRST KEYSTROKES SENT TO IT — the playbook
# records this for kiosks and it was measured here: the first `p` after
# `loadvm golden` left the framebuffer completely untouched, and the identical
# key twenty seconds later put PRINT on the screen. The first version of the
# negative below reported PREDICATE BROKEN because of it, which is the wrong
# diagnosis of a real effect. So: warm the path with a key that cannot change
# the picture (SHIFT alone is a no-op on a ZX81 at rest), and let every typing
# step retry before it blames anything.
warm_keyboard() {
  send_keys shift shift
  sleep 2
}

# Press P until the emulated ZX81 visibly reacts, and echo the resulting ink.
# In keyword mode the first P enters PRINT whole; a repeat lands as a letter
# after it, so a retry only ever adds ink. Failure here is a KEYBOARD failure
# and says so — it is not evidence about the readiness predicate.
press_p_until_visible() {
  local name=$1 tries=${2:-6} n=0 ink=0
  while [ "$n" -lt "$tries" ]; do
    n=$((n + 1))
    send_keys p
    sleep 2
    capture "$name"
    ink=$(ink_out_of "$name")
    if [ "$ink" -gt 300 ]; then
      log "P reached the emulated ZX81 after $n press(es) (ink_out=$ink)"
      echo "$ink"
      return 0
    fi
  done
  die "the P key never reached the emulated ZX81 ($tries presses, ink_out=$ink)"
}

# ---- the negatives the predicate exists to reject ---------------------------
# A predicate nobody has seen fail is a predicate that cannot fail. Each of
# these is produced on the live station AFTER the bake and required to be
# REJECTED; then the fixture is restored and required to be accepted again.
validate_predicate() {
  local out
  # 1. No emulator at all. `getty@tty1` MUST be stopped first: the kiosk session
  #    is `exec startx` from an autologin shell, so killing MAME alone makes X
  #    exit, agetty respawn and the whole kiosk come back within a couple of
  #    seconds. The first version of this check did exactly that, and the frame
  #    it captured was a healthy K cursor — which the predicate rightly accepted
  #    and the check then reported as PREDICATE BROKEN. Stop the session, then
  #    kill the emulator by resolving /proc/<pid>/exe (never by name).
  guest "systemctl stop getty@tty1 || true
    for p in \$(pgrep -x zx81); do
      [ \"\$(readlink /proc/\$p/exe)\" = /opt/zx81/mame/zx81 ] && kill -9 \$p
    done" || true
  sleep 8
  capture negative-dead-emulator
  if out=$(is_idle negative-dead-emulator 2>&1); then
    die "PREDICATE BROKEN: a dead emulator on a bare X root was accepted ($out)"
  fi
  log "negative 1 (dead emulator, bare X root) correctly rejected: ${out#*: }"

  hmp "loadvm golden" >/dev/null
  sleep 4
  wait_for_k_cursor negative-recovered-1

  # 2. The machine's OTHER white screen. While a ZX81 computes it switches its
  #    display off — the ULA stops drawing and the picture becomes an empty
  #    field — and a cleared screen looks the same. This is the frame every
  #    bright-pixel predicate in the sibling builders would accept, because it
  #    is just as bright as the fixture. Reproducing it from the keyboard needs
  #    a whole typed-in program (in FAST mode the display comes back whenever
  #    BASIC waits for a key, which is exactly when a keystroke could make it),
  #    so the builder SYNTHESISES it instead, from the accepted fixture, by
  #    painting the cursor cell paper-white. That is what an empty field IS,
  #    and it isolates the one clause under test.
  python3 "$FRAME_PY" "$EVIDENCE/negative-recovered-1.ppm" \
    --whiteout "$EVIDENCE/negative-blank-field.ppm" >/dev/null
  pnmtopng "$EVIDENCE/negative-blank-field.ppm" >"$EVIDENCE/negative-blank-field.png"
  if out=$(is_idle negative-blank-field 2>&1); then
    die "PREDICATE BROKEN: an empty white field (display off / screen cleared) was accepted ($out)"
  fi
  log "negative 2 (blank field: display off while computing, or cleared) correctly rejected: ${out#*: }"

  # 3. A screen with something typed on it — the state a curated golden would
  #    have been baked in, and the one a visitor must never be dropped into.
  warm_keyboard
  press_p_until_visible negative-typed-line >/dev/null
  if out=$(is_idle negative-typed-line 2>&1); then
    die "PREDICATE BROKEN: a screen with the PRINT keyword typed on it was accepted ($out)"
  fi
  log "negative 3 (typed line on screen) correctly rejected: ${out#*: }"

  hmp "loadvm golden" >/dev/null
  sleep 4
  wait_for_k_cursor negative-recovered-3
}

# The keyboard proof runs AFTER the bake, against the restored fixture, so
# nothing it types can reach the golden. It walks the ZX81's most characteristic
# behaviour: in K mode ONE keypress enters a whole BASIC keyword.
keyboard_proof() {
  warm_keyboard
  local ink_out
  # PRINT is five characters at column 0 of the input line; the cursor box is
  # two and a half columns wide, so at least three of them land outside it.
  # Asserting only "the framebuffer changed" would pass on a crashed emulator.
  ink_out=$(press_p_until_visible keyboard-print-keyword)
  send_keys ret
  sleep 2
  capture keyboard-print-executed
  log "keyboard proof: K-mode P -> PRINT, NEWLINE -> executed (ink_out=$ink_out)"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# ---- preflight ---------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -x "$MAME" ] ||
  die "missing pinned ZX81 MAME binary: $MAME (build with scripts/build-guests/emulators/build-mame-zx81.sh)"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE" "$(dirname "$ROM")"

# Stage the ROM once, on the host, hash-gated. Never committed, never served.
if [ ! -s "$ROM" ] || [ "$(sha256sum "$ROM" | awk '{print $1}')" != "$ROM_SHA256" ]; then
  log "fetching the ZX81 second-revision ROM (one-shot, preservation source)"
  curl -4 -fsSL --max-time 300 -o "$ROM.tmp" "$ROM_URL" || die "could not fetch $ROM_URL"
  mv "$ROM.tmp" "$ROM"
fi
[ "$(sha256sum "$ROM" | awk '{print $1}')" = "$ROM_SHA256" ] ||
  die "staged ZX81 ROM sha256 mismatch (expected $ROM_SHA256)"
[ "$(sha1sum "$ROM" | awk '{print $1}')" = "$ROM_SHA1" ] ||
  die "staged ZX81 ROM sha1 mismatch (expected $ROM_SHA1)"
[ "$(stat -c %s "$ROM")" -eq 8192 ] || die "the ZX81 ROM is not 8 KB"
log "ZX81 ROM staged and hash-verified: $ROM"

install -m 755 "$SRC_DIR/zx81-frame.py" "$FRAME_PY"
install -m 755 "$SRC_DIR/type-qmp.py" "$TYPE_PY"
# Two emulated frames each way is the playbook's FLOOR (50.655 Hz => 19.74 ms).
# The shipped value is the one bisected on this station — see docs/guests/zx81.md.
HOLD_MS=${HOLD_MS:-80}
GAP_MS=${GAP_MS:-80}

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
  wait_for_ssh
  # The distro MAME package is installed for its SDL/X11 runtime libraries and
  # its shared data ONLY; its 0.251 binary is never launched, because the station
  # ships the pinned 0.289 subtarget built by build-mame-zx81.sh.
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1
    apt-get install -y mame zip >>/tmp/apt.log 2>&1
    install -d -m 755 /opt/zx81/roms /opt/zx81/mame" ||
    die "could not install the MAME runtime libraries into the overlay (guest /tmp/apt.log)"
  guest "cat > /opt/zx81/mame/zx81 && chmod 755 /opt/zx81/mame/zx81" <"$MAME"

  # Assemble the romset AGAINST THE SHIPPED BINARY, by sha1 and not by
  # filename: MAME renames rom members and moves parent/clone splits between
  # versions, so the only trustworthy source of the member name is the binary
  # that will load it. -verifyroms is deliberately NOT the gate (see header).
  log "assembling zx81.zip from the shipped binary's own -listxml"
  guest "set -e
    /opt/zx81/mame/zx81 -listxml zx81 > /tmp/zx81.xml
    python3 - <<'PY' > /tmp/zx81.rom.want
import re, sys
xml = open('/tmp/zx81.xml').read()
m = re.search(r'<machine name=\"zx81\".*?</machine>', xml, re.S)
if not m:
    sys.exit('the shipped binary does not know the zx81 driver')
body = m.group(0)
st = re.search(r'<driver status=\"([a-z]+)\"', body)
if not st or st.group(1) != 'good':
    sys.exit('zx81 driver status is %r, not good — MAME will raise its red '
             'THIS SYSTEM DOESN\'T WORK panel and the fixture is not shippable'
             % (st and st.group(1)))
r = re.search(r'<rom name=\"([^\"]+)\"[^>]*bios=\"2nd\"[^>]*sha1=\"([0-9a-f]{40})\"', body)
if not r:
    sys.exit('the shipped binary has no bios=2nd rom entry for zx81')
print(r.group(1), r.group(2))
PY
    read -r NAME WANT < /tmp/zx81.rom.want
    [ \"\$WANT\" = '$ROM_SHA1' ] ||
      { echo \"shipped MAME wants sha1 \$WANT for bios 2nd, staged ROM is $ROM_SHA1\" >&2; exit 1; }
    echo \"\$NAME\" > /tmp/zx81.rom.name" ||
    die "the shipped MAME binary does not accept the staged ZX81 ROM (see above)"
  ROM_MEMBER=$(guest "cat /tmp/zx81.rom.name")
  log "shipped MAME wants '$ROM_MEMBER' sha1 $ROM_SHA1 for -bios 2nd"
  guest "cat > /opt/zx81/roms/$ROM_MEMBER && cd /opt/zx81/roms &&
    [ \"\$(sha1sum $ROM_MEMBER | awk '{print \$1}')\" = '$ROM_SHA1' ] &&
    rm -f zx81.zip && zip -q -j zx81.zip $ROM_MEMBER &&
    [ \"\$(unzip -p zx81.zip $ROM_MEMBER | sha1sum | awk '{print \$1}')\" = '$ROM_SHA1' ] &&
    rm -f $ROM_MEMBER" <"$ROM" ||
    die "zx81.zip was not assembled with a sha1-correct $ROM_MEMBER"
  log "zx81.zip assembled and its member re-hashed inside the guest"

  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "for p in \$(pgrep -x zx81); do
      [ \"\$(readlink /proc/\$p/exe)\" = /opt/zx81/mame/zx81 ] && kill -9 \$p
    done
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_k_cursor cold-boot-k-cursor
fi

# One clean COLD boot with the quiet console in force, then bake the golden from
# the very state UI reset restores for ever after. Bake from an UNTOUCHED cold
# boot: the mpf2 add shipped a golden carrying its own verification output.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile cold
wait_for_ssh
sleep 6
wait_for_k_cursor ready-before-golden
guest "pgrep -x zx81 >/dev/null" || die "MAME exited after the cold boot"
guest "awk '/MemAvailable/ {print \"guest MemAvailable: \" \$2 \" kB\"}' /proc/meminfo"
guest "awk '/MemAvailable/ {exit !(\$2 > 200000)}' /proc/meminfo" ||
  die "guest MemAvailable fell below 200 MB at ${MEM} MB of RAM — raise MEM"

capture golden-frame
bake_golden
sleep 4
wait_for_k_cursor golden-restored

[ "$SKIP_NEG" -eq 1 ] || validate_predicate
keyboard_proof

hmp "loadvm golden" >/dev/null
sleep 4
wait_for_k_cursor golden-restored-after-keyboard

log "PASS: ZX81 at its own K-cursor power-on screen; golden baked, restored and"
log "      re-proved; readiness predicate validated against its negatives"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
