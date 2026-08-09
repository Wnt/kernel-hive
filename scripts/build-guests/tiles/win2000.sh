#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/win2000.sh — from-scratch, reproducible build of the
# Windows 2000 Professional SP4 tile for the neko+QEMU Kernel Hive.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the Win2000
# guest END TO END from its real upstream source — NO image backups, NO
# pre-staged files. Produces the final bootable disk at
#     <GUEST_DIR>/win2k-pro.qcow2     (default /data/gallery-guests/Win2000)
# and framebuffer-verifies it reaches the Win2000 GUI.
#
# ---- WHAT THIS BUILD ACTUALLY IS (read this before editing) -----------------
# Win2000 is NOT installed from an ISO here. The dry-run box built it by taking
# a *pre-installed* Windows 2000 Pro SP4 VMware virtual machine (the WinWorld
# museum VM, mirrored on archive.org), converting its VMDK to qcow2, and then
# applying THREE offline "make it boot under QEMU/SeaBIOS i440fx" fixes, one
# offline PnP-wizard suppression, plus an offline era-software injection. A
# from-ISO unattended install of Win2000 is
# far more fragile (text-mode + GUI wizard keystroke automation); the pre-built
# WinWorld VM + geometry/registry fixes is the recipe that actually worked and
# is what this script reproduces faithfully.
#
# The three boot fixes (all discovered on the dry-run box; exact bytes/regs are
# transcribed below, verified against the shipped image via read-only qemu-nbd):
#   (A) MBR partition-1 start-CHS   01 01 00  ->  00 39 00
#       (repoint the CHS to the true partition start LBA 56 under SeaBIOS's
#        63-sector-per-track geometry; VMware wrote a CHS SeaBIOS mis-reads).
#   (B) NTFS VBR BPB sectors-per-track  0x38 (56) -> 0x3F (63)
#       (match the SeaBIOS INT13h geometry so NTLDR's INT13 maths line up).
#   (C) Registry MergeIDE into the SYSTEM hive: bind the PIIX3/PIIX4 IDE
#       controller (pci ven_8086 dev_7010 / dev_1230) to intelide + start
#       pciide/atapi/intelide at boot. Without this Win2000 STOP 0x7B
#       (INACCESSIBLE_BOOT_DEVICE) because the VMware VM's boot IDE driver
#       differs from QEMU's PIIX3. Plus CrashControl AutoReboot=0 so a bugcheck
#       stays on screen instead of rebooting (both control sets).
#   (D) FIRST BOOT, then registry ACPI\QEMU0002 ConfigFlags=2 in both control
#       sets. Windows must enumerate the PIIX3 controller and create the QEMU0002
#       instance before the latter is edited: pre-creating Enum\ACPI\QEMU0002 in
#       the pristine VMware hive makes this image STOP 0x7B. The first boot uses
#       the pinned live device set, then the existing instance is marked as a
#       failed install so its driverless wizard does not recur.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ......... FULLY AUTOMATED. Re-fetches the real 928 MB WinWorld
#                          VMware VM .7z from archive.org (URL below).
#   (2) DISK CREATE ...... FULLY AUTOMATED. qemu-img converts the VMDK inside
#                          the .7z to an 8 GiB qcow2. No blank disk is made —
#                          the OS is already installed in the VMware image.
#   (3) INSTALL .......... N/A — the WinWorld VM is already a fully installed,
#                          activated Win2000 Pro SP4. There is NO OS installer
#                          run here, hence NO answer file / sendkey / vncdotool
#                          sequence. (This is why it is reproducible & cheap.)
#   (4) INPUT AUTOMATION . A/B/C are applied offline. One automated priming boot
#                          persists QEMU's natural PIIX3/QEMU0002 enumeration;
#                          D is then applied offline. The final verifier dismisses
#                          the one remaining first-boot PnP dialog and restart
#                          prompt before capturing the desktop and golden state.
#   (5) ERA SOFTWARE ..... BEST-EFFORT, offline-injected into C:\RETRO\ (IE5 +
#                          Opera are already preinstalled in the VM). Each item
#                          is fetched from a period source INDEPENDENTLY and is
#                          NON-FATAL: a dead mirror logs a warning and is skipped
#                          — the OS image + boot fixes never depend on it. These
#                          URLs are the fragile part and WILL rot over time.
#   (6) FINAL IMAGE ...... win2k-pro.qcow2 in <GUEST_DIR>.
#   (7) VERIFY ........... FULLY AUTOMATED — headless QEMU + monitor screendump,
#                          asserts the framebuffer is a real (non-black) GUI.
#
#   MANUAL STEPS REMAINING AT RUNTIME OF THE GUEST:
#     * None for boot/login. Fix (D) suppresses the driverless VM-Generation-ID
#       wizard and the source VM already has automatic Administrator logon.
#     * The staged installers in C:\RETRO\Installers (Firefox/Winamp/DOSBox/GTA1)
#       remain ordinary optional interactive setups, run once by hand if wanted.
#
#   THE ONE GENUINELY UNCERTAIN INPUT: the archive.org WinWorld VM URL. It is
#   correct as of this writing (item id + filename verified), but archive.org
#   items can be renamed/removed. Override with --src-url if it 404s.
#
# IDEMPOTENT / RE-RUNNABLE: skips the big download if the .7z is already cached;
# skips conversion if a valid qcow2 already exists (override with --force).
# Namespaced work dir, a UNIQUE free /dev/nbdN, UNIQUE per-run VNC + QEMU-monitor
# sockets + a pidfile. Kills the verify VM ONLY via monitor `quit` / pidfile —
# NEVER pkill-by-name — so it cannot disturb other gallery guests, CTID 110,
# VM 900/920, or the macOS fan-out VMIDs. Detaches ONLY the nbd device it itself
# claimed.
#
# Usage:
#   build-guests/tiles/win2000.sh [--dir DIR] [--src-url URL] [--force]
#                           [--no-software] [--no-verify] [-h]
#     --dir DIR       output/guest dir      (default /data/gallery-guests/Win2000)
#     --src-url URL   override the WinWorld VMware VM .7z URL
#     --force         re-convert even if a valid win2k-pro.qcow2 already exists
#     --no-software   skip the C:\RETRO era-software injection (OS + fixes only)
#     --no-verify     skip the headless framebuffer boot check
#     -h|--help       show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUEST_DIR="/data/gallery-guests/Win2000"
IMG_NAME="win2k-pro.qcow2"
# Real upstream: the WinWorld museum's pre-installed Win2000 Pro SP4 VMware VM,
# mirrored on the Internet Archive. Item + filename verified. 928.6 MB .7z.
DEFAULT_SRC_URL="https://archive.org/download/Microsoft_Windows_2000_Professional_SP4_Virtual_Machine_VMware_WinWorld/Microsoft%20Windows%202000%20Professional%20SP4%20%5BVMware%20VM%5D.7z"
SRC_URL="$DEFAULT_SRC_URL"
# The inbox Cirrus driver ships inside this archive; there is no separate
# driver download. Keep the archive and extracted payload hashes pinned so a
# renamed/repacked museum image cannot silently change the display stack.
SRC_SHA256="d9388a7fd459eee9134d121304d1f8a945a2c03131e56f388ca96f183e36d0ca"
CIRRUS_DLL_SHA256="599cc1c2e3b548114d440229e45ed33b55ec89e39315cea7cbb7a066ed21675b"
CIRRUS_SYS_SHA256="9d5f3add8d0853ac11dfe459a1b8985a4f4150b91ee1e17131090b31e1881d36"
FORCE="${FORCE:-0}"
DO_SOFTWARE="${DO_SOFTWARE:-1}"
VERIFY="${VERIFY:-1}"

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      GUEST_DIR="$2"
      shift 2
      ;;
    --src-url)
      SRC_URL="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-software)
      DO_SOFTWARE=0
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h | --help)
      sed -n '2,120p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

IMG_PATH="${GUEST_DIR}/${IMG_NAME}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/win2000-build.XXXXXX")"
CACHE="${GUEST_DIR}/.cache" # persistent cache for the big .7z + sw
MNT="${WORK}/mnt"           # ntfs mount point (namespaced)
VNCSOCK="${WORK}/vnc.sock"
MONSOCK="${WORK}/mon.sock"
PIDFILE="${WORK}/qemu.pid"
PROOF_PPM="${GUEST_DIR}/win2k-desktop.ppm"
PROOF_PNG="${GUEST_DIR}/win2k-desktop.png"
NBD_DEV="" # the nbd we claim; set in claim_nbd()

log() { printf '\033[1;36m[win2000]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[win2000] WARN:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[win2000] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---- cleanup: unmount + detach ONLY our own nbd; never touch other devices --
cleanup() {
  set +e
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null
      sleep 2
      if kill -0 "$p" 2>/dev/null; then
        kill -KILL "$p" 2>/dev/null
      fi
    fi
  fi
  mountpoint -q "$MNT" 2>/dev/null && {
    sync
    umount "$MNT" 2>/dev/null
  }
  if [ -n "$NBD_DEV" ] && [ -e "$NBD_DEV" ]; then
    qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1
  fi
  rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

# ---- dependency check / one-time install ------------------------------------
ensure_tools() {
  local missing=""
  command -v curl >/dev/null 2>&1 || missing="$missing curl"
  command -v qemu-img >/dev/null 2>&1 || missing="$missing qemu-utils"
  command -v qemu-nbd >/dev/null 2>&1 || missing="$missing qemu-utils"
  command -v mount.ntfs-3g >/dev/null 2>&1 || command -v ntfs-3g >/dev/null 2>&1 || missing="$missing ntfs-3g"
  command -v hivexregedit >/dev/null 2>&1 || missing="$missing libwin-hivex-perl"
  command -v python3 >/dev/null 2>&1 || missing="$missing python3"
  # 7z (any of the common binary names)
  SEVENZ=""
  for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
    SEVENZ="$c"
    break
  }; done
  [ -n "$SEVENZ" ] || missing="$missing p7zip-full"

  if [ -n "$missing" ] && command -v apt-get >/dev/null 2>&1; then
    log "installing missing packages:$missing"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    # translate the needs into concrete debian packages
    local pkgs=""
    case "$missing" in *curl*) pkgs="$pkgs curl" ;; esac
    case "$missing" in *qemu-utils*) pkgs="$pkgs qemu-utils" ;; esac
    case "$missing" in *ntfs-3g*) pkgs="$pkgs ntfs-3g" ;; esac
    case "$missing" in *libwin-hivex-perl*) pkgs="$pkgs libwin-hivex-perl" ;; esac
    case "$missing" in *python3*) pkgs="$pkgs python3" ;; esac
    case "$missing" in *p7zip-full*) pkgs="$pkgs p7zip-full" ;; esac
    # shellcheck disable=SC2086 # $pkgs is a deliberately space-joined package-name list meant to word-split into apt-get args
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null 2>&1 || true
    for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
      SEVENZ="$c"
      break
    }; done
  fi

  command -v qemu-img >/dev/null 2>&1 || die "qemu-img missing (install qemu-utils)"
  command -v qemu-nbd >/dev/null 2>&1 || die "qemu-nbd missing (install qemu-utils)"
  command -v hivexregedit >/dev/null 2>&1 || die "hivexregedit missing (install libwin-hivex-perl)"
  command -v python3 >/dev/null 2>&1 || die "python3 missing"
  [ -n "$SEVENZ" ] || die "no 7z extractor (install p7zip-full)"
  { command -v mount.ntfs-3g >/dev/null 2>&1 || command -v ntfs-3g >/dev/null 2>&1; } ||
    die "ntfs-3g missing"
}

# ---- claim a FREE /dev/nbdN (never steal another build's device) ------------
claim_nbd() {
  modprobe nbd max_part=8 2>/dev/null || true
  [ -e /dev/nbd0 ] || die "nbd kernel module unavailable (need /dev/nbd*)"
  local n dev
  for n in $(seq 0 15); do
    dev="/dev/nbd${n}"
    [ -e "$dev" ] || continue
    # busy if it has a pid or a non-zero size
    if [ -f "/sys/block/nbd${n}/pid" ]; then continue; fi
    local sz
    sz="$(cat "/sys/block/nbd${n}/size" 2>/dev/null || echo 0)"
    [ "$sz" = "0" ] || continue
    NBD_DEV="$dev"
    return 0
  done
  die "no free /dev/nbdN device (all 0-15 busy)"
}

mkdir -p "$GUEST_DIR" "$CACHE" "$MNT"
ensure_tools

# =============================================================================
# (1) DOWNLOAD the WinWorld VMware VM archive (cached)
# =============================================================================
ARCHIVE="${CACHE}/win2k-winworld-vmware.7z"
if [ -s "$ARCHIVE" ]; then
  log "WinWorld VM archive already cached -> $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)); skipping download."
else
  log "downloading WinWorld Win2000 Pro SP4 VMware VM (~928 MB):"
  log "  $SRC_URL"
  curl -fSL --retry 4 --retry-delay 5 -o "${ARCHIVE}.part" "$SRC_URL" ||
    die "download failed ($SRC_URL). If the archive.org item moved, pass --src-url."
  mv "${ARCHIVE}.part" "$ARCHIVE"
  log "downloaded -> $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
fi

if [ "$SRC_URL" = "$DEFAULT_SRC_URL" ]; then
  log "verifying pinned WinWorld source archive SHA-256…"
  printf '%s  %s\n' "$SRC_SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null ||
    die "WinWorld archive SHA-256 mismatch (expected $SRC_SHA256)"
else
  warn "custom --src-url is not covered by the pinned default-source SHA-256"
fi

# =============================================================================
# (2) CONVERT the VMDK inside the .7z to an 8 GiB qcow2
# =============================================================================
qcow2_valid() { qemu-img info "$1" >/dev/null 2>&1 && [ "$(qemu-img info --output=json "$1" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["virtual-size"])' 2>/dev/null)" = "8589934592" ]; }

if [ "$FORCE" = 0 ] && [ -s "$IMG_PATH" ] && qcow2_valid "$IMG_PATH"; then
  log "valid qcow2 already present -> $IMG_PATH ($(du -h "$IMG_PATH" | cut -f1)); skipping convert (use --force)."
else
  log "extracting VMware VM from the .7z…"
  "$SEVENZ" x -y -o"${WORK}/vm" "$ARCHIVE" >/dev/null || die "7z extraction failed"
  # Find the VMDK descriptor qemu-img can actually read (skip -flat/-sNNN extents).
  SRC_VMDK=""
  while IFS= read -r cand; do
    if qemu-img info "$cand" >/dev/null 2>&1; then
      SRC_VMDK="$cand"
      break
    fi
  done < <(find "${WORK}/vm" -type f -iname '*.vmdk' ! -iname '*-flat.vmdk' | sort)
  [ -n "$SRC_VMDK" ] || die "no readable .vmdk found inside the archive"
  log "converting $(basename "$SRC_VMDK") -> $IMG_NAME (qcow2)…"
  qemu-img convert -p -O qcow2 "$SRC_VMDK" "${IMG_PATH}.tmp" || die "qemu-img convert failed"
  mv "${IMG_PATH}.tmp" "$IMG_PATH"
  qcow2_valid "$IMG_PATH" || warn "converted qcow2 virtual size != 8 GiB (source image may differ from the one this recipe was tuned on — boot-fix byte offsets are self-checked below)."
  log "converted -> $IMG_PATH ($(du -h "$IMG_PATH" | cut -f1))"
fi

# =============================================================================
# (A/B/C) OFFLINE BOOT FIXES  —  attach qcow2 via qemu-nbd (raw block view)
# =============================================================================
claim_nbd
log "attaching $IMG_PATH via ${NBD_DEV} (read/write)…"
qemu-nbd --connect="$NBD_DEV" -f qcow2 "$IMG_PATH" || die "qemu-nbd connect failed"
# settle + re-read partition table
sleep 1
partprobe "$NBD_DEV" 2>/dev/null || true
sleep 1

# ---- (A) MBR partition-1 start-CHS  01 01 00 -> 00 39 00
#      and (B) NTFS VBR BPB sectors-per-track  56 -> 63.
#   Both are raw single-byte writes. The patcher READS current bytes first,
#   applies only if they match the known VMware value, and is a NO-OP if already
#   patched (idempotent). VBR offset is computed from the MBR's LBA field so it
#   follows the real partition start, not a hard-coded sector number.
log "applying disk boot fixes (A: MBR CHS, B: NTFS VBR sectors/track)…"
python3 - "$NBD_DEV" <<'PY' || die "disk boot-fix patch failed"
import sys, struct
dev = sys.argv[1]
with open(dev, "r+b", buffering=0) as f:
    f.seek(0); mbr = f.read(512)
    if mbr[510:512] != b"\x55\xaa":
        raise SystemExit("no MBR 0x55AA signature — not the expected disk")
    e = 0x1BE                                    # partition entry 1
    chs = mbr[e+1:e+4]                           # start-CHS (head, sec/cylhi, cyllo)
    lba = struct.unpack_from("<I", mbr, e+8)[0]  # partition-1 start LBA

    # (A) start-CHS  01 01 00 -> 00 39 00
    if chs == b"\x01\x01\x00":
        f.seek(e+1); f.write(b"\x00\x39\x00")
        print(f"[win2000]   (A) MBR CHS 01 01 00 -> 00 39 00  (part start LBA {lba})")
    elif chs == b"\x00\x39\x00":
        print("[win2000]   (A) MBR CHS already 00 39 00 — skip (idempotent)")
    else:
        print(f"[win2000]   (A) WARN: MBR CHS is {chs.hex(' ')} (expected 01 01 00) — "
              f"source image differs; leaving as-is")

    # (B) NTFS VBR BPB 'sectors per track' at VBR+0x18 : 0x38 (56) -> 0x3F (63)
    vbr_off = lba * 512
    f.seek(vbr_off); vbr = f.read(512)
    if vbr[3:7] not in (b"NTFS", b"NTFS"):  # OEM id 'NTFS    '
        pass  # keep going; check the value anyway
    spt = struct.unpack_from("<H", vbr, 0x18)[0]
    if spt == 56:
        f.seek(vbr_off + 0x18); f.write(struct.pack("<H", 63))
        print(f"[win2000]   (B) VBR@{vbr_off} sectors/track 56 -> 63")
    elif spt == 63:
        print("[win2000]   (B) VBR sectors/track already 63 — skip (idempotent)")
    else:
        print(f"[win2000]   (B) WARN: VBR sectors/track is {spt} (expected 56) — leaving as-is")
    f.flush()
import os
os.sync()
PY

# ---- (C) Registry MergeIDE + AutoReboot=0 into the SYSTEM hive ---------------
# mount partition 1 read/write via ntfs-3g (also clears the NTFS 'dirty' flag).
PART="${NBD_DEV}p1"
[ -e "$PART" ] || PART="${NBD_DEV}" # fallback: whole-device fs (unpartitioned)
log "mounting ${PART} (ntfs-3g) at ${MNT}…"
mount -t ntfs-3g -o rw "$PART" "$MNT" || die "ntfs-3g mount failed ($PART)"

# locate the SYSTEM hive (Win2000 lives in \WINNT, not \WINDOWS; be case-robust)
SYS_HIVE="$(find "$MNT" -maxdepth 4 -type f \
  -ipath '*/win*/system32/config/system' -print -quit 2>/dev/null)"
[ -n "$SYS_HIVE" ] || die "could not find the SYSTEM hive under $MNT (expected WINNT\\system32\\config\\system)"
log "SYSTEM hive: ${SYS_HIVE#"$MNT"}"

# Win2000's inbox Cirrus Logic 5446 driver is the shipped high-resolution
# path. Device Manager identifies it as Microsoft 5.0.2184.1 (1999-11-18).
# Verify its two loaded payloads before relying on the GUI mode-set below.
CIRRUS_DLL="$(find "$MNT" -type f -ipath '*/winnt/system32/cirrus.dll' -print -quit 2>/dev/null)"
CIRRUS_SYS="$(find "$MNT" -type f -ipath '*/winnt/system32/drivers/cirrus.sys' -print -quit 2>/dev/null)"
[ -n "$CIRRUS_DLL" ] && [ -n "$CIRRUS_SYS" ] ||
  die "inbox Cirrus 5446 driver payloads are missing"
printf '%s  %s\n' "$CIRRUS_DLL_SHA256" "$CIRRUS_DLL" | sha256sum -c - >/dev/null ||
  die "cirrus.dll SHA-256 mismatch"
printf '%s  %s\n' "$CIRRUS_SYS_SHA256" "$CIRRUS_SYS" | sha256sum -c - >/dev/null ||
  die "cirrus.sys SHA-256 mismatch"
log "inbox Cirrus 5446 driver verified (Microsoft 5.0.2184.1)."

# --- generate the registry payloads (exact transcription of the dry-run box) --
cat >"${WORK}/mergeide.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_8086&dev_7010]
"Service"="intelide"
"ClassGUID"="{4D36E96A-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\pci#ven_8086&dev_1230]
"Service"="intelide"
"ClassGUID"="{4D36E96A-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\primary_ide_channel]
"Service"="atapi"
"ClassGUID"="{4D36E96A-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CriticalDeviceDatabase\secondary_ide_channel]
"Service"="atapi"
"ClassGUID"="{4D36E96A-E325-11CE-BFC1-08002BE10318}"

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\pciide]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\atapi]
"Start"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Services\intelide]
"Start"=dword:00000000
REG

cat >"${WORK}/noreboot.reg" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\CrashControl]
"AutoReboot"=dword:00000000

[HKEY_LOCAL_MACHINE\SYSTEM\ControlSet002\Control\CrashControl]
"AutoReboot"=dword:00000000
REG

QUIET_PNP_REG="${SCRIPT_DIR}/../assets/win2000/qemu0002-failedinstall.reg"
[ -f "$QUIET_PNP_REG" ] || die "missing QEMU0002 registry payload: $QUIET_PNP_REG"

# hivexregedit merges the .reg paths (rooted at HKLM\SYSTEM) into the hive.
log "(C) merging MergeIDE + AutoReboot=0 into the SYSTEM hive…"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYS_HIVE" "${WORK}/mergeide.reg" ||
  die "hivexregedit MergeIDE merge failed"
hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYS_HIVE" "${WORK}/noreboot.reg" ||
  die "hivexregedit AutoReboot merge failed"
log "(C) registry boot fix applied; (D) follows the required first QEMU boot."

# =============================================================================
# (5) ERA SOFTWARE — offline inject into C:\RETRO\  (IE5 + Opera already in VM)
#   BEST-EFFORT: each item fetched independently; a dead mirror is a warning,
#   not a failure. DOS games run via the staged DOSBox; installers are staged
#   for one-click run inside the guest. Sources are period/free/shareware.
# =============================================================================
inject_software() {
  local RETRO="${MNT}/RETRO"
  mkdir -p "${RETRO}/Installers" "${RETRO}/Games"

  # name | url | destination-relative-to-C:\RETRO
  # (dest ending in / => keep archive/exe as-is; a plain path => that filename)
  # NOTE: these are the fragile links. Update here if a mirror rots.
  local items=(
    "Firefox 2.0.0.20|https://ftp.mozilla.org/pub/firefox/releases/2.0.0.20/win32/en-US/Firefox%20Setup%202.0.0.20.exe|Installers/FirefoxSetup-2.0.0.20.exe"
    "DOSBox 0.74-3|https://sourceforge.net/projects/dosbox/files/dosbox/0.74-3/DOSBox0.74-3-win32-installer.exe/download|Installers/DOSBox0.74-3-win32-installer.exe"
    "Winamp 2.95|https://archive.org/download/winamp2.95/winamp295.exe|Installers/winamp295.exe"
    "GTA 1 (Rockstar free)|https://archive.org/download/grandtheftauto1997rockstargames/GTAINSTALLER.exe|Installers/GTAINSTALLER.exe"
    "DOOM shareware v1.9|https://archive.org/download/DoomsharewareEpisode/doom19s.zip|Games/doom19s.zip"
    "Duke Nukem 3D shareware|https://archive.org/download/3D_Realms_Duke_Nukem_3D_Shareware/3D%20Realms%20-%20Duke%20Nukem%203D%20%28Shareware%20Version%29.zip|Games/duke3d_sw.zip"
    "Quake shareware v1.06|https://archive.org/download/QuakeShareware_201802/quake106.zip|Games/quake_msdos.zip"
    "Freedoom 0.12.1|https://github.com/freedoom/freedoom/releases/download/v0.12.1/freedoom-0.12.1.zip|Games/freedoom-0.12.1.zip"
  )

  local it name url dest cachef ok=0 tot=0
  for it in "${items[@]}"; do
    IFS='|' read -r name url dest <<<"$it"
    tot=$((tot + 1))
    cachef="${CACHE}/$(basename "$dest")"
    if [ ! -s "$cachef" ]; then
      log "  fetch: ${name}"
      if ! curl -fSL --retry 2 --retry-delay 3 -o "${cachef}.part" "$url" 2>/dev/null; then
        warn "  ${name}: download failed (${url}) — SKIPPED (non-fatal)"
        rm -f "${cachef}.part"
        continue
      fi
      mv "${cachef}.part" "$cachef"
    else
      log "  cached: ${name}"
    fi
    install -D -m 0644 "$cachef" "${RETRO}/${dest}"
    ok=$((ok + 1))
  done

  # Desktop README (All Users) so the tile explains itself.
  local ALLUSERS
  ALLUSERS="$(find "$MNT" -maxdepth 3 -type d -ipath '*/Documents and Settings/All Users/Desktop' -print -quit 2>/dev/null)"
  local readme="${RETRO}/RETRO-README.txt"
  cat >"$readme" <<'TXT'
Windows 2000 Professional — Kernel Hive retro tile
==================================================
Preinstalled browsers: Internet Explorer 5  +  Opera.

C:\RETRO\Installers\  — run once by hand (ordinary setups):
    Firefox 2.0.0.20, Winamp 2.95, DOSBox 0.74-3, GTA 1 (Rockstar free).
C:\RETRO\Games\       — DOS shareware, play via DOSBox:
    DOOM 1.9, Duke Nukem 3D 1.3d, Quake 1.06, Freedoom (bonus WADs).

Note: QEMU's driverless VM-Generation-ID device is pre-marked as a failed install
offline, so its Found New Hardware wizard stays suppressed on cold boot.
TXT
  cp -f "$readme" "${RETRO}/" 2>/dev/null || true
  [ -n "$ALLUSERS" ] && cp -f "$readme" "${ALLUSERS}/RETRO-README.txt" 2>/dev/null || true

  log "software staged: ${ok}/${tot} items into C:\\RETRO (README on All-Users desktop)."
}

if [ "$DO_SOFTWARE" = 1 ]; then
  log "injecting era software into C:\\RETRO …"
  inject_software
else
  log "software injection skipped (--no-software)."
fi

# ---- flush + detach (via our own trap-safe path, but do it explicitly now) ---
sync
umount "$MNT" || die "umount failed"
qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
NBD_DEV=""
log "boot fixes + software committed; disk detached."

# =============================================================================
# (D) PRIME QEMU ENUMERATION, THEN SUPPRESS THE DRIVERLESS QEMU0002 WIZARD
# (7) FRAMEBUFFER VERIFY + GOLDEN — pinned live profile, real desktop proof
# =============================================================================
QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

mon_send() { # talk to the HMP monitor over the unix socket
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

QEMU_PID=""
launch_pinned() {
  local kvm=()
  [ -w /dev/kvm ] && kvm=(-enable-kvm)
  rm -f "$VNCSOCK" "$MONSOCK" "$PIDFILE"
  "$QEMU_BIN" \
    -machine pc-i440fx-11.0 "${kvm[@]}" -cpu host -m 512 -smp 1 \
    -drive file="$IMG_PATH",format=qcow2,if=ide,index=0,media=disk \
    -boot c -vga cirrus \
    -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
    -netdev user,id=n0 -device rtl8139,netdev=n0 \
    -usb -device usb-tablet \
    -rtc base=localtime -no-reboot \
    -display none \
    -vnc "unix:${VNCSOCK}" \
    -monitor "unix:${MONSOCK},server,nowait" \
    -pidfile "$PIDFILE" &
  QEMU_PID=$!

  local waited=0
  while [ ! -S "$MONSOCK" ] && [ $waited -lt 20 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  [ -S "$MONSOCK" ] || die "QEMU monitor did not appear"
}

wait_for_win2000() {
  # Win2000 cold boot to the GUI: ~30-60s on KVM, longer on TCG. Wait generously.
  if [ -w /dev/kvm ]; then sleep 75; else sleep 150; fi
}

stop_qemu_by_pidfile() {
  mon_send "quit"
  sleep 2
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 2
      if kill -0 "$p" 2>/dev/null; then
        kill -KILL "$p" 2>/dev/null || true
      fi
    fi
  fi
  if [ -n "$QEMU_PID" ]; then
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  QEMU_PID=""
}

shutdown_win2000_cleanly() {
  local p="" i
  [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null || true)"
  log "verify: shutting Windows down cleanly so the cold-boot disk is not dirty…"
  mon_send "sendkey ctrl-esc"
  sleep 2
  mon_send "sendkey u"
  sleep 3
  mon_send "sendkey ret"
  for i in $(seq 1 120); do
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || break
    sleep 0.5
  done
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    warn "guest shutdown timed out; falling back to this run's pidfile"
    stop_qemu_by_pidfile
    return
  fi
  if [ -n "$QEMU_PID" ]; then
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  QEMU_PID=""
}

set_cirrus_hires() {
  log "verify: setting inbox Cirrus 5446 to 1024x768 High Color (16 bit)…"
  # Start -> Run -> desk.cpl. The HMP monitor has no text verb, so spell the
  # short command with deterministic sendkey events.
  mon_send "sendkey ctrl-esc"
  sleep 1
  mon_send "sendkey r"
  sleep 1
  mon_send \
    "sendkey d" "sendkey e" "sendkey s" "sendkey k" "sendkey dot" \
    "sendkey c" "sendkey p" "sendkey l" "sendkey ret"
  sleep 4

  # Display Properties opens on Background. Move to Settings, where focus is
  # the Colors combo: Home, Down selects High Color (16 bit). Tab moves to the
  # screen-area slider: Home, Right, Right selects 1024 by 768.
  local i
  for i in 1 2 3 4 5; do mon_send "sendkey ctrl-tab"; done
  mon_send "sendkey home" "sendkey down" "sendkey tab" \
    "sendkey home" "sendkey right" "sendkey right"
  sleep 1

  # Apply -> acknowledge the pre-switch warning. The keep-settings dialog
  # deliberately defaults to No; Left, Enter selects Yes before its 15s timer.
  mon_send "sendkey alt-a"
  sleep 1
  mon_send "sendkey ret"
  sleep 4
  mon_send "sendkey left" "sendkey ret"
  sleep 3
  mon_send "sendkey ret" # close Display Properties
  sleep 3
}

validate_framebuffer() {
  [ -s "$PROOF_PPM" ] || die "verify FAILED — no framebuffer captured (did not reach GUI?)"

  # Assert the frame is a real GUI (colour variety + non-black), not a STOP 0x7B
  # blue-screen-of-text or a black screen. Run this before savevm so a failed
  # build cannot leave a misleading snapshot named 'golden'.
  python3 - "$PROOF_PPM" <<'PY' || die "verify FAILED — framebuffer looks blank/near-black (boot fix may not have taken)"
import sys
p=sys.argv[1]
data=open(p,'rb').read()
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(data)
magic=hdr[0]; w=int(hdr[1]); h=int(hdr[2]); px=data[off:]
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]; seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
print(f"[win2000] verify: {magic.decode(errors='replace')} {w}x{h}, ~{len(seen)} colours, mean brightness {mean:.1f}")
sys.exit(0 if (w == 1024 and h == 768 and len(seen) >= 8 and mean > 8) else 1)
PY
}

prime_qemu_hardware() {
  [ -n "$QEMU_BIN" ] || die "no qemu-system binary — required for the SCSI-to-IDE transition boot"
  log "(D) priming one pinned-profile boot so Windows enumerates PIIX3 and QEMU0002 naturally…"
  launch_pinned
  wait_for_win2000
  stop_qemu_by_pidfile

  claim_nbd
  qemu-nbd --connect="$NBD_DEV" -f qcow2 "$IMG_PATH" || die "qemu-nbd connect failed after priming boot"
  sleep 1
  partprobe "$NBD_DEV" 2>/dev/null || true
  sleep 1
  local part="${NBD_DEV}p1"
  [ -e "$part" ] || part="$NBD_DEV"
  mount -t ntfs-3g -o rw "$part" "$MNT" || die "ntfs-3g mount failed after priming boot"
  SYS_HIVE="$(find "$MNT" -maxdepth 4 -type f -ipath '*/win*/system32/config/system' -print -quit 2>/dev/null)"
  [ -n "$SYS_HIVE" ] || die "SYSTEM hive missing after priming boot"

  # Do not create this path in a pristine hive. That premature creation was the
  # reproducible 0x7B regression; Windows must create the full instance first.
  hivexregedit --export --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYS_HIVE" \
    '\ControlSet001\Enum\ACPI\QEMU0002\3&267a616a&0' >/dev/null 2>&1 ||
    die "priming boot did not create the expected QEMU0002 instance"
  log "(D) QEMU0002 exists; marking its instance failed-install in both control sets…"
  hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYS_HIVE" "$QUIET_PNP_REG" ||
    die "hivexregedit QEMU0002 ConfigFlags merge failed"
  sync
  umount "$MNT" || die "umount failed after QEMU0002 merge"
  qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  NBD_DEV=""
  log "(D) two-pass controller/PnP transition complete."
}

verify_boot() {
  [ -n "$QEMU_BIN" ] || die "no qemu-system binary — cannot framebuffer-verify or bake golden"
  log "verify: launching the pinned live profile from $IMG_PATH …"
  # AC97 uses QEMU's silent backend here; omitting the guest-visible device
  # would make the saved VM state incompatible with the live launcher.
  launch_pinned
  wait_for_win2000

  # The first pinned-profile boot installs several built-in devices. QEMU0002
  # is now suppressed, but one non-recurring PnP wizard and its restart prompt
  # remain. Escape cancels the wizard; Right+Enter selects 'No' on restart.
  log "verify: dismissing the remaining first-boot PnP dialog and restart prompt…"
  mon_send "sendkey esc"
  sleep 12
  mon_send "sendkey right" "sendkey ret"
  sleep 10

  set_cirrus_hires

  # Prove that the display selection survives a real disk boot before the
  # golden is captured. A clean power-off also leaves NTFS/bootstat clean.
  shutdown_win2000_cleanly
  log "verify: cold-booting once more to prove the 1024x768x16 mode persists…"
  launch_pinned
  wait_for_win2000
  sleep 10

  log "verify: capturing exact 1024x768 framebuffer via monitor screendump…"
  mon_send "screendump ${PROOF_PPM}"
  sleep 2
  validate_framebuffer

  log "verify: replacing internal snapshot 'golden' with this settled desktop…"
  mon_send "delvm golden" "savevm golden"
  sleep 10

  shutdown_win2000_cleanly

  qemu-img snapshot -l "$IMG_PATH" | awk '$2 == "golden" { found=1 } END { exit !found }' ||
    die "verify FAILED — internal snapshot 'golden' was not created"

  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  else
    log "verify: proof -> $PROOF_PPM (no PPM->PNG converter available)"
  fi
  log "verify: PASS — Win2000 reached 1024x768x16 on inbox Cirrus; internal snapshot 'golden' exists."
}

prime_qemu_hardware
if [ "$VERIFY" = 1 ]; then
  verify_boot
else
  log "verify skipped (--no-verify)."
fi

# =============================================================================
# DONE — how this image is wired into the neko+QEMU gallery (from the manifest
#         + the dry-run box helper win2k-boot.sh).
# =============================================================================
cat <<EOF

============================================================================
Windows 2000 Professional SP4 build complete.
  Final bootable image : ${IMG_PATH}
  Proof screenshot     : ${PROOF_PNG} (or .ppm)

neko-qemu tile env (per retro-gallery-guests.md):
  OS_NAME       = Windows 2000 Professional
  QEMU_MACHINE  = pc-i440fx-11.0  # pinned live i440FX/PIIX profile; ACPI on
  QEMU_MEM      = 512
  QEMU_VGA      = cirrus
  DISPLAY_MODE  = 1024x768x16     # inbox Cirrus Logic 5446 driver 5.0.2184.1
  QEMU_SOUND    = -device AC97,audiodev=snd
  GUEST_DISK    = /guests-retro/Win2000/win2k-pro.qcow2
  GUEST_FMT     = qcow2
  GUEST_BOOT    = c               # HDD boot=c (IDE primary master)
  QEMU_EXTRA    = -enable-kvm -cpu host -smp 1 -netdev user,id=n0 -device rtl8139,netdev=n0
                  -usb -device usb-tablet
                  # NORMAL modern KVM recipe (NT 5.0 kernel/ACPI HAL). accel=kvm +
                  # -cpu host + -smp 1, mirroring the working winxp tile. Do NOT apply
                  # the Win9x knobs (kernel-irqchip=off / -cpu pentium,-apic) here — the
                  # NT HAL has real APIC/ACPI. The builder performs the required priming
                  # boot and bakes the settled post-PnP desktop as internal snapshot golden.

Equivalent raw QEMU command (validated pinned live profile):
  qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host -m 512 -smp 1 \\
    -drive file=win2k-pro.qcow2,format=qcow2,if=ide,index=0,media=disk \\
    -boot c -vga cirrus \\
    -netdev user,id=n0 -device rtl8139,netdev=n0 \\
    -audiodev pa,id=snd -device AC97,audiodev=snd \\
    -usb -device usb-tablet -rtc base=localtime

Pitfalls baked into this script:
  * The disk MUST be IDE (PIIX3). SCSI/virtio does NOT boot Win2000 here — the
    MergeIDE registry fix (C) binds the boot device to the PIIX3 IDE driver.
  * SeaBIOS mis-reads the VMware CHS geometry -> boot fixes (A) MBR CHS and
    (B) NTFS VBR sectors-per-track realign it (else NTLDR fails / STOP 0x7B).
  * ACPI\QEMU0002 has no Win2000 driver. Never pre-create its Enum key in the
    pristine VMware hive: on this source that regresses to STOP 0x7B. Fix (D)
    boots A/B/C once, then marks the naturally enumerated instance failed-install.
  * Cirrus high colour is selected in Display Properties and cold-boot checked
    at exactly 1024x768 before golden is saved. The keep-mode dialog defaults
    to No; automation must send Left+Enter within its 15-second timer.
  * Software URLs are best-effort period mirrors and may rot; failures are
    non-fatal (OS image + boot fixes do not depend on them).
  * archive.org WinWorld VM URL is the one uncertain input — override --src-url.
============================================================================
EOF
