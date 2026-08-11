#!/usr/bin/env bash
# =============================================================================
# build-guests/armeval.sh — build the Acorn ARM Evaluation System (1986)
# streamhost station as a thin overlay on the frozen bridge base (bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) X kiosk running the SAME purpose-built MAME
#         `bbcb` the bbcmicro station ships, but with the ARM second processor
#         fitted to the Tube: `bbcb -tube arm`. streamhost captures the Linux
#         framebuffer + AC97 audio exactly like every other kiosk.
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# WHAT THE EXHIBIT IS. The ARM Evaluation System is the FIRST ARM PRODUCT EVER
# SOLD: an ARM1 on a podule board that hangs off a BBC Micro's Tube, sold to
# developers in 1986 so they could write ARM code before the Archimedes existed.
# The board has no operating system of its own — it has a 16 KB supervisor ROM.
# The LANGUAGE comes off a floppy: Disc 3 of the ARM Evaluation System set
# carries `AB`, ARM BBC Basic V 1.00, which loads into the co-processor's own
# 4 MB and runs THERE while the 6502 host is demoted to a terminal and a disc
# controller. That is the exhibit: a visitor types a BASIC line and a 1986 ARM
# executes it.
#
# ---- THE GOLDEN --------------------------------------------------------------
#   ARM Second Processor 4096K
#   Acorn ADFS
#   BASIC
#     A* *LIB $
#     A* AB
#   ARM BBC Basic V version 1.00 for ARM Second Processor (C) Acorn 1986
#
#   >_
#
#   The two `A*` lines are BAKED IN, not typed by a visitor, and they are left
#   on screen deliberately: they are the provenance of the `>` prompt below
#   them — a co-processor loading its language off a floppy, in public.
#   `*LIB $` is REQUIRED: on a cold boot the ADFS library is "Unset" and both
#   `AB` and `*AB` answer "No directory (169)". Disc 3's root catalogue is
#   !boot / DeBug / AB / du / fpe / link / readme / rm, and `AB` is ARM BASIC.
#
#   THE BANNER IS THE ACCEPTANCE TEST'S FIRST CRITERION and it is easy to ship
#   the wrong one: with no `-tube arm` the identical driver prints "BBC Computer
#   32K" and a white `>` BASIC prompt, which is the bbcmicro station — a
#   near-duplicate and worthless. The bake-time IDENTITY GATE catches that: the
#   supervisor prompt is a reverse-video field in teletext BLUE and a plain BBC
#   Micro power-on screen contains not one blue pixel (measured: this golden
#   carries 3288 blue pixels in its two `A*` cells; a bare BBC banner, zero).
#
# ---- THE THREE NON-OBVIOUS ARGUMENTS, EACH PAID FOR BY AN EXPERIMENT ---------
#   `-fdc acorn1770` : the armevals discs are ADFS `.adl` (640 KB, DOUBLE
#                      density). The Acorn 8271 that the bbcmicro station ships is
#                      SINGLE density and cannot read them at all. Swapping the
#                      FDC slot pulls in a second device romset, bbc_acorn1770
#                      (default BIOS dfs223), and drops bbc_acorn8271's DNFS
#                      1.20 — which is why this exhibit's *HELP says "DFS 2.23"
#                      and "Advanced DFS 1.30" where bbcmicro's says "DFS 1.20".
#   `-rom3`, NOT -rom1 : ADFS has to live in a SIDEWAYS socket. In romimage1 it
#                      KILLS THE TUBE — the banner falls back to "BBC Computer
#                      32K" and the station is a bbcmicro duplicate. romimage4
#                      keeps the Tube but displaces host BBC BASIC (the "BASIC"
#                      line vanishes from the banner). romimage3 keeps BOTH.
#   `skip_warnings 1` in ui.ini : it is a UI option, NOT a command-line one —
#                      `-skip_warnings` is rejected as an unknown option.
#
# ---- WHY `bbcb -tube arm`, NOT the `bbcmarm` driver -------------------------
#   MAME also has `bbcmarm`, a BBC MASTER with the same ARM podule. The Master
#   boots in MODE 7 and MAME's SAA5050 renders the supervisor prompt's blue
#   control code as mosaic blobs that read as screen corruption on a museum
#   wall. `bbcb -tube arm` renders the same prompt cleanly. Measured by frame on
#   both drivers, recon 2026-08-09.
#
# ---- THE MEDIA ---------------------------------------------------------------
#   Four MAME zips are assembled from operator-staged blobs, plus TWO plain
#   files handed to MAME by path (the ADFS sideways ROM and the floppy):
#     bbcb           os12.rom / basic2.rom / cm62024.bin   (BIOS 120)
#     saa5050        saa5050                (a THIRD zip in no BIOS set; without
#                                            it MODE 7 has no glyphs at all)
#     bbc_tube_arm   armeval_101.rom        (BIOS 101 = Executive v1.00,
#                                            14th August 1986 — four months
#                                            after the first ARM1 silicon ran)
#     bbc_acorn1770  "dfs v2.23,acorn.rom"  (BIOS dfs223)
#     -rom3          Acorn-ADFS-1.30.rom
#     -flop1         armevaluationsystem-disc3.adl  ("Utilities 2 / BASIC")
#
#   ALL OF IT IS PRESERVATION-SOURCE WITH NO AUTHORISED URL and a genuinely
#   disputed chain of title, so this builder does NOT download anything: it
#   REQUIRES the blobs staged at $ROMDIR by the operator, gates each on its
#   SHA-1, and lets the SHIPPED BINARY's own -listxml name the zip members (the
#   kim1/kc85_4 lesson — MAME renames members between versions, so the hash is
#   the only stable identity; the staged file is `phroma.bin`, the member
#   MAME wants is `cm62024.bin`, and only the SHA-1 connects them). Never
#   commit the bits. Discs 4-6 of the same set (Cambridge LISP, PROLOG,
#   FORTRAN 77) exist and verify, but are NOT part of this exhibit.
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
#   (device status is not driver status), so this station inherits bbcmicro's
#   answer: the shipped binary carries the one-line skip_warnings patch and
#   /opt/armeval/ui.ini sets it. nag_sweep() then walks EVERY frame of a cold
#   boot and rejects any red at all, so a binary rebuilt without the patch fails
#   this script instead of shipping a red panel to a museum wall.
#
# ---- THE VISITOR INTERACTION -------------------------------------------------
#   The golden rests INSIDE ARM BASIC, so the exhibit's actions are ARM BASIC's,
#   not the supervisor's. Each is driven against the RESTORED fixture at the
#   bottom of this script, through the same QMP key path and the same pacing the
#   station ships:
#     the registry demoProgram -> "20000 LOOPS 0.22": twenty thousand
#                       interpreted BASIC loops in a fifth of a second on an
#                       8 MHz ARM1, on a machine whose 6502 host would need the
#                       best part of a minute. THE TRAILING SPACE INSIDE THE
#                       QUOTES MATTERS — without it BBC BASIC butts the number
#                       against the word and prints "20000 LOOPS0.22".
#     LIST           -> the program back, tokenised and re-listed by the ARM.
#     *HELP          -> the whole machine naming itself: "Executive version 1.00
#                       (14th August 1986)", Advanced DFS 1.30, TUBE HOST 2.20,
#                       DFS 2.23, SRAM 1.03, OS 1.20.
#     *CAT           -> Disc 3's catalogue with `Lib. $` and `AB` in it — where
#                       the language the visitor is typing into came from.
#     ESCAPE         -> stops a running program ("Escape at line 20"), and MAME
#                       SURVIVES it (Esc is also MAME's own UI cancel key, so
#                       this one had to be measured, not assumed).
#
#   THE SUPERVISOR IS NOT REACHABLE FROM HERE, and this script does not pretend
#   otherwise. `*QUIT`, `*DIS 3000000` and `*SHOWREGS` all answer "Bad command"
#   from the ARM BASIC prompt, and BREAK (F12) does nothing at all. See
#   docs/guests/armeval.md for the frames.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the armeval station dir; refuses to
# run while streamhost@armeval is active.
#
# SANDBOX RUNS. There is deliberately NO env-var override for TILE_DIR here.
# `clone-guard check-launcher` refuses any script that can reach a production
# station path through an unset variable — that parameter-default is the exact
# footgun that once killed a live station (docs/lab/clone-guard.md) — so a bake-off
# or experiment run is made by REWRITING the three constants below into a
# /data/vms/soltest/<ns> copy, which then passes check-launcher on its own.
#
# Usage: armeval.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=armeval
VMID=238
UDP=54135
SSH_PORT=5838
WEB_PORT=8135
# Slot 135 is this station's; the VMID LABEL and the ssh hostfwd follow the fleet's
# own arithmetic (vmid = slot + 103, ssh = slot + 5703), which puts them at 238
# and 5838. The original scaffold reserved 235/5835 — both were already the LIVE
# kc854 station's, and 5835 is a real hostfwd, so QEMU refused to start on it.
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/stations/armeval
ROMDIR=/data/assets-staging/armeval
MAME=/data/vms/streamhost/assets/bbcmicro/mame/bbcb
# 768 MB, the same as bbcmicro: the same binary, the same 800x600 X root, two
# more 16 KB ROMs and a 640 KB floppy image. Asserted in-guest against the
# 200 MB MemAvailable floor below.
MEM=768

OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
# bbcmicro-type-qmp.py is shared with the bbcmicro station, so the build-guests
# reorganisation put it in ../lib/ rather than beside this script.
TYPE_DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/bbcmicro-type-qmp.py"

# Zip-member ROMs: guest name -> SHA1, asserted against the shipped binary's own
# -listxml before anything is copied into the guest.
ROM_SHA1_os12="0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d"
ROM_SHA1_basic2="4a7393f3a45ea309f744441c16723e2ef447a281"
ROM_SHA1_phroma="b369809275cb67dfd8a749265e91adb2d2558ae6"
ROM_SHA1_saa5050="6c8daba70374e5aa3a6402f24cdc5f8677d58a0f"
ROM_SHA1_armeval101="f86bbc4894e62725b8ef22d44e7f44d37c98ac14"
ROM_SHA1_dfs223="0d7ed0b0b3852cb61970ada1993244f2896896aa"
# Plain files handed to MAME by path, gated the same way.
ADFS_FILE="Acorn-ADFS-1.30.rom"
ADFS_SHA1="301fd05c475a629c4bec70510d4507256a5b00d8"
DISC_FILE="armevaluationsystem-disc3.adl"
DISC_SHA1="f5114ff744f6f742da3959a91a1b98af0bd1db5d"

# The listing the exhibit types, kept in ONE place so the builder's proof and
# registry/stations/armeval.json's demoProgram cannot drift apart.
DEMO='10 T%=TIME\n20 FOR I%=1 TO 20000:NEXT\n30 PRINT"20000 LOOPS ";(TIME-T%)/100\nRUN\n'

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,150p' "$0"
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
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=30 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# The launcher is bbcmicro's, verbatim, plus the ARM tube, the 1770 disc
# interface, ADFS in sideways socket 3 and Disc 3 in drive 0. Every one of the
# odd-looking lines below is a measured bbcmicro fix and they all apply
# unchanged here — same emulator, same X server, same QEMU PS/2 path:
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
# Acorn ARM Evaluation System (1986) kiosk launcher (kiosk).
# A BBC Micro Model B host (MOS 1.20 + BBC BASIC II) with the ARM Evaluation
# System on the Tube (Executive v1.00, 14th August 1986), the Acorn 1770 disc
# interface (the ADFS discs are double density; the 8271 cannot read them) and
# Acorn ADFS 1.30 in sideways socket 3. Socket 1 is NOT usable: ADFS there stops
# the Tube from coming up at all. Drive 0 holds Disc 3 of the ARM Evaluation
# System set, "Utilities 2 / BASIC", which carries ARM BASIC as $.AB.
# See build-guests/armeval.sh.
sleep 2
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
xset r off 2>/dev/null || true
exec nice -n 10 /opt/armeval/mame/bbcb bbcb \
  -tube arm \
  -fdc acorn1770 \
  -rom3 /opt/armeval/Acorn-ADFS-1.30.rom \
  -flop1 /opt/armeval/armevaluationsystem-disc3.adl \
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
# binary has been asked what it wants, and gate the two plain files.
# `bbc_tube_arm` and `bbc_acorn1770` are DEVICES, not drivers: they never appear
# without `-tube arm` / `-fdc acorn1770`, and MAME looks for them by name in the
# rompath like any other device romset.
assemble_roms() {
  local r want got
  for r in os12:os12.rom basic2:basic2.rom phroma:phroma.bin saa5050:saa5050 \
    armeval101:armeval_101.rom "dfs223:dfs v2.23,acorn.rom" \
    "ADFS:$ADFS_FILE" "DISC:$DISC_FILE"; do
    [ -s "$ROMDIR/${r#*:}" ] ||
      die "missing staged blob $ROMDIR/${r#*:} — see docs/guests/armeval.md (preservation-source, no authorised URL; the operator stages these eight blobs)"
    case "${r%%:*}" in
      ADFS) want=$ADFS_SHA1 ;;
      DISC) want=$DISC_SHA1 ;;
      *) eval "want=\$ROM_SHA1_${r%%:*}" ;;
    esac
    got=$(sha1sum "$ROMDIR/${r#*:}" | awk '{print $1}')
    [ "$got" = "$want" ] || die "staged ${r#*:} sha1 $got != pinned $want"
  done
  "$MAME" -listxml bbcb >"$TILE_DIR/listxml.xml" 2>/dev/null ||
    die "the shipped MAME could not list driver bbcb"
  rm -rf "$TILE_DIR/roms"
  mkdir -p "$TILE_DIR/roms"
  python3 - "$TILE_DIR/listxml.xml" "$ROMDIR" "$TILE_DIR/roms" \
    "$ROM_SHA1_os12" "$ROM_SHA1_basic2" "$ROM_SHA1_phroma" "$ROM_SHA1_saa5050" \
    "$ROM_SHA1_armeval101" "$ROM_SHA1_dfs223" <<'PY' || die "the shipped MAME's romset does not match this tile's pins"
import hashlib, os, sys, xml.etree.ElementTree as ET, zipfile  # noqa: E401
path, romdir, outdir = sys.argv[1:4]
pins = set(sys.argv[4:10])
SETS = ("bbcb", "saa5050", "bbc_tube_arm", "bbc_acorn1770")
machines = {m.get("name"): m for m in ET.parse(path).getroot().findall("machine")}
for name in SETS:
    if name not in machines:
        raise SystemExit(name + " absent from -listxml")


def chosen_bios(m):
    """MAME's own rule: the biosset flagged default, else the FIRST one declared.
    bbcb flags `120`; bbc_tube_arm flags `101` (Executive v1.00, 14th August
    1986) — the one this exhibit is about; bbc_acorn1770 flags `dfs223`."""
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
    p = os.path.join(romdir, fn)
    if not os.path.isfile(p):
        continue
    data = open(p, "rb").read()
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
# one blue pixel. This is what stops the station silently shipping as a duplicate
# of bbcmicro if the ARM romset or the `-tube arm` argument is ever lost — and
# it survives into the ARM BASIC golden because the two `A*` lines stay on
# screen above the `>` prompt.
blue_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$3 > 170 && $1 < 90 && $2 < 90 { sum += $5 } END { print sum + 0 }'
}

ARM_MIN_WHITE=${ARM_MIN_WHITE:-1200}
ARM_MAX_WHITE=${ARM_MAX_WHITE:-120000}
ARM_MIN_BLUE=${ARM_MIN_BLUE:-500}
# The ARM BASIC banner is three more lines of text than the bare supervisor
# screen: measured 12647 lit white pixels against the supervisor's ~4000, so a
# floor of 9000 fails a golden that never got past `A*`.
ARM_BASIC_WHITE=${ARM_BASIC_WHITE:-9000}

# Wait for the ARM supervisor's own power-on screen: white ink in range, at
# least one blue `A*` cell, and no red panel.
wait_for_banner() {
  local name=$1 white red blue black=0
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      white=$(white_ink "$name")
      red=$(red_ink "$name")
      blue=$(blue_ink "$name")
      if [ "$red" -gt 20000 ]; then
        die "MAME is showing its red startup WARNINGS panel (red=$red) — the shipped binary is missing the skip_warnings patch, or ui.ini was lost"
      fi
      # A BLACK root with MAME already up is the zero-byte-cookie failure — but
      # it is ALSO what the first second or two after `startx` looks like, so
      # this must be PERSISTENT before it is fatal. Measured on this station's own
      # first build: MAME had been exec'd for ~11 s and the root was still black,
      # and an eager one-frame check failed a build whose guest was perfect.
      if [ "$white" -eq 0 ] && guest "pgrep -x bbcb >/dev/null" 2>/dev/null; then
        black=$((black + 1))
        [ "$black" -lt 20 ] ||
          die "MAME has been running for 40 s and the captured root is still BLACK — it has no X window (check /home/bridge/.Xauthority; see restart_kiosk)"
      else
        black=0
      fi
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

# The second identity gate: the machine is not merely an ARM, it is an ARM
# RUNNING ARM BASIC. Both conditions, on the same frame.
assert_armbasic() {
  local name=$1 white blue
  capture "$name"
  white=$(white_ink "$name")
  blue=$(blue_ink "$name")
  [ "$white" -gt "$ARM_BASIC_WHITE" ] ||
    die "ARM BASIC did not load (white=$white < $ARM_BASIC_WHITE) — the fixture is still the bare supervisor screen; check *LIB \$ and the Disc 3 image"
  [ "$blue" -gt "$ARM_MIN_BLUE" ] ||
    die "the A* provenance lines are gone (blue=$blue) — this is not the ARM Evaluation System"
  log "ARM BBC Basic V on the ARM second processor (white=$white blue=$blue)"
}

# THE RED NAG SWEEP. wait_for_banner only rejects a red-dominant frame at the
# moment it happens to sample; this walks a whole cold boot at 1.5 s and fails
# on ANY red pixel in ANY frame a visitor could see.
nag_sweep() {
  local i red worst=0
  for i in $(seq 1 30); do
    capture "nag-sweep-$i" >/dev/null 2>&1 || true
    red=$(red_ink "nag-sweep-$i")
    [ "$red" -gt "$worst" ] && worst=$red
    rm -f "$EVIDENCE/nag-sweep-$i.ppm" "$EVIDENCE/nag-sweep-$i.png"
    sleep 1.5
  done
  [ "$worst" -eq 0 ] ||
    die "a red MAME warning panel was visible during the cold boot (worst red=$worst px over 30 frames)"
  log "red-nag sweep: 30 frames across 45 s of cold boot, worst red = 0 px"
}

restart_kiosk() {
  # The .Xauthority removal is not housekeeping: on a fresh overlay startx's
  # `xauth add` can lose a race and leave a ZERO-BYTE cookie, after which MAME
  # cannot open the display, does NOT exit, and the captured root is pure black
  # with no error anywhere (bbcmicro, measured 2026-08-09).
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

HOLD_MS=${HOLD_MS:-80}
GAP_MS=${GAP_MS:-80}
SETTLE_S=${SETTLE_S:-60}
type_line() { python3 "$TYPE_DRIVER" "$QMP" "$HOLD_MS" "$GAP_MS" "$1"; }

# Load ARM BASIC off Disc 3 and leave the two command lines on screen. This runs
# ONCE, before the bake, and IS the fixture — a visitor never types it.
load_arm_basic() {
  type_line '*LIB $\n'
  sleep 3
  type_line 'AB\n'
  # `AB` is a 40 KB image coming off an emulated 1770 through ADFS, and the ARM
  # prints its banner only when the whole thing has landed. Measured: 6 s is NOT
  # enough — the frame at 6 s shows both A* lines and an empty cursor line, i.e.
  # a load still in flight, which a fixed sleep would misreport as "no ARM
  # BASIC". Poll for the banner instead.
  local i white
  for i in $(seq 1 30); do
    sleep 3
    capture fixture-armbasic >/dev/null
    white=$(white_ink fixture-armbasic)
    [ "$white" -gt "$ARM_BASIC_WHITE" ] && break
  done
  assert_armbasic fixture-armbasic
}

# THE RESET CHECK, done honestly. MODE 7 BLINKS ITS CURSOR, so two screendumps
# taken a fixed number of WALL-CLOCK seconds after a restore differ by exactly
# one cursor cell (~40 px) and hash differently while describing the same state.
# Sample at a fixed MACHINE instant instead: stop, restore, stop, dump, resume.
reset_check() {
  local a b
  for _ in 1 2; do
    hmp stop >/dev/null
    hmp "loadvm golden" >/dev/null
    hmp stop >/dev/null
    rm -f "$EVIDENCE/reset-$1.ppm"
    hmp "screendump $EVIDENCE/reset-$1.ppm" >/dev/null
    hmp cont >/dev/null
    pnmtopng "$EVIDENCE/reset-$1.ppm" >"$EVIDENCE/reset-$1.png"
    [ -n "${a:-}" ] && b=$(sha256sum "$EVIDENCE/reset-$1.ppm" | awk '{print $1}') && break
    a=$(sha256sum "$EVIDENCE/reset-$1.ppm" | awk '{print $1}')
    sleep 3
  done
  [ "$a" = "$b" ] ||
    die "loadvm golden is NOT byte-identical with the VM stopped: $a != $b"
  log "reset check: two stopped restores are byte-identical, sha256 $a"
}

# The keyboard proof runs AFTER the bake, against the restored fixture, so
# nothing it types can reach the golden. It drives the UI's rows and the
# registry's demoProgram through the same QMP path and the same pacing the station
# ships, and asserts on WHITE INK rather than "the screen changed": a screen
# full of "Bad command" is a screen that changed.
keyboard_proof() {
  local base demo lst hlp cat0 t0 t1
  # SETTLE FIRST: a `loadvm` hands MAME a guest whose clock has jumped and for a
  # while afterwards it does not sample input reliably (bbcmicro lost a
  # 45-character burst reproducibly 5 s after a restore, at 80/80 AND at
  # 160/160 — so it is not pacing). 60 s after the same restore it typed clean.
  sleep "$SETTLE_S"
  capture keyboard-0-before
  base=$(white_ink keyboard-0-before)
  t0=$(date +%s)
  type_line "$DEMO"
  t1=$(date +%s)
  sleep 6
  capture keyboard-1-demo
  demo=$(white_ink keyboard-1-demo)
  [ "$demo" -gt $((base + 6000)) ] ||
    die "the demoProgram did not run (white $base -> $demo) — the keyboard route is not reaching ARM BASIC"
  log "demoProgram: 78 characters in $((t1 - t0)) s at ${HOLD_MS}/${GAP_MS} ms, white $base -> $demo"
  [ $((t1 - t0)) -lt 16 ] ||
    die "the demoProgram took $((t1 - t0)) s on the wire — over the ~15 s a visitor will wait"
  type_line 'LIST\n'
  sleep 4
  capture keyboard-2-list
  lst=$(white_ink keyboard-2-list)
  [ "$lst" -gt $((demo + 3000)) ] || die "LIST printed nothing (white $demo -> $lst)"
  type_line '*HELP\n'
  sleep 6
  capture keyboard-3-starhelp
  hlp=$(white_ink keyboard-3-starhelp)
  [ "$hlp" -gt 15000 ] || die "*HELP printed nothing useful (white=$hlp)"
  hmp "loadvm golden" >/dev/null
  sleep "$SETTLE_S"
  type_line '*CAT\n'
  sleep 6
  capture keyboard-4-starcat
  cat0=$(white_ink keyboard-4-starcat)
  [ "$cat0" -gt $((ARM_BASIC_WHITE + 6000)) ] ||
    die "*CAT did not catalogue Disc 3 (white=$cat0) — the floppy is not readable, check -fdc acorn1770"
  # ESCAPE is also MAME's own UI cancel key. Prove BOTH halves: the running
  # program stops, AND the emulator is still alive afterwards.
  type_line '20 FOR I%=1 TO 100000000:NEXT\nRUN\n'
  sleep 4
  python3 /root/cdrv.py "$QMP" key esc >/dev/null
  sleep 4
  capture keyboard-5-escape
  guest "pgrep -x bbcb >/dev/null" ||
    die "MAME EXITED when ESCAPE was pressed — Esc is MAME's UI cancel key and the exhibit cannot ship that button"
  hmp "loadvm golden" >/dev/null
  sleep 4
  assert_armbasic golden-restored-after-keyboard
}

# ---- preflight ---------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
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
  log "installing the pinned MAME binary, the assembled romset and the media"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    -o UserKnownHostsFile=/dev/null "$MAME" root@127.0.0.1:/opt/armeval/mame/bbcb || die "could not copy the MAME binary"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    -o UserKnownHostsFile=/dev/null "$TILE_DIR"/roms/*.zip root@127.0.0.1:/opt/armeval/roms/ ||
    die "could not copy the assembled romset zips"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    -o UserKnownHostsFile=/dev/null "$ROMDIR/$ADFS_FILE" "$ROMDIR/$DISC_FILE" root@127.0.0.1:/opt/armeval/ ||
    die "could not copy the ADFS sideways ROM and Disc 3 into the guest"
  guest "set -e
    chmod 755 /opt/armeval/mame/bbcb
    [ -s /opt/armeval/roms/bbcb.zip ] &&
    [ -s /opt/armeval/roms/saa5050.zip ] &&
    [ -s /opt/armeval/roms/bbc_tube_arm.zip ] &&
    [ -s /opt/armeval/roms/bbc_acorn1770.zip ] &&
    [ \"\$(sha1sum < /opt/armeval/$ADFS_FILE | cut -d' ' -f1)\" = $ADFS_SHA1 ] &&
    [ \"\$(sha1sum < /opt/armeval/$DISC_FILE | cut -d' ' -f1)\" = $DISC_SHA1 ]" ||
    die "the assembled MAME zips or the two plain media files did not land in the guest"
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  no_ntp
  restart_kiosk
  wait_for_banner cold-boot-banner
fi

# One clean cold boot with the quiet console in force. The red-nag sweep runs
# across THIS boot, because it is the boot a visitor's reset reproduces.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
boot_tile
nag_sweep
wait_for_ssh
restart_kiosk
wait_for_banner ready-before-golden
guest "pgrep -x bbcb >/dev/null" || die "MAME exited after the cold boot"
guest "awk '/MemAvailable/ {print \"guest MemAvailable: \" \$2 \" kB\"}' /proc/meminfo"
guest "awk '/MemAvailable/ {exit !(\$2 > 200000)}' /proc/meminfo" ||
  die "guest MemAvailable fell below 200 MB at ${MEM} MB of RAM — raise MEM"
awk '/VmRSS/ {print "[armeval] host QEMU " $0}' "/proc/$(cat "$PID")/status"

# ARM BASIC is loaded ONCE here, and the machine is baked sitting in it.
sleep 20
load_arm_basic
capture golden-frame
bake_golden
sleep 4
assert_armbasic golden-restored

reset_check a
keyboard_proof
reset_check b

log "PASS: ARM BBC Basic V 1.00 running on the 1986 ARM, golden baked"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT mem=${MEM}M evidence=$EVIDENCE"
