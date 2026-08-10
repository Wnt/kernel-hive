#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/zxspectrum.sh — build the Sinclair ZX Spectrum 48K (1982)
# streamhost tile as a thin overlay on the frozen bridge base
# (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running MAME's `spectrum` driver, which
#         boots the 16 KB Sinclair ROM straight to its power-on screen —
#         "© 1982 Sinclair Research Ltd" in black on the machine's own white
#         paper. streamhost captures the Linux framebuffer + AC97 audio exactly
#         like every other bridge tile (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- THE ROM, AND WHY IT MAY BE FETCHED -------------------------------------
#   The 48K ROM ships in Debian's `spectrum-roms` package (non-free section),
#   whose usr/share/doc/spectrum-roms/copyright quotes Cliff Lawson of Amstrad
#   plc verbatim: "Amstrad are happy for emulator writers to include images of
#   our copyrighted code as long as the (c)opyright messages are not altered".
#   The conditions are that nobody charges for the ROM code and that it is used
#   with an emulator, not real hardware — both of which this exhibit satisfies,
#   and the first of which the exhibit itself honours: the idle screen IS the
#   unaltered copyright message. Class: freely-fetchable-pinned.
#   The BITS ARE NEVER COMMITTED — only the URL, size and hashes, as a row in
#   docs/lab/ASSETS-MANIFEST.md and scripts/build-guests/check-assets.sh.
#
#   `48.rom` from that package is byte-identical to MAME's `spectrum.rom`
#   (sha1 5ea7c2b8…), which is what makes the two fit together with no patching.
#
# ---- WHY `-verifyroms` IS NOT THE GATE --------------------------------------
#   `mame -verifyroms spectrum` reports "romset spectrum is bad" even with a
#   hash-perfect ROM, because the driver declares THIRTY-ONE alternative BIOS
#   entries (Spanish, prototype, DiagROM, third-party upgrades) and none of them
#   is staged. The gate here is therefore the sha1 of the exact BIOS entry the
#   tile pins (`-bios en`), read out of `mame -listxml spectrum` from THE BINARY
#   THAT IS SHIPPED, so a MAME upgrade that moved the ROM cannot pass silently.
#
# ---- WHICH MAME ------------------------------------------------------------
#   Debian 12's own `mame` 0.251+dfsg.1-1, installed with apt INSIDE the guest.
#   Unlike mpf2 — which needs a purpose-built 0.289 subtarget because its driver
#   is `preliminary` and MAME's red "THIS SYSTEM DOESN'T WORK" panel had to be
#   patched out — `spectrum` is `status="good"` in both 0.251 and the host's
#   0.276, so stock MAME shows no nag at all (verified by framebuffer, not by
#   reading the driver flags). Pinning the distro package keeps the emulator,
#   its SDL/X11 stack and the guest's glibc from one apt release.
#
# ---- THE EXHIBIT ------------------------------------------------------------
#   ZX Spectrum 48K: Z80A at 3.5 MHz, 16 KB ROM + 48 KB RAM, 256x192 pixels in
#   8 colours with one ink/paper pair per 8x8 cell (the famous attribute clash),
#   one-bit beeper, 40 rubber keys. No pointing device ever existed for it, so X
#   runs with -nocursor and the tile ships --pointer none --input-backend
#   disabled.
#
# ---- KEYBOARD: KEYWORD ENTRY IS THE MACHINE, NOT A BUG ----------------------
#   In 48K BASIC the cursor starts each line in K (keyword) mode, where ONE
#   keypress enters a whole token: `p` is PRINT, `b` is BORDER, `g` is GO TO,
#   `r` is RUN. After the token the cursor drops to L (letter) mode. A
#   character-by-character type-in of "10 print" therefore produces
#   "10 PRINTRINT". The registry demoProgram is written as the KEYSTROKES a
#   person actually presses on this machine, which is why its lines look short.
#
#   The other half is that the Spectrum's 40-key matrix has NO punctuation keys:
#   every symbol is SYMBOL SHIFT (host right shift) plus a letter, and the SPA's
#   typeText() only ever sends US scancodes with LEFT shift. So `"` `;` `,` `.`
#   `=` and friends are UNREACHABLE from a type-in and must come from the SPA's
#   zxspectrum on-screen keyboard, which carries CAPS SHIFT / SYMBOL SHIFT
#   latches and the symbol chords instead. MAME's `-natural` was measured as the
#   alternative and rejected: it does synthesise the SYMBOL SHIFT chords, but it
#   also merges REPEATED characters ("hello" arrived as "helo" at 150/150 ms and
#   needed 250/250 ms to survive), which is a worse exhibit than a missing quote.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the
# zxspectrum tile dir; refuses to run while streamhost@zxspectrum is active.
#
# Usage: zxspectrum.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=zxspectrum
VMID=230
UDP=54127
SSH_PORT=5830
WEB_PORT=8130
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/zxspectrum
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
# 768 MB is deliberate and is the smallest memory of any bridge tile: MAME's
# spectrum driver needs a few tens of megabytes, and the measured guest
# MemAvailable with the kiosk up is ~320 MB, comfortably over the 200 MB floor.
MEM=768

# Staged intake (docs/lab/ASSETS-MANIFEST.md). The .deb is the pinned artifact;
# 48.rom is extracted from it at build time and never stored on its own.
DEB=/data/assets-staging/zxspectrum/spectrum-roms_20081224-5_all.deb
DEB_URL=https://deb.debian.org/debian/pool/non-free/s/spectrum-roms/spectrum-roms_20081224-5_all.deb
DEB_SHA256=8d25dd300a0c86b4459e152de3bc657dca894b167e6a6419eb195d9669bfe950
ROM_MEMBER=./usr/share/spectrum-roms/48.rom
# MAME's pin for the `en` (English) BIOS of driver `spectrum`. Re-asserted
# against the shipped binary's own -listxml below; this constant only catches a
# corrupted intake before the guest is even booted.
ROM_SHA1=5ea7c2b824672e914525d1d5c419d71b84a426a2
MAME_PIN=0.251

# Production key pacing, also used by this script's own keyboard proof so the
# proof exercises exactly what the SPA will. Rationale in
# streamhost/tiles/zxspectrum/tile.env.fixture.
HOLD_MS=200
GAP_MS=200

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

log() { echo "[zxspectrum $(date +%H:%M:%S)] $*"; }
die() {
  echo "[zxspectrum] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# MAME runs FULLSCREEN on the bridge base's stock 1024x768 X root (set by
# ~/.xinitrc, like every sibling bridge tile) with aspect correction on. The
# Spectrum's raster is 352x296 INCLUDING its border; -keepaspect stretches that
# to the 4:3 shape a 1982 television drew, which fills a 1024x768 root exactly,
# with no letterboxing. Do NOT pass -resolution 352x296: that is the pixel
# count, not the picture's shape, and it strands a small strip in a black root
# (the mistake the MPF-II add made first).
#
# -noreadconfig: no mame.ini is ever written into the golden, so the emulator's
#   whole configuration is this argv and a rebuilt overlay is reproducible.
# -bios en: pin the English 1982 ROM against the driver's 31 other BIOS entries.
# -prescale 2: render at 2x then stretch, which keeps the 8x8 character cells
#   crisp under -nofilter.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Sinclair ZX Spectrum 48K (1982) ROM BASIC kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/zxspectrum.sh for the flag rationale.
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
exec /usr/games/mame spectrum \
  -rompath /opt/zxspectrum/roms \
  -noreadconfig \
  -bios en \
  -skip_gameinfo \
  -video soft \
  -prescale 2 \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (the Spectrum never had a
# pointing device, and the core pointer would otherwise sit frozen mid-screen),
# and no console or X-log text on the visible VT — the captured framebuffer IS
# the exhibit. Redirecting startx's stdout is safe here: that is the shape mpf2
# uses, and the VICE-only segfault documented in vic20.sh does not apply to MAME.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (zxspectrum overlay). Start X with NO core pointer
# cursor (-nocursor: keyboard-only exhibit) and keep every byte of console/X-log
# text off the visible VT.
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

# Assemble the romset BY SHA1, from the pinned .deb, and assert it against the
# BINARY BEING SHIPPED rather than against a constant in this file. MAME renames
# ROM files between versions and moves parent/clone splits, so the only durable
# identity is the hash the driver itself asks for.
install_romset() {
  local want_name want_sha1
  guest "install -d -m 755 /opt/zxspectrum/roms"
  dpkg-deb --fsys-tarfile "$DEB" | tar -xO "$ROM_MEMBER" |
    guest "cat > /opt/zxspectrum/roms/spectrum.rom && chmod 644 /opt/zxspectrum/roms/spectrum.rom"
  # What does THIS binary want for -bios en?
  want_name=$(guest "/usr/games/mame -listxml spectrum" |
    sed -n 's/.*<rom name="\([^"]*\)" bios="en".*/\1/p' | head -1)
  want_sha1=$(guest "/usr/games/mame -listxml spectrum" |
    sed -n 's/.*<rom name="[^"]*" bios="en".*sha1="\([0-9a-f]*\)".*/\1/p' | head -1)
  [ "$want_name" = "spectrum.rom" ] ||
    die "shipped MAME wants '$want_name' for -bios en, not spectrum.rom — re-derive the romset"
  [ "$want_sha1" = "$ROM_SHA1" ] ||
    die "shipped MAME wants sha1 $want_sha1 for -bios en; this builder pins $ROM_SHA1"
  guest "cd /opt/zxspectrum/roms &&
    [ \"\$(sha1sum spectrum.rom | cut -d' ' -f1)\" = '$ROM_SHA1' ] &&
    rm -f spectrum.zip && zip -q -j spectrum.zip spectrum.rom" ||
    die "staged 48.rom does not hash to the MAME 'en' BIOS pin"
  log "romset assembled: spectrum.zip <- 48.rom (sha1 $ROM_SHA1), verified against the shipped binary"
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
    -name streamhost-zxspectrum \
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

# READINESS PREDICATE. At power-on the Spectrum paints the WHOLE screen — border
# included — in its own white (RGB 205,205,205 out of MAME, i.e. non-bright
# white) and writes one line of black text at the bottom. So a ready frame is
# two things at once, and both must hold:
#   * an overwhelming majority of the 1024x768 root is that one grey (a bare X
#     root, a dead MAME, or a Linux console is black; a MAME warning panel is
#     red/orange), and
#   * there is a meaningful count of near-black pixels — the copyright line. A
#     screen that is uniformly grey with no text is the emulator having cleared
#     but not yet run the ROM, and must NOT be baked.
ZXS_MIN_PAPER=${ZXS_MIN_PAPER:-600000}
ZXS_MIN_INK=${ZXS_MIN_INK:-300}
wait_for_zxspectrum_boot() {
  local name=$1 paper ink
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      paper=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 > 190 && $1 < 220 && $2 > 190 && $2 < 220 && $3 > 190 && $3 < 220 { s += $5 } END { print s + 0 }')
      ink=$(ppmhist "$EVIDENCE/$name.ppm" 2>/dev/null |
        awk '$1 < 40 && $2 < 40 && $3 < 40 { s += $5 } END { print s + 0 }')
      if [ "$paper" -gt "$ZXS_MIN_PAPER" ] && [ "$ink" -gt "$ZXS_MIN_INK" ]; then
        log "ready: paper=$paper ink=$ink"
        return 0
      fi
    fi
    sleep 2
  done
  die "no ZX Spectrum power-on framebuffer after 180 seconds"
}

# Type one key through QMP with the tile's production pacing, using explicit
# press/release pairs. Never `send-key hold-time`: QEMU releases that on its own
# timer and back-to-back calls overlap, so the instrument loses characters
# before the guest does.
send_key() {
  local qcode=$1
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep "$(awk "BEGIN{print $HOLD_MS/1000}")"
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$qcode"
    sleep "$(awk "BEGIN{print $GAP_MS/1000}")"
  } | socat - UNIX-CONNECT:"$QMP" >>"$EVIDENCE/keyboard-qmp.jsonl"
}

# Prove the PS/2 keyboard path reaches the emulated Spectrum AND that keyword
# entry is what this machine really does: a single `b` at the K cursor must put
# the whole word BORDER on the screen. A changed framebuffer digest is the
# assertion (it makes no claim about glyph rendering); the accompanying PNG is
# what a human reads to see the token. Returns non-zero instead of dying, so the
# pre-bake gate below can retry.
keyboard_proof() {
  local base=$1 name=$2 k
  : >"$EVIDENCE/keyboard-qmp.jsonl"
  for k in 1 0 spc b 2; do send_key "$k"; done
  sleep 2
  capture "$name"
  [ "$(sha256sum "$EVIDENCE/$name.ppm" | awk '{print $1}')" != "$base" ]
}

# MAME soft reset (UI key F3), wrapped in the scroll-lock UI toggle because MAME
# disables its UI keys while emulating a full keyboard. On this machine the ROM
# enters at 0x0000 and re-runs NEW, so a soft reset genuinely re-draws the
# power-on screen — MEASURED: the framebuffer afterwards is BYTE-IDENTICAL to a
# cold boot's, which is what lets the keyboard be proved before the bake without
# leaving a fingerprint in the golden. (Contrast mpf2, where F3 is warm enough
# that the Apple-family ROM skips its banner entirely.)
mame_soft_reset() {
  send_key scroll_lock
  send_key f3
  send_key scroll_lock
  sleep 3
}

# THE READINESS PREDICATE THAT ACTUALLY MATTERS, and the reason this tile has one
# the other bridge builders do not.
#
# A kiosk MAME started at cold boot is SOMETIMES BORN DEAF: X delivers the key
# events to its window (proved with `xev -id <mame window>`: KeyPress/KeyRelease
# both arrive, focus is MAME's window, the guest's i8042 interrupt count rises),
# but MAME passes none of them to the emulated machine — not even its own UI
# menu on scroll_lock+Tab. Restarting the kiosk fixes it; a savevm/loadvm cycle
# does NOT cause it and does NOT cure it (both measured 2026-08-09: an instance
# proved live before `savevm` was still live after `loadvm`, and a deaf one
# stayed deaf across the same round trip). It is a start-up race in the SDL/X
# focus handshake, and it is invisible in every log.
#
# So a golden baked on a pixel-perfect but DEAF instance ships an exhibit whose
# reset button restores a machine nobody can type on — which is exactly what the
# first bake of this tile did. The gate is therefore behavioural: type, require
# the frame to change, soft-reset back to a byte-identical power-on screen, and
# only then let the caller bake. Restart the kiosk and retry if the frame did
# not move.
ensure_live_keyboard() {
  local attempt pristine
  for attempt in 1 2 3 4; do
    wait_for_zxspectrum_boot "pristine-attempt$attempt"
    guest "pgrep -x mame >/dev/null" || die "the ready frame is painted but MAME is gone"
    pristine=$(sha256sum "$EVIDENCE/pristine-attempt$attempt.ppm" | awk '{print $1}')
    if keyboard_proof "$pristine" keyboard-keyword-border; then
      mame_soft_reset
      wait_for_zxspectrum_boot ready-before-golden
      [ "$(sha256sum "$EVIDENCE/ready-before-golden.ppm" | awk '{print $1}')" = "$pristine" ] ||
        die "soft reset did not restore a byte-identical power-on screen; refusing to bake"
      log "keyboard is LIVE on this MAME instance (attempt $attempt) and the screen is pristine again"
      return 0
    fi
    log "attempt $attempt: MAME accepted no keys — restarting the kiosk and retrying"
    guest "pkill -u bridge -x mame 2>/dev/null || true
      sleep 2
      systemctl reset-failed getty@tty1
      systemctl restart getty@tty1"
    sleep 20
  done
  die "the kiosk MAME never accepted a keystroke; refusing to bake a deaf golden"
}

bake_golden() {
  # Replace any snapshot from an earlier run: the overlay is this build's own
  # disposable artifact, so deleting a tag here can never touch a live fixture.
  hmp "delvm golden" >/dev/null 2>&1 || true
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# Fetch the pinned .deb into the intake cache if it is not staged: download to a
# temporary name, verify the hash, then move it into place atomically, so an
# interrupted fetch can never be mistaken for a verified asset.
stage_rom_deb() {
  local tmp
  [ -s "$DEB" ] && return 0
  log "staging $DEB_URL"
  install -d -m 0750 "$(dirname "$DEB")"
  tmp="$DEB.part.$$"
  curl -fsSL -o "$tmp" "$DEB_URL" || {
    rm -f "$tmp"
    die "could not fetch $DEB_URL"
  }
  [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$DEB_SHA256" ] || {
    rm -f "$tmp"
    die "fetched spectrum-roms .deb does not match the pinned sha256"
  }
  mv "$tmp" "$DEB"
  sha256sum "$DEB" >"$(dirname "$DEB")/MANIFEST.sha256"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
stage_rom_deb
[ "$(sha256sum "$DEB" | awk '{print $1}')" = "$DEB_SHA256" ] ||
  die "staged spectrum-roms .deb does not match the pinned sha256"
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
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get -qq update
    apt-get install -y --no-install-recommends mame zip" ||
    die "could not install MAME in the guest"
  guest "/usr/games/mame -version | grep -q '^$MAME_PIN '" ||
    die "guest MAME is not the pinned $MAME_PIN (apt moved; re-verify the romset first)"
  log "MAME $MAME_PIN installed from Debian 12 ($(guest '/usr/games/mame -version'))"
  install_romset
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  guest "pkill -u bridge -x mame 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 6
  wait_for_zxspectrum_boot cold-boot-basic
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the very state SPA reset will restore for ever after. Bake from an UNTOUCHED
# cold boot: this is the screen the MACHINE chose, not a curated state inside an
# application — the Plus/4 add shipped a golden resting inside its spreadsheet
# and had to be re-baked because a visitor arrived mid-application with no idea
# what it was. Here the untouched screen is also the licence condition being
# honoured in public: "© 1982 Sinclair Research Ltd", unaltered.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
sleep 6
ensure_live_keyboard
GOLDEN_HASH=$(sha256sum "$EVIDENCE/ready-before-golden.ppm" | awk '{print $1}')
bake_golden
sleep 3
wait_for_zxspectrum_boot golden-restored
[ "$(sha256sum "$EVIDENCE/golden-restored.ppm" | awk '{print $1}')" = "$GOLDEN_HASH" ] ||
  die "the restored golden is not the frame that was baked"

# And prove the RESET PATH THE VISITOR USES: type into the freshly restored
# fixture, because "restores a picture" and "restores a machine you can type on"
# are different claims and this tile has already failed the second one once.
#
# GIVE THE RESTORE TIME TO SETTLE FIRST. Measured: keys sent ~4 s after `loadvm`
# were swallowed outright on an instance that was demonstrably live before the
# bake and demonstrably live again when the same sequence was repeated with an
# 8 s settle. MAME needs several seconds after a restore before it samples input
# again — a visitor never notices, an automated proof does. Three attempts, each
# from a fresh restore, so one slow resume cannot fail the build.
restored_keyboard=0
for attempt in 1 2 3; do
  sleep 8
  if keyboard_proof "$GOLDEN_HASH" keyboard-after-restore; then
    restored_keyboard=1
    break
  fi
  log "restored fixture ignored keys on attempt $attempt; restoring and retrying"
  hmp "loadvm golden" >/dev/null
done
[ "$restored_keyboard" -eq 1 ] ||
  die "the restored golden does not accept keys — do not ship this snapshot"
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_zxspectrum_boot golden-restored-after-keyboard
[ "$(sha256sum "$EVIDENCE/golden-restored-after-keyboard.ppm" | awk '{print $1}')" = "$GOLDEN_HASH" ] ||
  die "second restore did not return the untouched fixture"

log "PASS: ZX Spectrum power-on screen, keyword entry, quiet console, golden snapshot"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
