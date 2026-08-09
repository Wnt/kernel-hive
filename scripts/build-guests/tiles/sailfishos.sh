#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/sailfishos.sh
#
# From-scratch, reproducible build of the Kernel Hive "Sailfish OS" tile (:8104).
# Runs on a fresh Proxmox host that already has the gallery infra
# (qemu-system-x86_64, qemu-img, qemu-nbd, socat, netpbm/pnmtopng).
#
# NOTE (2026-07 restructure): this is STAGE 1 of the Sailfish build chain —
# it produces the golden sailfishos.qcow2 base image. The live :8104 tile
# runs the Lipstick GUI image built by STAGE 2, sailfishos-gui.sh (Option B,
# bochs-drm KMS — the winning approach). Run both, in that order. The losing
# Option A (VirtualBox, sailfishos-vbox.sh) was deleted; see git history.
#
# GUEST : Sailfish OS 5.1.0.11 "Pispala" -- the official Sailfish SDK EMULATOR
#         image (Mer/Jolla "MerDevice"). 32-bit x86 (i486/i686), kernel
#         5.0.21-1.4.5.jolla. MBR/BIOS boot via extlinux/syslinux, single ext4
#         root partition (/dev/sda1), vesafb console at 1024x768 (vga=792).
#
# ---------------------------------------------------------------------------
# IMPORTANT -- WHAT THIS TILE ACTUALLY SHOWS, AND WHY (read before "fixing"):
#
#   The Sailfish SDK emulator is built to run under **VirtualBox**, and its
#   graphical shell (Lipstick / Wayland, the TOUCH phone UI) CANNOT render
#   under QEMU. This is a hard, structural limitation of the stock image, not
#   a mis-config. Root cause, verified on-box 2026-07-04:
#
#     1. lipstick's ONLY Qt platform plugin is `eglfs`
#        (/usr/lib/qt5/plugins/platforms/libqeglfs.so) and its only EGL device
#        integrations are `eglfs_kms` + `eglfs_kms_egldevice`. eglfs_kms needs a
#        DRM/KMS device (/dev/dri/cardN). Running lipstick by hand aborts with:
#            qt.qpa.eglfs.kms: Found the following video devices: ()
#            Could not find DRM device!   Aborted (SIGABRT)
#
#     2. The kernel has DRM/KMS drivers ONLY for vboxvideo (VirtualBox), i915
#        (real Intel HW), gma500 (Poulsbo) and udl (DisplayLink). Every
#        QEMU-emulatable GPU driver is disabled:
#            # CONFIG_DRM_BOCHS / QXL / VIRTIO_GPU / CIRRUS_QEMU / VMWGFX /
#            # AST / MGAG200  ... all "is not set"
#        So under QEMU (-vga std/qxl/virtio/vmware/...) the guest gets only
#        `vesafb` (/dev/fb0) and NO /dev/dri device -> eglfs_kms has nothing.
#        The emulator's compositor env even hard-codes the VirtualBox path:
#            /var/lib/environment/compositor/60-emul-wayland-ui.conf
#            EGL_PLATFORM=drm  QT_QPA_PLATFORM=eglfs
#            LIPSTICK_OPTIONS=-plugin VBoxTouch   (VirtualBox absolute-touch)
#
#     3. This build's Qt is 5.6.3, which PREDATES the Qt Quick software
#        renderer (added in Qt 5.8). There is no `QT_QUICK_BACKEND=software`
#        and no `linuxfb` QPA plugin installed -> there is NO non-GL fallback.
#
#   Net: to get the Lipstick GUI you must either (a) run this image under
#   VirtualBox (vboxvideo provides the KMS device), or (b) add a QEMU-drivable
#   KMS driver to the guest kernel (e.g. build & load bochs.ko for `-vga std`).
#   (b) is blocked in-place: no kernel-devel/kernel-source/Module.symvers/
#   vmlinux/build-tree is available on the device or in the Jolla repos, and
#   CONFIG_MODVERSIONS=y (so a hand-built module needs matching symbol CRCs).
#   See docs/guests/sailfish.md for the full remediation path.
#
#   THEREFORE this tile presents Sailfish OS as a LIVE, INTERACTIVE TEXT
#   CONSOLE on the framebuffer (autologin root shell showing the
#   "Sailfish OS 5.1.0.11 (Pispala)" banner) -- consistent with the gallery's
#   other console guests (Alpine, TinyCore, FreeDOS). Verified: neko keyboard
#   input reaches the shell and commands execute (id / uname rendered on the
#   framebuffer).
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT PRODUCES:
#   /data/gallery-guests/SailfishOS/sailfishos.qcow2   <- bootable tile image
#                                                          (patched for QEMU)
#   proof-*.png                                        <- framebuffer proof
#
# WHAT THIS SCRIPT DOES (end to end):
#   1. Obtain the Sailfish SDK emulator disk (qcow2). Order of preference:
#        a. reuse an existing $IMG (skip, unless SFOS_FORCE=1);
#        b. convert a local VirtualBox VDI ($SFOS_VDI) with qemu-img;
#        c. download+extract an emulator archive from $SFOS_EMULATOR_URL.
#      (The Sailfish emulator is normally obtained via the Sailfish SDK
#       installer, which fetches a VirtualBox VDI. There is no single stable
#       public direct-download URL across SDK releases, so the fetch is
#       parameterised; the PATCH+VERIFY recipe below is the reproducible core.)
#   2. PATCH the image (via qemu-nbd) for QEMU/neko operation:
#        - /boot/extlinux/extlinux.conf kernel append: add a framebuffer
#          console + quiet the kernel/audit spam:
#            console=tty0 console=ttyS0,115200n8 ... quiet loglevel=3 audit=0
#          (drops the VirtualBox-oriented `splash` + cursor-hide).
#        - install an AUTOLOGIN root getty on tty1 (the vesafb console) and on
#          ttyS0 (serial, for debugging) so the framebuffer shows an
#          interactive Sailfish shell.
#        - MASK lipstick.service (user unit -> /dev/null) so it does not
#          crash-loop (eglfs "Could not find DRM device") and burn CPU.
#   3. FRAMEBUFFER-VERIFY: boot headless under QEMU (unique VNC + monitor +
#      serial sockets), wait for the autologin shell, `screendump` a PNG, then
#      inject a keystroke via the monitor and screendump again to prove the
#      console is interactive.
#
# HYGIENE (per project rules):
#   * The verify VM is stopped ONLY via QEMU monitor `quit` (fallback: its own
#     pidfile). NEVER pkill by name. nbd is always cleanly disconnected.
#   * Namespaced work dir + unique VNC(:84)/monitor/serial sockets + VMID band.
#   * Touches ONLY /data/gallery-guests/SailfishOS. No other guest / CT / VM.
#
# ENV OVERRIDES (all optional):
#   SFOS_FORCE=1          rebuild the qcow2 even if it already exists
#   SFOS_SKIP_DOWNLOAD=1  reuse existing $IMG (never fetch/convert)
#   SFOS_VDI=/path.vdi    convert this local VirtualBox VDI -> qcow2
#   SFOS_EMULATOR_URL=... archive (7z/tar/zip) containing the emulator .vdi
#   SFOS_NO_VERIFY=1      skip the boot + framebuffer verification stage
###############################################################################
set -euo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
GUEST_KEY="sailfishos"
BASE="${SFOS_BASE:-/data/gallery-guests/SailfishOS}"
IMG="${BASE}/sailfishos.qcow2" # final bootable tile image (qcow2)

# Runtime handles (namespaced; unique to this guest; VMID band 980-989).
WORK="${SFOS_WORK:-/data/sailfish-build.$$}"
NBD="${SFOS_NBD:-/dev/nbd8}"
MNT="${WORK}/mnt"
VNC_DISPLAY="${SFOS_VNC:-84}" # -> host port 5900+84 = 5984
MON_SOCK="${WORK}/mon84.sock"
SER_SOCK="${WORK}/ser84.sock"
QEMU_LOG="${WORK}/qemu.log"
PIDFILE="${WORK}/qemu84.pid"

QEMU="${QEMU_BIN:-qemu-system-x86_64}"

log() { printf '[sfos %(%H:%M:%S)T] %s\n' -1 "$*"; }
die() {
  printf '[sfos ERROR] %s\n' "$*" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# 0. Dependency + host sanity check
# ----------------------------------------------------------------------------
check_deps() {
  local missing=()
  for b in "$QEMU" qemu-img qemu-nbd socat pnmtopng; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing tools: ${missing[*]} (install qemu-utils, socat, netpbm)"
  modprobe nbd max_part=8 2>/dev/null || true
  mkdir -p "$BASE" "$WORK" "$MNT"
}

# ----------------------------------------------------------------------------
# 1. Obtain the emulator qcow2 (reuse / convert VDI / download+extract).
# ----------------------------------------------------------------------------
fetch_image() {
  if [ -n "${SFOS_SKIP_DOWNLOAD:-}" ] && [ -s "$IMG" ]; then
    log "SFOS_SKIP_DOWNLOAD set and $IMG present -> reuse as-is"
    return 0
  fi
  if [ -s "$IMG" ] && [ -z "${SFOS_FORCE:-}" ]; then
    log "image already present ($(du -h "$IMG" | cut -f1)); skip fetch (SFOS_FORCE=1 to redo)"
    return 0
  fi

  local vdi="${SFOS_VDI:-}"
  if [ -z "$vdi" ] && [ -n "${SFOS_EMULATOR_URL:-}" ]; then
    log "downloading Sailfish emulator archive: ${SFOS_EMULATOR_URL}"
    local arc="${WORK}/emu-archive"
    curl -fSL --retry 3 -o "$arc" "$SFOS_EMULATOR_URL" || die "download failed"
    log "extracting emulator .vdi from archive"
    case "$SFOS_EMULATOR_URL" in
      *.7z)
        command -v 7z >/dev/null || die "need 7z to extract .7z (apt install p7zip-full)"
        7z x -y -o"$WORK" "$arc" >/dev/null
        ;;
      *.zip)
        command -v unzip >/dev/null || die "need unzip"
        unzip -o "$arc" -d "$WORK" >/dev/null
        ;;
      *.tar | *.tar.* | *.tgz) tar xf "$arc" -C "$WORK" ;;
      *) die "unknown archive type for $SFOS_EMULATOR_URL (expect .7z/.zip/.tar*)" ;;
    esac
    vdi="$(find "$WORK" -iname '*.vdi' -print -quit)"
    [ -n "$vdi" ] || die "no .vdi found inside emulator archive"
  fi

  [ -n "$vdi" ] || die "no image source: set SFOS_VDI=<emulator.vdi> or SFOS_EMULATOR_URL=<archive>, or stage $IMG and use SFOS_SKIP_DOWNLOAD=1. (The emulator VDI ships with the Sailfish SDK; it is a VirtualBox image.)"

  log "converting VirtualBox VDI -> qcow2: $vdi"
  qemu-img convert -p -O qcow2 "$vdi" "${IMG}.part"
  mv -f "${IMG}.part" "$IMG"
  log "image ready: $(du -h "$IMG" | cut -f1)"
}

# ----------------------------------------------------------------------------
# nbd helpers -- always disconnect cleanly.
# ----------------------------------------------------------------------------
nbd_up() {
  qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
  qemu-nbd -c "$NBD" "$IMG" || die "qemu-nbd connect failed on $NBD"
  sleep 1
  mount "${NBD}p1" "$MNT" || {
    qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
    die "mount ${NBD}p1 failed"
  }
}
nbd_down() {
  sync
  umount "$MNT" 2>/dev/null || true
  qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
# 2. Patch the image for QEMU/neko operation.
# ----------------------------------------------------------------------------
patch_image() {
  log "patching image via ${NBD}"
  nbd_up
  local M="$MNT"

  # 2a. Kernel cmdline: framebuffer console + quiet the kernel/audit spam.
  local newappend='	append ro root=/dev/sda1 video=vesafb:mtrr:3 vga=792 console=tty0 console=ttyS0,115200n8 rootfstype=ext4 quiet loglevel=3 audit=0'
  [ -f "$M/boot/extlinux/extlinux.conf" ] || {
    nbd_down
    die "extlinux.conf not found -- unexpected image layout"
  }
  sed -i "s#^\tappend .*#${newappend}#" "$M/boot/extlinux/extlinux.conf"
  log "  extlinux append: $(grep -m1 append "$M/boot/extlinux/extlinux.conf" | sed 's/^\t*//')"

  # 2b. Autologin root getty on tty1 (framebuffer) + ttyS0 (serial/debug).
  local getty
  for getty in tty1 ttyS0; do
    mkdir -p "$M/etc/systemd/system/serial-getty@${getty}.service.d" \
      "$M/etc/systemd/system/getty@${getty}.service.d"
    if [ "$getty" = "ttyS0" ]; then
      cat >"$M/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,38400,9600 %I \$TERM
EOF
    else
      cat >"$M/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF
      mkdir -p "$M/etc/systemd/system/getty.target.wants"
      ln -sf /usr/lib/systemd/system/getty@.service \
        "$M/etc/systemd/system/getty.target.wants/getty@tty1.service"
    fi
  done
  log "  autologin root getty installed on tty1 (framebuffer) + ttyS0 (serial)"

  # 2c. Mask lipstick so it does not crash-loop (no DRM device under QEMU).
  mkdir -p "$M/etc/systemd/user"
  ln -sf /dev/null "$M/etc/systemd/user/lipstick.service"
  log "  masked lipstick.service (eglfs has no DRM device under QEMU)"

  nbd_down
  log "patch complete"
}

# ----------------------------------------------------------------------------
# QEMU monitor helper (HMP over unix socket) -- kill/screendump/sendkey.
# ----------------------------------------------------------------------------
mon() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }
is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
stop_vm() {
  if is_running; then
    log "stopping verify VM (monitor quit) pid $(cat "$PIDFILE")"
    mon "quit"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      is_running || break
      sleep 1
    done
    is_running && {
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      sleep 2
    }
  fi
  rm -f "$PIDFILE" "$MON_SOCK" "$SER_SOCK"
}

snap() { # screendump framebuffer -> PNG; echoes the path
  local name="$1" ppm="${BASE}/$1.ppm" png="${BASE}/$1.png"
  rm -f "$ppm" "$png"
  mon "screendump ${ppm}"
  sleep 1
  [ -s "$ppm" ] && {
    pnmtopng "$ppm" >"$png" 2>/dev/null || true
    rm -f "$ppm"
    printf '%s' "$png"
  }
}

# ----------------------------------------------------------------------------
# 3. Boot headless + framebuffer-verify the interactive console.
#    This is the EXACT arg shape the neko tile runs (see print_gallery_args).
# ----------------------------------------------------------------------------
verify_gui() {
  stop_vm
  rm -f "$QEMU_LOG"
  log "booting verify VM (vnc :${VNC_DISPLAY}, monitor ${MON_SOCK})"
  "$QEMU" \
    -accel kvm -machine pc -cpu host -m 1536 -smp 2 \
    -drive "file=${IMG},format=qcow2,if=ide,snapshot=on" \
    -vga std \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
    -netdev user,id=n0 -device e1000,netdev=n0 \
    -rtc base=localtime \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "unix:${SER_SOCK},server,nowait" \
    -pidfile "$PIDFILE" \
    -name "Sailfish OS" \
    >"$QEMU_LOG" 2>&1 &
  echo $! >"$PIDFILE"
  log "started pid $(cat "$PIDFILE"); waiting for autologin shell (~45s)"

  local f="" i
  for i in $(seq 1 18); do
    sleep 5
    f="$(snap "proof-1-console")"
    # A rendered text console PNG is a few KB; a blank frame is ~200 bytes.
    if [ -n "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -ge 3000 ]; then
      log "console rendered after ~$((i * 5))s: $f ($(stat -c%s "$f") bytes)"
      break
    fi
    f=""
  done
  [ -n "$f" ] || {
    stop_vm
    die "no framebuffer console within timeout"
  }

  # Prove interactivity: type a command via the monitor's usb-kbd, screendump.
  log "injecting keystrokes (uname -m) to prove the console is interactive"
  local k
  for k in u n a m e spc minus m ret; do
    mon "sendkey $k"
    sleep 0.15
  done
  sleep 1.5
  local g
  g="$(snap "proof-2-console-input")"
  [ -n "$g" ] && log "post-input framebuffer: $g ($(stat -c%s "$g") bytes)"
  log "framebuffer proofs under $BASE (proof-1-console.png, proof-2-console-input.png)"
  stop_vm
}

# ----------------------------------------------------------------------------
# neko-qemu / gallery tile args (emitted for reference; wired via the manifest
# row in docs/guests/sailfish.md). NO OVMF (BIOS/syslinux), NO
# launch-qemu.sh change -- only stock env vars are used.
# ----------------------------------------------------------------------------
print_gallery_args() {
  cat <<'EOF'

# ============================================================================
# neko-qemu gallery TILE (Sailfish OS :8104) -- container-correct env.
# Uses ONLY existing launch-qemu.sh env vars; no OVMF, no launch-qemu edit.
# ============================================================================
#   OS_NAME=Sailfish OS
#   QEMU_MEM=1536  QEMU_SMP=2  QEMU_MACHINE=pc  QEMU_VGA=std
#   GUEST_DISK=/guests/SailfishOS/sailfishos.qcow2  GUEST_FMT=qcow2
#   GUEST_IF=ide   GUEST_BOOT=c
#   QEMU_EXTRA=-enable-kvm -cpu host \
#              -device qemu-xhci,id=xhci \
#              -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
#              -netdev user,id=n0 -device e1000,netdev=n0 -snapshot
#   NEKO_EPR=53280-53299   (host port 8104)
# usb-tablet = absolute pointer; usb-kbd -> the tty1 autologin shell.
# -snapshot keeps the read-only golden qcow2 pristine (ephemeral sessions).
# ============================================================================
EOF
}

# ----------------------------------------------------------------------------
cleanup() {
  nbd_down
  is_running && stop_vm || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

main() {
  check_deps
  fetch_image
  patch_image
  if [ -z "${SFOS_NO_VERIFY:-}" ]; then verify_gui; else log "SFOS_NO_VERIFY -> skip boot verify"; fi
  print_gallery_args
  log "DONE. Bootable tile image: $IMG"
}
main "$@"
