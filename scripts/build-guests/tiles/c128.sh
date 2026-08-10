#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/c128.sh — build the Commodore 128 (1985) streamhost tile as a
# thin overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running VICE `x128` emulating a PAL
#         Commodore 128 in its NATIVE 80-column mode, resting at the machine's
#         own untouched power-on screen, with the CP/M Plus system disk sitting
#         unbooted in drive 8.
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh +
#         an INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# ---- WHAT MAKES THIS EXHIBIT WORTH THE SLOT --------------------------------
#   The C128 is three machines in one case: native C128 mode driving the VDC's
#   80-column RGBI output, a hardware-faithful C64 mode, and CP/M 3.0 on a
#   second CPU, a Zilog Z80. No other tile in the lineup can tell the CP/M
#   story, and the exhibit is built around reaching it in one tap.
#
# ---- THE VDC IS A SECOND CANVAS, AND `-80col` IS THE ONLY WAY TO SEE IT -----
#   In VICE's SDL2 build the VDC (80-column) output is a SEPARATE canvas from
#   the VIC-II. `-dualwindow` and `+hidevdcwindow` are TRAPS here: there is no
#   window manager in the kiosk, so the second SDL window never becomes visible
#   and a capture taken with either flag shows only the VIC-II.
#
#   `-80col` is the answer. It sets C128ColumnKey=0; x128_ui.c then makes the
#   VDC the ACTIVE canvas, and with DualWindow off (the default) every canvas
#   shares ONE SDL container — a single X window showing 80 columns. The same
#   flag also chooses which display the machine BOOTS into, so one flag sets
#   both the idle screen and the visible chip. NEVER use -dualwindow in a tile.
#
# ---- WINDOW vs X ROOT: MEASURED, NOT GUESSED --------------------------------
#   VICE's SDL window is a fixed size and cannot grow, and with no window
#   manager a window larger than the X root is silently CLIPPED and
#   mispositioned. Measured in the guest with xwininfo (2026-08-09):
#
#     x128 -80col -VDCdsize   ->  window 1578x1152 at +171,-36
#         * on a 1024x768 root: badly clipped (top-left corner only visible)
#         * on a 1920x1080 root: STILL clipped — 1152 > 1080, y offset -36 —
#           and it leaves ~45% of the root black. "It fits at 1920x1080" is
#           what recon reported; xwininfo says otherwise. Measure the window.
#     x128 -80col (no doubling) -> window 789x576
#         * on an 800x600 root: fills it edge to edge with an 11x24 px margin,
#           and every VDC pixel is 1:1 (80 columns * 8 px = 640 px of text
#           plus border), so the 80-column text is CRISP rather than resampled.
#
#   So this tile drops the doubling flag and keeps the 800x600 root its VICE
#   siblings (c64, vic20, plus4) use. Doubling would have cost a 1600x1200
#   capture — four times the pixels of every other bridge tile — to gain
#   nothing but bigger blocks.
#
# ---- THE CP/M DISK, AND WHY IT IS NOT ON THE COMMAND LINE -------------------
#   VICE bundles every C128 ROM (BASIC lo/hi, KERNAL, the editor, the Z80 BIOS,
#   chargen, and the C64-mode pair) but NOT the CP/M system DISK, which is
#   ordinary distributed media. It is fetched once, hash-pinned, and staged
#   INSIDE the guest at /opt/bridge/media/c128/cpm.d64 — the same in-guest
#   media convention c64.sh and amiga.sh use.
#
#   IT IS DELIBERATELY *NOT* PASSED AS `-8 <path>`. The C128's KERNAL reads the
#   boot sector of drive 8 at every reset, so a CP/M disk present at power-on
#   AUTOBOOTS: measured here first time out, the tile came up mid-way through
#   "BOOTING CP/M PLUS" and never showed BASIC at all. That would have baked a
#   golden the assignment explicitly rules out and, worse, a machine whose
#   power-on screen is an application.
#
#   Instead the kiosk attaches the disk ~10 s AFTER VICE's remote monitor
#   starts listening — i.e. long after the C128 has passed its boot check and
#   settled at READY. The helper /usr/local/bin/c128-attach-cpm.sh speaks the
#   VICE text monitor on 127.0.0.1:6510 (`attach "<d64>" 8`, then `x` to resume)
#   and is guest-local; nothing outside the guest can reach that port. Cold boot
#   and `loadvm golden` therefore reach the SAME state: BASIC V7.0 at READY with
#   CP/M in the drive, waiting to be asked for.
#
# ---- THE FIXTURE ------------------------------------------------------------
#   The golden is the machine's own untouched 80-column power-on screen:
#     COMMODORE BASIC V7.0 122365 BYTES FREE
#     (C)1986 COMMODORE ELECTRONICS, LTD.
#     (C)1977 MICROSOFT CORP.
#      ALL RIGHTS RESERVED
#     READY.
#   Nothing is typed into it. This is the plus4 lesson applied before the
#   mistake rather than after it: an earlier Plus/4 golden rested inside its ROM
#   office suite and had to be re-baked because a visitor arrived in the middle
#   of an application with no idea what it was or how to leave. The affordances
#   belong in the exhibit UI around an honest idle screen — here, the SPA's
#   c128 on-screen keyboard carries a CP/M button that types BOOT + RETURN.
#
# ---- WHAT DOES *NOT* SHIP: A C64 BUTTON -------------------------------------
#   GO64 works, and it is invisible. Measured after the bake (2026-08-09):
#   `GO64` RETURN `Y` RETURN switches the machine to C64 mode, which paints on
#   the VIC-II — but with -80col the VISIBLE canvas is the VDC, which C64 mode
#   stops updating. Two screendumps 10 s apart were BYTE-IDENTICAL, while the
#   control (the live BASIC prompt, same interval) alternates between exactly
#   two hashes as the cursor blinks. So the frozen frame is the VDC going dead,
#   not a keystroke that failed to land. A C64 button would hand the visitor a
#   dead screen with no way back, so it is not shipped. Recording the
#   measurement is the point: the sequence is fine, the display is not.
#
# ---- TWO TRAPS INHERITED FROM THE VIC-20 AND PLUS/4 ADDS (both handled) -----
#   * VICE 3.9 SEGFAULTS whenever its stdout is not a terminal (vice_banner() ->
#     strlen(NULL)) and prints nothing at all. The kiosk profile therefore
#     leaves stdout on tty1. See docs/guests/vic20.md for the backtrace.
#   * VICE's `make install` SKIPS ROM data files; the emulator then segfaults on
#     startup with no output. Repair the C128 set from the retained source tree
#     and ASSERT it, rather than trusting the copy. (On this frozen base the
#     C128 tree happens to be complete — the assertion is what proves that,
#     and it is exactly the assertion c64/vic20 wished they had had.)
#
# ---- KEY PACING -------------------------------------------------------------
#   SH_KEY_MIN_HOLD_MS=80 / SH_KEY_MIN_GAP_MS=80 — four PAL frames each way,
#   BISECTED on this box for vic20 (scripts/dev/emu-key-pacing-bisect.py:
#   40/40 corrupted 1 line in 22, 80/80 none in 22). Same emulator, same 50 Hz
#   frame, same host. The 2-frame figure in the playbook is a floor, not an
#   answer.
#
# ---- MEMORY -----------------------------------------------------------------
#   768 MB, not the 1536 vic20/plus4 use, and verified rather than assumed:
#   with x128 running at the fixture the guest reports MemAvailable ~385 MB of
#   725 MB total (x128 RSS ~178 MB). The build asserts >200 MB and fails if a
#   future VICE grows past it.
#
# HYGIENE: thin overlay (no full copy), namespaced qmp.sock/pidfile, kills only
# by pidfile, idempotent, --force rebuilds the overlay. Touches ONLY the c128
# tile dir; refuses to run while streamhost@c128 is active.
#
# Usage: c128.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=c128
VMID=223
UDP=54087
SSH_PORT=5823
WEB_PORT=8123
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/c128
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEDIA_DIR="$TILE_DIR/media"
MEM=768

# CP/M 3.0 system disk — the ONE external file this tile needs, from a SINGLE
# mirror (zimmers.net). Never committed; only the URL + both hashes are. $MEDIA_DIR
# keeps the host copy: that is the offline recovery path if zimmers.net ever dies.
CPM_URL="https://www.zimmers.net/anonftp/pub/cbm/demodisks/c128/cpm.system.6228151676.d64.gz"
CPM_GZ_SHA=6ed0da2d8a6fa74ae7b6e6cb67d78e1806a2a625ca839b4d93558c5ce7f44cb9
CPM_D64_SHA=69159226bf1996d8fc8c8921f094cd03955c7a8b9ecf800069d1c369dc6e5a1d
CPM_GUEST=/opt/bridge/media/c128/cpm.d64

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[c128 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[c128] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
push() {
  scp -q -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" "$1" root@127.0.0.1:"$2"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The kiosk launcher. No -VDCdsize (see the window measurement in the header),
# an 800x600 X root like every other VICE tile, and the CP/M disk attached out
# of band by the helper below so the KERNAL's boot-sector check at reset misses
# it. -remotemonitor exists only so that helper has something to talk to.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Commodore 128 (PAL, 80-column VDC) kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/c128.sh for the flag rationale — in particular why
# the CP/M disk is NOT on this command line (it would autoboot at reset).
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
/usr/local/bin/c128-attach-cpm.sh >/dev/null 2>&1 &
exec x128 \
  -sounddev alsa \
  -pal \
  -80col \
  -remotemonitor
EOS

# Attach the CP/M system disk to drive 8 AFTER the C128 has passed the
# boot-sector check its KERNAL runs at reset. The wait is anchored to VICE's
# OWN readiness (its monitor socket appearing) rather than to this shell's
# start, so a slow emulator start cannot race the attach in front of the reset.
# ss only READS the listen table — probing with a connection would itself drop
# VICE into the monitor and pause it.
#
# The log goes to /tmp, not /run: the kiosk session runs as the unprivileged
# `bridge` user and /run is root-owned, so the first version of this helper
# ATTACHED THE DISK CORRECTLY and then died on the redirect, leaving the build's
# assertion looking at a file that could never exist. A proof channel the prover
# cannot write to reports failure for a run that succeeded.
read -r -d '' ATTACH <<'EOS' || true
#!/bin/bash
# Attach the CP/M Plus system disk to C128 drive 8, ~10 s after VICE is up.
# Deliberately late: the C128 KERNAL boots any CP/M disk it finds in drive 8 at
# reset, and this tile's fixture is the BASIC power-on screen.
D=/opt/bridge/media/c128/cpm.d64
LOG=/tmp/c128-attach.log
[ -s "$D" ] || {
  echo "missing $D" >"$LOG"
  exit 1
}
up=0
for _ in $(seq 1 180); do
  if ss -lntH "sport = :6510" | grep -q 6510; then
    up=1
    break
  fi
  sleep 1
done
[ "$up" -eq 1 ] || {
  echo "VICE monitor never listened on 6510" >"$LOG"
  exit 1
}
sleep 10
for _ in $(seq 1 30); do
  if exec 3<>/dev/tcp/127.0.0.1/6510; then
    printf 'attach "%s" 8\nx\n' "$D" >&3
    sleep 1
    exec 3<&- 3>&-
    echo "attached $D at $(date -Is)" >"$LOG"
    exit 0
  fi
  sleep 1
done
echo "could not reach the VICE monitor to attach $D" >"$LOG"
exit 1
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit).
#
# DO NOT REDIRECT startx's OUTPUT TO A FILE. VICE 3.9 SEGFAULTS AT STARTUP WITH
# NO OUTPUT WHENEVER ITS STDOUT IS NOT A TERMINAL: vice_banner() ->
# log_message(" ") -> log_helper() hands a NULL string to log_archdep(), and
# strlen(NULL) kills it before the emulator prints a single byte (gdb
# backtrace, 2026-08-08, docs/guests/vic20.md). The visible symptom is X dying a
# second after it starts and getty@tty1 looping into start-limit-hit — nothing
# whatsoever points at VICE.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (c128 overlay). Start X with NO core pointer cursor
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

# bridge-base.sh records the trap this guards: VICE's `make install` SKIPS some
# ROM data files and the emulator then SEGFAULTS on startup with NO output at
# all (it bit the C64 tile on the BASIC ROM and the VIC-20 on basic-901486-01).
# Repair the C128 set from the source tree the base retains, and ASSERT every
# ROM a PAL C128 actually needs — including the C64-mode pair (GO64 uses them)
# and the two drive ROMs, since CP/M is booted from an emulated 1541/1571.
repair_c128_roms() {
  # shellcheck disable=SC2016 # $src/$r are the GUEST shell's variables, by design
  guest 'set -e
    src=/usr/local/src/vice-3.9/data/C128
    [ -d "$src" ] || { echo "VICE source data tree missing: $src" >&2; exit 1; }
    install -d -m 755 /usr/local/share/vice/C128
    cp -n "$src"/*.bin /usr/local/share/vice/C128/ 2>/dev/null || true
    cp -n "$src"/*.vpl /usr/local/share/vice/C128/ 2>/dev/null || true
    install -d -m 755 /usr/local/share/vice/DRIVES
    cp -n /usr/local/src/vice-3.9/data/DRIVES/*.bin /usr/local/share/vice/DRIVES/ 2>/dev/null || true
    for r in basiclo-318018-04.bin basichi-318019-04.bin kernal-318020-05.bin \
             chargen-390059-01.bin basic64-901226-01.bin kernal64-901227-03.bin; do
      [ -s "/usr/local/share/vice/C128/$r" ] || { echo "missing C128 ROM: $r" >&2; exit 1; }
    done
    for r in "dos1541-325302-01+901229-05.bin" dos1571-310654-05.bin; do
      [ -s "/usr/local/share/vice/DRIVES/$r" ] || { echo "missing DRIVE ROM: $r" >&2; exit 1; }
    done' ||
    die "could not complete the C128 ROM set in the guest"
  log "C128 ROM set complete (BASIC lo/hi + KERNAL + chargen + C64 pair + 1541/1571)"
}

# Fetch the CP/M system disk once, verify BOTH published hashes on the host,
# push it into the guest, and verify the hash again in-guest. Three chances to
# fail; a silent corruption cannot reach the golden.
stage_cpm_disk() {
  mkdir -p "$MEDIA_DIR"
  local gz="$MEDIA_DIR/cpm.d64.gz" d64="$MEDIA_DIR/cpm.d64"
  if [ ! -s "$d64" ] || [ "$(sha256sum "$d64" | awk '{print $1}')" != "$CPM_D64_SHA" ]; then
    log "fetching the CP/M 3.0 system disk"
    curl -fsSL -o "$gz" "$CPM_URL" || die "could not fetch $CPM_URL"
    [ "$(sha256sum "$gz" | awk '{print $1}')" = "$CPM_GZ_SHA" ] ||
      die "cpm.system…d64.gz sha256 mismatch (expected $CPM_GZ_SHA)"
    gunzip -cf "$gz" >"$d64"
  fi
  [ "$(sha256sum "$d64" | awk '{print $1}')" = "$CPM_D64_SHA" ] ||
    die "cpm.d64 sha256 mismatch (expected $CPM_D64_SHA)"
  [ "$(stat -c %s "$d64")" -eq 174848 ] || die "cpm.d64 is not a 35-track .d64"
  guest "install -d -m 755 /opt/bridge/media/c128"
  push "$d64" "$CPM_GUEST"
  guest "[ \"\$(sha256sum $CPM_GUEST | awk '{print \$1}')\" = $CPM_D64_SHA ]" ||
    die "cpm.d64 hash differs INSIDE the guest after transfer"
  log "CP/M 3.0 system disk staged in-guest at $CPM_GUEST (sha256 verified)"
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
    -name streamhost-c128 \
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

# Colour is the discriminator on this machine, so the readiness predicates are
# colour predicates and each one can fail in a way the others cannot.
#   * The VDC's native C128 palette paints BASIC in CYAN on black. Measured on
#     the fixture: 3860-3964 cyan pixels out of 480000 (the banner + READY).
#     A bare X root, a dead x128 and the Linux console (grey text: r,g,b all
#     high, so r<96 rejects it) all score 0.
#   * CP/M Plus paints in MAGENTA — 1983 pixels on its A> screen and ZERO cyan.
#     Requiring magenta==0 is what stops "ready" from accepting a machine that
#     has autobooted CP/M, which is exactly the failure this tile hit first
#     time out.
cyan_px() {
  ppmhist "$1" 2>/dev/null |
    awk '$1 < 96 && $2 > 96 && $3 > 96 { sum += $5 } END { print sum + 0 }'
}
magenta_px() {
  ppmhist "$1" 2>/dev/null |
    awk '$1 > 96 && $2 < 96 && $3 > 96 { sum += $5 } END { print sum + 0 }'
}
C128_MIN_CYAN=${C128_MIN_CYAN:-2500}
wait_for_basic80() {
  local name=$1 cyan magenta
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      cyan=$(cyan_px "$EVIDENCE/$name.ppm")
      magenta=$(magenta_px "$EVIDENCE/$name.ppm")
      if [ "$cyan" -gt "$C128_MIN_CYAN" ] && [ "$magenta" -lt 100 ]; then
        log "80-column BASIC ready (cyan=$cyan magenta=$magenta)"
        return 0
      fi
    fi
    sleep 2
  done
  die "no C128 80-column BASIC framebuffer after 180 seconds"
}

# Type through QMP at the tile's PRODUCTION pacing (80 ms hold, 80 ms gap =
# four PAL frames each way), so the proof exercises what the SPA does.
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

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# The exhibit's whole claim, proven AFTER the bake against the RESTORED fixture
# so nothing typed here can ever reach the golden: the CP/M button types BOOT
# and RETURN, and CP/M 3.0 comes up on the Z80.
#
# The assertion is not "the framebuffer changed" — that would pass on a syntax
# error. CP/M Plus paints MAGENTA and native BASIC paints CYAN, so requiring
# a magenta screen with essentially no cyan left can only be satisfied by the
# CP/M banner actually being on the glass.
#
# It is SLOW, and that is the machine, not the rig: booting CP/M Plus off an
# emulated 1541 took ~85 s wall-clock, measured. Allow three minutes.
cpm_proof() {
  local k cyan magenta
  : >"$EVIDENCE/keyboard-qmp.jsonl"
  for k in b o o t ret; do send_key "$k"; done
  for _ in $(seq 1 60); do
    sleep 5
    capture keyboard-cpm-booted
    magenta=$(magenta_px "$EVIDENCE/keyboard-cpm-booted.ppm")
    cyan=$(cyan_px "$EVIDENCE/keyboard-cpm-booted.ppm")
    if [ "$magenta" -gt 800 ] && [ "$cyan" -lt 200 ]; then
      # Let the A> prompt finish painting before the evidence frame is kept:
      # the predicate is satisfied by the banner alone, and the first frame
      # that satisfies it can land a beat before CP/M writes its prompt.
      sleep 8
      capture keyboard-cpm-booted
      log "keyboard proof: BOOT + RETURN reached CP/M 3.0 (magenta=$magenta cyan=$cyan)"
      return 0
    fi
  done
  die "BOOT + RETURN did not reach CP/M (magenta=${magenta:-?} cyan=${cyan:-?})"
}

# GO64 is measured, not shipped. See the header: C64 mode paints the VIC-II
# while -80col leaves the VDC as the visible canvas, so the picture FREEZES.
# The control makes the proof falsifiable — a live VDC alternates between two
# frames as the cursor blinks, so "two identical frames 10 s apart" means the
# canvas is dead rather than the keystrokes having missed.
go64_measurement() {
  local live_a live_b dead_a dead_b k
  capture go64-control-a
  live_a=$(sha256sum "$EVIDENCE/go64-control-a.ppm" | awk '{print $1}')
  sleep 0.4
  capture go64-control-b
  live_b=$(sha256sum "$EVIDENCE/go64-control-b.ppm" | awk '{print $1}')
  [ "$live_a" != "$live_b" ] ||
    die "control failed: the live BASIC prompt did not change between frames, so a frozen frame proves nothing"
  for k in g o 6 4 ret; do send_key "$k"; done
  sleep 2
  for k in y ret; do send_key "$k"; done
  sleep 5
  capture go64-after
  dead_a=$(sha256sum "$EVIDENCE/go64-after.ppm" | awk '{print $1}')
  sleep 10
  capture go64-after-10s
  dead_b=$(sha256sum "$EVIDENCE/go64-after-10s.ppm" | awk '{print $1}')
  if [ "$dead_a" = "$dead_b" ]; then
    log "GO64 measurement: VDC canvas is FROZEN in C64 mode (two identical frames 10 s apart) — no C64 button ships"
  else
    log "GO64 measurement: the VDC still updates in C64 mode — RE-EVALUATE shipping a C64 button"
  fi
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE" "$MEDIA_DIR"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

wait_for_ssh() {
  log "waiting for bridge SSH"
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && return 0
    sleep 3
  done
  die "bridge SSH did not become ready"
}

# PROVISION ON EVERY RUN, not only when the overlay is new. Every step here is
# idempotent (cp -n, a fixed file body, a grep-guarded grub edit), and making it
# conditional is how a rerun silently keeps a stale kiosk: the second build run
# of this tile edited the attach helper and then ran against the OLD copy still
# in the overlay, and the failure it printed was about the new code.
boot_tile cold
wait_for_ssh
guest "command -v x128 >/dev/null" ||
  die "x128 missing from the bridge base (rebuild it with bridge-base.sh)"
repair_c128_roms
stage_cpm_disk
printf '%s\n' "$LAUNCH" |
  guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
printf '%s\n' "$ATTACH" |
  guest "cat > /usr/local/bin/c128-attach-cpm.sh &&
      chmod 755 /usr/local/bin/c128-attach-cpm.sh &&
      chown root:root /usr/local/bin/c128-attach-cpm.sh"
quiet_console
guest "pkill -u bridge x128 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
sleep 8
wait_for_basic80 cold-boot-basic80

# One clean cold boot with the quiet console in force, then bake the golden
# from the very state SPA reset will restore for ever after. NOTHING IS TYPED
# BEFORE THE BAKE: the fixture is the machine's own untouched power-on screen.
# `cold` is explicit: a rerun that let boot_tile pick up an existing golden
# would re-bake a restored snapshot instead of a genuine power-on.
stop_qemu
boot_tile cold
wait_for_ssh
wait_for_basic80 ready-before-golden
guest "pgrep -x x128 >/dev/null" || die "x128 exited after cold boot"

# The disk must be in the drive but NOT booted. Both halves are asserted: the
# helper's log proves the attach ran, and the ready predicate above already
# proved the screen is BASIC and not CP/M.
#
# POLL for it rather than checking once. The attach is deliberately anchored ~10 s
# behind VICE's own start, and /run is a tmpfs that a cold boot empties, so a
# single grep races the helper — it failed exactly that way on the first build
# run, at 36 s after boot, with the attach landing a second later.
attached=0
for _ in $(seq 1 40); do
  if guest "grep -q '^attached ' /tmp/c128-attach.log" 2>/dev/null; then
    attached=1
    break
  fi
  sleep 3
done
[ "$attached" -eq 1 ] ||
  die "the CP/M disk was not attached to drive 8 (see /tmp/c128-attach.log in the guest)"
log "CP/M disk attached to drive 8, unbooted: $(guest 'cat /tmp/c128-attach.log')"

# Memory verification (the tile runs 768 MB, half what its VICE siblings use).
MEMAVAIL_KB=$(guest "awk '/MemAvailable/ {print \$2}' /proc/meminfo")
log "guest MemAvailable with x128 running: $((MEMAVAIL_KB / 1024)) MB of $(guest "awk '/MemTotal/ {print int(\$2/1024)}' /proc/meminfo") MB"
[ "$MEMAVAIL_KB" -gt 204800 ] ||
  die "guest MemAvailable is only $((MEMAVAIL_KB / 1024)) MB — raise MEM above $MEM"

capture ready-before-golden
bake_golden
sleep 3
wait_for_basic80 golden-restored

# Everything typed from here on happens AFTER the bake, against the restored
# fixture, so none of it can reach the golden.
go64_measurement
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_basic80 golden-restored-after-go64

cpm_proof
hmp "loadvm golden" >/dev/null
sleep 3
wait_for_basic80 golden-restored-after-keyboard

log "PASS: C128 80-column power-on fixture, CP/M route proven, quiet console, golden"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT mem=${MEM}M evidence=$EVIDENCE"
