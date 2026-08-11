#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/qnx.sh — from-scratch, reproducible build of the QNX Neutrino
# gallery station for the neko+QEMU Kernel Hive.
#
# GUEST : QNX Neutrino RTOS 6.5.0 — the "self-hosting" LiveCD (boots the Photon
#         microGUI desktop straight from CD; no install-to-disk needed).
# TYPE  : LIVE CD, but NOT hands-off — the LiveCD's Photon first-run flow needs
#         to be DRIVEN to the desktop. This script does the full drive + a
#         framebuffer proof that the QNX Photon DESKTOP renders.
#
# WHAT QNX / PHOTON IS: QNX is a commercial hard-real-time microkernel OS (QSSL,
# later BlackBerry). Photon microGUI is its lightweight window system. This 6.5.0
# self-hosting LiveCD is the freely-redistributable evaluation image circulated
# by QNX; it is archived on archive.org. Era: late-1990s..2010 (6.5.0 = 2010).
#
# ---- LICENSE ----------------------------------------------------------------
#   QNX Neutrino 6.5.0 self-hosting LiveCD = QNX's freely-distributable
#   evaluation/DEMO image (non-commercial eval). Flagged here as a DEMO /
#   freely-distributable image, sourced from archive.org. It is NOT open source.
#   (Same stance the project already applies to its other copyrighted stations: free
#   to use in this private collection.)
#
# ---- AUTOMATION HONESTY (the hard-won recipe) -------------------------------
#   The LiveCD does NOT self-land on the desktop. Reaching it in QEMU needs a
#   precise sequence, ALL automated here:
#     (a) wait for the stable final "Select?" menu, then F2 exactly once;
#     (b) use -vga cirrus, which phgrafx binds as devg-svga;
#     (c) select 64K colour / 1024x768 by keyboard and accept with Alt+A;
#     (d) leave phgrafx with Alt+X and log in as root / empty password.
#   The production pointer remains tablet-free PS/2 relative. A hot-added UHCI
#   usb-tablet enumerates and carries buttons, but QNX ignores its Y coordinate,
#   so SH_POINTER=abs cannot align and is not shipped. Proof PNG is written to
#   <GUEST_DIR>/qnx-photon-desktop.png.
#
# HYGIENE (per project rules):
#   * Namespaced work dir + a unique monitor socket and pidfile. Torn down ONLY
#     via monitor `quit` / pidfile —
#     NEVER pkill-by-name — so it cannot disturb other gallery guests / CT 110 /
#     VM 900/925 / sibling OS builders.
#   * Touches ONLY <GUEST_DIR> (default /data/gallery-guests/QNX).
#
# Idempotent + re-runnable. Safe to run repeatedly on the real NVMe.
#
# Usage:
#   build-guests/tiles/qnx.sh [--dir DIR] [--force] [--no-verify] [--keep] [-h]
#     --dir DIR      output/guest dir      (default /data/gallery-guests/QNX)
#     --force        re-download even if a valid ISO is already present
#     --no-verify    just fetch the ISO; skip the drive-to-desktop framebuffer proof
#     --keep         leave the verify VM running after the proof (for station dev)
#     -h|--help      show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/QNX"
ISO_NAME="QNX650Live.iso"
# archive.org item "qnx-650-live" — the QNX 6.5.0 self-hosting LiveCD (~106 MB).
SRC_URL="https://archive.org/download/qnx-650-live/QNX650Live.iso"
ISO_SHA256="e22a2a75b2f4ec4be4a933590fd2bf9c9d8b6466b7c0b3553521d6ef005e4077"
FORCE=0
VERIFY=1
KEEP=0

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      GUEST_DIR="$2"
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
    --keep)
      KEEP=1
      shift
      ;;
    -h | --help)
      sed -n '2,64p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/qnx-build.XXXXXX")"
MONSOCK="${WORK}/mon.sock"
PIDFILE="${WORK}/qemu.pid"
PROOF_PNG="${GUEST_DIR}/qnx-photon-desktop.png"
PROOF_PPM="${WORK}/desktop.ppm"

QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

log() { printf '\033[1;36m[qnx]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[qnx] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # tear the verify VM down cleanly (monitor quit -> pidfile SIGTERM). NEVER pkill.
  if [ "$KEEP" = 1 ]; then
    # leave the VM AND its WORK dir (mon.sock + pidfile) so it stays manageable.
    printf '\033[1;36m[qnx]\033[0m --keep: VM left running. monitor=%s pidfile=%s\n' \
      "$MONSOCK" "$PIDFILE" >&2
    return 0
  fi
  [ -S "$MONSOCK" ] && mon "quit" 2>/dev/null || true
  sleep 1
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "${p:-}" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 1
      kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# ---- deps -------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "need curl"
command -v python3 >/dev/null 2>&1 || die "need python3 (monitor + framebuffer proof)"

mkdir -p "$GUEST_DIR"

# =============================================================================
# (1) DOWNLOAD + integrity check
# =============================================================================
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
iso_ok() { [ -s "$1" ] && [ "$(sha_of "$1")" = "$ISO_SHA256" ]; }

if [ "$FORCE" = 0 ] && iso_ok "$ISO_PATH"; then
  log "valid ISO already present -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1)); skipping download (use --force)."
else
  log "downloading QNX 6.5.0 self-hosting LiveCD:"
  log "  $SRC_URL"
  curl -fSL --retry 3 --retry-delay 3 -o "${ISO_PATH}.part" "$SRC_URL" ||
    die "download failed from $SRC_URL"
  got="$(sha_of "${ISO_PATH}.part")"
  if [ "$got" != "$ISO_SHA256" ]; then
    rm -f "${ISO_PATH}.part"
    die "SHA-256 mismatch: expected $ISO_SHA256 got $got"
  fi
  mv -f "${ISO_PATH}.part" "$ISO_PATH"
  log "installed -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1)), sha256 OK."
fi

# =============================================================================
# helpers: HMP monitor over unix socket and framebuffer probe
# =============================================================================
mon() { # mon CMD...  -> send HMP command(s) over the monitor unix socket
  python3 - "$MONSOCK" "$@" <<'PY' 2>/dev/null || true
import socket,sys,time
sock=sys.argv[1]; cmds=sys.argv[2:]
s=socket.socket(socket.AF_UNIX); s.settimeout(5)
try:
    s.connect(sock); time.sleep(0.2)
    for c in cmds:
        s.sendall((c+"\n").encode()); time.sleep(0.35)
    time.sleep(0.3)
finally:
    try: s.close()
    except Exception: pass
PY
}

fb_probe() { # echo "W H SHA" of the current framebuffer (via a monitor screendump)
  local ppm="${WORK}/_probe.ppm"
  rm -f "$ppm"
  mon "screendump ${ppm}"
  sleep 1
  [ -s "$ppm" ] || {
    echo "0 0 none"
    return
  }
  # PPM "P6\n<w> <h>\n255\n" + raw RGB. Hash the frame EXCLUDING the bottom rows,
  # so the blinking "Select? _" cursor doesn't defeat the stability check (static
  # menu text above stays constant; the boot-scan phase keeps changing there).
  python3 - "$ppm" <<'PY' 2>/dev/null || echo "0 0 none"
import sys,hashlib
d=open(sys.argv[1],'rb').read()
# parse ascii header (3 tokens after magic: w h maxval)
i=0; toks=[]
while len(toks)<4:
    while i<len(d) and d[i] in b' \t\r\n': i+=1
    j=i
    while j<len(d) and d[j] not in b' \t\r\n': j+=1
    toks.append(d[i:j]); i=j
off=i+1
try: w,h=int(toks[1]),int(toks[2])
except Exception: w,h=0,0
px=d[off:]
row=w*3
top=px[:max(0,(h-24)*row)] if (w and h) else px   # drop bottom 24 rows (cursor)
print(w,h,hashlib.sha1(top).hexdigest()[:12])
PY
}
fb_res() { fb_probe | awk '{print $1, $2}'; }

# =============================================================================
# (2) VERIFY / DRIVE — boot the LiveCD and drive it to the Photon DESKTOP
# =============================================================================
verify_boot() {
  [ -n "$QEMU_BIN" ] || {
    log "no qemu-system binary present — SKIPPING verify (ISO fetched)."
    return 0
  }

  local accel="" cpu="qemu64"
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel="-enable-kvm"
    cpu="host"
  fi
  log "verify: launching headless QEMU (${QEMU_BIN}, ${accel:-TCG}) …"
  # Exact production input/display device profile: cirrus VGA and PS/2 mouse;
  # no USB controller or tablet. NIC = e1000 (era-appropriate).
  "$QEMU_BIN" \
    -machine pc-i440fx-11.0 $accel -cpu "$cpu" -m 512 \
    -cdrom "$ISO_PATH" -boot d \
    -vga cirrus -rtc base=localtime \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -monitor "unix:${MONSOCK},server,nowait" \
    -pidfile "$PIDFILE" \
    -display none -daemonize ||
    die "QEMU failed to launch"

  # wait for the monitor socket
  local waited=0
  while [ ! -S "$MONSOCK" ] && [ $waited -lt 20 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -S "$MONSOCK" ] || die "monitor socket never appeared"

  # (a) BOOT MENU: the "Select?" prompt is 720x400 text mode — BUT so is the
  #     boot-scan phase before it, and an F2 sent mid-scan gets eaten (or worse,
  #     navigates a sub-menu). We can't tell them apart by resolution, so detect
  #     the menu by STABILITY: the menu is static (waiting for input) while the
  #     scan is still printing. Send F2 ONCE, only after two consecutive identical
  #     720x400 frames ~3s apart (and a minimum elapsed time as a guard).
  log "verify: waiting for the QNX boot menu (stable 720x400), then F2…"
  local i prev="" cur w h hsh f2=0 elapsed=0
  sleep 18
  elapsed=18
  for i in $(seq 1 40); do
    read -r w h hsh <<<"$(fb_probe)"
    if [ "$w" = 720 ] && [ "$h" = 400 ] && [ -n "$prev" ] && [ "$hsh" = "$prev" ] && [ "$elapsed" -ge 24 ]; then
      log "verify: boot menu stable (${w}x${h}); sending F2 (Run from CD)."
      mon "sendkey f2"
      f2=1
      break
    fi
    prev="$hsh"
    sleep 3
    elapsed=$((elapsed + 4))
  done
  [ "$f2" = 1 ] || die "verify FAILED — boot menu never stabilised at 720x400 (last ${w}x${h})"

  # (b) wait for the fresh 640x480 phgrafx wizard.
  log "verify: waiting for Photon Display Setup…"
  local i graphical=0
  for i in $(seq 1 24); do
    sleep 5
    res="$(fb_res)"
    case "$res" in 640\ 480 | 800\ 600 | 1024\ 768)
      graphical=1
      break
      ;;
    esac
  done
  [ "$graphical" = 1 ] || die "verify FAILED — never reached graphical mode (last res '${res}')"

  # (c) Driver=svga, Color=64K, Resolution=1024x768. The confirmation dialog's
  # Accept button has a working Alt+A mnemonic; no tablet/click is needed.
  log "verify: selecting devg-svga 64K 1024x768…"
  local k
  for k in tab tab tab down down tab tab tab tab tab spc; do
    mon "sendkey $k"
    sleep .3
  done
  sleep 2
  mon "sendkey alt-a"
  sleep 12
  [ "$(fb_res)" = "1024 768" ] || die "verify FAILED — 1024x768 mode was not accepted"

  # (d/e) leave phgrafx, then root / empty password.
  mon "sendkey alt-x"
  sleep 5
  log "verify: logging in as root (empty password)…"
  for k in r o o t ret ret; do
    mon "sendkey $k"
    sleep .3
  done
  sleep 12

  # capture the desktop proof
  log "verify: capturing the Photon desktop framebuffer…"
  mon "screendump ${PROOF_PPM}"
  sleep 2
  [ -s "$PROOF_PPM" ] || die "verify FAILED — no framebuffer captured"

  # sanity: a real Photon desktop is a colourful 1024x768 frame (many colours, not
  # near-black, not the flat grey wizard). Assert colour variety + non-trivial mean.
  python3 - "$PROOF_PPM" <<'PY' || die "verify FAILED — final frame does not look like the Photon desktop"
import sys
d=open(sys.argv[1],'rb').read()
# parse ascii PPM header
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(d); w=int(hdr[1]); h=int(hdr[2]); px=d[off:]
if (w,h) != (1024,768):
    print("[qnx] verify: wrong framebuffer %dx%d" % (w,h))
    sys.exit(1)
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]; seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
print("[qnx] verify: %dx%d, ~%d colours sampled, mean brightness %.1f" % (w,h,len(seen),mean))
sys.exit(0 if (len(seen) >= 12 and mean > 20) else 1)
PY

  # best-effort PPM -> PNG proof
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && log "verify: proof -> $PROOF_PNG"
  else
    cp "$PROOF_PPM" "${PROOF_PNG%.png}.ppm" && log "verify: proof -> ${PROOF_PNG%.png}.ppm (no PPM->PNG converter)"
  fi
  log "verify: PASS — QNX Neutrino 6.5.0 reached the Photon microGUI DESKTOP."
  [ "$KEEP" = 1 ] && log "verify: --keep set; leaving VM running (monitor ${MONSOCK})."
}

if [ "$VERIFY" = 1 ]; then
  verify_boot
else
  log "verify skipped (--no-verify)."
fi

# =============================================================================
# DONE — reference: how this ISO is wired into the neko+QEMU gallery.
#   See docs/guests/qnx.md for the production cirrus/1024/relative profile and
#   the F2 + phgrafx keyboard sequence; the LiveCD does not self-land.
# =============================================================================
cat <<EOF

============================================================================
QNX Neutrino 6.5.0 build complete.
  ISO                 : ${ISO_PATH}
  Desktop proof PNG   : ${PROOF_PNG}

Proven raw QEMU profile (QEMU 11.0.0, KVM), reached the Photon desktop:
  qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host -m 512 \\
    -cdrom QNX650Live.iso -boot d \\
    -vga cirrus -rtc base=localtime \\
    -netdev user,id=n0 -device e1000,netdev=n0 \\
    -audiodev pa,id=snd -device ac97,audiodev=snd

Drive-to-desktop sequence (all automated above / see tile-notes):
  1. stable final "Select?" menu -> F2 once (Run from CD)
  2. phgrafx -> Tab x3, Down x2, Tab x5, Space -> svga/64K/1024x768
  3. timed mode test -> Alt+A; phgrafx -> Alt+X
  4. login root / EMPTY password -> 1024x768 Photon desktop

Pitfalls baked in:
  * -vga cirrus, not std: std diverges the hardware and logical cursors.
  * No USB/tablet in the shipped device set. Hot-added UHCI tablet enumeration
    is reliable and buttons arrive, but Photon ignores Y (y=72 and y=696 both
    activate the bottom clock), so SH_POINTER=abs cannot align.
  * SH_POINTER=rel uses the existing bounded direct-relative daemon and the
    built-in PS/2 mouse; the launcher and golden contain no USB devices.
  * devg-svga is the stable 64K/1024x768 driver. It is unaccelerated; the
    accelerated devg-ati_rage128 experiment on QEMU ati-vga (1002:5046) could
    not start io-graphics, so it is not shipped.
  * F2 must be sent exactly once after the final menu stabilises.
============================================================================
EOF
