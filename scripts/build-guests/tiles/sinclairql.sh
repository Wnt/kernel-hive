#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/sinclairql.sh — build the Sinclair QL (1984) streamhost station as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running MAME's `ql` driver (68008 @ 7.5 MHz,
#         128 KB RAM, QDOS/SuperBASIC in ROM, two Microdrives). streamhost
#         captures the Linux framebuffer + AC97 audio like every other bridge
#         station (streamhost/docs/BRIDGE.md). Overlay + per-station
#         /etc/bridge/launch.sh + an INTERNAL `golden` snapshot (loadvm reset).
#
# Usage: sinclairql.sh [--force] [-h]
# ---- WHICH MAME ------------------------------------------------------------
#   The bridge guest's OWN Debian 12 package, pinned to mame 0.251+dfsg.1-1 and
#   asserted with dpkg-query. NOT the host's 0.276 (trixie glibc, will not run on
#   bookworm), and deliberately not a chroot-built subtarget like mpf2's 0.289:
#   that build exists for a warning-suppression patch this station replaces with one
#   keystroke, and `ql` is a status="good" driver.
#
# ---- THE ROMSET, ASSEMBLED BY SHA1 ------------------------------------------
#   Rebuilt in the guest from a preservation-source merged ql.zip keyed by SHA1
#   (MAME renames members between versions), reduced to the four the DEFAULT js
#   BIOS needs:
#     ql.js 0000.ic33 59fd4372771a630967ee102760f4652904d7d5fa  ql.js 8000.ic34
#     b8c9203026a7de6a44bd0942ec9343e8b222cb41  ipc8049.ic24
#     fcb1c97ee7c66e5b6d8fbb57c06fd2f6509f2e1b  bql010-sqpp
#     ba94bdad2303a263008b6ea744669a19938d9998
#   assert_romset re-derives that list from the SHIPPED BINARY's own -listxml and
#   compares sha1s. `-verifyroms ql` is NOT the gate: it calls a default-BIOS-only
#   set "bad" purely because the seven alternative BIOS entries are absent.
#
#   EXPECTED, NOT A FAILURE: every boot prints `hal16l8.ic38 NOT FOUND (NO GOOD
#   DUMP KNOWN)`. That PLD has never been dumped anywhere;
#   assert_expected_nodump_only asserts it is the ONLY complaint — and it is also
#   why MAME nags at startup.
#
# ---- THE TWO KEYSTROKES BEFORE THE GOLDEN -----------------------------------
#   A cold start shows two screens no visitor should meet: MAME's imperfect-dump
#   warning (from the nodump PLD; -skip_gameinfo does not suppress it and 0.251's
#   -skip_warnings does not reach this path — that is what mpf2's patch fixes),
#   then the QL's own `F1...monitor / F2...TV` chooser, which the real machine
#   insists on before drawing anything else. Both are answered here and the golden
#   is baked afterwards; the chooser frame is kept as evidence and is the poster.
#
#   "PRESS ANY KEY" DOES NOT MEAN ANY KEY (measured 2026-08-09): ret, spc and
#   esc leave the panel up, a plain letter clears it. The dismissal key is `x`,
#   sent only after the navy panel is asserted in the framebuffer — emulation
#   has not started then, and command_window_clean proves nothing was typed.
#
# ---- KEY PACING -------------------------------------------------------------
#   The ql screen runs at 50.08 Hz, so §5.1's two-frame floor is 40/40. Bisected
#   on a clone of this golden (scripts/dev/emu-key-pacing-bisect.py, table in
#   docs/guests/sinclairql.md); the station ships 120/120, slower than the VICE
#   stations' 80/80 because the QL's keyboard is scanned by a separate 8049 IPC and
#   shipped to the 68008 over a serial link — two sampling stages, not one.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent (--force rebuilds the overlay; without it an existing golden is
# re-proved, never re-baked). Touches ONLY the sinclairql station dir and refuses
# to run while streamhost@sinclairql is active.
# =============================================================================
set -euo pipefail

TILE=sinclairql
VMID=236
UDP=54133
SSH_PORT=5836
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/stations/sinclairql
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
# 768 MB: a Debian 12 kiosk, X, and one 68008. Verified, not assumed.
MEM=768
MEM_MIN_AVAIL_KB=200000
# The station's shipped SH_KEY_MIN_HOLD_MS / SH_KEY_MIN_GAP_MS, in seconds.
KEY_HOLD_S=0.12
KEY_GAP_S=0.12

# Preservation-source intake copy (docs/lab/ASSETS-MANIFEST.md row `sinclairql`).
ROMZIP=${SINCLAIRQL_ROMZIP:-/data/assets-staging/sinclairql/ql-mame0224-merged.zip}
ROMZIP_SHA256=c4c39530c7abe6518f90b0df9d4eec9201434a905c77f05f490137007e420b03
MAME_PKG_VERSION=0.251+dfsg.1-1

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,75p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[sinclairql $(date +%H:%M:%S)] $*"; }
die() {
  echo "[sinclairql] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# ---- LAUNCHER FLAGS: every one of these is a measurement ---------------------
# Numbers and the runs behind them: docs/guests/sinclairql.md.
#
# 1024x768 root, fullscreen, -keepaspect. The QL's 512x256 is a PIXEL count, not
#   the picture's shape (tall pixels on a 4:3 monitor), and this root is the
#   lucky one: exactly 2x across and 3x down, so every QL pixel is one identical
#   2x3 block. -prescale 2 was REMOVED — it prescales to 1024x512 then stretches
#   1.5x vertically, the one factor that makes the QL font uneven.
# -autoframeskip IS THE KEYBOARD FIX. The guest sees 50-60% CPU steal here;
#   `-video soft` alone ran the machine at 41.9% of realtime, turning an 80 ms
#   keypress into ~33 ms of EMULATED time (under two QL frames) and losing 4
#   keys in 20 typed SECONDS apart. Frameskip drops drawn frames, never emulated
#   ones: 103.4%, and the keyboard is scanned 50 times a second again.
# -video soft, not accel. accel is faster (101.9% with frameskip) and was
#   REJECTED: in this kiosk it ran for minutes with NO X window and a black
#   root. Do not "optimise" it back without a screenshot.
# -audio_latency 5 buys the deepest ALSA buffer MAME will ask for: a speed dip
#   starves the card, and the guest occasionally escalates from recoverable
#   underruns to `ALSA write failed (unrecoverable)`, on which MAME EXITS —
#   taking X with it and relaunching the whole kiosk every ~90 s.
# SDL_VIDEODRIVER=x11 IS LOAD-BEARING. Left to autodetect, SDL2 here twice chose
#   a driver that opened no window at all: MAME at 139% CPU, zero children of
#   the root, black exhibit. Pinned, as vic20 pins it; assert_emulator_window
#   makes a regression loud instead of black.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Sinclair QL (1984) QDOS/SuperBASIC kiosk launcher (kiosk).
# 512x256 monitor mode drawn at an exact 2x3 integer scale on the 1024x768 X
# root. See scripts/build-guests/tiles/sinclairql.sh for the flag rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_VIDEODRIVER=x11
export SDL_RENDER_DRIVER=software
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
exec /usr/games/mame ql \
  -rompath /opt/sinclairql/roms \
  -inipath /opt/sinclairql \
  -skip_gameinfo \
  -video soft \
  -autoframeskip \
  -audio_latency 5 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (the QL has no pointing
# device, so the core pointer would sit frozen mid-screen) and no console or
# X-log text on the visible VT. Redirecting startx's stdout is safe HERE
# because the emulator is MAME; the vic20/c64 stations must not do it (VICE 3.9
# segfaults when its stdout is not a tty).
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (sinclairql overlay). Start X with NO core pointer
# cursor (-nocursor: keyboard-only exhibit) and keep every byte of console and
# X-log text off the visible VT: the captured framebuffer IS the exhibit.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

# Quiet every text stage of a cold boot (GRUB -> kernel -> agetty).
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

# Install the pinned distro MAME and assemble /opt/sinclairql/roms/ql.zip BY
# SHA1 in the guest, so the bytes asserted are the bytes MAME opens.
install_mame_and_roms() {
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y mame x11-utils
    install -d -m 755 /opt/sinclairql/roms" ||
    die "could not install the pinned MAME package in the guest"
  local got
  got=$(guest "dpkg-query -W -f='\${Version}' mame")
  [ "$got" = "$MAME_PKG_VERSION" ] ||
    die "guest MAME is $got, tile pins $MAME_PKG_VERSION (re-pin deliberately and re-verify the romset)"
  guest "cat > /opt/sinclairql/merged-src.zip" <"$ROMZIP"
  guest "python3 - <<'PY'
import hashlib, zipfile
want = {
    '59fd4372771a630967ee102760f4652904d7d5fa': 'ql.js 0000.ic33',
    'b8c9203026a7de6a44bd0942ec9343e8b222cb41': 'ql.js 8000.ic34',
    'fcb1c97ee7c66e5b6d8fbb57c06fd2f6509f2e1b': 'ipc8049.ic24',
    'ba94bdad2303a263008b6ea744669a19938d9998': 'bql010-sqpp',
}
src = zipfile.ZipFile('/opt/sinclairql/merged-src.zip')
by_sha = {}
for info in src.infolist():
    data = src.read(info.filename)
    by_sha[hashlib.sha1(data).hexdigest()] = data
missing = [s for s in want if s not in by_sha]
if missing:
    raise SystemExit('merged source zip lacks sha1(s): ' + ' '.join(missing))
with zipfile.ZipFile('/opt/sinclairql/roms/ql.zip', 'w', zipfile.ZIP_DEFLATED) as out:
    for sha, name in sorted(want.items(), key=lambda kv: kv[1]):
        out.writestr(name, by_sha[sha])
print('assembled ql.zip with', len(want), 'members')
PY" || die "romset assembly by sha1 failed in the guest"
  guest "rm -f /opt/sinclairql/merged-src.zip"
}

# Gate on the sha1 of the entries the SHIPPED binary's own -listxml says the
# DEFAULT BIOS needs; catches a re-pin that renames, re-splits or re-defaults
# the set. `nodump` entries are skipped — they can never be satisfied.
assert_romset() {
  guest "python3 - <<'PY'
import hashlib, subprocess, sys, xml.etree.ElementTree as ET, zipfile
xml = subprocess.run(['/usr/games/mame', '-listxml', 'ql'],
                     capture_output=True, text=True, check=True).stdout
machine = [m for m in ET.fromstring(xml) if m.get('name') == 'ql'][0]
default = [b.get('name') for b in machine.findall('biosset') if b.get('default') == 'yes']
if default != ['js']:
    sys.exit('shipped MAME defaults to BIOS %r, tile pins js (v1.10)' % default)
need = {}
for rom in machine.findall('rom'):
    if rom.get('status') == 'nodump' or rom.get('sha1') is None:
        continue
    bios = rom.get('bios')
    if bios in (None, 'js'):
        need[rom.get('name')] = rom.get('sha1')
have = {}
with zipfile.ZipFile('/opt/sinclairql/roms/ql.zip') as z:
    for info in z.infolist():
        have[info.filename] = hashlib.sha1(z.read(info.filename)).hexdigest()
bad = [(n, s, have.get(n)) for n, s in need.items() if have.get(n) != s]
if bad:
    sys.exit('romset mismatch against the shipped binary: %r' % bad)
print('romset OK against shipped MAME: ' + ', '.join(sorted(need)))
PY" || die "the assembled romset does not match the shipped MAME's ql requirements"
}

# The nodump PLD must be the ONLY thing MAME cannot find: a second missing ROM
# would otherwise hide behind the expected line.
assert_expected_nodump_only() {
  guest "/usr/games/mame ql -rompath /opt/sinclairql/roms -inipath /opt/sinclairql \
      -video none -sound none -nothrottle -seconds_to_run 1 2>&1 |
    grep -E 'NOT FOUND|WRONG|INCORRECT' > /tmp/ql-romwarn.txt || true
    if [ -s /tmp/ql-romwarn.txt ]; then
      grep -qv 'hal16l8.ic38' /tmp/ql-romwarn.txt && {
        echo 'unexpected ROM complaint:' >&2; cat /tmp/ql-romwarn.txt >&2; exit 1; }
      grep -q 'hal16l8.ic38.*NO GOOD DUMP KNOWN' /tmp/ql-romwarn.txt ||
        { cat /tmp/ql-romwarn.txt >&2; exit 1; }
    fi" ||
    die "MAME reported a ROM problem other than the expected nodump hal16l8.ic38"
  log "ROM load clean apart from the expected nodump hal16l8.ic38 PLD"
}

# MAME alive is not MAME visible (see the SDL_VIDEODRIVER note above): the X
# window is a separate fact from the process.
assert_emulator_window() {
  # shellcheck disable=SC2016 # $(ls ...) must expand in the GUEST shell
  guest 'export DISPLAY=:0 XAUTHORITY=$(ls /tmp/serverauth.* 2>/dev/null | head -1)
    xwininfo -root -children 2>/dev/null | grep -q "MAME"' ||
    die "MAME has no X window (SDL video driver fell back?); the exhibit would be black"
  log "MAME owns an X window on the captured root"
}

assert_guest_memory() {
  local avail
  avail=$(guest "awk '/MemAvailable/ {print \$2}' /proc/meminfo")
  [ "$avail" -gt "$MEM_MIN_AVAIL_KB" ] ||
    die "guest MemAvailable ${avail}kB at ${MEM}MB is below the ${MEM_MIN_AVAIL_KB}kB floor"
  log "guest MemAvailable=${avail}kB with the emulator running (tile -m ${MEM})"
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

# boot_tile [build|production] — the two differ ONLY in the host-side audio
# BACKEND behind the same guest-visible AC97. `-audiodev dbus` hands its samples
# to whatever attaches to QEMU's D-Bus display: in production that is
# streamhost, which registers an audio listener at startup and drains
# continuously, but during a build nothing is attached and the guest's ALSA
# escalates to `ALSA write failed (unrecoverable)`, which KILLS MAME (X goes
# with it, getty relaunches the kiosk every ~90 s, and the builder keeps losing
# the machine it is baking). `-audiodev none` is a null sink with a real clock.
# No guest-visible device changes — but the playbook says prove that, so the
# builder bakes under `build`, then relaunches under `production` with
# -loadvm golden and re-asserts the fixture by framebuffer.
boot_tile() {
  local mode=${1:-production}
  stop_qemu
  local LOADVM="" AUDIODEV DISPLAY_ARG
  case "$mode" in
    # QEMU refuses `-display dbus,audiodev=` unless the audiodev is itself dbus
    # ("Audiodev 'snd0' is not compatible with DBus"), so build mode drops the
    # audiodev from the display too. The D-Bus display itself stays.
    build)
      AUDIODEV="none,id=snd0"
      DISPLAY_ARG="dbus,p2p=on"
      ;;
    production)
      AUDIODEV="dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16"
      DISPLAY_ARG="dbus,p2p=on,audiodev=snd0"
      ;;
    *) die "boot_tile: unknown mode $mode" ;;
  esac
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish)
  nohup qemu-system-x86_64 \
    -name streamhost-sinclairql \
    -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display "$DISPLAY_ARG" \
    -audiodev "$AUDIODEV" \
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

# Count pixels NEAR an RGB triple (per-channel tolerance, default 4). NOT an
# exact match: MAME's `accel` renderer writes the UI navy as 14,14,44 where
# `soft` gives 15,15,45, and an exact-triple predicate silently stopped seeing
# the warning screen when the launcher changed renderer. The tolerance is far
# below the distance between any two colours these screens use.
pixels_near() {
  local name=$1 r=$2 g=$3 b=$4 tol=${5:-4}
  ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
    awk -v r="$r" -v g="$g" -v b="$b" -v t="$tol" \
      '$1 ~ /^[0-9]+$/ && ($1-r)^2 <= t^2 && ($2-g)^2 <= t^2 && ($3-b)^2 <= t^2 \
        { sum += $5 } END { print sum + 0 }'
}

# Type one key through QMP at the station's SHIPPED pacing, so every keystroke the
# builder sends is the one the UI will send. Explicit press/release pairs, not
# `send-key hold-time`, which releases on QEMU's own timer and loses characters
# on overlapping calls (playbook §5.1).
send_key() {
  local qcode=$1
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep "$KEY_HOLD_S"
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep "$KEY_GAP_S"
  } | socat - UNIX-CONNECT:"$QMP" >>"$EVIDENCE/keyboard-qmp.jsonl"
}

# Three framebuffer signatures, measured on this station (ppmhist on the 1024x768
# root, 2026-08-09); a bare X root, a dead emulator and the QL's RAM-test
# confetti satisfy none of them:
#   warning  MAME's panel filled with UI navy 15,15,45          ~94700 px
#   chooser  QL green box round "F1...monitor" ~9980 px + red bar ~20100 px
#   monitor  QL window #2 white ~310000 px AND window #1 red ~302000 px
warning_is_up() { [ "$(pixels_near "$1" 15 15 45)" -gt 50000 ]; }
chooser_is_up() {
  [ "$(pixels_near "$1" 0 255 0)" -gt 5000 ] && [ "$(pixels_near "$1" 255 0 0)" -gt 10000 ]
}
monitor_is_up() {
  [ "$(pixels_near "$1" 255 255 255)" -gt 250000 ] &&
    [ "$(pixels_near "$1" 255 0 0)" -gt 250000 ]
}

# Poll one signature for up to `tries` * 2 seconds.
wait_for() {
  local pred=$1 name=$2 tries=$3
  for _ in $(seq 1 "$tries"); do
    if capture "$name" 2>/dev/null && "$pred" "$name"; then return 0; fi
    sleep 2
  done
  return 1
}

# Send a key until a signature appears. One injected key is NOT reliable here:
# the guest is a starved 2-vCPU VM on a box running 30+ emulators and a lone
# keystroke is occasionally never sampled (the run that produced this loop lost
# one `x` and one `f1`). Each attempt re-checks the framebuffer.
send_key_until() {
  local qcode=$1 pred=$2 name=$3 tries=$4 i
  for i in $(seq 1 "$tries"); do
    send_key "$qcode"
    sleep 3
    capture "$name" 2>/dev/null || continue
    if "$pred" "$name"; then
      [ "$i" -gt 1 ] && log "$qcode needed $i attempts (host contention)"
      return 0
    fi
  done
  return 1
}

# Nothing typed: the QL draws command-window text in GREEN, so a clean monitor
# screen has no green in it — which is what proves no dismissal keystroke
# leaked past MAME's warning into SuperBASIC. The threshold is half a glyph
# (one measures 96 lit pixels), not zero, because a renderer may leave a stray
# pixel on a window border but can never draw half a character.
command_window_clean() { [ "$(pixels_near "$1" 0 255 0)" -lt 48 ]; }

reach_monitor_mode() {
  wait_for warning_is_up mame-warning 90 ||
    die "MAME's imperfect-dump warning never appeared (is the emulator running at all?)"
  # A LETTER, not ret/spc/esc (see the header). Emulation has not started while
  # the warning is up, so this cannot reach the QL; command_window_clean below
  # proves that rather than assuming it. The QL then runs its RAM test, which
  # fills the screen with confetti for a few seconds before the chooser.
  send_key_until x chooser_is_up chooser 12 ||
    die "the QL chooser never appeared after dismissing MAME's warning"
  local before
  before=$(sha256sum "$EVIDENCE/chooser.ppm" | awk '{print $1}')
  send_key_until f1 monitor_is_up monitor-mode 12 ||
    die "F1 did not put the QL into monitor mode"
  [ "$before" != "$(sha256sum "$EVIDENCE/monitor-mode.ppm" | awk '{print $1}')" ] ||
    die "the monitor-mode frame is byte-identical to the chooser frame"
  command_window_clean monitor-mode ||
    die "the QL command window is not empty: a dismissal keystroke reached SuperBASIC"
  log "QL is in 80-column MONITOR mode (warning dismissed, F1 taken, nothing typed)"
}

# Prove the PS/2 -> X -> MAME -> QL keyboard path: type into SuperBASIC's
# command window (window #0, the black strip) and require the frame to change.
keyboard_proof() {
  local base_hash proof_hash k
  base_hash=$(sha256sum "$EVIDENCE/golden-restored.ppm" | awk '{print $1}')
  : >"$EVIDENCE/keyboard-qmp.jsonl"
  for k in p r i n t spc 7; do send_key "$k"; done
  sleep 3
  capture keyboard-print-7
  proof_hash=$(sha256sum "$EVIDENCE/keyboard-print-7.ppm" | awk '{print $1}')
  [ "$proof_hash" != "$base_hash" ] ||
    die "keyboard proof did not change the QL framebuffer"
  # NOT `command_window_clean … && die`: under `set -e` that idiom exits the
  # whole script, silently, on the branch where the assertion PASSES (it did).
  if command_window_clean keyboard-print-7; then
    die "typing left no green text in the QL command window"
  fi
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
[ -s "$ROMZIP" ] || die "missing staged QL romset: $ROMZIP (see docs/lab/ASSETS-MANIFEST.md)"
[ "$(sha256sum "$ROMZIP" | awk '{print $1}')" = "$ROMZIP_SHA256" ] ||
  die "staged QL romset SHA256 does not match the pin in this script"
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
  boot_tile build
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
  install_mame_and_roms
  assert_romset
  assert_expected_nodump_only
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge mame 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  reach_monitor_mode
fi
# BAKE, but only when there is no golden to protect. A re-run without --force
# must NOT cold-boot: the launcher enters an existing golden with -loadvm, the
# MAME warning screen it would wait for is long gone, and the only honest thing
# left to do is re-prove the fixture that is already there.
if qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  log "golden already present; re-proving it instead of re-baking (use --force to rebuild)"
else
  # One clean cold boot with the quiet console in force, then the two
  # dismissals, then bake. The screen baked here is the screen every visitor
  # sees for the life of the exhibit, so nothing else is typed before savevm:
  # mpf2 shipped a golden carrying its own verification output and had to be
  # re-baked.
  stop_qemu
  "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile # see lib/bridge-coldboot; this branch only runs when no golden exists yet
  boot_tile build
  sleep 8
  reach_monitor_mode
  guest "pgrep -x mame >/dev/null" || die "MAME exited before the golden bake"
  assert_emulator_window
  assert_guest_memory
  bake_golden
  sleep 3
  capture golden-restored
  monitor_is_up golden-restored || die "the restored golden is not the QL monitor screen"
  command_window_clean golden-restored ||
    die "the golden's command window is not empty; re-bake from a clean cold boot"
fi

# Now prove the golden under the PRODUCTION device set — same guest-visible
# devices, the real dbus audio backend, entered through -loadvm golden exactly
# as streamhost's launcher will enter it.
stop_qemu
boot_tile production
sleep 6
capture production-loadvm
monitor_is_up production-loadvm ||
  die "the golden does not restore under the production launcher's audio backend"
command_window_clean production-loadvm ||
  die "the production restore is not the clean fixture"

# Keyboard proof runs AFTER the bake, against the restored fixture, so nothing
# it types can ever reach the golden.
keyboard_proof
hmp "loadvm golden" >/dev/null
sleep 3
capture golden-restored-after-keyboard
monitor_is_up golden-restored-after-keyboard ||
  die "the golden did not restore cleanly after the keyboard proof"

log "PASS: QL in monitor mode, keyboard path, quiet console, golden snapshot"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
