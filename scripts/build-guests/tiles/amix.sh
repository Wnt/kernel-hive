#!/bin/bash
# =============================================================================
# tiles/amix.sh — build the Amiga UNIX (AMIX) 2.1 system disk for the
# host-native FS-UAE station (no QEMU anywhere in this builder).
#
# What is FULLY automated (stage: assemble):
#   * media fetch + hash gate — the AMIX 2.1 boot/root floppies and the two
#     installation-tape archives from amigaunix.com, and the A3000 Kickstart
#     2.04 r37.175 from the archive.org `commodore-amiga-firmware` item;
#   * the UAE tape directory — the 29 cpio segments 00..28 plus the
#     `index.tape` that names them in the tape's own `seglist` order.
#     index.tape is MANDATORY: without it UAE's directory-scan branch has an
#     inverted filename test and the tape reads as empty with no error
#     (docs/guests/amix.md, trap 1);
#   * both fs-uae configs — install (floppies + tape at SCSI 4 + blank 2 GB
#     RDB disk at SCSI 6) and station (golden only, 640x512, stretch=1 for
#     the mono golden; the colour golden wants the A2410 declared and a
#     1024x768 window -- see docs/guests/amix.md "Ready scene / golden").
#
# What is VISION-DRIVEN, not blind (stage: install): the AMIX install script
# is an interactive SVR4 shell script with no unattended interface. fs-uae
# runs under a namespaced Xvfb and the operator (or a vision agent) answers
# the prompts, screenshotting each step. The full answer sequence is printed
# by `--answers` and recorded in docs/guests/amix.md. Budget ~20 min for the
# UFS mkfs and ~2 h for the 296.7 MB tape restore.
#
# Output (ONE combination with the emulator binary):
#   $OUT/amix-system.hdf — the installed system disk (golden master).
#   No statefile: the station cold-boot resets.
#   BAKE RULE: halt the guest with /sbin/shutdown -y -g0 -i0 before copying
#   the golden. UFS has no host-repairable dirty flag, so a golden taken from
#   a killed emulator makes every visitor's boot run a full fsck.
#
# The 2026-08-30 bring-up ran these stages in /data/vms/sandbox/amix/rig
# (kept as evidence); this script encodes that recipe.
# docs/guests/amix.md is the narrative.
# =============================================================================
set -euo pipefail

OS_ID=amix
ASSETS="${AMIX_ASSETS:-/data/assets-staging/$OS_ID}"
WORK="${AMIX_WORK:-/data/vms/sandbox/$OS_ID/rig}"
OUT="${AMIX_OUT:-/data/gallery-guests/AmigaUNIX}"
FSUAE="${FSUAE_BIN:-/data/vms/streamhost/assets/$OS_ID/fsuae-native/bin/fs-uae}"
DISPLAY_NUM="${AMIX_DISPLAY:-77}"

BASE_URL=https://www.amigaunix.com/lib/exe/fetch.php/downloads%3A
KICK_URL='https://archive.org/download/commodore-amiga-firmware/Kickstart%20v2.04%20r37.175%20%281991-05%29%28Commodore%29%28A3000%29.zip'
KICK_MD5=b5e9a3bfc91abe121d973005d55a8ae2

# sha256 of the four amigaunix.com archives, as fetched 2026-08-30.
read -r -d '' MEDIA_SHA256 <<'SUMS' || true
5b0a9d988685c5a0b2db0a113d8549d52acdbc4687757b6b9f898f1ed34ccbbb  amix_2.1_boot.adf.bz2
adb24869e74e7fde703a67f8aa7d72ec3abaddce0211b83f7e9c214c4ebf6621  amix_2.1_root.adf.bz2
1427f68361b85adedaba4ebc2be1f27d08a9854b08a69500331111e03b01cf59  amix_2.1_tape_part1.tar.bz2
ae7b0884da7cad16a8c8edd0416faa7974d55ea70905d3f39356544e185abed4  amix_2.1_tape_part2.tar.bz2
SUMS

usage() {
  cat <<'USAGE'
usage: amix.sh <stage>
  fetch     download + hash-verify the media into $AMIX_ASSETS
  assemble  unpack floppies, build the tape dir + index.tape, write both configs
  install   launch fs-uae on the install config (interactive; see --answers)
  answers   print the AMIX install script's answer sequence
  scene     print the ready-scene files (kh-shell, kh-xres, kh-xsession, inittab)
  bake      copy the (cleanly halted) work disk to $OUT as the golden master
USAGE
}

die() {
  echo "amix.sh: $*" >&2
  exit 1
}

stage_fetch() {
  mkdir -p "$ASSETS"
  local f
  for f in amix_2.1_boot.adf.bz2 amix_2.1_root.adf.bz2 \
    amix_2.1_tape_part1.tar.bz2 amix_2.1_tape_part2.tar.bz2; do
    [ -f "$ASSETS/$f" ] || curl -fsSL --retry 3 -o "$ASSETS/$f" "$BASE_URL$f"
  done
  (cd "$ASSETS" && printf '%s\n' "$MEDIA_SHA256" | sha256sum -c -) ||
    die "media hash gate FAILED — refusing to build on unverified bits"

  if [ ! -f "$ASSETS/kick37175.A3000.rom" ]; then
    curl -fsSL -o "$ASSETS/ks204.zip" "$KICK_URL"
    echo "$KICK_MD5  $ASSETS/ks204.zip" | md5sum -c - ||
      die "Kickstart md5 gate FAILED"
    unzip -o -q "$ASSETS/ks204.zip" -d "$ASSETS/ks204"
    mv "$ASSETS"/ks204/*.rom "$ASSETS/kick37175.A3000.rom"
  fi
  echo "amix.sh: media verified in $ASSETS"
}

stage_assemble() {
  [ -d "$ASSETS" ] || die "no $ASSETS — run: amix.sh fetch"
  mkdir -p "$WORK/tape"

  bunzip2 -kfc "$ASSETS/amix_2.1_boot.adf.bz2" >"$WORK/amix_2.1_boot.adf"
  bunzip2 -kfc "$ASSETS/amix_2.1_root.adf.bz2" >"$WORK/amix_2.1_root.adf"
  cp -f "$ASSETS/kick37175.A3000.rom" "$WORK/kick37175.A3000.rom"

  tar xjf "$ASSETS/amix_2.1_tape_part1.tar.bz2" -C "$WORK"
  tar xjf "$ASSETS/amix_2.1_tape_part2.tar.bz2" -C "$WORK"
  cp -f "$WORK"/Tape_Amiga_Unix_2.1/[0-9][0-9] "$WORK/tape/"

  # index.tape: the read order, one filename per line. Segment NN is the
  # NN-th name in the tape's own seglist, so plain 00..28 IS that order.
  local n
  : >"$WORK/tape/index.tape"
  for n in $(seq -w 0 28); do
    [ -f "$WORK/tape/$n" ] || die "tape segment $n missing"
    echo "$n" >>"$WORK/tape/index.tape"
  done

  [ -f "$WORK/amix.hdf" ] || truncate -s 2G "$WORK/amix.hdf"

  cat >"$WORK/config.install.fs-uae" <<CFG
[fs-uae]
amiga_model = A3000
kickstart_file = $WORK/kick37175.A3000.rom
motherboard_ram = 16384
floppy_drive_0 = $WORK/amix_2.1_boot.adf
floppy_image_0 = $WORK/amix_2.1_boot.adf
floppy_image_1 = $WORK/amix_2.1_root.adf
hard_drive_0 = $WORK/amix.hdf
hard_drive_0_type = rdb
hard_drive_0_controller = scsi6
uae_uaehf1 = tape4,ro,TAPE:$WORK/tape,0,0,0,512,0,,scsi4
fullscreen = 0
window_width = 1050
window_height = 768
automatic_input_grab = 0
initial_input_grab = 0
keyboard_key_f9 = action_drive_0_insert_floppy_0
keyboard_key_f10 = action_drive_0_insert_floppy_1
CFG

  cat >"$WORK/config.station.fs-uae" <<CFG
[fs-uae]
amiga_model = A3000
kickstart_file = $WORK/kick37175.A3000.rom
motherboard_ram = 16384
hard_drive_0 = $WORK/work.hdf
hard_drive_0_type = rdb
hard_drive_0_controller = scsi6
fullscreen = 0
window_width = 640
window_height = 512
stretch = 1
automatic_input_grab = 0
initial_input_grab = 0
CFG
  echo "amix.sh: assembled in $WORK (tape: $(wc -l <"$WORK/tape/index.tape") segments)"
}

stage_install() {
  [ -x "$FSUAE" ] || die "no fs-uae at $FSUAE — run: FSUAE_STATION=amix build-fsuae-native.sh"
  [ -f "$WORK/config.install.fs-uae" ] || die "run: amix.sh assemble"
  Xvfb ":$DISPLAY_NUM" -screen 0 1050x768x24 -nolisten tcp >/dev/null 2>&1 &
  echo $! >"$WORK/xvfb.pid"
  sleep 2
  DISPLAY=":$DISPLAY_NUM" LIBGL_ALWAYS_SOFTWARE=1 \
    "$FSUAE" "$WORK/config.install.fs-uae" >"$WORK/fsuae.log" 2>&1 &
  echo $! >"$WORK/fsuae.pid"
  echo "amix.sh: installer running on :$DISPLAY_NUM — drive it with the answers below"
  stage_answers
}

stage_answers() {
  cat <<'ANSWERS'
AMIX 2.1 install — answer sequence (screenshot every step; the framebuffer is
the only proof). F10 inserts the root floppy when disk 2 is asked for.

  Insert floppy disk 2 (root file system)   -> F10, then RETURN
  Which keyboard are you using? [12]        -> RETURN   (usa, American)
  Do you want to install or repair?         -> RETURN   (install)
  Insert UNIX installation tape             -> RETURN   (the emulated tape)
  How many megabytes for AmigaDOS? [0]      -> RETURN
  How many megabytes for root? [2015]       -> RETURN
  How many megabytes for swap? [30]         -> RETURN
  What file system type is the root? [s5]   -> ufs      (NOT the default)
  Choose: (1) Standard (2) Everything (3)   -> 2        (guarantees X + OPEN LOOK)
  ... mkfs ~20 min, tape restore ~2 h ...
  system halted -> restart fs-uae WITHOUT floppy_drive_0 to boot from disk

First boot (system configuration):
  nodename [localhost]                      -> amix
  network domain [.uucp]                    -> RETURN
  small network hosts file? [n]             -> RETURN
  timezone [47]                             -> 27       (EET)
  date / time                               -> RETURN, RETURN  (period 1992)
  password for system accounts? [y]         -> n
  password for guest? [n]                   -> RETURN
  create a user account? [n]                -> y ; amixuser ; Kernel Hive visitor
  password for your user account? [n]       -> RETURN
  A2024 or Moniterm monitor? [n]            -> RETURN
  configure X for a color graphics card?    -> y, then 1 (A2410), then q
      NOTE: this configures the kernel's tiga driver only. The X server drives
      the board only when started with -tiga (colour golden); without the flag
      it paints the chipset screen, 640x512 depth 1. See docs/guests/amix.md.
  configure Netnews? [n]                    -> RETURN
  change any of these? [n]                  -> RETURN

Ready scene (as root, once at the amix login: prompt): the four files that
  `amix.sh scene` prints, verbatim -- /etc/kh-shell, /etc/kh-xres,
  /etc/kh-xsession and the inittab line. Then:
    /sbin/shutdown -y -g0 -i0     (ABSOLUTE path -- /usr/ucb/shutdown is
                                   a different command and rejects these flags)
ANSWERS
}

# The ready scene, byte for byte. Two rules are baked into kh-xsession and both
# were paid for on the live station (docs/guests/amix.md "Ready scene"):
#   1. olwm FIRST, clients only after OL_MANAGER_STATE is on the root. Started
#      the other way round the clients raced the window manager on the 25 MHz
#      emulated 68030: a window that mapped before olwm's adoption scan came up
#      27 px above its requested position, and ~1 cold boot in 5 lost xclock.
#   2. The xterm's frame covers the origin AND the screen centre. Focus follows
#      the pointer, streamhost restates its (0,0) target the moment it connects
#      to the guest X server, and the server itself starts the pointer at the
#      centre -- so wherever the pointer is on arrival, the shell has the keys.
stage_scene() {
  cat <<'SCENE'
--- /etc/kh-shell (chmod 755)
#!/bin/sh
uname -a
echo
exec /bin/sh
--- /etc/kh-xres
*windowFrameColor: gray82
*inputWindowHeader: SteelBlue4
*pointerFocus: true
--- /etc/kh-xsession (chmod 755; /etc/kh-xsession.mono is the same without
--- xrdb/xsetroot and with the chipset geometry, see docs/guests/amix.md)
#!/bin/sh
# /etc/kh-xsession -- the Kernel Hive ready scene (colour, A2410), run by xinit
# from the inittab entry xw. ORDER IS THE POINT: olwm must own the root's
# SubstructureRedirect before any client maps. When the clients were started
# first they raced olwm (2026-09-02): a window that mapped before olwm was up
# was ADOPTED (frame stacked 27 px above the requested position) instead of
# placed through MapRequest, and about one cold boot in five lost xclock.
PATH=/usr/bin:/usr/bin/X11:/usr/ucb:/etc:/usr/sbin; export PATH; HOME=/; export HOME
xrdb -merge /etc/kh-xres
xsetroot -solid SteelBlue
(
  # olwm publishes OL_MANAGER_STATE on the root once it is managing: wait for
  # that condition, not for a fixed time (bounded so a broken olwm still
  # leaves a usable screen)
  n=0
  until xprop -root OL_MANAGER_STATE 2>/dev/null | grep 0x >/dev/null; do
    n=`expr $n + 1`; [ $n -gt 120 ] && break; sleep 1
  done
  xclock -bg LightYellow -fg black -hd black -hl red -geometry 120x120+860+30 2>/tmp/xclock.err &
  xcalc -bg gray85 -geometry +640+60 2>/tmp/xcalc.err &
  # focus follows the pointer (*pointerFocus). The xterm's frame covers BOTH
  # the origin (streamhost restates its (0,0) target on connect) and the
  # screen centre (where the X server starts the pointer), so the shell
  # holds the keyboard from the first frame with no warp of our own.
  xterm -bg white -fg black -geometry 86x30+0+0 -T "Amiga UNIX 2.1" -e /etc/kh-shell 2>/tmp/xterm.err &
  /usr/bin/X11/xhost +slirphost >/tmp/xhost.log 2>&1
) &
exec olwm 2>/tmp/olwm.err
--- append to /etc/inittab (drop -tiga for the mono golden)
xw:2:respawn:/usr/bin/X11/xinit /etc/kh-xsession -- /usr/bin/X11/X -tiga >/dev/null 2>&1
SCENE
}

stage_bake() {
  [ -f "$WORK/amix.hdf" ] || die "no installed disk at $WORK/amix.hdf"
  if pgrep -f "$WORK/config" >/dev/null 2>&1; then
    die "an emulator is still running on this rig — halt the guest with /sbin/shutdown first"
  fi
  mkdir -p "$OUT"
  cp --sparse=always "$WORK/amix.hdf" "$OUT/amix-system.hdf"
  echo "amix.sh: golden master at $OUT/amix-system.hdf"
  echo "amix.sh: REMINDER — this is only clean if the guest was halted with /sbin/shutdown"
}

case "${1:-}" in
  fetch) stage_fetch ;;
  assemble) stage_assemble ;;
  install) stage_install ;;
  answers) stage_answers ;;
  scene) stage_scene ;;
  bake) stage_bake ;;
  *)
    usage
    exit 1
    ;;
esac
