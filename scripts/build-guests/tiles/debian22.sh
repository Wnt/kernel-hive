#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/debian22.sh — stage media and produce a pristine install
# disk for the Debian GNU/Linux 2.2 "potato" (i386) Tier-1 station.
#
# WHAT THIS SCRIPT DOES:
#   (1) fetch (or copy from staging) CD1 of the Debian 2.2 r0 "Official i386
#       Binary-1" disc, verify sha256 + size, stage it atomically under
#       /data/assets-staging/debian22/ then to the gallery-guests dir where
#       the station launcher expects it
#   (2) create a PRISTINE (no snapshot) 2 GiB qcow2 install disk
#   (3) launch the installer VM on the EXACT device set the station launcher
#       (streamhost/stations/debian22/qemu-streamhost.sh) uses, minus
#       -loadvm/-S, with -boot order=d so it boots the CD
#   (4) hand off to the OPERATOR/agent for the interactive dbootstrap install
#       (this is "vision"-class work: OCR/QMP-driven dbootstrap choreography
#       is out of scope for this builder) and wait for a completion signal
#
# The `golden` vmstate (X + GNOME + auto-login) is baked by the
# `debian22-golden` stream on a sandbox clone of THIS disk, never here.
#
# DEVICE SET (must match streamhost/stations/debian22/qemu-streamhost.sh
# verbatim, apart from -boot order and -loadvm/-S — the golden vmstate is
# captured on that exact set, so never drift the two independently):
#   pc-i440fx-11.0, KVM, -cpu host, 256 MB, 1 vCPU, IDE disk index 0,
#   IDE CD index 2, -vga cirrus, PS/2 mouse+keyboard, -nodefaults, no NIC,
#   no USB, no audio.
#
# -----------------------------------------------------------------------------
# INSTALL CHOREOGRAPHY (manual/agent-driven over QMP; from the ledger's
# golden-stream row — docs/lab/DEBIAN22-WAVE.md). Numbered so an operator or
# an agent can drive it step by step with screendump + sendkey:
#
#   1.  BIOS boots CD1 to the `boot:` prompt. Press Enter (default kernel).
#   2.  boot-floppies 2.2.16 loads; dbootstrap "Release Notes" dialog appears
#       (~20s under KVM) -> Enter/OK through it.
#   3.  Main menu -> "Configure the Keyboard" -> accept default (US) layout.
#   4.  "Partition a Hard Disk" -> select the sole IDE disk -> cfdisk: create
#       one primary Linux partition spanning the disk, write, quit.
#   5.  "Install Kernel and Driver Modules" -> source = CD-ROM drive.
#   6.  "Configure Device Driver Modules" -> skip/none needed for this device
#       set (Cirrus + IDE are already in the installed kernel).
#   7.  "Configure Network" -> skip (air-gapped; no NIC on this device set).
#   8.  "Install the Base System" -> source = CD-ROM (base2_2.tgz on CD1).
#   9.  "Make Linux Bootable Directly from Hard Disk" -> install LILO to the
#       MBR of the sole IDE disk.
#   10. "Make a Boot Floppy" -> skip (no floppy device on this set).
#   11. "Reboot the System" -> remove/ignore CD-ROM prompt (CD stays attached
#       per the device set, but boot order reverts to the disk after reboot
#       via the station launcher's `-boot order=c`; this builder's own
#       `-boot order=d` only applies to the install boot).
#   12. First boot from disk: base system boots to a login prompt. Log in as
#       root (dbootstrap set the root password during "Set Up Users and
#       Passwords" — capture it into registry/local.env key guest/debian22,
#       never into git).
#   13. `dselect` or `apt-get` (from CD1) install: `xserver-xfree86`,
#       `xfree86-common`, the Cirrus/`XF86_SVGA` server package, `gnome-core`
#       or `task-gnome-desktop`, `xdm` (or configure auto-login instead).
#   14. Hand-write `/etc/X11/XF86Config` (XFree86 3.3.6 `xf86config`
#       wizard): Device = "Cirrus Logic GD5446" (cirrus server), Monitor
#       generic multisync, Screen modes include "1024x768" at the default
#       (16 bpp) colour depth, Mouse = PS/2 protocol `/dev/psaux`, Keyboard
#       = generic 101-key.
#   15. Configure auto-login as `gallery` straight onto the GNOME desktop
#       (no gdm/xdm chooser in the fixture) per the ledger's `login` row.
#   16. Create the `gallery` user, set both root and gallery passwords, and
#       record them in gitignored registry/local.env key guest/debian22.
#
# This builder stops after step 1 (boots the installer to the CD) and WAITS
# for the operator/agent to run steps 2-16 by hand over QMP/VNC, then signal
# completion (see `wait_for_operator` below) — mirroring redstar2.sh's
# install_guest()/configure_guest() split, except the choreography itself is
# not automated here (Debian's dbootstrap has no stable OCR anchors pinned
# yet; that is `debian22-golden`'s job, or the `debian22-compose` racing
# theory that skips the interactive installer altogether).
# =============================================================================
set -euo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
OS_ID="debian22"
TILE_DIR="debian22"

STAGE_DIR="${STAGE_DIR:-/data/assets-staging/debian22}"
STAGE_SRC="${DEBIAN22_STAGE_SRC:-/data/assets-staging/debian22/debian-2.2-i386-cd1.iso}"
OUT_DIR="${OUT_DIR:-/data/gallery-guests/Debian22}"
ISO_OUT="$OUT_DIR/debian-2.2-i386-cd1.iso"
DISK_OUT="$OUT_DIR/debian22.qcow2"
DISK_SIZE=2G

ISO_URL="https://archive.org/download/Debian-GNULinux-2.2-arch-i386-CD/Debian-GNULinux-2.2-arch-i386-CD-1of3.iso"
ISO_SHA256="2b1d2b18a14ea1f62302aeb98caf1a7b9191a87c3591a42d8bbf0fe5ef1abf1f"
ISO_SIZE=659271680

WORK="${WORK:-/data/vms/build-${OS_ID}}"
QMP="$WORK/qmp.sock"
HMP="$WORK/hmp.sock"
PIDFILE="$WORK/qemu.pid"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
qmp() { python3 "$LABQMP" "$QMP" "$@"; }

[[ "$WORK" == /data/vms/build-* ]] || die "WORK must be namespaced under /data/vms/build-*"
mkdir -p "$WORK" "$STAGE_DIR" "$OUT_DIR"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# =============================================================================
# (1) stage CD1: prefer a hash-matching copy already on the box, else fetch
# =============================================================================
stage_iso() {
  if [ -s "$STAGE_SRC" ] && [ "$STAGE_SRC" != "$STAGE_DIR/debian-2.2-i386-cd1.iso" ] &&
    [ "$(stat -c %s "$STAGE_SRC")" = "$ISO_SIZE" ] && [ "$(sha_of "$STAGE_SRC")" = "$ISO_SHA256" ]; then
    log "staging source $STAGE_SRC matches pin; using it"
    cp --reflink=auto "$STAGE_SRC" "$STAGE_DIR/.debian22.iso.$$.tmp"
    mv "$STAGE_DIR/.debian22.iso.$$.tmp" "$STAGE_DIR/debian-2.2-i386-cd1.iso"
  elif [ ! -s "$STAGE_DIR/debian-2.2-i386-cd1.iso" ] ||
    [ "$(stat -c %s "$STAGE_DIR/debian-2.2-i386-cd1.iso")" != "$ISO_SIZE" ] ||
    [ "$(sha_of "$STAGE_DIR/debian-2.2-i386-cd1.iso")" != "$ISO_SHA256" ]; then
    log "fetching $ISO_URL"
    tmp="$STAGE_DIR/.debian22.iso.$$.tmp"
    curl -fL --retry 5 --retry-delay 3 -o "$tmp" "$ISO_URL"
    [ "$(stat -c %s "$tmp")" = "$ISO_SIZE" ] || die "ISO size mismatch"
    printf '%s  %s\n' "$ISO_SHA256" "$tmp" | sha256sum -c - >/dev/null || die "ISO hash mismatch"
    mv "$tmp" "$STAGE_DIR/debian-2.2-i386-cd1.iso"
  fi
  [ "$(stat -c %s "$STAGE_DIR/debian-2.2-i386-cd1.iso")" = "$ISO_SIZE" ] || die "staged ISO size mismatch"
  [ "$(sha_of "$STAGE_DIR/debian-2.2-i386-cd1.iso")" = "$ISO_SHA256" ] || die "staged ISO hash mismatch"
  printf '%s  debian-2.2-i386-cd1.iso\n' "$ISO_SHA256" >"$STAGE_DIR/MANIFEST.sha256.tmp"
  mv "$STAGE_DIR/MANIFEST.sha256.tmp" "$STAGE_DIR/MANIFEST.sha256"

  # Atomically publish to the gallery-guests dir the station launcher reads.
  if [ ! -s "$ISO_OUT" ] || [ "$(sha_of "$ISO_OUT")" != "$ISO_SHA256" ]; then
    cp --reflink=auto "$STAGE_DIR/debian-2.2-i386-cd1.iso" "$OUT_DIR/.debian-2.2-i386-cd1.iso.$$.tmp"
    mv "$OUT_DIR/.debian-2.2-i386-cd1.iso.$$.tmp" "$ISO_OUT"
  fi
  [ "$(sha_of "$ISO_OUT")" = "$ISO_SHA256" ] || die "published ISO hash mismatch"
  log "CD1 staged: $ISO_OUT"
}

# =============================================================================
# (2) pristine install disk
# =============================================================================
make_disk() {
  [ ! -e "$DISK_OUT" ] || die "refusing to overwrite existing $DISK_OUT (move it aside explicitly)"
  qemu-img create -f qcow2 "$DISK_OUT.tmp" "$DISK_SIZE" >/dev/null
  mv "$DISK_OUT.tmp" "$DISK_OUT"
  log "pristine disk created: $DISK_OUT ($DISK_SIZE)"
}

# =============================================================================
# (3) launch the installer VM on the pinned device set (boot from CD)
# =============================================================================
vm_stop() {
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE")
  if kill -0 "$pid" 2>/dev/null; then
    [ -S "$HMP" ] && printf 'quit\n' | socat - UNIX-CONNECT:"$HMP" >/dev/null 2>&1 || kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 80); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi
  rm -f "$PIDFILE" "$QMP" "$HMP"
}
trap vm_stop EXIT

launch_installer() {
  [ -c /dev/kvm ] || die "/dev/kvm missing"
  qemu-system-x86_64 -machine help | grep -q 'pc-i440fx-11.0' || die "pc-i440fx-11.0 unavailable"
  vm_stop
  qemu-system-x86_64 \
    -name debian22-build -nodefaults \
    -enable-kvm -machine pc-i440fx-11.0 -cpu host \
    -m 256 -smp 1 -rtc base=localtime \
    -drive file="$DISK_OUT",format=qcow2,if=ide,index=0 \
    -drive file="$ISO_OUT",media=cdrom,if=ide,index=2 \
    -boot order=d \
    -vga cirrus \
    -display none -vnc "unix:$WORK/vnc.sock" \
    -qmp "unix:$QMP,server=on,wait=off" \
    -monitor "unix:$HMP,server,nowait" -pidfile "$PIDFILE" \
    -daemonize -D "$WORK/qemu.log"
  for _ in $(seq 1 120); do
    [ -S "$QMP" ] && [ -S "$HMP" ] && [ -f "$PIDFILE" ] && return
    sleep 0.25
  done
  die "QEMU sockets did not appear"
}

# =============================================================================
# (4) hand off to the operator/agent for the dbootstrap choreography above;
# wait for a completion signal file rather than automating OCR here.
# =============================================================================
wait_for_operator() {
  local sentinel="$WORK/INSTALL-DONE"
  rm -f "$sentinel"
  log "installer VM up (QMP $QMP, VNC unix:$WORK/vnc.sock)."
  log "drive dbootstrap steps 2-16 from the header comment block, then:"
  log "  touch $sentinel"
  log "waiting for $sentinel ..."
  while [ ! -e "$sentinel" ]; do
    kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null || die "installer VM exited before completion signal"
    sleep 2
  done
  log "completion signal received"
  vm_stop
}

stage_iso
if [ ! -e "$DISK_OUT" ]; then
  make_disk
  launch_installer
  wait_for_operator
else
  log "SKIP: $DISK_OUT already exists (interactive install not re-run; delete it to redo)"
fi
log "PASS: media staged at $ISO_OUT; install disk at $DISK_OUT (no golden vmstate — baked by debian22-golden)"
