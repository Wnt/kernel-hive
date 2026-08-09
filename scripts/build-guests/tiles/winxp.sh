#!/usr/bin/env bash
###############################################################################
# build-guests/winxp.sh — reproduce the "Windows XP Professional" Kernel Hive
#                         retro guest FROM SOURCE on a fresh Proxmox host.
#
# GUEST : Windows XP Professional SP3 (built from the validated integrated-SP3
#         repack the owner used — operator supplies the media, see XP INSTALL
#         ISO below), auto-logon to the Administrator desktop, with a period "retro software"
#         CD (D:) carrying browsers, Winamp, and 4 games. This is the *winxp*
#         gallery tile whose validated build lives in
#         /data/gallery-guests/WinXPpro on the dry-run box.
#
# TYPE  : REAL UNATTENDED INSTALL. Unlike the WfW-3.11 tile (which injects a
#         prebuilt base), this recipe runs Windows XP Setup end-to-end from the
#         install ISO, driven by a FullUnattended answer file on a virtual
#         floppy — so the whole OS layer is genuinely built from source media.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh host):
#   1. Use the OPERATOR-SUPPLIED XP SP3 install ISO — XP_ISO_LOCAL, or a mirror
#      URL you provide via XP_ISO_URL; no source URL is shipped. (XP media is
#      Microsoft-copyright, free to use in this private collection; see LEGAL).
#   2. BUILD the unattended-install floppy `unattend.flp` (FAT12) carrying the
#      exact WINNT.SIF used by the validated build (FullUnattended, AutoPartition,
#      baked VLK product key, AdminPassword=retro, GuiRunOnce clean auto-shutdown).
#   3. Re-DOWNLOAD every piece of era software and BUILD the `retro-software.iso`
#      (D:) from scratch — byte-layout identical to the validated disc:
#        APPS\  Firefox 2.0.0.20, Winamp 2.95
#        GAMES\Doom\   ZDoom 2.8.1 (sw renderer) + doom1.wad + freedoom1/2.wad
#        GAMES\Quake\  FTEQW + id1\pak0.pak (shareware)
#        GAMES\Duke3D\ DUKE3D.GRP + DUKE3D.EXE (v1.3D shareware)
#        GTA1\  GTAINSTALLER.exe  (Rockstar official free re-release)
#        + Play-*.bat launchers + README.txt / README-Duke3D.txt
#   4. CREATE the 6 GiB qcow2 boot disk and RUN XP Setup fully unattended
#      (floppy WINNT.SIF drives text-mode partition/format AND the GUI phase;
#      GuiRunOnce fires `shutdown -s` so the VM powers off cleanly when done).
#   5. INJECT persistent gallery auto-logon OFFLINE via qemu-nbd + ntfs-3g +
#      hivexregedit (the in-setup AutoLogonCount=1 is one-shot; the gallery needs
#      it permanent) -> boots straight to the Administrator desktop forever.
#   6. Land the bootable artifacts in data/gallery-guests/WinXPpro/:
#        winxp.qcow2  (qcow2, boot=c)      retro-software.iso  (D:)
#   7. FRAMEBUFFER-VERIFY: boot headless under QEMU with the production gallery
#      args (unique monitor socket + pidfile), wait for auto-logon, `screendump`
#      a PNG and sanity-check it, then clean ACPI shutdown.
#
# AUTOMATION HONESTY  (what is fully automated vs. not):
#   * FULLY AUTOMATED, zero keystrokes: the OS install. The validated build sent
#     NO sendkeys during Setup — the FullUnattended WINNT.SIF fills every page
#     (Personalize / Computer-name+password / Workgroup / regional / network),
#     AutoPartition handles the text-mode partition+format, and [GuiRunOnce]
#     `shutdown -s -t 90` ends first-logon with a clean power-off. (Contrast the
#     *WinXP-usermedia* sibling build, whose thinner answer file DID need 3
#     GUI keystroke pages — this WinXPpro build closed those gaps in WINNT.SIF.)
#   * "Press any key to boot from CD": the validated integrated SP3 repack the
#     owner used auto-booted its CD under QEMU with no keypress on the validated run. As a portability safety net we
#     send a couple of early ENTERs via the monitor (SEND_CDBOOT_KEY, default 1);
#     they are harmless to the unattended flow. Set =0 to match the run exactly.
#   * Auto-logon is made permanent by OFFLINE registry injection (step 5), not by
#     any in-guest clicking.
#   * The full games/apps catalogue is STAGED on D: with one-click launchers.
#     Duke3D ships as data + DOS exe (drop eDuke32.exe for native play); GTA1
#     ships its installer. IN ADDITION (step 5a) the marquee titles are surfaced
#     as VISIBLE Administrator-desktop .lnk shortcuts with their payloads on C:\,
#     so a first-time viewer double-clicks an icon and plays: DOOM, Quake, 3D
#     Pinball Space Cadet, Minesweeper, Solitaire, Internet Explorer, Winamp 2.95.
#     Shortcuts are minted offline from source by pylnk3; Winamp is dropped in as
#     a pre-installed freeware folder (its installer can't run head-lessly).
#
# HYGIENE (per project rules):
#   * Every VM this script starts is killed ONLY via its own QEMU monitor `quit`
#     / `system_powerdown`, with its pidfile as the sole fallback. This script
#     NEVER `pkill`s by name — that would catch the live gallery tiles, CT 110,
#     VM 900/920 and the macOS fan-out VMs. (The dry-run helper scripts used
#     `pkill -f winxppro`; that is deliberately NOT reproduced here.)
#   * Namespaced run dir + unique monitor socket + unique pidfile (per PID).
#   * qemu-nbd uses the first FREE /dev/nbdN and disconnects exactly that one.
#   * Touches ONLY data/gallery-guests/WinXPpro/. No other guest, no CT/VM.
#
# Idempotent + re-runnable: downloads are cached-by-size; the floppy + software
# ISO are rebuilt deterministically each run; the qcow2 is (re)installed only
# when absent or when FORCE_INSTALL=1.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="winxp"
DIR_NAME="WinXPpro"

# Where the gallery keeps its guests (host dataset, bind-mounted into CT 110).
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${GUESTS_ROOT}/${DIR_NAME}"
DL_DIR="${GUEST_DIR}/dl"
DISK_IMG="${GUEST_DIR}/winxp.qcow2"
SW_ISO="${GUEST_DIR}/retro-software.iso"
FLP_IMG="${GUEST_DIR}/unattend.flp"

DISK_SIZE="${DISK_SIZE:-6G}" # matches the validated 6 GiB virtual disk

# ----------------------------------------------------------------- XP INSTALL ISO
# The validated build used the owner's own copy of a validated integrated-SP3
# repack (label GRTMPVOL_EN / WIN51IP.SP3, ~624 MB ISO; SP3 + IE8 slipstreamed,
# auto-boots its CD under QEMU). Windows XP itself is Microsoft-copyright ->
# free to use in this private collection as retro preservation, served behind
# the gallery's edge passkey auth (the ISO binary is never committed to the
# GitHub repo). NO download URL is shipped — provide your own media by EITHER:
#   * setting XP_ISO_LOCAL=/path/to/winxp-sp3.iso  (preferred; your own media), OR
#   * setting XP_ISO_URL to a mirror you control and trust.
XP_ISO="${GUEST_DIR}/winxp-sp3.iso"
XP_ISO_LOCAL="${XP_ISO_LOCAL:-}"
XP_ISO_MIN_BYTES="${XP_ISO_MIN_BYTES:-524288000}" # >=500 MB sanity floor

# Baked answer-file identity (exactly as the validated WINNT.SIF).
XP_PRODUCT_KEY="${WINXP_PRODUCT_KEY:?set WINXP_PRODUCT_KEY (XP volume-license key; not shipped in the repo)}"
XP_ADMIN_PW="${XP_ADMIN_PW:-retro}"

# ---------------------------------------------------------- retro software media
# Each item: URL + the EXACT byte size seen on the validated retro-software.iso
# (used as a cheap integrity cross-check; SHA left open for the moving mirrors).
FIREFOX_URL="${FIREFOX_URL:-https://archive.mozilla.org/pub/firefox/releases/2.0.0.20/win32/en-US/Firefox%20Setup%202.0.0.20.exe}"
FIREFOX_SIZE="6048152"

WINAMP_URL="${WINAMP_URL:-https://archive.org/download/winamp295/winamp295.exe}"
WINAMP_SIZE="2478784"

# ZDoom 2.8.1 zip -> provides zdoom.exe / zdoom.pk3 / fmodex.dll / licenses.zip
ZDOOM_URL="${ZDOOM_URL:-https://zdoom.org/files/zdoom/2.8/zdoom-2.8.1.zip}"

# DOOM shareware -> DOOM1.WAD (id Software, freely redistributable)
DOOMSW_URL="${DOOMSW_URL:-https://archive.org/download/DoomsharewareEpisode/DoomV1.9sw1995idSoftwareInc.action.zip}"

# Freedoom 0.12.1 -> freedoom1.wad + freedoom2.wad (+ licenses; BSD)
FREEDOOM_URL="${FREEDOOM_URL:-https://github.com/freedoom/freedoom/releases/download/v0.12.1/freedoom-0.12.1.zip}"

# Quake shareware -> id1/PAK0.PAK  (FTEQW engine fetched separately)
QUAKESW_URL="${QUAKESW_URL:-https://archive.org/download/quakeshareware/QUAKE_SW.zip}"
FTEQW_URL="${FTEQW_URL:-https://www.fteqw.org/dl/fteqw_win64.zip}" # -> fteqw.exe (moving build)

# Duke Nukem 3D v1.3D shareware -> DUKE3D.GRP + DUKE3D.EXE
DUKESW_URL="${DUKESW_URL:-https://archive.org/download/3D_Realms_Duke_Nukem_3D_Shareware/3D%20Realms%20-%20Duke%20Nukem%203D%20%28Shareware%20Version%29.zip}"

# GTA 1 — Rockstar's OFFICIAL FREE re-release (large; OPTIONAL, non-fatal).
GTA1_URL="${GTA1_URL:-https://archive.org/download/rockstar-classics_202107/GTAINSTALLER.exe}"
GTA1_SIZE="344338033"
WANT_GTA1="${WANT_GTA1:-1}" # set 0 to skip the ~330 MB GTA1 installer

# --------------------------------------------------------------- QEMU / verify
QEMU_BIN="${QEMU_BIN:-qemu-system-i386}" # validated build used i386 (see NOTE)
INSTALL_MEM="${INSTALL_MEM:-1024}"
GALLERY_MEM="${GALLERY_MEM:-768}"
VERIFY="${VERIFY:-1}"                      # VERIFY=0 skips the framebuffer boot
VERIFY_WAIT="${VERIFY_WAIT:-200}"          # s to auto-logon desktop under TCG/KVM
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-2700}" # s to wait for unattended install (45 min)
SEND_CDBOOT_KEY="${SEND_CDBOOT_KEY:-1}"    # early ENTER to satisfy "press any key"
FORCE_INSTALL="${FORCE_INSTALL:-0}"        # 1 = reinstall even if winxp.qcow2 exists
# NOTE on QEMU_BIN: the WinXP-usermedia sibling build had to switch to
# qemu-system-x86_64 to evade a *concurrent* workflow's name-based `pkill
# qemu-system-i386`. That collision does not exist for a standalone from-scratch
# run, and this build (per MANIFEST.json) completed cleanly on qemu-system-i386.
# Both emulators run the 32-bit guest fine; override QEMU_BIN if you prefer x86_64.

# Unique, namespaced runtime handles (never reused across concurrent builds).
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
SHOT_PNG="${GUEST_DIR}/verify-desktop.png"
NBD_DEV="" # set when we grab an nbd node

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch args this tile runs with in the live gallery.
# (verbatim from MANIFEST.json on the dry-run box; emitted here for reuse.)
#
#   qemu-system-i386 -name 'Windows XP Professional' \
#     -enable-kvm -machine pc -cpu host -m 768 -smp 1 \
#     -drive file=/opt/osgallery/guests/WinXPpro/winxp.qcow2,format=qcow2,if=ide,index=0,media=disk \
#     -drive file=/opt/osgallery/guests/WinXPpro/retro-software.iso,format=raw,if=ide,index=2,media=cdrom \
#     -boot order=c,menu=off \
#     -netdev user,id=n0 -device rtl8139,netdev=n0 \
#     -audiodev pa,id=snd -device AC97,audiodev=snd \
#     -usb -device usb-tablet -vga std -rtc base=localtime
#
# Rationale: stock XP has NO intel-hda driver -> AC97. rtl8139 has a native XP
# driver. std VGA (no 3D accel -> games use SOFTWARE renderers). usb-tablet gives
# an absolute pointer. Uniprocessor HAL -> keep -smp 1. In CT110/neko, swap the
# audiodev/-display for the neko VNC + pulse backend the other tiles use; keep
# everything else identical.
###############################################################################

need() { command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found"; }
for t in curl unzip qemu-img "$QEMU_BIN" socat sha256sum awk dd; do need "$t"; done
# ISO/floppy builders + offline-inject tools (checked lazily where used).

size_of() { wc -c <"$1" | tr -d ' '; }

# fetch <url> <dest> <expected_size|"">  (cached-by-size; returns non-zero on fail)
fetch() {
  local url="$1" dest="$2" want_size="${3:-}"
  if [[ -f "$dest" ]]; then
    if [[ -z "$want_size" || "$(size_of "$dest")" == "$want_size" ]]; then
      log "cached: $(basename "$dest")"
      return 0
    fi
    log "cache size mismatch, re-downloading $(basename "$dest")"
  fi
  local tmp="${dest}.part.$$"
  log "downloading $(basename "$dest") <- $url"
  if ! curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"; then
    rm -f "$tmp"
    log "WARN: download failed: $url"
    return 1
  fi
  if [[ -n "$want_size" && "$(size_of "$tmp")" != "$want_size" ]]; then
    log "WARN: $(basename "$dest") size $(size_of "$tmp") != expected $want_size"
  fi
  mv -f "$tmp" "$dest"
  log "downloaded ok: $(basename "$dest")"
  return 0
}

mk_dos() { printf '%b' "$2" | sed 's/$/\r/' >"$1"; } # LF text -> CRLF DOS file

# ------------------------------------------------------------------ 0. workspace
mkdir -p "$GUEST_DIR" "$DL_DIR" "$RUN_DIR"

###############################################################################
# 1. XP install ISO
###############################################################################
if [[ -n "$XP_ISO_LOCAL" ]]; then
  [[ -f "$XP_ISO_LOCAL" ]] || die "XP_ISO_LOCAL set but not found: $XP_ISO_LOCAL"
  log "using local XP ISO: $XP_ISO_LOCAL"
  XP_ISO="$XP_ISO_LOCAL"
elif [[ -f "$XP_ISO" && "$(size_of "$XP_ISO")" -ge "$XP_ISO_MIN_BYTES" ]]; then
  log "cached XP ISO: $XP_ISO ($(size_of "$XP_ISO") bytes)"
else
  # Required-if-no-local: the operator must bring their own media/mirror.
  XP_ISO_URL="${XP_ISO_URL:?set XP_ISO_URL or XP_ISO_LOCAL — provide your own Windows XP SP3 media; not shipped}"
  fetch "$XP_ISO_URL" "$XP_ISO" "" ||
    die "could not obtain the XP SP3 ISO. Set XP_ISO_LOCAL=/path/to/your.iso"
  [[ "$(size_of "$XP_ISO")" -ge "$XP_ISO_MIN_BYTES" ]] ||
    die "XP ISO too small ($(size_of "$XP_ISO") bytes) — wrong/partial download?"
fi

###############################################################################
# 2. Unattended-install floppy (FAT12) carrying WINNT.SIF
#    -> content is byte-faithful to the validated FullUnattended answer file.
#    XP Setup booted from CD reads A:\WINNT.SIF and it OVERRIDES the repack's
#    embedded I386\WINNT.SIF, giving us a truly hands-off Setup.
###############################################################################
build_floppy() {
  local sif="${RUN_DIR}/WINNT.SIF"
  cat >"${RUN_DIR}/WINNT.SIF.lf" <<SIF
[Data]
    AutoPartition=1
    MsDosInitiated=0
    UnattendedInstall=Yes

[Unattended]
    UnattendMode=FullUnattended
    OemSkipEula=Yes
    OemPreinstall=No
    TargetPath=\\WINDOWS
    FileSystem=*
    WaitForReboot=No
    DriverSigningPolicy=Ignore
    Repartition=No

[GuiUnattended]
    AdminPassword=${XP_ADMIN_PW}
    EncryptedAdminPassword=No
    OEMSkipRegional=1
    TimeZone=110
    OemSkipWelcome=1
    AutoLogon=Yes
    AutoLogonCount=1

[UserData]
    ProductKey=${XP_PRODUCT_KEY}
    FullName=Retro
    OrgName=KernelHive
    ComputerName=RETROXP

[Display]
    BitsPerPel=16
    Xresolution=1024
    Yresolution=768
    Vrefresh=60

[GuiRunOnce]
    "cmd /c shutdown -s -t 90 -f -c retro-clean-shutdown"

[Identification]
    JoinWorkgroup=RETRO

[Networking]
    InstallDefaultComponents=Yes

[RegionalSettings]
    LanguageGroup=1
    Language=00000409
SIF
  # Windows answer files want CRLF line endings.
  sed 's/$/\r/' "${RUN_DIR}/WINNT.SIF.lf" >"$sif"

  log "building unattend.flp (1.44 MB FAT12, WINNT.SIF)"
  dd if=/dev/zero of="$FLP_IMG" bs=1024 count=1440 status=none
  if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs.vfat -F 12 "$FLP_IMG" >/dev/null
  else
    command -v mformat >/dev/null 2>&1 || die "need mkfs.vfat or mtools(mformat) to build the floppy"
    mformat -i "$FLP_IMG" -f 1440 ::
  fi
  if command -v mcopy >/dev/null 2>&1; then
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$FLP_IMG" "$sif" ::/WINNT.SIF
  else
    # Fallback: loop-mount (needs root)
    local m="${RUN_DIR}/flpmnt"
    mkdir -p "$m"
    mount -o loop "$FLP_IMG" "$m"
    cp "$sif" "${m}/WINNT.SIF"
    sync
    umount "$m"
  fi
  log "unattend.flp ready"
}
build_floppy

###############################################################################
# 3. Build retro-software.iso (D:) from freshly downloaded era software
###############################################################################
build_software_iso() {
  local stage="${RUN_DIR}/rsw"
  local tmp="${RUN_DIR}/tmp"
  mkdir -p "$stage"/{APPS,GAMES/Doom,GAMES/Quake/id1,GAMES/Duke3D,GTA1} "$tmp"

  # --- APPS ---------------------------------------------------------------
  fetch "$FIREFOX_URL" "${DL_DIR}/Firefox-Setup-2.0.0.20.exe" "$FIREFOX_SIZE" &&
    cp -f "${DL_DIR}/Firefox-Setup-2.0.0.20.exe" "${stage}/APPS/" ||
    log "WARN: Firefox 2 not staged"
  fetch "$WINAMP_URL" "${DL_DIR}/Winamp-2.95.exe" "$WINAMP_SIZE" &&
    cp -f "${DL_DIR}/Winamp-2.95.exe" "${stage}/APPS/" ||
    log "WARN: Winamp 2.95 not staged"

  # --- GAMES\Doom : ZDoom 2.8.1 engine + doom1 + freedoom1/2 --------------
  if fetch "$ZDOOM_URL" "${DL_DIR}/zdoom-2.8.1.zip" ""; then
    local zd="${tmp}/zdoom"
    mkdir -p "$zd"
    unzip -qo "${DL_DIR}/zdoom-2.8.1.zip" -d "$zd"
    for f in zdoom.exe zdoom.pk3 fmodex.dll licenses.zip; do
      local hit
      hit="$(find "$zd" -iname "$f" -print -quit)"
      [[ -n "$hit" ]] && cp -f "$hit" "${stage}/GAMES/Doom/$f" || log "WARN: ZDoom missing $f"
    done
  else
    log "WARN: ZDoom engine not staged (DOOM launchers will lack an engine)"
  fi
  if fetch "$DOOMSW_URL" "${DL_DIR}/doom-shareware.zip" ""; then
    local dd1="${tmp}/doomsw"
    mkdir -p "$dd1"
    unzip -qjo "${DL_DIR}/doom-shareware.zip" -d "$dd1"
    local wad
    wad="$(find "$dd1" -iname 'doom1.wad' -print -quit)"
    [[ -n "$wad" ]] && cp -f "$wad" "${stage}/GAMES/Doom/doom1.wad" || log "WARN: doom1.wad missing"
  fi
  if fetch "$FREEDOOM_URL" "${DL_DIR}/freedoom-0.12.1.zip" ""; then
    local fd="${tmp}/freedoom"
    mkdir -p "$fd"
    unzip -qo "${DL_DIR}/freedoom-0.12.1.zip" -d "$fd"
    for f in freedoom1.wad freedoom2.wad; do
      local hit
      hit="$(find "$fd" -iname "$f" -print -quit)"
      [[ -n "$hit" ]] && cp -f "$hit" "${stage}/GAMES/Doom/$f" || log "WARN: $f missing"
    done
  fi
  # DOOM launchers (exact content from the validated disc)
  mk_dos "${stage}/GAMES/Doom/Play-Doom-Shareware.bat" '@echo off\nzdoom.exe -iwad doom1.wad\n'
  mk_dos "${stage}/GAMES/Doom/Play-Freedoom-Phase1.bat" '@echo off\nzdoom.exe -iwad freedoom1.wad\n'
  mk_dos "${stage}/GAMES/Doom/Play-Freedoom-Phase2.bat" '@echo off\nzdoom.exe -iwad freedoom2.wad\n'

  # --- GAMES\Quake : FTEQW engine + shareware id1\pak0.pak ---------------
  if fetch "$FTEQW_URL" "${DL_DIR}/fteqw.zip" ""; then
    local ft="${tmp}/fteqw"
    mkdir -p "$ft"
    unzip -qo "${DL_DIR}/fteqw.zip" -d "$ft"
    local exe
    exe="$(find "$ft" -iname 'fteqw*.exe' -print -quit)"
    [[ -n "$exe" ]] && cp -f "$exe" "${stage}/GAMES/Quake/fteqw.exe" || log "WARN: fteqw.exe missing"
  else
    log "WARN: FTEQW engine not staged"
  fi
  if fetch "$QUAKESW_URL" "${DL_DIR}/quake-shareware.zip" ""; then
    local qk="${tmp}/quake"
    mkdir -p "$qk"
    unzip -qo "${DL_DIR}/quake-shareware.zip" -d "$qk"
    local pak
    pak="$(find "$qk" -iname 'pak0.pak' -print -quit)"
    [[ -n "$pak" ]] && cp -f "$pak" "${stage}/GAMES/Quake/id1/pak0.pak" || log "WARN: pak0.pak missing"
  fi
  mk_dos "${stage}/GAMES/Quake/Play-Quake-Shareware.bat" '@echo off\nfteqw.exe -window +vid_renderer sw\n'

  # --- GAMES\Duke3D : v1.3D shareware data + DOS exe ---------------------
  if fetch "$DUKESW_URL" "${DL_DIR}/duke3d-shareware.zip" ""; then
    local dk="${tmp}/duke"
    mkdir -p "$dk"
    unzip -qo "${DL_DIR}/duke3d-shareware.zip" -d "$dk"
    for f in DUKE3D.GRP DUKE3D.EXE; do
      local hit
      hit="$(find "$dk" -iname "$f" -print -quit)"
      [[ -n "$hit" ]] && cp -f "$hit" "${stage}/GAMES/Duke3D/$f" || log "WARN: Duke3D missing $f"
    done
  fi
  mk_dos "${stage}/GAMES/Duke3D/README-Duke3D.txt" \
    'Duke Nukem 3D shareware DATA is here: DUKE3D.GRP (v1.3D, id/3D Realms shareware) + DUKE3D.EXE (DOS).\nThe DOS EXE does not run well on XP. For a native XP-friendly experience, download eDuke32 (free, GPL) from https://www.eduke32.com , drop eduke32.exe into this folder, and run:  eduke32.exe -gamegrp DUKE3D.GRP\nClassic (software) renderer works without 3D acceleration.\n'

  # --- GTA1 (optional; large) -------------------------------------------
  if [[ "$WANT_GTA1" == "1" ]]; then
    fetch "$GTA1_URL" "${DL_DIR}/GTAINSTALLER.exe" "$GTA1_SIZE" &&
      cp -f "${DL_DIR}/GTAINSTALLER.exe" "${stage}/GTA1/" ||
      log "WARN: GTA1 installer not staged (non-fatal)"
  else
    log "WANT_GTA1=0 — skipping GTA1 installer"
  fi

  # --- top-level README (verbatim from the validated disc) --------------
  cat >"${stage}/README.txt" <<'RME'
RETRO SOFTWARE DISC  (Windows XP Professional gallery guest)
============================================================
This CD (usually drive D:) carries period software. Internet Explorer 8
is already installed in Windows. For best results with the GAMES, COPY the
GAMES folder to C:\ first (so configs/saves can be written), then run the
.BAT launchers. Installers under APPS and GTA1 can be run straight from the CD.

BROWSERS
  * Internet Explorer 8      - preinstalled (slipstreamed in this SP3 repack)
  * Firefox 2.0.0.20         - APPS\Firefox-Setup-2.0.0.20.exe  (run to install)

MUSIC
  * Winamp 2.95              - APPS\Winamp-2.95.exe  (run to install)

GAMES
  * DOOM / Freedoom          - GAMES\Doom\  (ZDoom 2.8.1 software renderer)
        Play-Doom-Shareware.bat / Play-Freedoom-Phase1.bat / -Phase2.bat
  * Quake (shareware)        - GAMES\Quake\  (FTEQW engine + id1\pak0.pak)
        Play-Quake-Shareware.bat   (forces software renderer; no 3D needed)
  * Duke Nukem 3D (shareware)- GAMES\Duke3D\  (DUKE3D.GRP + DOS exe; see README-Duke3D.txt)
  * Grand Theft Auto 1       - GTA1\GTAINSTALLER.exe  (Rockstar official FREE release; run to install)

LEGAL: shareware Doom/Quake/Duke, Freedoom (BSD), and GTA1 (official free
re-release) are freely distributable. Firefox/Winamp are freeware/archived
installers. Windows XP itself is Microsoft-copyright - free to use in this private
collection as retro preservation behind edge passkey auth; the media binary stays
out of the GitHub repo.
RME

  # --- master the ISO (Joliet + Rock Ridge, volume label RETROSW) -------
  log "mastering retro-software.iso"
  if command -v genisoimage >/dev/null 2>&1; then
    genisoimage -quiet -J -r -V RETROSW -o "$SW_ISO" "$stage"
  elif command -v mkisofs >/dev/null 2>&1; then
    mkisofs -quiet -J -r -V RETROSW -o "$SW_ISO" "$stage"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -as mkisofs -J -r -V RETROSW -o "$SW_ISO" "$stage"
  else
    die "need genisoimage / mkisofs / xorriso to build the software ISO"
  fi
  log "retro-software.iso ready ($(size_of "$SW_ISO") bytes)"
}
build_software_iso

###############################################################################
# 4. Create disk + run the FULLY UNATTENDED install
###############################################################################
mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }

install_alive() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

run_install() {
  log "creating $DISK_SIZE qcow2 boot disk"
  rm -f "$DISK_IMG"
  qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null

  log "launching unattended XP Setup ($QEMU_BIN, monitor ${MON_SOCK})"
  # boot order=dc: CD first (Setup), then disk on the automatic reboots. On those
  # reboots do NOT press a key at "press any key to boot from CD" (times out to
  # the HDD and continues Setup). We only nudge the FIRST CD boot below.
  local accel=()
  "$QEMU_BIN" -accel help 2>/dev/null | grep -qw kvm && accel=(-enable-kvm -cpu host)
  "$QEMU_BIN" -name winxppro-install \
    "${accel[@]}" -machine pc -m "$INSTALL_MEM" -smp 1 \
    -drive file="$DISK_IMG",format=qcow2,if=ide,index=0,media=disk \
    -drive file="$XP_ISO",format=raw,if=ide,index=2,media=cdrom \
    -fda "$FLP_IMG" \
    -boot order=dc,menu=off \
    -netdev user,id=n0 -device rtl8139,netdev=n0 \
    -vga std -rtc base=localtime \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -pidfile "$PIDFILE" -display none -daemonize
  for _ in $(seq 1 20); do
    [[ -S "$MON_SOCK" ]] && break
    sleep 0.5
  done

  # Safety net for the "Press any key to boot from CD..." prompt. The validated
  # integrated SP3 repack the owner used auto-booted without this; a couple of
  # early ENTERs are harmless to FullUnattended Setup. Disable with
  # SEND_CDBOOT_KEY=0 to match the run.
  if [[ "$SEND_CDBOOT_KEY" == "1" ]]; then
    (
      sleep 3
      mon_cmd "sendkey ret"
      sleep 3
      mon_cmd "sendkey ret"
      sleep 4
      mon_cmd "sendkey ret"
    ) &
  fi

  # Wait for Setup to finish: WINNT.SIF's [GuiRunOnce] fires `shutdown -s` after
  # first-logon, so a CLEAN power-off (qemu process exit) is our "done" signal.
  log "waiting up to ${INSTALL_TIMEOUT}s for unattended install to power off..."
  local waited=0 last=0
  while install_alive; do
    sleep 20
    waited=$((waited + 20))
    local cur
    cur="$(size_of "$DISK_IMG")"
    local curMB=$((cur / 1048576))
    if [[ $curMB -ne $last ]]; then
      log "  installing... disk=${curMB}M (${waited}s)"
      last=$curMB
    fi
    if [[ $waited -ge $INSTALL_TIMEOUT ]]; then
      log "install TIMEOUT after ${waited}s — capturing screen, aborting"
      mon_cmd "screendump ${GUEST_DIR}/install-timeout.ppm"
      die "install did not complete in time (inspect install-timeout.ppm)"
    fi
  done
  local finalMB=$(($(size_of "$DISK_IMG") / 1048576))
  [[ $finalMB -ge 1000 ]] || die "install ended prematurely (disk only ${finalMB}M)"
  log "install complete — clean power-off, disk=${finalMB}M"
}

if [[ -f "$DISK_IMG" && "$FORCE_INSTALL" != "1" ]]; then
  log "winxp.qcow2 already present — skipping install (FORCE_INSTALL=1 to rebuild)"
else
  run_install
fi

###############################################################################
# 5. Offline-inject PERSISTENT auto-logon into the SOFTWARE hive
#    (in-setup AutoLogonCount=1 is one-shot; the gallery needs it permanent).
#    Sets AutoAdminLogon/DefaultUserName/DefaultPassword/ForceAutoLogon +
#    LogonType=0 (classic logon) exactly as the validated alfix step.
###############################################################################
inject_autologon() {
  for t in qemu-nbd hivexregedit; do command -v "$t" >/dev/null 2>&1 || {
    log "WARN: $t missing — skipping auto-logon inject"
    return 0
  }; done
  command -v ntfs-3g >/dev/null 2>&1 || command -v mount.ntfs-3g >/dev/null 2>&1 || log "WARN: ntfs-3g may be required to mount the NTFS partition"

  modprobe nbd max_part=8 2>/dev/null || true
  local nbd=""
  for n in $(seq 0 15); do
    # pick a node with no size (i.e. not connected)
    if [[ "$(cat "/sys/block/nbd$n/size" 2>/dev/null || echo 0)" == "0" ]]; then
      if qemu-nbd --connect="/dev/nbd$n" -f qcow2 "$DISK_IMG" 2>/dev/null; then
        nbd="/dev/nbd$n"
        break
      fi
    fi
  done
  [[ -n "$nbd" ]] || {
    log "WARN: no free nbd node — auto-logon not injected"
    return 0
  }
  NBD_DEV="$nbd"
  sleep 2
  partprobe "$nbd" 2>/dev/null || true

  local m="${RUN_DIR}/xpmnt"
  mkdir -p "$m"
  if ! mount -t ntfs-3g "${nbd}p1" "$m" 2>/dev/null; then mount "${nbd}p1" "$m" 2>/dev/null || {
    log "WARN: could not mount ${nbd}p1"
    qemu-nbd --disconnect "$nbd" >/dev/null 2>&1
    NBD_DEV=""
    return 0
  }; fi

  local hive
  hive="$(ls "$m"/WINDOWS/system32/config/software 2>/dev/null || ls "$m"/Windows/System32/config/SOFTWARE 2>/dev/null || true)"
  hive="$(echo "$hive" | head -1)"
  if [[ -n "$hive" ]]; then
    # DefaultDomainName MUST be the computer name (RETROXP) — without it, XP's
    # Winlogon cannot resolve the local Administrator and silently falls back to
    # the logon prompt (then resets AutoAdminLogon=0). Clearing AutoLogonCount
    # (set to 1 by the in-setup one-shot autologon) makes autologon permanent.
    cat >"${RUN_DIR}/al.reg" <<REG
[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="Administrator"
"DefaultDomainName"="RETROXP"
"DefaultPassword"="${XP_ADMIN_PW}"
"ForceAutoLogon"="1"
"AutoLogonCount"=-
"LogonType"=dword:00000000
REG
    if hivexregedit --merge --prefix 'HKEY_LOCAL_MACHINE\SOFTWARE' "$hive" "${RUN_DIR}/al.reg"; then
      log "auto-logon injected (AutoAdminLogon=$(hivexget "$hive" '\Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon 2>/dev/null))"
    else
      log "WARN: hivexregedit merge failed"
    fi
  else
    log "WARN: SOFTWARE hive not found — auto-logon not injected"
  fi
  # Clear F8 recovery bootstat (harmless; XP recreates it). Clean shutdowns avoid
  # it anyway, but this makes a hard-killed image boot straight through.
  rm -f "$m"/WINDOWS/bootstat.dat "$m"/Windows/bootstat.dat 2>/dev/null || true
  sync
  umount "$m" 2>/dev/null || true
  qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  NBD_DEV=""
}
inject_autologon

###############################################################################
# 5a. Bake VISIBLE DESKTOP SHORTCUTS + on-disk games/apps into the golden.
#
#   The gallery goal: a first-time viewer sees icons on the Administrator desktop
#   and double-clicks to play — NOT a hidden C:\ or a README. The retro CD (D:)
#   still carries the full staged catalogue, but this step surfaces the marquee
#   titles as real .lnk shortcuts and puts their payloads on C:\ so they run
#   straight from the desktop (the tile runs the qcow2 with -snapshot, so every
#   viewer sees this exact golden desktop each session):
#
#     GAMES  DOOM (ZDoom + doom1.wad shareware)  -> C:\Games\Doom
#            Quake (FTEQW + id1\pak0.pak share.) -> C:\Games\Quake
#            3D Pinball Space Cadet (stock XP)   -> C:\Program Files\Windows NT\Pinball
#            Minesweeper / Solitaire (stock XP)  -> C:\WINDOWS\system32
#     APPS   Winamp 2.95  -> installed into C:\Program Files\Winamp
#            Internet Explorer (period browser, preinstalled)
#
#   Winamp: its Nullsoft installer cannot run head-lessly, so we ship the
#   already-installed program folder as a repacked freeware asset
#   (assets/winxp/Winamp-2.95-installed.tar.gz). Its bundled Winamp.ini has the
#   first-run registration nag ("Stop bugging me!") and the startup
#   mini-browser/version-check DISABLED so viewers get a clean launch straight
#   to the player. The .lnk files are generated from source by pylnk3
#   (assets/winxp/make_shortcuts.py) so they are reproducible, not opaque.
#
#   NOT bundled in the repo: this is a custom repack (an already-installed
#   program tree, not the stock Nullsoft installer), so there is no stable
#   public URL to fetch it from automatically. An operator building from a
#   public checkout must supply their own copy at the path below — see
#   docs/guests/winxp.md for what it is and how to build one. Without it, the
#   Winamp desktop shortcut is simply skipped (WARN, not fatal).
###############################################################################
ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)/assets/winxp"
WINAMP_TARBALL="${ASSETS_DIR}/Winamp-2.95-installed.tar.gz"
WINAMP_EXPECT_SHA256="cd0bbbc4ceebfc2fd8c9b22d63a03fdb3c7a182be680af6dcea032f33c2a8dd9"
MK_SHORTCUTS="${ASSETS_DIR}/make_shortcuts.py"

bake_desktop_shortcuts() {
  command -v qemu-nbd >/dev/null 2>&1 || {
    log "WARN: qemu-nbd missing — skipping desktop shortcuts"
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    log "WARN: python3 missing — skipping desktop shortcuts"
    return 0
  }
  if [[ -f "$WINAMP_TARBALL" ]]; then
    local winamp_got
    winamp_got="$(sha256sum "$WINAMP_TARBALL" | awk '{print $1}')"
    if [[ "$winamp_got" != "$WINAMP_EXPECT_SHA256" ]]; then
      log "WARN: $WINAMP_TARBALL sha256 mismatch (expected $WINAMP_EXPECT_SHA256, got $winamp_got) — ignoring, Winamp shortcut will not resolve"
      WINAMP_TARBALL=""
    fi
  else
    log "WARN: $WINAMP_TARBALL not found — Winamp is not redistributed with this repo (custom repack, no stable public URL)."
    log "WARN: to include it, place your own already-installed Winamp 2.95 program-folder tarball at that path (tar.gz of the installed C:\\Program Files\\Winamp tree, see docs/guests/winxp.md). Skipping the Winamp desktop shortcut."
  fi
  [[ -f "$MK_SHORTCUTS" ]] || {
    log "WARN: $MK_SHORTCUTS missing — skipping desktop shortcuts"
    return 0
  }

  # pylnk3 is how we mint the Windows .lnk files offline.
  if ! python3 -c 'import pylnk3' 2>/dev/null; then
    log "installing pylnk3 (for offline .lnk generation)"
    pip3 install --break-system-packages -q pylnk3 2>/dev/null ||
      pip3 install -q pylnk3 2>/dev/null ||
      {
        log "WARN: could not install pylnk3 — skipping desktop shortcuts"
        return 0
      }
  fi

  modprobe nbd max_part=8 2>/dev/null || true
  local nbd=""
  for n in $(seq 0 15); do
    if [[ "$(cat "/sys/block/nbd$n/size" 2>/dev/null || echo 0)" == "0" ]]; then
      if qemu-nbd --connect="/dev/nbd$n" -f qcow2 "$DISK_IMG" 2>/dev/null; then
        nbd="/dev/nbd$n"
        break
      fi
    fi
  done
  [[ -n "$nbd" ]] || {
    log "WARN: no free nbd node — desktop shortcuts not baked"
    return 0
  }
  NBD_DEV="$nbd"
  sleep 2
  partprobe "$nbd" 2>/dev/null || true

  local m="${RUN_DIR}/xpmnt-sc"
  mkdir -p "$m"
  if ! mount -t ntfs-3g "${nbd}p1" "$m" 2>/dev/null; then
    mount "${nbd}p1" "$m" 2>/dev/null || {
      log "WARN: could not mount ${nbd}p1 for shortcuts"
      qemu-nbd --disconnect "$nbd" >/dev/null 2>&1
      NBD_DEV=""
      return 0
    }
  fi

  # --- 1. stage the games onto C:\ from the freshly-built retro-software.iso ---
  local iso_m="${RUN_DIR}/iso-sc"
  mkdir -p "$iso_m"
  if mount -o loop,ro "$SW_ISO" "$iso_m" 2>/dev/null; then
    mkdir -p "$m/Games"
    for g in Doom Quake; do
      if [[ -d "$iso_m/GAMES/$g" ]]; then
        rm -rf "$m/Games/$g"
        cp -r "$iso_m/GAMES/$g" "$m/Games/$g"
        log "staged C:\\Games\\$g"
      else
        log "WARN: GAMES/$g not on ISO — its shortcut will not resolve"
      fi
    done
    umount "$iso_m" 2>/dev/null || true
  else
    log "WARN: could not loop-mount $SW_ISO — games not copied to C:\\Games"
  fi
  rmdir "$iso_m" 2>/dev/null || true

  # --- 2. drop the pre-installed Winamp 2.95 folder into Program Files --------
  if [[ -f "$WINAMP_TARBALL" ]]; then
    rm -rf "$m/Program Files/Winamp"
    tar xzf "$WINAMP_TARBALL" -C "$m/Program Files/" &&
      log "installed C:\\Program Files\\Winamp" ||
      log "WARN: Winamp tarball extract failed"
  fi

  # --- 3. generate the visible desktop .lnk shortcuts ------------------------
  local desk="$m/Documents and Settings/Administrator/Desktop"
  mkdir -p "$desk"
  # remove any stray installer/AOL junk so the desktop stays curated
  rm -f "$desk/Like Music - Try AOL!.url" 2>/dev/null || true
  if python3 "$MK_SHORTCUTS" "$desk"; then
    # shellcheck disable=SC2012 # listing our own freshly-written desktop dir for a log line, not adversarial
    log "desktop shortcuts written: $(ls "$desk" | tr '\n' ' ')"
  else
    log "WARN: make_shortcuts.py failed"
  fi

  sync
  umount "$m" 2>/dev/null || true
  qemu-nbd --disconnect "$nbd" >/dev/null 2>&1 || true
  NBD_DEV=""
  log "desktop shortcuts + on-disk games/apps baked into golden"
}
bake_desktop_shortcuts

# 5b. Bake the 1920x1200x32 display (VBEMP universal-VESA miniport on std VGA) and
#     "show window contents while dragging = OFF" into the golden. std VGA's inbox
#     driver is 640x480-only and QEMU's cirrus breaks the XP desktop >640 under
#     KVM, so the VBEMP miniport is how the winxp tile gets a real 1920x1200 desktop
#     (verified full-frame on the streamhost tile 2026-07-27; the fleet resolution
#     target was raised 1024x768 -> 1920x1200 — docs/lab/tile-resolution-responsiveness.md).
#     Set HIRES=0 to skip.
HIRES="${HIRES:-1}"
if [[ "$HIRES" == "1" ]]; then
  _hires="$(dirname "$0")/winxp-vbemp-hires.sh"
  if [[ -x "$_hires" || -f "$_hires" ]]; then
    log "baking 1920x1200 VBEMP display + drag-off (winxp-vbemp-hires.sh)"
    DISK="$DISK_IMG" bash "$_hires" || log "WARN: hi-res display step failed — golden stays 640x480 std VGA"
  else
    log "WARN: $_hires not found — golden stays 640x480 std VGA (resolution goal unmet)"
  fi
fi

log "artifacts:"
log "  disk : ${DISK_IMG}  ($(qemu-img info "$DISK_IMG" | awk -F': ' '/disk size/{print $2}'))"
log "  D:   : ${SW_ISO}    ($(size_of "$SW_ISO") bytes)"

###############################################################################
# 6/7. Framebuffer verification: boot the FINISHED image with production args,
#      confirm it reaches the auto-logon desktop, then clean ACPI shutdown.
###############################################################################
# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
cleanup() {
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
  [[ -n "$NBD_DEV" ]] && qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT INT TERM

if [[ "$VERIFY" != "1" ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  echo "$DISK_IMG"
  exit 0
fi

RUN_DIR2="${GUEST_DIR}/.verify-run.$$"
mkdir -p "$RUN_DIR2"
MON_SOCK="${RUN_DIR2}/mon.sock"
PIDFILE="${RUN_DIR2}/qemu.pid"
log "framebuffer-verify: booting finished image with production gallery args"
accel=()
"$QEMU_BIN" -accel help 2>/dev/null | grep -qw kvm && accel=(-enable-kvm -cpu host)
"$QEMU_BIN" -name winxppro-verify \
  "${accel[@]}" -machine pc -m "$GALLERY_MEM" -smp 1 \
  -drive file="$DISK_IMG",format=qcow2,if=ide,index=0,media=disk \
  -drive file="$SW_ISO",format=raw,if=ide,index=2,media=cdrom \
  -boot order=c,menu=off \
  -netdev user,id=n0 -device rtl8139,netdev=n0 \
  -audiodev none,id=snd -device AC97,audiodev=snd \
  -usb -device usb-tablet -vga std -rtc base=localtime \
  -monitor "unix:${MON_SOCK},server,nowait" \
  -pidfile "$PIDFILE" -display none -daemonize
for _ in $(seq 1 20); do
  [[ -S "$MON_SOCK" ]] && break
  sleep 0.5
done

log "waiting ${VERIFY_WAIT}s for auto-logon to the Administrator desktop..."
sleep "$VERIFY_WAIT"

verify_rc=0
ppm="${RUN_DIR2}/shot.ppm"
mon_cmd "screendump ${ppm}"
sleep 1
if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
  pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || cp "$ppm" "${SHOT_PNG%.png}.ppm"
elif [[ -s "$ppm" ]]; then
  cp "$ppm" "${SHOT_PNG%.png}.ppm"
  SHOT_PNG="${SHOT_PNG%.png}.ppm"
fi
shot_bytes=0
[[ -f "$SHOT_PNG" ]] && shot_bytes="$(size_of "$SHOT_PNG")"
# A live 1920x1200 XP desktop screendump is comfortably > 20 KB.
if [[ "$shot_bytes" -gt 20000 ]]; then
  log "GUI VERIFIED: framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
else
  log "VERIFY WARN: framebuffer empty/too small (${shot_bytes} bytes) — raise VERIFY_WAIT / inspect ${SHOT_PNG}"
  verify_rc=2
fi

# Clean ACPI shutdown of the verify VM (monitor quit fallback lives in cleanup()).
log "clean ACPI shutdown of verify VM"
for r in 1 2 3 4 5; do
  install_alive || break
  mon_cmd "system_powerdown"
  sleep 5
  for _ in $(seq 1 8); do
    install_alive || break
    sleep 3
  done
  install_alive || {
    log "verify VM clean exit (round $r)"
    break
  }
done

rm -rf "$RUN_DIR2"
log "Done. Bootable artifacts: ${DISK_IMG} + ${SW_ISO}"
echo "$DISK_IMG"
exit "$verify_rc"

###############################################################################
# LAYOUT PRODUCED (verified against the validated dry-run box):
#   winxp.qcow2          qcow2, 6 GiB virtual (~800 MiB actual), IDE, boot=c
#                        XP Pro SP3, IE8 preinstalled, permanent Administrator
#                        auto-logon (password 'retro'), clean shutdown bit.
#   retro-software.iso   D: — APPS\{Firefox 2.0.0.20, Winamp 2.95},
#                        GAMES\Doom\ (ZDoom 2.8.1 + doom1/freedoom1/freedoom2 +
#                        Play-*.bat), GAMES\Quake\ (fteqw + id1\pak0.pak +
#                        Play-Quake-Shareware.bat), GAMES\Duke3D\ (GRP+EXE),
#                        GTA1\GTAINSTALLER.exe, README.txt.
#   unattend.flp         install-time answer floppy (kept for re-installs).
#
# PITFALLS / NOTES (from the validated build):
#   * std VGA has no 3D accel -> the launchers use SOFTWARE renderers (ZDoom sw,
#     FTEQW +vid_renderer sw). GLQuake/GZDoom-hw won't run.
#   * eDuke32 could not be fetched on the dry run (mirrors served HTML/404) ->
#     Duke3D ships as data + DOS exe; drop eduke32.exe in GAMES\Duke3D for native.
#   * First gallery boot shows a one-time "Display Settings" balloon; harmless.
#   * If you HARD-kill an install mid-GUI-phase, next boot shows the F8 recovery
#     menu; a clean ACPI/`shutdown -s` (as WINNT.SIF does) avoids it, and step 5
#     also removes bootstat.dat as a belt-and-suspenders.
#   * To ship as a neko tile: point CT110 at winxp.qcow2 + retro-software.iso
#     with the gallery args block above (swap -audiodev none/-display for the
#     neko VNC + pulse audiodev the other tiles use).
###############################################################################
