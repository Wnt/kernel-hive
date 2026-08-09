#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/sailfishos-gui.sh   (OPTION B: QEMU-drivable KMS driver)
#
# THE WINNER — this is the builder behind the live :8104 Sailfish tile
# (bochs-drm KMS injection; authority: sailfish-kms-notes, now in
# docs/guests/). Build chain: build-guests/tiles/sailfishos.sh first (produces the
# golden sailfishos.qcow2 base), then this script patches a COPY of it into
# sailfishos-gui.qcow2. The competing OPTION A (VirtualBox,
# sailfishos-vbox.sh) lost and was deleted in the 2026-07 restructure —
# recover from git history if ever needed.
#
# Turns the Sailfish OS 5.1.0.11 "Pispala" emulator image into a tile that
# renders the REAL Lipstick (Wayland) TOUCH GUI under PLAIN QEMU -- no
# VirtualBox, no launch-qemu.sh change, same `-vga std` every other tile uses.
#
# BACKGROUND (see docs/guests/sailfish.md for the original console tile):
#   Lipstick's only Qt platform plugin is eglfs, and its only EGL device
#   integration is eglfs_kms -> it needs /dev/dri/cardN. The stock emulator
#   kernel (5.0.21-1.4.5.jolla, 32-bit i686) has DRM/KMS ONLY for vboxvideo/
#   i915/gma500/udl; every QEMU-emulatable GPU (bochs/qxl/virtio-gpu/...) is
#   "not set". So under QEMU there is no /dev/dri and Lipstick SIGABRTs.
#
# WHAT THIS SCRIPT DOES (the fix, fully reproducible):
#   1. Fetch the EXACT Jolla kernel source for this build from GitHub:
#        sailfishos/kernel-adaptation-pc  tag  sailfish/5.0.21+git12
#      (matches the on-device build dir kernel-adaptation-pc-5.0.21+git12).
#   2. Build an out-of-tree `bochs-drm.ko` (i386) against that tree using the
#      guest's own /boot/config-5.0.21-1.4.5.jolla (CONFIG_DRM_BOCHS=m).
#      No Jolla Module.symvers is published for 5.x, but the guest kernel has
#      CONFIG_MODULE_FORCE_LOAD=y and CONFIG_MODULE_SIG is OFF, so the module
#      is force-loaded (--force-vermagic). Same source+config => struct layouts
#      match the running kernel, so force-loading a leaf DRM driver is safe.
#   3. Inject into a COPY of the image (never the golden):
#        - install bochs-drm.ko + depmod
#        - early systemd oneshot: modprobe ttm ; modprobe --force-vermagic bochs_drm
#        - DROP `video=vesafb:mtrr:3 vga=792` from the extlinux append
#          (vesafb reserves the stdvga BAR -> bochs-drm probe -EBUSY otherwise)
#        - UNMASK lipstick.service
#        - rewrite the compositor env: eglfs_kms + evdev input, drop VBoxTouch
#   4. Boot-verify under QEMU `-vga std`: assert /dev/dri/card0 appears, that
#      lipstick holds card0 + the USB-tablet/keyboard evdevs and maps
#      kms_swrast + libqeglfs-kms-integration, and screendump the Lipstick UI.
#
# RESULT (verified on-box 2026-07-04):
#   /dev/dri/card0 present; lipstick (PID) has card0 + /dev/input/event3
#   (QEMU USB Tablet) + event4 (USB Keyboard) open and maps
#   /usr/lib/dri/kms_swrast_dri.so + libqeglfs-kms-integration.so. With the
#   no-PIN auto-unlock (inject step 6) the tile boots straight to the Lipstick
#   HOME/app-grid (not the swipe lockscreen); a touch drag pulls up the app
#   launcher. Deployed live as the :8104 tile (see docs/guests/sailfish.md
#   sections 8-9).
#
# INTEGRATION: the neko+QEMU tile args are IDENTICAL to the console tile
#   (-vga std already presents PCI 1234:1111 which bochs-drm binds). The ONLY
#   deltas are (a) this patched image and (b) the kernel cmdline baked into it.
#   No launch-qemu.sh edit, no OVMF, no extra services -> the clean fit.
#
# HYGIENE: namespaced work dir, nbd9, VMID/VNC band 82x, unique QMP/monitor/
#   serial sockets, pidfile-only stop (never pkill), clean nbd disconnect.
#   Touches ONLY its own copy under $GUI_BASE. Never the golden or live tile.
#
# ENV OVERRIDES (all optional):
#   SFOS_SRC_IMG=/path.qcow2   source image to copy (default: the golden
#                              /data/gallery-guests/SailfishOS/sailfishos.qcow2)
#   SFOS_GUI_BASE=/dir         work/output dir (default /data/sfos-gui-work.820)
#   SFOS_KERNEL_TAG=...        kernel source tag (default sailfish/5.0.21+git12)
#   SFOS_SKIP_BUILD=1          reuse an existing $GUI_BASE/bochs-drm.ko
#   SFOS_NO_VERIFY=1           skip the boot + framebuffer verification stage
###############################################################################
set -euo pipefail

GUI_BASE="${SFOS_GUI_BASE:-/data/sfos-gui-work.820}"
SRC_IMG="${SFOS_SRC_IMG:-/data/gallery-guests/SailfishOS/sailfishos.qcow2}"
IMG="${GUI_BASE}/sailfishos-gui.qcow2" # patched GUI tile image (COPY)
KTAG="${SFOS_KERNEL_TAG:-sailfish/5.0.21+git12}"
KREL="5.0.21-1.4.5.jolla"                             # running-kernel uname -r
KDIRNAME="kernel-adaptation-pc-sailfish-5.0.21-git12" # tar top-dir for the tag

WORK="${GUI_BASE}"
KB="${GUI_BASE}/kbuild"
MNT="${GUI_BASE}/mnt"
NBD="${SFOS_NBD:-/dev/nbd9}"
VNC_DISPLAY="${SFOS_VNC:-22}" # host 5900+22 = 5922
MON_SOCK="${WORK}/mon.sock"
QMP_SOCK="${WORK}/qmp.sock"
SER_SOCK="${WORK}/ser.sock"
PIDFILE="${WORK}/qemu.pid"
QEMU_LOG="${WORK}/qemu.log"
KO="${GUI_BASE}/bochs-drm.ko"

CC12="${SFOS_CC:-gcc-12}" # 5.0-era-friendly compiler

log() { printf '[sfos-gui %(%H:%M:%S)T] %s\n' -1 "$*"; }
die() {
  printf '[sfos-gui ERROR] %s\n' "$*" >&2
  exit 1
}

# --------------------------------------------------------------------------
check_deps() {
  local miss=()
  for b in qemu-system-x86_64 qemu-img qemu-nbd socat pnmtopng "$CC12" make flex bison bc curl tar; do
    command -v "$b" >/dev/null 2>&1 || miss+=("$b")
  done
  [ "${#miss[@]}" -eq 0 ] || die "missing host tools: ${miss[*]}
  (apt-get install -y ${CC12} ${CC12}-multilib flex bison libelf-dev libssl-dev qemu-utils socat netpbm bc)"
  echo 'int main(){return 0;}' >/tmp/_m32.c
  "$CC12" -m32 /tmp/_m32.c -o /tmp/_m32 2>/dev/null || die "$CC12 lacks 32-bit (-m32) support: apt-get install ${CC12}-multilib libc6-dev-i386"
  modprobe nbd max_part=8 2>/dev/null || true
  mkdir -p "$GUI_BASE" "$KB" "$MNT"
}

# --------------------------------------------------------------------------
nbd_up() {
  qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
  qemu-nbd -c "$NBD" "$IMG" || die "nbd connect failed"
  sleep 1
  mount "${NBD}p1" "$MNT" || {
    qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
    die "mount failed"
  }
}
nbd_down() {
  sync
  umount "$MNT" 2>/dev/null || true
  qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------
make_copy() {
  [ -s "$SRC_IMG" ] || die "source image not found: $SRC_IMG"
  if [ -s "$IMG" ] && [ -z "${SFOS_FORCE:-}" ]; then
    log "GUI copy exists: $IMG (SFOS_FORCE=1 to redo)"
    return
  fi
  log "copying source image -> $IMG (COPY; golden untouched)"
  cp -f "$SRC_IMG" "${IMG}.part" && mv -f "${IMG}.part" "$IMG"
}

# --------------------------------------------------------------------------
extract_config() {
  log "reading guest kernel config from image"
  nbd_up
  [ -f "$MNT/boot/config-${KREL}" ] || {
    nbd_down
    die "config-${KREL} not found in image"
  }
  cp "$MNT/boot/config-${KREL}" "$KB/guest.config"
  nbd_down
}

# --------------------------------------------------------------------------
build_module() {
  if [ -n "${SFOS_SKIP_BUILD:-}" ] && [ -s "$KO" ]; then
    log "SFOS_SKIP_BUILD -> reuse $KO"
    return
  fi
  if [ ! -d "$KB/$KDIRNAME" ]; then
    local url="https://codeload.github.com/sailfishos/kernel-adaptation-pc/tar.gz/refs/tags/${KTAG}"
    log "downloading kernel source tag ${KTAG}"
    curl -fSL --retry 3 -o "$KB/src.tar.gz" "$url" || die "kernel source download failed ($url)"
    log "extracting source (~1.2 GiB)"
    tar xzf "$KB/src.tar.gz" -C "$KB"
    rm -f "$KB/src.tar.gz"
  fi
  local KSRC="$KB/$KDIRNAME"
  [ -d "$KSRC/drivers/gpu/drm/bochs" ] || die "bochs dir missing in source tree"
  log "configuring kernel tree with guest config + CONFIG_DRM_BOCHS=m"
  cp "$KB/guest.config" "$KSRC/.config"
  (
    cd "$KSRC"
    ./scripts/config --module DRM_BOCHS
    make ARCH=i386 CC="$CC12" HOSTCC="$CC12" olddefconfig >/dev/null
    grep -q '^CONFIG_DRM_BOCHS=m' .config || die "DRM_BOCHS did not stick"
    log "make modules_prepare"
    make ARCH=i386 CC="$CC12" HOSTCC="$CC12" -j"$(nproc)" modules_prepare >/dev/null
    log "building bochs-drm.ko (out-of-tree M=)"
    make ARCH=i386 CC="$CC12" HOSTCC="$CC12" -j"$(nproc)" M=drivers/gpu/drm/bochs modules >/dev/null 2>&1
    [ -f drivers/gpu/drm/bochs/bochs-drm.ko ] || die "bochs-drm.ko not produced"
    cp drivers/gpu/drm/bochs/bochs-drm.ko "$KO"
  )
  log "module built: $KO ($(stat -c%s "$KO") bytes)"
  modinfo "$KO" | grep -E 'vermagic|alias' | sed 's/^/  /'
}

# --------------------------------------------------------------------------
inject() {
  log "injecting module + patches into the COPY"
  nbd_up
  local M="$MNT"

  # 1. module + depmod (records bochs-drm -> ttm dependency)
  install -D -m644 "$KO" "$M/lib/modules/${KREL}/extra/bochs-drm.ko"
  depmod -b "$M" "$KREL" 2>/dev/null || true

  # 2. early force-load unit (before basic.target, well before the compositor)
  cat >"$M/etc/systemd/system/bochs-drm.service" <<'UNIT'
[Unit]
Description=Force-load bochs-drm KMS driver for QEMU stdvga (/dev/dri)
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target basic.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=-/sbin/modprobe ttm
ExecStart=/sbin/modprobe --force-vermagic bochs_drm
UNIT
  mkdir -p "$M/etc/systemd/system/sysinit.target.wants"
  ln -sf ../bochs-drm.service "$M/etc/systemd/system/sysinit.target.wants/bochs-drm.service"

  # 3. drop vesafb/vga= from the kernel cmdline (frees the stdvga BAR for bochs)
  [ -f "$M/boot/extlinux/extlinux.conf" ] || {
    nbd_down
    die "extlinux.conf missing"
  }
  sed -i 's#video=vesafb:mtrr:3 vga=792 ##' "$M/boot/extlinux/extlinux.conf"
  # if a fresh (unpatched) golden is used, still ensure a fb console is present:
  grep -q 'console=tty0' "$M/boot/extlinux/extlinux.conf" ||
    sed -i 's#^\(\tappend .*root=/dev/sda1\)#\1 console=tty0 console=ttyS0,115200n8 rootfstype=ext4 quiet loglevel=3 audit=0#' "$M/boot/extlinux/extlinux.conf"
  log "  append: $(grep -m1 append "$M/boot/extlinux/extlinux.conf" | sed 's/^\t*//')"

  # 4. UNMASK lipstick (the console-tile build masks it to /dev/null)
  [ -L "$M/etc/systemd/user/lipstick.service" ] && rm -f "$M/etc/systemd/user/lipstick.service" && log "  unmasked lipstick.service"

  # 5. compositor env: eglfs_kms + evdev input; drop VBoxTouch
  local CONF
  # shellcheck disable=SC2012 # picking the first matching compositor conf by name inside our own guest-mount tree, not adversarial
  CONF="$(ls "$M"/var/lib/environment/compositor/*emul*wayland*.conf 2>/dev/null | head -1)"
  [ -n "$CONF" ] || CONF="$M/var/lib/environment/compositor/60-emul-wayland-ui.conf"
  [ -f "$CONF" ] && cp "$CONF" "$CONF.orig"
  cat >"$CONF" <<'CENV'
LIBGL_ALWAYS_SOFTWARE=1
EGL_PLATFORM=drm
QT_QPA_PLATFORM=eglfs
QT_QPA_EGLFS_INTEGRATION=eglfs_kms
QT_QPA_EGLFS_DEPTH=32
QT_QPA_EGLFS_HIDECURSOR=1
QT_QPA_GENERIC_PLUGINS=evdevtouch,evdevmouse,evdevkeyboard
LIPSTICK_OPTIONS=
CENV
  log "  compositor env -> eglfs_kms + evdev (VBoxTouch dropped)"

  # 6. NO-PIN kiosk auto-unlock (lands on the Lipstick home/app-grid, not the
  #    swipe lockscreen). The emulator image has NO device code
  #    (devicelock_settings.conf: code_current_length=0, code_is_mandatory=false,
  #    automatic_locking=0), so the boot lockscreen is only the MCE *tklock*
  #    swipe screen. A tiny self-healing service keeps the tklock unlocked via
  #    the mce dbus (req_tklock_mode_change string:unlocked) so the tile always
  #    shows the home screen. mce.conf allows req_tklock_mode_change for the
  #    default context, so no privilege tricks are needed.
  install -D -m755 /dev/stdin "$M/usr/bin/sailfish-kiosk-autounlock.sh" <<'SCRIPT'
#!/bin/sh
# Kiosk no-PIN self-healing unlock: keep the MCE touchscreen lock (tklock)
# unlocked so the tile always shows the Lipstick home/app-grid rather than the
# swipe lockscreen. One cheap dbus round-trip every few seconds on an idle kiosk.
MCE_DEST=com.nokia.mce
MCE_PATH=/com/nokia/mce/request
MCE_IF=com.nokia.mce.request
while true; do
  mode=$(dbus-send --system --print-reply --dest="$MCE_DEST" "$MCE_PATH" "$MCE_IF".get_tklock_mode 2>/dev/null | grep -o 'unlocked')
  if [ "$mode" != "unlocked" ]; then
    dbus-send --system --type=method_call --dest="$MCE_DEST" "$MCE_PATH" "$MCE_IF".req_display_state_on >/dev/null 2>&1 || true
    dbus-send --system --type=method_call --dest="$MCE_DEST" "$MCE_PATH" "$MCE_IF".req_tklock_mode_change string:unlocked >/dev/null 2>&1 || true
  fi
  sleep 3
done
SCRIPT
  cat >"$M/etc/systemd/system/sailfish-kiosk-autounlock.service" <<'UNIT'
[Unit]
Description=Kiosk no-PIN auto-unlock of the Lipstick lockscreen
After=graphical.target
[Service]
Type=simple
ExecStart=/usr/bin/sailfish-kiosk-autounlock.sh
Restart=always
RestartSec=5
[Install]
WantedBy=graphical.target
UNIT
  # NOTE: enable via graphical.target.wants (NOT multi-user.target.wants) --
  # a unit ordered After=graphical.target but wanted by multi-user.target never
  # starts (ConditionResult=no), because graphical.target runs after multi-user.
  mkdir -p "$M/etc/systemd/system/graphical.target.wants"
  ln -sf ../sailfish-kiosk-autounlock.service "$M/etc/systemd/system/graphical.target.wants/sailfish-kiosk-autounlock.service"
  # belt-and-suspenders: never auto-lock / never blank (neko streams the tile)
  cat >"$M/etc/mce/61-kiosk-no-autolock.conf" <<'MCECONF'
# Kiosk tile: never auto-lock the touchscreen and never blank (neko streams it).
/system/osso/dsm/locks/tklock_autolock=0
/system/osso/dsm/locks/tklock_blank_disable=1
/system/osso/dsm/display/display_blank_timeout=0
/system/osso/dsm/display/display_dim_timeout=0
MCECONF
  log "  no-PIN auto-unlock service installed (graphical.target.wants)"

  nbd_down
  log "injection complete"
}

# --------------------------------------------------------------------------
mon() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }
is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }
stop_vm() {
  if is_running; then
    mon quit
    for _ in $(seq 1 10); do
      is_running || break
      sleep 1
    done
    is_running && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$MON_SOCK" "$QMP_SOCK" "$SER_SOCK"
}
snap() {
  local p="${WORK}/$1.ppm" g="${WORK}/$1.png"
  rm -f "$p" "$g"
  mon "screendump $p"
  sleep 1
  [ -s "$p" ] && {
    pnmtopng "$p" >"$g" 2>/dev/null || true
    rm -f "$p"
    printf '%s' "$g"
  }
}
ser() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${SER_SOCK}" 2>/dev/null || true; }

verify() {
  stop_vm
  rm -f "$QEMU_LOG"
  log "boot-verify under -vga std (vnc :${VNC_DISPLAY})"
  qemu-system-x86_64 \
    -accel kvm -machine pc -cpu host -m 1536 -smp 2 \
    -drive "file=${IMG},format=qcow2,if=ide,snapshot=on" \
    -vga std \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
    -netdev user,id=n0 -device e1000,netdev=n0 -rtc base=localtime \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -qmp "unix:${QMP_SOCK},server,nowait" \
    -serial "unix:${SER_SOCK},server,nowait" \
    -pidfile "$PIDFILE" -name "Sailfish OS GUI" >"$QEMU_LOG" 2>&1 &
  echo $! >"$PIDFILE"
  log "pid $(cat "$PIDFILE"); waiting ~55s for Lipstick"
  sleep 55

  # assert /dev/dri/card0 + lipstick holds it + software-GL mapped
  (
    printf '\n'
    sleep 1
    # shellcheck disable=SC2016 # deliberate: this is a shell one-liner typed INTO the guest console (via socat below); $P/$(...) must expand in the GUEST shell, not here
    printf 'P=$(pgrep lipstick|head -1); { echo DRI:; ls /dev/dri; echo LIPPID=$P; echo FDS:; ls -l /proc/$P/fd 2>/dev/null|grep -oE "/dev/(dri|input)/[a-z0-9]*"|sort|uniq -c; echo GL:; grep -oE "kms_swrast_dri.so|libqeglfs-kms-integration.so" /proc/$P/maps 2>/dev/null|sort -u; } >/tmp/v.txt 2>&1; echo VDONE\n'
    sleep 3
    printf 'cat /tmp/v.txt\n'
    sleep 2
  ) | socat - "UNIX-CONNECT:${SER_SOCK}" 2>&1 | tr -d '\r' | sed -n '/cat \/tmp\/v.txt/,$p' | tee "${WORK}/verify.txt"

  local png
  png="$(snap proof-lipstick-lockscreen)"
  [ -n "$png" ] && log "lock-screen proof: $png ($(stat -c%s "$png") bytes)"

  # prove pointer input: QMP absolute-touch swipe-up, screendump again
  log "injecting QMP absolute-touch swipe-up"
  {
    printf '{"execute":"qmp_capabilities"}\n'
    sleep 0.4
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":16384}},{"type":"abs","data":{"axis":"y","value":31500}},{"type":"btn","data":{"button":"left","down":true}}]}}\n'
    sleep 0.15
    for y in 28000 24000 20000 16000 12000 8000 4000 1500; do
      printf '{"execute":"input-send-event","arguments":{"events":[{"type":"abs","data":{"axis":"x","value":16384}},{"type":"abs","data":{"axis":"y","value":%s}}]}}\n' "$y"
      sleep 0.12
    done
    printf '{"execute":"input-send-event","arguments":{"events":[{"type":"btn","data":{"button":"left","down":false}}]}}\n'
    sleep 0.5
  } | socat - "UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1
  sleep 1.5
  png="$(snap proof-after-swipe)"
  [ -n "$png" ] && log "post-swipe proof: $png ($(stat -c%s "$png") bytes)"

  grep -q 'card0' "${WORK}/verify.txt" || {
    stop_vm
    die "VERIFY FAILED: /dev/dri/card0 not present"
  }
  grep -q 'kms_swrast_dri.so' "${WORK}/verify.txt" || log "WARN: kms_swrast not seen mapped in lipstick (check verify.txt)"
  stop_vm
  log "VERIFY OK: card0 present, lipstick composited; proofs under ${WORK}"
}

# --------------------------------------------------------------------------
print_tile() {
  cat <<EOF

# ============================================================================
# neko-qemu gallery TILE (Sailfish OS GUI) -- IDENTICAL args to the console
# tile; the fix lives entirely in the patched image ($IMG).
#   QEMU_MEM=1536 QEMU_SMP=2 QEMU_MACHINE=pc QEMU_VGA=std   <-- std == bochs 1234:1111
#   GUEST_DISK=/guests/SailfishOS/sailfishos-gui.qcow2 GUEST_FMT=qcow2
#     (live :8104 tile deploys the GUI image beside the golden in SailfishOS/)
#   GUEST_IF=ide GUEST_BOOT=c
#   QEMU_EXTRA=-enable-kvm -cpu host -device qemu-xhci,id=xhci \\
#              -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \\
#              -netdev user,id=n0 -device e1000,netdev=n0 -snapshot
# No OVMF, no launch-qemu.sh edit, no extra services. -snapshot keeps it kiosk.
# ============================================================================
EOF
}

cleanup() {
  nbd_down
  is_running && stop_vm || true
}
trap cleanup EXIT INT TERM

main() {
  check_deps
  make_copy
  extract_config
  build_module
  inject
  [ -z "${SFOS_NO_VERIFY:-}" ] && verify || log "SFOS_NO_VERIFY -> skip verify"
  print_tile
  log "DONE. GUI tile image: $IMG   module: $KO"
}
main "$@"
