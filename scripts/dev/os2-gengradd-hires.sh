#!/bin/bash
# os2-gengradd-hires.sh — reproduce the os2warp hi-res fix on a scratch clone.
#
# WHAT IT FIXES
#   OS/2's IBM GRADD display stack traps c0000005 in GENPMI.DLL/VIDEOPMI.DLL at
#   display init on QEMU `-vga std`, which pinned the os2warp station to 640x480.
#   The cause is NOT the missing VBE Protected Mode Interface (fn 4F0Ah) that the
#   earlier investigation assumed: GENPMI never calls 4F0Ah. It enumerates modes
#   through the OS/2 mini-VDM (real-mode INT 10h 4F00/4F01) into two fixed
#   64-entry buffers with no bounds check. SeaVGABIOS advertises 93 modes at
#   QEMU's default vgamem_mb=16, so the copy runs off the stack. VirtualBox — where
#   GENGRADD has always worked — advertises 36.
#
#   Capping the adapter at `-global VGA.vgamem_mb=2` trims SeaVGABIOS to 46 modes,
#   which still includes 1024x768x64k and 1280x1024x256. That single flag is the
#   whole fix: no QEMU rebuild, no custom VGA BIOS ROM, no OS/2 binary patching.
#
#   The second half is guest-side: the station's 4.52 build had its GRADD DLLs
#   overwritten by a failed SciTech SNAP install, so IBM's originals must be
#   restored from the MCP2 CD and SNAP's `\OS2\SVGADATA.PMI` (a one-line
#   `#includecode "sddpmi.dll"` stub) moved aside — otherwise BVHSVGA loads SNAP's
#   PMI and the boot dies with "Unable to open SDDHELP$ helper device driver!".
#
# USAGE
#   os2-gengradd-hires.sh prep <clone-dir> [source.qcow2]  # offline disk surgery
#   os2-gengradd-hires.sh run  <clone-dir> [cold|golden]   # launch the clone
#   os2-gengradd-hires.sh shot <clone-dir> [name]          # screendump -> PNG
#
#   Run it ON the box. <clone-dir> MUST live under /data/vms/soltest (clone-guard
#   refuses anything else). `prep` needs the guest's IBM GRADD files already
#   staged in C:\IBMGRADD — extract them in-guest with the MCP2 CD mounted:
#     UNPACK2 E:\OS2IMAGE\DISP_1\VGA     C:\IBMGRADD     (GENPMI, BVHSVGA, VIDEOPMI…)
#     UNPACK2 E:\OS2IMAGE\DISK_4\GRADD   C:\IBMGRADD     (GENGRADD, VGAGRADD, GRE2VMAN)
#     UNPACK2 E:\OS2IMAGE\DISK_4\BUNDLE  C:\IBMGRADD /N:VMAN.DLL
#     UNPACK2 E:\OS2IMAGE\DISK_1\BUNDLE  C:\IBMGRADD /N:GRADD.SYS
#     UNPACK2 E:\OS2IMAGE\DISK_3\BUNDLE  C:\IBMGRADD /N:SBFILTER.DLL
#   After `run`, pick the resolution in System Setup -> System -> Screen and reboot.
#
# Full write-up + the live cutover record: docs/guests/os2warp.md.
set -euo pipefail

CLONE_ROOT=/data/vms/soltest
NBD=${NBD:-/dev/nbd6}
MNT=${MNT:-/mnt/os2gradd}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESKTOP_OBJECTS_CMD="$REPO_ROOT/scripts/build-guests/assets/os2warp/create-desktop-objects.cmd"

die() {
  echo "os2-gengradd-hires: $*" >&2
  exit 1
}

guard_dir() {
  case "$1" in
    "$CLONE_ROOT"/*) ;;
    *) die "clone dir must live under $CLONE_ROOT (got '$1')" ;;
  esac
}

# ---- prep: restore IBM GRADD, neutralize SNAP's PMI, select the GENGRADD chain --
cmd_prep() {
  local d="$1" src="${2:-}"
  guard_dir "$d"
  mkdir -p "$d"
  if [ -n "$src" ]; then
    [ -f "$src" ] || die "source image '$src' not found"
    cp --reflink=auto "$src" "$d/disk.qcow2"
  fi
  [ -f "$d/disk.qcow2" ] || die "no $d/disk.qcow2 (pass a source image)"
  [ -f "$d/qemu.pid" ] && /usr/local/bin/clone-guard kill-pidfile "$d/qemu.pid" 2>/dev/null || true

  modprobe nbd max_part=8 2>/dev/null || true
  qemu-nbd -c "$NBD" "$d/disk.qcow2"
  sleep 1
  partprobe "$NBD" 2>/dev/null || true
  sleep 1
  mkdir -p "$MNT"
  mount "${NBD}p1" "$MNT"
  trap 'umount "$MNT" 2>/dev/null || true; qemu-nbd -d "$NBD" >/dev/null 2>&1 || true' EXIT

  [ -d "$MNT/IBMGRADD" ] || die "C:\\IBMGRADD not staged — see the UNPACK2 recipe in this script's header"

  local f src_f dst_f
  for f in GENGRADD.DLL GENPMI.DLL VMAN.DLL GRE2VMAN.DLL VGAGRADD.DLL \
    SBFILTER.DLL BVHSVGA.DLL BVHVGA.DLL VIDEOPMI.DLL IBMGPMI.DLL DISPLAY.DLL; do
    src_f=$(find "$MNT/IBMGRADD" -maxdepth 1 -iname "$f" | head -1)
    dst_f=$(find "$MNT/OS2/DLL" -maxdepth 1 -iname "$f" | head -1)
    if [ -n "$src_f" ] && [ -n "$dst_f" ]; then
      cp "$src_f" "$dst_f"
      echo "  restored $f"
    fi
  done
  for f in GRADD.SYS SCREEN01.SYS; do
    src_f=$(find "$MNT/IBMGRADD" -maxdepth 1 -iname "$f" | head -1)
    dst_f=$(find "$MNT/OS2" -maxdepth 1 -iname "$f" | head -1)
    if [ -n "$src_f" ] && [ -n "$dst_f" ]; then
      cp "$src_f" "$dst_f"
      echo "  restored $f"
    fi
  done

  # SNAP's SVGADATA.PMI (`#includecode "sddpmi.dll"`) makes BVHSVGA pull in the
  # SNAP engine, which dies on the missing SDDHELP$ driver. IBM's GENGRADD needs
  # no PMI file at all.
  if [ -f "$MNT/OS2/SVGADATA.PMI" ] && grep -qi sddpmi "$MNT/OS2/SVGADATA.PMI"; then
    mv "$MNT/OS2/SVGADATA.PMI" "$MNT/OS2/SVGADATA.SDDBAK"
    echo "  SVGADATA.PMI (SNAP stub) -> SVGADATA.SDDBAK"
  fi

  # CONFIG.SYS: base video stays plain VGA (BVHVGA); PM display = GENGRADD chain.
  # MUST stay CRLF — LF-only makes OS/2 mis-parse every line (SYS02068).
  python3 - "$MNT" <<'PY'
import re, sys
m = sys.argv[1]
p = m + "/CONFIG.SYS"
out = []
for s in open(p, "rb").read().decode("latin-1").split("\r\n"):
    if re.match(r"(?i)\s*SET\s+C1\s*=", s):
        out.append("SET C1=GENGRADD,SBFILTER,VGAGRADD")
    elif re.match(r"(?i)\s*SET\s+VIDEO_DEVICES\s*=", s):
        out.append("SET VIDEO_DEVICES=VIO_VGA")
    elif re.match(r"(?i)\s*SET\s+VIO_(VGA|SVGA)\s*=", s):
        out.append("SET VIO_VGA=DEVICE(BVHVGA)")
    elif re.match(r"(?i)\s*DEVICE\s*=\s*C:\\OS2\\MDOS\\VSVGA\.SYS", s):
        out.append("DEVICE=C:\\OS2\\MDOS\\VVGA.SYS")
    else:
        out.append(s)
open(p, "wb").write("\r\n".join(out).encode("latin-1"))
print("  CONFIG.SYS -> GENGRADD chain (CRLF preserved)")
PY

  # MCP2 can retain a WPS OBJECTID after moving the object out of the desktop.
  # Install the complete CRLF REXX bootstrap, which recreates the gallery-owned
  # objects after WPS settles and starts WARPD.EXE.
  [ -f "$DESKTOP_OBJECTS_CMD" ] ||
    die "desktop object source missing: $DESKTOP_OBJECTS_CMD"
  local startup_tmp="$d/STARTUP.CMD"
  sed 's/$/\r/' "$DESKTOP_OBJECTS_CMD" >"$startup_tmp"
  rm -f "$MNT/STARTUP.CMD"
  cp "$startup_tmp" "$MNT/STARTUP.CMD"
  cmp -s "$startup_tmp" "$MNT/STARTUP.CMD" ||
    die "C:\\STARTUP.CMD readback mismatch"
  rm -f "$startup_tmp"
  echo "  STARTUP.CMD -> reproducible gallery desktop inventory"

  sync
  echo "prep done: $d/disk.qcow2"
}

# ---- run: production-shaped launcher (mirrors tiles/os2warp/qemu-streamhost.sh) --
cmd_run() {
  local d="$1" mode="${2:-cold}" loadvm=""
  guard_dir "$d"
  [ -f "$d/disk.qcow2" ] || die "no $d/disk.qcow2 — run 'prep' first"
  if [ -f "$d/qemu.pid" ]; then
    /usr/local/bin/clone-guard kill-pidfile "$d/qemu.pid" 2>/dev/null || true
  fi
  sleep 0.3
  rm -f "$d/qmp.sock" "$d/serial.sock"
  [ "$mode" = golden ] && loadvm="-loadvm golden"

  # shellcheck disable=SC2086 # $loadvm must word-split into '-loadvm golden' (or vanish)
  nohup qemu-system-x86_64 \
    -name "$(basename "$d")" \
    -accel tcg -m 256 -smp 1 \
    -machine pc-i440fx-11.0,acpi=off,usb=off -cpu pentium \
    -rtc base=localtime \
    -boot c \
    -vga std -global VGA.vgamem_mb=2 \
    -display none \
    -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
    -drive "file=$d/disk.qcow2,format=qcow2,if=ide,index=0,media=disk" \
    -netdev user,id=n0 -device pcnet,netdev=n0 \
    -chardev "socket,id=ser0,path=$d/serial.sock,server=on,wait=off" -serial chardev:ser0 \
    $loadvm \
    -qmp "unix:$d/qmp.sock,server=on,wait=off" \
    -pidfile "$d/qemu.pid" \
    >"$d/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$d/qmp.sock" ] && [ -f "$d/qemu.pid" ] && break
    sleep 0.5
  done
  echo "running pid=$(cat "$d/qemu.pid" 2>/dev/null) mode=$mode qmp=$d/qmp.sock ser=$d/serial.sock"
}

cmd_shot() {
  local d="$1" n="${2:-shot}"
  guard_dir "$d"
  rm -f "$d/$n.ppm" "$d/$n.png"
  python3 /root/cdrv.py "$d/qmp.sock" dump "$d/$n.ppm" >/dev/null 2>&1
  sleep 0.4
  pnmtopng "$d/$n.ppm" >"$d/$n.png"
  echo "$d/$n.png"
}

case "${1:-}" in
  prep) shift && cmd_prep "$@" ;;
  run) shift && cmd_run "$@" ;;
  shot) shift && cmd_shot "$@" ;;
  *) die "usage: $(basename "$0") {prep|run|shot} <clone-dir> [args]" ;;
esac
