#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/decos.sh — the DEC PDP-11 tile: ONE machine and THREE of the
# operating systems DEC sold for it, behind a chooser, as a thin overlay on the
# frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running ONE fullscreen xterm, green on
#         black, whose only program is /opt/decos/chooser.sh. Pressing 1, 2 or 3
#         boots RT-11 V5.3, RSX-11M V4.2 or RSTS/E V9.6 under Open SIMH.
# TYPE  : "emulator bridge" tile — overlay + per-tile /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` taken AT THE CHOOSER with NO simulator running
#         (resetMode=loadvm). Traps below; measurements in the guest doc.
#
# ONE TILE, NOT THREE, because three near-identical green-on-black terminals
# differing only in the prompt read as one exhibit cloned by accident, and the
# chooser is the cheapest placard in the building. The pdp11-add.md warning that
# they "cannot share a golden if the device set differs" is about QEMU device
# sets; here that set belongs to the Debian kiosk and never changes.
# SIMH IS BUILT INTO THE OVERLAY (the amiga.sh precedent): the frozen base ships
# VICE/cap32/LinApple, not SIMH, so this builds Open SIMH pinned at a1f57fa3
# into the overlay. Every dependency is already there because the base builds
# VICE from source, so this runs no apt at all; 90 s in the guest. Debian's
# packaged simh is 3.8.1 without SDL video: never use it.
#
#   * RSTS/E's install tape does NOT boot from TK50/TU81 (`boot tq0` gives zero
#     console bytes on both). It is a nine-track image: `set tm enabled` +
#     `boot tm0` brings up "RSTS V9.6 (MT0) INIT V9.6-11" first time. And it
#     refuses a 21st-century date, and refuses INIT's own printed example:
#     "7-SEP-85" rejected, "31-DEC-90" accepted. The exhibit pins 1990.
#   * RT-11 CANNOT BE IDLE-DETECTED (SIMH's idle fires on WAIT, and its help says
#     so): 99% of a host core at a bare "."; `set throttle 1000K` gives 14% and
#     suits a 15 MHz J-11 anyway. RSX and RSTS do WAIT and idle at 0.7-4%.
#   * SIMH CATCHES SIGTERM and then spins at 100%; orphans need -KILL.
#   * `set cpu 11/70` REJECTS `nocis` and `set rha disabled`, the two lines the
#     widely-mirrored ak6dn 11/44 ini carries. They are not here.
#   * SIMH's EXPECT/SEND is used at RUN time; the BUILD drives a forkpty,
#     because EXPECT did not fire against the 2.11BSD boot prompt in recon.
#   * Nothing shells out to `import`: on a name miss it wedges the X server.
#
# Media: three archives staged by hand at /data/assets-staging/decos under the
# Mentec hobbyist grant (use and copy, NOT distribute); never committed, and the
# tile offers no download. HYGIENE: thin overlay, namespaced sockets, kills only
# by pidfile, idempotent, decos tile dir only.
# Usage: decos.sh [--force] [-h]   (DECOS_SKIP_RSTS=1 skips the long install)
# =============================================================================
set -euo pipefail
TILE=decos
VMID=229
UDP=54126
SSH_PORT=5829
MEM=768
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
STAGING=${DECOS_STAGING:-/data/assets-staging/decos}
TILE_DIR=/data/vms/streamhost/tiles/decos
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
SIMH_COMMIT=a1f57fa3738ed31148d31126ba1a7278ff845c6d
SIMH_URL=https://github.com/open-simh/simh.git
FORCE=0
SKIP_RSTS=${DECOS_SKIP_RSTS:-0}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h | --help)
      sed -n '2,53p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
  shift
done
log() { echo "[decos $(date +%H:%M:%S)] $*"; }
die() {
  echo "[decos] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
push() {
  scp -q -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -P "$SSH_PORT" "$1" "root@127.0.0.1:$2"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }
# Build-time forkpty driver. Directives: WAIT <regex>|<secs>, SEND <text, python
# escapes>, SLEEP <secs>, OVERRIDE <regex>|<reply>, AUTO <secs>|<stopregex>,
# EXIT. AUTO answers a DEC dialogue with its bracketed defaults (plus any
# OVERRIDE) because RSTS/E V9.6 asks ~60 questions whose defaults are the
# documented path, and aborts if one prompt is answered six times running.
# Regexes must never contain \r\n: SIMH emits LF-then-CR with 0x7f padding.
# Exit 1 if any WAIT or AUTO failed; the simulator is always shut down.
read -r -d '' SIMHDRV <<'EOS' || true
import os, pty, re, select, signal, sys, time
spath, lpath, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
log, buf, bad, over = open(lpath, "wb"), bytearray(), [], []
pid, fd = pty.fork()
if pid == 0:
    os.execvp(argv[0], argv)
# A DEC prompt: '?', ':' or the closing angle of a "<default>" hint, at the very
# END of the stream, so that prose containing a question mark never fires it.
PROMPT = re.compile(rb"(\?|:|>)[ \t]*$")
def pump(sec):
    end = time.time() + sec
    while time.time() < end:
        if not select.select([fd], [], [], 0.2)[0]: continue
        try: data = os.read(fd, 65536)
        except OSError: return False
        if not data: return False
        buf.extend(data); log.write(data); log.flush()
    return True
def seen(rx): return bool(rx.search(bytes(buf[-8000:])))
def wait(pat, sec):
    rx, end = re.compile(pat.encode(), re.S), time.time() + sec
    while time.time() < end and not seen(rx):
        if not pump(0.4): break
    return seen(rx)
def auto(sec, stop):
    srx = re.compile(stop.encode(), re.S) if stop else None
    end, prev, runs = time.time() + sec, "", 0
    while time.time() < end:
        n = len(buf)
        if not pump(1.5): return False
        if srx and seen(srx): return True
        if len(buf) != n: continue          # still talking; let it settle
        tail = bytes(buf[-200:])
        if not PROMPT.search(tail): continue
        # Match overrides on the PROMPT LINE ONLY: matching the whole tail kept
        # "Use template monitor?" matching after the dialogue had moved on, and
        # the installer looped while the driver reported progress.
        last = tail.rsplit(b"\n", 1)[-1]
        line = last.decode("latin1", "replace").strip()
        reply = next((t for rx, t in over if rx.search(last)), "\r")
        runs, prev = (runs + 1 if line == prev else 1), line
        if runs >= 6:
            sys.stderr.write("AUTO: stuck on %r\n" % line); return False
        sys.stderr.write("AUTO %-56s <- %r\n" % (line[-56:], reply))
        os.write(fd, reply.encode()); time.sleep(0.4)
    sys.stderr.write("AUTO: window expired without %r\n" % stop)
    return not srx
def unesc(t): return t.encode().decode("unicode_escape")
for raw in open(spath):
    line = raw.rstrip("\n")
    if not line or line.startswith("#"): continue
    verb, _, arg = line.partition(" ")
    if verb == "WAIT":
        pat, _, sec = arg.rpartition("|")
        ok = wait(pat, float(sec))
        sys.stderr.write("WAIT %-44r %s\n" % (pat, "ok" if ok else "TIMEOUT"))
        bad += [] if ok else [pat]
    elif verb == "SEND": os.write(fd, unesc(arg).encode("latin1")); time.sleep(0.25)
    elif verb == "SLEEP": pump(float(arg))
    elif verb == "OVERRIDE":
        pat, _, t = arg.partition("|")
        over.append((re.compile(pat.encode(), re.S), unesc(t)))
    elif verb == "AUTO":
        sec, _, stop = arg.partition("|")
        bad += [] if auto(float(sec), stop) else ["AUTO:" + stop]
    elif verb == "EXIT": break
    else: raise SystemExit("bad directive: %s" % line)
pump(2)
try: os.write(fd, b"\x05"); time.sleep(0.5); os.write(fd, b"quit\r"); pump(3)
except OSError: pass
for sig in (signal.SIGTERM, signal.SIGKILL):
    try: os.kill(pid, 0); os.kill(pid, sig)
    except OSError: break
    time.sleep(1.0)
try: os.waitpid(pid, os.WNOHANG)
except OSError: pass
log.close()
sys.exit(1 if bad else 0)
EOS
# The placard's rule is EXACTLY 80 '=' characters: its drawn width is the tile's
# readiness predicate AND its proof that no 80-column screen is clipped, so do
# not shorten it. The golden idles in the read at the bottom, no simulator.
read -r -d '' CHOOSER <<'EOS' || true
#!/bin/bash
# PDP-11 exhibit chooser (bridge tile 'decos'). Built by build-guests/tiles/decos.sh.
set -u
D=/opt/decos
W=/tmp/decos   # NOT /run: root-owned, and the kiosk runs as 'bridge'
mkdir -p "$W"
run() {
  local id=$1 pack=$2 name=$3
  if [ ! -s "$D/disks/$pack" ]; then
    printf '\n\n    %s is not installed on this exhibit.\n' "$name"
    printf '    See docs/guests/decos.md.  Press any key to go back.\n'
    read -rsn1 _
    return
  fi
  # Fresh sparse copy per visit; masters are 444, and cp copies the mode.
  cp --sparse=always -f "$D/disks/$pack" "$W/$pack" || return
  chmod 644 "$W/$pack"
  sed -e "s|@DISK@|$W/$pack|g" \
    -e "s|@RSXDATE@|$(date '+%H:%M %d-%b-%y' | tr '[:lower:]' '[:upper:]')|g" \
    "$D/ini/$id.ini" > "$W/$id.ini"
  clear
  /usr/local/bin/pdp11 "$W/$id.ini"
  rm -f "$W/$pack" "$W/$id.ini"
}
placard() {
  cat << 'PLACARD'

    d i g i t a l   P D P - 1 1              simulated by Open SIMH
================================================================================

    One machine.  Three of the operating systems DEC sold for it.


      1   RT-11 V5.3      single-user real-time monitor   11/73, RL02, prompt .

      2   RSX-11M V4.2    multi-user real-time executive  11/70, RD52, prompt >

      3   RSTS/E V9.6     multi-user timesharing system   11/70, RD54, prompt $
            its installer's last step wants a second "Library" tape that no
            longer exists anywhere, so it stops short: DCL answers, its
            packaged commands were never wired up.

    Press 1, 2 or 3.        Reset returns you to this screen.

PLACARD
}

while :; do
  clear
  placard
  read -rsn1 key
  case "$key" in
    1) run rt11 rt11.dsk "RT-11 V5.3" ;;
    2) run rsx rsx.dsk "RSX-11M V4.2" ;;
    3) run rsts rsts.dsk "RSTS/E V9.6" ;;
  esac
done
EOS
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# PDP-11 (decos) kiosk launcher. There is no window manager in the bridge base,
# so the terminal is sized by -geometry, not -fullscreen (which needs an EWMH
# WM): 80x31 at DejaVu Sans Mono 15 measures 960x760 of the 1024x768 root, and
# size 16 would want 1040 and clip column 80. The pkill reaps a simulator a
# previous session left behind, and needs SIGKILL: SIMH ignores SIGTERM.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
pkill -u "$(id -u)" -KILL -x pdp11 2> /dev/null || true
exec xterm -class DECOS -title decos -geometry 80x31+0+0 \
  -fa "DejaVu Sans Mono" -fs 15 \
  -fg "#33ff55" -bg "#000000" -cr "#33ff55" -bc -bcf 500 -bcn 500 \
  +sb -e /opt/decos/chooser.sh
EOS
read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (decos overlay). X with NO core pointer cursor
# (-nocursor): keyboard-only exhibit, and without it the xterm I-beam sits in
# the captured framebuffer forever.
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2> /dev/null || true
  setterm --cursor off 2> /dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS
# The three SIMH configurations live in assets/decos/{rt11,rsx,rsts}.ini, NOT in
# heredocs here: they are data, they are what the chooser and prep_rt11 read by
# name, and the file-size budget is not the place to lose them.
# PROVENANCE: RECOVERED FROM THE LIVE decos GUEST ON 2026-08-10, and they are
# authoritative for that reason. Until that day install_kiosk installed them into
# a DIRECTORY (see the note there), so no from-scratch build had ever put them
# where anything reads them, and the copies the running exhibit boots on had been
# hand-placed during the original bring-up. Their simulator directives turned out
# to match the old heredocs byte for byte; only the commentary had been lost.
ASSETS_DIR="${DECOS_ASSETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../assets/decos}"
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
    -name streamhost-decos -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp 2 -cpu host -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 -usb \
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
wait_ssh() {
  for _ in $(seq 1 60); do
    guest true 2>/dev/null && return 0
    sleep 3
  done
  die "bridge SSH did not become ready on 127.0.0.1:$SSH_PORT"
}
capture() {
  rm -f "$EVIDENCE/$1.ppm"
  hmp "screendump $EVIDENCE/$1.ppm" >/dev/null
  pnmtopng "$EVIDENCE/$1.ppm" >"$EVIDENCE/$1.png"
  log "framebuffer proof: $EVIDENCE/$1.png"
}
# Ready = the 80-column rule fully drawn. pnmcrop -verbose reports the black it
# would crop off each edge, i.e. the bounding box of everything lit; the rule is
# the widest thing on screen, so its right edge is both "the kiosk is up" and
# "no 80-column screen is clipped". An oversized font or a dead xterm fail it.
wait_for_chooser() {
  local crop l r
  for _ in $(seq 1 60); do
    if capture "$1" 2>/dev/null; then
      crop=$(pnmcrop -black -verbose "$EVIDENCE/$1.ppm" 2>&1 >/dev/null || true)
      l=$(echo "$crop" | sed -n 's/.*Cropping \([0-9]*\) pixels from the left.*/\1/p')
      r=$(echo "$crop" | sed -n 's/.*Cropping \([0-9]*\) pixels from the right.*/\1/p')
      if [ -n "$l" ] && [ -n "$r" ] && [ "$l" -lt 16 ] && [ "$r" -ge 1 ] && [ "$r" -le 124 ]; then
        log "chooser drawn: lit pixels span x=$l..$((1023 - r))"
        return 0
      fi
    fi
    sleep 3
  done
  die "the PDP-11 chooser never drew its full 80-column rule"
}
install_simh() {
  guest "command -v gcc make git pkg-config > /dev/null" ||
    die "the frozen bridge base is missing its build tools"
  guest "set -e
    mkdir -p /usr/local/src/simh && cd /usr/local/src/simh
    if [ ! -d .git ]; then git init -q .; git remote add origin $SIMH_URL; fi
    git fetch -q --depth 1 origin $SIMH_COMMIT
    git checkout -q FETCH_HEAD
    [ \"\$(git rev-parse HEAD)\" = $SIMH_COMMIT ] || { echo 'pin mismatch'; exit 1; }
    make pdp11 -j2 > /tmp/simh-build.log 2>&1
    install -m 755 BIN/pdp11 /usr/local/bin/pdp11" ||
    die "Open SIMH did not build in the overlay (guest /tmp/simh-build.log)"
  # Ask the BINARY, not the build log: a no-op `make` truncates the log.
  guest "ldd /usr/local/bin/pdp11 | grep -q libSDL2" ||
    die "SIMH built WITHOUT SDL video: libsdl2-dev missing from the frozen base"
  log "Open SIMH $SIMH_COMMIT built and installed in the overlay"
}
stage_media() {
  local f
  guest "mkdir -p /opt/decos/media /opt/decos/disks /opt/decos/ini /opt/decos/work"
  for f in rtv53swre.tar.Z rsx11m42.zip rsts_v9_6_install.zip; do
    [ -s "$STAGING/$f" ] || die "missing staged media: $STAGING/$f (see ASSETS-MANIFEST)"
    guest "[ -s /opt/decos/media/$f ]" 2>/dev/null || push "$STAGING/$f" "/opt/decos/media/$f"
  done
  push "$SIMHDRV_FILE" /opt/decos/simhdrv.py
  guest "cd /opt/decos/media && sha256sum -c -" <"$STAGING/SHA256SUMS" >/dev/null ||
    die "staged media failed its sha256 check inside the guest"
  log "media staged and hash-verified inside the overlay"
}
# RT-11's pack boots into DEC's install dialogue; answering NO to "automatic
# installation" writes the RT11FB bootstrap onto it, which is what makes it boot
# straight to ".". Byte-deterministic: same sha256 host-side and in the guest.
prep_rt11() {
  guest "set -e
    cd /opt/decos/work && rm -rf rt11 && mkdir rt11 && cd rt11
    zcat /opt/decos/media/rtv53swre.tar.Z | tar xf -
    install -m 644 Disks/rtv53_rl.dsk /opt/decos/disks/rt11.dsk
    install -m 444 Licenses/pdp11_license.txt /opt/decos/MENTEC-LICENSE.txt
    sed 's|@DISK@|/opt/decos/disks/rt11.dsk|' /opt/decos/ini/rt11.ini > prep.ini
    printf '%s\n' 'WAIT Welcome to RT-11 V5.3|180' \
      'WAIT Press the .RETURN. key when ready to continue|60' 'SEND \r' \
      'WAIT automatic installation procedure.|60' 'SEND NO\r' \
      'WAIT Press the .RETURN. key when ready to continue|60' 'SEND \r' \
      'WAIT RT-11FB  V05.03|180' 'SLEEP 6' 'EXIT' > prep.script
    python3 /opt/decos/simhdrv.py prep.script prep.log pdp11 prep.ini" ||
    die "RT-11 V5.3 did not reach its RT11FB monitor"
  log "RT-11 V5.3 pack prepared (boots straight to '.')"
}
# RSX-11M's TK50 kit is a two-stage restore: the tape boots DEC's Standalone
# Copy System, told MU: -> DU:, which runs BRU onto the RD52; the second run
# proves the result boots to MCR. ~30 s in the guest.
prep_rsx() {
  guest "set -e
    cd /opt/decos/work && rm -rf rsx && mkdir rsx && cd rsx
    unzip -oq /opt/decos/media/rsx11m42.zip
    rm -f /opt/decos/disks/rsx.dsk
    printf '%s\n' 'set cpu 11/70' 'set cpu 4M' 'set rq0 rd52' \
      'attach rq0 /opt/decos/disks/rsx.dsk' 'set tq tk50' \
      'attach -r tq0 /opt/decos/work/rsx/m42kit.tap' 'boot tq0' > prep.ini
    printf '%s\n' 'WAIT Enter first device:|180' 'SEND MU:\r' \
      'WAIT Enter second device:|60' 'SEND DU:\r' \
      'WAIT enter date and time|60' 'SEND \r' 'SLEEP 3' \
      'SEND TIM 10:00 08/09/90\r' 'SLEEP 4' 'SEND RUN BRU\r' \
      'WAIT BRU>|60' 'SEND /REW MU: DU:\r' 'WAIT BRU - Completed|1200' \
      'SLEEP 5' 'EXIT' > prep.script
    python3 /opt/decos/simhdrv.py prep.script prep.log pdp11 prep.ini
    sed -e 's|@DISK@|/opt/decos/disks/rsx.dsk|' -e 's|@RSXDATE@|10:00 09-AUG-90|' \
      /opt/decos/ini/rsx.ini > boot.ini
    printf '%s\n' 'WAIT RSX-11M V4.2 BL38|180' 'WAIT ACS SY:/BLKS|180' \
      'SLEEP 4' 'SEND TIM\r' 'SLEEP 4' 'EXIT' > boot.script
    python3 /opt/decos/simhdrv.py boot.script boot.log pdp11 boot.ini" ||
    die "the RSX-11M restore did not produce a pack that boots to MCR"
  log "RSX-11M V4.2 BL38 pack prepared and boot-verified"
}
# RSTS/E, the long one and the only step allowed to fail: INIT.SYS off a
# NINE-TRACK tape (tm0, NOT tq0), DSKINT an RD54, copy the system, reboot from
# the pack, then DEC's installation procedure, which AUTO answers with its
# defaults plus ALL packages. ~45 min. It ENDS at "Library device?": that last
# step wants a second RSTS/E Library tape nobody has, so the prompt IS the end.
prep_rsts() {
  guest "set -e
    cd /opt/decos/work && rm -rf rsts && mkdir rsts && cd rsts
    unzip -oq /opt/decos/media/rsts_v9_6_install.zip
    rm -f /opt/decos/disks/rsts.dsk
    printf '%s\n' 'set cpu 11/70' 'set cpu 4M' 'set rq0 rd54' \
      'attach rq0 /opt/decos/disks/rsts.dsk' 'set tm enabled' 'set tm0 format=tpc' \
      'attach -r tm0 rsts_v9_6_install.tap' 'boot tm0' > prep.ini
    {
      printf '%s\n' 'WAIT Today.s date|300' 'SEND 9-AUG-90\r' \
        'WAIT Current time|60' 'SEND 10:00 AM\r' 'WAIT new system disk|60' \
        'SEND \r' 'WAIT Disk.|60' 'SEND DU0\r' 'WAIT Pack ID|60' 'SEND RSTS96\r'
      for q in 'Pack cluster size' 'MFD cluster size' 'SATT.SYS base' \
        'Pre-extend directories' 'PUB, PRI, or SYS' '.1,1. cluster size' \
        '.1,2. cluster size' 'account base' 'Date last modified' \
        'New files first' 'Read-only'; do
        printf 'WAIT %s|60\nSEND \\\\r\n' \"\$q\"
      done
      printf '%s\n' 'WAIT Patterns|60' 'SEND 0\r' 'WAIT Erase Disk|60' 'SEND NO\r' \
        'WAIT Proceed .Y or N|120' 'SEND Y\r' 'WAIT Start timesharing|900' 'SEND \r' \
        'WAIT installation or an update|900' \
        'OVERRIDE Packages to install:|ALL\r' \
        'OVERRIDE from the Installation kit. <yes>|N\r' \
        'OVERRIDE password|SYSTEM\r' \
        'AUTO 12000|Library device' 'SLEEP 20' 'EXIT'
    } > prep.script
    python3 /opt/decos/simhdrv.py prep.script prep.log pdp11 prep.ini" || return 1
  log "RSTS/E V9.6 installed onto its RD54 pack"
}
# ONE EXPLICIT DESTINATION PER .ini, AND A `|| die`. `install a b c DIR/` keeps
# each source's BASENAME, so the three files landed as /opt/decos/ini/decos-*.ini
# while prep_rt11 and the chooser read /opt/decos/ini/<id>.ini — and because the
# guest command carried no `|| die`, this function logged "three .ini files
# installed" every time while installing nothing usable. Fixed 2026-08-10, after
# a from-scratch build died at "sed: can't read /opt/decos/ini/rt11.ini".
install_kiosk() {
  local d f n
  d=$(mktemp -d)
  printf '%s\n' "$CHOOSER" >"$d/chooser.sh"
  printf '%s\n' "$LAUNCH" >"$d/launch.sh"
  printf '%s\n' "$PROFILE" >"$d/bash_profile"
  for n in rt11 rsx rsts; do
    [ -s "$ASSETS_DIR/$n.ini" ] || die "missing SIMH config asset: $ASSETS_DIR/$n.ini"
    cp "$ASSETS_DIR/$n.ini" "$d/$n.ini"
  done
  for f in "$d"/*; do push "$f" "/tmp/decos-$(basename "$f")"; done
  rm -rf "$d"
  guest "set -e
    install -m 755 /tmp/decos-chooser.sh /opt/decos/chooser.sh
    install -m 755 /tmp/decos-launch.sh /etc/bridge/launch.sh
    install -m 644 -o bridge -g bridge /tmp/decos-bash_profile /home/bridge/.bash_profile
    install -m 644 /tmp/decos-rt11.ini /opt/decos/ini/rt11.ini
    install -m 644 /tmp/decos-rsx.ini /opt/decos/ini/rsx.ini
    install -m 644 /tmp/decos-rsts.ini /opt/decos/ini/rsts.ini
    rm -f /tmp/decos-*
    for n in rt11 rsx rsts; do [ -s /opt/decos/ini/\$n.ini ] || exit 1; done" ||
    die "the kiosk chooser/launcher/.ini files did not install into the overlay"
  log "kiosk chooser, launcher and three .ini files installed"
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
    update-grub > /dev/null 2>&1
    systemctl daemon-reload"
}
bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}
# Press "1" through QEMU's own input path, unpaced; require a simulator running
# afterwards and a screen that is no longer the chooser. Runs AFTER the bake
# against the restored fixture, so nothing it types can reach the golden.
keyboard_proof() {
  python3 /root/cdrv.py "$QMP" key 1 >/dev/null
  sleep 25
  capture keyboard-1-rt11
  guest "pgrep -u bridge -x pdp11 > /dev/null" ||
    die "pressing 1 did not start a simulator"
  cmp -s "$EVIDENCE/ready-before-golden.ppm" "$EVIDENCE/keyboard-1-rt11.ppm" &&
    die "pressing 1 left the chooser on screen"
  log "keyboard proof 1/2: '1' booted RT-11 under SIMH"
  hmp "loadvm golden" >/dev/null
  sleep 4
  wait_for_chooser golden-restored-after-keyboard
  guest "pgrep -u bridge -x pdp11 > /dev/null" &&
    die "the restored golden has a simulator running; it must idle at the chooser"
  log "keyboard proof 2/2: loadvm golden returned to the bare chooser"
}
# ---- main -------------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"
SIMHDRV_FILE=$(mktemp)
printf '%s\n' "$SIMHDRV" >"$SIMHDRV_FILE"
trap 'rm -f "$SIMHDRV_FILE"' EXIT
if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi
# DROP ANY EXISTING GOLDEN FIRST. A -loadvm boot restores the snapshot's DISK as
# well as its RAM, so a re-run would install the new kiosk files, then revert
# them, then bake the old fixture again while reporting PASS. Measured.
qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden &&
  qemu-img snapshot -d golden "$OVERLAY"
boot_tile
wait_ssh
install_simh
stage_media
install_kiosk # before the preps: they drive the very .ini files that ship
guest "[ -s /opt/decos/disks/rt11.dsk ]" 2>/dev/null || prep_rt11
guest "[ -s /opt/decos/disks/rsx.dsk ]" 2>/dev/null || prep_rsx
# RSTS/E is allowed to fail: the exhibit is shippable with two systems and a
# third chooser entry that says plainly it is not installed.
if [ "$SKIP_RSTS" -eq 0 ] && ! guest "[ -s /opt/decos/disks/rsts.dsk ]" 2>/dev/null; then
  prep_rsts || log "WARNING: RSTS/E V9.6 did not install; the chooser will say so"
fi
guest "chmod 444 /opt/decos/disks/*.dsk"
quiet_console
guest "pkill -u bridge -KILL -x pdp11 2> /dev/null || true
  sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1"
sleep 6
wait_for_chooser cold-boot-chooser
# One clean cold boot with the quiet console in force, then bake. Bake from a
# curated COLD boot, never from a screen that has carried verification output.
stop_qemu
"$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile # see lib/bridge-coldboot; golden is already dropped above, so no --skip-if-golden needed
boot_tile
wait_ssh
sleep 6
wait_for_chooser ready-before-golden
guest "pgrep -u bridge -x xterm > /dev/null" || die "the kiosk xterm is not running"
guest "pgrep -u bridge -x pdp11 > /dev/null" &&
  die "a simulator is running: the golden must idle at the chooser"
bake_golden
sleep 4
wait_for_chooser golden-restored
keyboard_proof
log "PASS: chooser fixture baked, restored, keyboard-driven. tile=$TILE" \
  "vmid=$VMID udp=$UDP ssh=$SSH_PORT mem=${MEM}M evidence=$EVIDENCE"
