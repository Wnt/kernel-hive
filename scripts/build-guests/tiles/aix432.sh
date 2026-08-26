#!/bin/bash
# aix432 — IBM AIX on an emulated RS/6000 7020 (40p), qemu-system-ppc.
#
# THE FLEET'S FIRST PReP/PowerPC STATION, and the second builder here that
# builds its own QEMU (after macos753). It needs to, twice over:
#
#   1. Upstream QEMU's 40p has NO display an RS/6000 guest can use — `-vga`
#      offers only std/cirrus. Herve Poussineau's S3 Trio card (2017, never
#      merged) is forward-ported onto 11.0.2 so Open Firmware gets a real
#      framebuffer instead of the serial console every published recipe uses.
#   2. Artyom Tarasenko's AIX fixes (lsi53c810 register hiding, raven PCI I/O
#      decoding, lsi reentrancy) are cherry-picked from his 40p-aix-boots branch.
#
# --------------------------------------------------------------------------
# READ docs/lab/research/candidate-aix.md BEFORE TOUCHING THIS.
# --------------------------------------------------------------------------
# The five things that cost time to learn, in the order they bite:
#
# 1. IT IS 4.3.3, NOT 4.3.2 — deliberately. AIX 4.3.2's installer kernel stops
#    driving the emulated LSI 53c810 after one retry cycle and hangs forever;
#    4.3.3 streams ~1100 reads and installs fine. Same firmware, same media
#    layout, same patches. The 4.3.2 Bonus Pack still goes on top, which is
#    where Ultimedia Services comes from.
# 2. `-M 40p` HAS NO IDE. block_default_type is IF_SCSI, so disk and CD both
#    land on the LSI at PCI_DEVFN(1,0). The ROM's /pci/ide/... devaliases are
#    stale and `dev /pci ls` shows no IDE node at all.
# 3. RAM IS CAPPED. `-m 512` is refused ("try 192 MB"); OF reports 128 MiB
#    whatever you pass, matching mc->default_ram_size.
# 4. AUTOBOOT NEVER WORKS. OF tries /pci/ethernet and gives up. Interrupt it
#    with a few CRs and boot explicitly: `boot cdrom:2` to install,
#    `boot disk` afterwards.
# 5. AUDIO NEEDS -global cs4231a.dma=6. AIX's CS4231 driver has play DMA fixed
#    at 6 and QEMU's cs4231a defaults to 3. iobase 0x830 / IRQ 10 already match.
#
# AND THE ONE THAT IS NOT SOLVED: AIX 4.3 has a driver for no display adapter
# QEMU emulates (see candidate-aix.md §4). The S3 gives the FIRMWARE a console;
# AIX itself cannot bind to it, so X does not start. A QEMU model for the
# Matrox Millennium II behind IBM's GXT130P is the work in flight.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

OS_ID="aix432"
WORK="${WORK:-/data/vms/sandbox/build-$OS_ID}"
ASSETS="${ASSETS:-/data/assets-staging/aix432}"
ROMS="$WORK/roms"
QMP="$WORK/qmp.sock"
SERIAL="$WORK/serial.sock"

QEMU_PREFIX="${QEMU_PREFIX:-/opt/qemu-ppc-s3}"
QEMU="$QEMU_PREFIX/bin/qemu-system-ppc"
FORK_URL="${FORK_URL:-https://github.com/Wnt/qemu.git}"
FORK_BRANCH="${FORK_BRANCH:-aix432-s3}"

# The install media. cd1 of the 4.3.3 set is the only bootable one — it carries
# the type-0x41 PReP boot partition; volumes 2-4 are fileset-only.
INSTALL_ISO="$ASSETS/aix433-vol1.iso"
BONUS_ISO="$ASSETS/ibm-aix-4.3.2-bonus-pack-cd1.iso"

DISK="$WORK/aix433.qcow2"
DISK_MB=8192
MEM_MB=192

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

# ---------------------------------------------------------------- qemu -------
phase_qemu() {
  if [ -x "$QEMU" ] && "$QEMU" -M 40p -vga help 2>/dev/null | grep -q '^s3'; then
    log "qemu-system-ppc with the S3 card already at $QEMU"
    return
  fi
  log "building qemu-system-ppc from $FORK_URL@$FORK_BRANCH"
  local src="$WORK/qemu"
  install -d "$WORK"
  [ -d "$src" ] || git clone -q --branch "$FORK_BRANCH" --depth 1 "$FORK_URL" "$src"
  install -d "$src/build"
  (cd "$src/build" && ../configure \
    --target-list=ppc-softmmu --enable-slirp --enable-dbus-display \
    --disable-opengl --disable-werror --disable-tools --prefix="$QEMU_PREFIX" \
    >"$WORK/configure.log" 2>&1) || die "configure failed; see $WORK/configure.log"
  (cd "$src/build" && nice -n 15 ninja qemu-system-ppc >"$WORK/ninja.log" 2>&1) ||
    die "build failed; see $WORK/ninja.log"
  install -Dm755 "$src/build/qemu-system-ppc" "$QEMU"
  "$QEMU" -M 40p | grep -q . 2>/dev/null || true
  "$QEMU" -M 40p -vga help | grep -q '^s3' ||
    die "built binary has no -vga s3; the S3 port did not land"
}

# ------------------------------------------------------------- firmware ------
# Artyom Tarasenko's Open Firmware for the 40p. There is no OpenBIOS path that
# boots AIX. The -vga variant is the graphical build; -serial the console one.
phase_firmware() {
  install -d "$ROMS"
  [ -s "$ROMS/q40pofw-serial.rom" ] ||
    die "stage q40pofw-serial.rom into $ROMS (see docs/lab/ASSETS-MANIFEST.md)"
  log "firmware present"
}

# ---------------------------------------------------------------- media ------
phase_media() {
  [ -s "$INSTALL_ISO" ] || die "missing $INSTALL_ISO"
  [ -s "$BONUS_ISO" ] || die "missing $BONUS_ISO"
  log "media present"
}

# ----------------------------------------------------------------- disk ------
phase_disk() {
  [ -f "$DISK" ] && {
    log "disk exists"
    return
  }
  install -d "$WORK"
  qemu-img create -f qcow2 "$DISK" "${DISK_MB}M" >/dev/null
  log "created $DISK (${DISK_MB}M)"
}

# --------------------------------------------------------------- launch ------
# Disk on SCSI id 0, CD on SCSI id 2 — OF's `cdrom` alias resolves to
# /scsi/disk@2, which is why `boot cdrom:2` is the incantation that works.
launch() {
  local cd="${1-}" vga="${2:-none}"
  local args=(
    -M 40p,audiodev=snd0 -audiodev none,id=snd0
    -global cs4231a.dma=6
    -bios "$ROMS/q40pofw-serial.rom"
    -m "$MEM_MB"
    -drive file="$DISK",format=qcow2,if=scsi,bus=0,unit=0
    -display none -vga "$vga"
    -serial unix:"$SERIAL",server,nowait
    -qmp unix:"$QMP",server,nowait
    -net none
  )
  [ -n "$cd" ] && args+=(-drive file="$cd",format=raw,if=scsi,bus=0,unit=2,media=cdrom,readonly=on)
  nohup "$QEMU" "${args[@]}" >"$WORK/qemu.err" 2>&1 &
  echo $! >"$WORK/qemu.pid"
}

# -------------------------------------------------------------- install ------
# NOT automated end to end. The BOS installer is a curses TUI over the serial
# line; the interactive recipe below was performed by hand on 2026-08-26 and is
# recorded so the next run can be scripted against it rather than rediscovered.
#
#   interrupt autoboot with several CRs, then:  boot cdrom:2
#   "Please define the System Console"       -> 1
#   language                                 -> 1  (English)
#   BOS Installation and Maintenance         -> 2  (change/show settings)
#   settings are already correct             -> 0  (New and Complete Overwrite,
#                                                   hdisk0)
#   ~60 min under TCG, 82 filesets, then it reboots to OF
#   at the ok prompt                         -> boot disk
#   terminal type                            -> vt100
#   Installation Assistant                   -> Esc+0 to exit, login as root
#   then, once:                                 rmitab install_assist
#
# Post-install, from a root shell (see docs/lab/research/candidate-aix.md §6):
#   crfs -v jfs -g rootvg -a size=2097152 -m /apps -A yes && mount /apps
#   chfs -a size=+1048576 /usr        # BOS leaves /usr with ~25 MB free
#   installp -acgXd /dev/cd0 devices.isa_sio.IBM000E      # CS4231 audio
#   installp -acgXd /dev/cd0 X11.base.rte X11.base.lib X11.base.common \
#       X11.base.smt X11.fnt.coreX X11.fnt.defaultFonts X11.fnt.fontServer \
#       X11.Dt.rte X11.Dt.lib X11.Dt.bitmaps X11.Dt.helpmin X11.apps.rte \
#       X11.apps.aixterm X11.apps.clients X11.motif.lib X11.motif.mwm \
#       X11.compat.lib.X11R5
#   (Bonus Pack CD1) installp -acgXd /dev/cd0 UMS.objects UMS.samples \
#       UMS.loc.en_US.objects Netscape.communicator-us.rte
#
# The audio device is NOT PnP-visible, so cfgmgr drops it every boot. Re-create
# it from a boot script with a CuDv stanza whose connwhere is "IBM000E", then
# `mkdev -l paud0`. See candidate-aix.md §6.
phase_install() {
  die "phase_install is interactive; follow the recipe in the comment above"
}

main() {
  case "${1:-}" in
    --qemu) phase_qemu ;;
    --firmware) phase_firmware ;;
    --media) phase_media ;;
    --disk) phase_disk ;;
    --install) phase_install ;;
    --all)
      phase_qemu
      phase_firmware
      phase_media
      phase_disk
      phase_install
      ;;
    *) die "usage: $0 [--all|--qemu|--firmware|--media|--disk|--install]" ;;
  esac
}

main "$@"
