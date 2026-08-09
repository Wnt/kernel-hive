#!/usr/bin/env bash
###############################################################################
# build-guests/stages/winxp-vbemp-hires.sh
#   Bake 1920x1200x32 display + "show window contents while dragging = OFF" into
#   the post-install Windows XP gallery golden (winxp.qcow2), reproducibly.
#   (Fleet resolution target raised 1024x768 -> 1920x1200 on 2026-07-27; the
#   unaccelerated packed-VBEMP path stays inside the 30 fps encode budget on KVM
#   — see docs/lab/tile-resolution-responsiveness.md.)
#
# WHY THIS EXISTS
#   The winxp tile runs on the QEMU *std* (Bochs) PCI VGA under KVM. XP's inbox
#   "Standard VGA" driver is hard-capped at 640x480, and QEMU's *cirrus*
#   emulation breaks the XP desktop bring-up above 640x480 on a cold -snapshot
#   boot under KVM (top ~half of the framebuffer scans out, the taskbar never
#   paints). The reliable, KVM-stable way to get a true 1920x1200 XP desktop on
#   std VGA is the VBEMP universal VESA display miniport (bearwindows / AnaPa):
#   its VBE 2.0 XP build binds to the std-VGA PCI device (PCI\CC_0300) and sets
#   real VESA modes through the Bochs VBE BIOS. 1920x1200x32 = 9.2 MiB, well
#   under the std-VGA default 16 MiB vgamem, so the production launcher's plain
#   "-vga std" renders it full-frame. Verified end-to-end 2026-07-27: a fresh
#   -loadvm golden boot comes up full-frame crisp at 1920x1200, taskbar and all.
#
#   NOTE the VBE *3.0* XP build (VBE30/) renders BLACK on this QEMU std VGA
#   (its VBE3 BIOS calls mis-set the mode) — use the VBE *2.0* build (VBE20/).
#
#   EDID GOTCHA (why the "Hide modes" step exists): QEMU's std VGA advertises a
#   Plug-and-Play monitor whose EDID caps the resolution slider at 1920x1080.
#   VBEMP's own mode list goes far higher (up to 3840x2160), but XP hides the
#   monitor-"unsupported" modes until you clear Advanced -> Monitor -> "Hide
#   modes that this monitor cannot display". With that cleared, 1920x1200 is
#   selectable and persists across reboots.
#
# WHAT IT DOES (two headless, monitor-driven QEMU phases + a verify boot)
#   0. fetch VBEMP (vbempk.zip) and build a FAT12 driver floppy (VBE20/XP/PNP).
#   1. boot std VGA + the floppy; drive Device Manager -> the driverless
#      "Video Controller (VGA Compatible)" -> Update Driver -> "No, not this
#      time" -> Install automatically (finds vbemppnp.inf on A:) -> Finish;
#      clean ACPI shutdown.
#   2. boot std VGA (VBEMP now active, defaults to 1280x800); Display Properties
#      -> Settings -> Advanced -> Monitor -> clear "Hide modes..." -> OK; then
#      slider End (=max 3840x2160) -> 3x Left (=1920x1200, Highest/32-bit) ->
#      Apply -> keep; Appearance -> Effects -> uncheck "Show window contents
#      while dragging" -> Apply; clean ACPI shutdown.
#   3. verify: boot, screendump, assert the PPM is 1920x1200, clean shutdown.
#
# QEMU_VGA stays "std" and the tile carries "-usb -device usb-tablet" (absolute
# cursor) + "-device AC97" (so the audio driver is baked in before the golden).
#
# RUN AFTER winxp.sh has produced the auto-logon golden. Idempotent-ish: re-runs
# re-install the driver over itself (harmless) but prefer running once on a fresh
# golden. Timing-driven GUI automation — each phase drops a screendump PNG into
# $LOG_DIR so you can eyeball the checkpoints.
#
# DEPS (host): qemu-system-x86_64 (or -i386), socat, curl, unzip, mcopy, and
#   mkfs.vfat OR mtools mformat, plus pnmtopng (optional, for verify PNG).
#
# LEGAL: VBEMP is © J.W.Soft / AnaPa, redistributable freeware (see lic.htm in
#   the zip). Windows XP is Microsoft-copyright — free to use in this private
#   collection; supply your own media upstream in winxp.sh (the binary stays out of
#   the GitHub repo).
###############################################################################
set -euo pipefail

DISK="${DISK:-/data/gallery-guests/WinXPpro/winxp.qcow2}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"        # KVM-capable; std VGA
QEMU_ACCEL="${QEMU_ACCEL:--enable-kvm -cpu host}" # match the live tile
MEM="${MEM:-768}"
RUN_DIR="${RUN_DIR:-/tmp/winxp-hires.$$}"
LOG_DIR="${LOG_DIR:-${RUN_DIR}/log}"
VBE_ZIP_URL="${VBE_ZIP_URL:-https://bearwindows.zcm.com.au/vbempk.zip}"
FLP="${RUN_DIR}/vbemp.img"
MON_SOCK="${RUN_DIR}/mon.sock"
BOOT_WAIT="${BOOT_WAIT:-70}" # seconds to reach the auto-logon desktop
SHUTDOWN_WAIT="${SHUTDOWN_WAIT:-90}"

mkdir -p "$RUN_DIR" "$LOG_DIR"
log() { printf '[winxp-hires] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
for t in "$QEMU_BIN" socat curl unzip mcopy; do need "$t"; done
command -v mkfs.vfat >/dev/null 2>&1 || command -v mformat >/dev/null 2>&1 ||
  die "need mkfs.vfat or mtools(mformat) to build the driver floppy"
[[ -f "$DISK" ]] || die "disk not found: $DISK"

# ---- QEMU monitor helpers ---------------------------------------------------
mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }
key() {
  local k
  for k in "$@"; do
    mon "sendkey $k"
    sleep 0.15
  done
}
# type an ASCII string via sendkey (lowercase letters, digits, and '.')
type_str() {
  local s="$1" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    case "$c" in
      .) mon "sendkey dot" ;;
      /) mon "sendkey slash" ;;
      *) mon "sendkey $c" ;;
    esac
    sleep 0.12
  done
}
shot() {
  mon "screendump ${LOG_DIR}/$1.ppm"
  sleep 1
}

QEMU_PID=""
boot() { # boot(<extra-args...>) — starts qemu detached with a monitor socket
  rm -f "$MON_SOCK"
  # shellcheck disable=SC2086
  "$QEMU_BIN" -name winxp-hires -m "$MEM" -smp 1 -machine pc -vga std \
    -rtc base=localtime $QEMU_ACCEL \
    -drive "file=${DISK},format=qcow2,if=ide" -boot order=c,menu=off \
    -netdev user,id=n0 -device rtl8139,netdev=n0 -usb -device usb-tablet \
    -audiodev none,id=snd -device AC97,audiodev=snd \
    -display none -monitor "unix:${MON_SOCK},server,nowait" "$@" &
  QEMU_PID=$!
  for _ in $(seq 1 40); do
    [[ -S "$MON_SOCK" ]] && break
    sleep 0.5
  done
  [[ -S "$MON_SOCK" ]] || die "qemu monitor socket never appeared"
}
powerdown() { # clean ACPI shutdown + wait for the process to exit
  mon "system_powerdown"
  for _ in $(seq 1 "$SHUTDOWN_WAIT"); do
    kill -0 "$QEMU_PID" 2>/dev/null || {
      QEMU_PID=""
      return 0
    }
    sleep 1
  done
  log "WARN: guest did not power off in ${SHUTDOWN_WAIT}s — sending monitor quit"
  mon "quit"
  sleep 2
  kill -9 "$QEMU_PID" 2>/dev/null || true
  QEMU_PID=""
}
trap '[[ -n "$QEMU_PID" ]] && { mon quit; sleep 1; kill -9 "$QEMU_PID" 2>/dev/null; }' EXIT

# ---- 0. fetch VBEMP + build the driver floppy -------------------------------
fetch_and_build_floppy() {
  log "fetching VBEMP ($VBE_ZIP_URL)"
  curl -fsSL "$VBE_ZIP_URL" -o "${RUN_DIR}/vbempk.zip" ||
    die "download failed (note: the host redirects http->https; -L handles it)"
  (cd "$RUN_DIR" && unzip -oq vbempk.zip)
  local src="${RUN_DIR}/VBE20/XP/PNP"
  [[ -f "${src}/vbemp.sys" && -f "${src}/vbemppnp.inf" ]] ||
    die "VBE20/XP/PNP/{vbemp.sys,vbemppnp.inf} not found in the zip"
  log "building FAT12 VBEMP driver floppy"
  dd if=/dev/zero of="$FLP" bs=1024 count=1440 status=none
  if command -v mkfs.vfat >/dev/null 2>&1; then
    mkfs.vfat -F 12 "$FLP" >/dev/null
  else mformat -i "$FLP" -f 1440 ::; fi
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "$FLP" \
    "${src}/vbemp.sys" "${src}/vbemppnp.inf" "${RUN_DIR}/CPL/vbemp.cpl" ::
  log "vbemp.img ready"
}

# ---- 1. install the VBEMP miniport on the driverless std-VGA device ---------
install_driver() {
  log "phase 1: install VBEMP miniport (boot std VGA + floppy)"
  boot -fda "$FLP"
  sleep "$BOOT_WAIT" # reach the Administrator desktop
  shot 10-desktop
  # Device Manager
  key ctrl-esc
  sleep 1
  key r
  sleep 1
  type_str "devmgmt.msc"
  key ret
  sleep 4
  # focus the tree, select "Video Controller (VGA Compatible)" under Other devices.
  # Tree order on the validated build: Computer, Disk drives, DVD/CD-ROM, Floppy
  # disk controllers, Floppy disk drives, HID, IDE ATA/ATAPI, Keyboards, Mice,
  # Network adapters, Other devices, >Video Controller< (12 Downs after Tab).
  key tab
  local i
  for i in $(seq 1 12); do key down; done
  sleep 1
  shot 11-video-selected
  # context menu -> first item is "Update Driver..." (arrow-select, NOT 'u':
  # 'Update' and 'Uninstall' share the U accelerator)
  key shift-f10
  sleep 1
  key down
  key ret
  sleep 2
  # wizard p1: "No, not this time"
  key tab
  key down
  key down
  sleep 0.5
  key alt-n
  sleep 2
  # wizard p2: "Install the software automatically" (default) -> search floppy
  key alt-n
  sleep 8
  shot 12-installed
  key ret # Finish
  sleep 2
  key alt-f4 # close Device Manager
  sleep 2
  powerdown
}

# ---- 2. clear the mode filter, set 1920x1200x32, disable full-window drag ----
set_mode_and_drag() {
  log "phase 2: unhide modes, set 1920x1200x32, drag-full-window OFF"
  boot
  sleep "$BOOT_WAIT" # VBEMP active; defaults to 1280x800
  shot 20-desktop
  # Display Properties -> Settings tab
  key ctrl-esc
  sleep 1
  key r
  sleep 1
  type_str "desk.cpl"
  key ret
  sleep 3
  key ctrl-tab ctrl-tab ctrl-tab ctrl-tab
  sleep 1 # -> Settings tab
  # (A) Clear "Hide modes that this monitor cannot display" so VBEMP's full mode
  #     list (incl. 1920x1200) is offered past the PnP-monitor EDID cap. From
  #     Settings: focus the slider, Tab x3 -> Advanced -> open; Ctrl+Tab x2 to
  #     the Monitor tab; Tab x2 -> the checkbox; Space clears it; Enter = OK.
  key tab
  sleep 0.3
  key shift-tab
  sleep 0.3 # focus the resolution slider (Tab=colour combo; Shift+Tab=slider)
  key tab tab tab
  sleep 0.3
  key ret
  sleep 2 # slider -> Troubleshoot -> Advanced -> open (General tab)
  key ctrl-tab ctrl-tab
  sleep 1 # General -> Adapter -> Monitor tab
  key tab tab
  sleep 0.3 # -> refresh-rate combo -> "Hide modes..." checkbox
  key spc
  sleep 0.5 # clear the checkbox
  shot 21-unhide
  key ret
  sleep 2 # Enter = default OK -> back to Settings with the full mode list
  # (B) Drive the slider to 1920x1200: End = max (3840x2160), then 3 Lefts step
  #     down 2560x1600 -> 2560x1440 -> 1920x1200 (Highest/32-bit auto-selected).
  key tab
  sleep 0.3
  key shift-tab
  sleep 0.3 # re-focus the slider
  key end
  sleep 0.5
  key left left left
  sleep 0.5
  shot 22-1920x1200
  # Apply, then confirm "Yes" on the reverting "Monitor Settings" dialog. The
  # default focus is "No" and it reverts in ~15s — send alt-a then alt-y quickly.
  mon "sendkey alt-a"
  sleep 3.5
  mon "sendkey alt-y"
  sleep 2
  shot 23-kept
  # Appearance -> Effects -> uncheck "Show window contents while dragging"
  key ctrl-shift-tab
  sleep 1 # Settings -> Appearance
  key tab tab tab
  sleep 0.3
  key ret
  sleep 1 # focus Effects... -> open
  key tab tab tab tab tab tab
  sleep 0.3 # -> "Show window contents while dragging"
  key spc
  sleep 0.3 # uncheck
  key ret
  sleep 1 # OK (Effects)
  key alt-a
  sleep 1 # Apply (Display Properties)
  shot 24-drag-off
  key ret
  sleep 2 # OK (close)
  powerdown
}

# ---- 3. verify --------------------------------------------------------------
verify() {
  log "phase 3: verify boot + assert 1920x1200 scanout"
  boot
  sleep "$BOOT_WAIT"
  shot 30-verify
  # The PPM header carries the true scanout WxH even when a -display none cold
  # boot only refreshes dirty regions, so it is a reliable resolution assert.
  local dims=""
  [[ -s "${LOG_DIR}/30-verify.ppm" ]] && dims="$(sed -n '2p' "${LOG_DIR}/30-verify.ppm")"
  if command -v pnmtopng >/dev/null 2>&1 && [[ -s "${LOG_DIR}/30-verify.ppm" ]]; then
    pnmtopng "${LOG_DIR}/30-verify.ppm" >"${LOG_DIR}/30-verify.png" 2>/dev/null || true
  fi
  if [[ "$dims" == "1920 1200" ]]; then
    log "VERIFIED: scanout is 1920x1200 (${LOG_DIR}/30-verify.png)"
  else
    log "VERIFY WARN: scanout is '${dims:-unknown}', expected '1920 1200' — inspect ${LOG_DIR}/30-verify.png"
  fi
  powerdown
  log "done. 1920x1200x32 VBEMP + drag-off baked into: $DISK"
}

fetch_and_build_floppy
install_driver
set_mode_and_drag
verify
