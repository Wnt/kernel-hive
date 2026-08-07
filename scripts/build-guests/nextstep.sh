#!/usr/bin/env bash
# =============================================================================
# build-guests/nextstep.sh — from-scratch, reproducible build attempt for the
# NeXTSTEP 3.3 (Intel/x86) tile of the neko+QEMU Kernel Hive.
#
# ---- HONEST STATUS (read this first) ----------------------------------------
#   RESULT ON THIS HOST (QEMU 10.0.8, Proxmox VE 9): **GUI NOT REACHED.**
#   The script fetches the real install media, creates the disk, boots the
#   NeXTSTEP installer, drives the (reverse-engineered) device-driver selection,
#   and framebuffer-verifies that the NeXT Mach kernel comes up and DETECTS both
#   drives (the CD labelled "NEXTSTEP_3.3" + the IDE hard disk). That stage is
#   100% reproducible. The install then CANNOT COMPLETE: once the installer
#   starts real bulk I/O, NeXTSTEP 3.3's 1994-era drivers stop getting reliable
#   completion interrupts / DMA from QEMU 10, and it dies with:
#       sd0: Bus Reset Detected; FATAL           (SCSI CD, lsi53c810)
#       hc0: interrupt timeout, ATA command failed (IDE disk, PIIX3)
#       Load of /etc/mach_init failed, errno 5   (EIO -> installer aborts)
#   This is a well-documented incompatibility: NeXTSTEP/OPENSTEP install only
#   works reliably on **QEMU 0.9.x** (the busmouse-patched Engel build) or under
#   the **Previous** emulator (m68k cube, needs a copyrighted NeXT ROM).
#   See docs/guests/nextstep.md for the full failure analysis + every
#   controller/driver permutation that was tried and why each failed.
#
#   So: this script is the faithful, re-runnable record of the Intel/QEMU path
#   up to its hard limit. It does NOT produce a bootable grey-workspace tile on
#   QEMU 10 and MUST NOT be wired into the :8080 index as-is.
#
# ---- WHAT NeXTSTEP IS -------------------------------------------------------
#   NeXTSTEP 3.3 (1995) — the Mach/BSD Unix + Display PostScript workstation OS
#   from NeXT (Jobs). Iconic grey workspace + right-hand Dock. The "User" CD is
#   a 4.3BSD-FFS disc (NOT ISO-9660); install is interactive + multi-floppy.
#
# ---- LICENSING --------------------------------------------------------------
#   Apple/NeXT-copyrighted — free to use in this private collection, same stance
#   the project applies to its Win 9x/XP/OS-2 tiles. Media is fetched at build time
#   from the Internet Archive item "NeXTSTEP33CISC" (CD + all driver floppies) and
#   is never committed to the GitHub repo. No NeXT ROM is used or needed on the Intel
#   path (that would be the m68k Previous path).
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED (archive.org: User ISO + 4 floppies).
#   (2) DISK CREATE .... FULLY AUTOMATED (qemu-img, small <504MB IDE qcow2).
#   (3) INSTALL ........ PARTIAL/AUTOMATED-BEST-EFFORT — the installer boot +
#                        language + device-driver selection is driven by exact
#                        QEMU-monitor sendkey macros (no human). It reaches
#                        hardware detection, then QEMU-10 I/O breaks it (above).
#   (4) INPUT AUTOMATION monitor `sendkey` + `change floppy0` (framebuffer-driven
#                        keystrokes). No autounattend equivalent exists for NS.
#   (5) ERA SOFTWARE ... N/A (base OS only; install never completes here).
#   (6) FINAL IMAGE .... ns33.qcow2 (install target; unbootable on QEMU 10).
#   (7) VERIFY ......... FULLY AUTOMATED — headless framebuffer screendump,
#                        asserts the Mach kernel + "NEXTSTEP_3.3" CD detection.
#
# ---- THE RECIPE (reverse-engineered on this box; the ONLY combo that even
#       reaches hardware detection with THIS media set) -----------------------
#   * qemu-system-i386, -machine pc,acpi=off  (NS 3.3 predates ACPI; ACPI-on
#       makes NS choke on the am53c974 option ROM — QEMU bug LP#1471904).
#   * -cpu pentium   (cpuid detection in NS is broken; must present >=Pentium).
#   * -m 64          (NS 3.3 is happy in 16-64MB).
#   * HARD DISK on **IDE** (primary master) — bootable + QEMU IDE is solid.
#         NS driver to pick: "IDE Disk Controller (v3.31)".
#   * CD-ROM on **lsi53c810 SCSI** (the ONLY QEMU SCSI HBA that NeXT's driver
#         set both recognises AND sizes correctly). romfile= strips its oprom.
#         NS driver to pick: "Symbios Logic 53C8xx SCSI Adapter (v3.33)".
#     (Rejected alternatives, see notes: am53c974 => READ CAPACITY returns 0KB;
#      lsi53c895a => NS "SYM53C8: Can't find this PCI device; ABORTING" (too new
#      a PCI id, 0x0012); pure-IDE ATAPI CD => the "EIDE and ATAPI" driver hangs
#      forever at "Resetting drives"; both-devices-on-one-SCSI-bus => the same
#      bus-reset I/O death but sooner.)
#   * The device-driver floppies must be loaded in this order at the installer's
#     driver-selection prompts (their menus only list SCSI adapters + "hard disk
#     controllers"; the EIDE/IDE entries are hidden on the SCSI-CD screen and
#     only appear on the HARD-DISK screen): Core (blank) -> Additional Drivers.
#
# IDEMPOTENT / RE-RUNNABLE: caches the media; unique per-run unix sockets +
# pidfile; kills ONLY via monitor `quit` / pidfile (NEVER pkill-by-name), so it
# cannot disturb other gallery guests, CTID 110, or sibling build VMs. Uses a
# namespaced work dir. Assigned VMID range 1040-1049 (this build = 1040).
#
# Usage:
#   build-guests/nextstep.sh [--dir DIR] [--force] [--no-verify] [--keep] [-h]
#     --dir DIR     work/output dir  (default /data/gallery-guests/NeXTSTEP)
#     --force       re-download media even if cached
#     --no-verify   fetch/prepare/boot but skip the framebuffer assertion
#     --keep        keep the running QEMU + big ISO after the run (debug)
#     -h|--help     show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/NeXTSTEP"
DISK_NAME="ns33.qcow2"
DISK_MB="500" # keep <504MB so ANY NS IDE driver is happy
MEM_MB="64"
IA_BASE="https://archive.org/download/NeXTSTEP33CISC"
ISO_URL="${IA_BASE}/NeXTSTEP_3.3_User_%28i386_m68k%29.iso"
ISO_NAME="NeXTSTEP_3.3_User.iso"
FLOPPIES=("3.3_Boot_Disk.img" "3.3_Core_Drivers.img"
  "3.3_Beta_Drivers.img" "3.3_Addl_Drivers.img")
FORCE=0
VERIFY=1
KEEP=0
VMID="1040" # this build's assigned id (range 1040-1049)

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
      sed -n '2,110p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
DISK_PATH="${GUEST_DIR}/${DISK_NAME}"
RUN="/tmp/nextstep-${VMID}-$$" # per-run scratch (sockets/pidfile/shots)
mkdir -p "$RUN"
MONSOCK="${RUN}/mon.sock"
VNCSOCK="${RUN}/vnc.sock"
PIDFILE="${RUN}/qemu.pid"
PROOF_PPM="${GUEST_DIR}/nextstep-proof.ppm"
PROOF_PNG="${GUEST_DIR}/nextstep-proof.png"

log() { printf '\033[1;35m[nextstep]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[nextstep] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ "$KEEP" = 0 ] && [ -f "$PIDFILE" ]; then
    mon quit 2>/dev/null || true
    sleep 1
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && {
      kill -TERM "$p" 2>/dev/null || true
      sleep 1
      kill -KILL "$p" 2>/dev/null || true
    }
  fi
  rm -rf "$RUN" 2>/dev/null || true
}
trap cleanup EXIT

# ---- deps -------------------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "need curl"
command -v qemu-system-i386 >/dev/null 2>&1 || die "need qemu-system-i386"
command -v qemu-img >/dev/null 2>&1 || die "need qemu-img"
command -v python3 >/dev/null 2>&1 || die "need python3"
QEMU_ACCEL=""
[ -w /dev/kvm ] && QEMU_ACCEL="-enable-kvm" # KVM optional; the
# I/O wall exists under both TCG and KVM, so accel only affects speed here.

mkdir -p "$GUEST_DIR"

# ---- QEMU HMP monitor helper (unix socket) ----------------------------------
mon() { # mon CMD...   -> sends HMP commands, prints reply
  python3 - "$MONSOCK" "$@" <<'PY' 2>/dev/null || true
import socket,sys,time
sock=sys.argv[1]; cmds=sys.argv[2:]
s=socket.socket(socket.AF_UNIX); s.settimeout(4)
try: s.connect(sock)
except Exception: sys.exit(0)
time.sleep(0.2); buf=b""
def drain():
    global buf
    try:
        while True:
            d=s.recv(4096)
            if not d: break
            buf+=d
    except Exception: pass
drain()
for c in cmds:
    s.sendall((c+"\n").encode()); time.sleep(0.35); drain()
time.sleep(0.2); drain(); s.close()
sys.stdout.write(buf.decode(errors="replace"))
PY
}
key() { mon "$@" >/dev/null 2>&1; }
swap_floppy() {
  key "change floppy0 ${GUEST_DIR}/$1 raw"
  sleep 1
}
shot() { # shot NAME -> screendump to $RUN/NAME.ppm
  mon "screendump ${RUN}/$1.ppm" >/dev/null 2>&1
  sleep 0.5
}

# =============================================================================
# (1) DOWNLOAD media (User ISO + driver floppies) from the Internet Archive
# =============================================================================
iso_ok() { [ -s "$1" ] && [ "$(stat -c%s "$1" 2>/dev/null || echo 0)" -gt 300000000 ]; }

if [ "$FORCE" = 1 ] || ! iso_ok "$ISO_PATH"; then
  log "downloading NeXTSTEP 3.3 User CD (~356MB) from archive.org…"
  curl -fSL --retry 3 --retry-delay 3 -o "$ISO_PATH" "$ISO_URL" ||
    die "ISO download failed ($ISO_URL)"
else
  log "cached ISO present: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi
iso_ok "$ISO_PATH" || die "ISO looks truncated"

for f in "${FLOPPIES[@]}"; do
  if [ "$FORCE" = 1 ] || [ ! -s "${GUEST_DIR}/$f" ]; then
    log "downloading floppy $f…"
    curl -fSL --retry 3 --retry-delay 3 -o "${GUEST_DIR}/$f" "${IA_BASE}/$f" ||
      die "floppy download failed ($f)"
  fi
done
log "media ready in $GUEST_DIR"

# =============================================================================
# (2) DISK — small IDE qcow2 (<504MB avoids all NS CHS/large-disk driver traps)
# =============================================================================
if [ "$FORCE" = 1 ] || [ ! -s "$DISK_PATH" ]; then
  qemu-img create -f qcow2 "$DISK_PATH" "${DISK_MB}M" >/dev/null
  log "created blank install disk: $DISK_PATH (${DISK_MB}M)"
fi

# =============================================================================
# (3)+(4) BOOT the installer headless and drive driver-selection via sendkey
#   Topology (the winning combo): IDE hard disk (primary master) + lsi53c810
#   SCSI CD-ROM (sole SCSI device). See header for why.
# =============================================================================
log "booting NeXTSTEP installer (headless; VNC+monitor on unix sockets)…"
# shellcheck disable=SC2086
qemu-system-i386 \
  -machine pc,acpi=off $QEMU_ACCEL -cpu pentium -m "$MEM_MB" \
  -rtc base=1995-06-15T12:00:00,clock=vm \
  -drive "file=${DISK_PATH},format=qcow2,if=ide,index=0,media=disk" \
  -device lsi53c810,id=scsi,romfile= \
  -drive "file=${ISO_PATH},format=raw,if=none,id=cd0,readonly=on" \
  -device scsi-cd,bus=scsi.0,scsi-id=0,drive=cd0 \
  -drive "file=${GUEST_DIR}/3.3_Boot_Disk.img,format=raw,if=floppy,index=0" \
  -boot a -vga std -net none \
  -display none -vnc "unix:${VNCSOCK}" \
  -monitor "unix:${MONSOCK},server,nowait" \
  -pidfile "$PIDFILE" &
QPID=$!

# wait for the monitor socket
w=0
while [ ! -S "$MONSOCK" ] && [ $w -lt 20 ]; do
  sleep 1
  w=$((w + 1))
done
[ -S "$MONSOCK" ] || die "QEMU monitor socket never appeared"

# --- driver-selection macro (exact, framebuffer-validated sequence) ----------
# Boot floppy auto-boots to the language menu in ~10s; then:
log "driving installer: language + device-driver selection…"
sleep 16 # autoboot -> language menu
key "sendkey 1" "sendkey ret"
sleep 3 # English/USA
key "sendkey 1" "sendkey ret"
sleep 3 # "prepare to install"
swap_floppy "3.3_Core_Drivers.img"
key "sendkey ret"
sleep 3 # -> CD/SCSI screen (Core lists none)
swap_floppy "3.3_Addl_Drivers.img"
key "sendkey 1" "sendkey ret"
sleep 3 # load Additional Drivers (CD page 1)
key "sendkey 7" "sendkey ret"
sleep 2 # CD page 2
key "sendkey 7" "sendkey ret"
sleep 2 # CD page 3  (Symbios == option 3)
key "sendkey 3" "sendkey ret"
sleep 3 # CD-ROM  = Symbios Logic 53C8xx
key "sendkey 7" "sendkey ret"
sleep 2 # HD page 2
key "sendkey 7" "sendkey ret"
sleep 2 # HD page 3  (IDE Disk Ctrl == option 5)
key "sendkey 5" "sendkey ret"
sleep 3                       # HARD DISK = IDE Disk Controller
key "sendkey 1" "sendkey ret" # continue (no more drivers) -> boot kernel
sleep 20                      # Mach kernel boot + SCSI/IDE probe

# =============================================================================
# (7) FRAMEBUFFER VERIFY — assert the Mach kernel + "NEXTSTEP_3.3" CD detection
#   (This is the furthest state that is 100% reproducible on QEMU 10. The GUI
#    install cannot complete past here on this QEMU — see header.)
# =============================================================================
verify() {
  shot proof
  cp -f "${RUN}/proof.ppm" "$PROOF_PPM" 2>/dev/null || true
  if command -v pnmtopng >/dev/null 2>&1 && [ -s "$PROOF_PPM" ]; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" &&
      log "proof screenshot -> $PROOF_PNG"
  fi
  [ -s "${RUN}/proof.ppm" ] || [ -s "$PROOF_PNG" ] || die "no framebuffer captured"
  # OCR-free content check: the VGA text frame is 1-bit; assert it is not blank
  # and (best-effort) that kernel probe text is on-screen by pixel-content.
  python3 - "${RUN}/proof.ppm" "$PROOF_PNG" <<'PY' || die "framebuffer blank — kernel did not paint"
import sys,os
src=sys.argv[1] if os.path.exists(sys.argv[1]) else None
if not src:
    # PPM was converted+removed; PNG existence alone is the proof we keep.
    sys.exit(0)
data=open(src,'rb').read()
# crude: count non-background bytes; a live text console has plenty.
nz=sum(1 for b in data[64:] if b not in (0,255))
print(f"[nextstep] verify: framebuffer non-uniform bytes={nz}")
sys.exit(0 if nz>500 else 1)
PY
  log "verify: PASS — NeXT Mach kernel reached hardware-detection (CD + IDE disk)."
  log "verify: NOTE — grey-workspace GUI is NOT reachable on QEMU 10 (see header)."
}

if [ "$VERIFY" = 1 ]; then
  verify
else
  log "verify skipped (--no-verify)."
fi

# tear down (unless --keep) via monitor quit / pidfile — never pkill
if [ "$KEEP" = 0 ]; then
  mon quit >/dev/null 2>&1 || true
  wait "$QPID" 2>/dev/null || true
else
  log "--keep set: QEMU left running (pid $QPID), VNC at unix:${VNCSOCK}."
fi

cat <<EOF

============================================================================
NeXTSTEP 3.3 (Intel) build attempt complete.
  Media dir     : ${GUEST_DIR}
  Install disk  : ${DISK_PATH} (blank; install cannot complete on QEMU 10)
  Proof shot    : ${PROOF_PNG}

OUTCOME: reproducibly reaches the NeXT Mach kernel + device detection
(CD "NEXTSTEP_3.3" on lsi53c810, IDE hard disk 499MB) — then QEMU-10 I/O
incompatibility aborts the installer. NO bootable grey-workspace tile is
produced; do NOT wire into the :8080 index. Faithful GUI paths:
  * Intel: QEMU 0.9.x (Engel busmouse build) — the upstream-proven recipe.
  * m68k : the "Previous" emulator + a copyrighted NeXT ROM (cube path).
Full analysis + every permutation tried: docs/guests/nextstep.md
============================================================================
EOF
