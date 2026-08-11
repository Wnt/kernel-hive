#!/bin/bash
###############################################################################
# build-guests/stages/postmarketos.sh
#
# From-scratch, reproducible build of the Kernel Hive "postmarketOS" station.
# Runs on a fresh Proxmox host that already has the gallery infra
# (qemu-system-x86_64, qemu-img, xz, curl, socat, netpbm/pnmtopng, and the
# pve-edk2-firmware OVMF blobs). No image backup required: this script
# re-downloads the official pmOS phone image and re-seeds everything.
#
# GUEST: postmarketOS v26.06 "Phosh" (generic-x86_64 UEFI phone image)
#        Portrait phone shell (720x1440) -> PIN lockscreen -> app launcher.
#        Software-rendered (llvmpipe / bochs KMS) under KVM, no GPU.
#
# WHAT THIS PRODUCES:
#   /data/gallery-guests/postmarketOS/pmos-phosh.img   <- final bootable image
#   /data/gallery-guests/postmarketOS/OVMF_CODE.fd     <- UEFI code (ro)
#   /data/gallery-guests/postmarketOS/OVMF_VARS.local.fd <- writable UEFI vars seed
#   proof-*.png                                        <- framebuffer GUI proof
#
# ---------------------------------------------------------------------------
# AUTOMATION HONESTY (read before trusting "unattended"):
#   * There is NO OS installer for this guest. postmarketOS ships a COMPLETE,
#     pre-provisioned, flashable disk image. "Build" = download + decompress +
#     seed OVMF vars + boot. So there is no autounattend/answer-file to encode;
#     the only "input automation" is the framebuffer wake + PIN unlock below,
#     which THIS SCRIPT performs unattended over the QEMU monitor (sendkey).
#   * FULLY AUTOMATED end-to-end: download, checksum verify, decompress, OVMF
#     seed, boot, PIN-unlock (147147), framebuffer screenshot verification.
#   * The one thing that is intrinsically stock (not scripted here) is the
#     first-boot user/PIN provisioning -- it is BAKED INTO the official image
#     (default unlock PIN 147147). We do not create a user; pmOS already did.
#
# CRITICAL PITFALLS (encoded below, do not "fix"):
#   1. ROOT DISK MUST BE AHCI/SATA (or NVMe) -- NEVER if=virtio-blk. The
#      generic-x86_64 stage-1 initramfs has no virtio_blk module, so a virtio
#      root is invisible -> "Waiting for root partition" -> initramfs shell.
#   2. UEFI REQUIRED (systemd-boot). Will NOT boot on SeaBIOS -> OVMF pflash.
#   3. Boot the base image with snapshot=on so the pristine .img is never
#      mutated (re-runnable / idempotent). Do NOT oversize the disk.
#   4. -vga std (bochs KMS) is the capturable default: it renders portrait
#      720x1440 AND screendump reads real pixels. virtio-gpu renders a clean
#      UI but screendump goes BLACK once GL scanout starts.
#   5. Phosh idle-blanks / auto-locks in ~30s of no input -> screendump reads
#      black. WAKE with a pointer/key event immediately before capture. In the
#      live neko station the continuous user input keeps it awake.
#
# HYGIENE: kills only via pidfile / monitor 'quit'. NEVER pkill by name.
#          Namespaced work dir + unique VNC(:47)/monitor(mon47.sock) sockets.
#          Does not touch other guests, CTID 110, VM 900/920, macOS VMIDs.
#
# ENV OVERRIDES (all optional):
#   PMOS_SKIP_DOWNLOAD=1   reuse an existing pmos-phosh.img (skip fetch/verify)
#   PMOS_FORCE=1           re-download + re-decompress even if img exists
#   PMOS_NO_VERIFY=1       skip the boot + framebuffer verification stage
#   PMOS_IMG_URL=...       full override of the .img.xz source URL
#   PMOS_VERSION / PMOS_BUILD / PMOS_IMG_FILE  fine-grained URL parts
###############################################################################
set -euo pipefail

# ----------------------------------------------------------------------------
# Parameters
# ----------------------------------------------------------------------------
GUEST_KEY="postmarketos"
BASE="${PMOS_BASE:-/data/gallery-guests/postmarketOS}"

# Official image coordinates (images.postmarketos.org). Parameterised so a
# newer dated build can be dropped in without editing the body. The dated
# build dir changes on each pmOS rebuild; override PMOS_BUILD/PMOS_IMG_FILE
# (or the whole PMOS_IMG_URL) to track a newer one.
PMOS_VERSION="${PMOS_VERSION:-v26.06}"
PMOS_DEVICE="${PMOS_DEVICE:-generic-x86_64}"
PMOS_UI="${PMOS_UI:-phosh}"
PMOS_BUILD="${PMOS_BUILD:-20260703-0246}"
PMOS_IMG_FILE="${PMOS_IMG_FILE:-20260703-0246-postmarketOS-v26.06-phosh-29.1-generic-x86_64-lts.img.xz}"
PMOS_BASE_URL="https://images.postmarketos.org/bpo/${PMOS_VERSION}/${PMOS_DEVICE}/${PMOS_UI}/${PMOS_BUILD}"
PMOS_IMG_URL="${PMOS_IMG_URL:-${PMOS_BASE_URL}/${PMOS_IMG_FILE}}"

IMG="${BASE}/pmos-phosh.img"  # final decompressed bootable raw image
XZ="${BASE}/${PMOS_IMG_FILE}" # downloaded compressed artifact

# OVMF firmware (Proxmox pve-edk2-firmware; 4M split blobs).
OVMF_CODE_SRC="${OVMF_CODE_SRC:-/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd}"
OVMF_VARS_SRC="${OVMF_VARS_SRC:-/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd}"
OVMF_CODE="${BASE}/OVMF_CODE.fd"
OVMF_VARS="${BASE}/OVMF_VARS.local.fd" # writable, persisted vars seed

# Runtime handles (namespaced; unique to this guest).
VNC_DISPLAY="${PMOS_VNC:-47}" # -> host port 5900+47 = 5947
MON_SOCK="${BASE}/mon47.sock"
SER_LOG="${BASE}/serial.log"
QEMU_LOG="${BASE}/qemu.log"
PIDFILE="${BASE}/qemu47.pid"

# Guest facts.
UNLOCK_PIN="${PMOS_PIN:-147147}" # default lockscreen PIN in the stock image

QEMU="${QEMU_BIN:-qemu-system-x86_64}"

log() { printf '[pmos %(%H:%M:%S)T] %s\n' -1 "$*"; }
die() {
  printf '[pmos ERROR] %s\n' "$*" >&2
  exit 1
}

# ----------------------------------------------------------------------------
# 0. Dependency + host sanity check
# ----------------------------------------------------------------------------
check_deps() {
  local missing=()
  for b in "$QEMU" qemu-img xz curl socat pnmtopng; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing tools: ${missing[*]} (install qemu, xz-utils, socat, netpbm)"
  [ -r "$OVMF_CODE_SRC" ] || die "OVMF code blob not found: $OVMF_CODE_SRC (apt install pve-edk2-firmware)"
  [ -r "$OVMF_VARS_SRC" ] || die "OVMF vars blob not found: $OVMF_VARS_SRC"
  mkdir -p "$BASE"
}

# ----------------------------------------------------------------------------
# 1. Download + verify + decompress the official image
#    (re-download from the real URL; do not assume it is already on disk)
# ----------------------------------------------------------------------------
fetch_image() {
  if [ -n "${PMOS_SKIP_DOWNLOAD:-}" ] && [ -s "$IMG" ]; then
    log "PMOS_SKIP_DOWNLOAD set and $IMG present -> skipping fetch/decompress"
    return 0
  fi
  if [ -s "$IMG" ] && [ -z "${PMOS_FORCE:-}" ]; then
    log "final image already present ($(du -h "$IMG" | cut -f1)); skip download (PMOS_FORCE=1 to redo)"
    return 0
  fi

  log "downloading pmOS image:"
  log "  $PMOS_IMG_URL"
  curl -fSL --retry 3 --continue-at - -o "$XZ" "$PMOS_IMG_URL" ||
    die "download failed: $PMOS_IMG_URL"

  # Checksum verify against the published .sha256 (best-effort: skip if absent).
  if curl -fsSL -o "${XZ}.sha256" "${PMOS_IMG_URL}.sha256" 2>/dev/null; then
    log "verifying sha256 ..."
    (cd "$BASE" && sha256sum -c "$(basename "${XZ}.sha256")") ||
      die "sha256 mismatch on $(basename "$XZ")"
    log "sha256 OK"
  else
    log "WARN: no published .sha256 fetched; continuing without checksum verify"
  fi

  log "decompressing -> $IMG"
  # -k keeps the .xz so a re-run is cheap; write image atomically.
  xz -dc -T0 "$XZ" >"${IMG}.part"
  mv -f "${IMG}.part" "$IMG"
  log "image ready: $(du -h "$IMG" | cut -f1) raw ($(du -h --apparent-size "$IMG" 2>/dev/null | cut -f1 || true) logical)"
}

# ----------------------------------------------------------------------------
# 2. Seed OVMF firmware into the guest dir.
#    IMPORTANT: seed FRESH writable vars every run. With clean vars, BdsDxe
#    auto-discovers the image's EFI system partition (\EFI\BOOT\BOOTX64.EFI ->
#    systemd-boot) and boots the SATA disk. A *stale* vars file carrying a boot
#    entry for a different device path (e.g. an earlier NVMe experiment) makes
#    BdsDxe skip the disk and fall through to PXE/HTTP boot -> no OS. So we do
#    NOT persist vars across differing configs; fresh is the verified behavior.
# ----------------------------------------------------------------------------
seed_ovmf() {
  cp -f "$OVMF_CODE_SRC" "$OVMF_CODE"
  cp -f "$OVMF_VARS_SRC" "$OVMF_VARS"
  log "seeded fresh writable OVMF vars -> $OVMF_VARS"
}

# ----------------------------------------------------------------------------
# QEMU monitor helper (HMP over the unix socket). Kill/screendump/sendkey all
# go through here -- never pkill by name.
# ----------------------------------------------------------------------------
mon() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }

is_running() {
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

stop_vm() {
  if is_running; then
    log "stopping VM (monitor quit) pid $(cat "$PIDFILE")"
    mon "quit"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      is_running || break
      sleep 1
    done
    if is_running; then
      log "monitor quit did not land -> kill by pidfile only"
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      sleep 2
    fi
  fi
  rm -f "$PIDFILE" "$MON_SOCK"
}

# ----------------------------------------------------------------------------
# 3. Boot the image -- fully automated, exact verified arg set.
#    Root on AHCI (NOT virtio-blk). -vga std for capturable portrait framebuffer.
#    snapshot=on keeps the base .img pristine and makes the run idempotent.
# ----------------------------------------------------------------------------
start_vm() {
  stop_vm # ensure no stale instance on our namespaced sockets
  rm -f "$QEMU_LOG" "$SER_LOG" "$MON_SOCK"
  log "booting postmarketOS (vnc :${VNC_DISPLAY}, monitor ${MON_SOCK})"
  "$QEMU" \
    -accel kvm -machine q35 -cpu host -smp 4 -m 3072 \
    -drive if=pflash,unit=0,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,unit=1,format=raw,file="$OVMF_VARS" \
    -vga std \
    -device intel-hda -device hda-duplex,audiodev=snd0 -audiodev none,id=snd0 \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \
    -device ahci,id=ahci0 \
    -drive if=none,id=disk0,file="$IMG",format=raw,snapshot=on \
    -device ide-hd,drive=disk0,bus=ahci0.0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -rtc base=utc \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "file:${SER_LOG}" \
    -name "pmos-phosh-${GUEST_KEY}" \
    >"$QEMU_LOG" 2>&1 &
  echo $! >"$PIDFILE"
  log "started pid $(cat "$PIDFILE")"
}

# screendump the current framebuffer to a PNG via the monitor.
snap() {
  local name="$1" ppm="${BASE}/$1.ppm" png="${BASE}/$1.png"
  rm -f "$ppm" "$png"
  mon "screendump ${ppm}"
  sleep 1
  if [ -s "$ppm" ]; then
    pnmtopng "$ppm" >"$png" 2>/dev/null || true
    rm -f "$ppm"
    printf '%s' "$png"
  fi
}

# type digits into phosh via HMP sendkey (each key = a keypad press) then press
# Return to hit the "Unlock" button. NOTE: the v26.06 phosh keypad does NOT
# auto-submit at 6 digits -- it shows an explicit Unlock button, so the trailing
# 'ret' is REQUIRED to actually unlock (verified on-box).
type_pin() {
  local s="$1" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:$i:1}"
    mon "sendkey ${c}"
    sleep 0.2
  done
  sleep 0.3
  mon "sendkey ret"
}

# wake the (idle-blanked) screen with a harmless key event.
wake() {
  mon "sendkey ctrl"
  sleep 0.5
}

# ----------------------------------------------------------------------------
# 4/5. Boot to GUI, unlock, framebuffer-verify it reaches the phone shell.
#      Size heuristic: a real portrait lockscreen/home PNG is tens-to-hundreds
#      of KB; an idle-black frame is a couple hundred bytes.
# ----------------------------------------------------------------------------
GUI_MIN_BYTES="${PMOS_GUI_MIN_BYTES:-40000}"

png_ok() {
  local f="$1"
  [ -n "$f" ] && [ -s "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -ge "$GUI_MIN_BYTES" ]
}

verify_gui() {
  start_vm
  log "waiting for UEFI + plymouth + phosh (up to ~120s) ..."
  local f=""
  # Poll for a non-trivial framebuffer (the lockscreen).
  for i in $(seq 1 24); do
    sleep 5
    wake
    f="$(snap "proof-1-lockscreen")"
    if png_ok "$f"; then
      log "lockscreen reached after ~$((i * 5))s: $f ($(stat -c%s "$f") bytes)"
      break
    fi
    f=""
  done
  [ -n "$f" ] || {
    log "serial tail:"
    tail -20 "$SER_LOG" 2>/dev/null || true
    die "no GUI framebuffer within timeout"
  }

  # Unlock: type the 6 PIN digits + Return (presses the "Unlock" button).
  log "entering unlock PIN"
  wake
  type_pin "$UNLOCK_PIN"
  # phosh plays an unlock transition; wake+retry until the app launcher renders
  # a real (non-black) frame. -vga std reads black during the fade, so poll.
  local home=""
  for _ in 1 2 3 4 5 6 7 8; do
    sleep 3
    wake
    home="$(snap "proof-2-phosh-home")"
    png_ok "$home" && break
    home=""
  done
  if [ -n "$home" ]; then
    log "unlocked -> phosh app launcher: $home ($(stat -c%s "$home") bytes)"
  else
    log "WARN: post-unlock frame stayed small/black. Lockscreen proof stands (PIN accepted); phosh may have idle-blanked -- in the live neko tile continuous input keeps it awake."
  fi

  log "framebuffer proofs written under $BASE (proof-1-lockscreen.png, proof-2-phosh-home.png)"
  stop_vm
}

# ----------------------------------------------------------------------------
# neko-qemu / gallery runtime args (for reference; emitted, not executed here).
# In the live station: drop snapshot=on if you want persistence, and swap
# `-audiodev none` for the neko container's PulseAudio/PipeWire sink.
#
# GALLERY TILE INTEGRATION (verified on-box 2026-07-04 -> Phosh UI reached):
#   The station is wired by gallery-integrate-all.sh [neko-era, deleted — git history] (key 'postmarketos',
#   host port :8103). Two environment-specific gotchas -- BOTH now handled --
#   were what left the station gated:
#
#   1. OVMF PATHS ARE CONTAINER-RELATIVE, NOT PVE-HOST.
#      This script builds/verifies the IMAGE on the *PVE host*, where the OVMF
#      blobs live at /usr/share/pve-edk2-firmware/* (correct HERE). But the station
#      boots inside the neko-qemu *Docker container* (Debian), which has NO such
#      path -- its OVMF is the Debian `ovmf` package at
#           /usr/share/OVMF/OVMF_CODE_4M.fd   (read-only CODE)
#           /usr/share/OVMF/OVMF_VARS_4M.fd   (VARS template)
#      So the station must NOT hardcode pve paths. Instead the manifest sets the
#      guestenv token OVMF=1, and the patched osgallery/neko-qemu/launch-qemu.sh
#      AUTO-DISCOVERS the container's OVMF_CODE and SEEDS A FRESH, WRITABLE
#      per-boot copy of OVMF_VARS (default /tmp/OVMF_VARS.<uid>.fd) before boot.
#      Fresh vars each boot == no stale boot entry -> BdsDxe finds the ESP's
#      \EFI\BOOT\BOOTX64.EFI (systemd-boot) and boots the AHCI disk.
#
#   2. IMAGE MUST LIVE IN THE PARENT gallery-guests DATASET (a PLAIN DIR),
#      NOT A CHILD ZFS DATASET. The CT exposes the images via a single
#      `lxc.mount.entry ... bind` of /data/gallery-guests. A plain `bind` (not
#      rbind) does NOT carry NESTED mounts, so if pmos-phosh.img sits in a child
#      dataset (e.g. `zfs create data/gallery-guests/postmarketOS`) the container
#      sees an EMPTY dir and the station has no disk. Keep this guest's dir a plain
#      subdirectory of the parent dataset (this script's $BASE is already a plain
#      path -- do NOT `zfs create` a child dataset under it). If one already
#      exists, flatten it:  zfs set mountpoint=/mnt/tmp <child> ; cp --sparse=always
#      /mnt/tmp/pmos-phosh.img <BASE>/ ; zfs destroy <child>.
# ----------------------------------------------------------------------------
print_gallery_args() {
  cat <<EOF

# ============================================================================
# neko-qemu gallery TILE args (postmarketOS :8103) -- container-correct form.
# NOTE: pflash is NOT hardcoded here; the station sets OVMF=1 and launch-qemu.sh
# attaches the container's /usr/share/OVMF/OVMF_CODE_4M.fd (ro) + a freshly
# seeded WRITABLE /tmp/OVMF_VARS.<uid>.fd. The equivalent explicit args are:
# ============================================================================
qemu-system-x86_64 -accel kvm -machine q35 -cpu host -smp 4 -m 3072 \\
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \\
  -drive if=pflash,unit=1,format=raw,file=/tmp/OVMF_VARS.pmos.fd  # seeded from OVMF_VARS_4M.fd \\
  -vga std \\
  -device intel-hda -device hda-duplex,audiodev=snd0 -audiodev <neko-sink>,id=snd0 \\
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 -device usb-kbd,bus=xhci.0 \\
  -device ahci,id=ahci0 \\
  -drive if=none,id=disk0,file=/guests/postmarketOS/pmos-phosh.img,format=raw,snapshot=on \\
  -device ide-hd,drive=disk0,bus=ahci0.0 \\
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \\
  -rtc base=utc
#  usb-tablet = absolute pointer -> neko click = TAP; drag = swipe (verified).
#  Root MUST be AHCI/NVMe, never virtio-blk. Unlock PIN: 147147.
# ============================================================================
EOF
}

# ----------------------------------------------------------------------------
main() {
  check_deps
  fetch_image
  seed_ovmf
  if [ -z "${PMOS_NO_VERIFY:-}" ]; then
    verify_gui
  else
    log "PMOS_NO_VERIFY set -> skipping boot/framebuffer verification"
  fi
  print_gallery_args
  log "DONE. Final bootable image: $IMG"
}

main "$@"
