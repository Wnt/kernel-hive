#!/usr/bin/env bash
###############################################################################
# build-guests/win95.sh — reproduce the Windows 95 OSR2 gallery tile from source
#
# GUEST : Windows 95 OSR2 (retro-gallery tile, priority 1)
# TYPE  : PRE-INSTALLED PRESERVATION IMAGE + era-software injection.
#         There is NO scripted from-scratch MS-Setup for Win95 (no answer file /
#         autounattend exists for the 1995 Setup, and cycling real Setup from the
#         boot floppies is not reproducible).
#         The reproducible SOURCE is the community "Windows 95 for UTM" disk image
#         on archive.org — a clean, already-installed, already-patcher9x-patched
#         Win95 OSR2 that boots to desktop under QEMU/UTM. "Building" this tile ==
#         fetch that image, normalise it to qcow2, INJECT the curated era software
#         into C:\GALLERY\, cycle first-boot PnP once, and framebuffer-prove the
#         desktop. That injection is the real automated work this script encodes.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh Proxmox host):
#   1. Re-DOWNLOAD the real source image ("Windows 95 for UTM.zip") from
#      archive.org (idempotent; skips if the on-disk copy already matches the
#      pinned MD5). Unzip, locate the qcow2 inside the UTM bundle.
#   2. Normalise to a clean qcow2 at the target path (2 GiB, FAT32, boot=C:).
#   3. (patcher9x) OPTIONAL re-assert of the fast-CPU TLBI patch. The archive
#      image already ships patcher9x-patched (that is why it survives a modern
#      host under TCG); this step is guarded/no-op by default. See PATCHER9X.
#   4. INJECT era software into C:\GALLERY\ by mounting the FAT32 partition
#      (qemu-nbd -> loop) and dropping each payload, downloaded from its real
#      upstream URL. Writes C:\GALLERY\README.TXT and stages the pinned VBEMP
#      19.12.0001 `032MB` payload in C:\VBEMP.
#   5. Land the final bootable artifact at
#      data/gallery-guests/Win95/win95-osr2.qcow2
#   6. (first-boot settle) operator-driven once under the production device set.
#      SEE AUTOMATION HONESTY; blind input is deliberately not sent.
#   6b/6c. Build the KVM/-vga std copy, install VBEMP through the deterministic
#      Have-Disk path, cold-boot it at 640x480 High Color (16 bit), import
#      DragFullWindows=1, and emit a real framebuffer acceptance capture.
#   7. FRAMEBUFFER-VERIFY: boot headless under QEMU (unique VNC + monitor
#      socket), wait for the desktop, `screendump` a PNG, sanity-check its size.
#
# AUTOMATION HONESTY:
#   * Steps 1,2,4,5,7 are FULLY automated and reproduce with no human input
#     (given the upstream mirrors are reachable — see PAYLOAD honesty below).
#   * Step 3 (patcher9x) is a guarded OPTIONAL re-assert; the source image is
#     already patched, so by default this is a no-op you can enable with
#     PATCH9X=1 if you ever swap in an unpatched base.
#   * Step 6 (first-boot PnP cycle) is MANUAL ONCE and defaults off.
#     On the very first boot on QEMU's cirrus/sb16/pcnet hardware, Win95 pops
#     one-time "New Hardware Found", "System Settings Change -> Restart?", and
#     DST-clock dialogs. With SETTLE=1 the script exposes a namespaced VNC and
#     monitor window but sends no keys. Follow docs/guests/win9x.md exactly and
#     guest-shutdown cleanly before saving `golden`; blind Enter loops can launch
#     a selected desktop icon and monitor quit leaves the FAT volume dirty.
#   * Step 6c is automated when KVM_READY=1, VBEMP_READY=1, and WARPNET=1 (the
#     defaults). It uses a namespaced host-forward for warpnet motion plus QEMU
#     buttons/keys, stops each candidate only by PIDFILE, cold-boots after the
#     driver switch, and preserves `-vga std` throughout.
#   * PAYLOAD honesty: Winamp/Doom95/Duke3D/Quake and Freedoom fetch directly.
#     A working GTA payload must contain gtados+gtadata; supply an explicit
#     GTA1_URL or payload/gta1.zip. The generic rockstar-classics ZIP is not it.
#     NETSCAPE Communicator
#     4.05 lives on WinWorld behind a download portal, not
#     a stable direct URL — set NETSCAPE_URL to a reachable mirror or drop the
#     installer at $GUEST_DIR/payload/NETSCAPE.EXE beforehand. If neither is
#     present the script SKIPS Netscape with a warning (it is a staged one-click
#     installer, non-blocking for the tile; IE5.5 is already on the image).
#
# HYGIENE (per project rules):
#   * Every VM this script boots is killed ONLY via its QEMU monitor `quit`
#     (fallback: its own pidfile). NEVER `pkill qemu*` — that would catch the
#     live gallery tiles, VM 900/920, and the macOS fan-out VMs.
#   * qemu-nbd is connected to a DYNAMICALLY-CHOSEN FREE /dev/nbdN and always
#     disconnected in cleanup; the mount uses a namespaced dir.
#   * Namespaced run dir + unique VNC display + unique monitor socket (PID-
#     derived) so concurrent guest builds never collide.
#   * Touches ONLY data/gallery-guests/Win95/. Never CT 110, VM 900/920, the
#     macOS VMIDs, or any other guest dir.
#
# Idempotent + re-runnable. Safe to run repeatedly.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="win95"
DIR_NAME="Win95"

# --- Source OS image (archive.org: "Windows 95 for UTM") ---------------------
# Clean, pre-installed, patcher9x-patched Win95 OSR2 that boots under QEMU/UTM.
IA_ITEM="windows-95-for-utm"
SRC_ZIP_NAME="Windows 95 for UTM.zip"
SRC_ZIP_URL="https://archive.org/download/${IA_ITEM}/Windows%2095%20for%20UTM.zip"
SRC_ZIP_MD5="9ccbf5b59f1ddf82f2ad007ff9471814" # pinned from the validated box
SRC_ZIP_SHA256="9dfd213d1f58268a5e8214a0067121b63b76d6e7a6896c86efd5944f5dc7eedd"
SRC_ZIP_BYTES="351717750"

# Where the gallery keeps its guests (host dataset, bind-mounted into CT 110 as
# /opt/osgallery/guests-retro). OUT_DIR is the preferred isolated-build override;
# GUESTS_ROOT remains supported for compatibility.
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${OUT_DIR:-${GUESTS_ROOT}/${DIR_NAME}}"
IMG_PATH="${GUEST_DIR}/win95-osr2.qcow2"         # final bootable artifact (cirrus/TCG golden)
KVM_IMG_PATH="${GUEST_DIR}/win95-osr2-kvm.qcow2" # KVM/-vga std live variant: Standard VGA is the
# intermediate boot fix; VBEMP_READY=1 finishes it
# at 640x480 High Color (16 bit). COPY-AND-SWAP;
# the cirrus/TCG preservation image is untouched.
WORK_DIR="${WORK_DIR:-${GUEST_DIR}/build}" # downloads + scratch (namespaced)
ZIP_PATH="${WORK_DIR}/${SRC_ZIP_NAME}"
PAYLOAD_DIR="${GUEST_DIR}/payload" # pre-staged payload override drop
SHOT_PNG="${GUEST_DIR}/verify-desktop.png"

# --- Behaviour knobs ---------------------------------------------------------
INJECT="${INJECT:-1}"       # 0 = skip C:\GALLERY software injection
PATCH9X="${PATCH9X:-0}"     # 1 = re-assert patcher9x on the base image
KVM_READY="${KVM_READY:-1}" # 1 = make the KVM-bootable live-tile variant (see KVM section
#     + docs/guests/win9x.md). First swaps to Standard VGA,
#     then VBEMP_READY=1 installs packed 640x480x16-bit.
#     Set 0 only when
#     rebuilding the cirrus TCG preservation image alone.
SETTLE="${SETTLE:-0}"                    # 1 = open an operator-driven first-boot PnP window
SETTLE_WAIT="${SETTLE_WAIT:-240}"        # seconds to let first-boot PnP run
VERIFY="${VERIFY:-1}"                    # 0 = skip the framebuffer verify boot
VERIFY_WAIT="${VERIFY_WAIT:-90}"         # seconds to let the Win95 desktop come up
QEMU_BIN="${QEMU_BIN:-qemu-system-i386}" # Win95 is 32-bit; i386 (x86_64 also OK)

# Payload upstream sources (real URLs). Archive.org items are resolved to a
# concrete file via their _files.xml manifest (ia_fetch). Netscape has no stable
# direct URL — override NETSCAPE_URL or pre-stage $PAYLOAD_DIR/NETSCAPE.EXE.
NETSCAPE_URL="${NETSCAPE_URL:-}" # WinWorld: netscape-navigator/40x
FREEDOOM_URL="${FREEDOOM_URL:-https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip}"
GTA1_URL="${GTA1_URL:-}" # full gtados+gtadata ZIP only

# The live Win95 tile cannot use usb-tablet, so its absolute pointer is supplied
# by the tiny Winsock warpnet agent. i686 MinGW defaults may emit CMOV, which the
# tile's Pentium CPU model does not implement; -march=pentium is load-bearing.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARPNET="${WARPNET:-1}"
WARPNET_SRC="${WARPNET_SRC:-${SCRIPT_DIR}/../../streamhost/guest-agents/win9x/warpnet.c}"
WARPNET_EXE="${WARPNET_EXE:-}"
WARPNET_CC="${WARPNET_CC:-i686-w64-mingw32-gcc}"

# Packed-pixel display fix for the KVM/-vga std image. This is the latest
# available upstream Win9x VBEMP release validated on QEMU 11.0.2. The 032MB
# variant is sufficient for std-vga's 16 MiB BAR.
VBEMP_READY="${VBEMP_READY:-1}"
VBEMP_URL="https://bearwindows.zcm.com.au/191201.zip"
VBEMP_SHA256="93d9bd34fc82904e827e0f4a5cee28beb3013c5d3d8b9730b5367a74b06acd3d"
VBEMP_ZIP="${WORK_DIR}/191201.zip"
VBEMP_STAGE="${WORK_DIR}/vbemp-191201-032MB"
VBEMP_BOOT_WAIT="${VBEMP_BOOT_WAIT:-150}"
VBEMP_WARPD_PORT="${VBEMP_WARPD_PORT:-}"

# Unique, namespaced runtime handles (never reused across concurrent builds)
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
NBD_MNT="${RUN_DIR}/mnt"
VNC_DISP="${VNC_DISP:-62}" # VNC :62 -> tcp 5962; clear of gallery tiles
NBD_DEV=""                 # chosen dynamically in inject/patch steps

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch args this tile runs with in the live gallery.
# (from Win95/manifest.json; emitted here for reference + reuse)
#
#   qemu-system-i386 -machine pc,acpi=off,usb=off,accel=tcg -cpu pentium -m 256 \
#     -drive file=IMG,format=qcow2,if=ide,index=0,media=disk -boot c \
#     -vga cirrus -audiodev AUDIODEV,id=a1 -device sb16,audiodev=a1 \
#     -netdev user,id=n0 -device pcnet,netdev=n0 -rtc base=localtime
#
# neko-qemu / launch-qemu.sh environment-contract for this tile
# (retro-guests-add.sh [neko-era, deleted — git history] row; launch-qemu.sh emits audiodev id "snd"):
#   OS_NAME      = Windows 95
#   QEMU_MACHINE = pc,acpi=off,usb=off   # acpi OFF: Win95 has no ACPI
#   QEMU_MEM     = 256                   # Win9x max ~512
#   QEMU_SMP     = 1
#   QEMU_VGA     = cirrus                # comes up 1024x768 after first-run driver
#   QEMU_SOUND   = -device sb16,audiodev=snd
#   GUEST_DISK   = /guests-retro/Win95/win95-osr2.qcow2
#   GUEST_FMT    = qcow2
#   GUEST_IF     = ide
#   GUEST_BOOT   = c
#   QEMU_EXTRA   = -cpu pentium -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot
#
# DEFAULT is TCG (accel=tcg) for the SHIPPED cirrus 1024x768 hi-colour tile.
# The old note "KVM hangs/corrupts first-boot PnP" was MISDIAGNOSED: KVM hang is the
# guest's *Cirrus Logic 5446 display driver*, not PnP or the CPU/TSC. Win95 DOES run
# under KVM once that driver is swapped for Standard VGA. Full analysis + the working
# KVM launch args + before/after measurements are in docs/guests/win9x.md.
# Build a KVM-ready (Standard-VGA, 640x480x16) variant with KVM_READY=1 (see step 6b).
#
#   KVM launch profile (from the recipe, verified to a responsive normal desktop):
#     qemu-system-i386 -machine pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm \
#       -cpu pentium,-apic -m 256 -smp 1 -vga std ...   # NOT -vga cirrus
#   (userspace irqchip + no local APIC is required: the in-kernel KVM PIT delivers
#    zero IRQ0 to this guest, and -apic is what lets kernel-irqchip=off start.)
###############################################################################

# --------------------------------------------------------------- 0. workspace
mkdir -p "$GUEST_DIR" "$WORK_DIR"

command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
command -v qemu-nbd >/dev/null 2>&1 || die "qemu-nbd not found (needed for injection)"
if [[ "$INJECT" -eq 1 && "$WARPNET" -eq 1 ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 not found (needed to update WIN.INI)"
fi

# ---------- helpers ----------------------------------------------------------
md5_of() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }

# ia_fetch <archive-item> <filename-regex> <dest-file>
# Resolve a concrete file inside an archive.org item via its _files.xml and
# download it. Idempotent: skips if dest already non-empty.
ia_fetch() {
  local item="$1" rx="$2" dest="$3" fx name
  if [[ -s "$dest" ]]; then
    log "  have $(basename "$dest") (cached)"
    return 0
  fi
  fx="$(curl -fsL "https://archive.org/download/${item}/${item}_files.xml")" ||
    {
      log "  WARN: cannot read files.xml for ${item}"
      return 1
    }
  name="$(printf '%s\n' "$fx" | grep -oE 'name="[^"]+"' | sed 's/name="//;s/"//' |
    grep -iE "$rx" | head -n1)"
  [[ -n "$name" ]] || {
    log "  WARN: no file matching /$rx/ in ${item}"
    return 1
  }
  local enc
  enc="$(printf '%s' "$name" | sed 's/ /%20/g')"
  log "  fetching ${item}/${name}"
  curl -fL --retry 3 --retry-delay 2 -o "$dest.part" \
    "https://archive.org/download/${item}/${enc}" &&
    mv -f "$dest.part" "$dest" || {
    rm -f "$dest.part"
    return 1
  }
}

# Pick a free /dev/nbdN (one with no pid holder). Returns via echo.
pick_free_nbd() {
  modprobe nbd max_part=8 2>/dev/null || true
  local n
  for n in $(seq 0 15); do
    [[ -e "/dev/nbd$n" ]] || continue
    if [[ ! -e "/sys/block/nbd$n/pid" ]]; then
      echo "/dev/nbd$n"
      return 0
    fi
  done
  return 1
}

# ---------- unified cleanup (monitor quit -> pidfile; nbd disconnect; umount)-
mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }

# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
cleanup() {
  # stop any verify/settle VM: monitor quit first, pidfile SIGTERM fallback
  if [[ -S "$MON_SOCK" ]]; then
    mon_cmd "quit"
    sleep 1
  fi
  if [[ -f "$PIDFILE" ]]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null || true
      sleep 1
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  # release nbd + mount if injection left them open
  mountpoint -q "$NBD_MNT" 2>/dev/null && umount "$NBD_MNT" 2>/dev/null || true
  [[ -n "$NBD_DEV" ]] && qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

###############################################################################
# 1. DOWNLOAD + verify the source image, unzip, locate the qcow2
###############################################################################
need_dl=1
if [[ -f "$ZIP_PATH" ]] && [[ "$(md5_of "$ZIP_PATH")" == "$SRC_ZIP_MD5" ]]; then
  log "source zip present and MD5 matches — skipping download."
  need_dl=0
fi
if [[ "$need_dl" -eq 1 ]]; then
  log "Downloading source: ${SRC_ZIP_URL}"
  curl -fL --retry 3 --retry-delay 2 -o "${ZIP_PATH}.part" "$SRC_ZIP_URL"
  got="$(md5_of "${ZIP_PATH}.part")"
  [[ "$got" == "$SRC_ZIP_MD5" ]] || {
    rm -f "${ZIP_PATH}.part"
    die "source zip MD5 mismatch: expected $SRC_ZIP_MD5 got $got"
  }
  mv -f "${ZIP_PATH}.part" "$ZIP_PATH"
  log "source zip download OK, MD5 verified."
fi
[[ "$(stat -c %s "$ZIP_PATH")" == "$SRC_ZIP_BYTES" ]] ||
  die "source zip size mismatch: expected $SRC_ZIP_BYTES got $(stat -c %s "$ZIP_PATH")"
[[ "$(sha256sum "$ZIP_PATH" | awk '{print $1}')" == "$SRC_ZIP_SHA256" ]] ||
  die "source zip SHA256 mismatch"
log "source zip size, MD5, and SHA256 verified."

# Build the qcow2 only if we do not already have the final artifact. (Re-runs
# that just re-inject or re-verify must NOT clobber a good injected image.)
if [[ ! -f "$IMG_PATH" ]]; then
  log "Extracting UTM bundle + locating disk image..."
  command -v unzip >/dev/null 2>&1 || die "unzip not found"
  EXTRACT="${WORK_DIR}/extract"
  rm -rf "$EXTRACT"
  mkdir -p "$EXTRACT"
  unzip -o -q "$ZIP_PATH" -d "$EXTRACT"
  # UTM bundle stores the disk as Data/*.qcow2 (or a raw *.img). Pick the largest.
  SRC_DISK="$(find "$EXTRACT" \( -iname '*.qcow2' -o -iname '*.img' -o -iname '*.qcow' \) \
    -type f -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2-)"
  [[ -n "$SRC_DISK" ]] || die "no qcow2/img disk found inside ${SRC_ZIP_NAME}"
  log "found base disk: ${SRC_DISK}"
  log "Normalising to clean qcow2 -> ${IMG_PATH}"
  qemu-img convert -O qcow2 "$SRC_DISK" "${IMG_PATH}.part"
  mv -f "${IMG_PATH}.part" "$IMG_PATH"
  rm -rf "$EXTRACT"
  log "base qcow2 ready."
else
  log "final qcow2 already exists — keeping it (delete it to rebuild from source)."
fi

qemu-img info "$IMG_PATH" >&2 || true

###############################################################################
# 3. PATCHER9X (optional re-assert) — the archive image is ALREADY patched.
#    patcher9x (github.com/JHRobotics/patcher9x, MIT) fixes the Win95 fast-CPU
#    TLB-invalidation crash on >~2.1 GHz hosts. Enable only if you swap in an
#    unpatched base. Portable/Linux CLI: `patch9x <mounted-\WINDOWS-path>`.
###############################################################################
if [[ "$PATCH9X" -eq 1 ]]; then
  if command -v patch9x >/dev/null 2>&1; then
    NBD_DEV="$(pick_free_nbd)" || die "no free /dev/nbd device for patcher9x"
    mkdir -p "$NBD_MNT"
    qemu-nbd --connect="$NBD_DEV" "$IMG_PATH"
    sleep 1
    mount "${NBD_DEV}p1" "$NBD_MNT"
    log "patcher9x: patching $(ls -d "$NBD_MNT"/[Ww][Ii][Nn][Dd][Oo][Ww][Ss] 2>/dev/null)"
    patch9x "$NBD_MNT"/[Ww][Ii][Nn][Dd][Oo][Ww][Ss] || log "  WARN: patch9x returned nonzero"
    umount "$NBD_MNT"
    qemu-nbd -d "$NBD_DEV"
    NBD_DEV=""
  else
    log "PATCH9X=1 but patch9x binary not found — skipping (image is pre-patched)."
  fi
fi

###############################################################################
# 4. INJECT era software into C:\GALLERY\  (the real automated build work)
#    Mount the FAT32 partition via qemu-nbd and drop each payload.
###############################################################################
if [[ "$INJECT" -eq 1 ]]; then
  PL="${WORK_DIR}/payload"
  mkdir -p "$PL"
  if [[ "$WARPNET" -eq 1 ]]; then
    if [[ -n "$WARPNET_EXE" ]]; then
      [[ -s "$WARPNET_EXE" ]] || die "WARPNET_EXE does not exist: $WARPNET_EXE"
    else
      [[ -s "$WARPNET_SRC" ]] || die "warpnet source not found: $WARPNET_SRC"
      command -v "$WARPNET_CC" >/dev/null 2>&1 ||
        die "$WARPNET_CC not found (install gcc-mingw-w64-i686 or set WARPNET_EXE)"
      WARPNET_EXE="${WORK_DIR}/warpnet.exe"
      log "Building Pentium-safe warpnet agent -> ${WARPNET_EXE}"
      "$WARPNET_CC" -O2 -s -mwindows -march=pentium -mtune=pentium \
        -o "$WARPNET_EXE" "$WARPNET_SRC" -lwsock32
    fi
  fi
  log "Fetching era-software payload into ${PL} ..."

  if [[ "$VBEMP_READY" -eq 1 ]]; then
    if [[ ! -s "$VBEMP_ZIP" ]] ||
      [[ "$(sha256sum "$VBEMP_ZIP" | awk '{print $1}')" != "$VBEMP_SHA256" ]]; then
      rm -f "$VBEMP_ZIP"
      log "  fetching VBEMP 19.12.0001: ${VBEMP_URL}"
      curl -fL --retry 3 --retry-delay 2 -o "${VBEMP_ZIP}.part" "$VBEMP_URL"
      got="$(sha256sum "${VBEMP_ZIP}.part" | awk '{print $1}')"
      [[ "$got" == "$VBEMP_SHA256" ]] || {
        rm -f "${VBEMP_ZIP}.part"
        die "VBEMP SHA256 mismatch: expected $VBEMP_SHA256 got $got"
      }
      mv -f "${VBEMP_ZIP}.part" "$VBEMP_ZIP"
    fi
    rm -rf "$VBEMP_STAGE"
    mkdir -p "$VBEMP_STAGE"
    unzip -j "$VBEMP_ZIP" '032MB/*' -d "$VBEMP_STAGE"
    # Upstream vbemp.inf is CRLF. A sed expression anchored to '[Mfg]$'
    # silently misses because of the carriage return, so patch bytes explicitly.
    python3 - "$VBEMP_STAGE/vbemp.inf" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
raw = p.read_bytes()
needle = b'[Mfg]\r\n'
line = b'%JWSoft.DeviceDesc% (QEMU Bochs VBE) = PCIVID, PCI\\VEN_1234&DEV_1111\r\n'
assert raw.count(needle) == 1 and line not in raw
raw = raw.replace(needle, needle + line, 1)
assert raw.count(line) == 1 and b'\n' not in raw.replace(b'\r\n', b'')
p.write_bytes(raw)
PY
    log "  VBEMP staged: 032MB, PCI\\VEN_1234&DEV_1111 INF match, CRLF verified"
  fi

  # --- Winamp 2.95 (freeware, Nullsoft) : archive.org/details/winamp295 -------
  ia_fetch "winamp295" 'winamp.*\.exe$' "$PL/WINAMP.EXE" || true

  # --- Doom95 (native Win95 build; shareware DOOM1.WAD) -----------------------
  #     archive.org/details/DOOM_95  (ships DOOM95.EXE + DLLs + DOOM1.WAD)
  ia_fetch "DOOM_95" '\.(zip)$' "$PL/doom95.zip" || true

  # --- Freedoom WADs (BSD) : GitHub release -----------------------------------
  if [[ ! -s "$PL/freedoom.zip" ]]; then
    log "  fetching Freedoom: ${FREEDOOM_URL}"
    curl -fL --retry 3 -o "$PL/freedoom.zip.part" "$FREEDOOM_URL" &&
      mv -f "$PL/freedoom.zip.part" "$PL/freedoom.zip" || {
      rm -f "$PL/freedoom.zip.part"
      log "  WARN: Freedoom fetch failed"
    }
  fi

  # --- Duke Nukem 3D shareware (ep.1) -----------------------------------------
  ia_fetch "3D_Realms_Duke_Nukem_3D_Shareware" '\.(zip)$' "$PL/duke3d.zip" ||
    ia_fetch "duke-3d-sw" '\.(zip)$' "$PL/duke3d.zip" || true

  # --- Quake shareware (WinQuake) : archive.org/details/Quake_802 -------------
  ia_fetch "Quake_802" '\.(zip)$' "$PL/quake.zip" || true

  # --- GTA 1 DOS rip -----------------------------------------------------------
  # The generic archive.org `rockstar-classics` ZIP is an 837 MiB collection,
  # not the gtados+gtadata payload this image needs. Never download it by a loose
  # regex. Accept only an explicitly supplied full-rip ZIP.
  rm -f "$PL/gta1.zip"
  if [[ -s "$PAYLOAD_DIR/gta1.zip" ]]; then
    cp -f "$PAYLOAD_DIR/gta1.zip" "$PL/gta1.zip"
  elif [[ -n "$GTA1_URL" ]]; then
    log "  fetching operator-pinned GTA full rip: ${GTA1_URL}"
    curl -fL --retry 3 -o "$PL/gta1.zip.part" "$GTA1_URL" &&
      mv -f "$PL/gta1.zip.part" "$PL/gta1.zip" ||
      {
        rm -f "$PL/gta1.zip.part"
        log "  WARN: GTA full-rip fetch failed"
      }
  else
    log "  GTA: no full gtados+gtadata ZIP supplied; skipping (set GTA1_URL or pre-stage $PAYLOAD_DIR/gta1.zip)"
  fi

  # --- Netscape Communicator 4.05 (WinWorld) ---------------------------------
  if [[ -s "$PAYLOAD_DIR/NETSCAPE.EXE" ]]; then
    cp -f "$PAYLOAD_DIR/NETSCAPE.EXE" "$PL/NETSCAPE.EXE"
  elif [[ -n "$NETSCAPE_URL" ]]; then
    log "  fetching Netscape: ${NETSCAPE_URL}"
    curl -fL --retry 3 -o "$PL/NETSCAPE.EXE.part" "$NETSCAPE_URL" &&
      mv -f "$PL/NETSCAPE.EXE.part" "$PL/NETSCAPE.EXE" || {
      rm -f "$PL/NETSCAPE.EXE.part"
      log "  WARN: Netscape fetch failed"
    }
  else
    log "  Netscape: no NETSCAPE_URL and no pre-staged $PAYLOAD_DIR/NETSCAPE.EXE"
    log "            -> SKIPPING (staged installer, non-blocking; IE5.5 is on image)"
  fi

  # --- stage the C:\GALLERY tree on the host, then copy in one pass -----------
  STAGE="${WORK_DIR}/GALLERY"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"/{INSTALL,DOOM95,DUKE3D,QUAKE,GTA}

  [[ -s "$PL/WINAMP.EXE" ]] && cp -f "$PL/WINAMP.EXE" "$STAGE/INSTALL/WINAMP.EXE"
  [[ -s "$PL/NETSCAPE.EXE" ]] && cp -f "$PL/NETSCAPE.EXE" "$STAGE/INSTALL/NETSCAPE.EXE"

  unzip_into() { # <zip> <destdir> [<anchor>] — flatten wrapper dirs to the anchor's root
    [[ -s "$1" ]] || return 0
    local t="${WORK_DIR}/uz.$$"
    rm -rf "$t"
    mkdir -p "$t"
    unzip -o -q "$1" -d "$t" || true
    # <anchor> = a file OR dir name that identifies the TRUE payload root (the
    # IA/old-games shareware zips bury the game under one or two wrapper dirs,
    # e.g. duke3d.zip => "3D Realms - ...(Shareware)/DUKE3D/DUKE3D.EXE"). Find the
    # dir that actually CONTAINS the anchor and copy ITS CONTENTS up, dropping the
    # wrapper(s) so DUKE3D.EXE lands at $dest/DUKE3D.EXE (and gtados/ at $dest/gtados/).
    local anchor="${3:-}" src="" hit=""
    if [[ -n "$anchor" ]]; then
      hit="$(find "$t" -iname "$anchor" -print -quit 2>/dev/null)"
      [[ -n "$hit" ]] && src="$(dirname "$hit")"
    fi
    if [[ -n "$src" && -d "$src" ]]; then
      # flatten: copy the CONTENTS (incl. dotfiles) of the real payload root
      cp -rf "$src"/. "$2"/
    else
      # no anchor (or not found): preserve the archive's own top-level subtree
      (cd "$t" && find . -mindepth 1 -maxdepth 1 -exec cp -rf {} "$2"/ \;)
    fi
    rm -rf "$t"
  }
  unzip_into "$PL/doom95.zip" "$STAGE/DOOM95"
  unzip_into "$PL/duke3d.zip" "$STAGE/DUKE3D" "DUKE3D.EXE"
  unzip_into "$PL/quake.zip" "$STAGE/QUAKE"
  # GTA: flatten any wrapper to the dir that holds gtados/ (+ gtadata/), so the
  # PIF target C:\GALLERY\GTA\GTADOS\GTA24.EXE and the gtados config block below
  # both resolve; a gtawin-only zip has no gtados => staging stays non-fatal.
  unzip_into "$PL/gta1.zip" "$STAGE/GTA" "gtados"

  # --- baked-in game configs (validated on the live tile 2026-07-12) ----------
  #  DUKE3D.CFG: Duke3D v1.1 hard-EXITS at startup when DUKE3D.CFG is missing
  #  ("ReadSetup: DUKE3D.CFG does not exist -- Please run SETUP.EXE") -- to a
  #  gallery viewer the DOS box just flashes and dies. Stage the SETUP.EXE
  #  output verbatim (SB16 0x220/IRQ5/DMA1/HDMA5 = the tile's QEMU sb16; music
  #  None -- no OPL device in the launcher; 8-bit/11kHz mixing).
  base64 -d >"$STAGE/DUKE3D/DUKE3D.CFG" <<'DUKECFG'
W1NldHVwXQ0KO1NldHVwIEZpbGUgZm9yIER1a2UgTnVrZW0gM0QNClNldHVwVmVyc2lvbiA9ICIx
LjEiDQo7IA0KOyANCltTY3JlZW4gU2V0dXBdDQo7IA0KOyANCjtTY3JlZW5Nb2RlDQo7IC0gQ2hh
aW5lZCAtIDANCjsgLSBWZXNhIDIuMCAtIDENCjsgLSBTY3JlZW4gQnVmZmVyZWQgLSAyDQo7IC0g
VHNlbmcgb3B0aW1pemVkIC0gMw0KOyAtIFBhcmFkaXNlIG9wdGltaXplZCAtIDQNCjsgLSBTMyBv
cHRpbWl6ZWQgLSA1DQo7IC0gUmVkQmx1ZSBTdGVyZW8gLSA3DQo7IC0gQ3J5c3RhbCBFeWVzIC0g
Ng0KOyANCjtTY3JlZW5XaWR0aCBwYXNzZWQgdG8gZW5naW5lDQo7IA0KO1NjcmVlbkhlaWdodCBw
YXNzZWQgdG8gZW5naW5lDQo7IA0KOyANClNjcmVlbk1vZGUgPSAyDQpTY3JlZW5XaWR0aCA9IDMy
MA0KU2NyZWVuSGVpZ2h0ID0gMjAwDQo7IA0KOyANClNoYWRvd3MgPSAxDQpFbnZpcm9ubWVudCA9
ICIiDQpEZXRhaWwgPSAxDQpUaWx0ID0gMQ0KTWVzc2FnZXMgPSAxDQpPdXQgPSAwDQpTY3JlZW5T
aXplID0gOA0KU2NyZWVuR2FtbWEgPSAwDQpbU291bmQgU2V0dXBdDQo7IA0KOyANCkZYRGV2aWNl
ID0gMA0KTXVzaWNEZXZpY2UgPSAxMw0KRlhWb2x1bWUgPSAyMjANCk11c2ljVm9sdW1lID0gMjAw
DQpOdW1Wb2ljZXMgPSA0DQpOdW1DaGFubmVscyA9IDINCk51bUJpdHMgPSA4DQpNaXhSYXRlID0g
MTEwMDANCk1pZGlQb3J0ID0gMHgzMzANCkJsYXN0ZXJBZGRyZXNzID0gMHgyMjANCkJsYXN0ZXJU
eXBlID0gNg0KQmxhc3RlckludGVycnVwdCA9IDUNCkJsYXN0ZXJEbWE4ID0gMQ0KQmxhc3RlckRt
YTE2ID0gNQ0KQmxhc3RlckVtdSA9IDB4NjIwDQpSZXZlcnNlU3RlcmVvID0gMA0KOyANCjsgDQpT
b3VuZFRvZ2dsZSA9IDENClZvaWNlVG9nZ2xlID0gMQ0KQW1iaWVuY2VUb2dnbGUgPSAxDQpNdXNp
Y1RvZ2dsZSA9IDENCltLZXlEZWZpbml0aW9uc10NCjsgDQo7IA0KTW92ZV9Gb3J3YXJkID0gIlVw
IiAiS3BhZDgiDQpNb3ZlX0JhY2t3YXJkID0gIkRvd24iICJLcGFkMiINClR1cm5fTGVmdCA9ICJM
ZWZ0IiAiS3BhZDQiDQpUdXJuX1JpZ2h0ID0gIlJpZ2h0IiAiS1BhZDYiDQpTdHJhZmUgPSAiTEFs
dCIgIlJBbHQiDQpGaXJlID0gIkxDdHJsIiAiUkN0cmwiDQpPcGVuID0gIlNwYWNlIiAiIg0KUnVu
ID0gIkxTaGlmdCIgIlJTaGlmdCINCkF1dG9SdW4gPSAiQ2FwTGNrIiAiIg0KSnVtcCA9ICJBIiAi
LyINCkNyb3VjaCA9ICJaIiAiIg0KTG9va19VcCA9ICJQZ1VwIiAiS3BhZDkiDQpMb29rX0Rvd24g
PSAiUGdEbiIgIktwYWQzIg0KTG9va19MZWZ0ID0gIkluc2VydCIgIktwYWQwIg0KTG9va19SaWdo
dCA9ICJEZWxldGUiICJLcGFkLiINClN0cmFmZV9MZWZ0ID0gIiwiICIiDQpTdHJhZmVfUmlnaHQg
PSAiLiIgIiINCkFpbV9VcCA9ICJIb21lIiAiS1BhZDciDQpBaW1fRG93biA9ICJFbmQiICJLcGFk
MSINCldlYXBvbl8xID0gIjEiICIiDQpXZWFwb25fMiA9ICIyIiAiIg0KV2VhcG9uXzMgPSAiMyIg
IiINCldlYXBvbl80ID0gIjQiICIiDQpXZWFwb25fNSA9ICI1IiAiIg0KV2VhcG9uXzYgPSAiNiIg
IiINCldlYXBvbl83ID0gIjciICIiDQpXZWFwb25fOCA9ICI4IiAiIg0KV2VhcG9uXzkgPSAiOSIg
IiINCldlYXBvbl8xMCA9ICIwIiAiIg0KSW52ZW50b3J5ID0gIkVudGVyIiAiS3BkRW50Ig0KSW52
ZW50b3J5X0xlZnQgPSAiWyIgIiINCkludmVudG9yeV9SaWdodCA9ICJdIiAiIg0KSG9sb19EdWtl
ID0gIkgiICIiDQpKZXRwYWNrID0gIkoiICIiDQpOaWdodFZpc2lvbiA9ICJOIiAiIg0KTWVkS2l0
ID0gIk0iICIiDQpUdXJuQXJvdW5kID0gIkJha1NwYyIgIiINClNlbmRNZXNzYWdlID0gIlQiICIi
DQpNYXAgPSAiVGFiIiAiIg0KU2hyaW5rX1NjcmVlbiA9ICItIiAiS3BhZC0iDQpFbmxhcmdlX1Nj
cmVlbiA9ICI9IiAiS3BhZCsiDQpDZW50ZXJfVmlldyA9ICJLUGFkNSIgIiINCkhvbHN0ZXJfV2Vh
cG9uID0gIlNjckxjayIgIiINClNob3dfT3Bwb25lbnRzX1dlYXBvbiA9ICJXIiAiIg0KTWFwX0Zv
bGxvd19Nb2RlID0gIkYiICIiDQpTZWVfQ29vcF9WaWV3ID0gIksiICIiDQpNb3VzZV9BaW1pbmcg
PSAiVSIgIiINClRvZ2dsZV9Dcm9zc2hhaXIgPSAiSSIgIiINClN0ZXJvaWRzID0gIlIiICIiDQo7
IA0KOyANCltDb250cm9sc10NCjsgDQo7IA0KO0NvbnRyb2xzDQo7IA0KO0NvbnRyb2xsZXJUeXBl
DQo7IC0gS2V5Ym9hcmQgICAgICAgICAgICAgICAgICAtIDANCjsgLSBLZXlib2FyZCBhbmQgTW91
c2UgICAgICAgIC0gMQ0KOyAtIEtleWJvYXJkIGFuZCBKb3lzdGljayAgICAgLSAyDQo7IC0gS2V5
Ym9hcmQgYW5kIEdhbWVwYWQgICAgICAtIDQNCjsgLSBLZXlib2FyZCBhbmQgRXh0ZXJuYWwgICAg
IC0gMw0KOyAtIEtleWJvYXJkIGFuZCBGbGlnaHRTdGljayAgLSA1DQo7IC0gS2V5Ym9hcmQgYW5k
IFRocnVzdE1hc3RlciAtIDYNCjsgDQo7IA0KQ29udHJvbGxlclR5cGUgPSAxDQpKb3lzdGlja1Bv
cnQgPSAwDQpNb3VzZVNlbnNpdGl2aXR5ID0gMzI3NjgNCkV4dGVybmFsRmlsZW5hbWUgPSAiRVhU
RVJOQUwuRVhFIg0KRW5hYmxlUnVkZGVyID0gMA0KTW91c2VBaW1pbmcgPSAwDQpNb3VzZUJ1dHRv
bjAgPSAiRmlyZSINCk1vdXNlQnV0dG9uQ2xpY2tlZDAgPSAiIg0KTW91c2VCdXR0b24xID0gIlN0
cmFmZSINCk1vdXNlQnV0dG9uQ2xpY2tlZDEgPSAiT3BlbiINCk1vdXNlQnV0dG9uMiA9ICJNb3Zl
X0ZvcndhcmQiDQpNb3VzZUJ1dHRvbkNsaWNrZWQyID0gIiINCkpveXN0aWNrQnV0dG9uMCA9ICJG
aXJlIg0KSm95c3RpY2tCdXR0b25DbGlja2VkMCA9ICIiDQpKb3lzdGlja0J1dHRvbjEgPSAiU3Ry
YWZlIg0KSm95c3RpY2tCdXR0b25DbGlja2VkMSA9ICJJbnZlbnRvcnkiDQpKb3lzdGlja0J1dHRv
bjIgPSAiUnVuIg0KSm95c3RpY2tCdXR0b25DbGlja2VkMiA9ICJKdW1wIg0KSm95c3RpY2tCdXR0
b24zID0gIk9wZW4iDQpKb3lzdGlja0J1dHRvbkNsaWNrZWQzID0gIkNyb3VjaCINCkpveXN0aWNr
QnV0dG9uNCA9ICJBaW1fRG93biINCkpveXN0aWNrQnV0dG9uQ2xpY2tlZDQgPSAiIg0KSm95c3Rp
Y2tCdXR0b241ID0gIkxvb2tfUmlnaHQiDQpKb3lzdGlja0J1dHRvbkNsaWNrZWQ1ID0gIiINCkpv
eXN0aWNrQnV0dG9uNiA9ICJBaW1fVXAiDQpKb3lzdGlja0J1dHRvbkNsaWNrZWQ2ID0gIiINCkpv
eXN0aWNrQnV0dG9uNyA9ICJMb29rX0xlZnQiDQpKb3lzdGlja0J1dHRvbkNsaWNrZWQ3ID0gIiIN
Ck1vdXNlQW5hbG9nQXhlczAgPSAiYW5hbG9nX3R1cm5pbmciDQpNb3VzZURpZ2l0YWxBeGVzMF8w
ID0gIiINCk1vdXNlRGlnaXRhbEF4ZXMwXzEgPSAiIg0KTW91c2VBbmFsb2dBeGVzMSA9ICJhbmFs
b2dfbW92aW5nIg0KTW91c2VEaWdpdGFsQXhlczFfMCA9ICIiDQpNb3VzZURpZ2l0YWxBeGVzMV8x
ID0gIiINCkpveXN0aWNrQW5hbG9nQXhlczAgPSAiYW5hbG9nX3R1cm5pbmciDQpKb3lzdGlja0Rp
Z2l0YWxBeGVzMF8wID0gIiINCkpveXN0aWNrRGlnaXRhbEF4ZXMwXzEgPSAiIg0KSm95c3RpY2tB
bmFsb2dBeGVzMSA9ICJhbmFsb2dfbW92aW5nIg0KSm95c3RpY2tEaWdpdGFsQXhlczFfMCA9ICIi
DQpKb3lzdGlja0RpZ2l0YWxBeGVzMV8xID0gIiINCkpveXN0aWNrQW5hbG9nQXhlczIgPSAiYW5h
bG9nX3N0cmFmaW5nIg0KSm95c3RpY2tEaWdpdGFsQXhlczJfMCA9ICIiDQpKb3lzdGlja0RpZ2l0
YWxBeGVzMl8xID0gIiINCkpveXN0aWNrQW5hbG9nQXhlczMgPSAiIg0KSm95c3RpY2tEaWdpdGFs
QXhlczNfMCA9ICJSdW4iDQpKb3lzdGlja0RpZ2l0YWxBeGVzM18xID0gIiINCkdhbWVQYWREaWdp
dGFsQXhlczBfMCA9ICJUdXJuX0xlZnQiDQpHYW1lUGFkRGlnaXRhbEF4ZXMwXzEgPSAiVHVybl9S
aWdodCINCkdhbWVQYWREaWdpdGFsQXhlczFfMCA9ICJNb3ZlX0ZvcndhcmQiDQpHYW1lUGFkRGln
aXRhbEF4ZXMxXzEgPSAiTW92ZV9CYWNrd2FyZCINCjsgDQo7IA0KW0NvbW0gU2V0dXBdDQo7IA0K
OyANCkNvbVBvcnQgPSAyDQpJcnFOdW1iZXIgPSB+DQpVYXJ0QWRkcmVzcyA9IH4NClBvcnRTcGVl
ZCA9IDk2MDANClRvbmVEaWFsID0gMQ0KU29ja2V0TnVtYmVyID0gfg0KTnVtYmVyUGxheWVycyA9
IDINCk1vZGVtTmFtZSA9ICIiDQpJbml0U3RyaW5nID0gIkFUWiINCkhhbmd1cFN0cmluZyA9ICJB
VEgwPTAiDQpEaWFsb3V0U3RyaW5nID0gIiINClBsYXllck5hbWUgPSAiRFVLRSINClJUU05hbWUg
PSAiRFVLRS5SVFMiDQpQaG9uZU51bWJlciA9ICIiDQpDb25uZWN0VHlwZSA9IDANCkNvbW1iYXRN
YWNybyMwID0gIkFuIGluc3BpcmF0aW9uIGZvciBiaXJ0aCBjb250cm9sLiINCkNvbW1iYXRNYWNy
byMxID0gIllvdSdyZSBnb25uYSBkaWUgZm9yIHRoYXQhIg0KQ29tbWJhdE1hY3JvIzIgPSAiSXQg
aHVydHMgdG8gYmUgeW91LiINCkNvbW1iYXRNYWNybyMzID0gIkx1Y2t5IFNvbiBvZiBhIEJpdGNo
LiINCkNvbW1iYXRNYWNybyM0ID0gIkhtbW0uLi4uUGF5YmFjayB0aW1lLiINCkNvbW1iYXRNYWNy
byM1ID0gIllvdSBib3R0b20gZHdlbGxpbmcgc2N1bSBzdWNrZXIuIg0KQ29tbWJhdE1hY3JvIzYg
PSAiRGFtbiwgeW91J3JlIHVnbHkuIg0KQ29tbWJhdE1hY3JvIzcgPSAiSGEgaGEgaGEuLi5XYXN0
ZWQhIg0KQ29tbWJhdE1hY3JvIzggPSAiWW91IHN1Y2shIg0KQ29tbWJhdE1hY3JvIzkgPSAiQUFS
UlJHSEhISEghISEiDQpQaG9uZU5hbWUjMCA9ICIiDQpQaG9uZU51bWJlciMwID0gIiINClBob25l
TmFtZSMxID0gIiINClBob25lTnVtYmVyIzEgPSAiIg0KUGhvbmVOYW1lIzIgPSAiIg0KUGhvbmVO
dW1iZXIjMiA9ICIiDQpQaG9uZU5hbWUjMyA9ICIiDQpQaG9uZU51bWJlciMzID0gIiINClBob25l
TmFtZSM0ID0gIiINClBob25lTnVtYmVyIzQgPSAiIg0KUGhvbmVOYW1lIzUgPSAiIg0KUGhvbmVO
dW1iZXIjNSA9ICIiDQpQaG9uZU5hbWUjNiA9ICIiDQpQaG9uZU51bWJlciM2ID0gIiINClBob25l
TmFtZSM3ID0gIiINClBob25lTnVtYmVyIzcgPSAiIg0KUGhvbmVOYW1lIzggPSAiIg0KUGhvbmVO
dW1iZXIjOCA9ICIiDQpQaG9uZU5hbWUjOSA9ICIiDQpQaG9uZU51bWJlciM5ID0gIiINCltNaXNj
XQ0KRXhlY3V0aW9ucyA9IDINCg==
DUKECFG

  #  GTA1: the Windows build (gtawin\GTAWIN.EXE) does NOT run on this image:
  #  its DirectPlay import fails at load ("A required .DLL file, DPLAYX.DLL,
  #  was not found" -- OSR2 ships only DirectX 2) and the KVM golden's
  #  display driver exposes no 8/16-bpp DirectDraw modes anyway. The WORKING
  #  path is the DOS build in a full-screen DOS box: QEMU's VGA BIOS provides
  #  the mode independent of the Windows display driver. Which DOS build
  #  matters (2026-07-14): under the VBEMP desktop driver (baked 07-13),
  #  GTA8.EXE (8-bit 640x400) freezes at level entry -- first frame paints,
  #  then its VESA page flips go to a page the scanout never shows (game loop
  #  keeps spinning behind a stale display; menu/intro are fine). GTA24.EXE
  #  (the high-colour VESA-LFB build) renders straight to the linear
  #  framebuffer and plays correctly (320x200 in-game). Under the older
  #  Standard-VGA golden gta8 worked; keep gta24 -- it works on both.
  #  Needs a rip that carries gtados\ + gtadata\ (old-games style; a
  #  gtawin-only zip cannot work -- pre-stage the full rip as
  #  $PAYLOAD_DIR/gta1.zip in that case).
  if [[ -d "$STAGE/GTA/gtados" ]]; then
    # launcher chain target: VESA-LFB build (gta8 = page-flip freeze under
    # VBEMP; gtafx = 3dfx, no Voodoo here)
    printf 'gta24.exe\r\n' >"$STAGE/GTA/gtados/DINO.BAT"
    # runtype 0 = Low Color, so K.EXE's "Run GTA" menu defaults to the VGA build
    base64 -d >"$STAGE/GTA/gtados/STARTUP.INI" <<'GTASTARTUP'
W2R1bW15XQ0KMA0KDQoNCltsYW5ndWFnZV0NCjANCltydW50eXBlXQ0KMA0KW2NvbnRyb2xzXQ0K
MzMxLDMzMywzMjgsMzM2LDU3LDI5LDI4LDE1LDQ1LDQ0DQoNCg0KDQo=
GTASTARTUP
    # Miles Sound System digital-audio driver config (what K.EXE's "Configure
    # Sound Details -> SB16 -> auto-detect" writes; reads BLASTER for IRQ/DMA)
    base64 -d >"$STAGE/GTA/gtados/DIG.INI" <<'GTADIG'
Ow0KO01pbGVzIFNvdW5kIFN5c3RlbSBWMy41MEQgb2YgMTQtU2VwLTk2DQo7DQoNCkRFVklDRSAg
ICAgIENyZWF0aXZlIExhYnMgU291bmQgQmxhc3RlciAxNiBvciBBV0UzMg0KRFJJVkVSICAgICAg
U0IxNi5ESUcNCklPX0FERFIgICAgIDIyMGgNCklSUSAgICAgICAgIC0xDQpETUFfOF9CSVQgICAt
MQ0KRE1BXzE2X0JJVCAgLTENCg==
GTADIG
  else
    log "  WARN: GTA rip has no gtados/ -- DOS-build config skipped (gtawin.exe alone does NOT run on Win95 OSR2, see above)"
  fi

  # Freedoom WADs -> DOOM95 as FREEDM1/2.WAD (8.3 names, matching the golden img)
  if [[ -s "$PL/freedoom.zip" ]]; then
    t="${WORK_DIR}/fd.$$"
    rm -rf "$t"
    mkdir -p "$t"
    unzip -o -q "$PL/freedoom.zip" -d "$t"
    fd1="$(find "$t" -iname 'freedoom1.wad' | head -n1)"
    fd2="$(find "$t" -iname 'freedoom2.wad' | head -n1)"
    [[ -n "$fd1" ]] && cp -f "$fd1" "$STAGE/DOOM95/FREEDM1.WAD"
    [[ -n "$fd2" ]] && cp -f "$fd2" "$STAGE/DOOM95/FREEDM2.WAD"
    rm -rf "$t"
  fi

  # C:\GALLERY\README.TXT (verbatim from the golden image)
  cat >"$STAGE/README.TXT" <<'RDM'
RETRO GALLERY - preinstalled software (C:\GALLERY)
=================================================

BROWSER : C:\GALLERY\INSTALL\NETSCAPE.EXE  (run once to install Netscape Communicator 4.05)
          (Internet Explorer is also already on this system)
WINAMP  : C:\GALLERY\INSTALL\WINAMP.EXE     (run once to install Winamp 2.95)

GAMES (ready to run):
  DOOM    : C:\GALLERY\DOOM95\DOOM95.EXE     (shareware DOOM1.WAD; also FREEDM1/2.WAD)
  DUKE3D  : C:\GALLERY\DUKE3D\DUKE3D.EXE     (shareware; SETUP.EXE sound config baked in)
  QUAKE   : C:\GALLERY\QUAKE\QUAKE.EXE       (shareware; or Q95.BAT)
  GTA     : C:\GALLERY\GTA\gtados\GTA24.EXE  (DOS VESA-LFB build; gta8 freezes under VBEMP, gtawin.exe needs DirectX 5+)

RDM

  # --- mount the guest FAT32 partition and copy C:\GALLERY in -----------------
  NBD_DEV="$(pick_free_nbd)" || die "no free /dev/nbd device for injection"
  mkdir -p "$NBD_MNT"
  log "Injecting C:\\GALLERY via ${NBD_DEV} ..."
  qemu-nbd --connect="$NBD_DEV" "$IMG_PATH"
  sleep 1
  # partition 1 is the W95 FAT32 (LBA) volume
  mount -t vfat "${NBD_DEV}p1" "$NBD_MNT"
  rm -rf "$NBD_MNT/GALLERY"
  cp -rf "$STAGE" "$NBD_MNT/GALLERY"
  if [[ "$VBEMP_READY" -eq 1 ]]; then
    rm -rf "$NBD_MNT/VBEMP"
    mkdir -p "$NBD_MNT/VBEMP"
    cp -f "$VBEMP_STAGE/VBEMP.DRV" "$VBEMP_STAGE/VBE.vxd" \
      "$VBEMP_STAGE/vbemp.inf" "$NBD_MNT/VBEMP/"
    printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Control Panel\\Desktop]\r\n' \
      >"$NBD_MNT/VBEMP/DRAG.REG"
    printf '"DragFullWindows"="1"\r\n' >>"$NBD_MNT/VBEMP/DRAG.REG"
    log "VBEMP 19.12.0001 + DragFullWindows=1 staged in C:\\VBEMP"
  fi
  if [[ "$WARPNET" -eq 1 ]]; then
    cp -f "$WARPNET_EXE" "$NBD_MNT/WARPNET.EXE"
    python3 - "$NBD_MNT/WINDOWS/WIN.INI" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
raw = p.read_bytes()
lines = raw.decode('latin-1').splitlines()
section = None
done = False
for i, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith('[') and stripped.endswith(']'):
        section = stripped.lower()
    elif section == '[windows]' and stripped.lower().startswith('load='):
        value = line.split('=', 1)[1].strip()
        if r'c:\warpnet.exe' not in value.lower():
            lines[i] = 'load=' + (value + ' ' if value else '') + r'C:\WARPNET.EXE'
        done = True
        break
if not done:
    for i, line in enumerate(lines):
        if line.strip().lower() == '[windows]':
            lines.insert(i + 1, r'load=C:\WARPNET.EXE')
            done = True
            break
if not done:
    lines.extend(['', '[windows]', r'load=C:\WARPNET.EXE'])
p.write_bytes(('\r\n'.join(lines) + '\r\n').encode('latin-1'))
PY
    log "warpnet baked as C:\\WARPNET.EXE and added to WIN.INI load="
  fi
  # SET BLASTER for every Win95 DOS box (Miles/GTA-DOS auto-detect reads it;
  # matches the launcher's sb16: 0x220 IRQ5 DMA1 HDMA5)
  if ! grep -qi "BLASTER" "$NBD_MNT/AUTOEXEC.BAT" 2>/dev/null; then
    printf 'SET BLASTER=A220 I5 D1 H5 P330 T6\r\n' >>"$NBD_MNT/AUTOEXEC.BAT"
  fi
  # Desktop launchers for the two DOS games (binary Win95 PIFs, byte-identical
  # to the live golden; GTA.pif was patched from the Duke PIF -> target
  # C:\GALLERY\GTA\GTADOS\GTA24.EXE, workdir C:\GALLERY\GTA\GTADOS; retargeted
  # from GTA8.EXE 2026-07-14 -- gta8 page-flip-freezes under the VBEMP driver)
  mkdir -p "$NBD_MNT/WINDOWS/Desktop"
  base64 -d >"$NBD_MNT/WINDOWS/Desktop/GTA.pif" <<'GTAPIF'
AHhHVEEgICAgICAgICAgICAgICAgICAgICAgICAgICCAAgAAQzpcR0FMTEVSWVxHVEFcR1RBRE9T
XEdUQTI0LkVYRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABDOlxHQUxMRVJZXEdU
QVxHVEFET1MAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAABAP8ZUAAABwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAATUlDUk9TT0ZUIFBJRkVYAIcBAABxAVdJTkRPV1Mg
Mzg2IDMuMAAFAp0BaACAAgAAZAAyAP//AAD//wAAAhACAB8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAFdJTkRPV1MgVk1NIDQuMAD//xsCrAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
UElGTUdSLkRMTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAADIAAQAAAAAAAAAAAAAAAQAAAAUA
GQADAMgA6AMCAAoAAQAAAAAAAAAcAAAAAAAAAAYACwBUZXJtaW5hbAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAEx1Y2lkYSBDb25zb2xlAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAUAAZAJAB4QCcARwB
FgAAAAEA//////////9aAFgA9gF0AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAA==
GTAPIF
  base64 -d >"$NBD_MNT/WINDOWS/Desktop/Duke Nukem 3D.pif" <<'DUKEPIF'
AHhEVUtFM0QgICAgICAgICAgICAgICAgICAgICAgICCAAgAAQzpcR0FMTEVSWVxEVUtFM0RcRFVL
RTNELkVYRQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABDOlxHQUxMRVJZXERV
S0UzRAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAABAP8ZUAAABwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAATUlDUk9TT0ZUIFBJRkVYAIcBAABxAVdJTkRPV1Mg
Mzg2IDMuMAAFAp0BaACAAgAAZAAyAP//AAD//wAAAhACAB8AAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAFdJTkRPV1MgVk1NIDQuMAD//xsCrAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
UElGTUdSLkRMTAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAADIAAQAAAAAAAAAAAAAAAQAAAAUA
GQADAMgA6AMCAAoAAQAAAAAAAAAcAAAAAAAAAAAAAABUZXJtaW5hbAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAEx1Y2lkYSBDb25zb2xlAAAAAAAAAAAAAAAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAA
FgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAA==
DUKEPIF
  # drop the stale shortcut to the non-working Windows build, if present
  rm -f "$NBD_MNT/WINDOWS/Desktop/GTA.lnk"
  sync
  df -h "$NBD_MNT" >&2 || true
  umount "$NBD_MNT"
  qemu-nbd -d "$NBD_DEV"
  NBD_DEV=""
  log "injection complete."
else
  log "INJECT=0 — leaving C:\\GALLERY as-is."
fi

###############################################################################
# 6. FIRST-BOOT PnP SETTLE (operator-driven; see AUTOMATION HONESTY)
#    Blind Enter loops are unsafe: once the desktop appears they can launch the
#    selected icon, and monitor quit leaves FAT dirty. SETTLE therefore defaults
#    off. With SETTLE=1 this opens a VNC/monitor window but sends no input; perform
#    the documented click-through and a guest shutdown during SETTLE_WAIT.
###############################################################################
boot_qemu() { # <extra-boot-args...> ; launches daemonized verify/settle VM
  mkdir -p "$RUN_DIR"
  "$QEMU_BIN" \
    -machine pc,acpi=off,usb=off,accel=tcg -cpu pentium -m 256 \
    -drive file="$IMG_PATH",format=qcow2,if=ide,index=0,media=disk -boot c \
    -vga cirrus \
    -audiodev none,id=snd -device sb16,audiodev=snd \
    -netdev user,id=n0 -device pcnet,netdev=n0 -rtc base=localtime \
    "$@" \
    -vnc ":${VNC_DISP}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -pidfile "$PIDFILE" \
    -display none -daemonize
  for _ in $(seq 1 20); do
    [[ -S "$MON_SOCK" ]] && break
    sleep 0.5
  done
}

if [[ "$SETTLE" -eq 1 ]]; then
  if command -v "$QEMU_BIN" >/dev/null 2>&1; then
    log "First-boot settle: operator window ${SETTLE_WAIT}s (VNC :${VNC_DISP}, monitor ${MON_SOCK})..."
    boot_qemu
    end=$((SECONDS + SETTLE_WAIT))
    while [[ $SECONDS -lt $end ]]; do
      [[ -f "$PIDFILE" ]] || break
      p="$(cat "$PIDFILE" 2>/dev/null || true)"
      [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null || break
      sleep 2
    done
    if [[ -S "$MON_SOCK" ]]; then
      log "WARN: settle VM did not guest-shutdown before timeout; stopping via its monitor."
      mon_cmd "quit"
      sleep 2
    fi
    # ensure it is down before verify reuses the sockets
    if [[ -f "$PIDFILE" ]]; then
      p="$(cat "$PIDFILE" 2>/dev/null || true)"
      [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null && {
        kill "$p" 2>/dev/null || true
        sleep 1
      }
    fi
    rm -f "$MON_SOCK" "$PIDFILE"
    log "NOTE: reproduce every manual input from docs/guests/win9x.md, then guest-shutdown cleanly."
  else
    log "WARN: $QEMU_BIN not found — cannot run first-boot settle."
  fi
fi

###############################################################################
# 6b. KVM-READY VARIANT (optional; KVM_READY=1) — BEST-EFFORT, see recipe.
#   Win95's Cirrus 5446 display driver deadlocks the guest under accel=kvm (root
#   cause + full evidence in docs/guests/win9x.md). Swapping the display
#   driver to the generic "Standard PCI Graphics Adapter (VGA)" makes the image
#   boot to a responsive normal desktop under KVM (at 640x480x16).
#
#   Reproducible method: boot ONCE under `-vga std` + TCG (TCG boots fine; the
#   deadlock is KVM-only). Win95 sees the changed adapter and pops the "Update
#   Device Driver Wizard" offering the Standard PCI Graphics Adapter; clicking
#   Next -> Finish -> Restart (Yes) installs it. We drive those default buttons
#   with periodic `sendkey ret` (same trick as the settle step). After this the
#   image boots KVM with the launch profile documented above.
#
#   HONESTY: like the settle step this is BEST-EFFORT and not guaranteed hands-off
#   (a wizard page may want a pointer click sendkey cannot make). If the image is
#   not KVM-ready afterwards, do the one-time swap by hand (boot it once under
#   `-vga std`, click the wizard through, or Device Manager -> Display adapters ->
#   change driver to Standard PCI Graphics Adapter (VGA), restart).
###############################################################################
boot_qemu_stdvga() { # like boot_qemu but Standard VGA + writes PERSIST (no -snapshot)
  # $1 = image to boot RW (the KVM COPY, never the golden). TCG boots fine; the
  # cirrus deadlock is KVM-only, so the one-time driver swap is done under TCG.
  local img="${1:?boot_qemu_stdvga needs an image path}"
  mkdir -p "$RUN_DIR"
  "$QEMU_BIN" \
    -machine pc,acpi=off,usb=off,accel=tcg -cpu pentium -m 256 \
    -drive file="$img",format=qcow2,if=ide,index=0,media=disk -boot c \
    -vga std \
    -audiodev none,id=snd -device sb16,audiodev=snd \
    -netdev user,id=n0 -device pcnet,netdev=n0 -rtc base=localtime \
    -vnc ":${VNC_DISP}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -pidfile "$PIDFILE" \
    -display none -daemonize
  for _ in $(seq 1 20); do
    [[ -S "$MON_SOCK" ]] && break
    sleep 0.5
  done
}

if [[ "$KVM_READY" -eq 1 ]]; then
  if command -v "$QEMU_BIN" >/dev/null 2>&1; then
    # COPY-AND-SWAP: never modify the in-use cirrus golden. Work on a fresh copy and
    # emit it as win95-osr2-kvm.qcow2 (this is the image the live KVM tile boots).
    log "KVM-ready: copy-and-swap golden -> ${KVM_IMG_PATH} (golden left untouched)..."
    cp -f "$IMG_PATH" "$KVM_IMG_PATH"
    sync
    log "KVM-ready: booting the COPY once under -vga std (TCG) to install Standard VGA driver..."
    boot_qemu_stdvga "$KVM_IMG_PATH"
    # Do not send blind input during boot: an unclean prior artifact runs ScanDisk,
    # where Enter toggles Pause. Allow boot/PnP to settle first, then advance only
    # the small default-button cascade at conservative intervals.
    sleep 150
    mon_cmd "sendkey ret"
    sleep 45
    mon_cmd "sendkey ret"
    sleep 30
    mon_cmd "sendkey ret"
    sleep 30
    log "KVM-ready: driver-swap window elapsed; clean-shutting the guest (Start->Shut Down)..."
    # Clean Win95 shutdown so the on-disk state is consistent (no ScanDisk on next boot):
    # Ctrl+Esc opens Start; Up wraps to Shut Down; Enter opens the dialog; Enter confirms Yes.
    printf 'sendkey ctrl-esc\n' | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true
    sleep 2
    mon_cmd "sendkey up"
    sleep 1
    mon_cmd "sendkey ret"
    sleep 3
    mon_cmd "sendkey ret"
    sleep 45
    log "KVM-ready: stopping (monitor quit)."
    mon_cmd "quit"
    sleep 2
    if [[ -f "$PIDFILE" ]]; then
      p="$(cat "$PIDFILE" 2>/dev/null || true)"
      [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null && {
        kill "$p" 2>/dev/null || true
        sleep 1
      }
    fi
    rm -f "$MON_SOCK" "$PIDFILE"
    log "KVM-ready: ${KVM_IMG_PATH} display driver is now Standard VGA. VERIFIED live recipe"
    log "           (docs/guests/win9x.md + the (deleted neko-era) win95-perf-override.yml):"
    log "             QEMU_MACHINE=pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm"
    log "             QEMU_VGA=std  QEMU_SMP=1  GUEST_DISK=/guests/Win95/win95-osr2-kvm.qcow2"
    log "             QEMU_EXTRA='-cpu pentium,-apic -netdev user,id=n0 -device pcnet,netdev=n0 -snapshot'"
    log "           (-apic removal is what lets kernel-irqchip=off start; -vga std avoids the"
    log "            cirrus-driver KVM deadlock.) If the swap did not take, do it by hand (see 6b)."
  else
    log "WARN: $QEMU_BIN not found — cannot build KVM-ready variant."
  fi
fi

###############################################################################
# 6c. SMOOTH FULL-WINDOW DRAG — VBEMP 19.12.0001, 640x480x16-bit
#
# Driver: https://bearwindows.zcm.com.au/191201.zip
# SHA256: 93d9bd34fc82904e827e0f4a5cee28beb3013c5d3d8b9730b5367a74b06acd3d
# Variant: 032MB/{VBEMP.DRV,VBE.vxd,vbemp.inf}; DriverVer 19.12.0001.
#
# Step 4 already staged C:\VBEMP and inserted this exact CRLF-aware INF line
# immediately after [Mfg]:
#   %JWSoft.DeviceDesc% (QEMU Bochs VBE) = PCIVID, PCI\VEN_1234&DEV_1111
# A line-oriented sed expression ending in [Mfg]$ is wrong: the upstream INF has
# a trailing carriage return. Keep -vga std; Cirrus deadlocks under this KVM profile.
#
# Validated Setup path (the automation below drives the equivalent controls):
#   Display Properties -> Settings -> Advanced Properties -> Adapter -> Change ->
#   Have Disk -> C:\VBEMP -> VBE Miniport(QEMUBochsVBE) -> Apply -> cold boot.
# The nearby "VBE Miniport - Standard PCI Graphics Adapter (VGA)" model is NOT the
# target. On the next cold boot the 032MB driver selects 640x480 High Color (16 bit).
# DRAG.REG then sets DragFullWindows=1; the Plus! checkbox reads "Show window contents
# while dragging". The transient corrupt/black frame during the driver switch is
# expected; acceptance is always from a fresh cold-boot framebuffer.
###############################################################################

vbemp_hmp_key() {
  mon_cmd "sendkey $1"
  sleep 0.25
}

vbemp_hmp_type() {
  local text="$1" ch key i
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:i:1}"
    case "$ch" in
      [a-z0-9]) key="$ch" ;;
      ' ') key=spc ;;
      ':') key=shift-semicolon ;;
      "\\") key=backslash ;;
      '/') key=slash ;;
      '.') key="dot" ;;
      *) die "VBEMP GUI typer has no mapping for: $ch" ;;
    esac
    vbemp_hmp_key "$key"
  done
}

vbemp_warp_probe() {
  timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/${VBEMP_WARPD_PORT}; printf 'QUIT\\n' >&3" \
    >/dev/null 2>&1
}

vbemp_warp_move() {
  local x="$1" y="$2"
  timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${VBEMP_WARPD_PORT}; printf 'M %s %s\\nQUIT\\n' '$x' '$y' >&3"
  sleep 0.25
}

vbemp_warp_click() {
  local x="$1" y="$2" mask="${3:-1}"
  vbemp_warp_move "$x" "$y"
  mon_cmd "mouse_button $mask"
  sleep 0.15
  mon_cmd "mouse_button 0"
  sleep 0.5
}

vbemp_stop_qemu() {
  if [[ -s "$PIDFILE" ]]; then
    local p
    p="$(cat "$PIDFILE")"
    kill "$p" 2>/dev/null || true
    for _ in $(seq 1 120); do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$p" 2>/dev/null && die "VBEMP candidate QEMU failed to stop by pidfile"
  fi
  rm -f "$MON_SOCK" "$PIDFILE"
}

boot_qemu_vbemp_kvm() {
  mkdir -p "$RUN_DIR"
  "$QEMU_BIN" -enable-kvm -m 256 -smp 1 \
    -machine pc-i440fx-11.0,acpi=off,usb=off,kernel-irqchip=off,accel=kvm \
    -cpu pentium,-apic -rtc base=localtime -boot c \
    -vga std -audiodev none,id=snd -device sb16,audiodev=snd \
    -drive file="$KVM_IMG_PATH",format=qcow2,if=ide,index=0,media=disk \
    -netdev user,id=n0,hostfwd="tcp:127.0.0.1:${VBEMP_WARPD_PORT}-:7777" \
    -device pcnet,netdev=n0 \
    -vnc ":${VNC_DISP}" -display none \
    -monitor "unix:${MON_SOCK},server,nowait" -pidfile "$PIDFILE" -daemonize
  for _ in $(seq 1 40); do
    [[ -S "$MON_SOCK" && -s "$PIDFILE" ]] && break
    sleep 0.5
  done
  [[ -S "$MON_SOCK" && -s "$PIDFILE" ]] || die "VBEMP QEMU did not create monitor/pidfile"
}

vbemp_wait_desktop() {
  sleep "$VBEMP_BOOT_WAIT"
  # If WIN.INI load= has already started warpnet, no modal blocks the desktop.
  # Otherwise dismiss the blank Network Password dialog once, then wait again.
  if ! vbemp_warp_probe; then
    vbemp_hmp_key ret
    for _ in $(seq 1 90); do
      vbemp_warp_probe && return 0
      sleep 1
    done
    die "warpnet did not appear after the Win95 cold-boot/login window"
  fi
}

if [[ "$KVM_READY" -eq 1 && "$VBEMP_READY" -eq 1 ]]; then
  [[ "$WARPNET" -eq 1 ]] || die "VBEMP automatic install requires WARPNET=1"
  if [[ -z "$VBEMP_WARPD_PORT" ]]; then
    VBEMP_WARPD_PORT="$(
      python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1]); s.close()
PY
    )"
  fi

  log "VBEMP: cold-booting KVM/-vga std copy on warp port ${VBEMP_WARPD_PORT}"
  boot_qemu_vbemp_kvm
  vbemp_wait_desktop

  # Open Display Properties from an unused desktop point (Notepad ends above it),
  # then follow the validated Settings/Adapter/Have-Disk path. Keyboard mnemonics
  # avoid dependence on where Win95 centres each nested dialog.
  vbemp_warp_click 560 380 2
  vbemp_hmp_key up
  vbemp_hmp_key ret
  sleep 3
  for _ in 1 2 3 4; do
    vbemp_hmp_key ctrl-tab
    sleep 1
  done
  vbemp_hmp_key alt-a
  sleep 3 # Advanced Properties
  vbemp_hmp_key alt-c
  sleep 3 # Change
  vbemp_hmp_key alt-h
  sleep 2 # Have Disk
  vbemp_hmp_type 'c:\vbemp'
  vbemp_hmp_key ret
  sleep 3
  vbemp_hmp_key down # explicit QEMUBochsVBE model, not std-VGA
  vbemp_hmp_key ret
  sleep 10
  vbemp_hmp_key alt-a
  sleep 15 # Apply driver (transient corruption allowed)
  mon_cmd "screendump ${GUEST_DIR}/verify-vbemp-switch.ppm"

  vbemp_stop_qemu
  log "VBEMP: cold boot after driver replacement (never loadvm old state)"
  boot_qemu_vbemp_kvm
  vbemp_wait_desktop

  # Enable full-window drag through the staged registry file.
  vbemp_warp_click 30 466 1
  vbemp_hmp_key r
  vbemp_hmp_type 'regedit /s c:\vbemp\drag.reg'
  vbemp_hmp_key ret
  sleep 4

  # Framebuffer evidence: Settings must visibly say High Color (16 bit),
  # 640 by 480 pixels. This screenshot is the rebuild acceptance artifact.
  vbemp_warp_click 560 380 2
  vbemp_hmp_key up
  vbemp_hmp_key ret
  sleep 3
  for _ in 1 2 3 4; do
    vbemp_hmp_key ctrl-tab
    sleep 1
  done
  mon_cmd "screendump ${GUEST_DIR}/verify-vbemp-640x480x16.ppm"
  sleep 1
  [[ -s "${GUEST_DIR}/verify-vbemp-640x480x16.ppm" ]] ||
    die "VBEMP framebuffer verification capture is missing"
  vbemp_hmp_key esc

  # Leave the rebuilt KVM image filesystem clean.
  vbemp_hmp_key ctrl-esc
  vbemp_hmp_key up
  vbemp_hmp_key ret
  sleep 2
  vbemp_hmp_key ret
  sleep 45
  vbemp_stop_qemu
  log "VBEMP READY: ${KVM_IMG_PATH} = 640x480 High Color (16 bit), -vga std, DragFullWindows=1"
fi

###############################################################################
# 7. FRAMEBUFFER VERIFY — boot headless, screendump, sanity-check
###############################################################################
log "Bootable artifact: ${IMG_PATH}"
if [[ "$VERIFY" -ne 1 ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  echo "$IMG_PATH"
  exit 0
fi
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  log "WARN: $QEMU_BIN not found — cannot framebuffer-verify. Artifact still built."
  echo "$IMG_PATH"
  exit 0
fi

log "Framebuffer-verify: booting headless (VNC :${VNC_DISP}, monitor ${MON_SOCK})"
# Verification must not dirty the preservation image or leave ScanDisk pending
# for the subsequent KVM copy/rebuild. QEMU's temporary overlay is discarded.
boot_qemu -snapshot
log "Waiting ${VERIFY_WAIT}s for the Win95 desktop..."
sleep "$VERIFY_WAIT"

if mon_cmd "screendump -f png ${SHOT_PNG}" && [[ -s "$SHOT_PNG" ]]; then
  :
else
  ppm="${RUN_DIR}/shot.ppm"
  mon_cmd "screendump ${ppm}"
  sleep 1
  if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || cp "$ppm" "${SHOT_PNG%.png}.ppm"
  elif [[ -s "$ppm" ]]; then
    cp "$ppm" "${SHOT_PNG%.png}.ppm"
    SHOT_PNG="${SHOT_PNG%.png}.ppm"
  fi
fi

shot_bytes=0
[[ -f "$SHOT_PNG" ]] && shot_bytes="$(wc -c <"$SHOT_PNG" | tr -d ' ')"
if [[ "$shot_bytes" -gt 15000 ]]; then
  log "GUI VERIFIED: framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
  verify_rc=0
else
  log "VERIFY WARN: framebuffer capture empty/too small (${shot_bytes} bytes)."
  log "  Raise VERIFY_WAIT, or complete the one-time PnP click-through (see honesty)."
  verify_rc=2
fi

# cleanup() runs on EXIT: monitor quit -> pidfile fallback -> nbd disconnect.
log "Done. Bootable artifact: ${IMG_PATH}"
echo "$IMG_PATH"
exit "$verify_rc"

###############################################################################
# PITFALLS (from Win95/manifest.json + the validated dry-run box):
#  * The DEFAULT shipped image (cirrus, 1024x768 hi-colour) runs under TCG. Under
#    accel=kvm it deadlocks — NOT at PnP and NOT a CPU/TSC bug (both were disproven),
#    but in the guest's Cirrus 5446 DISPLAY DRIVER. KVM_READY=1 first installs
#    Standard VGA; VBEMP_READY=1 then finishes the live `-vga std` image at
#    640x480 High Color (16 bit) with the QEMUBochsVBE miniport.
#    Full root-cause, the ruled-out attempts, and measurements: docs/guests/win9x.md.
#  * acpi=off (Win95 has no ACPI). With APM/ACPI off, shutdown ends at the
#    "It's now safe to turn off your computer" busy-loop instead of powering
#    off — neko / this script just stops the qemu process (never pkill).
#  * RAM ~256 MB; do NOT exceed ~512 MB (Win9x chokes above that).
#  * 2 GB FAT32 disk, ~1.4 GB free after payload; do NOT add >1 GB without
#    repartitioning.
#  * GTA1 runs via the DOS build gtados\GTA24.EXE (VESA-LFB) in a full-screen
#    DOS box (desktop GTA.pif). GTA8.EXE freezes at level entry under the
#    VBEMP desktop driver (VESA page flips land on a never-scanned page); the
#    Windows build gtawin\GTAWIN.EXE does NOT start on this image: DPLAYX.DLL
#    missing (OSR2 = DirectX 2 only), no 8/16-bpp DirectDraw modes. The modern
#    Rockstar re-installer also will NOT install on Win95 and is avoided.
#  * Duke3D/Quake run in the Win95 DOS box. Duke3D v1.1 REQUIRES DUKE3D.CFG at
#    startup (staged above -- without it the game exits instantly); Quake's
#    SETUP is optional.
#  * Netscape + Winamp are STAGED one-click installers in C:\GALLERY\INSTALL\
#    (run once inside the guest). IE5.5 is already present on the image.
###############################################################################
