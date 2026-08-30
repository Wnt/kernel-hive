#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/rhapsody.sh — reproduce the `rhapsody` station's install
# disk (Rhapsody 5.1 Developer Release 2 for Intel) from the archive.org media,
# on the station-specific QEMU.
#
# PROOF STATUS: hand-verified procedure 2026-08-18 on the sandbox rig
# /data/vms/sandbox/rhapsody/rig (launch.sh + drive-install.sh); this script
# encodes that recipe and has not yet been run end-to-end. Read
# docs/guests/rhapsody.md first — it explains the one real blocker (a guest PIC
# race that stock QEMU makes constant) and why /opt/qemu-rhapsody exists.
#
# PHASES
#   qemu    build /opt/qemu-rhapsody/bin/qemu-system-i386 from the kernel-hive
#           QEMU fork + streamhost/qemu-patches/0006-i8259-lenient-spurious-
#           cascade.patch (skipped when the binary is present and carries the
#           KH_I8259_LENIENT_CASCADE switch)
#   media   media_cache_require the three gzipped images (sha256 pins), gunzip
#   install boot the floppy on the pinned device set, swap in the drivers
#           floppy over QMP, answer the installer, wait for the copy to finish
#   output  $RHAPSODY_OUTPUT_DIR/rhapsody-golden.qcow2 (no golden snapshot yet
#           — the checkpoint is baked on the station once the desktop is proven)
#
# SAFETY: everything transient lives in a namespaced WORK dir under the
# sandbox root; every QEMU is stopped through clone-guard's kill-pidfile.
#
# USAGE
#   scripts/build-guests/tiles/rhapsody.sh            # all phases
#   PHASES=qemu scripts/build-guests/tiles/rhapsody.sh
#   FORCE=1 … replaces an existing output disk (backed up first)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=scripts/build-guests/lib/media-cache.sh
. "$REPO/scripts/build-guests/lib/media-cache.sh"
# shellcheck source=scripts/lib/clone-guard.sh
. "$REPO/scripts/lib/clone-guard.sh"

OS_ID="rhapsody"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="${RHAPSODY_WORK_DIR:-/data/vms/sandbox/build-${OS_ID}-${STAMP}}"
OUT_DIR="${RHAPSODY_OUTPUT_DIR:-/data/vms/build/Rhapsody}"
OUT_DISK="$OUT_DIR/rhapsody-golden.qcow2"
QEMU_PREFIX="${QEMU_PREFIX:-/opt/qemu-rhapsody}"
QEMU="$QEMU_PREFIX/bin/qemu-system-i386"
FORK_URL="${FORK_URL:-https://github.com/Wnt/qemu.git}"
FORK_BRANCH="${FORK_BRANCH:-kernel-hive}"
PATCH="$REPO/streamhost/qemu-patches/0006-i8259-lenient-spurious-cascade.patch"
# 0007 adds `-device kh-ramabs`, the station's absolute pointer: it writes the
# commanded pixel into Rhapsody's OWN pointer coordinate in guest RAM and
# publishes it with one small PS/2 nudge. It holds no vmstate and models no
# hardware, so it does not change the device set and the golden still restores.
PATCH_PTR="$REPO/streamhost/qemu-patches/0007-kh-ramabs-guest-ram-absolute-pointer.patch"
QMPTYPE="$REPO/scripts/dev/qmp-type.py"
QMPHMP="$REPO/scripts/qmp_hmp.py"
PHASES="${PHASES:-qemu media install output}"
DISK_SIZE="${RHAPSODY_DISK_SIZE:-2G}"
INSTALL_WAIT_MAX="${RHAPSODY_INSTALL_WAIT_MAX:-5400}"

# archive.org item rhapsody5.1, directory Rhapsody_5.1/ (sha256 of the .gz files)
MEDIA_BASE="https://archive.org/download/rhapsody5.1/Rhapsody_5.1"
BOOT_GZ_SHA="ed64360d77a2b7e46c522602d05285f66266391591e63279943083ca7f1ea411"
DRV_GZ_SHA="eb4c2c5b5b638b41b492b974ad00596f5089e461ab68c37697c144868ed342da"
CD_GZ_SHA="c297391cbdfa3341e741a92c27fe8dbcb824acb4562dfeca03feb251f29c505b"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
hmp() { python3 "$QMPHMP" "$WORK/qmp.sock" "$@" >/dev/null; }
keys() { # keys <wait> [sendkey names…]
  local w="$1"
  shift
  [ $# -gt 0 ] && python3 "$QMPTYPE" --qmp "$WORK/qmp.sock" --keys "$@" --out "$WORK/shot" >/dev/null
  sleep "$w"
  python3 "$QMPTYPE" --qmp "$WORK/qmp.sock" --shot --out "$WORK/shot" >/dev/null
}
cleanup() {
  [ -f "$WORK/qemu.pid" ] && clone_guard_kill_pidfile "$WORK/qemu.pid" 2>/dev/null || true
  [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

phase_qemu() {
  if [ -x "$QEMU" ] && strings "$QEMU" | grep -q KH_I8259_LENIENT_CASCADE &&
    strings "$QEMU" | grep -q kh-ramabs; then
    log "qemu already at $QEMU (lenient-cascade switch and kh-ramabs present)"
    return 0
  fi
  log "building qemu-system-i386 from $FORK_URL@$FORK_BRANCH + $(basename "$PATCH") + $(basename "$PATCH_PTR")"
  local src="$WORK/qemu-src"
  mkdir -p "$WORK"
  [ -d "$src" ] || git clone -q --branch "$FORK_BRANCH" --depth 1 "$FORK_URL" "$src"
  (cd "$src" && git apply --check "$PATCH" && git apply "$PATCH") || die "0006 patch does not apply to the fork"
  (cd "$src" && git apply --check "$PATCH_PTR" && git apply "$PATCH_PTR") || die "0007 patch does not apply to the fork"
  mkdir -p "$src/build"
  (cd "$src/build" && ../configure \
    --target-list=i386-softmmu --enable-slirp --enable-dbus-display --enable-kvm \
    --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
    --disable-opengl --disable-werror --disable-tools --disable-xkbcommon \
    --prefix="$QEMU_PREFIX" >"$WORK/configure.log" 2>&1) || die "configure failed; see $WORK/configure.log"
  # ninja install, not a bare copy: the binary looks for bios-256k.bin and
  # friends under $QEMU_PREFIX/share/qemu.
  (cd "$src/build" && nice -n 15 ninja >"$WORK/ninja.log" 2>&1 && ninja install >>"$WORK/ninja.log" 2>&1) || die "build failed; see $WORK/ninja.log"
  strings "$QEMU" | grep -q KH_I8259_LENIENT_CASCADE || die "built binary lacks the lenient-cascade switch"
  strings "$QEMU" | grep -q SH_DBUS_UPDATE_MS || die "built binary lacks the fork's fast-poll patch"
  strings "$QEMU" | grep -q kh-ramabs || die "built binary lacks the kh-ramabs absolute pointer"
  log "built and verified $QEMU"
}

phase_media() {
  mkdir -p "$WORK/media"
  media_cache_require "sha256:$BOOT_GZ_SHA" "$WORK/media/boot.img.gz" "rhapsody-5.1-boot-floppy" "$MEDIA_BASE/rhapsody_5.1_boot.img.gz"
  media_cache_require "sha256:$DRV_GZ_SHA" "$WORK/media/drivers.img.gz" "rhapsody-5.1-drivers-floppy" "$MEDIA_BASE/rhapsody_5.1_drivers.img.gz"
  media_cache_require "sha256:$CD_GZ_SHA" "$WORK/media/cd.img.gz" "rhapsody-5.1-install-cd" "$MEDIA_BASE/rhapsody_5.1_install_cd.img.gz"
  for f in boot drivers cd; do gunzip -kf "$WORK/media/$f.img.gz"; done
  log "media staged in $WORK/media"
}

launch() { # launch <-boot a|c> [-fda path]
  local bootarg="$1" fda="${2:-}" fdargs=()
  [ -n "$fda" ] && fdargs=(-drive "file=$fda,format=raw,if=floppy,index=0")
  export KH_I8259_LENIENT_CASCADE=1
  nohup "$QEMU" -name "build-$OS_ID" \
    -accel tcg -m 64 -smp 1 -machine pc-i440fx-11.0 -cpu pentium2 -rtc base=localtime \
    -drive "file=$WORK/rhapsody-golden.qcow2,format=qcow2,if=ide,index=0" \
    -drive "file=$WORK/media/cd.img,format=raw,if=ide,index=2,media=cdrom,readonly=on" \
    "${fdargs[@]}" -boot "$bootarg" \
    -vga std -display none \
    -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
    -chardev msmouse,id=ms0 -serial chardev:ms0 -serial "file:$WORK/serial.log" \
    -qmp "unix:$WORK/qmp.sock,server=on,wait=off" -pidfile "$WORK/qemu.pid" >"$WORK/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$WORK/qmp.sock" ] && break
    sleep 0.5
  done
  [ -S "$WORK/qmp.sock" ] || die "QEMU did not come up; see $WORK/qemu.log"
}

phase_install() {
  mkdir -p "$WORK"
  qemu-img create -f qcow2 "$WORK/rhapsody-golden.qcow2" "$DISK_SIZE" >/dev/null
  launch a "$WORK/media/boot.img"
  keys 12       # language prompt
  keys 12 1 ret # English / USA keyboard
  keys 12 1 ret # prepare to install
  hmp "change floppy0 $WORK/media/drivers.img raw"
  keys 20 ret   # drivers disk inserted
  keys 8 7 ret  # SCSI list page 2
  keys 8 7 ret  # page 3
  keys 25 4 ret # Intel PIIX PCI EIDE/ATAPI Device Controller (v5.01)
  keys 40 1 ret # no more drivers -> Mach kernel from the CD
  keys 15 1 ret # Ok - ready to install
  keys 15 1 ret # install on IDE Disk 0
  keys 15 1 ret # erase the entire disk
  keys 45 1 ret # start installing
  # The copy takes ~1 h under TCG. Done = the disk stops growing AND the
  # framebuffer stops changing for three consecutive minutes.
  local t=0 prev="" same=0 cur
  while [ "$t" -lt "$INSTALL_WAIT_MAX" ]; do
    sleep 60
    t=$((t + 60))
    keys 0
    cur="$(stat -c %s "$WORK/rhapsody-golden.qcow2")-$(md5sum "$WORK/shot/cur.png" | cut -c1-8)"
    if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; fi
    prev="$cur"
    [ "$same" -ge 3 ] && break
  done
  [ "$same" -ge 3 ] || die "install did not settle within ${INSTALL_WAIT_MAX}s"
  log "installer settled after ${t}s; last frame $WORK/shot/cur.png (inspect: the DR2 installer ends on a reboot prompt)"
  clone_guard_kill_pidfile "$WORK/qemu.pid" || die "clone-guard refused to stop the build QEMU"
}

phase_output() {
  mkdir -p "$OUT_DIR"
  if [ -f "$OUT_DISK" ]; then
    [ "${FORCE:-0}" = 1 ] || die "$OUT_DISK exists (FORCE=1 to replace)"
    mv "$OUT_DISK" "$OUT_DISK.bak-$STAMP"
  fi
  qemu-img convert -O qcow2 "$WORK/rhapsody-golden.qcow2" "$OUT_DISK"
  log "wrote $OUT_DISK — first disk boot + golden bake happen on the station (docs/guests/rhapsody.md)"
}

for p in $PHASES; do "phase_$p"; done
