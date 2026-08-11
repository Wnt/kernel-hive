#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/bbcmicro.sh — build the Acorn BBC Micro Model B (1981) streamhost
# station as a thin overlay on the frozen bridge base (bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) X kiosk running a purpose-built MAME `bbcb`
#         fullscreen; streamhost captures the Linux framebuffer + AC97 audio
#         exactly like every other kiosk (streamhost/docs/BRIDGE.md).
# TYPE  : "emulator bridge" station. Overlay + per-station /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#
# THE GOLDEN IS THE MACHINE'S OWN UNTOUCHED POWER-ON SCREEN — the MOS 1.20
# banner and the `>` BASIC prompt, nothing typed, nothing curated. That is the
# lesson the Plus/4 paid for: a golden baked inside an application drops a
# visitor into the middle of something with no idea what it is or how to leave.
# Here the machine's own first screen is also the exhibit's whole invitation:
# a blinking prompt on a machine whose entire point was that you programmed it.
#
# ---- WHY A PURPOSE-BUILT MAME, AND WHICH ONE --------------------------------
#   scripts/build-guests/emulators/build-mame-bbcb.sh builds MAME **0.289** (tag
#   `mame0289` == f34f02505e32c1993c6a782b6814232cbfc74e36, the newest stable tag
#   at the time of the add) in the TRIXIE chroot, SUBTARGET=bbcb,
#   SOURCES=src/mame/acorn. The host's own /usr/games/mame is 0.276 — a pinned
#   release is still the point, and it is the station's pin that the romset is
#   assembled against. Now that guest and host are both Debian 13 the chroot is
#   no longer an ABI detour, only a reproducible one; the bridge base's apt
#   `mame` would be an unpinned suite freeze. A romset is only meaningful
#   against ONE binary, so this script re-derives the wanted (name, sha1) pairs
#   from the SHIPPED binary's own `-listxml` — never from a filename.
#
# ---- THE ROMS: ASSEMBLED BY SHA1, STAGED BY THE OPERATOR --------------------
#   The Acorn MOS/BASIC dumps are preservation-source with genuinely murky
#   provenance: there is NO authorised fetchable source, and there is public
#   doubt that Acorn's successors hold clean assignment of the original MOS
#   work. So this builder does NOT download them. It REQUIRES five blobs staged
#   at $ROMDIR by the operator and gates each on its SHA1, then assembles the
#   three MAME zips itself, LETTING THE BINARY NAME THE MEMBERS. Assembling by
#   SHA1 rather than by filename is the kim1/kc85_4 lesson, and it bit here on
#   the first run: 0.276 calls the speech PHROM `phroma.bin` and 0.289 calls the
#   same dump `cm62024.bin`. 0.289 also renamed the BIOS sets (`os12` -> `120`)
#   and flags NONE of them default, so a reader that only honours default="yes"
#   silently drops the OS and BASIC ROMs; MAME's own rule is "default, else the
#   first declared", which is what assemble_roms() implements.
#     os12.rom     0d9bcaf6…  MOS 1.20              (bios `120`, first declared)
#     basic2.rom   4a7393f3…  BBC BASIC II          (bios `120`)
#     phroma.bin   b3698092…  TMS5220 speech PHROM  (machine `bbcb`, no bios tag)
#     saa5050      6c8daba7…  SAA5050 teletext character generator (device `saa5050`)
#     dnfs120.rom  7e3c536b…  Acorn DNFS 1.20       (device `bbc_acorn8271`)
#
#   `saa5050` IS A THIRD ZIP AND IT IS EASY TO MISS: not a member of bbcb.zip and
#   in no BIOS set, it is the character generator inside the Mullard teletext
#   chip, shipped as its own 960-byte device romset. MODE 7 — the mode the
#   machine powers on in — has no glyphs without it and MAME refuses to start
#   (`saa5050 NOT FOUND (tried in saa5050 bbcb)`, measured 2026-08-09 with the
#   four obvious ROMs present). The assertion below walks THREE machine entries.
#
#   THE DISC INTERFACE IS THE DRAGON32 TRAP IN REVERSE. `mame bbcb` with no slot
#   options fits the driver's DEFAULT `fdc` slot, which is `acorn8271` — the
#   Acorn disc interface — and that device's default BIOS is DNFS 1.20. Leave
#   it out and the machine does not fall back to a cassette-only Model B: MAME
#   refuses the missing device ROM. This station ships the driver's own defaults,
#   so the banner carries the `Acorn DFS` line a disc-equipped Model B printed,
#   which is also the configuration the planned `armeval` exhibit runs under
#   (`bbcb -tube arm`). The frame below is what decided it, not this comment.
#
#   `-verifyroms` IS NOT USED AS A GATE: on BIOS-selectable computer drivers it
#   reports "bad" purely because the alternative BIOS entries (OS 1.00/0.92/0.10,
#   BASIC I, eight DFS variants) are absent, which is the point of a pinned set.
#
# ---- THE RED NAG SCREEN -----------------------------------------------------
#   `bbcb` is driver status "imperfect" (emulation good, sound imperfect), so
#   MAME raises a startup WARNINGS stage — a separate stage from the game-info
#   screen, which `-skip_gameinfo` does NOT suppress. It is not the full-screen
#   red "THIS SYSTEM DOESN'T WORK" panel (that one is for `preliminary`), but it
#   would still be the first thing a visitor saw, for ever. The shipped binary
#   carries the same one-line patch the IRIX/MPF-II builds use so the existing
#   `skip_warnings` UI option actually gates that stage, and /opt/bbcmicro/ui.ini
#   sets it. wait_for_banner() below REJECTS a red-dominant frame outright, so a
#   binary rebuilt without the patch fails this script instead of shipping.
#
# ---- KEYBOARD: A BBC IS NOT A PC, AND CAPS LOCK IS ON -----------------------
#   Derived from the driver's own PORT_CHAR table (src/mame/acorn/bbc_kbd.cpp,
#   the `bbc_keyboard` port) with scripts/dev/mame-keymap.py, NOT guessed:
#   thirteen characters sit on different keys from a US PC. The important ones
#   for a BASIC listing are `=` (BBC: Shift+`-`, i.e. send US `_`), `"` (Shift+2,
#   send `@`), `(`/`)` (Shift+8/9, send `*`/`(`), `:` (its own key, send `'`) and
#   `+` (Shift+`;`, send `:`). Untranslated, `=` and every bracket land one key
#   over and the listing is quietly corrupt. The map is declared once in the
#   registry (`keyboard.charMap` -> `SH_KEY_MAP`) and used by both the UI typist
#   and the proof below.
#
#   THE MOS ENABLES CAPS LOCK AT RESET, so unshifted letters arrive UPPERCASE —
#   what BBC BASIC's tokeniser requires. The registry listing is therefore in
#   lower case, as vic20's and mpf2's are, and the machine does the shifting;
#   real upper case with caps lock on would arrive LOWER case and "Mistake".
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the bbcmicro station dir; refuses to
# run while streamhost@bbcmicro is active.
#
# Usage: bbcmicro.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=bbcmicro
VMID=232
UDP=54129
SSH_PORT=5832
WEB_PORT=8132
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/stations/bbcmicro
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
TYPE_DRIVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/bbcmicro-type-qmp.py"
# 768 MB. Measured in-guest with X + MAME up (see the assertion near the end):
# MemAvailable stays comfortably above the 200 MB floor while host QEMU RSS is
# roughly half what the 1536 MB VICE stations cost. MAME's bbcb is a much smaller
# resident set than its arcade drivers.
MEM=768
ROMDIR=/data/assets-staging/bbcmicro
MAME=/data/vms/streamhost/assets/bbcmicro/mame/bbcb

# Guest ROM name -> SHA1. These are ASSERTED against the shipped binary's own
# -listxml before anything is copied into the guest, so a MAME version bump that
# moves a dump fails here rather than at the exhibit.
ROM_SHA1_os12="0d9bcaf6a393c9ce2359ed700ddb53c232c2c45d"
ROM_SHA1_basic2="4a7393f3a45ea309f744441c16723e2ef447a281"
ROM_SHA1_phroma="b369809275cb67dfd8a749265e91adb2d2558ae6"
ROM_SHA1_saa5050="6c8daba70374e5aa3a6402f24cdc5f8677d58a0f"
ROM_SHA1_dnfs120="7e3c536baeae84d6498a14e8405319e01ee78232"

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,95p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[bbcmicro $(date +%H:%M:%S)] $*"; }
die() {
  echo "[bbcmicro] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o ServerAliveInterval=30 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# MAME runs FULLSCREEN with its own aspect correction on. The BBC's MODE 7
# raster is 480x500 (40x25 teletext cells of 12x20): that is the PIXEL count,
# not the picture's shape, and forcing -resolution to it would pin a nearly
# square block in the middle of a black root. -keepaspect reconstructs the 4:3
# image the machine drew on a television or a Microvitec monitor.
#
# THE X ROOT IS 800x600, AND THAT IS AN EMULATION-SPEED DECISION, NOT A PICTURE
# ONE. Under std-VGA capture MAME's only usable renderer is `-video soft`, so
# every frame is scaled and blitted by the guest's CPU and the bill scales with
# the ROOT's pixel count, not the machine's. This add measured the whole curve
# from inside the guest with the BBC's own clock (`P.TIME` twice across a known
# wall interval), which is the only honest way to ask "is the emulator keeping
# up?":
#
#     1024x768, -prescale 2 (copied from mpf2)      47% of real speed
#     1024x768, -prescale 1                         69%
#     1024x768, -prescale 1 -autoframeskip          94%
#      800x600, -prescale 1 -autoframeskip          99%   <- shipped
#
# SPEED IS AN INPUT PROPERTY HERE, NOT A SMOOTHNESS ONE. At 47% a host pacing of
# 80/80 ms is 40/40 in EMULATED time — exactly playbook 5.1's two-frame floor —
# and an 85-character listing came back with a 30-character hole punched in its
# middle, reproducibly, at 80/80 AND again at 160/160. Slowing the typist down
# does not fix an emulator running at half speed; making the emulator keep up
# does. Autoframeskip drops video frames rather than emulated time, which is the
# right trade for a machine whose whole exhibit is its keyboard.
#
# -artwork_crop is NOT cosmetic housekeeping. The bbcb driver ships an internal
# layout with the Model B's three keyboard LEDs (cassette motor, caps lock,
# shift lock) drawn as a labelled strip UNDER the screen; without the crop the
# composite view is 480x549 and the exhibit is a picture with a row of emulator
# chrome beneath it. Cropping to the screen also restores the 4:3 letterbox.
# (The playbook's "artwork machines need -view AND -snapview" note applies to
# headless SNAPSHOT probes; -artwork_crop is the stable option name and is what
# the live view needs.) The caps-lock LED the crop removes was still worth
# seeing once: it is lit at power-on, which is why the demo listing is typed in
# lower case.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Acorn BBC Micro Model B (1981) kiosk launcher (kiosk).
# MOS 1.20 + BBC BASIC II + Acorn DNFS 1.20, MAME driver `bbcb` with the
# driver's own default slots. See scripts/build-guests/tiles/bbcmicro.sh.
# Xorg needs a moment to settle its root mode on a fresh QEMU boot.
sleep 2
# 800x600, NOT the bridge base's stock 1024x768. This is an emulation-SPEED
# choice, not a picture choice: see scripts/build-guests/tiles/bbcmicro.sh.
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
# X'S OWN KEY AUTO-REPEAT IS PURE NOISE HERE, AND IT CORRUPTS TYPING. The
# emulated BBC does its own auto-repeat from the keyboard matrix, so the X
# server's synthetic repeat is a duplicate; and when MAME is busy the server
# processes a press and its release far apart, decides the key was held, and
# injects a burst. Measured 2026-08-09: with repeat on, one 85-character
# listing in three came back mangled (once as a whole line of `O`); with it off,
# the same listing typed clean.
xset r off 2>/dev/null || true
# nice -n 10 IS AN INPUT FIX TOO, AND IT IS THE ONE THAT MATTERED MOST.
# Keystrokes reach MAME as QEMU PS/2 -> guest kernel evdev -> X server -> SDL.
# The kernel's per-client evdev buffer is 64 EVENTS -- 32 characters -- and when
# it overflows the kernel drops the backlog and the X driver resyncs, so the
# keys are simply gone. MAME at 107% of a core on a two-vCPU guest, on a host
# under load, starves the X server for exactly long enough: a 90-character burst
# at 80/80 ms stopped dead after 46 characters and never caught up, while
# /proc/interrupts proved all 190 scancodes had reached the guest kernel. With
# MAME niced below X the same 90-character burst arrives complete. Measured
# 2026-08-09.
exec nice -n 10 /opt/bbcmicro/mame/bbcb bbcb \
  -rompath /opt/bbcmicro/roms \
  -inipath /opt/bbcmicro \
  -skip_gameinfo \
  -artwork_crop \
  -video soft \
  -prescale 1 \
  -autoframeskip \
  -keepaspect \
  -nowindow \
  -nofilter
EOS

# Kiosk session profile: X with NO core pointer cursor (keyboard-only exhibit;
# the core pointer would otherwise sit frozen mid-screen) and no console or
# X-log text on the visible VT. Redirecting startx's output to a file is SAFE
# here and would NOT be on a VICE station: VICE 3.9 segfaults when its stdout is
# not a terminal (docs/guests/vic20.md). MAME does not care.
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (bbcmicro overlay). Start X with NO core pointer cursor
# and keep every byte of console/X-log text off the visible VT: the captured
# framebuffer IS the exhibit.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor >"$HOME"/startx.log 2>&1
fi
EOS
# Host-side QMP typist for the post-bake keyboard proof, kept beside this
# builder as scripts/build-guests/lib/bbcmicro-type-qmp.py. It applies the SAME BBC
# charMap the registry declares, so the proof exercises the translation the UI
# will use rather than a private one. `labctl type` is not a fair test of this
# path (it bypasses streamhost's pacing and drops characters while printing
# "ok"), so the proof owns its typist and its explicit hold/gap.

# Assemble the two MAME zips from the operator-staged blobs, but only after the
# SHIPPED binary has been asked what it wants. Every step here can fail.
assemble_roms() {
  local r want got
  for r in os12:os12.rom basic2:basic2.rom phroma:phroma.bin saa5050:saa5050 dnfs120:dnfs120.rom; do
    [ -s "$ROMDIR/${r##*:}" ] ||
      die "missing staged ROM $ROMDIR/${r##*:} — see docs/guests/bbcmicro.md (preservation-source, no authorised URL; the operator stages these five blobs)"
    eval "want=\$ROM_SHA1_${r%%:*}"
    got=$(sha1sum "$ROMDIR/${r##*:}" | awk '{print $1}')
    [ "$got" = "$want" ] || die "staged ${r##*:} sha1 $got != pinned $want"
  done
  # Ask the binary we ship what it wants, refuse a set it does not agree with,
  # and let IT name the zip members. Three machine entries, because the BBC's
  # ROMs are spread across the driver, the disc-interface device and the
  # teletext chip.
  "$MAME" -listxml bbcb >"$TILE_DIR/listxml.xml" 2>/dev/null ||
    die "the shipped MAME could not list driver bbcb"
  rm -rf "$TILE_DIR/roms"
  mkdir -p "$TILE_DIR/roms"
  python3 - "$TILE_DIR/listxml.xml" "$ROMDIR" "$TILE_DIR/roms" \
    "$ROM_SHA1_os12" "$ROM_SHA1_basic2" "$ROM_SHA1_phroma" "$ROM_SHA1_saa5050" \
    "$ROM_SHA1_dnfs120" <<'PY' || die "the shipped MAME's bbcb romset does not match this tile's pins"
import hashlib, os, sys, xml.etree.ElementTree as ET, zipfile  # noqa: E401
path, romdir, outdir = sys.argv[1:4]
pins = set(sys.argv[4:9])
SETS = ("bbcb", "bbc_acorn8271", "saa5050")
machines = {m.get("name"): m for m in ET.parse(path).getroot().findall("machine")}
for name in SETS:
    if name not in machines:
        raise SystemExit(name + " absent from -listxml")


def chosen_bios(m):
    """MAME's own rule: the biosset flagged default, else the FIRST one declared.
    0.289's bbcb flags NONE of its four (and renamed them 'os12' -> '120'), so a
    default-only reader silently drops the OS and BASIC ROMs entirely."""
    sets = m.findall("biosset")
    if not sets:
        return None
    for b in sets:
        if b.get("default") == "yes":
            return b.get("name")
    return sets[0].get("name")


def wanted(m):
    """(name, sha1) the machine needs with NO slot/bios options given: the chosen
    BIOS's entries plus every entry belonging to no BIOS at all. `nodump` entries
    are excluded -- MAME warns about them every boot and runs anyway."""
    bios = chosen_bios(m)
    return {(r.get("name"), r.get("sha1")) for r in m.findall("rom")
            if r.get("bios") in (None, bios) and r.get("status") != "nodump"}

# Index the staged blobs BY SHA1, never by filename: MAME renames members
# between versions (0.276's `phroma.bin` is 0.289's `cm62024.bin`, same dump),
# so the hash is the only stable identity and the driver supplies the name.
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

# NTP IS A KEYSTROKE THIEF ON A SNAPSHOTTED GUEST. `loadvm` restores a guest
# whose wall clock is wrong -- measured here at +2h51m immediately after a
# restore, corrected back by systemd-timesyncd about twenty seconds later -- and
# across that correction the first ~30 characters typed after a restore vanished
# reproducibly. A museum kiosk with no clock consumer does not need NTP, so the
# overlay switches it off; the RTC still comes from the host at every cold boot.
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
    -name streamhost-bbcmicro \
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

# The BBC's MODE 7 power-on screen is white teletext on black: a bare X root, a
# dead MAME and a black MODE 1 canvas all measure ~0.
white_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 > 170 && $2 > 170 && $3 > 170 { sum += $5 } END { print sum + 0 }'
}
# MAME's startup WARNINGS stage paints a large red field. If the shipped binary
# were ever rebuilt without the skip_warnings patch this is what would ship, so
# the readiness predicate rejects it rather than baking it into the golden.
red_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 > 110 && $2 < 70 && $3 < 70 { sum += $5 } END { print sum + 0 }'
}

# Banner + prompt is a few thousand white pixels on the 1024x768 root; a full
# MODE 1 pattern is an order of magnitude more. The band rejects both a black
# root and a screen that is not the idle banner.
BBC_MIN_WHITE=${BBC_MIN_WHITE:-1200}
BBC_MAX_WHITE=${BBC_MAX_WHITE:-120000}
wait_for_banner() {
  local name=$1 white red
  for _ in $(seq 1 90); do
    if capture "$name" 2>/dev/null; then
      white=$(white_ink "$name")
      red=$(red_ink "$name")
      if [ "$red" -gt 20000 ]; then
        die "MAME is showing its red startup WARNINGS panel (red=$red) — the shipped binary is missing the skip_warnings patch, or ui.ini was lost"
      fi
      # An all-black root is the .Xauthority failure above, not a slow boot:
      # MAME keeps emulating happily with no window. Name it rather than timing
      # out after three minutes with "no framebuffer".
      [ "$white" -eq 0 ] && guest "pgrep -x bbcb >/dev/null" 2>/dev/null &&
        die "MAME is running but the captured root is BLACK — it has no X window (check /home/bridge/.Xauthority; see restart_kiosk)"
      [ "$white" -gt "$BBC_MIN_WHITE" ] && [ "$white" -lt "$BBC_MAX_WHITE" ] && {
        log "BBC Micro at its power-on banner (white ink=$white, red=$red)"
        return 0
      }
    fi
    sleep 2
  done
  die "no BBC Micro power-on framebuffer after 180 seconds"
}

# THE BLACK-SCREEN TRAP, and why the .Xauthority removal is not housekeeping.
# On the very first boot of a fresh overlay the kiosk's X session left
# /home/bridge/.Xauthority at ZERO BYTES (startx's `xauth add` lost a race with
# the session the builder had just restarted underneath it). Every X client then
# fails authentication — and MAME does not exit when it cannot open the display.
# It keeps emulating: the process is alive, its ALSA buffer underruns scroll past
# in startx.log, and the captured framebuffer is 1024x768 of pure black with no
# error anywhere. `xwininfo -root -tree` against the SERVER's own auth file is
# what proves it: "0 children". Deleting the stale file before the restart makes
# startx mint a fresh cookie, and the window appears. Measured 2026-08-09.
restart_kiosk() {
  guest "systemctl stop getty@tty1 || true
    sleep 2
    for p in \$(pgrep -x bbcb); do
      [ \"\$(readlink /proc/\$p/exe)\" = /opt/bbcmicro/mame/bbcb ] && kill -9 \$p
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
# nothing it types can reach the golden. It types the registry's own demo
# listing at the station's SHIPPED pacing and runs it, and asserts what the screen
# actually shows: a MODE 1 fan of coloured lines is an order of magnitude more
# lit pixels than a teletext banner: measured on this station, the banner is 5 735
# lit pixels, the five typed lines about 15 000, and the fan 87 924, so 50 000
# separates them with room either side. Asserting only "the framebuffer changed"
# would pass on a listing full of `Mistake` errors — which is exactly what an
# unmapped `=` or bracket produces.
HOLD_MS=${HOLD_MS:-80}
GAP_MS=${GAP_MS:-80}
SETTLE_S=${SETTLE_S:-60}
lit_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$1 + $2 + $3 > 150 { sum += $5 } END { print sum + 0 }'
}
keyboard_proof() {
  local lit
  # SETTLE FIRST, and the delay is a measurement, not superstition. A `loadvm`
  # hands MAME a guest whose clock has jumped, and for a while afterwards it
  # does not sample its input reliably: the same listing typed 5 s after a
  # restore lost a 45-character burst out of its middle, REPRODUCIBLY, at 80/80
  # and again at 160/160 — so it is not a pacing problem. Typed 60 s after the
  # same restore it landed intact. Measured 2026-08-09; docs/guests/bbcmicro.md
  # records what it means for a visitor who hits reset and types immediately.
  sleep "$SETTLE_S"
  python3 "$TYPE_DRIVER" "$QMP" "$HOLD_MS" "$GAP_MS" \
    '10 mode 1\n20 for i=0 to 1279 step 16\n30 gcol 0,1+i mod 3\n40 move 640,512:draw i,1023\n50 next\n'
  sleep 3
  capture keyboard-1-listing
  python3 "$TYPE_DRIVER" "$QMP" "$HOLD_MS" "$GAP_MS" 'run\n'
  sleep 8
  capture keyboard-2-run
  lit=$(lit_ink keyboard-2-run)
  [ "$lit" -gt 50000 ] ||
    die "RUN did not paint the MODE 1 pattern (lit=$lit) — the listing did not tokenise, check the charMap"
  log "keyboard proof: the demo listing typed at ${HOLD_MS}/${GAP_MS} ms and RAN (lit=$lit)"
  hmp "loadvm golden" >/dev/null
  sleep 3
  capture golden-restored-after-keyboard
}

# ---- preflight ---------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
[ -x "$MAME" ] ||
  die "missing the pinned BBC MAME binary: $MAME (build with scripts/build-guests/emulators/build-mame-bbcb.sh)"
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
    install -d -m 755 /opt/bbcmicro/roms /opt/bbcmicro/mame
    printf 'skip_warnings 1\n' > /opt/bbcmicro/ui.ini" ||
    die "could not install the MAME runtime libraries into the overlay (guest /tmp/apt.log)"
  log "installing the pinned MAME binary and the host-assembled romset"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    -o UserKnownHostsFile=/dev/null "$MAME" root@127.0.0.1:/opt/bbcmicro/mame/bbcb || die "could not copy the MAME binary"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    -o UserKnownHostsFile=/dev/null "$TILE_DIR"/roms/*.zip root@127.0.0.1:/opt/bbcmicro/roms/ ||
    die "could not copy the assembled romset zips"
  guest "set -e
    chmod 755 /opt/bbcmicro/mame/bbcb
    [ -s /opt/bbcmicro/roms/bbcb.zip ] &&
    [ -s /opt/bbcmicro/roms/bbc_acorn8271.zip ] &&
    [ -s /opt/bbcmicro/roms/saa5050.zip ]" ||
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
# the state UI reset restores for ever after. Bake from an UNTOUCHED cold boot:
# the mpf2 add shipped a golden carrying its own verification output and had to
# be re-baked, and the Plus/4 shipped one curated inside an application and had
# to be re-baked too.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile --skip-if-golden # see lib/bridge-coldboot
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

log "PASS: BBC Micro Model B at its untouched power-on banner, BASIC prompt, golden baked"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT mem=${MEM}M evidence=$EVIDENCE"
