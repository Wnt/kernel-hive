#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/kolibrios.sh — from-scratch, reproducible build of the KolibriOS
# station for the neko+QEMU Kernel Hive.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the KolibriOS
# guest END TO END from its real upstream source — no image backups, no
# pre-staged files. Produces the final bootable live ISO at
#     <GUEST_DIR>/kolibri.iso        (default /data/gallery-guests/KolibriOS)
# and framebuffer-verifies it reaches the graphical desktop. It then stages the
# station-local fixture helpers, bakes the internal `golden` savevm snapshot, and
# proves a live loadvm round-trip against the production device set.
#
# WHAT KOLIBRIOS IS: a tiny assembly-written GPLv2 OS that ships as a *live CD*.
# There is NO installer, NO answer file, NO disk, NO era-software injection step:
# the nightly ISO already bundles the full app suite (NetSurf browser, games,
# editors, etc.) and boots straight to the graphical desktop in ~1 second,
# fully unattended. So the "build" is really: download upstream -> unpack the
# ISO -> verify it boots to GUI. That is faithfully all the original dry-run box
# did (see /data/gallery-guests/KolibriOS/NOTES.md on host 192.0.2.10).
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED (real upstream URL, re-fetched here).
#   (2) DISK CREATE .... N/A — pure live CD, no HDD is created or needed.
#   (3) INSTALL ........ N/A — no installer. Boot IS the whole thing.
#   (4) INPUT AUTOMATION N/A — ZERO keypresses/clicks. It self-lands on the
#                        desktop; no autounattend / sendkey / vncdotool needed.
#   (5) ERA SOFTWARE ... N/A — bundled in the upstream ISO already.
#   (6) FINAL IMAGE .... kolibri.iso placed in <GUEST_DIR>.
#   (7) VERIFY ......... FULLY AUTOMATED — headless QEMU + framebuffer screendump.
#   => There are NO manual/interactive steps. The whole build is hands-off.
#
# IDEMPOTENT / RE-RUNNABLE: skips the download if a valid ISO already exists
# (override with --force). Uses a namespaced work dir and UNIQUE per-run unix
# sockets (VNC + QEMU monitor) + a pidfile. Kills ONLY via monitor `quit` /
# pidfile — NEVER pkill-by-name — so it cannot disturb other gallery guests,
# CTID 110, VM 900/920, or the macOS fan-out VMIDs.
#
# Usage:
#   OUT_DIR=/isolated/output WORK_DIR=/isolated/work \
#     build-guests/tiles/kolibrios.sh [--dir DIR] [--force] [--no-verify] [-h]
#     --dir DIR      output/guest dir      (default: OUT_DIR or /data/gallery-guests/KolibriOS)
#     --force        re-download even if a valid kolibri.iso is already present
#     --no-verify    skip the headless framebuffer boot check (just fetch/unpack)
#     -h|--help      show this header
#
#   OUT_DIR and WORK_DIR make trial runs fully independent of the live paths.
#   --dir takes precedence over OUT_DIR.
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="${OUT_DIR:-/data/gallery-guests/KolibriOS}"
ISO_NAME="kolibri.iso"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TILE_DIR="${TILE_DIR:-/data/vms/streamhost/tiles/kolibrios}"
# Upstream nightly live ISO. NOTE the path is /en_US/ — the /eng/ path 404s.
SRC_URL="${SRC_URL:-https://builds.kolibrios.org/en_US/latest-iso.7z}"
FORCE="${FORCE:-0}"
VERIFY=1

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
      sed -n '2,58p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ISO_PATH="${GUEST_DIR}/${ISO_NAME}"
# Namespaced, per-run scratch so parallel/other builds never collide.
if [ -n "${WORK_DIR:-}" ]; then
  WORK="$WORK_DIR"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/kolibrios-build.XXXXXX")"
fi
RUN_TAG="kolibrios-$$"
VNCSOCK="${WORK}/vnc.sock"
MONSOCK="${WORK}/mon.sock"
PIDFILE="${WORK}/qemu.pid"
PROOF_PPM="${GUEST_DIR}/kolibri-desktop.ppm"
PROOF_PNG="${GUEST_DIR}/kolibri-desktop.png"

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

log() { printf '\033[1;36m[kolibrios]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[kolibrios] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# ---- dependency check -------------------------------------------------------
need_dl=""
command -v curl >/dev/null 2>&1 || need_dl="$need_dl curl"
# 7z is needed to unpack the .7z. Accept any of the common binary names.
SEVENZ=""
for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
  SEVENZ="$c"
  break
}; done
if [ -z "$SEVENZ" ]; then
  log "no 7z binary found — attempting one-time install of p7zip-full…"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq p7zip-full >/dev/null 2>&1 || true
    for c in 7z 7za 7zr; do command -v "$c" >/dev/null 2>&1 && {
      SEVENZ="$c"
      break
    }; done
  fi
fi
[ -n "$SEVENZ" ] || die "need a 7z extractor (install p7zip-full)"
[ -z "$need_dl" ] || die "missing tools:$need_dl"

# QEMU binary for the verify step (production launch-qemu.sh uses x86_64 + -cpu qemu32).
QEMU_BIN=""
for c in qemu-system-x86_64 qemu-system-i386; do
  command -v "$c" >/dev/null 2>&1 && {
    QEMU_BIN="$c"
    break
  }
done

mkdir -p "$GUEST_DIR"

# =============================================================================
# (1) DOWNLOAD  +  unpack the live ISO
# =============================================================================
iso_valid() {
  [ -s "$1" ] &&
    [ "$(dd if="$1" bs=1 skip=32769 count=5 status=none 2>/dev/null)" = "CD001" ]
}

if [ "$FORCE" = 0 ] && iso_valid "$ISO_PATH"; then
  log "valid ISO already present -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1)); skipping download (use --force to refetch)."
else
  log "downloading upstream KolibriOS live ISO archive:"
  log "  $SRC_URL"
  curl -fSL --retry 3 --retry-delay 3 -o "${WORK}/latest-iso.7z" "$SRC_URL" ||
    die "download failed from $SRC_URL"
  log "extracting kolibri.iso from the .7z archive…"
  # -y assume-yes, e = extract flat into -o<dir>
  "$SEVENZ" e -y -o"$WORK" "${WORK}/latest-iso.7z" >/dev/null || die "7z extraction failed"
  # The archive contains kolibri.iso (and a kolibri.img floppy). Pick the ISO.
  src_iso="$(find "$WORK" -maxdepth 1 -type f -iname '*.iso' | head -n1)"
  [ -n "$src_iso" ] || die "no .iso found inside the archive"
  iso_valid "$src_iso" || die "extracted file is not a valid ISO-9660 image"
  install -m 0644 "$src_iso" "$ISO_PATH"
  log "installed -> $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
fi

# =============================================================================
# (2)-(5) DISK / INSTALL / INPUT-AUTOMATION / ERA-SOFTWARE
#   All N/A for KolibriOS — see the AUTOMATION HONESTY block in the header.
#   The ISO produced above IS the final, self-contained, bootable image.
# =============================================================================

# =============================================================================
# (7) FRAMEBUFFER VERIFY — headless QEMU boot + monitor screendump
#   Confirms the ISO reaches the graphical desktop. Uses unique unix sockets and
#   a pidfile; tears the VM down via the monitor `quit` (never pkill).
#   Sound is intentionally omitted here (a bare AC97 with no host audio backend
#   aborts QEMU — see NOTES.md); audio is added only in the production station.
# =============================================================================
mon_send() { # mon_send CMD...  — talk to the HMP monitor over the unix socket
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
  # Same profile as the validated station, minus audio, plus headless VNC+monitor.
  "$QEMU_BIN" \
    -machine pc -cpu qemu32 -m 256 \
    -cdrom "$ISO_PATH" -boot d \
    -vga std \
    -rtc base=localtime \
    -display none \
    -vnc "unix:${VNCSOCK}" \
    -monitor "unix:${MONSOCK},server,nowait" \
    -pidfile "$PIDFILE" &
  local qpid=$!

  # KolibriOS lands on the desktop in ~1s; wait generously for a cold TCG boot.
  local waited=0
  while [ ! -S "$MONSOCK" ] && [ $waited -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  sleep 15 # let the desktop paint

  log "verify: capturing framebuffer via monitor screendump…"
  mon_send "screendump ${PROOF_PPM}"
  sleep 2

  # Tear down cleanly: monitor quit first, then pidfile fallback. NEVER pkill.
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
  kill -0 "$qpid" 2>/dev/null && { kill -TERM "$qpid" 2>/dev/null || true; }
  wait "$qpid" 2>/dev/null || true

  [ -s "$PROOF_PPM" ] || die "verify FAILED — no framebuffer captured (did not reach GUI?)"

  # Assert the frame is a real desktop, not a black/blank screen: check the PPM
  # has meaningful colour variety and non-trivial brightness.
  python3 - "$PROOF_PPM" <<'PY' || die "verify FAILED — framebuffer looks blank (near-black / no colour variety)"
import sys
p=sys.argv[1]
with open(p,'rb') as f: data=f.read()
# Parse ascii PPM header (magic, w, h, maxval) then raw RGB bytes.
def toks(b):
    out=[]; i=0
    while len(out)<4:
        while i<len(b) and b[i] in b' \t\r\n': i+=1
        j=i
        while j<len(b) and b[j] not in b' \t\r\n': j+=1
        out.append(b[i:j]); i=j
    return out, i+1
hdr,off=toks(data)
magic=hdr[0]; w=int(hdr[1]); h=int(hdr[2])
px=data[off:]
# sample: count distinct colours + mean brightness over a stride.
seen=set(); tot=0; n=0
for k in range(0, max(0,len(px)-3), 3*97):
    r,g,b=px[k],px[k+1],px[k+2]
    seen.add((r>>4,g>>4,b>>4)); tot+=r+g+b; n+=1
mean=(tot/(3*n)) if n else 0
print(f"[kolibrios] verify: {magic.decode(errors='replace')} {w}x{h}, ~{len(seen)} colours sampled, mean brightness {mean:.1f}")
# A live desktop has many colours and is not near-black.
sys.exit(0 if (len(seen) >= 8 and mean > 8) else 1)
PY

  # Best-effort convert the proof PPM -> PNG for a nicer artifact, then drop PPM.
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$PROOF_PPM" >"$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  elif command -v convert >/dev/null 2>&1; then
    convert "$PROOF_PPM" "$PROOF_PNG" 2>/dev/null && rm -f "$PROOF_PPM" && log "verify: proof -> $PROOF_PNG"
  else
    log "verify: proof -> $PROOF_PPM (no PPM->PNG converter; PPM kept as-is)"
  fi
  log "verify: PASS — KolibriOS reached the graphical desktop."
}

# =============================================================================
# (8) GOLDEN FIXTURE — stage and run the station-specific deterministic bake.
#   The production station directory is emitted separately from this guest build,
#   so copy only the fixture helpers/assets here; never replace its launcher.
# =============================================================================
FIXTURE_SRC="$REPO_ROOT/streamhost/tiles/kolibrios"
for f in golden-bake.sh qemu-setup.sh kolmouse.py state.qcow2.base-empty; do
  [ -f "$FIXTURE_SRC/$f" ] || die "missing fixture asset: $FIXTURE_SRC/$f"
done
mkdir -p "$TILE_DIR"
install -m 0755 "$FIXTURE_SRC/golden-bake.sh" "$TILE_DIR/golden-bake.sh"
install -m 0755 "$FIXTURE_SRC/qemu-setup.sh" "$TILE_DIR/qemu-setup.sh"
install -m 0755 "$FIXTURE_SRC/kolmouse.py" "$TILE_DIR/kolmouse.py"
install -m 0644 "$FIXTURE_SRC/state.qcow2.base-empty" "$TILE_DIR/state.qcow2.base-empty"

log "golden: baking deterministic tile fixture with pc-i440fx-11.0…"
# shellcheck disable=SC2097,SC2098 # intentional: exports the parent's current TILE_DIR/ISO_PATH into golden-bake.sh's environment; the $TILE_DIR expansion on this line correctly uses the pre-existing parent value
TILE_DIR="$TILE_DIR" KOLIBRI_ISO="$ISO_PATH" bash "$TILE_DIR/golden-bake.sh"
qemu-img snapshot -l "$TILE_DIR/state.qcow2" | awk '{print $2}' | grep -qx golden || die "golden snapshot absent after fixture bake"
log "golden: PASS — state.qcow2 contains the verified 'golden' snapshot."
if [ "$TILE_DIR" = /data/vms/streamhost/tiles/kolibrios ] && command -v labctl >/dev/null 2>&1; then
  log "golden: refreshing labctl's generated snapshot state…"
  labctl gen >/dev/null
fi

[ "$VERIFY" = 1 ] && verify_boot || log "verify skipped (--no-verify)."

# =============================================================================
# DONE — distinguish the base-media smoke test from the current streamhost
# launcher contract. The manifest owns the production launcher wiring.
# =============================================================================
cat <<EOF

============================================================================
KolibriOS build complete.
  Final bootable image : ${ISO_PATH}
  Golden state disk    : ${TILE_DIR}/state.qcow2 (snapshot: golden)
  Proof screenshot     : ${PROOF_PNG} (or .ppm)

Base-media smoke-test command (validated on host, QEMU 11.0.0):
  qemu-system-x86_64 -machine pc -cpu qemu32 -m 256 \\
    -cdrom kolibri.iso -boot d -vga std \\
    -audiodev pa,id=snd -device AC97,audiodev=snd -rtc base=localtime

Production contract (streamhost/tiles-manifest.sh):
  The emitted launcher adds usb-tablet and a persistent virtio state.qcow2.
  That qcow2 holds savevm 'golden', and startup passes '-loadvm golden' when
  the snapshot exists. The bake and production launchers must use identical
  machine, CPU, memory, SMP, tablet, AC97, and virtio device models.

Pitfalls baked into this script:
  * download path is /en_US/  (the /eng/ path 404s)
  * a bare '-device AC97' with no host audio backend ABORTS qemu — always pass
    an explicit -audiodev (pa in the neko container; omitted in the verify step)
  * boot is so fast NO keypress/automation is required — it self-lands on the GUI
  * the vendored tile-specific bake helper creates state.qcow2's curated
    'golden' snapshot with the same pinned machine/device set as production
============================================================================
EOF
