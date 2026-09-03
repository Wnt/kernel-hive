#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/openbsd.sh — from-scratch, unattended build of the
# OpenBSD 7.9 amd64 station media for the Kernel Hive (host-native
# streamhost, Tier 1). Sibling device set: alpine.
#
# GUEST: OpenBSD 7.9 amd64 (released 2026-05; kernel GENERIC.MP #449, built
#        Wed May 6 2026), ISC/BSD-style licence, installed via the real
#        autoinstall(8) flow (not a hand-rolled disk image) so the golden
#        scene is a genuinely-installed system: fvwm (ships in base
#        Xenocara — no extra packages) + xterm/xclock/xeyes/xcalc as the
#        easily-discoverable desktop apps.
#
# WHAT THIS SCRIPT DOES:
#   1. fetch the 13 release files from MIRROR into STAGE_DIR, skipping any
#      file that already verifies against its pin (media_cache-style skip,
#      done inline since these files are OpenBSD-specific, not shared).
#   2. verify every file against the LITERAL pinned SHA-256s below — pins
#      were read directly off the staged copies on labhost
#      (`sha256sum` in STAGE_DIR, 2026-09-02); this script does not
#      independently re-derive them, it enforces them.
#   3. compose site79.tgz from the checked-in kit at
#      tiles/openbsd-site/ (etc/, root/ — autologin, .xinitrc, .fvwmrc,
#      the usb-tablet InputClass fix) with
#      `tar --owner=0 --group=0 --numeric-owner`, and stage
#      tiles/openbsd-install.conf as install.conf next to it.
#   4. build a www/ tree at WWW_DIR: pub/OpenBSD/7.9/amd64/ populated with
#      symlinks to every staged set + site79.tgz + install.conf, an
#      index.txt from `ls -lL`, `SHA256`/`SHA256.sig` copied through
#      unmodified (autoinstall is told to continue past their absence
#      for site79.tgz — see install.conf — since we do not resign the
#      release manifest); serves it on 127.0.0.1:8079, claimed via
#      `kh-claim take port 8079` under $KH_SESSION and released on exit.
#   5. create a 4 GiB qcow2, boot cd79.iso on the ledger's exact device
#      set + `-cdrom cd79.iso -boot d -display dbus,p2p=on` and a -qmp
#      socket; wait for the bsd.rd installer prompt with fb-wait.py, type
#      `a` (autoinstall) with qmp-type.py at the default --gap (0.05
#      drops characters on the wscons console — do not lower it), wait,
#      type the install.conf URL, then wait (--settle 25 --timeout 900)
#      for the installer to halt: QEMU keeps running at the halt screen,
#      so completion is detected by framebuffer settle time, not process
#      exit, and the process is then killed by its own pidfile.
#   6. output GUEST_DIR/openbsd.qcow2 (pristine — no snapshot; the
#      `golden` vmstate is baked by the station stream, never here).
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED: mirror fetch, 13 files, every one
#                        SHA-256-pinned below (pins are the exact values
#                        measured on labhost 2026-09-02 — see the ledger,
#                        docs/lab/OPENBSD-WAVE.md).
#   (2) DISK CREATE .... `qemu-img create -f qcow2` blank 4 GiB.
#   (3) INSTALL ........ FULLY AUTOMATED — real autoinstall(8) over loopback
#                        HTTP; two QMP keystrokes select autoinstall and
#                        point it at install.conf, everything else (disk
#                        layout, sets, site79.tgz, halt) is driven by the
#                        response file.
#   (4) INPUT AUTOMATION only the two QMP keystrokes above; site79.tgz ships
#                        every config file so nothing is ever typed with
#                        embedded quotes (qmp-type.py mangles `"` to `\`).
#   (5) ERA SOFTWARE ... xterm/xclock/xeyes/xcalc + fvwm, all from the base
#                        sets (comp/game excluded, x sets included).
#   (6) FINAL IMAGE .... openbsd.qcow2 (pristine, no snapshot).
#   (7) VERIFY ......... NOT wired into this script (--no-verify is the only
#                        mode); the golden bake + loadvm proof is the
#                        `golden` stream's job, not the builder's. This
#                        builder's own proof is the halt-screen framebuffer
#                        settle in step 5.
#   => Manual steps: none. Hands-off once STAGE_DIR is populated (or the
#      mirror is reachable); ~4-5 minutes end to end per the ledger's
#      measured timings (installer prompt ~16s, autoinstall ~2.5min, first
#      boot to login ~50s).
#
# HARDWARE PROFILE (ledger, docs/lab/OPENBSD-WAVE.md — do not drift):
#   qemu-system-x86_64, pc-i440fx-11.0, KVM, -cpu host, 1024 MB, 2 vCPU,
#   -vga none -device VGA,edid=on,xres=1024,yres=768, one virtio qcow2
#   (4 GiB), virtio-net-pci on SLIRP, -usb -device usb-tablet, AC97.
#   Install-only additions: -cdrom cd79.iso -boot d -display dbus,p2p=on
#   + a -qmp unix socket. Production boot (station stream) drops the
#   cdrom and boots from the virtio disk instead (-boot c).
#
# Usage:
#   build-guests/tiles/openbsd.sh [--dir DIR] [--force] [-h]
#     --dir DIR   output/guest dir  (default /data/gallery-guests/OPENBSD)
#     --force     re-fetch/re-verify even if a valid stage copy is present
#     -h|--help   show this header
#   env: WORK        scratch dir   (default /data/vms/build-openbsd)
#        STAGE_DIR   intake dir    (default /data/assets-staging/openbsd79)
#        WWW_DIR     loopback www  (default $WORK/www)
#        MIRROR      release mirror (default the fu-berlin mirror below;
#                     cdn.openbsd.org measured at 0.8 MB/s vs 59 MB/s here)
#        KH_SESSION  required to claim port 8079 via kh-claim
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

GUEST_DIR="/data/gallery-guests/OPENBSD"
STAGE_DIR="${STAGE_DIR:-/data/assets-staging/openbsd79}"
WORK="${WORK:-/data/vms/build-openbsd}"
WWW_DIR="${WWW_DIR:-$WORK/www}"
OUT_NAME="openbsd.qcow2"
DISK_BYTES=4294967296 # 4 GiB
MIRROR="${MIRROR:-https://ftp.spline.inf.fu-berlin.de/pub/OpenBSD/7.9/amd64}"
HTTP_PORT=8079
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
HTTPD_PIDFILE="$WORK/httpd.pid"

# Files pulled from MIRROR, with the SHA-256 measured on the staged copies
# on labhost 2026-09-02 (see docs/lab/OPENBSD-WAVE.md ledger). LITERAL pins
# — never invented, never re-derived here.
FETCH_FILES=(
  cd79.iso
  bsd
  bsd.mp
  bsd.rd
  base79.tgz
  man79.tgz
  xbase79.tgz
  xfont79.tgz
  xserv79.tgz
  xshare79.tgz
  SHA256
  SHA256.sig
  INSTALL.amd64
)
declare -A PIN_SHA256=(
  ["cd79.iso"]="da6eed49185e7d4e5199e4fb15252d53a377e4a7dad572838705bfebfb7ac0ab"
  ["bsd"]="5d576c453f78a48dbb20f9e7d26eeacabb2a4e0b814e5cb578c52489a6ab1030"
  ["bsd.mp"]="869351281e616b2eea8cade78f1081babd88d646e89f57acf2938eaa54734793"
  ["bsd.rd"]="6f0974bf92e28e2a97594987cfd1db135fc2fb4aea00f3f3e35ca6f70448f034"
  ["base79.tgz"]="923d2e03f06408d50d4848334398c6d04b5514dcac7917badfc178a0eef248de"
  ["man79.tgz"]="7a5e66facf678b41b6b4722b073c357d1eea27facaf4610701ffbec1c80751af"
  ["xbase79.tgz"]="9418643106bdd17bdf1fad19e2dd9af789c42d5a184999696af23c6e71b94edb"
  ["xfont79.tgz"]="72ca863adeff7c719f27bd5b74b98f4dd1ecd7980a44ec38fc368d807becf6a2"
  ["xserv79.tgz"]="2983b33123226d3086290ea7e0497e93553abdf0ffd3bda633cfa47e8b8f7be7"
  ["xshare79.tgz"]="4a16fb91da827ddd5ef8cea43f3d22753ac02137144bd23bdd7fd91e8ab186a6"
  ["SHA256"]="50bec66f28426a22b9c9436f6a87cf3e7029e636bb915ba1d0db80d638881b87"
  ["SHA256.sig"]="99db2ba3d63cddeeb9a1166319e48bf4b22224c48bbdc4deff8ecadc0f7b2786"
  ["INSTALL.amd64"]="28c272da41fa8d6f9ff1399ec4b7748368438c86e4a516e302cad1f16e657807"
)

FORCE=0
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
    -h | --help)
      sed -n '2,105p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '[build:openbsd] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

verify_sha256() {
  local f="$1" want="${PIN_SHA256[$1]}" got
  [ -f "$STAGE_DIR/$f" ] || return 1
  got="$(sha256sum "$STAGE_DIR/$f" | awk '{print $1}')"
  [ "$got" = "$want" ]
}

fetch_and_verify() {
  mkdir -p "$STAGE_DIR"
  local f
  for f in "${FETCH_FILES[@]}"; do
    if [ "$FORCE" -eq 0 ] && verify_sha256 "$f"; then
      log "stage ok (skip fetch): $f"
      continue
    fi
    log "fetching $f from $MIRROR"
    curl -fsSL -o "$STAGE_DIR/$f.part" "$MIRROR/$f"
    mv "$STAGE_DIR/$f.part" "$STAGE_DIR/$f"
    verify_sha256 "$f" || die "sha256 mismatch for $f (pin ${PIN_SHA256[$f]}, got $(sha256sum "$STAGE_DIR/$f" | awk '{print $1}'))"
    log "verified: $f"
  done
}

build_site_tarball() {
  local kit="$HERE/openbsd-site"
  [ -d "$kit" ] || die "missing site kit $kit — checked-in owned path"
  (cd "$kit" && tar --owner=0 --group=0 --numeric-owner -czf "$WORK/site79.tgz" .)
  log "built site79.tgz from $kit"
}

build_www_tree() {
  local dir="$WWW_DIR/pub/OpenBSD/7.9/amd64"
  mkdir -p "$dir"
  local f
  for f in "${FETCH_FILES[@]}"; do
    ln -sf "$STAGE_DIR/$f" "$dir/$f"
  done
  ln -sf "$WORK/site79.tgz" "$dir/site79.tgz"
  local conf="$HERE/openbsd-install.conf"
  [ -f "$conf" ] || die "missing $conf — checked-in owned path"
  cp "$conf" "$WWW_DIR/install.conf"
  (cd "$dir" && ls -lL >index.txt)
  log "www tree ready at $WWW_DIR"
}

serve_www() {
  command -v kh-claim >/dev/null || die "kh-claim not on PATH"
  [ -n "${KH_SESSION:-}" ] || die "KH_SESSION not set — required to claim port $HTTP_PORT"
  kh-claim take port "$HTTP_PORT" || die "could not claim port $HTTP_PORT"
  (
    cd "$WWW_DIR" && python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >"$WORK/httpd.log" 2>&1 &
    echo $! >"$HTTPD_PIDFILE"
  )
  log "loopback httpd on 127.0.0.1:$HTTP_PORT (pid $(cat "$HTTPD_PIDFILE"))"
}

release_www() {
  if [ -f "$HTTPD_PIDFILE" ]; then
    kill "$(cat "$HTTPD_PIDFILE")" 2>/dev/null || true
    rm -f "$HTTPD_PIDFILE"
  fi
  kh-claim release port "$HTTP_PORT" 2>/dev/null || true
}
trap release_www EXIT

install_guest() {
  mkdir -p "$WORK" "$GUEST_DIR"
  local disk="$WORK/openbsd.qcow2"
  qemu-img create -f qcow2 "$disk" "$DISK_BYTES" >/dev/null

  qemu-system-x86_64 \
    -machine pc-i440fx-11.0,accel=kvm \
    -cpu host -m 1024 -smp 2 \
    -vga none -device VGA,edid=on,xres=1024,yres=768 \
    -drive file="$disk",if=virtio,format=qcow2 \
    -cdrom "$STAGE_DIR/cd79.iso" -boot d \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -usb -device usb-tablet \
    -device AC97 \
    -display dbus,p2p=on \
    -qmp "unix:$QMP,server,nowait" \
    -pidfile "$PIDFILE" \
    -daemonize

  python3 "$HERE/../../dev/fb-wait.py" --qmp "$QMP" --settle 3 --timeout 60 ||
    die "installer prompt did not settle"
  python3 "$HERE/../../dev/qmp-type.py" --qmp "$QMP" "a\n"
  python3 "$HERE/../../dev/fb-wait.py" --qmp "$QMP" --change --timeout 30 ||
    die "no response-file prompt after autoinstall selection"
  python3 "$HERE/../../dev/qmp-type.py" --qmp "$QMP" "http://10.0.2.2:${HTTP_PORT}/install.conf\n"
  python3 "$HERE/../../dev/fb-wait.py" --qmp "$QMP" --settle 25 --timeout 900 ||
    die "install did not reach the halt screen within 900s"

  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi

  cp "$disk" "$GUEST_DIR/$OUT_NAME"
  log "wrote $GUEST_DIR/$OUT_NAME"
}

main() {
  mkdir -p "$WORK"
  fetch_and_verify
  build_site_tarball
  build_www_tree
  serve_www
  install_guest
}

main "$@"
