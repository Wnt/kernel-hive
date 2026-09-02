#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/bootos.sh — from-scratch, reproducible build of the bootOS
# station media for the Kernel Hive (host-native streamhost, Tier 1).
#
# GOAL: on a FRESH Proxmox host, (re)fetch the pinned upstream bootOS release
# files, integrity-verify every one of them against the SHA-256 pins below,
# stage the immutable intake under
#     <STAGE_DIR>/            (default /data/assets-staging/bootos)
# and produce the canonical station media
#     <GUEST_DIR>/bootos-floppy.qcow2   (default /data/gallery-guests/BootOS)
# = the upstream 720K `osall.img` floppy converted raw -> qcow2, PRISTINE (no
# snapshot; the `golden` vmstate is baked by the station stream, never here),
# then framebuffer-verify that it boots to the `$` prompt and that `dir` lists
# the programs. `os.img` (the bare 512-byte boot sector) is kept next to it.
#
# WHAT BOOTOS IS: Óscar Toledo G.'s 2019 operating system in ONE 512-byte boot
# sector (BSD-2-Clause, https://github.com/nanochess/bootOS): a command shell,
# a filesystem on the floppy, a hex program loader (`enter`), `dir`/`del`/
# `format`/`ver`, and it runs any boot-sector program by name. `osall.img` is
# the upstream 720K floppy that bundles bootOS with 19 one-sector programs:
# fbird pillman invaders basic textmode counter data.bin bootslide atomchess
# tetranglix snake mine rogue bricks cubicdoom sokoban heart pi bootle. The
# third-party ones (bootSlide, tetranglix, snake, bootMine, sokoban) carry their
# own licences — which is why the image is staged locally and never committed.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED: raw.githubusercontent.com at a pinned
#                        COMMIT, every file SHA-256-pinned in this script.
#   (2) DISK CREATE .... `qemu-img convert -f raw -O qcow2` of the 720K floppy.
#   (3) INSTALL ........ N/A — the floppy IS the installed system.
#   (4) INPUT AUTOMATION only for the verify: `dir` + Enter over QMP.
#   (5) ERA SOFTWARE ... on the upstream floppy already (19 programs).
#   (6) FINAL IMAGE .... bootos-floppy.qcow2 (+ os.img, .sha256 sidecars).
#   (7) VERIFY ......... FULLY AUTOMATED — headless QEMU on a SCRATCH COPY of the
#                        qcow2 (the canonical output is never mounted), two QMP
#                        screendumps: the boot frame must end in a prompt line
#                        (one glyph at column 0 — the `$`), then after `dir` the
#                        frame must CHANGE, the lit 16-px text rows must have
#                        grown and number at least 21 (`$dir` + 19 names + `$`),
#                        and the last row must again be a prompt line.
#   => No manual steps. The whole build is hands-off (~1 minute).
#
# HARDWARE PROFILE (the verify mirrors the station's device set, minus display
# and audio): qemu-system-x86_64, -machine pc-i440fx-11.0, 64 MB, 1 vCPU,
# -vga std (BIOS 80x25 text mode -> a 720x400 framebuffer), the floppy as a
# qcow2 `if=floppy` drive, `-boot a`. KVM + -cpu host when /dev/kvm is usable,
# TCG (-cpu qemu64) otherwise. No pointer device: bootOS reads the BIOS
# keyboard (int 16h) and nothing else. pc-i440fx-11.0 is what
# streamhost/stations/bootos/qemu-streamhost.sh runs; do not drift it.
#
# IDEMPOTENT / RE-RUNNABLE: skips fetch/convert when a checksum-matching staged
# copy and a snapshot-free qcow2 that round-trips to the pinned floppy are
# already present (override with --force). Namespaced WORK dir with a unique
# QMP socket + pidfile; QEMU is stopped ONLY via QMP `quit` / its own pidfile —
# never by name — so it cannot disturb any other guest on the host.
#
# Usage:
#   build-guests/tiles/bootos.sh [--dir DIR] [--force] [--no-verify] [-h]
#     --dir DIR      output/guest dir      (default /data/gallery-guests/BootOS)
#     --force        re-fetch and re-convert even if valid outputs are present
#     --no-verify    skip the headless framebuffer boot + `dir` check
#     -h|--help      show this header
#   env: WORK       scratch dir  (default /data/vms/build-bootos)
#        STAGE_DIR  intake dir   (default /data/assets-staging/bootos)
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
GUEST_DIR="/data/gallery-guests/BootOS"
STAGE_DIR="${STAGE_DIR:-/data/assets-staging/bootos}"
WORK="${WORK:-/data/vms/build-bootos}"
OUT_NAME="bootos-floppy.qcow2"
FLOPPY_BYTES=368640                                        # 720K: 80 tracks x 2 heads x 9 sectors x 512
UPSTREAM_COMMIT="329b75e60d04e89616bc1844578098df43d4f432" # nanochess/bootOS master, 2026-08-01
SRC_BASE="https://raw.githubusercontent.com/nanochess/bootOS/${UPSTREAM_COMMIT}"
# Every upstream file we take, with its SHA-256 at the pinned commit. Order is
# the MANIFEST order. The two images are the payload; the rest is provenance
# (source, licence, README) staged beside them so the intake explains itself.
PIN_FILES=(
  os.img osall.img os.asm README.md LICENSE
  patch/mine.asm patch/mine.img patch/snake.asm patch/snake.img
  patch/sokoban.asm patch/sokoban.fdd
)
declare -A PIN_SHA=(
  ["os.img"]=35e1231cf29f8750566a97dfb628b2bbe2c24a2f7d7518d7a94103f9976d3df8
  ["osall.img"]=20927188a96cca1cc41bd43a24186cd6fb3e68a4f82fdaf7c2e59c9bfd874653
  ["os.asm"]=5d9cf205a76aae591aba2fed015d1bfbd10bab586441f32e9badac7c4bfec6d3
  ["README.md"]=38d40a724b615b78c634635a64f2e1915e55f829bfdbc496cf0135f375c2c5f0
  ["LICENSE"]=b752a941b6a80602d7121ebb89e6d20bec35d8b16b979e07a5b245e694632155
  ["patch/mine.asm"]=291a3b9d043ca0dc4bee869d40e7b1eacb24c4471135d0fd255c101690562b59
  ["patch/mine.img"]=8f63fcf15a7cdad58ed1cc8af74243c2787eac537bbc600b946967890eae708e
  ["patch/snake.asm"]=baf920713c44648fd6ac3482109efe17c57b99f4fd0438ac2681c05b0749d7a6
  ["patch/snake.img"]=5d46e3ee85930933053cbc0e856209fc77fc012575cad2758817d13ed8d122d5
  ["patch/sokoban.asm"]=7c48940ed83642b15ff637bbe98fe1c6cd1844b13d09285fa2c5515a5b1ae57c
  ["patch/sokoban.fdd"]=ae8feb45617dec904e49fa89276c29d961166e8a3b0bfc57fa259a606cb16e46
)
PROGRAM_COUNT=19 # what `dir` lists on the pinned osall.img
FORCE=0
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
      sed -n '2,66p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
OUT_PATH="${GUEST_DIR}/${OUT_NAME}"
QMPSOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"
SCRATCH="${WORK}/verify-floppy.qcow2"
PROOF_BOOT="${GUEST_DIR}/bootos-boot"
PROOF_DIR="${GUEST_DIR}/bootos-dir"

log() { printf '\033[1;36m[bootos]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[bootos] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

# Stop OUR qemu (pidfile only), then drop the scratch state. Never by name.
stop_qemu() {
  local p=""
  [ -f "$PIDFILE" ] && p="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
    python3 - "$LABQMP" "$QMPSOCK" <<'PY' 2>/dev/null || true
import importlib.util, sys
spec = importlib.util.spec_from_file_location("labqmp", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
try:
    with mod.QMPClient(sys.argv[2], timeout=5, connect_timeout=5) as c:
        c.execute("quit")
except Exception:
    pass
PY
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null || true
    sleep 1
    kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$QMPSOCK"
}
BUILD_OK=0
cleanup() {
  stop_qemu
  # A failed run keeps $WORK (frames, qemu.log) for the post-mortem.
  [ "$BUILD_OK" = 1 ] && rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# ---- dependency check -------------------------------------------------------
for c in curl python3 sha256sum qemu-img; do
  command -v "$c" >/dev/null 2>&1 || die "need $c"
done
[ -f "$LABQMP" ] || die "missing $LABQMP"
QEMU_BIN=""
command -v qemu-system-x86_64 >/dev/null 2>&1 && QEMU_BIN=qemu-system-x86_64

[ -e "$WORK" ] && [ "$FORCE" = 0 ] && [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null &&
  die "another bootos build is running (pidfile $PIDFILE); set WORK=<other dir> or wait"
mkdir -p "$WORK/dl/patch" "$GUEST_DIR"
install -d -m 0750 "$STAGE_DIR" "$STAGE_DIR/patch"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
staged_ok() { [ -s "$STAGE_DIR/$1" ] && [ "$(sha_of "$STAGE_DIR/$1")" = "${PIN_SHA[$1]}" ]; }

# =============================================================================
# (1) FETCH + PIN-VERIFY every upstream file, stage the intake (idempotent)
# =============================================================================
fetched=0
for f in "${PIN_FILES[@]}"; do
  if [ "$FORCE" = 0 ] && staged_ok "$f"; then
    continue
  fi
  log "fetching ${SRC_BASE}/${f}"
  curl -fsSL --retry 3 --retry-delay 3 -o "${WORK}/dl/${f}.tmp" "${SRC_BASE}/${f}" ||
    die "download failed: ${SRC_BASE}/${f}"
  got="$(sha_of "${WORK}/dl/${f}.tmp")"
  if [ "$got" != "${PIN_SHA[$f]}" ]; then
    log "  expected: ${PIN_SHA[$f]}"
    log "  got:      $got"
    die "sha256 mismatch for $f at commit $UPSTREAM_COMMIT (a pinned commit cannot change; refusing)"
  fi
  install -m 0640 "${WORK}/dl/${f}.tmp" "$STAGE_DIR/$f"
  fetched=$((fetched + 1))
done
for f in os.img osall.img; do
  sz="$(stat -c %s "$STAGE_DIR/$f")"
  case "$f" in
    os.img) [ "$sz" = 512 ] || die "$f is $sz bytes, not one 512-byte sector" ;;
    osall.img) [ "$sz" = "$FLOPPY_BYTES" ] || die "$f is $sz bytes, not a 720K floppy ($FLOPPY_BYTES)" ;;
  esac
done
# 0x55AA boot signature at the end of the boot sector, on both images.
for f in os.img osall.img; do
  [ "$(dd if="$STAGE_DIR/$f" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "55aa" ] ||
    die "$f has no 0x55AA boot signature"
done
{
  for f in "${PIN_FILES[@]}"; do printf '%s  %s\n' "${PIN_SHA[$f]}" "$f"; done
} >"$STAGE_DIR/MANIFEST.sha256"
(cd "$STAGE_DIR" && sha256sum -c --quiet MANIFEST.sha256) || die "staged intake fails its own MANIFEST"
if [ "$fetched" = 0 ]; then
  log "intake already staged and pin-verified -> $STAGE_DIR (${#PIN_FILES[@]} files); nothing fetched (use --force)."
else
  log "staged $fetched file(s) -> $STAGE_DIR; MANIFEST.sha256 rewritten (upstream commit $UPSTREAM_COMMIT)."
fi

# =============================================================================
# (2)+(6) COMPOSE the canonical media: osall.img -> qcow2, pristine, no snapshot
# =============================================================================
qcow_pristine() {
  # A valid output: a qcow2 whose raw content IS the pinned floppy and which
  # carries no internal snapshot (the golden is baked elsewhere, on a copy).
  [ -s "$1" ] || return 1
  qemu-img info --output=json "$1" 2>/dev/null | python3 -c '
import json,sys
i=json.load(sys.stdin)
ok = i.get("format")=="qcow2" and i.get("virtual-size")==int(sys.argv[1]) and not i.get("snapshots")
sys.exit(0 if ok else 1)' "$FLOPPY_BYTES" || return 1
  qemu-img convert -f qcow2 -O raw "$1" "$WORK/roundtrip.img" 2>/dev/null || return 1
  [ "$(sha_of "$WORK/roundtrip.img")" = "${PIN_SHA["osall.img"]}" ]
}

if [ "$FORCE" = 0 ] && qcow_pristine "$OUT_PATH" && [ "$(sha_of "$GUEST_DIR/os.img")" = "${PIN_SHA["os.img"]}" ]; then
  log "pristine, snapshot-free $OUT_NAME already present -> $OUT_PATH; skipping convert (use --force)."
else
  qemu-img convert -f raw -O qcow2 "$STAGE_DIR/osall.img" "$WORK/${OUT_NAME}.tmp" ||
    die "qemu-img convert failed"
  qcow_pristine "$WORK/${OUT_NAME}.tmp" || die "converted qcow2 does not round-trip to the pinned osall.img"
  install -m 0644 "$WORK/${OUT_NAME}.tmp" "$OUT_PATH"
  install -m 0644 "$STAGE_DIR/os.img" "$GUEST_DIR/os.img"
  {
    printf '%s  %s\n' "${PIN_SHA["osall.img"]}" "osall.img (raw content of $OUT_NAME; the qcow2 container itself is not byte-pinned)"
    printf '%s  %s\n' "${PIN_SHA["os.img"]}" "os.img"
    printf '# upstream nanochess/bootOS commit %s\n' "$UPSTREAM_COMMIT"
  } >"${OUT_PATH}.sha256"
  chmod 0644 "${OUT_PATH}.sha256"
  log "composed -> $OUT_PATH ($(stat -c %s "$OUT_PATH") bytes, qcow2 of the 720K osall.img, no snapshot) + os.img"
fi

# =============================================================================
# (7) FRAMEBUFFER VERIFY — boot a SCRATCH COPY headless, gate on two frames
# =============================================================================
qmp() { python3 "$LABQMP" "$QMPSOCK" "$@"; }

# Print "cells=<lit 16-px text rows> last_x0=<first lit x> last_x1=<last lit x>"
# for the last lit text row of a P6 PPM. bootOS runs in BIOS 80x25 text mode
# (9x16 cells on a 720x400 canvas), so a prompt line that holds only `$` (and
# maybe the cursor) lights x < 18 on its row and nothing further right.
frame_stats() {
  python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], "rb").read()
assert d[:2] == b"P6", "not a P6 ppm"
i, vals = 2, []
while len(vals) < 3:
    while d[i] in b" \t\r\n": i += 1
    j = i
    while d[j] not in b" \t\r\n": j += 1
    vals.append(int(d[i:j])); i = j
i += 1
w, h, _ = vals; px = d[i:]
row_lit = []
for y in range(h):
    row = px[y * w * 3:(y + 1) * w * 3]
    xs = [x for x in range(w) if row[x * 3] > 100 or row[x * 3 + 1] > 100 or row[x * 3 + 2] > 100]
    row_lit.append((min(xs), max(xs)) if xs else None)
cells = []
for c in range(h // 16):
    span = [r for r in row_lit[c * 16:(c + 1) * 16] if r]
    if span:
        cells.append((c, min(s[0] for s in span), max(s[1] for s in span)))
if not cells:
    print("cells=0 last_x0=-1 last_x1=-1")
else:
    c, x0, x1 = cells[-1]
    print(f"cells={len(cells)} last_x0={x0} last_x1={x1}")
PY
}

to_png() { # $1 basename without extension: keeps .ppm if no converter
  if command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$1.ppm" >"$1.png" 2>/dev/null || return 1
  elif command -v convert >/dev/null 2>&1; then
    convert "$1.ppm" "$1.png" 2>/dev/null || return 1
  else
    return 1
  fi
  chmod 0644 "$1.png" && rm -f "$1.ppm"
}

verify_boot() {
  [ -n "$QEMU_BIN" ] || {
    log "no qemu-system-x86_64 present — SKIPPING verify (fetch+checksum+convert succeeded)."
    return 0
  }
  local accel_args
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    accel_args="-enable-kvm -cpu host"
    log "verify: /dev/kvm present -> KVM (-cpu host)"
  else
    accel_args="-cpu qemu64"
    log "verify: no /dev/kvm -> TCG fallback (-cpu qemu64)"
  fi
  cp "$OUT_PATH" "$SCRATCH" # the canonical output is never mounted
  rm -f "$QMPSOCK" "$PIDFILE"
  log "verify: launching headless QEMU on a scratch copy ($SCRATCH) …"
  # shellcheck disable=SC2086 # $accel_args is a deliberately space-joined flag pair meant to word-split
  nohup "$QEMU_BIN" \
    -name build-bootos -machine pc-i440fx-11.0 $accel_args -m 64 -smp 1 \
    -rtc base=localtime \
    -drive file="$SCRATCH",if=floppy,format=qcow2 -boot a \
    -vga std -display none \
    -qmp "unix:${QMPSOCK},server=on,wait=off" \
    -pidfile "$PIDFILE" \
    >"$WORK/qemu.log" 2>&1 &
  local waited=0
  while { [ ! -S "$QMPSOCK" ] || [ ! -f "$PIDFILE" ]; } && [ $waited -lt 30 ]; do
    sleep 0.5
    waited=$((waited + 1))
  done
  [ -S "$QMPSOCK" ] || die "verify FAILED — QEMU never opened $QMPSOCK ($(tail -3 "$WORK/qemu.log" 2>/dev/null))"

  # Boot frame: poll until the last lit text row is a lone glyph at column 0
  # (the `$` prompt, cursor allowed in the next cell), max ~30 s.
  local stats cells x0 x1 tries=0 boot_cells=0
  while :; do
    sleep 2
    qmp shot "${WORK}/boot.ppm" >/dev/null
    stats="$(frame_stats "${WORK}/boot.ppm")"
    cells="${stats#cells=}" cells="${cells%% *}"
    x0="${stats#*last_x0=}" x0="${x0%% *}"
    x1="${stats#*last_x1=}"
    if [ "$cells" -ge 2 ] && [ "$x0" -le 8 ] && [ "$x1" -lt 18 ]; then
      boot_cells="$cells"
      break
    fi
    tries=$((tries + 1))
    [ $tries -lt 15 ] || die "verify FAILED — no \`\$\` prompt line after boot (last frame: $stats; kept ${WORK}/boot.ppm)"
  done
  log "verify: boot frame shows the prompt line ($boot_cells lit text rows, prompt glyph x=$x0..$x1)"
  cp "${WORK}/boot.ppm" "${PROOF_BOOT}.ppm"

  # Type `dir` + Enter; the frame must change and grow by the program listing.
  qmp type $'dir\n' >/dev/null
  sleep 3
  qmp shot "${WORK}/dir.ppm" >/dev/null
  cmp -s "${WORK}/boot.ppm" "${WORK}/dir.ppm" && die "verify FAILED — frame did not change after typing dir (keyboard dead?)"
  stats="$(frame_stats "${WORK}/dir.ppm")"
  cells="${stats#cells=}" cells="${cells%% *}"
  x0="${stats#*last_x0=}" x0="${x0%% *}"
  x1="${stats#*last_x1=}"
  # The listing block — the echoed `$dir`, the program names, the new `$` —
  # is PROGRAM_COUNT+2 consecutive lit rows, and it fits the 25-row screen, so
  # it is on screen in full even after the SeaBIOS banner scrolled off the top
  # (which is why the growth is measured as a floor, not as boot+19).
  [ "$cells" -gt "$boot_cells" ] && [ "$cells" -ge $((PROGRAM_COUNT + 2)) ] ||
    die "verify FAILED — \`dir\` left $cells lit text rows (boot frame had $boot_cells); the listing needs at least $((PROGRAM_COUNT + 2))"
  [ "$x0" -le 8 ] && [ "$x1" -lt 18 ] ||
    die "verify FAILED — no \`\$\` prompt line after dir (last row x=$x0..$x1)"
  cp "${WORK}/dir.ppm" "${PROOF_DIR}.ppm"
  log "verify: after \`dir\` the frame changed and grew $boot_cells -> $cells text rows, ending in a prompt line"

  stop_qemu
  to_png "$PROOF_BOOT" && to_png "$PROOF_DIR" &&
    log "verify: proof -> ${PROOF_BOOT}.png, ${PROOF_DIR}.png" ||
    log "verify: proof -> ${PROOF_BOOT}.ppm, ${PROOF_DIR}.ppm (no PPM->PNG converter)"
  log "verify: PASS — the qcow2 floppy boots bootOS to \`\$\` and \`dir\` lists the programs."
}

[ "$VERIFY" = 1 ] && verify_boot || log "verify skipped (--no-verify)."
BUILD_OK=1

# =============================================================================
# DONE — how this media is wired into the station (see docs/guests/bootos.md).
# =============================================================================
cat <<EOF

============================================================================
bootOS build complete.
  Station media        : ${OUT_PATH}   (qcow2 of the 720K osall.img, pristine)
  Boot sector only     : ${GUEST_DIR}/os.img
  Intake               : ${STAGE_DIR}/ (MANIFEST.sha256, upstream commit ${UPSTREAM_COMMIT})
  Integrity            : osall.img sha256 ${PIN_SHA["osall.img"]}
                         os.img    sha256 ${PIN_SHA["os.img"]}
  Proof frames         : ${PROOF_BOOT}.png, ${PROOF_DIR}.png (or .ppm)

Station wiring (streamhost/stations/bootos/qemu-streamhost.sh copies this file
to /data/vms/streamhost/stations/bootos/floppy.qcow2 on first launch; that copy
— the ONLY block device — later carries the savevm 'golden' vmstate, so loadvm
restores the floppy contents too):
  qemu-system-x86_64 -enable-kvm -m 64 -smp 1 \\
    -machine pc-i440fx-11.0,pcspk-audiodev=snd0 -cpu host \\
    -drive file=floppy.qcow2,if=floppy,format=qcow2 -boot a -vga std
  Keyboard-only (BIOS int 16h); no pointer device; PC speaker -> audiodev.

Pitfalls baked into this script:
  * The output must stay PRISTINE: never savevm into it. The golden lives in
    the station's own copy. A snapshot here fails qcow_pristine() next run.
  * Third-party programs on osall.img (bootSlide, tetranglix, snake, bootMine,
    sokoban) have their own licences — the floppy is staged, never committed.
  * The prompt/dir gate reads 16-px text rows of the 720x400 BIOS text frame;
    a different -vga or a graphics-mode program would fail it by design.
============================================================================
EOF
