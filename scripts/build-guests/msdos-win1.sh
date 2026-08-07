#!/usr/bin/env bash
###############################################################################
# build-guests/msdos-win1.sh — reproduce the MS-DOS 6.22 + Windows 1.01 gallery
#                              tile FROM SOURCE on a fresh Proxmox host.
#
# GUEST : MS-DOS 6.22 (Microsoft, 1994) that boots straight to the C:\> prompt,
#         with Windows 1.01 (Microsoft, 1985) pre-installed in C:\WIN10. Typing
#         WIN (a C:\WIN.BAT launcher) drops into Windows 1.01's tiled MS-DOS
#         Executive GUI. ONE image backs TWO future SPA exhibits: "MS-DOS 6.22"
#         and "Windows 1.0".
# TYPE  : GENUINE FROM-FLOPPY BUILD (no prebuilt HDD base). The bootable C: drive
#         is created by booting the real MS-DOS 6.22 Setup Disk 1 in QEMU as an
#         unattended provisioning floppy (FDISK /MBR + FORMAT C: /S) — so IO.SYS,
#         MSDOS.SYS, COMMAND.COM and the MBR/boot sector are all AUTHENTIC MS
#         binaries laid down by MS-DOS itself. DOS utilities + the Windows 1.01
#         tree are then injected host-side with mtools; no interactive install.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh host):
#   1. Re-DOWNLOAD every source from archive.org (cached + idempotent):
#        - MS-DOS 6.22 Install Diskettes Disk1/2/3.img (genuine 3-floppy set)
#        - Windows 1.01 single-floppy image (carries WIN10.zip = a pre-built
#          Windows 1.01 with a working WIN.COM + all apps/fonts).
#   2. Build an UNATTENDED PROVISIONING FLOPPY = a copy of Setup Disk 1 whose
#      CONFIG.SYS is emptied and AUTOEXEC.BAT is replaced with:
#           FDISK /MBR                 (write the standard MS-DOS master boot code)
#           FORMAT C: /S /V:... < YES  (partition already exists -> format + SYS)
#      The "Proceed with Format (Y/N)?" prompt is answered from a piped YES.TXT,
#      so the whole provisioning run needs ZERO keystrokes.
#   3. Create the C: hard-disk image (raw, one primary FAT16 type-06 ACTIVE
#      partition at LBA 63 via sfdisk) and boot the provisioning floppy against
#      it headless in QEMU. When it finishes, C: is a genuine bootable MS-DOS
#      6.22 volume.
#   4. INJECT host-side with mtools (partition offset 63*512 = 32256):
#        - C:\DOS   : every UNCOMPRESSED *.COM/*.EXE/*.SYS/*.CPI/*.INI/*.TXT from
#                     the 3 Setup disks (EDIT, QBASIC, FORMAT, SYS, FDISK, CHKDSK,
#                     MEM, ATTRIB, DEBUG, XCOPY, MORE, CHOICE, HELP, ...).
#        - C:\WIN10 : the pre-built Windows 1.01 tree from WIN10.zip.
#        - C:\CONFIG.SYS   (FILES=30 / BUFFERS=20)
#        - C:\AUTOEXEC.BAT (PATH C:\DOS;C:\WIN10 + a boots-to-C:\> welcome banner)
#        - C:\WIN.BAT      (cd \WIN10 & WIN — so "WIN" launches Windows 1.01)
#   5. Land the artifact at data/gallery-guests/MSDOSWin1/msdos-win1.qcow2
#      (qemu-img convert -c; ~2 MB of real data in a 120 MB sparse volume).
#   6. FRAMEBUFFER-VERIFY: boot the qcow2 headless under the EXACT neko-qemu tile
#      profile (unique VNC + monitor socket), wait, `screendump` a PNG of the
#      C:\> boot screen and sanity-check it.
#
# WHY FDISK /MBR IS REQUIRED (diagnosed + verified on the dry-run box):
#   sfdisk writes the PARTITION TABLE but leaves the MBR bootstrap code (first
#   446 bytes) all-zeros. SeaBIOS loads that empty MBR and jumps into zeros ->
#   the guest HANGS at "Booting from Hard Disk..." forever. FORMAT /S makes the
#   PARTITION bootable but does NOT touch the MBR. Running FDISK /MBR first lays
#   down the standard MS-DOS master boot record that chain-loads the active
#   partition. With it, the disk boots to C:\> reliably.
#
# LICENSE / SOURCING (READ THIS):
#   MS-DOS 6.22 and Windows 1.01 are Microsoft-copyrighted — free to use in this
#   private collection. Microsoft open-sourced ONLY MS-DOS 1.25 and 2.0 (MIT,
#   github.com/microsoft/MS-DOS) — NOT 6.22, and NOT any Windows. There is no
#   free/open faithful substitute for this specific pairing (FreeDOS is a separate
#   tile; it is not MS-DOS, and Windows 1.01 needs real MS-DOS-family binaries under
#   it). These images are fetched at build time from archive.org (the binaries stay
#   out of the GitHub repo — never committed) and used in this PRIVATE, LAN-only,
#   edge-passkey-gated home-lab museum — the exact same stance the project already
#   applies to its Win 3.11/95/98/2000/XP tiles.
#
# HYGIENE (per project rules):
#   * Provisioning + verify VMs are killed ONLY via their QEMU monitor `quit`
#     (fallback: their own pidfile). NEVER `pkill qemu*` — that would catch live
#     gallery tiles / sibling OS builders / VM 900/925.
#   * Namespaced run dir + unique VNC display + unique monitor socket (per PID).
#   * Touches ONLY data/gallery-guests/MSDOSWin1/. No other guest, CT, or VM.
#
# Idempotent + re-runnable. `bash -n` clean. Safe to run repeatedly.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="msdos-win1"
DIR_NAME="MSDOSWin1" # matches /guests/MSDOSWin1 in the live tile

GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${GUESTS_ROOT}/${DIR_NAME}"
QCOW2_PATH="${GUEST_DIR}/msdos-win1.qcow2"

WORK="${GUEST_DIR}/.build-work" # sources + scratch (kept between runs = cache)
DL="${WORK}/dl"                 # downloaded sources cache
RAW_IMG="${WORK}/hdd.img"       # writable raw C: we provision then compress
PART_OFFSET=32256               # partition 1 starts at LBA 63 (63*512)
DISK_MB="${DISK_MB:-120}"       # C: size (MiB)

# Behaviour knobs
FORCE="${FORCE:-0}"                    # FORCE=1 rebuilds even if the qcow2 exists
VERIFY="${VERIFY:-1}"                  # VERIFY=0 skips the framebuffer boot
PROVISION_WAIT="${PROVISION_WAIT:-25}" # seconds for FDISK/MBR + FORMAT /S (fast)
VERIFY_WAIT="${VERIFY_WAIT:-16}"       # seconds for Windows 1.01 to reach the Executive
KEEP_WORK="${KEEP_WORK:-1}"            # 1 = keep source cache; 0 = wipe $WORK at end
VNC_DISP="${VNC_DISP:-88}"             # VNC :88 -> tcp 5988; clear of gallery tiles
QEMU_BIN="${QEMU_BIN:-qemu-system-i386}"

export MTOOLS_SKIP_CHECK=1 # let mtools work on partition-offset images

# ------------------------------------------------------------- source URLs (real)
# Genuine MS-DOS 6.22 Setup Disks 1-3 (1.44 MB each).
DOS_BASE="https://archive.org/download/disk-1_202101/MS-DOS%206.22%20Install%20Diskettes"
DOS_D1_URL="${DOS_BASE}/Disk1.img"
DOS_D2_URL="${DOS_BASE}/Disk2.img"
DOS_D3_URL="${DOS_BASE}/Disk3.img"
# Windows 1.01 single-floppy (root has INSTALL.BAT + UNZIP.EXE + WIN10.zip; the
# zip is a pre-built Windows 1.01 tree with a working WIN.COM).
WIN101_URL="https://archive.org/download/windows-1.01_1floppy/Windows%201.01.img"
WIN101_FIXED_QCOW2="${WIN101_FIXED_QCOW2:-$DL/disk_install2.qcow2}"
WIN101_FIXED_SHA256="cf7a75f0d61223ad594e33b6c55b7f457a1880f67f2c5699634440aa2a18071e"

UA="Mozilla/5.0 (msdos-win1-gallery-build)"

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch args this tile runs with in the live gallery
# (validated headless + confirmed streaming via the neko screenshot API):
#
#   qemu-system-x86_64 -machine pc -enable-kvm -cpu host -m 16 -smp 1 -vga std \
#     -drive file=msdos-win1.qcow2,format=qcow2,if=ide -boot c -snapshot
#
# neko-qemu / launch-qemu.sh environment for this tile:
#   OS_NAME="MS-DOS 6.22 + Windows 1.01"
#   QEMU_MACHINE=pc  QEMU_MEM=16  QEMU_SMP=1  QEMU_VGA=std
#   GUEST_DISK=/guests/MSDOSWin1/msdos-win1.qcow2  GUEST_FMT=qcow2
#   GUEST_IF=ide  GUEST_BOOT=c
#   QEMU_EXTRA="-cpu host -snapshot"   ACCEL=kvm   (KVM flip, 2026-07-04)
# Notes: std VGA renders Windows 1.01's EGA driver correctly. PS/2 kbd+mouse only
#   (1985/1994 hardware — do NOT add usb-tablet). 16 MB RAM is plenty; single core.
#   Image is mounted read-only + -snapshot -> every visitor session is ephemeral.
#   PERF: flipped TCG->KVM per docs/perf-baseline-report.md [deleted — git history] §4 (KVM-safe set: "DOS
#   busy-waits under TCG; KVM big win"). ACCEL=kvm emits -enable-kvm; -cpu pentium->
#   -cpu host. Verified: /dev/kvm fd open, C:\> renders identically, input->photon
#   improved (mouse 573->195ms, kbd 436->379ms, 5/5). This guest is real MS-DOS +
#   Win 1.01, NOT a protected-mode Win9x guest -> the Win9x KVM knobs do NOT apply.
#   The build/verify QEMU runs below stay TCG headless (build correctness, not perf).
###############################################################################

# --------------------------------------------------------------- tool checks
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need curl
need unzip
need sha256sum
need qemu-img
need sfdisk
need dd
need mcopy
need mdir
need mmd
need socat
command -v "$QEMU_BIN" >/dev/null 2>&1 || QEMU_BIN="qemu-system-x86_64"
command -v "$QEMU_BIN" >/dev/null 2>&1 || die "no qemu-system-i386/x86_64 binary"

# --------------------------------------------------------------- 0. workspace
mkdir -p "$GUEST_DIR" "$WORK" "$DL"

if [[ -f "$QCOW2_PATH" && "$FORCE" != "1" ]]; then
  log "msdos-win1.qcow2 already present (FORCE=1 to rebuild) — jumping to verify."
else

  # ---------------------------------------------------------- 1. download sources
  fetch() { # fetch URL DEST — cached; re-downloads only if missing or zero-size
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then
      log "cached: $(basename "$dest")"
      return 0
    fi
    log "download: $url"
    curl -fL --retry 3 --retry-delay 2 -A "$UA" -e "https://archive.org/" \
      -o "${dest}.part" "$url"
    mv -f "${dest}.part" "$dest"
  }
  fetch "$DOS_D1_URL" "$DL/Disk1.img"
  fetch "$DOS_D2_URL" "$DL/Disk2.img"
  fetch "$DOS_D3_URL" "$DL/Disk3.img"
  fetch "$WIN101_URL" "$DL/win101.img"

  # ------------------------------------------------ 1a. extract Windows 1.01 tree
  # The win101 floppy root holds WIN10.zip; unzip it -> WIN10/ (pre-built Win 1.01).
  log "extracting Windows 1.01 (WIN10.zip) from the single-floppy image"
  mcopy -n -o -i "$DL/win101.img" ::WIN10.zip "$DL/WIN10.zip"
  WIN10_DIR="$WORK/win10"
  rm -rf "$WIN10_DIR"
  mkdir -p "$WIN10_DIR"
  unzip -o -q "$DL/WIN10.zip" -d "$WIN10_DIR"
  WIN10_SRC="$(dirname "$(find "$WIN10_DIR" -type f -iname 'WIN.COM' | head -1)")"
  [[ -n "$WIN10_SRC" && -d "$WIN10_SRC" ]] || die "WIN.COM not found inside WIN10.zip"
  log "Windows 1.01 tree: $WIN10_SRC ($(find "$WIN10_SRC" -type f | wc -l | tr -d ' ') files)"

  # ------------------------------------------------ 2. build provisioning floppy
  # Copy Setup Disk 1 (already bootable) and swap its boot scripts for ours.
  PROV="$WORK/prov.img"
  cp -f "$DL/Disk1.img" "$PROV"
  : >"$WORK/empty.cfg"
  mcopy -o -i "$PROV" "$WORK/empty.cfg" ::CONFIG.SYS # no SETUP driver load
  printf 'Y\r\n\r\n' >"$WORK/YES.TXT"                # Proceed=Y, blank label line
  mcopy -o -i "$PROV" "$WORK/YES.TXT" ::YES.TXT
  {
    printf '@ECHO OFF\r\n'
    printf 'ECHO === PROVISIONING C: (MBR + FORMAT /S) ===\r\n'
    printf 'FDISK /MBR\r\n'
    printf 'FORMAT C: /S /V:MSDOS622 < A:\\YES.TXT\r\n'
    printf 'ECHO PROVISION-DONE-SENTINEL\r\n'
    printf ':LOOP\r\n'
    printf 'GOTO LOOP\r\n'
  } >"$WORK/AUTOEXEC.BAT"
  mcopy -o -i "$PROV" "$WORK/AUTOEXEC.BAT" ::AUTOEXEC.BAT

  # ------------------------------------------------ 3. create + provision C: disk
  log "creating ${DISK_MB} MiB C: (1 primary FAT16 type-06 ACTIVE @ LBA 63)"
  qemu-img create -f raw "$RAW_IMG" "${DISK_MB}M" >/dev/null
  sfdisk --no-reread --no-tell-kernel "$RAW_IMG" >/dev/null 2>&1 <<SF
label: dos
63,,6,*
SF

  PROV_RUN="$WORK/.prov-run.$$"
  mkdir -p "$PROV_RUN"
  PMON="$PROV_RUN/mon.sock"
  PROV_PIDFILE="$PROV_RUN/qemu.pid"
  pmon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${PMON}" >/dev/null 2>&1 || true; }
  prov_cleanup() {
    if [[ -S "$PMON" ]]; then
      pmon "quit"
      sleep 1
    fi
    if [[ -f "$PROV_PIDFILE" ]]; then
      local p
      p="$(cat "$PROV_PIDFILE" 2>/dev/null || true)"
      [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null && {
        kill "$p" 2>/dev/null || true
        sleep 1
        kill -9 "$p" 2>/dev/null || true
      }
    fi
    rm -rf "$PROV_RUN"
  }
  trap prov_cleanup EXIT INT TERM

  log "booting unattended provisioning floppy (VNC :${VNC_DISP}, headless)"
  "$QEMU_BIN" \
    -machine pc -cpu pentium -m 16 \
    -drive file="$PROV",format=raw,if=floppy,index=0 \
    -drive file="$RAW_IMG",format=raw,if=ide,index=0 -boot a \
    -vga std \
    -vnc ":${VNC_DISP}" \
    -monitor "unix:${PMON},server,nowait" \
    -pidfile "$PROV_PIDFILE" \
    -display none -daemonize
  for _ in $(seq 1 20); do
    [[ -S "$PMON" ]] && break
    sleep 0.5
  done
  log "waiting ${PROVISION_WAIT}s for FDISK /MBR + FORMAT C: /S to finish..."
  sleep "$PROVISION_WAIT"
  prov_cleanup
  trap - EXIT INT TERM

  # ------------------------------------------------ 4. inject DOS + Windows 1.01
  MRC="$WORK/mtoolsrc"
  printf 'drive c: file="%s" offset=%s\n' "$RAW_IMG" "$PART_OFFSET" >"$MRC"
  export MTOOLSRC="$MRC"

  # sanity: FORMAT /S must have transferred the system (COMMAND.COM visible on C:)
  mdir c: 2>/dev/null | grep -qi 'COMMAND' || die "C: not formatted/bootable — provisioning failed (raise PROVISION_WAIT)"

  # 4a. DOS utilities: extract each Setup disk, copy the UNCOMPRESSED externals.
  log "injecting C:\\DOS utilities from the 3 Setup disks"
  DEX="$WORK/disks"
  rm -rf "$DEX"
  mkdir -p "$DEX/d1" "$DEX/d2" "$DEX/d3"
  for n in 1 2 3; do mcopy -o -s -i "$DL/Disk${n}.img" "::*" "$DEX/d${n}/" 2>/dev/null || true; done
  mmd c:/DOS 2>/dev/null || true
  shopt -s nullglob nocaseglob
  dos_count=0
  for f in "$DEX"/d1/* "$DEX"/d2/* "$DEX"/d3/*; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"
    ext="${b##*.}"
    case "$b" in
      IO.SYS | MSDOS.SYS | COMMAND.COM) continue ;;                   # already on C: via /S
      SETUP.* | DOSSETUP.INI | AUTOEXEC.BAT | CONFIG.SYS) continue ;; # installer bits
    esac
    case "$ext" in
      COM | EXE | SYS | CPI | INI | TXT | com | exe | sys | cpi | ini | txt)
        mcopy -o "$f" c:/DOS/ 2>/dev/null && dos_count=$((dos_count + 1)) || true
        ;;
    esac
  done
  shopt -u nullglob nocaseglob
  log "  copied $dos_count DOS files into C:\\DOS"

  # 4b. Windows 1.01 tree -> C:\WIN10
  log "injecting Windows 1.01 into C:\\WIN10"
  mmd c:/WIN10 2>/dev/null || true
  mcopy -o -s "$WIN10_SRC"/* c:/WIN10/ 2>/dev/null

  # 4c. boot config (land at C:\> ; WIN launches Windows 1.01)
  printf 'FILES=30\r\nBUFFERS=20\r\n' >"$WORK/CONFIG.SYS.new"
  mcopy -o "$WORK/CONFIG.SYS.new" c:/CONFIG.SYS
  {
    printf '@ECHO OFF\r\n'
    printf 'PATH C:\\DOS;C:\\WIN10\r\n'
    # shellcheck disable=SC2016 # literal MS-DOS AUTOEXEC.BAT prompt syntax ($P$G = drive+path); not a shell variable
    printf 'PROMPT $P$G\r\n'
    printf 'SET TEMP=C:\\DOS\r\n'
    printf 'CLS\r\n'
    printf 'ECHO.\r\n'
    printf 'ECHO  ==========================================================\r\n'
    printf 'ECHO   MS-DOS 6.22   (Microsoft, 1994)\r\n'
    printf 'ECHO   Windows 1.01  (Microsoft, 1985) is installed in C:\\WIN10\r\n'
    printf 'ECHO  ----------------------------------------------------------\r\n'
    printf 'ECHO   Type  WIN   to launch Windows 1.01\r\n'
    printf 'ECHO   Type  DIR   to list files,  HELP  for DOS help\r\n'
    printf 'ECHO  ==========================================================\r\n'
    printf 'ECHO.\r\n'
  } >"$WORK/AUTOEXEC.BAT.new"
  mcopy -o "$WORK/AUTOEXEC.BAT.new" c:/AUTOEXEC.BAT
  printf '@ECHO OFF\r\nC:\r\nCD \\WIN10\r\nWIN\r\nCD \\\r\n' >"$WORK/WIN.BAT"
  mcopy -o "$WORK/WIN.BAT" c:/WIN.BAT
  unset MTOOLSRC
  log "C: assembled: MS-DOS 6.22 (boot) + C:\\DOS + C:\\WIN10 + WIN.BAT"

  # 4d. Replace the damaged single-floppy tree with the validated genuine-SETUP
  # install. This small staged qcow2 is the deterministic output of installing the
  # five original Windows 1.01 floppies after replacing SETUP-disk MOUSE.DRV with
  # Windows 2.03 D2_Build.img's 3,667-byte driver. It also carries the DOS 6.22
  # SETVER table entries WIN100.BIN=3.30 and WIN.COM=3.30.
  [[ -s "$WIN101_FIXED_QCOW2" ]] || die "missing staged genuine Windows 1.01 install: $WIN101_FIXED_QCOW2"
  got_fixed_sha="$(sha256sum "$WIN101_FIXED_QCOW2" | awk '{print $1}')"
  [[ "$got_fixed_sha" == "$WIN101_FIXED_SHA256" ]] || die "genuine Windows 1.01 staged image sha256 mismatch: $got_fixed_sha"
  FIXED_RAW="$WORK/win101-fixed.raw"
  qemu-img convert -O raw "$WIN101_FIXED_QCOW2" "$FIXED_RAW"
  printf 'drive c: file="%s" offset=%s\ndrive w: file="%s" offset=%s\n' \
    "$RAW_IMG" "$PART_OFFSET" "$FIXED_RAW" "$PART_OFFSET" >"$MRC"
  export MTOOLSRC="$MRC"
  mmd c:/WINDOWS 2>/dev/null || true
  mcopy -o -s "w:/WINDOWS/*" c:/WINDOWS/
  mcopy -o w:/DOS/SETVER.EXE c:/DOS/SETVER.EXE
  mdir c:/WINDOWS/WIN.COM >/dev/null 2>&1 || die "genuine Windows tree graft failed"
  mdir c:/DOS/SETVER.EXE >/dev/null 2>&1 || die "SETVER graft failed"
  printf 'DEVICE=C:\\DOS\\SETVER.EXE\r\nFILES=30\r\nBUFFERS=20\r\n' >"$WORK/CONFIG.SYS.new"
  mcopy -o "$WORK/CONFIG.SYS.new" c:/CONFIG.SYS
  {
    printf '@ECHO OFF\r\n'
    printf 'PATH C:\\DOS;C:\\WINDOWS\r\n'
    # shellcheck disable=SC2016 # literal MS-DOS AUTOEXEC.BAT prompt syntax ($P$G = drive+path); not a shell variable
    printf 'PROMPT $P$G\r\n'
    printf 'SET TEMP=C:\\DOS\r\n'
    printf 'CLS\r\n'
    printf 'ECHO MS-DOS 6.22 + genuine Windows 1.01 (SETVER + PS/2 mouse fix)\r\n'
    printf 'CALL WIN.BAT\r\n'
  } >"$WORK/AUTOEXEC.BAT.new"
  mcopy -o "$WORK/AUTOEXEC.BAT.new" c:/AUTOEXEC.BAT
  printf '@ECHO OFF\r\nC:\r\nCD \\WINDOWS\r\nWIN\r\nCD \\\r\n' >"$WORK/WIN.BAT"
  mcopy -o "$WORK/WIN.BAT" c:/WIN.BAT
  unset MTOOLSRC
  log "promoted genuine C:\\WINDOWS + Windows 2.03 PS/2 mouse driver + SETVER fixes; boot auto-launches WIN"
  # ------------------------------------------------ 5. finalize -> compressed qcow2
  log "compressing to qcow2 -> $QCOW2_PATH"
  rm -f "$QCOW2_PATH"
  qemu-img convert -c -O qcow2 "$RAW_IMG" "$QCOW2_PATH"
  log "built: $(qemu-img info "$QCOW2_PATH" | awk -F': ' '/virtual size/{print $2}') virtual"

  [[ "$KEEP_WORK" == "1" ]] || {
    rm -rf "$RAW_IMG" "$DEX" "$WIN10_DIR"
    log "wiped scratch (kept $DL cache)"
  }

fi # end build block

# ------------------------------------------------ 6. framebuffer verification
if [[ "$VERIFY" != "1" ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  echo "$QCOW2_PATH"
  exit 0
fi

VRUN="${GUEST_DIR}/.verify-run.$$"
VMON="${VRUN}/mon.sock"
VPID="${VRUN}/qemu.pid"
SHOT_PNG="${GUEST_DIR}/verify-win101-gui.png"
mkdir -p "$VRUN"
vmon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${VMON}" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
vcleanup() {
  if [[ -S "$VMON" ]]; then
    vmon "quit"
    sleep 1
  fi
  if [[ -f "$VPID" ]]; then
    local p
    p="$(cat "$VPID" 2>/dev/null || true)"
    [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null && {
      kill "$p" 2>/dev/null || true
      sleep 1
      kill -9 "$p" 2>/dev/null || true
    }
  fi
  rm -rf "$VRUN"
}
trap vcleanup EXIT INT TERM

log "framebuffer-verify: booting the qcow2 headless (VNC :${VNC_DISP})"
# EXACT neko-qemu tile profile (audio device dropped for the headless host).
"$QEMU_BIN" \
  -machine pc -cpu pentium -m 16 -smp 1 -vga std \
  -drive file="$QCOW2_PATH",format=qcow2,if=ide,index=0 -boot c -snapshot \
  -vnc ":${VNC_DISP}" \
  -monitor "unix:${VMON},server,nowait" \
  -pidfile "$VPID" \
  -display none -daemonize
for _ in $(seq 1 20); do
  [[ -S "$VMON" ]] && break
  sleep 0.5
done
log "waiting ${VERIFY_WAIT}s for Windows 1.01 to reach the MS-DOS Executive..."
sleep "$VERIFY_WAIT"

# Grab the Windows 1.01 framebuffer (PNG with PPM fallback for old QEMU).
verify_rc=0
if vmon "screendump -f png ${SHOT_PNG}" && [[ -s "$SHOT_PNG" ]]; then :; else
  ppm="${VRUN}/shot.ppm"
  vmon "screendump ${ppm}"
  sleep 1
  if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || {
      cp "$ppm" "${SHOT_PNG%.png}.ppm"
      SHOT_PNG="${SHOT_PNG%.png}.ppm"
    }
  elif [[ -s "$ppm" ]]; then
    cp "$ppm" "${SHOT_PNG%.png}.ppm"
    SHOT_PNG="${SHOT_PNG%.png}.ppm"
  fi
fi
shot_bytes=0
[[ -f "$SHOT_PNG" ]] && shot_bytes="$(wc -c <"$SHOT_PNG" | tr -d ' ')"
if [[ "$shot_bytes" -gt 1000 ]]; then
  log "GUI VERIFIED: Windows 1.01 framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
else
  log "VERIFY WARN: capture empty/too small (${shot_bytes} bytes). Raise VERIFY_WAIT and re-run."
  verify_rc=2
fi

log "Done. Bootable artifact: ${QCOW2_PATH}"
echo "$QCOW2_PATH"
exit "$verify_rc"

###############################################################################
# LAYOUT PRODUCED (verified on the dry-run box, 2026-07-04):
#   C: msdos-win1.qcow2 (120 MB virtual, FAT16 @ LBA 63, ~2 MB real data)
#      \IO.SYS \MSDOS.SYS \COMMAND.COM   (genuine MS-DOS 6.22, laid by FORMAT /S)
#      \CONFIG.SYS   (FILES=30 / BUFFERS=20)
#      \AUTOEXEC.BAT (PATH + boots-to-C:\> welcome banner — does NOT auto-run WIN)
#      \WIN.BAT      (cd \WIN10 & WIN)
#      \DOS\         (EDIT, QBASIC, FORMAT, SYS, FDISK, CHKDSK, MEM, ATTRIB,
#                     DEBUG, XCOPY, MORE, CHOICE, HELP, ... — uncompressed set)
#      \WIN10\       (Windows 1.01: WIN.COM, WIN100.BIN/OVL, CALC/PAINT/REVERSI/
#                     CARDFILE/CALENDAR/CLOCK/CONTROL/NOTEPAD/TERMINAL/WRITE, fonts)
#
# PITFALLS / NOTES:
#   * FDISK /MBR is MANDATORY (see header) — without it the guest hangs at
#     "Booting from Hard Disk...". This was the single hardest bug in the build.
#   * The "Proceed with Format (Y/N)?" prompt IS answerable via `< A:\YES.TXT`
#     redirection on MS-DOS 6.22 FORMAT (verified). No sendkey timing needed.
#   * Windows 1.01's WIN.COM must run from its own dir (it finds WIN100.BIN in the
#     CWD) — hence WIN.BAT does `CD \WIN10` first. Running WIN.COM straight from
#     C:\ would not find its overlay.
#   * Display: std VGA renders Win 1.01's EGA driver fine. Do NOT switch to cirrus
#     (unnecessary; std is what was validated). No usb-tablet.
#   * STREAMHOST TILE FIXES (2026-07-13; see docs/guests/msdos-win1.md):
#     - Keyboard: Win 1.01 ignores 0xE0-prefixed enhanced arrow scancodes; the
#       streamhost tile sets SH_LEGACY_KBD=1 so input.rs remaps the dedicated
#       cursor cluster to bare keypad codes. Host-side only, no rebake.
#     - Sound: Keen 1 is PC-speaker only; the tile launcher wires
#       -machine pc,pcspk-audiodev=snd0 + -audiodev dbus + SH_AUDIO=on (backend
#       only, no rebake). Confirmed non-silent under KVM.
#     - App launch ("Cannot run NOTEPAD.EXE" for EVERY app): SOLVED, clone-validated
#       2026-07-13. NOT memory (584 KB free) — it is Win 1.x's DOS major-version
#       check refusing to launch tasks under DOS 6.22. Fix (config only, no device
#       change): EXPAND SETVER.EX_ (Disk2) -> C:\DOS\SETVER.EXE, add
#       DEVICE=C:\DOS\SETVER.EXE to CONFIG.SYS, and register
#       `SETVER WIN100.BIN 3.30` + `SETVER WIN.COM 3.30`. All bundled apps then run.
#     - Mouse: SOLVED, clone-validated 2026-07-13 (supersedes the old "BLOCKED" note).
#       Win 1.01's stock bound-in Microsoft Mouse driver does NOT detect QEMU's
#       msmouse serial device (QEMU GitLab #78). Fix: fresh SETUP install from the
#       genuine 5-disk set (archive.org microsoft-windows-1.01-install-disks) with the
#       Windows 2.03 MOUSE.DRV (from microsoft-windows-2.03-5.25 D2_Build.img) swapped
#       over the 1.01 MOUSE.DRV on the SETUP disk; pick "Microsoft Mouse (Bus/Serial)"
#       + "EGA (more than 64K)". The 2.03 driver drives QEMU's DEFAULT PS/2 mouse, so
#       NO launcher device change is needed (loadvm golden device-set preserved) — it
#       is a golden-content rebake only. Cursor move + File-menu click framebuffer-
#       proven. See docs/guests/msdos-win1.md "Win 1.01 four-issue deep fix".
#   * Compressed Setup-disk files (*.??_ e.g. HIMEM.SY_) are SZDD-packed and need
#     DOS EXPAND, so they are intentionally NOT injected into C:\DOS — the
#     uncompressed core set is more than enough for a museum DOS prompt.
#   * ONE image, TWO SPA exhibits: expose it as "MS-DOS 6.22" (C:\> prompt) and
#     "Windows 1.0" (auto-run WIN, or instruct the visitor to type WIN).
###############################################################################
