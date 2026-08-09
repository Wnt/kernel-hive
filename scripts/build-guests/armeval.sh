#!/usr/bin/env bash
# =============================================================================
# build-guests/armeval.sh — build the Acorn ARM Evaluation System (1986)
# streamhost tile as a thin overlay on the frozen bridge base (bridge-base.sh).
#
# GUEST : a captured Debian-12 X kiosk running the SAME purpose-built MAME
#         `bbcb` the bbcmicro tile ships, but with the ARM second processor
#         fitted to the Tube: `bbcb -tube arm`. streamhost captures the Linux
#         framebuffer + AC97 audio exactly like every other bridge tile.
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# WHAT THE EXHIBIT IS. The ARM Evaluation System is the FIRST ARM PRODUCT EVER
# SOLD: an ARM1 on a podule board that hangs off a BBC Micro's Tube, sold to
# developers in 1986 so they could write ARM code before the Archimedes existed.
# It has no operating system of its own. What it has is a supervisor — a monitor
# in 16 KB of ROM that identifies itself, disassembles ARM instructions, dumps
# memory and dumps the registers of whatever just went wrong. So the exhibit is
# that supervisor, and the exhibit's whole point is that a visitor can make a
# 1986 ARM talk about itself.
#
# ---- THE GOLDEN IS THE MACHINE'S OWN UNTOUCHED POWER-ON SCREEN --------------
#   "ARM Second Processor 4096K / Acorn DFS / BASIC" and a blue `A*` supervisor
#   prompt, nothing typed. Same rule as bbcmicro and for the same reason (the
#   Plus/4 lesson): bake what the machine chose, not a curated screen.
#
#   THE BANNER IS THE ACCEPTANCE TEST'S FIRST CRITERION and it is easy to ship
#   the wrong one: with no `-tube arm` the identical driver prints "BBC Computer
#   32K" and a white `>` BASIC prompt, which is the bbcmicro tile — a
#   near-duplicate and worthless. Two independent bake-time gates catch that:
#   the frame must carry ~4 K BLUE pixels (the A* prompt's reverse-video field;
#   a plain BBC Micro banner has ZERO) and the OCR-free ink band below.
#
# ---- WHY `bbcb -tube arm`, NOT the `bbcmarm` driver -------------------------
#   MAME also has `bbcmarm`, a BBC MASTER with the same ARM podule. The Master
#   boots in MODE 7 and MAME's SAA5050 renders the supervisor prompt's blue
#   control code as mosaic blobs that read as screen corruption on a museum
#   wall. `bbcb -tube arm` renders the same prompt cleanly. Measured in recon
#   2026-08-09 by frame, on both drivers.
#
# ---- THE ROMS ---------------------------------------------------------------
#   Five of the six blobs are the bbcmicro tile's, unchanged and for the same
#   reasons (see build-guests/bbcmicro.sh for the full derivation: `saa5050` is
#   a third zip and MODE 7 has no glyphs without it; the Acorn 8271 disc
#   interface is the driver's own default and cannot simply be left out).
#   The SIXTH is the ARM Evaluation System's own bootstrap:
#     armeval_101.rom  f86bbc48…  Executive v1.00 (14th August 1986)
#   which is `bbc_tube_arm`'s DEFAULT biosset in 0.289 (four are offered:
#   101, 100, and the two earlier "Brazil" builds). 14 August 1986 is four
#   months after the first ARM1 silicon ran, and the firmware says so out loud
#   when a visitor types HELP.
#
#   All six are PRESERVATION-SOURCE WITH NO AUTHORISED URL and a genuinely
#   disputed chain of title, so this builder does NOT download them: it REQUIRES
#   them staged at $ROMDIR by the operator, gates each on its SHA-1, and lets
#   the SHIPPED BINARY's own -listxml name the zip members (the kim1/kc85_4
#   lesson — MAME renames members between versions, so the hash is the only
#   stable identity). Never commit the bits.
#
#   `-verifyroms` IS NOT USED AS A GATE: on BIOS-selectable drivers it reports
#   "bad" purely because the alternative BIOS entries are absent, which is the
#   whole point of a pinned set.
#
# ---- THE RED NAG SCREEN -----------------------------------------------------
#   `bbcb` is driver status "imperfect" (sound), NOT "preliminary", so MAME
#   never paints the full-screen red "THIS SYSTEM DOESN'T WORK" panel for it —
#   but it does raise the amber/red startup WARNINGS stage, which is a separate
#   stage from the game-info screen and which `-skip_gameinfo` does NOT
#   suppress. Fitting a tube co-processor does not change the driver's status
#   (device status is not driver status), so this tile inherits bbcmicro's
#   answer: the shipped binary carries the one-line skip_warnings patch and
#   /opt/armeval/ui.ini sets it. wait_for_banner() REJECTS a red-dominant frame
#   outright, so a binary rebuilt without the patch fails this script instead of
#   shipping a red panel to a museum wall.
#
# ---- THE VISITOR INTERACTION, AND THE ERROR PATH IT DELIBERATELY USES -------
#   Three keyboard actions, each proven by framebuffer against the RESTORED
#   fixture at the bottom of this script:
#     HELP           -> "Supervisor 1.00 / Executive version 1.00 (14th August
#                       1986) / DFS 1.20 / OS 1.20" — the firmware dating itself.
#     BASIC          -> the machine tries to enter the HOST's 6502 BASIC, the ARM
#                       is handed 6502 bytes, and the supervisor catches it:
#                       "Not ARM code / Entering Supervisor because of branch
#                       through 0 / Register dump (stored at &E40) is: R0 = … /
#                       Mode SVC flags set: nzcvif / Finished after 0.07 sec."
#     DIS 3000000    -> the supervisor's own ARM disassembler walking the
#                       bootstrap ROM: real ARM1 mnemonics (SUBS PC, STMDB, BIC,
#                       TEQCCP), paged with "Any key continue, Return finish".
#
#   BASIC IS AN ERROR PATH AND THE PLACARD SAYS SO. It is also measured to be
#   SAFE: the supervisor returns to the `A*` prompt and accepts the next command
#   (verified by typing at the prompt afterwards), so a visitor who presses it
#   does not need a reset. The placard frames it as what it is — a 1986 ARM
#   telling you what it just refused to execute — not as a feature.
#
#   THE DISASSEMBLER'S PAGER SWALLOWS THE NEXT KEYSTROKE. After `DIS` the
#   machine sits at "Any key continue, Return finish", so any further button a
#   visitor taps pages the listing instead of running. RETURN finishes it. The
#   proof below sends the RETURN, and the SPA row must too.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the armeval tile dir; refuses to
# run while streamhost@armeval is active.
#
# SANDBOX RUNS. There is deliberately NO env-var override for TILE_DIR here.
# `clone-guard check-launcher` refuses any script that can reach a production
# tile path through an unset variable — that parameter-default is the exact
# footgun that once killed a live tile (docs/lab/clone-guard.md) — so a bake-off
# or experiment run is made by REWRITING the three constants below into a
# /data/vms/soltest/<ns> copy, which then passes check-launcher on its own.
# That is how this tile's angle-B evaluation was run (docs/guests/armeval.md).
#
# Usage: armeval.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=armeval
VMID=235
UDP=54135
SSH_PORT=5835
WEB_PORT=8135
BRIDGE_BASE=/data/vms/bridge/bridge-base.qcow2
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/armeval
ROMDIR=/data/assets-staging/armeval
MAME=/data/vms/streamhost/assets/bbcmicro/mame/bbcb
# 768 MB, the same as bbcmicro: the same binary, the same X root, and one more
# 16 KB ROM. Asserted in-guest against the 200 MB MemAvailable floor below.
MEM=768

OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
TYPE_DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bbcmicro-type-qmp.py"

# Guest ROM name -> SHA1, asserted against the shipped binary's own -listxml
# before anything is copied into the guest.
ROM_SHA1_os12="0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d"
ROM_SHA1_basic2="4a7393f3a45ea309f744441c16723e2ef447a281"
ROM_SHA1_phroma="b369809275cb67dfd8a749265e91adb2d2558ae6"
ROM_SHA1_saa5050="6c8daba70374e5aa3a6402f24cdc5f8677d58a0f"
ROM_SHA1_dnfs120="7e3c536baeae84d6498a14e8405319e01ee78232"
ROM_SHA1_armeval101="f86bbc4894e62725b8ef22d44e7f44d37c98ac14"

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,110p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[armeval $(date +%H:%M:%S)] $*"; }
die() {
  echo "[armeval] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 -o ServerAliveInterval=30 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The launcher is bbcmicro's, verbatim, plus `-tube arm` and its own /opt dir.
# Every one of the odd-looking lines below is a measured bbcmicro fix and they
# all apply unchanged here — same emulator, same X server, same QEMU PS/2 path:
#   800x600 root  : -video soft is the only usable renderer under std-VGA
#                   capture, so the CPU bill scales with the ROOT's pixels;
#                   800x600 + -autoframeskip is what reaches ~99% of real speed,
#                   and SPEED IS AN INPUT PROPERTY (at half speed an 80/80 ms
#                   host pacing is 40/40 in emulated time and characters vanish).
#   xset r off    : X's synthetic auto-repeat duplicates the emulated keyboard's
#                   own repeat and injects bursts when MAME is busy.
#   nice -n 10    : the kernel's per-client evdev buffer is 64 events — 32
#                   characters — and MAME starving the X server overflows it,
#                   silently dropping the backlog. This is the one that mattered
#                   most on bbcmicro.
#   -artwork_crop : drops the driver's labelled keyboard-LED strip, which would
#                   otherwise sit under the picture as emulator chrome.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Acorn ARM Evaluation System (1986) kiosk launcher (bridge tile).
# MOS 1.20 + BBC BASIC II + Acorn DNFS 1.20 host, ARM1 second processor on the
# Tube with Executive v1.00 (14th August 1986). See build-guests/armeval.sh.
sleep 2
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
xset r off 2>/dev/null || true
exec nice -n 10 /opt/armeval/mame/bbcb bbcb -tube arm \
  -rompath /opt/armeval/roms \
  -inipath /opt/armeval \
  -skip_gameinfo \
  -artwork_crop \
  -video soft \
  -prescale 1 \
  -autoframeskip \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (armeval overlay). Start X with NO core pointer cursor
# and keep every byte of console/X-log text off the visible VT: the captured
# framebuffer IS the exhibit.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS

# Assemble the FOUR MAME zips from the operator-staged blobs, after the SHIPPED
# binary has been asked what it wants. `bbc_tube_arm` is the fourth set and it
# is a DEVICE, not a driver: it never appears without `-tube arm`, and MAME
# looks for it by that name in the rompath like any other device romset.
assemble_roms() {
  local r want got
  for r in os12:os12.rom basic2:basic2.rom phroma:phroma.bin saa5050:saa5050 \
    dnfs120:dnfs120.rom armeval101:armeval_101.rom; do
    [ -s "$ROMDIR/${r##*:}" ] ||
      die "missing staged ROM $ROMDIR/${r##*:} — see docs/guests/armeval.md (preservation-source, no authorised URL; the operator stages these six blobs)"
    eval "want=\$ROM_SHA1_${r%%:*}"
    got=$(sha1sum "$ROMDIR/${r##*:}" | awk '{print $1}')
    [ "$got" = "$want" ] || die "staged ${r##*:} sha1 $got != pinned $want"
  done
  # `-listxml bbcb` already carries every device the driver's slots can take,
  # `bbc_tube_arm` among them — it is a slot option of the Tube, so it does not
  # need (and does not have) a driver entry of its own.
  "$MAME" -listxml bbcb >"$TILE_DIR/listxml.xml" 2>/dev/null ||
    die "the shipped MAME could not list driver bbcb"
  rm -rf "$TILE_DIR/roms"
  mkdir -p "$TILE_DIR/roms"
  python3 - "$TILE_DIR/listxml.xml" "$ROMDIR" "$TILE_DIR/roms" \
    "$ROM_SHA1_os12" "$ROM_SHA1_basic2" "$ROM_SHA1_phroma" "$ROM_SHA1_saa5050" \
    "$ROM_SHA1_dnfs120" "$ROM_SHA1_armeval101" <<'PY' || die "the shipped MAME's romset does not match this tile's pins"
import hashlib, os, sys, xml.etree.ElementTree as ET, zipfile  # noqa: E401
path, romdir, outdir = sys.argv[1:4]
pins = set(sys.argv[4:10])
SETS = ("bbcb", "bbc_acorn8271", "saa5050", "bbc_tube_arm")
machines = {m.get("name"): m for m in ET.parse(path).getroot().findall("machine")}
for name in SETS:
    if name not in machines:
        raise SystemExit(name + " absent from -listxml")


def chosen_bios(m):
    """MAME's own rule: the biosset flagged default, else the FIRST one declared.
    bbcb flags none of its four; bbc_tube_arm DOES flag `101` (Executive v1.00,
    14th August 1986) — the one this exhibit is about."""
    sets = m.findall("biosset")
    if not sets:
        return None
    for b in sets:
        if b.get("default") == "yes":
            return b.get("name")
    return sets[0].get("name")


def wanted(m):
    bios = chosen_bios(m)
    return {(r.get("name"), r.get("sha1")) for r in m.findall("rom")
            if r.get("bios") in (None, bios) and r.get("status") != "nodump"}

# Index the staged blobs BY SHA1, never by filename.
blobs = {}
for fn in sorted(os.listdir(romdir)):
    data = open(os.path.join(romdir, fn), "rb").read()
    blobs[hashlib.sha1(data).hexdigest()] = data
need = {s: wanted(machines[s]) for s in SETS}
flat = {sha for entries in need.values() for _, sha in entries}
if flat != pins:
    raise SystemExit("driver wants sha1s %s, tile pins %s" % (sorted(flat), sorted(pins)))
for setname, entries in need.items():
    with zipfile.ZipFile(os.path.join(outdir, setname + ".zip"), "w", zipfile.ZIP_DEFLATED) as z:
        for member, sha in sorted(entries):
            z.writestr(member, blobs[sha])
    print("%s.zip: %s" % (setname, ", ".join(sorted(n for n, _ in entries))))
print("chosen bios: " + " ".join("%s=%s" % (s, chosen_bios(machines[s])) for s in SETS))
PY
  log "romset assembled from the shipped binary's own -listxml (chosen BIOS entries only)"
}

# NTP is a keystroke thief on a snapshotted guest (bbcmicro measured +2h51m of
# clock jump after a restore, and the first ~30 characters typed across the
# correction vanished). A museum kiosk has no clock consumer.
no_ntp() {
  guest "systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
    timedatectl set-ntp false >/dev/null 2>&1 || true
    ! systemctl is-active --quiet systemd-timesyncd" ||
    die "systemd-timesyncd is still running in the overlay"
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
    -name streamhost-armeval \
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
  log "framebuffer proof: $EVIDENCE/$1.png"
}

white_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 > 170 && $2 > 170 && $3 > 170 { sum += $5 } END { print sum + 0 }'
}
red_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 > 110 && $2 < 70 && $3 < 70 { sum += $5 } END { print sum + 0 }'
}
# THE IDENTITY GATE. The supervisor prompt is drawn as a reverse-video field in
# teletext blue; a plain BBC Micro power-on screen (no `-tube arm`) contains not
# one blue pixel. This is what stops the tile silently shipping as a duplicate
# of bbcmicro if the ARM romset or the `-tube arm` argument is ever lost.
blue_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$3 > 170 && $1 < 90 && $2 < 90 { sum += $5 } END { print sum + 0 }'
}

ARM_MIN_WHITE=${ARM_MIN_WHITE:-1200}
ARM_MAX_WHITE=${ARM_MAX_WHITE:-120000}
ARM_MIN_BLUE=${ARM_MIN_BLUE:-500}
wait_for_banner() {
  local name=$1 white red blue
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      white=$(white_ink "$name")
      red=$(red_ink "$name")
      blue=$(blue_ink "$name")
      if [ "$red" -gt 20000 ]; then
        die "MAME is showing its red startup WARNINGS panel (red=$red) — the shipped binary is missing the skip_warnings patch, or ui.ini was lost"
      fi
      [ "$white" -eq 0 ] && guest "pgrep -x bbcb >/dev/null" 2>/dev/null &&
        die "MAME is running but the captured root is BLACK — it has no X window (check /home/bridge/.Xauthority; see restart_kiosk)"
      if [ "$white" -gt "$ARM_MIN_WHITE" ] && [ "$white" -lt "$ARM_MAX_WHITE" ]; then
        [ "$blue" -gt "$ARM_MIN_BLUE" ] ||
          die "the banner has no blue A* supervisor prompt (blue=$blue) — this is a PLAIN BBC Micro screen, the ARM tube is not fitted"
        log "ARM Evaluation System at its supervisor prompt (white=$white blue=$blue red=$red)"
        return 0
      fi
    fi
    sleep 2
  done
  die "no ARM supervisor framebuffer after 180 seconds"
}

# The .Xauthority removal is not housekeeping: on a fresh overlay startx's
# `xauth add` can lose a race and leave a ZERO-BYTE cookie, after which MAME
# cannot open the display, does NOT exit, and the captured root is pure black
# with no error anywhere (bbcmicro, measured 2026-08-09).
restart_kiosk() {
  guest "systemctl stop getty@tty1 || true
    sleep 2
    for p in \$(pgrep -x bbcb); do
      [ \"\$(readlink /proc/\$p/exe)\" = /opt/armeval/mame/bbcb ] && kill -9 \$p
    done
    rm -f /home/bridge/.Xauthority /home/bridge/.Xauthority-c /home/bridge/.Xauthority-l
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  sleep 8
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# The keyboard proof runs AFTER the bake, against the restored fixture, so
# nothing it types can reach the golden. It drives the three SPA rows through
# the same QMP path and the same pacing the tile ships, and asserts on WHITE INK
# rather than "the screen changed": a screen full of "Bad command" is a screen
# that changed. Measured on this tile: the bare banner is ~4 k lit white pixels,
# the HELP block ~11 k, and the BASIC register dump ~26 k.
HOLD_MS=${HOLD_MS:-80}
GAP_MS=${GAP_MS:-80}
SETTLE_S=${SETTLE_S:-60}
type_line() { python3 "$TYPE_DRIVER" "$QMP" "$HOLD_MS" "$GAP_MS" "$1"; }
keyboard_proof() {
  local base help dump
  # SETTLE FIRST: a `loadvm` hands MAME a guest whose clock has jumped and for a
  # while afterwards it does not sample input reliably (bbcmicro lost a
  # 45-character burst reproducibly 5 s after a restore, at 80/80 AND at
  # 160/160 — so it is not pacing). 60 s after the same restore it typed clean.
  sleep "$SETTLE_S"
  capture keyboard-0-before
  base=$(white_ink keyboard-0-before)
  type_line 'HELP\n'
  sleep 4
  capture keyboard-1-help
  help=$(white_ink keyboard-1-help)
  [ "$help" -gt $((base + 3000)) ] ||
    die "HELP printed nothing (white $base -> $help) — the keyboard route is not reaching the supervisor"
  type_line 'BASIC\n'
  sleep 6
  capture keyboard-2-registerdump
  dump=$(white_ink keyboard-2-registerdump)
  [ "$dump" -gt $((help + 5000)) ] ||
    die "BASIC did not produce the ARM register dump (white $help -> $dump)"
  # The disassembler, and the pager RETURN that the SPA row must also send.
  type_line 'DIS 3000000\n'
  sleep 5
  capture keyboard-3-disassembly
  type_line '\n'
  sleep 2
  capture keyboard-4-after-pager
  # The error path must leave the machine USABLE: back at A*, accepting input.
  [ "$(blue_ink keyboard-4-after-pager)" -gt "$ARM_MIN_BLUE" ] ||
    die "no A* prompt after the register dump and the disassembler — the supervisor did not come back"
  log "keyboard proof: HELP, BASIC (register dump) and DIS all drove at ${HOLD_MS}/${GAP_MS} ms (white $base -> $help -> $dump)"
  hmp "loadvm golden" >/dev/null
  sleep 3
  capture golden-restored-after-keyboard
}

# ---- preflight ---------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing frozen bridge base: $BRIDGE_BASE"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -x "$MAME" ] ||
  die "missing the pinned BBC MAME binary: $MAME (build with scripts/build-guests/build-mame-bbcb.sh)"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
[ -f "$TYPE_DRIVER" ] || die "missing the keyboard-proof typist: $TYPE_DRIVER"
assemble_roms

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
  # The distro `mame` package is installed ONLY for its SDL/X11 runtime
  # libraries; its binary is never launched — the pinned host-built one is.
  guest "export DEBIAN_FRONTEND=noninteractive
    apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1
    apt-get install -y mame >>/tmp/apt.log 2>&1
    install -d -m 755 /opt/armeval/roms /opt/armeval/mame
    printf 'skip_warnings 1\n' > /opt/armeval/ui.ini" ||
    die "could not install the MAME runtime libraries into the overlay (guest /tmp/apt.log)"
  log "installing the pinned MAME binary and the host-assembled romset"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    "$MAME" root@127.0.0.1:/opt/armeval/mame/bbcb || die "could not copy the MAME binary"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    "$TILE_DIR"/roms/*.zip root@127.0.0.1:/opt/armeval/roms/ ||
    die "could not copy the assembled romset zips"
  guest "set -e
    chmod 755 /opt/armeval/mame/bbcb
    [ -s /opt/armeval/roms/bbcb.zip ] &&
    [ -s /opt/armeval/roms/bbc_acorn8271.zip ] &&
    [ -s /opt/armeval/roms/saa5050.zip ] &&
    [ -s /opt/armeval/roms/bbc_tube_arm.zip ]" ||
    die "the assembled MAME zips did not land in the guest"
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  no_ntp
  restart_kiosk
  wait_for_banner cold-boot-banner
fi

# One clean cold boot with the quiet console in force, then bake the golden from
# the state SPA reset restores for ever after.
stop_qemu
boot_tile
wait_for_ssh
restart_kiosk
wait_for_banner ready-before-golden
guest "pgrep -x bbcb >/dev/null" || die "MAME exited after the cold boot"
guest "awk '/MemAvailable/ {print \"guest MemAvailable: \" \$2 \" kB\"}' /proc/meminfo"
guest "awk '/MemAvailable/ {exit !(\$2 > 200000)}' /proc/meminfo" ||
  die "guest MemAvailable fell below 200 MB at ${MEM} MB of RAM — raise MEM"

capture golden-frame
bake_golden
sleep 4
wait_for_banner golden-restored

keyboard_proof
wait_for_banner golden-restored-final

log "PASS: ARM Evaluation System at its untouched supervisor prompt, golden baked"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT mem=${MEM}M evidence=$EVIDENCE"
