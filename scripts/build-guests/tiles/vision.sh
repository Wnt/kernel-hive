#!/bin/bash
# =============================================================================
# tiles/vision.sh — stage the `vision` station: VisiCorp Visi On 1.0 (1983) on
# an IBM 5160 XT (8088, 640 KB, CGA, 10 MB XT fixed disk, Mouse Systems serial
# mouse on COM1). docs/lab/VISION-WAVE.md is the wave; docs/guests/vision.md
# the operating manual.
#
# Stages, in order:
#   --fetch    fetch every input from its ORIGIN into $STAGE (URL + sha256 +
#              byte size pinned below; nothing is ever copied from the Virtual
#              OS Museum, which was reference only) — idempotent, hash-gated
#   --unpack   unpack the archives into $MEDIA (raw 360K PC-DOS images, the
#              TransCopy .TC Visi On disks, the PCE XT ROMs + hd0.pbi)
#   --rootfs   build the nspawn sandbox rootfs at $OUT/rootfs: debootstrap
#              --variant=minbase trixie + the X and build packages, then PCE
#              itself compiled from the pinned tarball INSIDE that rootfs into
#              /opt/pce, then the whole tree uid-shifted ONCE to $UID_BASE so
#              the launcher can run --private-users-ownership=off
#   --compose  build the station disk set: convert the TransCopy .TC disks with
#              PCE's own `psi` (the copy protection lives in the flux; a plain
#              sector export loses it), stage the pce.cfg and the pristine
#              hd0.pbi with Visi On installed
#   (default)  all four
#
# PCE won the race against MAME's ibm5160 (docs/lab/VISION-WAVE.md §Race). PCE
# is a stock X11 host application, so the station runs it inside a systemd-nspawn
# container under the operator's host-application rule — hence --rootfs, which
# has no equivalent in a fleet-QEMU or host-native-MAME tile builder.
#
# Never commits media: the gallery is private, the repo is public (rule 1 —
# only URLs and hashes live here).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_ID=vision
STAGE="${STAGE:-/data/assets-staging/$OS_ID}"
OUT="${OUT:-/data/vms/streamhost/assets/$OS_ID}"
MEDIA="${MEDIA:-$OUT/media}"
DISK="${DISK:-$OUT/disk}"
ROOTFS="${ROOTFS:-$OUT/rootfs}"
# The container's uid 0 maps to this host uid. Distinct per sandboxed station
# (wave contract 2026-09-13: vision 2162688) and a multiple of 65536 so the
# 65536-uid range never overlaps another station's.
UID_BASE="${UID_BASE:-2162688}"
PCE_SRC=pce-20250420-cc0c583c
SUITE="${SUITE:-trixie}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
UA="Mozilla/5.0 (X11; Linux x86_64) kernel-hive-lab/1.0"

# Everything the sandbox needs at RUN time and at BUILD time. x11-apps is not
# decoration: vision-inner.sh polls the framebuffer with xwd to wait for the
# screen to settle instead of sleeping a guessed number of seconds, and a race
# runner lost its proof window on 2026-09-13 to a rootfs that had no xwd.
RUNTIME_PKGS="xvfb x11-utils x11-xkb-utils x11-apps xauth xdotool libx11-6 libxext6 python3"
BUILD_PKGS="build-essential libx11-dev libxext-dev pkgconf make"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

# name  size  sha256  origin URL — measured 2026-09-13 (stat -c %s, sha256sum)
# Visi On disks: WinWorld "Visi On 1.0" (https://winworldpc.com/product/visi-on/1x),
# each 7z = one title's disk pair as Kryoflux raw + SuperCard Pro .scp + TransCopy .TC.
# PC-DOS 2.00: WinWorld (https://winworldpc.com/product/pc-dos/2x).
# PCE (GPL, hampa.ch): the 2025-04-20 git snapshot — the 2014 snapshot the VOM used
# has rotated out of hampa.ch's /pub/pce/pre/ (oldest kept is 2021-08).
# MAME ibm5160 ROM set: archive.org mame-0.264-roms-non-merged.
SOURCES=(
  "VOAPP-1.0.7z 32863268 873b87d3d5fb068beaf4e9ef76e5ff65c5ddae41f2d09eb816398fae677c80f7 https://winworldpc.com/download/3910ba20-b30e-11ea-8b3c-fa163e9022f0"
  "VOCALC-1.0.7z 15907010 60c96a695047f039a8f18ada33cb8ac2e243b037d2fb8c7bf60737bf9f572da3 https://winworldpc.com/download/1f290193-b32c-11ea-8b14-fa163e9022f0"
  "VOGRAPH-1.0.7z 15232234 b50fd08377dd0afe26b82ed19961811cac2b712a98a8674482f6009310d2e4b4 https://winworldpc.com/download/8c90fc3a-b32c-11ea-8b14-fa163e9022f0"
  "VOWORD-1.0.7z 16210938 3f1bacde70437ba5f7d77596f03009dabdf4c744603e1ca8a5da75fd96388079 https://winworldpc.com/download/4c5dd471-b32d-11ea-8b14-fa163e9022f0"
  "IBM-PCDOS-2.00-5.25.7z 3382112 b47dff3322cd926e149521d5ce4d1e9246e0fc18291f1e8fc5d675ade8f9e351 https://winworldpc.com/download/e280a6c3-99c2-a1c5-bdc2-b4e280a011ef"
  "pce-20250420-cc0c583c.tar.gz 1113043 32a37f01bb9cabaa9cc5b5e0f72268755f3211430c57f83871da67c5aedd7117 http://www.hampa.ch/pub/pce/pre/pce-20250420-cc0c583c/pce-20250420-cc0c583c.tar.gz"
  "pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip 1405591 0f6a14b92c158c1cdf774818f1afed34de4404c84ee4470cee8def1cb532eec5 http://www.hampa.ch/pub/pce/pre/pce-20250420-cc0c583c/machines/pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip"
  "ibm5160.zip 145947 57f75c9dc87bed4b33cb9001b628774c1fcf1113bd4a0f650222709af82a2783 https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/ibm5160.zip"
  "isa_hdc.zip 5558 a732c67b3716b3eb92bf401904ebfcad3a0b826f7f118f6c2c0a966729900639 https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/isa_hdc.zip"
)

verify() { # verify <file> <size> <sha256>
  [ -f "$1" ] || return 1
  [ "$(stat -c %s "$1")" = "$2" ] || return 1
  [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$3" ]
}

do_fetch() {
  mkdir -p "$STAGE"
  local row name size sha url
  for row in "${SOURCES[@]}"; do
    read -r name size sha url <<<"$row"
    if verify "$STAGE/$name" "$size" "$sha"; then
      log "ok       $name ($size bytes)"
      continue
    fi
    log "fetching $name from $url"
    curl -fsSL -A "$UA" -o "$STAGE/$name.part" "$url"
    mv "$STAGE/$name.part" "$STAGE/$name"
    verify "$STAGE/$name" "$size" "$sha" || die "$name: size/sha256 mismatch after fetch (expected $size / $sha)"
  done
  (cd "$STAGE" && sha256sum "${SOURCES[@]%% *}" >MANIFEST.sha256)
  log "staged at $STAGE (MANIFEST.sha256 written)"
}

do_unpack() {
  local row name size sha url
  for row in "${SOURCES[@]}"; do
    read -r name size sha url <<<"$row"
    verify "$STAGE/$name" "$size" "$sha" || die "$name missing or wrong in $STAGE — run --fetch"
  done
  mkdir -p "$MEDIA/tc" "$MEDIA/pcdos" "$MEDIA/pce" "$MEDIA/roms"
  # the four Visi On titles: only the TransCopy members (the .scp flux dumps are
  # the same disks in a format neither emulator reads; they stay in the archive)
  local a
  for a in VOAPP VOCALC VOGRAPH VOWORD; do
    7z e -y -o"$MEDIA/tc" "$STAGE/$a-1.0.7z" '*/Transcopy/*.TC' >/dev/null
  done
  7z e -y -o"$MEDIA/pcdos" "$STAGE/IBM-PCDOS-2.00-5.25.7z" '*/Disk0?.img' >/dev/null
  unzip -qo "$STAGE/pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip" 'rom/*' hd0.pbi pce-5160.cfg -d "$MEDIA/pce"
  unzip -qo "$STAGE/ibm5160.zip" -d "$MEDIA/roms"
  unzip -qo "$STAGE/isa_hdc.zip" -d "$MEDIA/roms"
  # measured 2026-09-13: every .TC is 1114112 bytes, every PC-DOS image 184320
  local f
  for f in "$MEDIA"/tc/*.TC; do [ "$(stat -c %s "$f")" = 1114112 ] || die "$f: not a 1114112-byte TransCopy image"; done
  for f in "$MEDIA"/pcdos/Disk0?.img; do [ "$(stat -c %s "$f")" = 184320 ] || die "$f: not a 360K image"; done
  log "unpacked: $(find "$MEDIA/tc" -name '*.TC' | wc -l) TransCopy disks, $(find "$MEDIA/pcdos" -name '*.img' | wc -l) PC-DOS images, PCE ROMs + hd0.pbi, MAME roms"
}

# --- the sandbox rootfs -------------------------------------------------------
# Built ONCE and shipped as a station asset. The launcher runs it with
# --volatile=overlay, so nothing a visitor does ever reaches these bytes; the
# only writable thing in the container is the station's own work/ bind.
#
# The uid shift happens HERE, once, not at every launch: nspawn's
# --private-users-ownership=chown would walk the whole tree on every start.
# Shifted once at build time, the launcher passes
# --private-users-ownership=off and starts instantly.
#
# PCE is compiled INSIDE the rootfs (via systemd-nspawn, not chroot — a chroot
# here would need chroot-guard and buys nothing), so the binary links against
# the trixie libraries it will actually run against.
do_rootfs() {
  command -v debootstrap >/dev/null || die "debootstrap not installed"
  command -v systemd-nspawn >/dev/null || die "systemd-nspawn not installed"
  [ "$(id -u)" = 0 ] || die "--rootfs needs root (debootstrap + the uid shift)"
  verify "$STAGE/$PCE_SRC.tar.gz" 1113043 32a37f01bb9cabaa9cc5b5e0f72268755f3211430c57f83871da67c5aedd7117 ||
    die "$PCE_SRC.tar.gz missing or wrong in $STAGE — run --fetch"

  local tmp="$ROOTFS.staging"
  rm -rf "$tmp"
  mkdir -p "$(dirname "$tmp")"
  log "debootstrap --variant=minbase $SUITE (this is the slow part, ~3 min)"
  debootstrap --variant=minbase "$SUITE" "$tmp" "$MIRROR" >/dev/null

  log "installing runtime + build packages"
  # shellcheck disable=SC2086
  systemd-nspawn -q -D "$tmp" --resolv-conf=copy-host \
    env DEBIAN_FRONTEND=noninteractive sh -c \
    "apt-get -qq update && apt-get -qq install -y --no-install-recommends $RUNTIME_PKGS $BUILD_PKGS" >/dev/null

  log "building PCE $PCE_SRC inside the rootfs -> /opt/pce"
  mkdir -p "$tmp/src"
  tar -C "$tmp/src" -xzf "$STAGE/$PCE_SRC.tar.gz"
  # Pointer patch (docs/lab/VISION-WAVE.md §Pointer, theory A of the pointer
  # race): stock PCE's x11 terminal forwards mouse motion only while it holds
  # an X pointer grab, which a headless Xvfb station can never take. Applies
  # cleanly to the pinned tarball with -p1.
  # Mouse Systems sync-alias patch (VISION-WAVE.md §POINTER DELIVERY pass): a dx
  # of -127..-121 encodes as a byte identical to the protocol's own sync byte, so
  # Visi On's driver throws the packet away — which is why every large LEFTWARD
  # move was lost and the arrow ratcheted into the right edge and wedged there.
  local pt
  for pt in pce-x11-nograb.patch pce-msys-sync-alias.patch; do
    local patch="$SCRIPT_DIR/../patches/vision/$pt"
    [ -f "$patch" ] || die "missing pointer patch: $patch"
    patch -p1 -d "$tmp/src/$PCE_SRC" <"$patch" || die "$pt failed to apply to $PCE_SRC"
  done
  systemd-nspawn -q -D "$tmp" sh -c "
    set -e
    cd /src/$PCE_SRC
    ./configure --prefix=/opt/pce --enable-ibmpc --with-x \
      --without-sdl --enable-char-pty >/dev/null
    make -j\"\${JOBS:-4}\" >/dev/null
    make install >/dev/null
  " || die "PCE build failed inside the rootfs"
  [ -x "$tmp/opt/pce/bin/pce-ibmpc" ] || die "no /opt/pce/bin/pce-ibmpc after make install"
  [ -x "$tmp/opt/pce/bin/psi" ] || die "no /opt/pce/bin/psi after make install"

  # the build tree is not shipped: it is the only writable-looking thing a
  # visitor could ever see, and it is 40 MB of C we do not need at run time
  rm -rf "$tmp/src" "$tmp/var/cache/apt/archives"/*.deb

  log "uid-shifting the tree to base $UID_BASE (once, so the launcher can use ownership=off)"
  # every uid/gid u becomes u + UID_BASE; nspawn's --private-users=$UID_BASE:65536
  # then maps them back to 0..65535 inside the container
  find "$tmp" -xdev \( -type d -o -type f -o -type l \) -print0 |
    xargs -0 -r -n 200 stat -c '%u %g %n' |
    while read -r u g n; do
      chown -h "$((u + UID_BASE)):$((g + UID_BASE))" "$n"
    done
  rm -rf "$ROOTFS"
  mv "$tmp" "$ROOTFS"
  log "rootfs at $ROOTFS ($(du -sh "$ROOTFS" | cut -f1), uid base $UID_BASE, pce-ibmpc + psi in /opt/pce/bin)"
}

# --- the disk set and the config ----------------------------------------------
# Three artefacts, and they are ONE combination with the launcher (rule 6):
#   disk/hd0.pbi      the 10 MB XT fixed disk with PC-DOS 2.00 and Visi On 1.0
#                     installed (provenance below)
#   disk/VOAPP1.psi   the Application Manager KEY DISK, in A: at every start
#   disk/VOAPP2.psi   Application Manager disk 2, in B:
#   pce.cfg           the 5160 machine description
#
# WHY .psi AND NOT A SECTOR IMAGE. Visi On 1.0 is copy protected and VOAPP1 is
# the key disk: the check reads track data a plain sector image cannot carry.
# The WinWorld dumps are TransCopy (.TC), which PCE reads but cannot write back
# on eject; PCE's own `psi` converts .TC to .psi, which keeps the protection AND
# is writable. Converting to .img here would boot to a "not an original disk"
# refusal — this is the trap that costs an afternoon.
do_compose() {
  [ -d "$MEDIA/tc" ] || die "no unpacked media at $MEDIA — run --unpack"
  local PSI="$ROOTFS/opt/pce/bin/psi"
  [ -x "$PSI" ] || die "no psi at $PSI — run --rootfs"
  mkdir -p "$DISK"

  log "converting the TransCopy disks to PCE .psi (the protection lives in the flux)"
  local f base
  for f in "$MEDIA"/tc/*.TC; do
    base="$(basename "$f" .TC)"
    "$PSI" -i "$f" -o "$DISK/$base.psi" || die "psi failed on $f"
  done
  for f in VOAPP1 VOAPP2; do
    [ -s "$DISK/$f.psi" ] || die "no $DISK/$f.psi after conversion"
  done

  # --- the installed hard disk -------------------------------------------------
  # PROVENANCE. hd0.pbi is the PCE XT bundle's own 10 MB PC-DOS 2.00 image
  # (hampa.ch, inside pce-20250420-cc0c583c-ibm-xt-pcdos-2.00.zip, hashed above)
  # with Visi On 1.0 installed onto it ONCE, by hand, on the race rig of
  # 2026-09-13. The install is not replayed here because VINSTALL is an
  # interactive full-screen installer with a mid-run disk swap; the exact
  # keystrokes and the monitor commands that drive it are written down in
  # docs/lab/VISION-WAVE.md §Installing Visi On, so the disk can be rebuilt from
  # the hashed inputs by hand in about ten minutes. The installed image is a
  # station asset under /data (never committed — rule 1, the gallery is private).
  local INSTALLED="${INSTALLED_HD:-$STAGE/hd0-visi-on-installed.pbi}"
  if [ -f "$INSTALLED" ]; then
    cp --reflink=auto "$INSTALLED" "$DISK/hd0.pbi"
    log "staged the installed hard disk from $INSTALLED"
  elif [ -f "$DISK/hd0.pbi" ]; then
    log "keeping the existing $DISK/hd0.pbi"
  else
    die "no installed hard disk: put it at $INSTALLED (see docs/lab/VISION-WAVE.md §Installing Visi On) or set INSTALLED_HD"
  fi
  [ "$(stat -c %s "$DISK/hd0.pbi")" -gt 900000 ] || die "$DISK/hd0.pbi looks truncated"

  # --- the machine -------------------------------------------------------------
  mkdir -p "$OUT/rom"
  cp "$MEDIA"/pce/rom/*.rom "$OUT/rom/"
  write_pce_cfg >"$OUT/pce.cfg"

  # The container reads $OUT read-only as host uid $VISION_UID_BASE (2162688),
  # not as root -- a caller with a restrictive umask (root's non-interactive
  # ssh shells default to one) leaves the disk/rom files at 0400/0600 root-only,
  # which the sandbox cannot read at all ("*** loading failed", measured
  # 2026-09-13). Every sibling station's assets/ tree is world-readable
  # (0755 dirs, 0644 files under root:root, e.g. lisa/medley); match that
  # regardless of the caller's umask rather than depending on it.
  chmod a+rx "$OUT"
  chmod -R a+rX "$OUT/rom" "$DISK"
  chmod a+r "$OUT/pce.cfg"

  log "staged: $DISK (hd0.pbi + $(find "$DISK" -name "*.psi" | wc -l) .psi disks), $OUT/rom, $OUT/pce.cfg"
}

# The 5160 the station emulates. Kept in the builder rather than committed as a
# separate file so the ROM paths and the /work disk paths can never drift from
# what x11-runtime.sh copies into place.
#   boot = 128  -> boot the FIXED DISK, not A:. Visi On's key disk lives in A:
#                  permanently, and an XT would otherwise try to boot from it.
#   cpu.speed=1 -> a real 4.77 MHz 8088. Visi On is timing-fragile and misbehaves
#                  on anything faster; this is the only throttle worth touching.
#   scale = 2   -> with PCE's 4/3 aspect correction, CGA 640x200 becomes exactly
#                  1280x800, which is the Xvfb root. Change one, change both.
#   serial mouse -> Mouse Systems protocol on COM1. Visi On drives the 8250
#                  itself; there is no DOS mouse driver anywhere in this station.
write_pce_cfg() {
  cat <<'CFG'
# vision station — IBM 5160 XT for VisiCorp Visi On 1.0.
# Generated by scripts/build-guests/tiles/vision.sh; do not hand-edit the copy
# under /data/vms/streamhost/assets/vision — edit the builder.
# @ASSETS@ is substituted by x11-runtime.sh when it copies this into the
# launch's work/ dir: the assets are bound into the container at their own HOST
# path (so /proc/<pid>/exe of the sandboxed PCE reads as a host path and the
# daemon's SH_IDLE_PAUSE_PROC_MATCH keeps working), and that path is not known
# until launch. The disk paths below are NOT substituted — /work is the one
# writable bind and is always mounted there.
system {
	model = "5160"
	boot = 128
	rtc  = 1
	memtest = 0
	floppy_disk_drives = 2
	patch_bios_init  = 0
	patch_bios_int19 = 0
}

cpu {
	model = "8088"
	speed = 1
}

load { format = "binary" address = 0xfe000 file = "@ASSETS@/rom/ibm-xt-1982-11-08.rom" }
load { format = "binary" address = 0xf6000 file = "@ASSETS@/rom/ibm-basic-1.10.rom" }
load { format = "binary" address = 0xc8000 file = "@ASSETS@/rom/ibm-hdc-1985.rom" }

ram { address = 0 size = 640K }
rom { address = 0xf6000 size = 40K }
rom { address = 0xc8000 size = 32K }

terminal {
	driver = "x11"
	scale = 2
	# The pointer patch (docs/lab/VISION-WAVE.md §Pointer) forwards raw
	# WINDOW-PIXEL motion deltas with no grab; these divide them back down to
	# CGA-pixel deltas so 1 CGA pixel of guest cursor motion == 1 CGA pixel of
	# XTEST motion. PCE's own aspect correction at `scale = 2` on 640x200 CGA
	# is asymmetric: fx=2 (1280/640) but fy=4 (800/200), NOT the uniform x2 the
	# scale name suggests (trm_get_scale() in terminal.c stretches the Y axis
	# alone to hit the 4:3 aspect ratio, since CGA pixels are not square).
	# Measured/derived, not guessed — see the wave doc for the arithmetic.
	mouse_mul_x = 1
	mouse_div_x = 2
	mouse_mul_y = 1
	mouse_div_y = 4
}

video {
	device = "cga"
	font   = 0
	blink  = 30
}

serial {
	uart      = "8250"
	address   = 0x3f8
	irq       = 4
	multichar = 1
	driver = "mouse:protocol=msys:xmul=1:xdiv=1:ymul=1:ydiv=1"
}

fdc { address = 0x3f0 irq = 6 drive0 = 0x00 drive1 = 0x01 accurate = 1 }
hdc { address = 0x320 irq = 5 drive0 = 0x80 switches = 0b00000000 }

# Every image lives in the WRITABLE /work bind, never in a --bind-ro: PCE writes
# .psi floppies back on eject and Visi On writes to C:. A read-only media bind
# makes the guest see a dead drive (docs/lab/VISION-WAVE.md §Traps).
disk { drive = 0x00 type = "auto" optional = 1 file = "/work/VOAPP1.psi" }
disk { drive = 0x01 type = "auto" optional = 1 file = "/work/VOAPP2.psi" }
disk { drive = 0x80 type = "auto" optional = 1 file = "/work/hd0.pbi" }
CFG
}

case "${1:-all}" in
  --fetch) do_fetch ;;
  --unpack) do_unpack ;;
  --rootfs) do_rootfs ;;
  --compose) do_compose ;;
  all)
    do_fetch
    do_unpack
    do_rootfs
    do_compose
    ;;
  *) die "usage: $0 [--fetch|--unpack|--rootfs|--compose]" ;;
esac
