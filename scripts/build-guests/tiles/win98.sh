#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/win98.sh — from-scratch, reproducible build of the Windows 98 SE
# station for the neko+QEMU Kernel Hive.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the Win98 SE
# guest END TO END from its real upstream sources — no image backups, no
# pre-staged files. Produces the two final qcow2 disks in <GUEST_DIR>:
#     win98se.qcow2         (8 GiB virtual, boot=c  -> C:, IDE primary master)
#     win98se-games.qcow2   (768 MiB, FAT32, IDE primary slave -> D:, all SW)
# and framebuffer-verifies the guest boots to the Windows desktop.
#
# ---- HOW THIS GUEST WAS ACTUALLY BUILT (the recipe we transcribe) -----------
# The dry-run box did NOT perform a real Win98-from-CD install. Doing an
# authentic Win98 setup unattended (MSBATCH.INF answer file + QEMU sendkeys) is
# possible but slow and fragile under TCG. Instead the build used a KNOWN-GOOD,
# ready-to-run Win98 SE VMware image from WinWorld (hosted on archive.org),
# converted VMware VMDK -> qcow2. That image already has:
#     * Windows 98 Second Edition OEM, fully installed, boots to desktop
#     * Internet Explorer 5 preinstalled  (the period browser requirement)
# The source image does not contain the complete driver CAB set. This builder
# injects all 77 CAB files plus hidusb.sys from a separately hash-pinned Win98SE
# ISO so the production ACPI/std-VGA/PCnet/USB-tablet PnP cascade can self-service.
# The era software (Winamp, Doom95, Duke3D, Quake, GTA1) is delivered on a
# SECOND, hand-built FAT32 disk that enumerates inside the guest as D:. We build
# that disk from scratch here: partition table -> mkfs.vfat -> mcopy the files.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED. Re-fetches the real WinWorld VMware
#                        image + every piece of era software from upstream URLs.
#   (2) DISK CREATE .... FULLY AUTOMATED. System disk = qemu-img convert of the
#                        VMDK. Games disk = truncate+sfdisk MBR + mkfs.vfat FAT32
#                        + mcopy (root-free; no losetup/mount needed).
#   (3) INSTALL ........ N/A as a live setup — the OS is delivered pre-installed
#                        in the WinWorld image (see recipe note above). This is
#                        the deliberate, documented choice, not a shortcut around
#                        a working automated CD install.
#   (4) INPUT AUTOMATION MANUAL ONCE. The prebuilt image reaches a GUI, but the
#                        production ACPI PCI/USB device set has a long first-boot
#                        wizard cascade. The exact transcript is in win9x.md.
#   (5) ERA SOFTWARE ... FULLY AUTOMATED. Downloaded, staged into a directory
#                        tree, and written into the FAT32 games disk (D:).
#   (6) FINAL IMAGES ... win98se.qcow2 + win98se-games.qcow2 in <GUEST_DIR>.
#   (7) VERIFY ......... AUTOMATED — production KVM/acpi=on/std/usb-tablet boot
#                        + framebuffer screendump, asserted non-blank.
#
#   *** NOT-FULLY-AUTOMATED / MANUAL CAVEAT (honestly flagged): ***
#   - FIRST-BOOT PnP: this is not a one-click step. Cold-booting the ACPI-HAL
#     image with the production device set enumerates the Intel PCI/ISA/IDE/USB
#     bridges, Standard VGA, PCnet, monitor and USB HID tablet. Point each copy
#     prompt at C:\WINDOWS\OPTIONS\CABS, keep the newer pci.vxd, finish the known
#     driverless ACPI stubs, restart, select Windows Logon, and clean-shutdown.
#     Save `golden` only from the settled desktop. See the exact key transcript.
#   - GTA1: the file we stage on D: is Rockstar's MODERN free re-release
#     installer. It is STAGED (copied), not run. Its installer may refuse to run
#     on Win98 (use the WinXP guest as the GTA1 fallback). Everything else
#     (Doom95, Duke3D, Quake) is a working drop-in; Winamp is a clean one-click
#     installer that runs fine on 98.
#
# IDEMPOTENT / RE-RUNNABLE: large source downloads are cached under
# <GUEST_DIR>/.src-cache and reused; the two output qcow2s are skipped if
# already present and valid (override with --force). Uses a namespaced work dir
# and UNIQUE per-run unix sockets (VNC + QEMU monitor) + a pidfile for verify.
# Tears the VM down ONLY via monitor `quit` / pidfile — NEVER pkill-by-name — so
# it cannot disturb other gallery guests, CTID 110, VM 900/920, or the macOS
# fan-out VMIDs.
#
# Usage:
#   OUT_DIR=DIR WORK_DIR=DIR build-guests/tiles/win98.sh [--dir DIR] [--force] [--no-verify]
#                         [--skip-system] [--skip-games] [--vbemp-floppy [OUT]] [-h]
#     --dir DIR      output/guest dir   (default $OUT_DIR or /data/gallery-guests/Win98SE)
#     --force        re-download sources and rebuild both disks from scratch
#     --no-verify    skip the headless framebuffer boot check
#     --no-stage-pnp don't inject the pinned Win98 CD CAB set + hidusb.sys
#     --skip-system  don't (re)build win98se.qcow2       (games disk only)
#     --skip-games   don't (re)build win98se-games.qcow2 (system disk only)
#     --vbemp-floppy [OUT]  ONLY build the VBEMP-9x full-window-drag-fix driver
#                    floppy (default <DIR>/vbe9x.img) and exit; see STEP 5 +
#                    docs/guests/win9x.md for the in-guest install + golden re-bake
#     -h|--help      show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="${OUT_DIR:-/data/gallery-guests/Win98SE}"
SYS_QCOW="win98se.qcow2"         # C:  (system, from WinWorld VMware image)
KVM_QCOW="win98se-kvm.qcow2"     # persistent production copy; one-time PnP + golden live here
GAMES_QCOW="win98se-games.qcow2" # D:  (FAT32, all curated era software)
GAMES_DISK_MB=768                # virtual size of the games disk (matches build)
FORCE=0
VERIFY=1
DO_SYSTEM=1
DO_GAMES=1
STAGE_PNP=1
VBEMP_FLOPPY=0
VBEMP_OUT=""
VERIFY_WAIT="${VERIFY_WAIT:-90}"

# --- Upstream sources (all verified reachable 2026-07; see manifest.json) ----
# System: WinWorld "Windows 98 SE Virtual Machine (VMware)" — a .7z holding the
# VMware .vmdk(s). qemu-img converts the VMDK straight to qcow2.
WINWORLD_ITEM="Microsoft_Windows_98_Second_Edition_Virtual_Machine_VMware_WinWorld"
WINWORLD_FILE="Microsoft Windows 98 Second Edition [VMware VM].7z"
WINWORLD_BYTES="425349569"
WINWORLD_MD5="3d436db22042970b0fe56fbb138e9500"
WINWORLD_SHA256="08ba180d64e75972b019a9f3ef37c8cd153f40fa7b65fdcb228e0546865be47e"
# Licensed Win98SE installation media used only for inbox PnP files. The entire
# CAB chain is required: pci.vxd is in DRIVER*.CAB, while WIN98_21.CAB spans back
# into DRIVER20.CAB when extracting hidusb.sys.
WIN98_ISO_ITEM="windows-98-se-isofile"
WIN98_ISO_FILE="Windows 98 Second Edition.iso"
WIN98_ISO_BYTES="655591424"
WIN98_ISO_MD5="7c32b76e1b8374597cb5ef58a22aa635"
WIN98_ISO_SHA256="2adfb46df8a9c7bbd2f67bff07461cc2f9d9ec8e01f0e112cb044c9e3e62f607"
WIN98_ISO_PATH="${WIN98_ISO_PATH:-}"
# Era software (archive.org + freedoom GitHub release):
URL_WINAMP="https://archive.org/download/winamp295/winamp295.exe"
URL_GTA1="https://archive.org/download/rockstar-classics_202107/GTAINSTALLER.exe"
URL_DOOM95="https://archive.org/download/DOOM_95/doom95.zip"
URL_DOOMWAD="https://archive.org/download/DoomsharewareEpisode/doom.ZIP" # shareware DOOM1.WAD
URL_FREEDOOM="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
URL_DUKE="https://archive.org/download/3D_Realms_Duke_Nukem_3D_Shareware/3D%20Realms%20-%20Duke%20Nukem%203D%20%28Shareware%20Version%29.zip"
URL_QUAKE="https://archive.org/download/quakeshareware/QUAKE_SW.zip"

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
    --no-stage-pnp)
      STAGE_PNP=0
      shift
      ;;
    --skip-system)
      DO_SYSTEM=0
      shift
      ;;
    --skip-games)
      DO_GAMES=0
      shift
      ;;
    --vbemp-floppy)
      VBEMP_FLOPPY=1
      shift
      case "${1:-}" in "" | --*) ;; *)
        VBEMP_OUT="$1"
        shift
        ;;
      esac
      ;;
    -h | --help)
      sed -n '2,95p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

SYS_PATH="${GUEST_DIR}/${SYS_QCOW}"
KVM_PATH="${GUEST_DIR}/${KVM_QCOW}"
GAMES_PATH="${GUEST_DIR}/${GAMES_QCOW}"
CACHE="${GUEST_DIR}/.src-cache" # persistent download cache (idempotent re-runs)
WORK_IS_TEMP=0
if [ -n "${WORK_DIR:-}" ]; then
  WORK="$WORK_DIR"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/win98-build.XXXXXX")"
  WORK_IS_TEMP=1
fi
VNCSOCK="${WORK}/vnc.sock"
MONSOCK="${WORK}/mon.sock"
PIDFILE="${WORK}/qemu.pid"
NBD_DEV=""
NBD_MNT="${WORK}/nbd-mnt"
PROOF_PPM="${GUEST_DIR}/win98-desktop.ppm"
PROOF_PNG="${GUEST_DIR}/win98-desktop.png"

cleanup() {
  if mountpoint -q "$NBD_MNT" 2>/dev/null; then umount "$NBD_MNT" 2>/dev/null || true; fi
  if [ -n "$NBD_DEV" ]; then qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true; fi
  if [ "$WORK_IS_TEMP" = 1 ]; then rm -rf "$WORK" 2>/dev/null || true; fi
}
trap cleanup EXIT

log() { printf '\033[1;36m[win98]\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m[win98] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---- dependency check -------------------------------------------------------
# 7z name varies (7z / 7za / 7zr); resolve it. Everything else is standard on a
# Debian/Proxmox host (dosfstools=mkfs.vfat, mtools=mcopy, util-linux=sfdisk,
# qemu-utils=qemu-img, unzip, curl, python3). netpbm/pnmtopng is optional (PNG
# proof). We best-effort apt-install the two that are commonly missing.
SEVENZ=""
for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
  SEVENZ="$c"
  break
}; done
if [ -z "$SEVENZ" ] && command -v apt-get >/dev/null 2>&1; then
  log "installing p7zip-full (for the WinWorld .7z)…"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq p7zip-full >/dev/null 2>&1 || true
  for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
    SEVENZ="$c"
    break
  }; done
fi
if ! command -v mcopy >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  log "installing mtools + dosfstools (for the FAT32 games disk)…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mtools dosfstools >/dev/null 2>&1 || true
fi

miss=""
for t in curl unzip qemu-img sfdisk mkfs.vfat mcopy truncate python3 sha256sum; do
  command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
done
[ -n "$SEVENZ" ] || miss="$miss 7z"
[ "$STAGE_PNP" = 0 ] || for t in qemu-nbd mount umount mountpoint modprobe; do
  command -v "$t" >/dev/null 2>&1 || miss="$miss $t"
done
[ -z "$miss" ] || die "missing tools:$miss  (apt install p7zip-full mtools dosfstools qemu-utils unzip)"

# QEMU binary for the verify step (production launch-qemu.sh uses x86_64).
QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

mkdir -p "$GUEST_DIR" "$CACHE"

# ---- generic cached downloader ----------------------------------------------
# fetch <url> <dest-basename-in-cache> — resumable, retried, cached. Returns the
# cached path on stdout. --force wipes the cached copy first.
fetch() {
  local url="$1" name="$2" out="${CACHE}/$2"
  [ "$FORCE" = 1 ] && rm -f "$out"
  if [ -s "$out" ]; then
    log "cached: $name ($(du -h "$out" | cut -f1))"
  else
    log "downloading: $name"
    log "  <- $url"
    curl -fL --retry 3 --retry-delay 5 -C - -o "$out" "$url" ||
      curl -fL --retry 3 --retry-delay 5 -o "$out" "$url" ||
      die "download failed: $url"
  fi
  printf '%s' "$out"
}

# =============================================================================
# STEP 1 — SYSTEM DISK: WinWorld VMware image (VMDK) -> win98se.qcow2 (C:)
# =============================================================================
build_system() {
  if [ "$FORCE" = 0 ] && [ -s "$SYS_PATH" ] && qemu-img info "$SYS_PATH" >/dev/null 2>&1; then
    log "system disk already present -> $SYS_PATH ($(du -h "$SYS_PATH" | cut -f1)); skip (use --force)."
    return 0
  fi

  local sevenz_path
  sevenz_path="$(fetch "https://archive.org/download/${WINWORLD_ITEM}/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$WINWORLD_FILE")" "win98se-vmware.7z")"
  local got_bytes got_md5 got_sha256
  got_bytes="$(stat -c %s "$sevenz_path")"
  got_md5="$(md5sum "$sevenz_path" | awk '{print $1}')"
  got_sha256="$(sha256sum "$sevenz_path" | awk '{print $1}')"
  [ "$got_bytes" = "$WINWORLD_BYTES" ] ||
    die "WinWorld source size mismatch: expected $WINWORLD_BYTES, got $got_bytes"
  [ "$got_md5" = "$WINWORLD_MD5" ] ||
    die "WinWorld source MD5 mismatch: expected $WINWORLD_MD5, got $got_md5"
  [ "$got_sha256" = "$WINWORLD_SHA256" ] ||
    die "WinWorld source SHA256 mismatch: expected $WINWORLD_SHA256, got $got_sha256"
  log "source archive verified: ${got_bytes} bytes, MD5 ${got_md5}, SHA256 ${got_sha256}"
  "$SEVENZ" t "$sevenz_path" >/dev/null 2>&1 || die "cached WinWorld .7z fails integrity test (delete ${CACHE}/win98se-vmware.7z and retry)"

  local ex="${WORK}/vmware"
  mkdir -p "$ex"
  log "extracting VMware image from the .7z…"
  "$SEVENZ" x -y -o"$ex" "$sevenz_path" >/dev/null || die "7z extraction failed"

  # Pick the right .vmdk to hand to qemu-img:
  #  - If a .vmx is present, honour the disk it references.
  #  - A split image has a small TEXT DESCRIPTOR .vmdk plus -s001/-f001 EXTENTS;
  #    qemu-img must be pointed at the DESCRIPTOR, never an extent.
  #  - A monolithic image is a single .vmdk. Either way: prefer the .vmdk whose
  #    name is NOT an extent suffix; among those, the descriptor (small) or the
  #    lone monolithic file.
  local vmdk=""
  local vmx
  vmx="$(find "$ex" -type f -iname '*.vmx' | head -n1 || true)"
  if [ -n "$vmx" ]; then
    local ref
    ref="$(grep -ioE '[^"]+\.vmdk' "$vmx" 2>/dev/null | grep -viE -- '-(s|f)[0-9]+\.vmdk$' | head -n1 || true)"
    [ -n "$ref" ] && vmdk="$(find "$ex" -type f -iname "$(basename "$ref")" | head -n1 || true)"
  fi
  if [ -z "$vmdk" ]; then
    # No/unhelpful vmx: take vmdks that are not extents; prefer the smallest
    # (=text descriptor) if several remain, else the single monolithic file.
    vmdk="$(find "$ex" -type f -iname '*.vmdk' | grep -viE -- '-(s|f)[0-9]+\.vmdk$' |
      xargs -r ls -S 2>/dev/null | tail -n1 || true)"
  fi
  [ -z "$vmdk" ] && vmdk="$(find "$ex" -type f -iname '*.vmdk' | head -n1 || true)"
  [ -n "$vmdk" ] || die "no .vmdk found inside the WinWorld archive"
  log "converting VMDK -> qcow2:  $(basename "$vmdk")"
  qemu-img info "$vmdk" >/dev/null 2>&1 || die "selected .vmdk is not readable by qemu-img: $vmdk"

  qemu-img convert -p -O qcow2 "$vmdk" "${SYS_PATH}.tmp" || die "qemu-img convert failed"
  qemu-img info "${SYS_PATH}.tmp" >/dev/null 2>&1 || die "converted qcow2 is invalid"
  mv -f "${SYS_PATH}.tmp" "$SYS_PATH"
  log "system disk ready -> $SYS_PATH  (virtual $(qemu-img info "$SYS_PATH" | awk -F': ' '/virtual size/{print $2}'), $(du -h "$SYS_PATH" | cut -f1) on disk)"
}

# Pick an NBD device which is not held by another namespaced build.
pick_free_nbd() {
  modprobe nbd max_part=8 2>/dev/null || true
  local n
  for n in $(seq 0 31); do
    [ -e "/dev/nbd${n}" ] || continue
    [ -s "/sys/block/nbd${n}/pid" ] || {
      printf '/dev/nbd%s\n' "$n"
      return 0
    }
  done
  return 1
}

# Offline-inject the complete, hash-pinned Win98SE CD CAB chain and HID USB
# minidriver. This is what lets the one-time acpi=on PCI/USB cascade self-service.
stage_pnp_drivers() {
  [ "$STAGE_PNP" = 1 ] || {
    log "PnP CAB staging skipped (--no-stage-pnp)."
    return 0
  }
  [ -s "$SYS_PATH" ] || die "cannot stage PnP drivers: missing $SYS_PATH"

  local iso="$WIN98_ISO_PATH" iso_url got_bytes got_md5 got_sha256
  if [ -z "$iso" ]; then
    iso_url="https://archive.org/download/${WIN98_ISO_ITEM}/$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$WIN98_ISO_FILE")"
    iso="$(fetch "$iso_url" win98se.iso)"
  fi
  [ -s "$iso" ] || die "Win98SE ISO does not exist: $iso"
  got_bytes="$(stat -c %s "$iso")"
  got_md5="$(md5sum "$iso" | awk '{print $1}')"
  got_sha256="$(sha256sum "$iso" | awk '{print $1}')"
  [ "$got_bytes" = "$WIN98_ISO_BYTES" ] ||
    die "Win98SE ISO size mismatch: expected $WIN98_ISO_BYTES, got $got_bytes"
  [ "$got_md5" = "$WIN98_ISO_MD5" ] ||
    die "Win98SE ISO MD5 mismatch: expected $WIN98_ISO_MD5, got $got_md5"
  [ "$got_sha256" = "$WIN98_ISO_SHA256" ] ||
    die "Win98SE ISO SHA256 mismatch: expected $WIN98_ISO_SHA256, got $got_sha256"
  log "licensed Win98SE ISO verified: ${got_bytes} bytes, MD5 ${got_md5}, SHA256 ${got_sha256}"

  local ex="${WORK}/win98-cd" cabroot cab21 driver_stage winroot cabdest
  rm -rf "$ex"
  mkdir -p "$ex"
  "$SEVENZ" x -y -ssc- -o"$ex" "$iso" 'win98/*.CAB' >/dev/null ||
    die "failed to extract Win98 CAB chain from ISO"
  cabroot="$(find "$ex" -type f -iname 'WIN98_21.CAB' -printf '%h\n' | head -n1)"
  [ -n "$cabroot" ] || die "WIN98_21.CAB not found in licensed ISO"
  [ "$(find "$cabroot" -maxdepth 1 -type f -iname '*.CAB' | wc -l)" -eq 77 ] ||
    die "licensed ISO CAB chain incomplete (expected 77 CAB files)"
  cab21="$(find "$cabroot" -maxdepth 1 -type f -iname 'WIN98_21.CAB' | head -n1)"
  driver_stage="${WORK}/hidusb"
  rm -rf "$driver_stage"
  mkdir -p "$driver_stage"
  "$SEVENZ" e -y -o"$driver_stage" "$cab21" hidusb.sys >/dev/null ||
    die "failed to extract hidusb.sys (complete CAB chain must be adjacent)"
  [ -s "$driver_stage/hidusb.sys" ] || die "hidusb.sys missing after CAB extraction"

  NBD_DEV="$(pick_free_nbd)" || die "no free /dev/nbd device for PnP staging"
  mkdir -p "$NBD_MNT"
  qemu-nbd --connect="$NBD_DEV" "$SYS_PATH"
  for _ in $(seq 1 20); do
    [ -b "${NBD_DEV}p1" ] && break
    sleep .5
  done
  mount -t vfat "${NBD_DEV}p1" "$NBD_MNT" || die "cannot mount ${NBD_DEV}p1"
  winroot="$(find "$NBD_MNT" -maxdepth 1 -type d -iname windows | head -n1)"
  [ -n "$winroot" ] || die "Windows directory not found on system disk"
  cabdest="${winroot}/OPTIONS/CABS"
  mkdir -p "$cabdest" "${winroot}/SYSTEM32/DRIVERS"
  find "$cabdest" -maxdepth 1 -type f -iname '*.CAB' -delete
  find "$cabroot" -maxdepth 1 -type f -iname '*.CAB' -exec cp -f {} "$cabdest"/ \;
  cp -f "$driver_stage/hidusb.sys" "${winroot}/SYSTEM32/DRIVERS/hidusb.sys"
  sync
  log "staged 77 CD CABs at C:\\WINDOWS\\OPTIONS\\CABS and hidusb.sys in SYSTEM32\\DRIVERS"
  umount "$NBD_MNT"
  qemu-nbd -d "$NBD_DEV" >/dev/null
  NBD_DEV=""
}

# =============================================================================
# STEP 2 — GAMES DISK: build a FAT32 (MBR) disk of curated era software -> D:
#
# Root-free construction (no losetup/mount needed):
#   truncate a raw disk -> write a 1-partition MBR with sfdisk (type 0x0C =
#   FAT32 LBA) -> mkfs.vfat a standalone partition image sized to that slot ->
#   mcopy the staged file tree into it -> dd the partition back into the disk at
#   its LBA offset -> qemu-img convert -c to qcow2.
#
# Layout written into D: (exactly what manifest.json documents):
#   D:\INSTALL\WINAMP\WINAMP295.EXE     one-click Winamp 2.95 installer (staged)
#   D:\INSTALL\GTA1\GTASETUP.EXE        Rockstar GTA1 free installer   (staged)
#   D:\GAMES\DOOM95\  DOOM95.EXE + DOOM1.WAD + FREEDM1.WAD + FREEDM2.WAD
#   D:\GAMES\DUKE3D\  DUKE3D.EXE (+GRP)     3D Realms shareware, DOS drop-in
#   D:\GAMES\QUAKE\   QUAKE.EXE + ID1\PAK0.PAK + Q95.BAT   shareware, DOS
# =============================================================================

# flatten_copy <extract_dir> <dest_dir> — copy the CONTENTS of an unzip dir into
# dest, collapsing a single wrapper subfolder if the zip had one.
flatten_copy() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  local entries
  entries="$(find "$src" -mindepth 1 -maxdepth 1)"
  local count
  count="$(printf '%s\n' "$entries" | grep -c . || true)"
  if [ "$count" = 1 ] && [ -d "$entries" ]; then
    cp -a "$entries"/. "$dst"/
  else
    cp -a "$src"/. "$dst"/
  fi
}

# find_one <dir> <iname-glob> — echo first matching file path (or empty).
find_one() { find "$1" -type f -iname "$2" 2>/dev/null | head -n1; }

stage_software() {
  local S="$1" # staging root that becomes the FAT32 root (=D:\)
  mkdir -p "$S/INSTALL/WINAMP" "$S/INSTALL/GTA1" "$S/GAMES/DOOM95" "$S/GAMES/DUKE3D" "$S/GAMES/QUAKE"

  # --- Winamp 2.95 (staged one-click installer) ---
  cp -f "$(fetch "$URL_WINAMP" winamp295.exe)" "$S/INSTALL/WINAMP/WINAMP295.EXE"

  # --- GTA1 (staged; modern re-release installer, may refuse on 98) ---
  cp -f "$(fetch "$URL_GTA1" GTAINSTALLER.exe)" "$S/INSTALL/GTA1/GTASETUP.EXE"

  # --- Doom95 engine + shareware WAD + Freedoom IWADs ---
  local d95 wadsw fdoom ex
  d95="$(fetch "$URL_DOOM95" doom95.zip)"
  wadsw="$(fetch "$URL_DOOMWAD" doom-shareware.zip)"
  fdoom="$(fetch "$URL_FREEDOOM" freedoom-0.13.0.zip)"
  ex="${WORK}/doom95"
  rm -rf "$ex"
  mkdir -p "$ex"
  unzip -o -q "$d95" -d "$ex" || die "unzip doom95 failed"
  cp -f "$(find_one "$ex" 'DOOM95.EXE')" "$S/GAMES/DOOM95/DOOM95.EXE" 2>/dev/null ||
    die "DOOM95.EXE not found in doom95.zip"
  # DOOM1.WAD: prefer one bundled with doom95.zip, else pull from the shareware WAD zip.
  local wad
  wad="$(find_one "$ex" 'DOOM1.WAD')"
  if [ -z "$wad" ]; then
    ex="${WORK}/doomwad"
    rm -rf "$ex"
    mkdir -p "$ex"
    unzip -o -q "$wadsw" -d "$ex" || die "unzip shareware WAD failed"
    wad="$(find_one "$ex" 'DOOM1.WAD')"
    [ -z "$wad" ] && wad="$(find_one "$ex" '*.WAD')"
  fi
  [ -n "$wad" ] && cp -f "$wad" "$S/GAMES/DOOM95/DOOM1.WAD" || log "warn: no shareware DOOM1.WAD (Freedoom still playable)"
  ex="${WORK}/freedoom"
  rm -rf "$ex"
  mkdir -p "$ex"
  unzip -o -q "$fdoom" -d "$ex" || die "unzip freedoom failed"
  cp -f "$(find_one "$ex" 'freedoom1.wad')" "$S/GAMES/DOOM95/FREEDM1.WAD" 2>/dev/null || log "warn: freedoom1.wad missing"
  cp -f "$(find_one "$ex" 'freedoom2.wad')" "$S/GAMES/DOOM95/FREEDM2.WAD" 2>/dev/null || log "warn: freedoom2.wad missing"

  # --- Duke Nukem 3D shareware (DOS drop-in) ---
  ex="${WORK}/duke"
  rm -rf "$ex"
  mkdir -p "$ex"
  unzip -o -q "$(fetch "$URL_DUKE" duke3d-sw.zip)" -d "$ex" || die "unzip duke3d failed"
  flatten_copy "$ex" "$S/GAMES/DUKE3D"
  [ -n "$(find_one "$S/GAMES/DUKE3D" 'DUKE3D.EXE')" ] || log "warn: DUKE3D.EXE not seen after extract"

  # --- Quake shareware (WinQuake/DOS; software renderer only, no GLQuake) ---
  ex="${WORK}/quake"
  rm -rf "$ex"
  mkdir -p "$ex"
  unzip -o -q "$(fetch "$URL_QUAKE" quake-sw.zip)" -d "$ex" || die "unzip quake failed"
  flatten_copy "$ex" "$S/GAMES/QUAKE"
  # Q95.BAT: convenience launcher for the DOS build inside a Win9x DOS box.
  if [ -z "$(find_one "$S/GAMES/QUAKE" 'Q95.BAT')" ] && [ -n "$(find_one "$S/GAMES/QUAKE" 'QUAKE.EXE')" ]; then
    printf '@echo off\r\ncd %%~dp0\r\nquake.exe %%*\r\n' >"$S/GAMES/QUAKE/Q95.BAT"
  fi

  log "staged software tree:"
  (cd "$S" && find . -type f | sed 's/^/    /') >&2
}

build_games() {
  if [ "$FORCE" = 0 ] && [ -s "$GAMES_PATH" ] && qemu-img info "$GAMES_PATH" >/dev/null 2>&1; then
    log "games disk already present -> $GAMES_PATH ($(du -h "$GAMES_PATH" | cut -f1)); skip (use --force)."
    return 0
  fi

  local S="${WORK}/dstage"
  mkdir -p "$S"
  stage_software "$S"

  # --- geometry: 1 primary FAT32-LBA partition starting at LBA 2048 ---
  local disk_sect part_start part_sect
  disk_sect=$((GAMES_DISK_MB * 1024 * 1024 / 512))
  part_start=2048
  part_sect=$((disk_sect - part_start))

  local raw="${WORK}/games.raw" part="${WORK}/games.part"
  log "creating ${GAMES_DISK_MB} MiB raw disk + MBR partition table…"
  truncate -s "$((disk_sect * 512))" "$raw"
  # sfdisk works directly on a regular file — no loop device / root mount needed.
  printf 'label: dos\nstart=%s, size=%s, type=0c, bootable\n' "$part_start" "$part_sect" |
    sfdisk "$raw" >/dev/null || die "sfdisk failed to write MBR"

  log "formatting FAT32 partition + copying files (mcopy)…"
  truncate -s "$((part_sect * 512))" "$part"
  mkfs.vfat -F 32 -n GALLERY "$part" >/dev/null || die "mkfs.vfat failed"
  # Copy the whole staged tree into the FAT32 root. -s = recursive.
  mcopy -s -i "$part" "$S"/* :: || die "mcopy into FAT32 image failed"

  log "splicing partition into disk + converting to qcow2…"
  dd if="$part" of="$raw" bs=512 seek="$part_start" conv=notrunc status=none || die "dd splice failed"
  qemu-img convert -c -O qcow2 "$raw" "${GAMES_PATH}.tmp" || die "qemu-img convert (games) failed"
  qemu-img info "${GAMES_PATH}.tmp" >/dev/null 2>&1 || die "games qcow2 is invalid"
  mv -f "${GAMES_PATH}.tmp" "$GAMES_PATH"
  log "games disk ready -> $GAMES_PATH  (virtual ${GAMES_DISK_MB}M, $(du -h "$GAMES_PATH" | cut -f1) on disk)"
}

# =============================================================================
# STEP 3 — prepare the persistent production copy and write manifest.json.
# =============================================================================
prepare_live_copy() {
  if [ "$FORCE" = 0 ] && [ -s "$KVM_PATH" ] && qemu-img info "$KVM_PATH" >/dev/null 2>&1; then
    log "production copy already present -> $KVM_PATH; preserve its PnP/golden state (use --force to replace)."
    return 0
  fi
  [ -s "$SYS_PATH" ] || die "cannot prepare production copy: missing $SYS_PATH"
  cp --reflink=auto -f "$SYS_PATH" "${KVM_PATH}.tmp"
  mv -f "${KVM_PATH}.tmp" "$KVM_PATH"
  log "production copy ready -> $KVM_PATH (run the documented one-time PnP settle, then golden-bake.sh)."
}

write_manifest() {
  cat >"${GUEST_DIR}/manifest.json" <<JSON
{
  "os": "Windows 98 SE",
  "priority": 1,
  "built_by": "scripts/build-guests/tiles/win98.sh",
  "status": "built-needs-one-time-pnp-settle",
  "disks": {
    "system": {
      "host_path": "${SYS_PATH}",
      "format": "qcow2",
      "role": "boot=c, IDE primary master, C:",
      "source": "archive.org/${WINWORLD_ITEM} (WinWorld VMware VMDK) -> qemu-img convert -O qcow2",
      "notes": "Ready-to-run WinWorld image. IE5 preinstalled. Complete 77-file Win98SE CD CAB chain plus hidusb.sys injected from hash-pinned licensed ISO."
    },
    "production_system": {
      "host_path": "${KVM_PATH}",
      "format": "qcow2",
      "role": "persistent PnP-settled C: and internal golden snapshot container"
    },
    "games": {
      "host_path": "${GAMES_PATH}",
      "format": "qcow2",
      "virtual_size": "${GAMES_DISK_MB}M",
      "role": "IDE primary slave, D: (FAT32) holding all curated software",
      "built_by": "truncate + sfdisk MBR + mkfs.vfat FAT32 + mcopy, converted to qcow2"
    }
  },
  "qemu_args": "-enable-kvm -machine pc,acpi=on -cpu pentium3 -m 384 -smp 1 -drive file=${SYS_QCOW},if=ide,index=0,media=disk,format=qcow2 -drive file=${GAMES_QCOW},if=ide,index=1,media=disk,format=qcow2 -vga std -audiodev none,id=snd -device sb16,audiodev=snd -netdev user,id=n0 -device pcnet,netdev=n0 -usb -device usb-tablet -boot c -rtc base=localtime",
  "accel": "KVM; this ACPI-HAL image requires acpi=on"
}
JSON
  log "wrote manifest -> ${GUEST_DIR}/manifest.json"
}

# =============================================================================
# STEP 4 — FRAMEBUFFER VERIFY: exact production KVM device set -> screendump.
#   Boots BOTH disks exactly as the station does, but with -snapshot so the golden
#   images are NEVER mutated by the test, and WITHOUT a sound device (a bare
#   SB16 with no host audio backend can abort QEMU on the verify host; audio is
#   proven separately and encoded in the neko-qemu args below). Unique unix
#   sockets + pidfile; teardown via monitor `quit` then pidfile — NEVER pkill.
# =============================================================================
mon_send() {
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

verify_boot() {
  [ -n "$QEMU_BIN" ] || {
    log "no qemu-system binary present — SKIPPING verify (build succeeded)."
    return 0
  }
  [ -s "$SYS_PATH" ] || {
    log "no system disk to verify — SKIPPING."
    return 0
  }

  log "verify: production KVM/acpi=on/std/usb-tablet boot of Win98 (${VERIFY_WAIT}s)…"
  # CORRECTION (2026-07-12): the "acpi=off = Win98's default HAL" assumption was WRONG
  # for THIS WinWorld image — it is an ACPI-HAL install (Device Manager > System
  # devices lists "ACPI BIOS"), so acpi=off is a HAL mismatch that left Win98 on the
  # fail-safe PnP BIOS and STOPPED IT ENUMERATING THE PCI BUS (dead NIC, no display
  # adapter, no USB). The live win98se TILE now runs acpi=ON + a usb-tablet for an
  # ABSOLUTE pointer (SH_POINTER=abs) — baked + verified 2026-07-12. Winning accel =
  # KVM + acpi=on (apic ON, default irqchip): no "Windows protection error" and no
  # logon-freeze across 3 cold boots (acpi=on also cures the old KVM timer/freeze — no
  # FIX95CPU needed). The verifier uses that exact production device set.
  #
  # USB-POINTER BAKE RECIPE (one-time, per docs/guests/win9x.md win98se section):
  #   1. This WinWorld image is MISSING the base install cabs (win98_*.cab) AND
  #      hidusb.sys (the USB-HID minidriver required by WINDOWS\INF\HIDDEV.INF). Fetch a
  #      hash-pinned Win98SE CD ISO. stage_pnp_drivers above injects all 77 CABs
  #      (including DRIVER*.CAB, required for pci.vxd) and hidusb.sys offline.
  #   2. Cold-boot acpi=on: Win98 enumerates PCI (82441FX/82371SB bridges, IRQ steering,
  #      std VGA -> clears the display nag, Intel 82371SB USB Universal Host Controller,
  #      PCnet NIC) and the usb-tablet installs as a USB HID device (uhcd/usbd/usbhub +
  #      hidclass/hidparse/hidusb). Point any "insert disk" copy prompt at
  #      C:\WINDOWS\OPTIONS\CABS (Win98 then remembers it). Cancel/Finish-mark the few
  #      driverless ACPI stub devices (ACPI Generic Bus/EIO Bus, PnP Monitor, IDE bus
  #      master) to reach an idle desktop. Verify 1:1 abs tracking + winipcfg 10.0.2.15.
  #   3. savevm golden ; tile.env SH_POINTER=abs. The station boots via -loadvm golden, so
  #      the RAM snapshot restores the settled desktop with the pointer live (no re-scan).
  #   Do NOT re-add acpi=off / usb=off / -apic / kernel-irqchip=off.
  local drives=(-drive "file=${SYS_PATH},if=ide,index=0,media=disk,format=qcow2")
  [ -s "$GAMES_PATH" ] && drives+=(-drive "file=${GAMES_PATH},if=ide,index=1,media=disk,format=qcow2")

  "$QEMU_BIN" \
    -enable-kvm -machine pc,acpi=on -cpu pentium3 -m 384 -smp 1 \
    "${drives[@]}" \
    -vga std \
    -audiodev none,id=snd -device sb16,audiodev=snd \
    -netdev user,id=n0 -device pcnet,netdev=n0 \
    -usb -device usb-tablet \
    -boot c -rtc base=localtime \
    -snapshot \
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
  sleep "$VERIFY_WAIT"

  log "verify: capturing framebuffer via monitor screendump…"
  mon_send "screendump ${PROOF_PPM}"
  sleep 2

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
  kill -0 "$qpid" 2>/dev/null && kill -TERM "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true

  [ -s "$PROOF_PPM" ] || die "verify FAILED — no framebuffer captured (did not reach GUI?)"

  python3 - "$PROOF_PPM" <<'PY' || die "verify FAILED — framebuffer looks blank (near-black / no colour variety)"
import sys
p=sys.argv[1]
with open(p,'rb') as f: data=f.read()
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(data); magic=hdr[0]; w=int(hdr[1]); h=int(hdr[2]); px=data[off:]
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]; seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
print(f"[win98] verify: {magic.decode(errors='replace')} {w}x{h}, ~{len(seen)} colours sampled, mean brightness {mean:.1f}")
sys.exit(0 if (len(seen) >= 8 and mean > 8) else 1)
PY

  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  else
    log "verify: proof -> $PROOF_PPM (no PPM->PNG converter; PPM kept)"
  fi
  log "verify: PASS — Win98 SE produced a non-blank production-profile GUI framebuffer (PnP may still be modal)."
}

# =============================================================================
# STEP 5 (post-install golden step) — FULL-WINDOW-DRAG FIX: VBEMP-9x packed
# linear framebuffer.  Run `win98.sh --vbemp-floppy` to build just the driver
# floppy; the in-guest install is a driven GUI step (see docs/guests/win9x.md
# "Full-window drag fix" for the exact wizard path + the live cutover recipe).
#
# WHY: the golden shipped the inbox "Standard PCI Graphics Adapter (VGA)" driver,
# which on `-vga std` runs 640x480 x 16-COLOUR PLANAR (VGA mode 12h). Every pixel
# is a 4-plane read-modify-write => CPU-bound guest repaint => "Show window
# contents while dragging" (DragFullWindows=1) crawled at <1 FPS. WinXP is smooth
# because it runs the VBEMP VESA linear framebuffer (see winxp-vbemp-hires.sh).
#
# FIX (guest-internal; device set stays `-vga std`, so it needs a GOLDEN RE-BAKE):
# install the bearwindows "VBEMP 9x/ME" universal VBE driver. Its DEFAULT mode is
# 640x480 x 16-bit HIGH COLOR **packed** (a repaint becomes a memcpy). NOTE this is
# a DIFFERENT package from the NT-only vbempk.zip used for XP (that zip has no 9x
# build). The Win9x driver is bearwindows `vbe9x.htm` -> latest `191201.zip`,
# `032MB` build (VBEMP.DRV + VBE.vxd + vbemp.inf); 032MB fits QEMU std-vga's 16 MB
# VRAM. Resolution stays 640x480 so the streamhost/UI capture geometry is
# unchanged (dbus always presents a 32bpp packed scanout regardless of guest depth).
# Verified 2026-07-13: smooth drag (8 clean full-window frames in ~0.2 s) vs the
# <1 FPS planar crawl; baked into the live win98se golden (acpi=on + usb-tablet
# launcher preserved).
#
# *** REGRESSION + RE-BAKE HISTORY — READ BEFORE ANY GOLDEN REBUILD ***
# 2026-07-15: a full builder rebuild re-baked the golden straight from the planar
#   base (this STEP 5 is deliberately NOT in the default `run` flow below), so the
#   shipped golden silently reverted to 640x480 16-COLOUR PLANAR and the drag crawl
#   came back. 2026-07-26: RE-BAKED to VBEMP-9x 640x480x16-bit + DragFullWindows=1
#   (Notepad golden fixture, acpi=on + usb-tablet + `-vga std` device set unchanged),
#   re-verified on a clone AND on the live golden (full window tracks the cursor).
# LESSON: STEP 5 is a REQUIRED part of the shipped golden, not an optional extra.
#   Any rebuild that regenerates win98se-kvm.qcow2 MUST re-apply STEP 5 (install the
#   VBEMP-9x driver + enable DragFullWindows) — or copy a VBEMP-baked C: — BEFORE
#   `savevm golden`, else the planar crawl returns. Full recipe: docs/guests/win9x.md.
VBE9X_URL="${VBE9X_URL:-http://bearwindows.zcm.com.au/191201.zip}" # Win9x VBEMP, latest build
build_vbemp9x_floppy() {
  local out="${1:-${GUEST_DIR}/vbe9x.img}" work
  work="$(mktemp -d)"
  log "VBEMP-9x: fetching $(basename "$VBE9X_URL") + building FAT12 driver floppy"
  curl -fL --retry 3 -o "${work}/vbe9x.zip" "$VBE9X_URL" || die "VBEMP-9x download failed"
  (cd "$work" && unzip -oq vbe9x.zip)
  local src="${work}/032MB" # 032MB build fits std-vga 16 MB VRAM
  [ -f "${src}/VBEMP.DRV" ] && [ -f "${src}/VBE.vxd" ] && [ -f "${src}/vbemp.inf" ] ||
    die "VBEMP.DRV/VBE.vxd/vbemp.inf not found in 032MB/ (zip layout changed?)"
  dd if=/dev/zero of="$out" bs=1024 count=1440 status=none
  mkfs.vfat -F 12 "$out" >/dev/null
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "$out" "${src}/VBEMP.DRV" "${src}/VBE.vxd" "${src}/vbemp.inf" ::
  rm -rf "$work"
  log "VBEMP-9x driver floppy ready -> $out"
  log "  attach as '-fda $out', cold-boot, then Display Properties -> Settings ->"
  log "  Advanced -> Adapter -> Change -> Have Disk -> A:\\ -> 'VBE Miniport' -> restart;"
  log "  Effects -> check 'Show window contents while dragging'. See docs/guests/win9x.md."
}
if [ "$VBEMP_FLOPPY" = 1 ]; then
  build_vbemp9x_floppy "$VBEMP_OUT"
  exit 0
fi

# ---- run --------------------------------------------------------------------
[ "$DO_SYSTEM" = 1 ] && {
  build_system
  stage_pnp_drivers
} || log "system disk step skipped."
[ "$DO_GAMES" = 1 ] && build_games || log "games disk step skipped."
prepare_live_copy
write_manifest
[ "$VERIFY" = 1 ] && verify_boot || log "verify skipped (--no-verify)."

# =============================================================================
# DONE — how this station is wired into the neko+QEMU gallery.
# The container mounts /data/gallery-guests read-only at /guests; launch-qemu.sh
# uses qemu-system-x86_64 with -audiodev pa,id=snd (hence audiodev=snd below).
# =============================================================================
cat <<EOF

============================================================================
Windows 98 SE build complete.
  System disk (C:) : ${SYS_PATH}
  Production C:    : ${KVM_PATH} (persistent one-time PnP + golden snapshot container)
  Games disk  (D:) : ${GAMES_PATH}
  Proof screenshot : ${PROOF_PNG} (or .ppm)

Production tile profile:
  OS_NAME       = Windows 98 SE
  QEMU_MACHINE  = pc,acpi=on         (this source is an ACPI-HAL install)
  QEMU_MEM      = 384                (keep <=512)
  QEMU_VGA      = std
  QEMU_SOUND    = -device sb16,audiodev=snd
  GUEST_DISK    = tile-local win98se-golden.qcow2
  GUEST_FMT     = qcow2
  GUEST_BOOT    = c
  QEMU_EXTRA    = -enable-kvm -cpu pentium3 -smp 1 -usb -device usb-tablet
                  -drive file=tile-local/win98se-games-golden.qcow2,format=qcow2,if=ide,index=1
                  -netdev user,id=n0 -device pcnet,netdev=n0

Equivalent raw QEMU command (after the documented one-time PnP settle):
  qemu-system-x86_64 -enable-kvm -machine pc,acpi=on -cpu pentium3 -m 384 -smp 1 \\
    -drive file=win98se-golden.qcow2,if=ide,index=0,media=disk,format=qcow2 \\
    -drive file=win98se-games-golden.qcow2,if=ide,index=1,media=disk,format=qcow2 \\
    -vga std -audiodev pa,id=snd -device sb16,audiodev=snd \\
    -netdev user,id=n0 -device pcnet,netdev=n0 -usb -device usb-tablet \\
    -boot c -rtc base=localtime -loadvm golden

Pitfalls baked into this script / to remember:
  * acpi=on is required; acpi=off hides the PCI bus from this ACPI-HAL image.
  * The complete 77-CAB chain is required; WIN98_*.CAB alone misses pci.vxd.
  * The USB tablet is the pointer implementation. No warpnet agent is expected.
  * Games/data disk enumerates as D:; the CD-ROM (if any) shifts to E:.
  * The PnP cascade is manual once; reproduce the exact transcript in win9x.md.
  * The shipped golden REQUIRES the VBEMP-9x drag fix (STEP 5): 640x480x16-bit
    packed linear framebuffer + DragFullWindows=1. This build flow makes only the
    PLANAR base; skipping STEP 5 ships a 16-colour planar golden whose full-window
    drag crawls at <1 FPS. Re-apply STEP 5 before savevm golden on every rebuild.
  * GTA1 is STAGED only; its modern installer may refuse 98 (use the WinXP tile).
  * A bare '-device sb16' with no host audio backend can abort qemu — always
    pass an explicit -audiodev (pa in production; none in verify).
============================================================================
EOF
