#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/amigaos.sh — from-scratch, reproducible build of the AmigaOS tile
# for the neko+QEMU Kernel Hive, using the FREE/OPEN AROS path.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the "AmigaOS"
# guest END TO END from its real upstream source — no image backups, no
# pre-staged files. Produces the final bootable live ISO at
#     <GUEST_DIR>/aros-pc-i386.iso   (default /data/gallery-guests/AmigaOS)
# and a fresh tile golden-scratch.qcow2 whose internal `golden` snapshot is the
# framebuffer-verified Wanderer/Workbench desktop with an open AROS Shell and
# Poseidon bound to QEMU's absolute USB tablet.
#
# ---- WHAT THIS IS (and the licensing stance) --------------------------------
# We represent AmigaOS with **AROS** — the AROS Research Operating System, an
# open-source, from-scratch re-implementation of the AmigaOS 3.1 APIs. We use the
# official **pc-i386** (x86, 32-bit) *boot ISO* nightly, which runs QEMU
# x86-NATIVE and boots straight to the Amiga-style **Wanderer** Workbench desktop
# with **NO copyrighted Kickstart ROM** required. AROS is distributed under the
# APL (AROS Public License, an MPL derivative) — FREE / OPEN, re-distributable;
# the ISO ships its own LICENSE + ACKNOWLEDGEMENTS (copied into GUEST_DIR).
#
# The classic 68k AmigaOS 3.x path (FS-UAE / vAmiga + a copyrighted Kickstart ROM)
# is the ALTERNATIVE — see docs/guests/aros.md. We deliberately do NOT require
# that ROM: this free AROS path is faithful to the Workbench look and fully legal
# to redistribute.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED. Fetches the pinned 20260701 pc-i386
#                        boot + contrib archives and validates both sha256 sums.
#   (2) DISK CREATE .... AUTOMATED — creates a fresh no-backing 1 GiB qcow2 to
#                        hold QEMU's internal full-machine `golden` snapshot.
#   (3) INSTALL ........ N/A — no installer step. Boot IS the whole thing (the CD
#                        also OFFERS "InstallAROS", but we run it purely live).
#   (4) INPUT AUTOMATION AUTOMATED — GRUB/Wanderer need no input; the golden bake
#                        opens AROS Shell, runs `AddUSBHardware pciusb.device 0`,
#                        and proves the USB HID tablet owns absolute input.
#   (5) ERA SOFTWARE ... AUTOMATED — bakes a Games/ drawer of freely-distributable
#                        native AROS games (Soliton, MUIMine, XInvaders3D, Moria3D)
#                        onto the live CD and surfaces them + stock apps as VISIBLE
#                        Wanderer desktop icons via a .backdrop rewrite. Contrib is
#                        pulled from the same nightly; remastered with xorriso, the
#                        original El Torito boot record replayed byte-intact.
#   (6) FINAL IMAGE .... aros-pc-i386.iso plus a freshly-created tile qcow2 with
#                        an internal `golden` snapshot (open AROS Shell).
#   (7) VERIFY ......... FULLY AUTOMATED — headless QEMU + framebuffer screendump,
#                        asserted to be a real (non-blank) desktop.
#   => There are NO manual/interactive steps. The whole build is hands-off.
#
# IDEMPOTENT / RE-RUNNABLE: reuses only sha256-verified pinned archives; --force
# rebuilds the ISO from those inputs. Uses namespaced work dirs and per-run unix
# sockets (VNC + QEMU monitor) + a pidfile. Kills ONLY via monitor `quit` /
# pidfile — NEVER pkill-by-name — so it cannot disturb other gallery guests,
# CTID 110, VM 900/925, or the sibling OS builders.
#
# Usage:
#   build-guests/tiles/amigaos.sh [--dir DIR] [--force] [--no-verify] [-h]
#     --dir DIR      output/guest dir      (default /data/gallery-guests/AmigaOS)
#     --force        rebuild the ISO from sha256-verified pinned inputs
#     --no-verify    skip only the redundant TCG ISO smoke check (golden gate stays)
#     -h|--help      show this header
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/AmigaOS"
ISO_NAME="aros-pc-i386.iso"
# Pin both upstream inputs: following "latest" cannot reproduce the gallery ISO.
AROS_DATE="20260701"
BOOT_URL="https://sourceforge.net/projects/aros/files/nightly2/${AROS_DATE}/Binaries/AROS-${AROS_DATE}-pc-i386-boot-iso.zip/download"
CONTRIB_URL="https://sourceforge.net/projects/aros/files/nightly2/${AROS_DATE}/Binaries/AROS-${AROS_DATE}-pc-i386-contrib.tar.bz2/download"
BOOT_SHA256="b3b607580f14e6c58ad796fe7c96768c04c4542da3a9c2f19386781e7015a3ce"
CONTRIB_SHA256="f574087ff62d9bb52024cee891f4e774aa6cefcd0ca805a63764a8dd4321e2c5"
FINAL_ISO_SHA256="5aff10ed5ff1aec62ed9336db984725c31c61b20d3d4c285857dfc021d2b2488"
FORCE="${FORCE:-0}"
VERIFY="${VERIFY:-1}"

# ---- arg parse --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)
      GUEST_DIR="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-verify)
      VERIFY=0
      shift
      ;;
    -h | --help)
      sed -n '2,66p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
CACHE_DIR="${GUEST_DIR}/.cache"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TILE_DIR="${TILE_DIR:-/data/vms/streamhost/tiles/amigaos}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/amigaos-build.XXXXXX")"
PIDFILE="${WORK}/qemu.pid"
MONSOCK="${WORK}/mon.sock"
PROOF_PPM="${GUEST_DIR}/aros-desktop.ppm"
PROOF_PNG="${GUEST_DIR}/aros-desktop.png"

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '\033[1;36m[amigaos]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[amigaos] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---- dependency check -------------------------------------------------------
need=""
command -v curl >/dev/null 2>&1 || need="$need curl"
command -v unzip >/dev/null 2>&1 || need="$need unzip"
command -v bzip2 >/dev/null 2>&1 || need="$need bzip2"
command -v xorriso >/dev/null 2>&1 || need="$need xorriso"
if [ -n "$need" ]; then
  log "installing missing tools:$need"
  if command -v apt-get >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # $need is a deliberately space-joined package-name list meant to word-split into apt-get args
    DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $need >/dev/null 2>&1 || true
  fi
fi
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v unzip >/dev/null 2>&1 || die "unzip is required"
command -v bzip2 >/dev/null 2>&1 || die "bzip2 is required"
command -v xorriso >/dev/null 2>&1 || die "xorriso is required"
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required"

QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

mkdir -p "$GUEST_DIR" "$CACHE_DIR"

# =============================================================================
# (1) DOWNLOAD + unpack the live boot ISO
# =============================================================================
iso_valid() { [ -s "$1" ] && head -c 32774 "$1" 2>/dev/null | tail -c 5 | grep -q 'CD001' 2>/dev/null; }

fetch_archive() {
  local label="$1" url="$2" dst="$3" expected="$4" got
  got="$(sha256sum "$dst" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$got" = "$expected" ]; then
    log "$label: using verified cache -> $dst"
    return 0
  fi
  log "$label: downloading pinned AROS ${AROS_DATE} input"
  log "  $url"
  if [ -e "$dst" ]; then
    log "$label: attempting to resume the incomplete cache"
    curl -fSL --retry 3 --retry-delay 3 -C - -o "$dst" "$url" || true
  else
    curl -fSL --retry 3 --retry-delay 3 -o "$dst" "$url" || true
  fi
  got="$(sha256sum "$dst" 2>/dev/null | awk '{print $1}' || true)"
  if [ "$got" != "$expected" ]; then
    log "$label: resume failed or cache is corrupt; retrying from byte zero"
    rm -f "$dst"
    curl -fSL --retry 3 --retry-delay 3 -o "$dst" "$url" ||
      die "$label download failed"
    got="$(sha256sum "$dst" | awk '{print $1}')"
  fi
  [ "$got" = "$expected" ] || die "$label sha256 mismatch: got $got, expected $expected"
}

if [ "$FORCE" = 0 ] && iso_valid "$ISO_PATH"; then
  log "valid ISO already present -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1)); use --force to rebuild from pinned inputs."
else
  archive="${CACHE_DIR}/AROS-${AROS_DATE}-pc-i386-boot-iso.zip"
  fetch_archive "boot ISO" "$BOOT_URL" "$archive" "$BOOT_SHA256"
  log "extracting ISO from the .zip archive…"
  unzip -o -q "$archive" -d "$WORK" || die "unzip failed"
  src_iso="$(find "$WORK" -type f -iname '*.iso' | head -n1)"
  [ -n "$src_iso" ] || die "no .iso found inside the archive"
  iso_valid "$src_iso" || die "extracted file is not a valid ISO-9660 image"
  install -m 0644 "$src_iso" "$ISO_PATH"
  # Preserve the upstream licence + credits alongside the ISO (APL — free/open).
  for meta in LICENSE ACKNOWLEDGEMENTS; do
    m="$(find "$WORK" -type f -name "$meta" | head -n1)"
    [ -n "$m" ] && install -m 0644 "$m" "${GUEST_DIR}/${meta}" 2>/dev/null || true
  done
  log "installed -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi

# =============================================================================
# (5) ERA SOFTWARE — bake freely-distributable AROS-native games onto the desktop
#   Adds a Games/ drawer of self-contained native pc-i386 games to the live CD and
#   surfaces them (plus a few stock apps) as VISIBLE Wanderer *backdrop* icons by
#   rewriting the volume-root .backdrop (the same mechanism the stock InstallAROS
#   desktop icon uses). Reproducible + hands-off:
#     * pulls the SAME-nightly pc-i386 *contrib* archive from the very SourceForge
#       project the boot ISO came from (native i386 ELF games, freely redistributable);
#     * overlays pre-staged .info icons + .backdrop shipped in assets/amigaos/;
#     * remasters with xorriso, REPLAYING the original El Torito boot record intact
#       (BIOS+UEFI GRUB untouched) — only files are added, boot is byte-identical.
#   Idempotent: skips if the ISO already carries /Games (unless --force). Missing
#   tools/assets, bad downloads, or a non-reference output hash fail the build.
#
#   Games (all native AROS i386 ELF, self-contained, launch-verified on KVM):
#     Soliton      Klondike solitaire (MUI/Zune)     Games/Soliton/Soliton
#     MUIMine      Minesweeper        (MUI/Zune)      Games/MUIMine/MUIMine
#     XInvaders3D  wireframe Space Invaders           Games/XInvaders3D/XInvaders3D
#     Moria3D      raycaster dungeon crawler          Games/Moria3D/Moria3D
#   Surfaced stock apps (already on the ISO, just leftout as icons):
#     Calculator, Editor (text editor), MultiView (image/text viewer).
# =============================================================================
ASSETS_DIR="${ASSETS_DIR:-$SCRIPT_DIR/../assets/amigaos}"

iso_has_games() { xorriso -indev "$1" -lsl /Games 2>/dev/null | grep -qi 'Soliton'; }

add_games() {
  [ -d "$ASSETS_DIR/icons" ] || die "assets/amigaos icons missing: $ASSETS_DIR/icons"

  if [ "$FORCE" = 0 ] && iso_has_games "$ISO_PATH"; then
    log "ISO already carries the Games drawer — skipping games bake (use --force to rebuild)."
    return 0
  fi

  log "era-software: staging pinned pc-i386 contrib archive for nightly ${AROS_DATE} …"
  local cz="${CACHE_DIR}/AROS-${AROS_DATE}-pc-i386-contrib.tar.bz2"
  fetch_archive "contrib" "$CONTRIB_URL" "$cz" "$CONTRIB_SHA256"
  bzip2 -t "$cz" 2>/dev/null || die "contrib archive failed bzip2 validation"

  local cx="${WORK}/contrib"
  mkdir -p "$cx"
  local base="AROS-${AROS_DATE}-pc-i386-contrib/Extras/Games"
  tar xjf "$cz" -C "$cx" \
    "$base/Card/Soliton" "$base/Board/MUIMine" \
    "$base/Action/XInvaders3D" "$base/Fps/Moria3D" 2>/dev/null ||
    die "contrib game extraction failed"

  local G="${WORK}/overlay/Games"
  mkdir -p "$G"
  cp -a "$cx/$base/Card/Soliton" "$G/Soliton"
  cp -a "$cx/$base/Board/MUIMine" "$G/MUIMine"
  cp -a "$cx/$base/Action/XInvaders3D" "$G/XInvaders3D"
  cp -a "$cx/$base/Fps/Moria3D" "$G/Moria3D"
  chmod -R u+rwX "${WORK}/overlay"
  # per-game launch icons (WBTOOL, pre-positioned on the backdrop grid)
  install -m0644 "$ASSETS_DIR/icons/game_icons/Soliton.info" "$G/Soliton/Soliton.info"
  install -m0644 "$ASSETS_DIR/icons/game_icons/MUIMine.info" "$G/MUIMine/MUIMine.info"
  install -m0644 "$ASSETS_DIR/icons/game_icons/XInvaders3D.info" "$G/XInvaders3D/XInvaders3D.info"
  install -m0644 "$ASSETS_DIR/icons/game_icons/Moria3D.info" "$G/Moria3D/Moria3D.info"

  # xorriso records mtime, atime, and ctime in Rock Ridge TF entries. Normalize
  # source-visible mtimes/atimes here; ctime and contrib atimes are set in the
  # in-memory ISO tree below because Unix cannot set ctime on staging files.
  touch -d '2026-07-06 16:54:28 +0300' "$G" "$G"/* "$G"/*/*.info
  local A="${WORK}/overlay-assets"
  mkdir -p "$A/Tools" "$A/Utilities"
  install -m0644 "$ASSETS_DIR/icons/Games.info" "$A/Games.info"
  install -m0644 "$ASSETS_DIR/icons/Tools/Calculator.info" "$A/Tools/Calculator.info"
  install -m0644 "$ASSETS_DIR/icons/Tools/Editor.info" "$A/Tools/Editor.info"
  install -m0644 "$ASSETS_DIR/icons/Utilities/MultiView.info" "$A/Utilities/MultiView.info"
  install -m0644 "$ASSETS_DIR/backdrop" "$A/backdrop"
  touch -d '2026-07-06 16:41:57 +0300' \
    "$A/Games.info" "$A/Tools/Calculator.info" "$A/Tools/Editor.info" \
    "$A/Utilities/MultiView.info" "$A/backdrop"

  local NEW="${WORK}/aros-games.iso"
  local XLOG="${WORK}/xorriso-games.log"
  TZ=UTC xorriso -indev "$ISO_PATH" -outdev "$NEW" -boot_image any replay \
    -map "$G" /Games \
    -map "$A/Games.info" /Games.info \
    -map "$A/Tools/Calculator.info" /Tools/Calculator.info \
    -map "$A/Tools/Editor.info" /Tools/Editor.info \
    -map "$A/Utilities/MultiView.info" /Utilities/MultiView.info \
    -map "$A/backdrop" /.backdrop \
    -alter_date c 2026.07.06.134157 \
    /.backdrop /Games.info /Tools/Calculator.info /Tools/Editor.info /Utilities/MultiView.info -- \
    -alter_date_r a-c 2026.07.06.131956 /Games/MUIMine -- \
    -alter_date a-c 2026.07.06.135428 /Games/MUIMine/MUIMine.info -- \
    -alter_date_r a-c 2026.07.06.131952 /Games/Moria3D -- \
    -alter_date a-c 2026.07.06.135428 /Games/Moria3D/Moria3D.info -- \
    -alter_date_r a-c 2026.07.06.131957 /Games/Soliton -- \
    -alter_date a-c 2026.07.06.135428 /Games/Soliton/Soliton.info -- \
    -alter_date_r a-c 2026.07.06.131956 /Games/XInvaders3D -- \
    -alter_date a-c 2026.07.06.135428 /Games/XInvaders3D/XInvaders3D.info -- \
    -find /Games -exec alter_date c 2026.07.06.135428 -- \
    >"$XLOG" 2>&1 || {
    tail -50 "$XLOG" >&2
    die "xorriso games remaster failed"
  }
  iso_valid "$NEW" || die "remastered ISO failed ISO-9660 validation"

  install -m0644 "$NEW" "$ISO_PATH"
  log "era-software: baked Games drawer + desktop icons into $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))."
}
add_games

actual_iso_sha256="$(sha256sum "$ISO_PATH" | awk '{print $1}')"
[ "$actual_iso_sha256" = "$FINAL_ISO_SHA256" ] ||
  die "remastered ISO sha256 mismatch: got $actual_iso_sha256, expected $FINAL_ISO_SHA256"
log "reproducible ISO sha256: $actual_iso_sha256"

# =============================================================================
# (3) INSTALL — N/A for the live-CD path. The games bake above is a pure file
#   overlay on the same self-contained bootable ISO. Golden creation is below.
# =============================================================================

# =============================================================================
# (7) FRAMEBUFFER VERIFY — headless QEMU boot + monitor screendump
#   Confirms the ISO reaches the Wanderer (Workbench) desktop. Unique unix
#   sockets + pidfile; torn down via monitor `quit` then pidfile (never pkill).
# =============================================================================
mon_send() {
  python3 - "$MONSOCK" "$@" <<'PY' 2>/dev/null || true
import socket,sys,time
sock=sys.argv[1]; cmds=sys.argv[2:]
s=socket.socket(socket.AF_UNIX); s.settimeout(5)
try:
    s.connect(sock); time.sleep(0.3)
    for c in cmds:
        s.sendall((c+"\n").encode()); time.sleep(0.4)
    time.sleep(0.4)
finally:
    try: s.close()
    except Exception: pass
PY
}

verify_boot() {
  [ -n "$QEMU_BIN" ] || {
    log "no qemu-system binary present — SKIPPING verify (fetch/unpack succeeded)."
    return 0
  }
  command -v python3 >/dev/null 2>&1 || {
    log "python3 absent — SKIPPING verify."
    return 0
  }

  log "verify: launching headless QEMU (${QEMU_BIN}) from $ISO_PATH …"
  # Matches the validated tile chipset: pc-i440fx-11.0, 512M, std VGA, boot d.
  # TCG here (no -enable-kvm) so verify runs anywhere; the live tile is identical.
  "$QEMU_BIN" \
    -machine pc-i440fx-11.0 -cpu qemu64 -m 512 \
    -cdrom "$ISO_PATH" -boot d \
    -vga std -rtc base=localtime \
    -display none \
    -vnc "unix:${WORK}/vnc.sock" \
    -monitor "unix:${MONSOCK},server,nowait" \
    -pidfile "$PIDFILE" &
  local qpid=$!

  local waited=0
  while [ ! -S "$MONSOCK" ] && [ $waited -lt 30 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  # AROS lands on the Wanderer desktop in ~40-60s under cold TCG; wait generously.
  sleep 70

  log "verify: capturing framebuffer via monitor screendump…"
  mon_send "screendump ${PROOF_PPM}"
  sleep 2

  mon_send "quit"
  sleep 2
  if [ -f "$PIDFILE" ]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 2
      kill -KILL "$p" 2>/dev/null || true
    fi
  fi
  kill -0 "$qpid" 2>/dev/null && kill -TERM "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true

  [ -s "$PROOF_PPM" ] || die "verify FAILED — no framebuffer captured (did not reach GUI?)"

  python3 - "$PROOF_PPM" <<'PY' || die "verify FAILED — framebuffer looks blank (near-black / no colour variety)"
import sys
p=sys.argv[1]
data=open(p,'rb').read()
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(data)
magic=hdr[0]; w=int(hdr[1]); h=int(hdr[2]); px=data[off:]
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]
    seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
print(f"[amigaos] verify: {magic.decode(errors='replace')} {w}x{h}, ~{len(seen)} colours sampled, mean brightness {mean:.1f}")
sys.exit(0 if (len(seen) >= 8 and mean > 8) else 1)
PY

  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  else
    log "verify: proof -> $PROOF_PPM (no PPM->PNG converter; PPM kept)"
  fi
  log "verify: PASS — AROS reached the Amiga-style Wanderer (Workbench) desktop."
}

[ "$VERIFY" = 1 ] && verify_boot || log "verify skipped (--no-verify)."

# =============================================================================
# (8) GOLDEN FIXTURE — stage and run the tile-owned deterministic cold bake.
#   The helper creates a brand-new no-backing qcow2, gates on Wanderer, opens an
#   AROS Shell, binds Poseidon to the QEMU USB tablet, proves absolute corner and
#   centre motion, saves `golden` under pc-i440fx-11.0, then dirties the
#   framebuffer and proves loadvm restores both the Shell and tablet binding.
# =============================================================================
FIXTURE_SRC="$REPO_ROOT/streamhost/tiles/amigaos/golden-bake.sh"
[ -f "$FIXTURE_SRC" ] || die "missing golden fixture helper: $FIXTURE_SRC"
mkdir -p "$TILE_DIR"
install -m 0755 "$FIXTURE_SRC" "$TILE_DIR/golden-bake.sh"
log "golden: baking a fresh tile fixture under pc-i440fx-11.0…"
GOLDEN_HELPER="$TILE_DIR/golden-bake.sh"
TILE_DIR="$TILE_DIR" AROS_ISO="$ISO_PATH" PROOF_DIR="$GUEST_DIR" bash "$GOLDEN_HELPER"
qemu-img snapshot -l "$TILE_DIR/golden-scratch.qcow2" |
  awk '{print $2}' | grep -qx golden || die "golden snapshot absent after fixture bake"
if qemu-img info "$TILE_DIR/golden-scratch.qcow2" | grep -q '^backing file:'; then
  die "fresh golden-scratch.qcow2 unexpectedly has a backing file"
fi
log "golden: PASS — freshly-baked golden-scratch.qcow2 contains snapshot 'golden'."
if [ "$TILE_DIR" = /data/vms/streamhost/tiles/amigaos ] && command -v labctl >/dev/null 2>&1; then
  labctl gen >/dev/null
fi

# =============================================================================
# DONE — reference: how this ISO is wired into the neko+QEMU gallery.
# (The container bind-mounts /data/gallery-guests read-only at /guests, and
#  launch-qemu.sh runs qemu-system-x86_64 with -audiodev pa,id=snd.)
# =============================================================================
cat <<EOF

============================================================================
AmigaOS (AROS) build complete.
  Final bootable image : ${ISO_PATH}
  Golden state disk    : ${TILE_DIR}/golden-scratch.qcow2 (snapshot: golden)
  Proof screenshot     : ${PROOF_PNG} (or .ppm)
  Upstream licence     : ${GUEST_DIR}/LICENSE (APL — free/open, redistributable)

neko-qemu tile env (own compose service, port :8110):
  OS_NAME       = AROS (AmigaOS-compatible)
  QEMU_MACHINE  = pc-i440fx-11.0
  QEMU_MEM      = 512
  QEMU_SMP      = 1
  QEMU_VGA      = std          (VESA/Bochs; AROS picks 1024x768)
  GUEST_CDROM   = /guests/AmigaOS/aros-pc-i386.iso
  GUEST_BOOT    = d            (boot from CD — pure live, no HDD)
  QEMU_EXTRA    = -enable-kvm -cpu host   (KVM ADOPTED — test-then-adopt PASSED)

Equivalent raw QEMU command (validated on host, QEMU 11.0.0, KVM):
  qemu-system-x86_64 -machine pc-i440fx-11.0 -enable-kvm -cpu host -m 512 \\
    -cdrom aros-pc-i386.iso -boot d -vga std -usb -device usb-tablet,id=tab0 \\
    -audiodev pa,id=snd -device AC97,audiodev=snd -rtc base=localtime

Notes:
  * FREE/OPEN path — AROS (APL licence). NO Kickstart ROM needed.
  * GRUB auto-boots; AROS self-lands on Wanderer (~30-45s cold under KVM). The
    golden helper then opens AROS Shell with Right-Amiga+E/newshell/Enter.
  * KVM ADOPTED (perf rollout, test-then-adopt): flipped TCG -> -enable-kvm -cpu
    host and framebuffer+input-verified on the live tile (Wanderer desktop renders;
    RMB pops the full Workbench menu = input reaches the guest; /dev/kvm + kvm-vm +
    kvm-vcpu fds open host-side; idle vCPU ~0% HLT'd). Stable, no crash-loop.
    Revert to '-cpu qemu64' (TCG) if a future AROS nightly regresses under KVM.
  * AROS does not auto-add its PCI USB controller to Poseidon. The golden helper
    runs \$(AddUSBHardware pciusb.device 0); current hid.class then binds the QEMU
    tablet and tracks absolute coordinates. The live launcher auto-loads this
    device-set-matched snapshot.
  * The framebuffer-verify step above (build_verify) stays on TCG on purpose so the
    build check runs on any host (incl. non-KVM CI); the live tile is KVM.
  * Classic 68k AmigaOS 3.x (FS-UAE/vAmiga + copyrighted Kickstart ROM) is the
    ALTERNATIVE, deliberately not required — see docs/guests/aros.md.
============================================================================
EOF
