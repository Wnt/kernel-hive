#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/pdp11.sh — build the DEC PDP-11/70 running 2.11BSD as a thin
# overlay on the frozen bridge base (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-13 (trixie) kiosk running Open SIMH's `pdp11` as a PDP-11/70
#         with 4 MB of core and an FP11, booting 2.11BSD off an MSCP pack into
#         a full-screen xterm dressed as green phosphor. streamhost captures
#         the Linux framebuffer like every other bridge tile (BRIDGE.md).
# TYPE  : "emulator bridge" tile. Overlay + per-tile /etc/bridge/launch.sh + an
#         INTERNAL qcow2 `golden` snapshot (resetMode=loadvm).
#         The oldest lineage in the collection and the ancestor of most of it:
#         every Unix tile descends from PDP-11 Unix, and openvms' VMS was
#         written by the team that had just finished RSX-11M for this machine.
#
# THE DEVIATION: SIMH IS BUILT INTO THE OVERLAY. The bridge base is FROZEN and
# ships no SIMH; Debian's package is 3.8.1 without SDL video and useless. So
# this script compiles Open SIMH from source INTO THE TILE'S OWN OVERLAY, as
# amiga.sh does for FS-UAE. Every dependency is already in the frozen base, so
# there is no apt-get here: 1 m 32 s at -j2 for one 2.8 MB binary. The matching
# bridge-base.sh addition for an NVMe rebuild is in docs/guests/pdp11.md.
#
# ---- TRAPS PAID FOR, IN THE ORDER THEY BIT ----------------------------------
#   1. `set cpu 11/70` REJECTS the two lines every 11/44 recipe on the internet
#      opens with: `nocis` ("The CIS option can't be disabled on a 11/70 CPU")
#      and `set rha disabled` ("Command not allowed"). Neither is in the ini.
#   2. `set cpu idle` COSTS THE EXHIBIT ITS RESET, so this tile does not use
#      it. It is the standard answer to SIMH burning a whole host core, and it
#      works beautifully — 2.37% at an idle login prompt instead of 100% — but
#      idle detection rides on SIMH's calibrated timer, and a savevm/loadvm
#      cycle destroys that calibration PERMANENTLY: after restoring a snapshot
#      120 s old, one keystroke took 38-80 s to echo and it never recovered
#      over three further rounds. Measured on this tile, 120 s-old snapshot,
#      echo latency after `loadvm` / CPU at an idle prompt:
#         set cpu idle        never echoed (38-80 s+)   2.4%
#         nothing at all      0.5 s                   100.1%
#         set throttle 1200k  0.5 s                    59.0%   (~real 11/70)
#         set throttle 10%    0.5 s                    19.7%   <- shipped
#         set throttle 5%     0.4 s                     7.9%   (visibly slow)
#      The tile ships `set throttle 10%` + `set timer nocatchup`: a reset stays
#      instant, and the cost is a fifth of a core rather than a whole one.
#   3. SIMH's console emits LF-then-CR with 0x7f padding (`\n\r\x7f`), NOT
#      CRLF. Every expect regex written `\r\n` silently never matches.
#   4. SIMH's own EXPECT/SEND did not fire against 2.11BSD's boot block, so the
#      dialogue is walked by a forkpty driver that then becomes a transparent
#      relay — which also lets a COLD boot reach the fixture with zero input.
#   5. The simulator runs in its OWN session (setsid, so a visitor's ^C reaches
#      2.11BSD as a byte instead of killing the driver), so a signal aimed at
#      the driver ORPHANS it. Two orphaned simulators sharing one pack printed
#      `ra0a: hard error sn36 status 20006` and a kernel dump onto the exhibit.
#   6. THE KIOSK RUNS AS `bridge`, NOT root. A root-owned 0644 pack attaches
#      READ-ONLY and 2.11BSD panics identically to trap 5 on its first write.
#   7. xterm's `-fs` is POINTS at ~96 dpi, not pixels: -fs 21 measured 17.4 px
#      per column — an 80-column window 1392 px wide whose right-hand end fell
#      off the 1024 px root. -fs 15 measures 12.05 px/col and 24.0 px/row.
#   8. THE EXPENSIVE ONE. SIMH's makefile auto-detects libpthread and builds
#      with -DSIM_ASYNCH_IO -DUSE_READER_THREAD, and that build DEADLOCKS
#      ACROSS `loadvm`: after a restore both simulator threads sit in
#      futex_wait burning 0 CPU ticks per 20 s, so every keystroke vanishes
#      while the exhibit looks perfectly healthy — right framebuffer, live
#      xterm, X focus correct, QEMU's i8042 interrupt counter still ticking.
#      Chasing it through X focus and PS/2 first cost an hour. The tile builds
#      with `make pdp11 AIO_CCDEFS=` (a command-line variable overrides every
#      `+=` in the makefile), which drops both flags; the simulator is then
#      single-threaded, survives savevm/loadvm, and idles at 0 ticks/10 s. The
#      builder ASSERTS the thread count, because a rebuilt-with-defaults binary
#      would pass every other check here.
#
# KEY PACING: THERE IS NONE, AND THAT IS MEASURED. Playbook 5.1's frame-
# sampling trap does not apply inside the simulator — a SIMH console is a byte
# stream, and a 69-character line at a 0 ms inter-character gap echoed and
# executed intact 5/5. Only the bridge PS/2 -> X -> xterm path remains, and
# 40/40 through QMP delivered `root`, `uname -a` and `ls /usr/src` losing
# nothing (the keyboard proof below IS that test), so the tile ships 40/40
# rather than vic20/plus4's 80/80 and needs no canary streamhost build.
#
# THE GOLDEN RESTS AT 2.11BSD'S OWN `login:`, not at a logged-in root shell:
# that is where an unattended cold boot stops, the banner above it names the
# system, and it is the only state a visitor cannot arrive in the middle of. A
# baked shell would be a state a human typed into and would hand the next
# visitor whatever the last one left running. The one thing the screen cannot
# say — root, no password — is on the placard, in the SPA hint and in
# SH_FIXTURE_DESC, and the keyboard proof walks exactly that route.
#
# WHAT WAS CURATED ON THE PACK: it expects a DZ11 mux and a DEUNA Ethernet
# board this 11/70 does not have, so the console was overprinted with seven
# `getty: /dev/tty0N: Device not configured`, `ifconfig: no such interface`,
# and — every 60 s, for ever — `ntpd: sendto: Network is unreachable`. Four
# edits, all ordinary 2.11BSD site configuration for the hardware present:
# /etc/ttys tty00-07 off, /etc/dtab dz/rx/tms/cn commented, /etc/netstart
# INET=NO, /etc/rc.local ntpd off. /usr/src is untouched — the whole kernel and
# userland source tree is half the point of the exhibit. docs/guests/pdp11.md
# has the before/after console transcripts.
#
# HYGIENE: thin overlay, namespaced qmp.sock/pidfile, kills only by pidfile,
# idempotent, --force rebuilds. Touches ONLY the pdp11 tile dir; refuses to run
# while streamhost@pdp11 is active.
#
# Usage: pdp11.sh [--force] [-h]
# =============================================================================
set -euo pipefail

TILE=pdp11
VMID=227
UDP=54115
SSH_PORT=5827
WEB_PORT=8127
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/tiles/pdp11
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
STAGE="$TILE_DIR/media"
TYPE_DRIVER="$TILE_DIR/type-qmp.py"
SIMH_PIN=a1f57fa3738ed31148d31126ba1a7278ff845c6d # Open SIMH master, 2026-07-03
# 512 MB, not the 1536 the VICE/MAME bridge tiles use. Measured in-guest at the
# login prompt with everything running: MemTotal 468 MB, MemAvailable 338 MB,
# simulator RSS 21 MB. (At 768 MB: MemAvailable 408 MB, host QEMU RSS 859 MB;
# at 512 MB, host QEMU RSS 591 MB. The simulated PDP-11 is 4 MB of core.)
MEM=512

# 2.11BSD (1991, UCB) prebuilt MSCP pack. PRESERVATION SOURCE: 2.11BSD predates
# the Net/2 split, is NOT covered by the Caldera 2002 Ancient-Unix letter, and
# this prebuilt image carries no licence statement. Streamed as pixels only:
# never committed, never served, no download affordance anywhere in the tile.
# simh.trailing-edge.com (which every howto links) has been Cloudflare-dead
# since at least 2026-08-09; this is Don North's kit on GitHub Pages. Hashes
# measured on the box 2026-08-09.
MEDIA_URL="https://ak6dn.github.io/PDP-11/2.11BSD/2.11BSD_rq.dsk.zip"
MEDIA_ZIP_SHA=94abeca02f001619e7aa2252cb2336ffe79af0cb3fb35cbd8c14240af3125a6b
MEDIA_DSK_SHA=2f100ee585f229fd55923e1d1c44108e72df96f649f28a31df35985e6a481805

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

log() { echo "[pdp11 $(date +%H:%M:%S)] $*"; }
die() {
  echo "[pdp11] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o ConnectTimeout=8 -o ServerAliveInterval=30 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

read -r -d '' PDP11_INI <<'EOS' || true
; Open SIMH configuration for the museum's PDP-11/70 running 2.11BSD.
; A REAL 11/70: 4 MB of core (the model's 22-bit maximum) and the FP11.
; Do NOT copy the circulated ak6dn 11/44 ini: on an 11/70 SIMH REJECTS both
; `nocis` ("The CIS option can't be disabled") and `set rha disabled`.
set cpu 11/70 4096K fpp
; NOT `set cpu idle`, however tempting. Idle detection rides on SIMH's
; calibrated timer and a savevm/loadvm cycle destroys that calibration for
; good: after restoring a 120 s-old golden, one keystroke took 38-80 s to echo
; and never recovered. Throttling instead survives the restore (0.5 s echo) and
; still keeps the simulator off a whole host core: measured 19.7% of one core
; at an idle 2.11BSD login prompt, against 100.1% with no limit at all.
; NOCATCHUP stops SIMH trying to make up the simulated clock ticks it thinks it
; owes for the wall-clock gap the snapshot restore invented.
set throttle 10%
set timer nocatchup
; One console terminal on one MSCP disk. Everything the 2.11BSD ZEKE kernel
; would otherwise probe for is switched off explicitly, so this file IS the
; machine's device list. No Ethernet (/etc/netstart is set to match, INET=NO).
set ptr disabled
set ptp disabled
set lpt disabled
set cr disabled
set rp disabled
set rk disabled
set rl disabled
set rx disabled
set ry disabled
set tm disabled
set ts disabled
set tq disabled
set hk disabled
set vh disabled
set dz disabled
set xu disabled
set xq disabled
; 7-bit console: 2.11BSD is 7-bit ASCII and an 8-bit console passes the high
; bit through as mojibake in an xterm.
set tto 7b
set rq enabled
set rq0 RAUSER=1000
attach rq0 media/2.11BSD_rq.dsk
boot rq0
EOS

# The one guest-side driver: walks 2.11BSD's boot dialogue, then either relays
# the exhibit's terminal (no PDP11_SCRIPT) or runs a build-time command script.
read -r -d '' CONSOLE_PY <<'EOS' || true
#!/usr/bin/env python3
"""Run Open SIMH's PDP-11 on a pty, walk 2.11BSD's boot dialogue, get out of the way.

WHY NOT SIMH'S OWN EXPECT/SEND: 2.11BSD's boot block asks two questions an
operator answered by hand -- the `:` bootstrap prompt and single-user's `#`
(^D for multiuser) -- and SIMH's EXPECT did not fire against either (recon
2026-08-09). A forkpty driver worked first time, and it is also what lets a
COLD boot reach the exhibit's fixture with zero visitor input.

WHY THE REGEXES LOOK ODD: SIMH's console emits LF-then-CR with 0x7f padding
(`\n\r\x7f`), not CRLF. Patterns written `\r\n` never match.

With PDP11_SCRIPT set (build time only) it logs in, runs that file's lines and
sync/halt/quits so the pack is left clean. Without it (the exhibit) it becomes
a byte-for-byte relay between the kiosk's xterm and the simulator, so nothing
reaches the screen that the machine did not print itself.
"""
import fcntl, os, pty, re, select, signal, subprocess, sys, termios, time, tty  # noqa: E401

CWD = "/opt/pdp11"
ARGV = [CWD + "/bin/pdp11", CWD + "/pdp11.ini"]
SCRIPT, LOG = os.environ.get("PDP11_SCRIPT", ""), os.environ.get("PDP11_LOG", "")
BOOTCMD = "ra(0,0,0)unix"  # the bootstrap's default kernel, typed in full
buf = ""

isatty = sys.stdin.isatty()
mfd, sfd = pty.openpty()
if isatty:
    try:
        fcntl.ioctl(mfd, termios.TIOCSWINSZ,
                    fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, b"\0" * 8))
    except OSError:
        pass
proc = subprocess.Popen(ARGV, cwd=CWD, stdin=sfd, stdout=sfd, stderr=sfd,
                        close_fds=True, preexec_fn=os.setsid)
os.close(sfd)
log = open(LOG, "wb", 0) if LOG else None


# The simulator gets its OWN session so a ^C typed at the exhibit reaches
# 2.11BSD as a byte instead of killing this process -- which also means a
# signal aimed at US orphans it, still holding the pack open. Two orphaned
# simulators on one pack panicked the kernel with `ra0a: hard error sn36
# status 20006`. Always take the whole process group down with us.
def killgroup(*_a):
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except OSError:
        pass
    os._exit(143)


signal.signal(signal.SIGTERM, killgroup)
signal.signal(signal.SIGHUP, killgroup)


def pump(timeout):
    global buf
    if not select.select([mfd], [], [], timeout)[0]:
        return False
    try:
        data = os.read(mfd, 65536)
    except OSError:
        return False
    if not data:
        return False
    if not SCRIPT:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    if log:
        log.write(data)
    buf = (buf + data.decode("latin-1"))[-65536:]
    return True


def expect(pattern, timeout):
    global buf
    rx, deadline = re.compile(pattern), time.time() + timeout
    while time.time() < deadline:
        m = rx.search(buf)
        if m:
            buf = buf[m.end():]
            return True
        pump(0.5)
    return False


def send(text):
    os.write(mfd, text.encode("latin-1"))


def drain(secs):
    end = time.time() + secs
    while time.time() < end:
        pump(0.2)


ok = expect(r"[\n\r\x7f]+: ", 180)
if ok:
    send(BOOTCMD + "\r")
    ok = expect(r"[\n\r\x7f]+# ", 600)
if ok:
    send("\004")  # ^D leaves single user for multiuser
    ok = expect(r"login: ", 900)

if SCRIPT:
    if not ok:
        raise SystemExit("2.11BSD never reached its login prompt")
    drain(6)
    send("root\r")
    expect(r"[\n\r\x7f]+# ", 120)
    drain(4)
    for line in open(SCRIPT):
        if line.strip():
            buf = ""
            send(line.rstrip("\n") + "\r")
            expect(r"[\n\r\x7f]+# ", 180)
            drain(1)
    send("sync\r")
    drain(3)
    send("halt\r")
    drain(20)
    send("quit\r")
    drain(5)
    killgroup()

saved = None
if isatty:
    saved = termios.tcgetattr(sys.stdin.fileno())
    tty.setraw(sys.stdin.fileno())
try:
    fds = [mfd] + ([sys.stdin.fileno()] if isatty else [])
    while proc.poll() is None:
        r = select.select(fds, [], [], 0.5)[0]
        if mfd in r and not pump(0):
            break
        if isatty and sys.stdin.fileno() in r:
            data = os.read(sys.stdin.fileno(), 4096)
            if not data:
                break
            os.write(mfd, data)
finally:
    if saved is not None:
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, saved)
    if log:
        log.close()
    killgroup()
EOS

# Host-side QMP typist for the post-bake keyboard proof. Deliberately covers
# only the unshifted ASCII the proof needs: `labctl type` is not a fair test of
# this path (it drops characters while printing "ok"), so the proof owns its
# own typist and its own explicit hold/gap pacing.
read -r -d '' TYPE_PY <<'EOS' || true
#!/usr/bin/env python3
"""Type ASCII into this tile over QMP, with explicit pacing.

Exercises the exhibit's ONLY input path: browser -> streamhost -> QEMU PS/2
keyboard -> X -> xterm -> the simulator's console pty.
Usage: type-qmp.py <qmp.sock> <hold_ms> <gap_ms> <text>   (\\n = RETURN)
"""
import json, socket, sys, time  # noqa: E401

QCODE = {" ": "spc", "-": "minus", ".": "dot", "/": "slash", "\n": "ret"}
sock = socket.socket(socket.AF_UNIX)
sock.settimeout(30)
sock.connect(sys.argv[1])
conn = sock.makefile("rwb")
conn.readline()
hold, gap = int(sys.argv[2]) / 1000.0, int(sys.argv[3]) / 1000.0


def cmd(payload):
    conn.write((json.dumps(payload) + "\n").encode())
    conn.flush()
    while True:
        msg = json.loads(conn.readline())
        if "error" in msg:
            raise SystemExit("QMP error: %s" % msg)
        if "return" in msg:
            return


cmd({"execute": "qmp_capabilities"})
for ch in " ".join(sys.argv[4:]).replace("\\n", "\n"):
    code = ch if ch.isalnum() else QCODE.get(ch)
    if code is None:
        raise SystemExit("no qcode for %r" % ch)
    for down in (True, False):
        cmd({"execute": "input-send-event", "arguments": {"events": [
            {"type": "key", "data": {"down": down,
                                     "key": {"type": "qcode", "data": code}}}]}})
        time.sleep(hold if down else gap)
EOS

read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# DEC PDP-11/70 + 2.11BSD kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/pdp11.sh for the rationale behind every choice.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
# The X root stays at the bridge base's default 1024x768: unlike the VICE/MAME
# tiles there is no fixed-size SDL window to fit -- the terminal is sized in
# CHARACTERS and the root is simply the black surround.
xsetroot -solid black 2>/dev/null || true
# 80x24 is the VT100 the machine believes it is talking to (/etc/ttys gives the
# console `vt100`, and 2.11BSD cannot learn otherwise over a DL11 serial line).
# A taller window would leave vi(1) painting only its top 24 rows, so the
# window matches the terminal instead and the boot text scrolls off the top
# exactly as it did on real glass.
# xterm's -fs is POINTS at ~96 dpi, not pixels: -fs 21 measured 17.4 px per
# column, an 80-column window 1392 px wide whose right-hand end fell off the
# 1024 px root. -fs 15 measures 12.05 px/col and 24.0 px/row => 964x576, which
# +30+96 centres. Re-measure on the framebuffer if the font ever changes.
# THERE IS NO WINDOW MANAGER, so X's focus is PointerRoot: keystrokes go to
# whatever window the CORE POINTER happens to be over. This guest parks the
# pointer at (0,0), OUTSIDE a centred 80x24 window, and every keystroke was
# swallowed by the root window while the exhibit looked perfectly healthy --
# QEMU's i8042 interrupt counter proved the scancodes reached the guest kernel,
# and nothing at all reached the terminal. Park the pointer inside the window
# and set the focus explicitly, once the window has actually mapped.
(
  for _ in $(seq 1 60); do
    xdotool search --class XTerm >/dev/null 2>&1 && break
    sleep 0.5
  done
  xdotool mousemove 512 384 2>/dev/null || true
  xdotool search --class XTerm windowfocus 2>/dev/null || true
) &
exec xterm \
  -geometry 80x24+30+96 \
  -fa 'DejaVu Sans Mono' -fs 15 \
  -bg '#000000' -fg '#33ff33' -cr '#33ff33' \
  -b 0 -bw 0 +sb -sl 512 \
  -xrm 'XTerm*cursorBlink: true' \
  -title 'PDP-11/70' \
  -e /usr/bin/env PDP11_LOG=/tmp/pdp11-console.log /opt/pdp11/pdp11-console.py
EOS

read -r -d '' PROFILE <<'EOS' || true
# Bridge kiosk session (pdp11 overlay). Start X with NO core pointer cursor
# (-nocursor: keyboard-only exhibit; the core pointer would otherwise sit
# frozen mid-screen on top of the terminal).
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  setterm --msg off 2>/dev/null || true
  setterm --cursor off 2>/dev/null || true
  clear
  exec startx -- -nocursor
fi
EOS

# 2.11BSD site configuration for the hardware this 11/70 actually has.
read -r -d '' CURATE <<'EOS' || true
sed -e '/^tty0[0-7]/s/on secure/off secure/' /etc/ttys > /tmp/a
cp /tmp/a /etc/ttys
sed -e '1,/testnet/s/^INET=.*/INET=NO/' /etc/netstart > /tmp/b
cp /tmp/b /etc/netstart
sed -e 's/^ntpd$/#ntpd/' /etc/rc.local > /tmp/c
cp /tmp/c /etc/rc.local
sed -e '/^dz/s/^/#/' -e '/^rx/s/^/#/' -e '/^tms/s/^/#/' -e '/^cn/s/^/#/' /etc/dtab > /tmp/d
cp /tmp/d /etc/dtab
rm -f /tmp/a /tmp/b /tmp/c /tmp/d
echo CURATED-MARKER
echo TTYS-OFF-`grep -c 'off secure' /etc/ttys`
echo NET-`grep '^INET=' /etc/netstart`
echo NTPD-`tail -1 /etc/rc.local`
EOS

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
    -name streamhost-pdp11 \
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

# Green phosphor on the captured framebuffer. A bare X root, a dead xterm and a
# simulator that never started all measure ~0; the login screen measures ~22k.
green_ink() {
  ppmhist "$EVIDENCE/$1.ppm" 2>/dev/null |
    awk '$2 > 120 && $1 < 120 && $3 < 160 { sum += $5 } END { print sum + 0 }'
}

# Readiness has TWO independent halves and both can fail: the simulator's own
# transcript must reach `login: ` and be free of the panic a read-only or
# shared pack produces (which looks like a healthy exhibit from outside), and
# the captured FRAMEBUFFER must carry a terminal's worth of green.
PDP11_MIN_INK=${PDP11_MIN_INK:-12000}
wait_for_login() {
  local ink ready=0
  for _ in $(seq 1 90); do
    if guest "grep -q 'login: ' /tmp/pdp11-console.log" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 4
  done
  [ "$ready" -eq 1 ] || die "2.11BSD never reached login (guest /tmp/pdp11-console.log)"
  if guest "grep -Eq 'hard error|panic|dumping to dev' /tmp/pdp11-console.log" 2>/dev/null; then
    guest "tail -20 /tmp/pdp11-console.log" >&2 || true
    die "2.11BSD panicked on the pack (read-only image, or two simulators on one disk)"
  fi
  sleep 4
  capture "$1"
  ink=$(green_ink "$1")
  [ "$ink" -gt "$PDP11_MIN_INK" ] ||
    die "the captured framebuffer carries no terminal (green ink=$ink)"
  log "at the 2.11BSD login prompt (green ink=$ink)"
}

restart_kiosk() {
  guest "systemctl stop getty@tty1 || true
    sleep 2
    for p in \$(pgrep -x pdp11); do
      [ \"\$(readlink /proc/\$p/exe)\" = /opt/pdp11/bin/pdp11 ] && kill -9 \$p
    done
    rm -f /tmp/pdp11-console.log
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
}

bake_golden() {
  hmp "savevm golden" >/dev/null
  qemu-img snapshot -l "$OVERLAY" | grep -qw golden ||
    die "savevm golden did not land in $OVERLAY"
  hmp "loadvm golden" >/dev/null
  log "golden snapshot baked and restore-verified"
}

# The keyboard proof runs AFTER the bake, against the restored fixture, so
# nothing it types can reach the golden. It walks the ONLY route the placard
# advertises -- root, no password -- then two commands that could not work
# anywhere but a real Unix, and asserts each from what the machine printed.
# Asserting merely "the framebuffer changed" would pass with a panicked kernel.
keyboard_proof() {
  python3 "$TYPE_DRIVER" "$QMP" 40 40 'root\n'
  sleep 10
  python3 "$TYPE_DRIVER" "$QMP" 40 40 'uname -a\n'
  sleep 8
  python3 "$TYPE_DRIVER" "$QMP" 40 40 'ls /usr/src\n'
  sleep 10
  capture keyboard-root-shell
  guest "grep -q 'BSD pdp11 2.11' /tmp/pdp11-console.log" ||
    die "root/no-password login + uname -a did not reach a 2.11BSD shell"
  guest "grep -q 'asm.sed.pdp' /tmp/pdp11-console.log" ||
    die "ls /usr/src did not list the 2.11BSD source tree"
  log "keyboard proof: root (no password) -> uname -a -> ls /usr/src, nothing lost"
}

# ---- preflight ---------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE" "$STAGE"
printf '%s\n' "$TYPE_PY" >"$TYPE_DRIVER"
chmod 755 "$TYPE_DRIVER"

# ---- stage the pack ONCE, on the host, hash-gated ----------------------------
# DEC media sourcing is fragile and the box has NO working IPv6 egress, so the
# curl needs -4 or it hangs 40 s on the AAAA record. The bits are staged here,
# outside the overlay, so --force never re-fetches them.
if [ ! -s "$STAGE/2.11BSD_rq.dsk.zip" ] ||
  [ "$(sha256sum "$STAGE/2.11BSD_rq.dsk.zip" | cut -d' ' -f1)" != "$MEDIA_ZIP_SHA" ]; then
  log "fetching the 2.11BSD pack (one-shot; never committed, never served)"
  curl -4 -sSL --max-time 900 -o "$STAGE/2.11BSD_rq.dsk.zip" "$MEDIA_URL" ||
    die "could not fetch $MEDIA_URL"
  [ "$(sha256sum "$STAGE/2.11BSD_rq.dsk.zip" | cut -d' ' -f1)" = "$MEDIA_ZIP_SHA" ] ||
    die "2.11BSD_rq.dsk.zip sha256 mismatch (expected $MEDIA_ZIP_SHA)"
fi
log "2.11BSD pack staged and hash-verified: $STAGE/2.11BSD_rq.dsk.zip"

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
  # Assert the base's build dependencies instead of apt-get: a missing one
  # should fail loudly here, not reach out to the network from a museum tile.
  guest "command -v gcc make git xterm xsetroot unzip >/dev/null &&
    [ -f /usr/include/SDL2/SDL.h ]" ||
    die "the bridge base is missing a SIMH build dependency or xterm"
  # xdotool IS missing from the frozen base and the kiosk cannot focus its
  # terminal without it (see the launcher). Installed into the overlay, like
  # amiga.sh installs fs-uae; bridge-base.sh should bake it in (docs/guests).
  if ! guest "command -v xdotool >/dev/null"; then
    log "installing xdotool into the overlay (window focus; not in the base)"
    guest "export DEBIAN_FRONTEND=noninteractive
      apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1
      apt-get install -y xdotool >>/tmp/apt.log 2>&1
      command -v xdotool >/dev/null" ||
      die "could not install xdotool into the overlay (guest /tmp/apt.log)"
  fi

  log "building Open SIMH ($SIMH_PIN) into the overlay — about 95 s"
  guest "set -e
    mkdir -p /opt/pdp11/bin /opt/pdp11/media /opt/pdp11/src
    cd /opt/pdp11/src && rm -rf simh && mkdir simh && cd simh
    git init -q .
    git remote add origin https://github.com/open-simh/simh.git
    git fetch -q --depth 1 origin $SIMH_PIN
    git checkout -q FETCH_HEAD
    make pdp11 AIO_CCDEFS= -j2 > /tmp/simh-build.log 2>&1
    cp BIN/pdp11 /opt/pdp11/bin/pdp11" ||
    die "Open SIMH build failed (guest /tmp/simh-build.log)"
  guest "test -x /opt/pdp11/bin/pdp11" || die "no /opt/pdp11/bin/pdp11 after the build"
  guest "grep -q 'SIM_ASYNCH_IO' /tmp/simh-build.log && exit 1 || exit 0" ||
    die "SIMH was built with SIM_ASYNCH_IO — it will deadlock across loadvm (trap 8)"
  log "Open SIMH built: $(guest 'stat -c %s /opt/pdp11/bin/pdp11') bytes, no async I/O"

  log "installing the pack, the ini and the console driver"
  scp -q -i "$KEY" -o StrictHostKeyChecking=no -P "$SSH_PORT" \
    "$STAGE/2.11BSD_rq.dsk.zip" root@127.0.0.1:/opt/pdp11/media/ ||
    die "could not copy the 2.11BSD pack into the guest"
  # The kiosk runs as `bridge`: a root-owned pack attaches READ-ONLY and
  # 2.11BSD panics the first time it writes /etc/utmp.
  guest "set -e
    cd /opt/pdp11/media
    unzip -o -q 2.11BSD_rq.dsk.zip && rm -f 2.11BSD_rq.dsk.zip
    [ \"\$(sha256sum 2.11BSD_rq.dsk | cut -d' ' -f1)\" = '$MEDIA_DSK_SHA' ]
    chown -R bridge:bridge /opt/pdp11/media" ||
    die "the unpacked 2.11BSD pack did not match sha256 $MEDIA_DSK_SHA"
  printf '%s\n' "$PDP11_INI" | guest "cat > /opt/pdp11/pdp11.ini"
  printf '%s\n' "$CONSOLE_PY" |
    guest "cat > /opt/pdp11/pdp11-console.py && chmod 755 /opt/pdp11/pdp11-console.py"
  printf '%s\n' "$CURATE" | guest "cat > /opt/pdp11/curate.cmds"

  log "curating the pack for the hardware this 11/70 has (ttys/dtab/netstart/ntpd)"
  guest "cd /opt/pdp11 &&
    PDP11_SCRIPT=/opt/pdp11/curate.cmds PDP11_LOG=/tmp/curate.log \
      python3 pdp11-console.py < /dev/null > /dev/null 2>&1
    grep -q CURATED-MARKER /tmp/curate.log &&
    grep -q 'TTYS-OFF-8' /tmp/curate.log &&
    grep -q 'NET-INET=NO' /tmp/curate.log &&
    grep -q 'NTPD-#ntpd' /tmp/curate.log" ||
    die "the 2.11BSD curation did not take (guest /tmp/curate.log)"
  guest "pgrep -x pdp11 >/dev/null && exit 1 || exit 0" ||
    die "a simulator survived the curation session — it would corrupt the pack"
  log "2.11BSD curated: 8 console lines off, INET=NO, ntpd off, dtab trimmed"

  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  quiet_console
  restart_kiosk
  wait_for_login cold-boot-login
fi

# One clean cold boot with the quiet console in force, then bake the golden
# from the very state SPA reset restores for ever after. Bake from an UNTOUCHED
# cold boot: the mpf2 add shipped a golden carrying its own verification output
# and had to be re-baked.
stop_qemu
boot_tile
wait_for_ssh
restart_kiosk
wait_for_login ready-before-golden
guest "pgrep -x pdp11 >/dev/null" || die "the simulator exited after cold boot"
# Trap 8's tripwire: an async-I/O build has 3+ threads and deadlocks on the
# first reset, hours after this script has reported success.
guest "[ \"\$(ls /proc/\$(pgrep -x pdp11)/task | wc -l)\" = 1 ]" ||
  die "the simulator is multi-threaded (async I/O build) — it will deadlock across loadvm"

# What `set throttle 10%` costs, measured rather than asserted: an unthrottled
# simulator sits at 100.1% of a host core for ever.
IDLE_PCT=$(guest "P=\$(pgrep -x pdp11)
  A=\$(awk '{print \$14+\$15}' /proc/\$P/stat); sleep 20
  B=\$(awk '{print \$14+\$15}' /proc/\$P/stat)
  awk -v a=\$A -v b=\$B 'BEGIN{printf \"%.2f\", (b-a)/100/20*100}'")
log "simulator CPU at the idle login prompt: ${IDLE_PCT}% of one core (20 s)"
awk -v p="$IDLE_PCT" 'BEGIN { exit !(p < 35) }' ||
  die "the simulator is burning ${IDLE_PCT}% of a core — is 'set throttle' in the ini?"
guest "awk '/MemAvailable/ {print \"guest MemAvailable: \" \$2 \" kB\"}' /proc/meminfo"
guest "awk '/MemAvailable/ {exit !(\$2 > 200000)}' /proc/meminfo" ||
  die "guest MemAvailable fell below 200 MB at ${MEM} MB of RAM — raise MEM"

capture golden-frame
bake_golden
sleep 4
capture golden-restored
[ "$(green_ink golden-restored)" -gt "$PDP11_MIN_INK" ] ||
  die "the restored golden framebuffer is not a terminal"

keyboard_proof

hmp "loadvm golden" >/dev/null
sleep 4
capture golden-restored-after-keyboard
[ "$(green_ink golden-restored-after-keyboard)" -gt "$PDP11_MIN_INK" ] ||
  die "the fixture did not come back after the keyboard proof"

log "PASS: PDP-11/70 at 2.11BSD's login prompt, root route proven, golden baked"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT mem=${MEM}M evidence=$EVIDENCE"
