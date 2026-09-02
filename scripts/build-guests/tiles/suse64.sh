#!/usr/bin/env bash
# Build the suse64 gallery guest: SuSE Linux 6.4 i386 (2000), KDE 1.1.2 on
# XFree86 3.3.6, YaST2 installer.
#
# WHAT THIS SCRIPT DOES:
#   1. Download suse-linux-6.4-cd1.iso from archive.org (unless already
#      staged), verify sha256 + size.
#   2. Create a 1.5 GiB qcow2 disk in OUT_DIR.
#   3. Boot it headless with the EXACT suse64 station device set (see
#      docs/lab/SUSE64-WAVE.md allocation ledger), CD1 attached, -boot d.
#   4. Wait for the linuxrc/YaST2 boot screen (fb-wait.py --settle) and
#      screendump it as proof the install media boots.
#
# AUTOMATION HONESTY — what this script does NOT do:
#   It stops at the booted installer. Everything past that point is driven
#   interactively over QMP by an agent using scripts/dev/qmp-type.py (a
#   vision loop: screendump -> OCR/read -> type/click -> repeat), because
#   YaST2's graphical installer, XF86Config, and the KDE 1.1.2 desktop have
#   no unattended/answer-file path on this media:
#     - YaST2 install: language English, keyboard us, source CD, partition
#       one swap + one ext2 `/`, package selection default + KDE, bootloader
#       LILO to the MBR, root password `gallery`, network eth0 via DHCP.
#     - /etc/XF86Config: SVGA server on the cirrus chipset, 1024x768x16.
#     - tty1 autologin into `startx` -> KDE 1.1.2 desktop, then
#       `xhost +10.0.2.2` from an xterm so the host-side X11-warp bridge
#       (SH_X11WARP_DISPLAY=127.0.0.1:80, 127.0.0.1:6080 -> 10.0.2.15:6000)
#       can reach the guest's X server.
#     - `savevm golden` on the QMP monitor, with the station device set
#       (no -cdrom) and a loadvm proof before the disk is staged to
#       /data/gallery-guests/SUSE64/suse64.qcow2.
#   Next steps for that agent are printed at the end of this script.
set -euo pipefail
umask 077

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAGE=${SUSE64_STAGE:-/data/assets-staging/suse64}
ISO=$STAGE/suse-linux-6.4-cd1.iso
WORK=${SUSE64_WORK:-/data/vms/sandbox/suse64-build-$(date +%Y%m%d)}
OUT_DIR=${SUSE64_OUT_DIR:-/data/gallery-guests/SUSE64}
DISK=$OUT_DIR/suse64.qcow2
QMP=$WORK/qmp.sock
PIDFILE=$WORK/qemu.pid

ISO_URL=https://archive.org/download/suse-linux-6.4/suse-linux-6.4-cd1.iso
ISO_SIZE=663029760
ISO_SHA256=5a835e4bba03485f17f31d6b8204881a77c1206571b27e8300c889e8bf721a33

QEMU_BIN=/opt/qemu-beos/bin/qemu-system-x86_64

log() { printf '[suse64] %s\n' "$*"; }
die() {
  log "FAIL: $*" >&2
  exit 1
}

[ "$WORK" != /mnt/poc ] || die "refusing /mnt/poc"
[[ "$WORK" == /data/vms/sandbox/suse64-build-* ]] || die "WORK must be namespaced under /data/vms/sandbox/suse64-build-*"
[ -x "$QEMU_BIN" ] || die "$QEMU_BIN missing"
# TCG on purpose: the 2.2 kernel drives IDE in 16-bit PIO and every outw is a KVM exit (70 KiB/s measured); see docs/lab/SUSE64-WAVE.md

mkdir -p "$WORK" "$STAGE" "$OUT_DIR"

stage_media() {
  if [ ! -s "$ISO" ]; then
    log "fetching CD1 from archive.org (663 MB)"
    tmp=$STAGE/.suse64.iso.$$.tmp
    trap 'rm -f "$tmp"' RETURN
    curl -fL --retry 5 --retry-delay 3 -o "$tmp" "$ISO_URL"
    [ "$(stat -c %s "$tmp")" = "$ISO_SIZE" ] || die "ISO size mismatch (got $(stat -c %s "$tmp"), want $ISO_SIZE)"
    printf '%s  %s\n' "$ISO_SHA256" "$tmp" | sha256sum -c - >/dev/null || die "ISO hash mismatch"
    mv "$tmp" "$ISO"
    trap - RETURN
  fi
  [ "$(stat -c %s "$ISO")" = "$ISO_SIZE" ] || die "staged ISO size mismatch"
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c - >/dev/null || die "staged ISO hash mismatch"
  printf '%s  suse-linux-6.4-cd1.iso\n' "$ISO_SHA256" >"$STAGE/MANIFEST.sha256.tmp"
  mv "$STAGE/MANIFEST.sha256.tmp" "$STAGE/MANIFEST.sha256"
}

make_disk() {
  [ ! -e "$DISK" ] || die "refusing to overwrite existing $DISK (move it aside explicitly)"
  qemu-img create -f qcow2 "$DISK.tmp" 1536M >/dev/null
  mv "$DISK.tmp" "$DISK"
}

vm_stop() {
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE")
  kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  rm -f "$PIDFILE" "$QMP"
}
trap vm_stop EXIT

boot_installer() {
  # EXACTLY the suse64 station device set + -display none for the headless
  # build; see docs/lab/SUSE64-WAVE.md allocation ledger.
  "$QEMU_BIN" \
    -accel tcg -cpu pentium3 -m 256 -smp 1 -machine pc-i440fx-11.0,acpi=off \
    -rtc base=localtime -vga cirrus \
    -drive file="$DISK",format=qcow2,if=ide \
    -cdrom "$ISO" -boot d \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:6080-10.0.2.15:6000 \
    -device ne2k_pci,netdev=n0 \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PIDFILE" \
    -display none \
    -daemonize
  for _ in $(seq 1 120); do
    [ -S "$QMP" ] && [ -f "$PIDFILE" ] && return
    sleep 0.25
  done
  die "QEMU did not come up (no QMP socket)"
}

wait_and_prove() {
  log "waiting for the linuxrc/YaST2 boot screen to settle"
  mkdir -p "$WORK/evidence"
  python3 "$SELF_DIR/../../dev/fb-wait.py" --qmp "$QMP" --settle 3 --timeout 180 \
    --out "$WORK/evidence/linuxrc-boot.png" \
    || die "linuxrc screen did not settle within 180s"
  log "proof framebuffer: $WORK/evidence/linuxrc-boot.png"
}

stage_media
make_disk
boot_installer
wait_and_prove
vm_stop

cat <<EOF

[suse64] PASS: booted to the linuxrc/YaST2 installer on a fresh 4 GiB disk.
  disk:      $DISK
  qemu.pid:  (stopped after proof)
  evidence:  $WORK/evidence/linuxrc-boot.png

Next steps (agent, over QMP with scripts/dev/qmp-type.py, vision loop):
  1. Re-launch with the same device set (this script's boot_installer)
     minus -display none if you need a local view, and drive YaST2:
     English / us keyboard / CD source / one swap + one ext2 "/" /
     default+KDE package selection / LILO to MBR / root password "gallery" /
     eth0 via DHCP.
  2. After first boot into the installed system, write /etc/XF86Config:
     SVGA server on the cirrus chipset, 1024x768x16.
  3. Wire tty1 autologin -> "startx" -> KDE 1.1.2, then from an xterm run
     "xhost +10.0.2.2" so the host X11-warp bridge can reach the X server.
  4. Reboot on the station device set (drop -cdrom), reach the KDE desktop,
     then on the QMP monitor: "savevm golden". Prove it with a "loadvm golden"
     that returns to the same desktop.
  5. Stage the disk to $DISK (already the OUT_DIR path) and report the
     measured facts back to the coordinator for station.env.fixture +
     registry truth.
EOF
