#!/usr/bin/env bash
###############################################################################
# build-guests/os2warp.sh — reproduce the IBM OS/2 Warp 4 gallery guest
#                           FROM SOURCE on a fresh Proxmox host.
#
# GUEST : IBM OS/2 Warp 4 (1996, "Merlin") — the Workplace Shell tile (:8108).
# TYPE  : PREBUILT-IMAGE + AUTOMATED FIRST-BOOT TAMING + AGENT/GOLDEN BAKE.
#         Exactly like the project's Win311 / Win95 tiles, this does NOT run the
#         OS/2 installer (an unattended OS/2 install under QEMU is multi-reboot,
#         FDISK-driven and notoriously fragile). Instead it consumes a community
#         PRE-INSTALLED OS/2 Warp 4.0 qcow2 from the Internet Archive and then
#         prepares it into a clean, museum-ready golden image:
#           (a) TAME FIRST-BOOT: the archive image was captured mid-first-boot,
#               so a fresh boot lands on the "IBM Software Registration" wizard
#               (over a stray "REQ0815: cannot get connection ID" network error).
#               We boot it headless once, drive the exact keystrokes to dismiss
#               the error + cancel registration, then perform a clean Workplace
#               Shell shutdown so the past-first-boot state is flushed to disk.
#           (b) DISABLE THE LAN NAG: the image ships a NetWare Requester with
#               "Directory Services ON" but no server, which pops the same
#               REQ0815 dialog on EVERY boot. We REM its three daemons in
#               C:\CONFIG.SYS (via qemu-nbd) so nothing dials out at startup.
#         Result: a fresh (-snapshot) boot lands STRAIGHT on the clean OS/2 WARP
#         desktop — LaunchPad, OS/2 System / Programs / WebExplorer, Shredder.
#
# LICENSE: OS/2 Warp 4 is IBM-copyrighted — free to use in this private collection.
#   It is fetched at build time from the Internet Archive for this PRIVATE, LAN-only
#   home-lab museum (the same stance this project already applies to its Windows
#   9x/XP/2000 and macOS tiles); the binary media is never committed to the GitHub
#   repo and the tile is never exposed to the public Internet. The modern successor
#   is ArcaOS by Arca Noae (a paid OS/2 distribution) — buy that for any real /
#   commercial OS/2 use. No faithful free/open OS/2 exists.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh host):
#   1. DOWNLOAD the pristine pre-installed Warp 4.0 qcow2 from archive.org
#      (item os2warp4_20240227, ~352 MiB; cached + size-checked).
#   2. COPY pristine -> golden, then TAME first-boot headlessly (scripted QEMU
#      monitor keystrokes; framebuffer-polled so it adapts to boot speed).
#   3. PATCH C:\CONFIG.SYS via qemu-nbd to disable the NetWare Requester nag.
#   4. BUILD the serial pointer agent with OpenWatcom 1.9, inject WARPD.EXE,
#      and add its REXX-quoted launch command to C:\STARTUP.CMD.
#   5. COLD-BOOT with the live tile's pinned machine/device set, wait for the
#      real desktop, and save the internal `golden` VM-state snapshot.
#   6. LOADVM-VERIFY the golden and capture the framebuffer after an exact
#      serial-agent pointer move.  Production routes buttons through QEMU's
#      PS/2 device after the agent mirrors the warp with MouSetPtrPos.
#
# AUTOMATION HONESTY:
#   * Steps 1-6 are FULLY AUTOMATED — zero manual keystrokes/clicks. The taming
#     keystrokes are transcribed from a verified interactive session and are
#     framebuffer-gated (poll for the bright first-boot UI; poll for the clean
#     desktop) so they are not blind fixed sleeps.
#   * We deliberately do NOT install OS/2 from scratch (see TYPE above); the
#     pre-installed qcow2 is the only non-self-authored input, used behind the
#     gallery's LAN-only edge — identical to the Win9x/XP prebuilt-image tiles.
#
# HYGIENE (per project rules):
#   * The tame + verify VMs are killed ONLY via QEMU monitor `quit` (fallback:
#     their own pidfile). NEVER `pkill qemu*` (would catch live gallery tiles,
#     CT 110, VM 900/925 and sibling builders).
#   * Namespaced per-PID run dir + unique serial/VNC/monitor UNIX sockets. qemu-nbd uses
#     the first FREE /dev/nbd* and always disconnects it.
#   * Touches ONLY <GUESTS_ROOT>/OS2Warp/. No other guest, CT, VM or shared file.
#
# Idempotent + re-runnable: the pristine download is cached-by-size; the OS base
# is rebuilt only when missing/invalid or --force is given, while agent injection
# and the pinned-machine `golden` snapshot are refreshed on every run.
#
# Usage:
#   build-guests/os2warp.sh [--dir DIR] [--force] [--no-verify] [-h]
#     --dir DIR     guest/output dir       (default /data/gallery-guests/OS2Warp)
#     --force       rebuild the golden image even if a valid one is present
#     --no-verify   skip the final framebuffer boot check
#     -h|--help     show this header
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="os2warp"
DIR_NAME="OS2Warp"

# Pre-installed OS/2 Warp 4.0 qcow2 on the Internet Archive (2 GiB virtual,
# ~352 MiB on disk). archive.org /download/ redirects to a datanode; curl -L
# follows it. Set SRC_URL to a mirror if the item ever moves.
SRC_URL="${SRC_URL:-https://archive.org/download/os2warp4_20240227/os2.qcow2}"
SRC_SIZE_BYTES="369229824" # pristine download size (cross-check)

GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${GUEST_DIR:-${GUESTS_ROOT}/${DIR_NAME}}"
DL_DIR="${GUEST_DIR}/dl"
PRISTINE="${DL_DIR}/os2-pristine.qcow2" # cached upstream download
GOLDEN="${GUEST_DIR}/os2.qcow2"         # final tile image (tamed + patched)
PROOF_PNG="${GUEST_DIR}/os2-warp4-desktop.png"

FORCE="${FORCE:-0}"
VERIFY="${VERIFY:-1}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MACHINE="${QEMU_MACHINE:-pc-i440fx-11.0}"
WATCOM_ROOT="${WATCOM_ROOT:-/opt/watcom}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT_DIR="${REPO_ROOT}/streamhost/guest-agents/os2"
AGENT_EXE="${AGENT_DIR}/WARPD.EXE"
DESKTOP_OBJECTS_CMD="${REPO_ROOT}/scripts/build-guests/assets/os2warp/create-desktop-objects.cmd"

# Unique, namespaced runtime handles (never reused across concurrent builds).
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
VNC_SOCK="${RUN_DIR}/vnc.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
SER_SOCK="${RUN_DIR}/serial.sock"
NBD_DEV=""
NBD_MP=""

log() { printf '\033[1;36m[%s]\033[0m %s\n' "$KEY" "$*" >&2; }
die() {
  printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$KEY" "$*" >&2
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch profile this tile runs with in the live gallery.
# (mirrored verbatim in docs/guests/os2warp.md as the manifest row)
#
#   qemu-system-x86_64 -machine pc-i440fx-11.0,acpi=off,usb=off \
#     -accel tcg -cpu pentium -m 128 -smp 1 -drive file=os2.qcow2,format=qcow2,if=ide \
#     -boot c -vga cirrus -device sb16,audiodev=snd \
#     -chardev socket,id=ser0,path=serial.sock,server=on,wait=off \
#     -serial chardev:ser0 -netdev user,id=n0 -device pcnet,netdev=n0
#
# WHY THESE FLAGS (OS/2-under-QEMU lore, all verified on host QEMU 11.0.0):
#   * TCG ONLY — OS/2 will NOT boot with hardware virtualisation (KVM). The neko
#     tile therefore does NOT engage /dev/kvm for this guest.
#   * acpi=off,usb=off — OS/2 Warp 4 predates ACPI; leaving it on wedges boot.
#     OS/2 has no USB stack, so usb-tablet gives no cursor (PS/2 mouse only).
#   * -cpu pentium + -smp 1 — the image ships a uniprocessor kernel.
#   * -vga cirrus — the installed video driver is Cirrus (640x480x8); std/qxl
#     give a black screen.
#   * IDE disk (default if=ide); qcow2 mounted read-only + -snapshot => every
#     visitor session is ephemeral.
###############################################################################

need() { command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found"; }
for t in curl qemu-img qemu-nbd socat python3 mount umount; do need "$t"; done
command -v "$QEMU_BIN" >/dev/null 2>&1 || die "$QEMU_BIN not found"

# ------------------------------------------------------------------ arg parse
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      GUEST_DIR="$2"
      DL_DIR="${GUEST_DIR}/dl"
      PRISTINE="${DL_DIR}/os2-pristine.qcow2"
      GOLDEN="${GUEST_DIR}/os2.qcow2"
      PROOF_PNG="${GUEST_DIR}/os2-warp4-desktop.png"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h | --help)
      sed -n '2,58p' "$0"
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

# --dir changes every runtime handle too.  Keep these together so a staging bake
# cannot accidentally use or remove the default live build directory's sockets.
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
VNC_SOCK="${RUN_DIR}/vnc.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
SER_SOCK="${RUN_DIR}/serial.sock"

mkdir -p "$GUEST_DIR" "$DL_DIR" "$RUN_DIR"

cleanup() {
  if [ -n "$NBD_MP" ]; then umount "$NBD_MP" 2>/dev/null || true; fi
  if [ -n "$NBD_DEV" ]; then qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true; fi
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
on_signal() {
  cleanup
  exit 130
} # so INT/TERM actually terminate long polls
trap cleanup EXIT
trap on_signal INT TERM

size_of() { wc -c <"$1" | tr -d ' '; }
# NOTE: `qemu-img info` can exit 0 even for a missing/unopenable file on some
# builds (observed on pve-qemu 11.0.0), so we must NOT rely on its return code.
# Require the file to exist AND qemu-img to actually report a qcow2 format.
qcow_ok() { [ -f "$1" ] && qemu-img info "$1" 2>/dev/null | grep -q 'file format: qcow2'; }

# ------------------------------------------------ QEMU monitor helper (HMP)
mon() { # mon "cmd" ["cmd"...] — send HMP commands over the UNIX monitor socket
  local c
  for c in "$@"; do
    printf '%s\n' "$c" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true
    sleep 0.4
  done
}

# Grab a framebuffer PPM via the monitor and print "meanR meanG meanB" over a
# sampled stride. Used to gate the taming keystrokes on the actual screen state.
frame_rgb() { # frame_rgb <ppm_path> -> echoes "R G B" (0-255) or nothing
  local ppm="$1"
  rm -f "$ppm"
  mon "screendump ${ppm}"
  sleep 1
  [ -s "$ppm" ] || return 1
  python3 - "$ppm" <<'PY' 2>/dev/null || return 1
import sys
d=open(sys.argv[1],'rb').read()
if d[:2]!=b'P6': sys.exit(1)
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    j=i
    while j<len(d) and d[j] not in b' \t\n\r': j+=1
    vals.append(int(d[i:j])); i=j
i+=1
w,h,_=vals
px=d[i:i+w*h*3]
if len(px)<w*h*3: sys.exit(1)
sr=sg=sb=n=0
step=max(1,(w*h)//6000)
for k in range(0,w*h,step):
    o=k*3; sr+=px[o]; sg+=px[o+1]; sb+=px[o+2]; n+=1
print(f"{sr//n} {sg//n} {sb//n}")
PY
}

# ================================================================= 1. DOWNLOAD
fetch_pristine() {
  if [ -f "$PRISTINE" ] && [ "$(size_of "$PRISTINE")" = "$SRC_SIZE_BYTES" ] && qcow_ok "$PRISTINE"; then
    log "pristine cached (size ok): $PRISTINE"
    return 0
  fi
  log "downloading pristine OS/2 Warp 4 qcow2 <- $SRC_URL"
  curl -fL --retry 3 --retry-delay 3 -o "${PRISTINE}.part" "$SRC_URL" ||
    die "download failed from $SRC_URL"
  qcow_ok "${PRISTINE}.part" || die "downloaded file is not a valid qcow2"
  local gs
  gs="$(size_of "${PRISTINE}.part")"
  [ "$gs" = "$SRC_SIZE_BYTES" ] || log "WARN: size $gs != expected $SRC_SIZE_BYTES (upstream may have re-rolled)"
  mv -f "${PRISTINE}.part" "$PRISTINE"
  log "pristine ready: $PRISTINE ($(du -h "$PRISTINE" | cut -f1))"
}

# ============================================== boot the golden headless (rw)
boot_headless() { # boot_headless <extra qemu args...>  (golden, NO -snapshot)
  rm -f "$MON_SOCK" "$VNC_SOCK" "$SER_SOCK" "$PIDFILE"
  # Keep the production DBus backend exact.  The bake-only VNC mirror makes
  # headless QEMU continuously update the scanout when no DBus client exists;
  # it adds no guest device and therefore does not change vmstate compatibility.
  nice -n15 "$QEMU_BIN" \
    -name build-os2warp -accel tcg -m 128 -smp 1 \
    -machine "${QEMU_MACHINE},acpi=off,usb=off" -cpu pentium \
    -rtc base=localtime -boot c -vga cirrus \
    -display dbus,p2p=on,audiodev=snd0 \
    -vnc "unix:${VNC_SOCK}" \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device sb16,audiodev=snd0 \
    -chardev "socket,id=ser0,path=${SER_SOCK},server=on,wait=off" \
    -serial chardev:ser0 \
    -drive "file=${GOLDEN},format=qcow2,if=ide" \
    -netdev user,id=n0 -device pcnet,netdev=n0 \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -pidfile "$PIDFILE" "$@" &
  local waited=0
  while [ ! -S "$MON_SOCK" ] && [ $waited -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -S "$MON_SOCK" ] || die "QEMU monitor socket never appeared"
}

kill_vm() { # clean teardown: monitor quit -> pidfile SIGTERM/KILL (never pkill)
  mon "quit"
  sleep 2
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 2
      kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  wait 2>/dev/null || true
}

# ============================================ 2. TAME FIRST-BOOT (headless)
# Drives the exact, verified keystroke path that dismisses the REQ0815 network
# error, cancels the "IBM Software Registration" wizard, closes the leftover
# WIN-OS/2 setup window, and performs a clean Workplace Shell shutdown so the
# past-first-boot state is flushed. Keystrokes are gated on the framebuffer:
# we wait for the BRIGHT first-boot UI to appear (not a blind sleep).
tame_first_boot() {
  log "tame: booting golden headless to clear OS/2 first-boot..."
  boot_headless

  # Poll for the first-boot UI: the registration wizard + error dialog is a
  # large light-gray/white surface => high overall brightness. Wait until the
  # screen is bright (mean of R+G+B channels high) or a generous cap.
  local ppm="${RUN_DIR}/tame.ppm" rgb r g b sum=0 t=0 ready=0
  log "tame: waiting for the first-boot registration UI to paint..."
  while [ $t -lt 200 ]; do
    sleep 6
    t=$((t + 6))
    rgb="$(frame_rgb "$ppm" || true)"
    [ -n "$rgb" ] || continue
    r="${rgb%% *}"
    b="${rgb##* }"
    g="$(printf '%s' "$rgb" | awk '{print $2}')"
    sum=$((r + g + b))
    # bright, near-neutral gray dialog => sum high (> ~360) and not strongly blue
    if [ "$sum" -gt 330 ] && [ $((b - r)) -lt 60 ]; then
      ready=1
      log "tame: first-boot UI detected at ${t}s (rgb=$rgb)"
      break
    fi
  done
  [ "$ready" = 1 ] || log "tame: WARN first-boot UI not clearly detected (rgb=$rgb); proceeding blind at ${t}s"

  # --- verified dismissal sequence -----------------------------------------
  log "tame: dismissing REQ0815 error + cancelling registration..."
  mon "sendkey ret"
  sleep 2 # OK the REQ0815 "cannot get connection ID"
  mon "sendkey tab"
  sleep 1 # move focus Next -> Cancel on the wizard
  mon "sendkey ret"
  sleep 2 # activate Cancel -> "are you sure?" confirm
  mon "sendkey ret"
  sleep 10 # OK the confirm -> desktop paints (+WIN-OS/2 win)
  mon "sendkey alt-f4"
  sleep 5 # close the leftover WIN-OS/2 setup window

  # --- clean Workplace Shell shutdown via the desktop popup menu -----------
  # Pin the PS/2 pointer to the top-left corner, then nudge onto empty desktop
  # (right of the icon column, below the LaunchPad), right-click for the desktop
  # menu, arrow UP twice (wraps to the bottom => "Shut down..."), activate, OK.
  log "tame: initiating clean WPS shutdown..."
  mon "mouse_move -4000 -4000"
  sleep 1 # pin to (0,0)
  mon "mouse_move 170 360"
  sleep 1 # land on empty desktop
  mon "mouse_button 2" "mouse_button 0"
  sleep 2 # right-click -> desktop menu
  mon "sendkey up" "sendkey up"
  sleep 1 # highlight "Shut down..."
  mon "sendkey ret"
  sleep 3           # activate -> shutdown confirmation
  mon "sendkey ret" # OK -> shutdown proceeds

  # Poll for the "Shutdown has completed" screen: near-uniform medium blue with
  # a tiny light box => strongly blue (b >> r) and moderate brightness.
  log "tame: waiting for shutdown to complete + flush to disk..."
  t=0
  local done=0
  while [ $t -lt 120 ]; do
    sleep 6
    t=$((t + 6))
    rgb="$(frame_rgb "$ppm" || true)"
    [ -n "$rgb" ] || continue
    r="${rgb%% *}"
    b="${rgb##* }"
    g="$(printf '%s' "$rgb" | awk '{print $2}')"
    if [ $((b - r)) -gt 60 ] && [ "$b" -gt 90 ]; then
      done=1
      log "tame: shutdown-complete screen at ${t}s (rgb=$rgb)"
      break
    fi
  done
  # Give the disk a moment even if detection was fuzzy, then power off cleanly.
  sleep 4
  [ "$done" = 1 ] || log "tame: WARN shutdown-complete not clearly detected; powering off after ${t}s anyway"
  kill_vm
  log "tame: done."
}

# ---------------------------------------------------------- offline FAT access
mount_golden() {
  modprobe nbd max_part=16 2>/dev/null || true
  local n
  NBD_DEV=""
  for n in 15 14 13 12 11 10 9 8 7 6 5 4 3; do
    if [ ! -e "/sys/block/nbd${n}/pid" ]; then
      NBD_DEV="/dev/nbd${n}"
      break
    fi
  done
  [ -n "$NBD_DEV" ] || die "no free /dev/nbd* for OS/2 image injection"
  qemu-nbd --connect="$NBD_DEV" "$GOLDEN" || die "qemu-nbd connect failed: $NBD_DEV"
  sleep 1
  NBD_MP="${RUN_DIR}/nbdmnt"
  mkdir -p "$NBD_MP"
  mount "${NBD_DEV}p1" "$NBD_MP" || die "cannot mount OS/2 FAT partition ${NBD_DEV}p1"
}

unmount_golden() {
  sync
  umount "$NBD_MP" || die "cannot unmount OS/2 FAT partition"
  qemu-nbd --disconnect "$NBD_DEV" >/dev/null || die "cannot disconnect $NBD_DEV"
  NBD_MP=""
  NBD_DEV=""
}

# ==================================== 3. DISABLE the NetWare Requester nag
# The image's C: is FAT16, so we can edit C:\CONFIG.SYS offline via qemu-nbd.
# We REM the three NetWare daemon RUN= lines (DDAEMON/SPDAEMON/NWDAEMON) that
# otherwise try (and fail) to attach to a NetWare tree at every boot, popping
# the "REQ0815: cannot get connection ID" dialog. The original is preserved
# on-image as C:\CONFIG.NWO. Idempotent.
disable_netware_nag() {
  local count
  log "patch: disabling NetWare Requester nag in C:\\CONFIG.SYS (qemu-nbd)..."
  mount_golden
  [ -f "$NBD_MP/CONFIG.SYS" ] || die "C:\\CONFIG.SYS not found on image"
  [ -f "$NBD_MP/CONFIG.NWO" ] || cp "$NBD_MP/CONFIG.SYS" "$NBD_MP/CONFIG.NWO"
  # Prepend "REM " to any 'RUN=...NETWARE\...' line (keeps CRLF intact).
  sed -i "/NETWARE\\\\/ s/^RUN=/REM RUN=/I" "$NBD_MP/CONFIG.SYS"
  count="$(grep -ci '^REM RUN=.*NETWARE' "$NBD_MP/CONFIG.SYS" 2>/dev/null || true)"
  log "patch: NetWare daemons REM'd -> ${count:-0} line(s)"
  unmount_golden
}

# =============================================== 4. BUILD + INJECT AGENT
build_agent() {
  local wcl="${WATCOM_ROOT}/binl/wcl386" ver
  [ -x "$wcl" ] || die "OpenWatcom 1.9 compiler missing: $wcl"
  [ -f "${WATCOM_ROOT}/lib386/os2/clib3r.lib" ] ||
    die "OpenWatcom 1.9 OS/2 32-bit runtime missing: ${WATCOM_ROOT}/lib386/os2/clib3r.lib"
  ver="$("$wcl" -? 2>&1 || true)"
  printf '%s\n' "$ver" | grep -q 'Version 1\.9' ||
    die "OpenWatcom must be exactly 1.9 (V2 runtime crashes on Warp 4 GA)"
  log "agent: building WARPD.EXE with OpenWatcom 1.9..."
  (
    export WATCOM="$WATCOM_ROOT"
    export PATH="${WATCOM_ROOT}/binl:${PATH}"
    export INCLUDE="${WATCOM_ROOT}/h:${WATCOM_ROOT}/h/os2"
    export EDPATH="${WATCOM_ROOT}/eddat"
    cd "$AGENT_DIR"
    nice -n15 wcl386 -bt=os2 -l=os2v2_pm -fe=WARPD.EXE warpd_os2.c
  )
  [ -s "$AGENT_EXE" ] || die "agent build produced no WARPD.EXE"
  log "agent: built $(wc -c <"$AGENT_EXE" | tr -d ' ') bytes, sha256=$(sha256sum "$AGENT_EXE" | awk '{print $1}')"
}

inject_agent() {
  log "agent: injecting C:\\WARPD.EXE + reproducible STARTUP.CMD desktop..."
  [ -f "$DESKTOP_OBJECTS_CMD" ] ||
    die "desktop object source missing: $DESKTOP_OBJECTS_CMD"
  mount_golden
  cp -f "$AGENT_EXE" "$NBD_MP/WARPD.EXE"
  cmp -s "$AGENT_EXE" "$NBD_MP/WARPD.EXE" || die "C:\\WARPD.EXE readback mismatch"
  local startup_tmp="${RUN_DIR}/STARTUP.CMD"
  sed 's/$/\r/' "$DESKTOP_OBJECTS_CMD" >"$startup_tmp"
  rm -f "$NBD_MP/STARTUP.CMD"
  cp "$startup_tmp" "$NBD_MP/STARTUP.CMD"
  cmp -s "$startup_tmp" "$NBD_MP/STARTUP.CMD" ||
    die "C:\\STARTUP.CMD readback mismatch"
  grep -Fqi 'start C:\WARPD.EXE' "$NBD_MP/STARTUP.CMD" ||
    die "desktop bootstrap does not start WARPD.EXE"
  grep -Fq '<GAL_DOOM>' "$NBD_MP/STARTUP.CMD" ||
    die "desktop bootstrap is missing the gallery object inventory"
  log "agent: installed CRLF STARTUP.CMD with idempotent gallery desktop objects"
  unmount_golden
}

wait_for_desktop() { # wait_for_desktop <ppm> <minimum seconds> <maximum seconds>
  local ppm="$1" min="$2" max="$3" rgb="" r=0 g=0 b=0 t=0
  while [ "$t" -lt "$max" ]; do
    sleep 6
    t=$((t + 6))
    rgb="$(frame_rgb "$ppm" || true)"
    [ -n "$rgb" ] || continue
    r="${rgb%% *}"
    b="${rgb##* }"
    g="$(printf '%s' "$rgb" | awk '{print $2}')"
    if [ "$t" -ge "$min" ] && [ $((b - r)) -gt 55 ] &&
      [ $((b - g)) -gt 20 ] && [ "$b" -gt 90 ]; then
      log "desktop detected at ${t}s (rgb=$rgb)"
      return 0
    fi
  done
  log "last framebuffer rgb=${rgb:-unavailable}"
  return 1
}

serial_move() { # serial_move <x> <y>
  local x="$1" y="$2"
  [ -S "$SER_SOCK" ] || die "serial socket missing: $SER_SOCK"
  printf 'M %s %s\n' "$x" "$y" |
    socat -T1 - "UNIX-CONNECT:${SER_SOCK}" >/dev/null 2>&1 ||
    die "cannot send serial-agent move M $x $y"
  sleep 2
}

# =========================================== 5. COLD BOOT + SAVEVM GOLDEN
bake_agent_golden() {
  local ppm="${RUN_DIR}/bake.ppm"
  log "bake: cold-booting pinned ${QEMU_MACHINE} device set..."
  boot_headless
  # The evolved gallery STARTUP.CMD deliberately sleeps 60s while WPS settles;
  # a strongly-blue early boot frame is therefore not enough.  Require 90s.
  wait_for_desktop "$ppm" 90 240 ||
    {
      kill_vm
      die "bake FAILED — cold boot never reached the WPS desktop"
    }
  serial_move 320 240
  frame_rgb "$ppm" >/dev/null 2>&1 || true
  mon "delvm golden"
  mon "savevm golden"
  sleep 12
  kill_vm
  qemu-img snapshot -l "$GOLDEN" | grep -qw golden ||
    die "savevm golden did not create an internal snapshot"
  log "bake: internal golden snapshot saved with WARPD.EXE auto-started"
}

# =========================================== 6. LOADVM + FRAMEBUFFER VERIFY
# loadvm must reach the clean, BLUISH Workplace Shell desktop, then two serial
# moves are captured for a real framebuffer pointer-delta proof.
verify_desktop() {
  log "verify: loadvm golden -> expecting clean WPS desktop + live serial agent..."
  boot_headless -loadvm golden
  local ppm_a="${RUN_DIR}/probe-a.ppm" ppm_b="${RUN_DIR}/probe-b.ppm"
  wait_for_desktop "$ppm_a" 0 60 ||
    {
      kill_vm
      die "verify FAILED — loadvm golden did not restore the WPS desktop"
    }
  serial_move 123 321
  frame_rgb "$ppm_a" >/dev/null 2>&1 || true
  serial_move 511 77
  frame_rgb "$ppm_b" >/dev/null 2>&1 || true
  cp -f "$ppm_a" "${GUEST_DIR}/os2-agent-probe-123x321.ppm"
  cp -f "$ppm_b" "${GUEST_DIR}/os2-agent-probe-511x77.ppm"
  if [ -s "$ppm_b" ]; then
    if python3 -c "import sys;from PIL import Image;Image.open(sys.argv[1]).save(sys.argv[2])" "$ppm_b" "$PROOF_PNG" 2>/dev/null; then
      log "verify: proof -> $PROOF_PNG"
    else
      PROOF_PNG="${PROOF_PNG%.png}.ppm"
      cp "$ppm_b" "$PROOF_PNG"
      log "verify: proof -> $PROOF_PNG (no PIL)"
    fi
  fi
  kill_vm
  log "verify: PASS — loadvm desktop restored; serial M 123 321 -> M 511 77 captured."
}

# ================================================================== main flow
if [ "$FORCE" = 0 ] && qcow_ok "$GOLDEN"; then
  log "base golden already present -> $GOLDEN (use --force to rebuild upstream base)."
  # savevm/loadvm can leave the qcow2 active disk state older or newer than the
  # known-good internal snapshot.  Offline injection followed by a cold boot of
  # that stale active state failed with CLOCK01.SYS on the 2026-07-16 mouse
  # re-bake.  Materialize the snapshot's DISK state first; the following agent
  # injection then changes that known-good state and the cold boot is repeatable.
  if qemu-img snapshot -l "$GOLDEN" | grep -qw golden; then
    log "base: applying existing golden disk state before offline injection..."
    qemu-img snapshot -a golden "$GOLDEN"
  fi
else
  fetch_pristine
  log "building golden image from pristine..."
  cp -f "$PRISTINE" "$GOLDEN"
  tame_first_boot
fi

disable_netware_nag
build_agent
inject_agent
bake_agent_golden
[ "$VERIFY" = 1 ] && verify_desktop || log "verify skipped (--no-verify)."

cat <<EOF

============================================================================
IBM OS/2 Warp 4 build complete.
  Golden image       : ${GOLDEN}
  Machine type       : ${QEMU_MACHINE}
  Agent              : C:\WARPD.EXE (STARTUP.CMD, COM1 serial)
  Proof screenshot   : ${PROOF_PNG}
  Pointer probes     : ${GUEST_DIR}/os2-agent-probe-{123x321,511x77}.ppm

neko-qemu tile env (see docs/guests/os2warp.md for the compose row):
  OS_NAME       = IBM OS/2 Warp 4
  QEMU_MACHINE  = ${QEMU_MACHINE},acpi=off,usb=off
                                            (pinned; TCG only — OS/2 won't
                                             boot with KVM/ACPI)
  QEMU_MEM      = 128
  QEMU_SMP      = 1                          (uniprocessor kernel)
  QEMU_VGA      = cirrus                     (640x480x8 — std/qxl = black screen)
  QEMU_SOUND    = -device sb16,audiodev=snd
  GUEST_DISK    = /guests/OS2Warp/os2.qcow2  (GUEST_FMT=qcow2 GUEST_IF=ide)
  GUEST_BOOT    = c
  QEMU_EXTRA    = -cpu pentium -serial chardev:ser0 -netdev user,id=n0 -device pcnet,netdev=n0

LICENSE: IBM-copyrighted — free to use in this private collection; binaries never
         committed to the GitHub repo, tile stays private/LAN-only. Modern
         paid path = ArcaOS (Arca Noae).
============================================================================
EOF
