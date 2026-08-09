#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/9front.sh  —  reproducible from-scratch build of the 9front
# (Plan 9) Kernel Hive guest.
#
# GOAL: on a fresh Proxmox host that already has the gallery infra, rebuild the
# 9front tile END TO END from its real upstream source — no image backups.
#
# WHAT THIS PRODUCES:
#   /data/gallery-guests/9front/9front-11554.amd64.qcow2   (agent-enabled golden)
#   /data/gallery-guests/9front/plan9.ini.orig             (pristine plan9.ini)
#   /data/gallery-guests/9front/proof-rio-desktop.png      (framebuffer proof)
#   /data/gallery-guests/9front/MANIFEST.md                (neko-qemu args)
#
# RECIPE (see exotic-gallery-guests.md §1 "9front"):
#   9front ships an OFFICIAL prebuilt amd64 qcow2 disk. It is otherwise a
#   console/serial image with no graphical boot. The ONLY customization needed
#   is to rewrite plan9.ini (in the 9fat FAT16 partition) so the machine boots
#   fully unattended into a VESA framebuffer -> the `rio` graphical desktop,
#   with zero keypresses. No OS install is run; the disk is already installed.
#
# AUTOMATION HONESTY:
#   * FULLY automated, zero interactive steps:
#       - download + gunzip of the upstream qcow2.gz
#       - plan9.ini rewrite (qemu-nbd + mtools/mcopy into the 9fat FAT16 fs)
#       - headless boot, in-guest 6c/6l build, install, and termrc autostart
#       - cold-boot TCP pointer proof, savevm/loadvm proof, and framebuffer proof
#   * QMP send-key types one deterministic rc command into rio's initial term;
#     the fetched installer performs every guest-side change and emits a marker.
#
# HYGIENE (per task rules):
#   * Kills QEMU ONLY via QMP `quit` (never pkill/killall by name).
#   * Namespaced run dir + a UNIQUE, unused /dev/nbdN and a UNIQUE QMP socket.
#   * Builds a staged image and replaces the live disk only after every proof.
#   * Stops/restarts only streamhost@ninefront; QEMU is killed only by pidfile.
#   * Idempotent + re-runnable. Set FORCE=1 only to re-download the pinned source.
# =============================================================================
set -euo pipefail

# ---- Parameters -------------------------------------------------------------
KEY="9front"
RELEASE="11554" # 9front release number
ARCH="amd64"
IMG_BASENAME="9front-${RELEASE}.${ARCH}.qcow2"
SRC_URL="https://9front.org/iso/${IMG_BASENAME}.gz" # official prebuilt disk
SRC_GZ_SHA256="0e4a0808020c7845f854599b910d3a63ee56cbf3ebcd038332e22b7c1a272361"

GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/${KEY}}"
IMG="${GUEST_DIR}/${IMG_BASENAME}" # final golden disk
CACHE_GZ="${GUEST_DIR}/.cache/${IMG_BASENAME}.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
AGENT_DIR="${REPO_ROOT}/streamhost/guest-agents/ninefront"
AGENT_SRC="${AGENT_DIR}/warpd.c"
TILE_DIR="${TILE_DIR:-/data/vms/streamhost/tiles/ninefront}"
LIVE_SERVICE="${LIVE_SERVICE:-streamhost@ninefront}"
MACHINE="${MACHINE:-pc-q35-11.0}"
WARPD_HOST_PORT="${WARPD_HOST_PORT:-57793}"
# Port 0 lets the kernel allocate a collision-free source-server port. A fixed
# port can still be supplied for constrained build hosts.
AGENT_HTTP_PORT="${AGENT_HTTP_PORT:-0}"

# Framebuffer resolution baked into plan9.ini (change here to re-res the tile).
# 1920x1080 = full-era-correct 16:9. 9front's monitor=vesa path negotiates it from
# QEMU 11's std-vga VGABIOS mode list (validated on a soltest clone 2026-07-27, KVM
# + packed framebuffer; see docs/lab/tile-resolution-responsiveness.md). Keep WxHx32.
VGASIZE="${VGASIZE:-1920x1080x32}"
# Geometry + golden pointer-park position parsed from VGASIZE, threaded into the
# framebuffer proof gates below so a re-res only needs the VGASIZE + FIXTURE_COMMAND
# (and, if the aspect changes, the fixture sample points) edited here.
FB_W="${VGASIZE%%x*}"
FB_REST="${VGASIZE#*x}"
FB_H="${FB_REST%%x*}"
PARK_X="${PARK_X:-1580}"
PARK_Y="${PARK_Y:-916}"

# Exact production VM shape + bounded proof timeouts.
VERIFY_MEM_MB="${VERIFY_MEM_MB:-1024}"
VERIFY_BOOT_WAIT="${VERIFY_BOOT_WAIT:-90}"
AGENT_BUILD_WAIT="${AGENT_BUILD_WAIT:-45}"
AGENT_BOOT_TIMEOUT="${AGENT_BOOT_TIMEOUT:-90}"
MANAGE_LIVE_TILE="${MANAGE_LIVE_TILE:-auto}"
KEEP_FAILED="${KEEP_FAILED:-0}"
# Curated 4-window rio fixture, laid out for 1920x1080 (acme fills the left ~64%;
# stats/load, catclock, and a focused rc terminal stack the right column). Typed on
# top of stock riostart's tiny top-left stats + boot term. Re-tune with VGASIZE.
FIXTURE_COMMAND="${FIXTURE_COMMAND:-window -r 20 130 1250 1050 acme; window -r 1268 130 1900 430 stats; window -r 1268 442 1900 770 games/catclock; window -r 1268 782 1900 1050}"

FORCE="${FORCE:-0}"

# Namespaced, unique runtime scratch (unique per PID -> no socket collisions).
RUN_DIR="${GUEST_DIR}/.build-run.$$"
QMP_SOCK="${RUN_DIR}/qmp.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
QLOG="${RUN_DIR}/qemu.log"
PROOF_PPM="${RUN_DIR}/shot.ppm"
PROOF_PNG="${GUEST_DIR}/proof-rio-desktop.png"
AGENT_PROOF_PPM="${RUN_DIR}/proof-warpd-park.ppm"
AGENT_PROOF_PNG="${GUEST_DIR}/proof-warpd-park.png"
WORK_IMG="${RUN_DIR}/${IMG_BASENAME}"
HTTP_PID=""
LIVE_WAS_ACTIVE=0
DEPLOYED=0
VALIDATED=0
OLD_IMG="${RUN_DIR}/pre-bake-live.qcow2"

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$KEY" "$*" >&2
  exit 1
}

# ---- Preconditions ----------------------------------------------------------
for t in qemu-img qemu-system-x86_64 qemu-nbd curl gzip python3 modprobe sha256sum pngtopnm flock; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t"
done
command -v mcopy >/dev/null 2>&1 ||
  die "missing required tool: mcopy (install Debian package: mtools)"
mkdir -p "$GUEST_DIR" "$(dirname "$CACHE_GZ")" "$RUN_DIR"
# Only one run may stop/promote this guest or claim its production host port.
exec 9>"$GUEST_DIR/.build.lock"
flock -n 9 || die "another 9front build is already running"
[ -s "$AGENT_SRC" ] || die "missing agent source: $AGENT_SRC"

if [ "$MANAGE_LIVE_TILE" = auto ]; then
  if [ "$GUEST_DIR" = /data/gallery-guests/9front ] && systemctl cat "$LIVE_SERVICE" >/dev/null 2>&1; then
    MANAGE_LIVE_TILE=1
  else
    MANAGE_LIVE_TILE=0
  fi
fi

# ---- Cleanup / hygiene ------------------------------------------------------
NBD_DEV="" # set once we claim one; cleaned up unconditionally
cleanup() {
  # 1) Stop QEMU via QMP quit (NEVER pkill). Fall back to the recorded PID only.
  if [ -S "$QMP_SOCK" ]; then qmp_quit || true; fi
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null; then
      sleep 2
      kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null || true
    fi
  fi
  # 2) Release the nbd device and source server we claimed.
  [ -n "$NBD_DEV" ] && qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
    kill "$HTTP_PID" 2>/dev/null || true
  fi
  if [ "$DEPLOYED" = 1 ] && [ "$VALIDATED" = 0 ]; then
    systemctl stop "$LIVE_SERVICE" >/dev/null 2>&1 || true
    rm -f "$IMG"
    [ -f "$OLD_IMG" ] && mv -f "$OLD_IMG" "$IMG"
  fi
  if [ "$KEEP_FAILED" != 1 ] || [ "$VALIDATED" = 1 ]; then
    rm -rf "$RUN_DIR" 2>/dev/null || true
  else
    log "preserving failed run for diagnosis: $RUN_DIR"
  fi
  if [ "$LIVE_WAS_ACTIVE" = 1 ] && [ "$VALIDATED" = 0 ]; then
    systemctl start "$LIVE_SERVICE" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# ---- QMP helper: drive the monitor over a unix socket via python3 -----------
# Speaks just enough QMP to: negotiate caps, run one command, read one reply.
qmp_cmd() { # $1 = json command line
  python3 - "$QMP_SOCK" "$1" <<'PY'
import socket,sys,json,time
sock,cmd=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(15)
for _ in range(30):
    try: s.connect(sock); break
    except OSError: time.sleep(0.5)
else: sys.exit(3)
f=s.makefile('rw')
f.readline()                                   # greeting
f.write(json.dumps({"execute":"qmp_capabilities"})+"\n"); f.flush(); f.readline()
f.write(cmd+"\n"); f.flush()
print(f.readline().strip())
PY
}
qmp_quit() { qmp_cmd '{"execute":"quit"}' >/dev/null 2>&1 || true; }

# ---- Claim an unused /dev/nbdN ----------------------------------------------
claim_nbd() {
  modprobe nbd max_part=16 2>/dev/null || modprobe nbd 2>/dev/null || die "cannot load nbd module"
  for n in $(seq 0 15); do
    local dev="/dev/nbd${n}" sz="/sys/block/nbd${n}/size"
    [ -b "$dev" ] || continue
    # size==0 means the device is not currently backing any image -> free.
    if [ "$(cat "$sz" 2>/dev/null || echo 1)" = "0" ]; then
      NBD_DEV="$dev"
      return 0
    fi
  done
  die "no free /dev/nbdN device available"
}

# =============================================================================
# STEP 1 — Download the upstream qcow2.gz from the REAL URL and decompress it.
# =============================================================================
build_disk() {
  # Every run starts from the official compressed artifact. The cache saves
  # bandwidth but is never trusted until its pinned hash matches.
  [ "$FORCE" = "1" ] && rm -f "$CACHE_GZ"
  if [ ! -f "$CACHE_GZ" ]; then
    log "downloading $SRC_URL"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$CACHE_GZ" "$SRC_URL" ||
      curl -fL --retry 3 -o "$CACHE_GZ" "$SRC_URL" ||
      die "download failed"
  else
    log "using cached upstream archive $CACHE_GZ"
  fi
  echo "$SRC_GZ_SHA256  $CACHE_GZ" | sha256sum -c - ||
    die "upstream archive hash mismatch (set FORCE=1 to re-download)"
  gzip -t "$CACHE_GZ" || die "downloaded gz is corrupt"
  log "decompressing pristine upstream qcow2 -> $WORK_IMG"
  gzip -dc "$CACHE_GZ" >"$WORK_IMG"
  qemu-img info "$WORK_IMG" >/dev/null 2>&1 || die "decompressed file is not a valid qcow2"
  log "staged disk ready: $(qemu-img info "$WORK_IMG" | awk -F': ' '/virtual size/{print $2}')"
}

# =============================================================================
# STEP 2 — Rewrite plan9.ini for unattended VESA boot.
#
# The 9front disk is a single MBR partition (type 0x39 "Plan 9") starting at
# LBA 63; the 9fat FAT16 filesystem lives at the START of that partition, so
# `mcopy -i <nbd>p1` reads/writes it directly (fallback: byte offset 63*512).
#
# EXACT effective plan9.ini (CRLF line endings — Plan 9 requires \r\n):
#   bootfile=9pc64                    -> 64-bit PC kernel
#   nobootprompt=local!/dev/sdE0/fs   -> skip bootargs prompt (disk = sdE0 on q35 IDE)
#   user=glenda                       -> skip the user[] prompt
#   mouseport=ps2                     -> PS/2 mouse
#   monitor=vesa                      -> VESA framebuffer (without this rio dies:
#                                        "bind: #i: no frame buffer")
#   vgasize=<WxHxD> (VGASIZE)         -> framebuffer geometry (default 1920x1080x32)
# =============================================================================
PLAN9_INI_CONTENT=$(printf 'bootfile=9pc64\r\nnobootprompt=local!/dev/sdE0/fs\r\nuser=glenda\r\nmouseport=ps2\r\nmonitor=vesa\r\nvgasize=%s\r\n' "$VGASIZE")

patch_plan9ini() {
  claim_nbd
  log "attaching $WORK_IMG to $NBD_DEV"
  qemu-nbd --connect="$NBD_DEV" "$WORK_IMG" || die "qemu-nbd connect failed"

  # Wait for the kernel to expose the first partition node.
  local part="${NBD_DEV}p1" mtarget=""
  command -v partprobe >/dev/null 2>&1 && partprobe "$NBD_DEV" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    [ -b "$part" ] && break
    sleep 0.3
  done
  if [ -b "$part" ]; then
    mtarget="$part" # 9fat is at the start of the Plan 9 partition
  else
    mtarget="${NBD_DEV}@@32256" # fallback: raw byte offset 63*512 (mtools syntax)
  fi
  log "9fat target = $mtarget"

  # Back up the pristine plan9.ini exactly once (before we ever mutate it).
  if [ ! -f "${GUEST_DIR}/plan9.ini.orig" ]; then
    mcopy -n -i "$mtarget" ::/PLAN9.INI "${GUEST_DIR}/plan9.ini.orig" 2>/dev/null &&
      log "saved pristine plan9.ini.orig" ||
      log "warn: could not read original PLAN9.INI (continuing)"
  fi

  # Write the new plan9.ini into the 9fat FAT16 root (overwrite in place).
  printf '%s' "$PLAN9_INI_CONTENT" >"${RUN_DIR}/plan9.ini"
  mcopy -o -i "$mtarget" "${RUN_DIR}/plan9.ini" ::/PLAN9.INI ||
    die "mcopy of new plan9.ini failed"

  # Verify the write took.
  log "plan9.ini now in image:"
  mcopy -i "$mtarget" ::/PLAN9.INI - 2>/dev/null | sed 's/\r/<CR>/' | sed 's/^/    /' >&2 || true

  qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  NBD_DEV=""
  log "plan9.ini patched for unattended VESA boot"
}

# =============================================================================
# STEP 3 — Build/install the agent, cold-boot it, and save/prove golden.
# The staged disk uses the production machine type and exact emulated devices.
# =============================================================================
stop_bake_qemu() {
  if [ -S "$QMP_SOCK" ]; then
    qmp_quit || true
  fi
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ]; then
      for _ in $(seq 1 40); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$p" 2>/dev/null && kill "$p" 2>/dev/null || true
    fi
  fi
  rm -f "$QMP_SOCK" "$PIDFILE"
}

stop_live_tile() {
  [ "$MANAGE_LIVE_TILE" = 1 ] || return 0
  systemctl is-active --quiet "$LIVE_SERVICE" && LIVE_WAS_ACTIVE=1
  log "stopping $LIVE_SERVICE before claiming host port $WARPD_HOST_PORT"
  systemctl stop "$LIVE_SERVICE"
  if [ -f "$TILE_DIR/qemu.pid" ]; then
    local p
    p="$(cat "$TILE_DIR/qemu.pid" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      log "service stop left pidfile-owned QEMU $p; terminating it by pidfile"
      kill "$p"
      for _ in $(seq 1 40); do
        kill -0 "$p" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
    fi
  fi
}

qmp_op() {
  python3 - "$QMP_SOCK" "$@" <<'PYQMP'
import json, socket, sys, time
sock, op, args = sys.argv[1], sys.argv[2], sys.argv[3:]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
json.loads(f.readline())

def command(obj):
    f.write(json.dumps(obj).encode() + b"\n")
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:
            continue
        if "error" in reply:
            raise SystemExit("QMP error: " + json.dumps(reply["error"]))
        if "return" in reply:
            return reply["return"]

command({"execute": "qmp_capabilities"})

def send_key(keys):
    command({"execute": "send-key", "arguments": {
        "keys": [{"type": "qcode", "data": key} for key in keys],
        "hold-time": 20
    }})
    time.sleep(.060)

if op == "shot":
    command({"execute": "screendump", "arguments": {"filename": args[0]}})
elif op == "hmp":
    out = command({"execute": "human-monitor-command",
                   "arguments": {"command-line": args[0]}})
    if out:
        print(out, end="")
elif op == "stop":
    command({"execute": "stop"})
elif op == "cont":
    command({"execute": "cont"})
elif op == "type":
    plain = {
        " ": "spc", "\n": "ret", "\t": "tab", "-": "minus", "=": "equal",
        "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
        ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
        ",": "comma", ".": "dot", "/": "slash",
    }
    shifted = {
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6",
        "&": "7", "*": "8", "(": "9", ")": "0", "_": "minus",
        "+": "equal", "{": "bracket_left", "}": "bracket_right",
        "|": "backslash", ":": "semicolon", '"': "apostrophe",
        "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
    }
    for char in args[0]:
        if char.isalpha() and char.isupper():
            send_key(["shift", char.lower()])
        elif char.isalpha() or char.isdigit():
            send_key([char.lower()])
        elif char in plain:
            send_key([plain[char]])
        elif char in shifted:
            send_key(["shift", shifted[char]])
        else:
            raise SystemExit("unsupported fixture character: " + repr(char))
    send_key(["ret"])
else:
    raise SystemExit("unknown QMP operation: " + op)
s.close()
PYQMP
}

focus_rio_terminal() {
  # Fresh rio does not assign keyboard focus until a click. Clamp the relative
  # PS/2 pointer to (0,0), move into the initial term, and left-click it.
  # PS/2 relative packets clamp large deltas, so use repeated bounded moves.
  for _ in $(seq 1 12); do
    qmp_op hmp "mouse_move -100 -100" >/dev/null
  done
  qmp_op hmp "mouse_move 100 200" >/dev/null
  qmp_op hmp "mouse_button 1" >/dev/null
  qmp_op hmp "mouse_button 0" >/dev/null
  sleep 1
}

start_bake_qemu() {
  stop_bake_qemu
  log "cold boot under production shape: $MACHINE, 2 vCPU, host CPU"
  nice -n15 qemu-system-x86_64 \
    -name ninefront-golden-bake \
    -enable-kvm -m "$VERIFY_MEM_MB" -smp 2 \
    -machine "$MACHINE" -cpu host \
    -rtc base=localtime \
    -boot c \
    -vga std \
    -display none -vnc unix:"${RUN_DIR}/vnc.sock" \
    -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 \
    -drive file="$WORK_IMG",if=none,id=hd0,format=qcow2 \
    -device ide-hd,drive=hd0,bus=ide.0 \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"${WARPD_HOST_PORT}"-:7777 \
    -device virtio-net-pci,netdev=n0 \
    -qmp unix:"${QMP_SOCK}",server=on,wait=off \
    -pidfile "$PIDFILE" \
    >"$QLOG" 2>&1 &
  for _ in $(seq 1 60); do
    [ -S "$QMP_SOCK" ] && [ -f "$PIDFILE" ] && return 0
    sleep 0.5
  done
  cat "$QLOG" >&2
  die "QEMU/QMP did not start"
}

frame_is_rio() {
  python3 - "$1" "$FB_W" "$FB_H" <<'PYFRAME'
import sys
d = open(sys.argv[1], "rb").read()
W, H = int(sys.argv[2]), int(sys.argv[3])
i = 2
vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b" \t\r\n":
        i += 1
    if d[i:i+1] == b"#":
        while i < len(d) and d[i] != 10:
            i += 1
        continue
    j = i
    while j < len(d) and d[j] not in b" \t\r\n":
        j += 1
    vals.append(int(d[i:j]))
    i = j
while i < len(d) and d[i] in b" \t\r\n":
    i += 1
w, h, mx = vals
if (w, h, mx) != (W, H, 255):
    raise SystemExit(1)
px = d[i:i+w*h*3]
def at(x, y):
    o = (y*w+x)*3
    return tuple(px[o:o+3])
# Stock riostart at cold boot = tiny top-left stats + a boot term near
# (30,130)-(630,430) on the grey rio floor. Sample the floor (grey) in the empty
# lower-right, and the boot term body (white) — both resolution-independent.
grey = [at(w-100, h-100), at(w-300, h-300), at(w-100, h//2)]
white = [at(100, 200), at(300, 300), at(500, 400)]
rio = all(max(c)-min(c) <= 6 and 100 <= sum(c)/3 <= 150 for c in grey)
rio = rio and all(min(c) >= 235 for c in white)
raise SystemExit(0 if rio else 1)
PYFRAME
}

wait_for_rio() {
  local label="$1"
  for _ in $(seq 1 "$VERIFY_BOOT_WAIT"); do
    qmp_op shot "$PROOF_PPM" >/dev/null 2>&1 || true
    if [ -s "$PROOF_PPM" ] && frame_is_rio "$PROOF_PPM"; then
      log "framebuffer gate passed: rio desktop ($label)"
      return 0
    fi
    sleep 1
  done
  cat "$QLOG" >&2 2>/dev/null || true
  die "rio framebuffer did not arrive within ${VERIFY_BOOT_WAIT}s ($label)"
}

frame_is_fixture() {
  python3 - "$1" "$FB_W" "$FB_H" <<'PYFRAME'
import sys
d = open(sys.argv[1], "rb").read()
W, H = int(sys.argv[2]), int(sys.argv[3])
i = 2
vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b" \t\r\n":
        i += 1
    if d[i:i+1] == b"#":
        while i < len(d) and d[i] != 10:
            i += 1
        continue
    j = i
    while j < len(d) and d[j] not in b" \t\r\n":
        j += 1
    vals.append(int(d[i:j]))
    i = j
while i < len(d) and d[i] in b" \t\r\n":
    i += 1
w, h, mx = vals
if (w, h, mx) != (W, H, 255):
    raise SystemExit(1)
px = d[i:i+w*h*3]
def at(x, y):
    o = (y*w+x)*3
    return tuple(px[o:o+3])
def white(c):
    return min(c) >= 235
def grey(c):
    return max(c)-min(c) <= 6 and 100 <= sum(c)/3 <= 145
def yellow(c):
    return c[0] >= 245 and c[1] >= 245 and 200 <= c[2] <= 245
def pink(c):
    return c[0] >= 245 and 200 <= c[1] <= 245 and 200 <= c[2] <= 245
# Sample points are tied to the 1920x1080 FIXTURE_COMMAND above (re-tune together):
# acme white body + yellow /usr/glenda dir column, stats/load (pink), catclock
# (white), focused rc term (white), and the grey rio floor below all windows.
fixture = white(at(300, 600)) and yellow(at(1000, 400))
fixture = fixture and pink(at(1500, 380)) and white(at(1300, 500))
fixture = fixture and white(at(1400, 850)) and grey(at(960, 1068))
raise SystemExit(0 if fixture else 1)
PYFRAME
}

wait_for_fixture() {
  local label="$1"
  for _ in $(seq 1 30); do
    qmp_op shot "$PROOF_PPM" >/dev/null 2>&1 || true
    sleep 0.1
    if [ -s "$PROOF_PPM" ] && frame_is_fixture "$PROOF_PPM"; then
      log "framebuffer gate passed: acme + stats + catclock + focused term ($label)"
      return 0
    fi
    sleep 0.9
  done
  die "lively rio fixture did not settle within 30s ($label)"
}

write_installer() {
  mkdir -p "$RUN_DIR/http"
  install -m 0644 "$AGENT_SRC" "$RUN_DIR/http/warpd.c"
  cat >"$RUN_DIR/http/install.rc" <<'RC'
#!/bin/rc
rfork e
base=$1
cd /tmp
hget $base/warpd.c >warpd.c || exit 'hget warpd.c failed'
6c warpd.c || exit '6c failed'
6l -o warpd warpd.6 || exit '6l failed'
cp warpd /amd64/bin/warpd || exit 'install warpd failed'
mkdir -p /cfg/cirno || exit 'create cfg directory failed'
hget $base/termrc >/cfg/cirno/termrc || exit 'install termrc failed'
chmod +x /cfg/cirno/termrc
echo 'warpd-bake-ok' >/cfg/cirno/warpd.bake
sync
echo WARPD_BAKE_OK
RC
  cat >"$RUN_DIR/http/termrc" <<'RCTERM'
#!/bin/rc
ip/ipconfig >[2]/dev/null
ndb/cs >[2]/dev/null
bind -a '#m' /dev >[2]/dev/null
{ while(! /amd64/bin/warpd >>/cfg/cirno/warpd.log >[2=1]) sleep 2 } &
RCTERM
  rm -f "$RUN_DIR/http.port"
  python3 - "$RUN_DIR/http" "$RUN_DIR/http.port" "$AGENT_HTTP_PORT" \
    >"$RUN_DIR/http.log" 2>&1 <<'PYHTTP' &
import http.server, sys
directory, port_file, requested = sys.argv[1], sys.argv[2], int(sys.argv[3])
handler = lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
    *args, directory=directory, **kwargs)
server = http.server.ThreadingHTTPServer(("0.0.0.0", requested), handler)
with open(port_file, "w") as f:
    print(server.server_address[1], file=f)
server.serve_forever()
PYHTTP
  HTTP_PID=$!
  for _ in $(seq 1 20); do
    [ -s "$RUN_DIR/http.port" ] && break
    kill -0 "$HTTP_PID" 2>/dev/null || break
    sleep 0.1
  done
  if ! kill -0 "$HTTP_PID" 2>/dev/null || [ ! -s "$RUN_DIR/http.port" ]; then
    cat "$RUN_DIR/http.log" >&2
    die "agent source server failed on requested port $AGENT_HTTP_PORT"
  fi
  AGENT_HTTP_PORT="$(cat "$RUN_DIR/http.port")"
  log "serving agent source on collision-free host port $AGENT_HTTP_PORT"
}

# Q <x> <y> both PROVES the agent is live (reply K) AND emits a move, so it doubles
# as the deterministic pointer-park at PARK_X,PARK_Y (the golden/boot-video seam).
warpd_exact_probe() {
  python3 - "$WARPD_HOST_PORT" "$PARK_X" "$PARK_Y" <<'PYEXACT'
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3)
s.sendall(("Q %s %s\n" % (sys.argv[2], sys.argv[3])).encode())
reply = s.recv(32)
s.close()
if reply.strip() != b"K":
    raise SystemExit("warpd probe reply: %r" % reply)
time.sleep(1)
PYEXACT
}

wait_for_exact_probe() {
  local label="$1" deadline=$((SECONDS + AGENT_BOOT_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$label" = production ]; then
      systemctl is-active --quiet "$LIVE_SERVICE" &&
        [ -S "$TILE_DIR/qmp.sock" ] ||
        die "production service/QMP exited while waiting for warpd"
    else
      local qpid
      qpid="$(cat "$PIDFILE" 2>/dev/null || true)"
      if [ -z "$qpid" ] || ! kill -0 "$qpid" 2>/dev/null; then
        cp -f "$QLOG" "$GUEST_DIR/debug-warpd-$label.qemu.log" 2>/dev/null || true
        cat "$QLOG" >&2
        die "bake QEMU exited while waiting for warpd ($label)"
      fi
    fi
    if warpd_exact_probe >/dev/null 2>&1; then
      log "warpd exact probe acknowledged mouse-device write (Q ${PARK_X} ${PARK_Y} -> K)"
      return 0
    fi
    sleep 1
  done
  log "capturing in-guest diagnostics after failed probe ($label)"
  focus_rio_terminal || true
  qmp_op type "echo WARPDEBUG; cat /cfg/cirno/warpd.bake; ls -l /amd64/bin/warpd; ps | grep warpd; cat /cfg/cirno/warpd.log" || true
  sleep 5
  qmp_op shot "$GUEST_DIR/debug-warpd-$label.ppm" || true
  ppm_to_png "$GUEST_DIR/debug-warpd-$label.ppm" "$GUEST_DIR/debug-warpd-$label.png" || true
  die "warpd exact probe could not connect within ${AGENT_BOOT_TIMEOUT}s"
}

cursor_is_at() {
  python3 - "$1" "$2" "$3" <<'PYCURSOR'
import sys
path, x, y = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
d = open(path, "rb").read()
i = 2
vals = []
while len(vals) < 3:
    while d[i] in b" \t\r\n":
        i += 1
    j = i
    while d[j] not in b" \t\r\n":
        j += 1
    vals.append(int(d[i:j]))
    i = j
while d[i] in b" \t\r\n":
    i += 1
w, h, _ = vals
px = d[i:]
dark = 0
for yy in range(y, min(h, y+24)):
    for xx in range(x, min(w, x+24)):
        o = (yy*w+xx)*3
        if max(px[o:o+3]) < 80:
            dark += 1
print("cursor probe: requested=(%d,%d), dark pixels in 24x24 hotspot=%d" % (x, y, dark))
raise SystemExit(0 if dark >= 8 else 1)
PYCURSOR
}

ppm_to_png() {
  python3 - "$1" "$2" <<'PYPNG'
import sys, zlib, struct
ppm, png = sys.argv[1], sys.argv[2]
d = open(ppm, "rb").read()
i = 2
vals = []
while len(vals) < 3:
    while i < len(d) and d[i] in b" \t\n\r":
        i += 1
    if d[i:i+1] == b"#":
        while i < len(d) and d[i] != 10:
            i += 1
        continue
    j = i
    while j < len(d) and d[j] not in b" \t\n\r":
        j += 1
    vals.append(int(d[i:j]))
    i = j
while i < len(d) and d[i] in b" \t\n\r":
    i += 1
w, h, mx = vals
assert mx == 255
px = d[i:i+w*h*3]
def chunk(t, b):
    return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw = bytearray()
for y in range(h):
    raw.append(0)
    raw += px[y*w*3:(y+1)*w*3]
out = b"\x89PNG\r\n\x1a\n"
out += chunk(b"IHDR", struct.pack(">IIBBBBB",w,h,8,2,0,0,0))
out += chunk(b"IDAT", zlib.compress(bytes(raw),6))
out += chunk(b"IEND", b"")
open(png, "wb").write(out)
PYPNG
}

bake_agent_and_snapshot() {
  stop_live_tile
  write_installer

  start_bake_qemu
  wait_for_rio "pristine upstream"
  local base="http://10.0.2.2:${AGENT_HTTP_PORT}"
  log "typing deterministic in-guest installer command"
  focus_rio_terminal
  qmp_op type "ip/ipconfig; ndb/cs; hget ${base}/install.rc >/tmp/install.rc; rc /tmp/install.rc ${base}"
  sleep "$AGENT_BUILD_WAIT"
  qmp_op type "fshalt"
  for _ in $(seq 1 120); do
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -z "$p" ] || ! kill -0 "$p" 2>/dev/null && break
    sleep 0.25
  done
  stop_bake_qemu

  start_bake_qemu
  wait_for_rio "agent cold boot"
  wait_for_exact_probe "cold-boot"

  log "launching lively rio fixture: acme, stats, catclock, and a focused terminal"
  qmp_op type "$FIXTURE_COMMAND"
  wait_for_fixture "pre-savevm"

  # Park the pointer at PARK_X,PARK_Y via warpd so the SAVED golden (and thus the
  # first live frame) has a deterministic cursor position the boot-video seam and
  # the production reset proof both match.
  log "parking golden pointer at ${PARK_X},${PARK_Y} via warpd"
  warpd_exact_probe || die "could not park golden pointer via warpd"

  # Pause explicitly at the framebuffer-validated frame. This makes the saved
  # state exactly the boot-video poster/fixture frame; it resumes as running.
  qmp_op stop
  qmp_op shot "$PROOF_PPM"
  sleep 0.2
  frame_is_fixture "$PROOF_PPM" || die "fixture changed before paused savevm"

  log "saving internal golden snapshot under exact production device set"
  qmp_op hmp "delvm golden" >/dev/null 2>&1 || true
  qmp_op hmp "savevm golden" >"$RUN_DIR/savevm.out"
  qmp_op hmp "info snapshots" | tee "$RUN_DIR/snapshots.txt"
  grep -qw golden "$RUN_DIR/snapshots.txt" || die "savevm golden did not create a snapshot"
  qmp_op cont

  log "proving saved RAM state: loadvm golden lands directly in the lively fixture"
  qmp_op hmp "loadvm golden" >/dev/null
  wait_for_fixture "post-loadvm golden"
  ppm_to_png "$PROOF_PPM" "$PROOF_PNG"
  wait_for_exact_probe "loadvm"
  qmp_op shot "$AGENT_PROOF_PPM"
  ppm_to_png "$AGENT_PROOF_PPM" "$AGENT_PROOF_PNG"

  stop_bake_qemu
  qemu-img snapshot -l "$WORK_IMG" | awk '{print $2}' | grep -qx golden ||
    die "offline qcow2 snapshot audit found no golden"
  [ -f "$IMG" ] && mv -f "$IMG" "$OLD_IMG"
  mv -f "$WORK_IMG" "$IMG"
  chmod 0644 "$IMG"
  DEPLOYED=1
  if [ "$MANAGE_LIVE_TILE" = 1 ]; then
    systemctl start "$LIVE_SERVICE"
    for _ in $(seq 1 60); do
      [ -S "$TILE_DIR/qmp.sock" ] && break
      sleep 0.5
    done
    [ -S "$TILE_DIR/qmp.sock" ] || die "production QMP did not return"
    command -v labctl >/dev/null 2>&1 || die "labctl is required for production loadvm proof"
    labctl reset ninefront
    wait_for_exact_probe "production"
    local production_frame_ok=0
    for _ in $(seq 1 10); do
      labctl shot ninefront "$AGENT_PROOF_PNG" >/dev/null
      pngtopnm "$AGENT_PROOF_PNG" >"$AGENT_PROOF_PPM"
      if frame_is_fixture "$AGENT_PROOF_PPM" &&
        cursor_is_at "$AGENT_PROOF_PPM" "$PARK_X" "$PARK_Y"; then
        production_frame_ok=1
        break
      fi
      sleep 0.5
    done
    [ "$production_frame_ok" = 1 ] ||
      die "production reset framebuffer/cursor proof did not settle"
  fi
  VALIDATED=1
  log "promoted and loadvm-verified staged disk -> $IMG"
}

# =============================================================================
# STEP 4 — (Re)generate the MANIFEST.md with the neko-qemu runtime args.
# =============================================================================
write_manifest() {
  cat >"${GUEST_DIR}/MANIFEST.md" <<EOF
# 9front (Plan 9) - gallery guest

Image: ${IMG_BASENAME} (release ${RELEASE}, ${ARCH})
Source: ${SRC_URL}
Source archive sha256: ${SRC_GZ_SHA256}
Built by: scripts/build-guests/tiles/9front.sh

Customization:
- plan9.ini in 9fat rewritten for unattended ${VGASIZE} VESA/rio boot.
- streamhost/guest-agents/ninefront/warpd.c compiled in-guest with 6c/6l.
- /amd64/bin/warpd installed; /cfg/cirno/termrc binds #m and launches a retrying agent supervisor.
- Internal snapshot 'golden' saved under ${MACHINE}, 2 vCPU, -cpu host.
- Existing user netdev has hostfwd 127.0.0.1:${WARPD_HOST_PORT} -> guest :7777.

The build cold-boots the staged disk, proves TCP Q ${PARK_X} ${PARK_Y} acknowledges a
mouse-device write (which also parks the golden pointer there), saves golden,
loadvm-restores it, repeats the same probe, and only then promotes the image.
Runtime must use the same device set and must not use -snapshot because the
internal golden snapshot lives in this qcow2.

Proofs:
- proof-rio-desktop.png
- proof-warpd-park.png
EOF
  log "MANIFEST.md written"
}

# ---- Main -------------------------------------------------------------------
log "=== building 9front gallery guest ==="
build_disk
patch_plan9ini
write_manifest
bake_agent_and_snapshot
log "=== DONE: agent-enabled golden disk at $IMG ==="
