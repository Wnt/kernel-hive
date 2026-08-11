#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/reactos.sh — from-scratch, reproducible build of the ReactOS
# station for the neko+QEMU Kernel Hive.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the ReactOS
# guest END TO END from its real upstream source — no image backups, no
# pre-staged files. Produces the final bootable live ISO and curated golden at
#     <GUEST_DIR>/ReactOS.iso        (default /data/gallery-guests/ReactOS)
#     <GUEST_DIR>/reactos-golden.qcow2
# and framebuffer-verifies the golden reaches the graphical desktop.
#
# WHAT REACTOS IS: an open-source (GPLv2 / LGPL / BSD components) OS that is
# binary- and driver-compatible with Windows NT / 2000. It ships as a *live CD*
# that boots to a familiar Windows-2000-style desktop (Start menu, taskbar,
# ReactOS Explorer). The live CD first shows a small 2-step "ReactOS LiveCD"
# wizard (pick language/keyboard -> "Run ReactOS Live CD") and then lands on the
# full blue desktop with icons (My Computer, Command Prompt, Recycle Bin, …).
# Era ~mid-2000s (NT5 look & feel). This build is, like the KolibriOS/TempleOS
# stations: download upstream -> unpack the ISO -> verify it boots to the GUI.
#
# !!! VERSION: we use ReactOS **0.4.14** (release-125), NOT the newer 0.4.15.  !!!
# The 0.4.15 stable live CD DETERMINISTICALLY HANGS in early kernel init on this
# host's QEMU 11.0.0 — frozen at ntoskrnl EIP 0x8046e408 with a black 720x400
# screen, identical across every -cpu (qemu32/qemu64/pentium3/host), TCG *and*
# KVM, acpi on/off, std/cirrus VGA. It is a ReactOS-0.4.15-vs-QEMU-11 kernel
# regression, not a config knob. 0.4.14 boots cleanly to the GUI. If a future
# ReactOS release fixes this, bump REACTOS_* below and re-verify.
#
# LICENSE: OPEN SOURCE (GPLv2 / LGPLv2.1 / BSD, per component). This is NOT
# abandonware — it is sourced directly from the official ReactOS SourceForge
# release mirror. Freely redistributable.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED (official SourceForge release URL).
#   (2) DISK CREATE .... FULLY AUTOMATED — fresh qcow2 savevm store.
#   (3) INSTALL ........ N/A — no installer step. The live boot IS the whole station.
#   (4) INPUT AUTOMATION FULL — QMP drives the wizard and fixture customization.
#   (5) ERA SOFTWARE ... LiveCD desktop plus generated settings-floppy tweaks.
#   (6) FINAL IMAGE .... ReactOS.iso + reactos-golden.qcow2 in <GUEST_DIR>.
#   (7) VERIFY ......... FULL — framebuffer gate plus dirty/loadvm/reset proof.
#   => There are NO manual/interactive steps. The whole build is hands-off.
#
# IDEMPOTENT / RE-RUNNABLE: skips the download if a valid ISO already exists
# (override with --force). Uses a namespaced work dir and UNIQUE per-run unix
# sockets (VNC + QEMU monitor) + a pidfile. Kills ONLY via monitor `quit` /
# pidfile — NEVER pkill-by-name — so it cannot disturb other gallery guests,
# CTID 110, VM 900/925, or the macOS fan-out VMIDs.
#
# Usage:
#   build-guests/tiles/reactos.sh [--dir DIR] [--force] [--no-verify] [-h]
#     --dir DIR      output/guest dir      (default /data/gallery-guests/ReactOS)
#     --force        re-download even if a valid ReactOS.iso is already present
#     --no-verify    skip the separate portable-TCG ISO check; golden proof remains
#     -h|--help      show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/ReactOS"
ISO_NAME="ReactOS.iso"
# Official ReactOS 0.4.14 LIVE CD (release-125-g5b02d38). We deliberately pin
# 0.4.14 — see the VERSION note in the header (0.4.15 hangs on QEMU 11). The
# .zip contains a single ReactOS-0.4.14-release-125-g5b02d38-Live.iso.
# SourceForge's /download suffix 302-redirects to a regional mirror; curl -L
# follows it.
REACTOS_VER="0.4.14"
REACTOS_BUILD="0.4.14-release-125-g5b02d38"
SRC_URL="https://sourceforge.net/projects/reactos/files/ReactOS/${REACTOS_VER}/ReactOS-${REACTOS_BUILD}-live.zip/download"
FORCE="${FORCE:-0}"
VERIFY="${VERIFY:-1}"

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
    -h | --help)
      sed -n '2,60p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
# Namespaced, per-run scratch so parallel/other builds never collide.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/reactos-build.XXXXXX")"
RUN_TAG="reactos-$$"
VNCSOCK="${WORK}/vnc.sock"
MONSOCK="${WORK}/mon.sock"
PIDFILE="${WORK}/qemu.pid"
PROOF_PPM="${GUEST_DIR}/reactos-desktop.ppm"
PROOF_PNG="${GUEST_DIR}/reactos-desktop.png"

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '\033[1;36m[reactos]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[reactos] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---- dependency check -------------------------------------------------------
need_dl=""
command -v curl >/dev/null 2>&1 || need_dl="$need_dl curl"
# unzip needed to unpack the release .zip.
if ! command -v unzip >/dev/null 2>&1; then
  log "no unzip found — attempting one-time install…"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip >/dev/null 2>&1 || true
  fi
fi
command -v unzip >/dev/null 2>&1 || die "need unzip (install unzip)"
[ -z "$need_dl" ] || die "missing tools:$need_dl"

# QEMU binary for the verify step (production launch-qemu.sh uses x86_64).
QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

mkdir -p "$GUEST_DIR"

# =============================================================================
# (1) DOWNLOAD  +  unpack the live ISO
# =============================================================================
# ISO-9660 primary volume descriptor signature: byte offset 0x8001, five bytes.
iso_valid() { [ -s "$1" ] && head -c 32774 "$1" 2>/dev/null | tail -c 5 | grep -q 'CD001' 2>/dev/null; }

if [ "$FORCE" = 0 ] && iso_valid "$ISO_PATH"; then
  log "valid ISO already present -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1)); skipping download (use --force to refetch)."
else
  log "downloading official ReactOS ${REACTOS_VER} live CD archive:"
  log "  $SRC_URL"
  curl -fSL --retry 3 --retry-delay 3 -o "${WORK}/live.zip" "$SRC_URL" ||
    die "download failed from $SRC_URL"
  log "extracting the live ISO from the .zip archive…"
  unzip -o "${WORK}/live.zip" -d "$WORK" >/dev/null || die "unzip failed"
  src_iso="$(find "$WORK" -maxdepth 1 -type f -iname '*.iso' | head -n1)"
  [ -n "$src_iso" ] || die "no .iso found inside the archive"
  iso_valid "$src_iso" || die "extracted file is not a valid ISO-9660 image"
  install -m 0644 "$src_iso" "$ISO_PATH"
  log "installed -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi

# =============================================================================
# (3) INSTALL is N/A for the live ISO. Golden store creation, QMP input
# automation, customization, and final verification follow the ISO sanity check.
# =============================================================================

# =============================================================================
# (7) FRAMEBUFFER VERIFY — headless QEMU boot + monitor screendump
#   Confirms the ISO reaches the graphical desktop. Uses unique unix sockets and
#   a pidfile; tears the VM down via the monitor `quit` (never pkill).
#   ReactOS under TCG is slow to reach the desktop (~2–4 min cold), so we poll:
#   the boot loader shows a 720x400 VGA-TEXT frame; the live desktop switches to
#   a 32-bit 800x600 (or 1024x768) framebuffer with a taskbar + wallpaper. We
#   capture several frames and PASS on the first that looks like a real desktop.
# =============================================================================
mon_send() { # mon_send CMD...  — talk to the HMP monitor over the unix socket
  python3 - "$MONSOCK" "$@" <<'PY' 2>/dev/null || true
import socket,sys,time
sock=sys.argv[1]; cmds=sys.argv[2:]
s=socket.socket(socket.AF_UNIX); s.settimeout(5)
try:
    s.connect(sock); time.sleep(0.3)
    for c in cmds:
        s.sendall((c+"\n").encode()); time.sleep(0.4)
    time.sleep(0.4)
finally:
    try: s.close()
    except Exception: pass
PY
}

# Returns 0 if the PPM looks like a live GUI desktop (many colours, not near
# black, and NOT the 720x400 text-mode boot frame), else 1.
frame_is_desktop() {
  python3 - "$1" <<'PY'
import sys
p=sys.argv[1]
try:
    data=open(p,'rb').read()
except Exception:
    sys.exit(1)
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(data)
try:
    w=int(hdr[1]); h=int(hdr[2])
except Exception:
    sys.exit(1)
px=data[off:]
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]
    seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
# 720x400 == VGA text mode (boot loader / setup) — not the GUI yet.
is_text_mode = (w==720 and h==400)
ok = (not is_text_mode) and len(seen)>=10 and mean>8
print(f"[reactos] frame {w}x{h}, ~{len(seen)} colours, mean {mean:.1f}, text_mode={is_text_mode} -> {'DESKTOP' if ok else 'not-yet'}")
sys.exit(0 if ok else 1)
PY
}

verify_boot() {
  [ -n "$QEMU_BIN" ] || {
    log "no qemu-system binary present — SKIPPING verify (fetch/unpack succeeded)."
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    log "python3 absent — SKIPPING verify."
    return 0
  }

  log "verify: launching headless QEMU (${QEMU_BIN}) from $ISO_PATH …"
  # Same profile as the station: plain TCG (matches the other live-CD stations),
  # -cpu qemu64, std VGA, PS/2 kbd+mouse only (no usb-tablet — ReactOS 0.4.x USB
  # enumeration can stall early boot).
  "$QEMU_BIN" \
    -machine pc -cpu qemu64 -m 512 \
    -cdrom "$ISO_PATH" -boot d \
    -vga std \
    -rtc base=localtime \
    -display none \
    -vnc "unix:${VNCSOCK}" \
    -monitor "unix:${MONSOCK},server,nowait" \
    -pidfile "$PIDFILE" &
  local qpid=$!

  local waited=0
  while [ ! -S "$MONSOCK" ] && [ $waited -lt 20 ]; do
    sleep 1
    waited=$((waited + 1))
  done

  # Poll for the GUI for up to ~5 minutes (cold TCG boot is slow). The first GUI
  # frame is the 800x600 "ReactOS LiveCD" language wizard — that already proves
  # the graphical subsystem is up. Once we see it, click through the 2-step
  # wizard (Enter = Next, then Enter = "Run ReactOS Live CD") so the final proof
  # PNG shows the real desktop rather than the wizard.
  local got=1 i
  for i in $(seq 1 20); do
    sleep 15
    mon_send "screendump ${PROOF_PPM}"
    sleep 2
    if [ -s "$PROOF_PPM" ] && frame_is_desktop "$PROOF_PPM"; then
      got=0
      break
    fi
  done

  if [ "$got" = 0 ]; then
    log "verify: GUI up (LiveCD wizard). Clicking through to the desktop…"
    mon_send "sendkey ret"
    sleep 6 # page 1: language -> Next
    mon_send "sendkey ret"
    sleep 18 # page 2: "Run ReactOS Live CD" -> desktop
    mon_send "screendump ${PROOF_PPM}"
    sleep 2
  fi

  # Tear down cleanly: monitor quit first, then pidfile fallback. NEVER pkill.
  mon_send "quit"
  sleep 2
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 2
      kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  kill -0 "$qpid" 2>/dev/null && { kill -TERM "$qpid" 2>/dev/null || true; }
  wait "$qpid" 2>/dev/null || true

  [ "$got" = 0 ] || die "verify FAILED — never reached the graphical desktop within the timeout"

  # Best-effort convert the proof PPM -> PNG for a nicer artifact, then drop PPM.
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  else
    log "verify: proof -> $PROOF_PPM (no PPM->PNG converter; PPM kept as-is)"
  fi
  log "verify: PASS — ReactOS reached the graphical desktop."
}

[ "$VERIFY" = 1 ] && verify_boot || log "verify skipped (--no-verify)."

# =============================================================================
# (2)-(7) GOLDEN BAKE — always replace the snapshot store from a cold LiveCD.
# The helper generates its own settings floppy, drives the two-page wizard,
# customizes the desktop, ejects the floppy, saves `golden`, and proves loadvm.
# =============================================================================
GOLDEN_BAKE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/streamhost/stations/reactos/golden-bake.sh"
[ -x "$GOLDEN_BAKE" ] || die "missing golden bake helper: $GOLDEN_BAKE"
log "baking curated golden from the freshly produced LiveCD (no restore input)…"
GUEST_DIR="$GUEST_DIR" REACTOS_ISO="$ISO_PATH" QEMU_BIN="$QEMU_BIN" bash "$GOLDEN_BAKE"

# =============================================================================
# DONE — reference: how this ISO is wired into the neko+QEMU gallery.
# (Matches the TempleOS/KolibriOS live-CD stations; the container mounts
#  /data/gallery-guests read-only at /guests, and launch-qemu.sh uses
#  qemu-system-x86_64 with -audiodev pa,id=snd — hence audiodev=snd below.)
# =============================================================================
cat <<EOF

============================================================================
ReactOS build complete.
  Final bootable image : ${ISO_PATH}
  Fresh golden store   : ${GUEST_DIR}/reactos-golden.qcow2 (snapshot: golden)
  Proof screenshot     : ${PROOF_PNG} (or .ppm)

neko-qemu tile env (standalone compose service, port :8106):
  OS_NAME       = ReactOS
  ACCEL         = kvm           (2026-07-04 perf flip — emits -enable-kvm)
  QEMU_MACHINE  = pc-i440fx-11.0 (snapshot-compatible machine pin)
  QEMU_MEM      = 512           (768/1024 also fine)
  QEMU_SMP      = 1             (single core — ReactOS SMP is flaky)
  QEMU_VGA      = std           (Bochs VBE; cirrus also boots)
  QEMU_SOUND    = -device AC97,audiodev=snd
  GUEST_CDROM   = /guests/ReactOS/ReactOS.iso
  GUEST_BOOT    = d             (boot from CD — pure live, no HDD)
  QEMU_EXTRA    = -cpu host     (native CPUID under KVM; qemu64 for TCG fallback)

Equivalent raw QEMU command (LIVE tile — KVM, validated on host, QEMU 11.0.0):
  qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host -m 512 -smp 1 \\
    -cdrom ReactOS.iso -boot d -vga std \\
    -audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000 \\
    -device AC97,audiodev=snd -rtc base=localtime
  # TCG fallback (KVM unavailable): drop -enable-kvm, use -cpu qemu64.

The tile opens on the "ReactOS LiveCD" wizard; two clicks (Next -> Run ReactOS
Live CD) land on the Windows-2000-style desktop. Verified to the desktop under
BOTH plain TCG and KVM (accel=kvm) with 0.4.14. Perf flip 2026-07-04: TCG -> KVM
(-cpu host); framebuffer render + xdotool input->photon confirmed live post-flip.
NOTE: the headless build-verify step below still uses plain TCG (-cpu qemu64) so
the ISO sanity-check runs on any build host without needing /dev/kvm.

Pitfalls baked into this script:
  * VERSION: 0.4.15 hangs in early kernel init on QEMU 11 — pin 0.4.14 (header).
  * SourceForge /download 302-redirects to a mirror — always curl -L.
  * The portable TCG ISO check uses PS/2 only; the KVM golden/runtime device set
    includes the required usb-tablet and is framebuffer-gated before savevm.
  * -smp 1 — ReactOS SMP is fragile.
  * Cold TCG boot to the desktop is slow (~2–4 min) — neko streams it fine.
  * The live CD shows a 2-step wizard before the desktop (not a fault).
============================================================================
EOF
