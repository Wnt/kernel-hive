#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/indyr4400.sh — build the SGI Indy (MIPS R4400) / IRIX 6.5
# streamhost tile as a thin overlay on the shared bridge base
# (scripts/build-guests/lib/bridge-base.sh).
#
# GUEST : a captured Debian-12 kiosk running Iris (github.com/techomancer/iris,
#         BSD-3), a userspace Rust emulator of a REAL SGI Indy — MIPS R4400,
#         256 MB, XL/REX3 24-bit graphics — booting IRIX 6.5.22 to the Indigo
#         Magic graphical login. streamhost captures the Linux framebuffer.
# TYPE  : "emulator bridge" tile (see streamhost/docs/BRIDGE.md). Overlay + a
#         per-tile /etc/bridge/launch.sh + an INTERNAL qcow2 golden snapshot.
#
# DISTINCT FROM the 'irix' tile. Same museum machine, different silicon and a
# different emulator: `irix` is MAME's indy_4610 (an **R4600** Indy) and runs
# BARE-METAL as an x11-runtime tile because MAME's Indy emulation kernel-panics
# under a KVM vCPU. Iris is pure userspace and has no such constraint — verified
# on 2026-08-10 by booting it inside a KVM guest to the graphical login — so this
# exhibit is an ordinary bridge tile and inherits pointer, keyboard and
# `loadvm golden` from QEMU with zero streamhost daemon changes.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   * THE IRIS BINARY IS BUILT AGAINST THE GUEST'S SUITE, NOT BLINDLY AGAINST
#     THE HOST. On the BOOKWORM suite the lab box (Debian 13 trixie, glibc 2.41)
#     and the frozen bridge base (Debian 12, glibc 2.36) disagree, and a
#     host-built iris dies in the guest with "GLIBC_2.39 not found" — so the
#     build goes through a throwaway bookworm chroot (debootstrap + a rustup
#     install inside it, ~10 minutes before a line of Rust compiles) and only the
#     resulting 64 MB binary is copied into the overlay; no Rust toolchain is
#     ever installed in the tile. On the TRIXIE suite host and guest are the same
#     generation (glibc 2.41 both sides), so that whole dance — and the
#     debootstrap dependency with it — is SKIPPED and iris is built directly with
#     the host's own cargo. Same output, same pin, one fewer moving part: this is
#     the clearest place in the repo where the migration pays for itself.
#     The suite comes from registry/bridge-suites.json (resolver:
#     scripts/build-guests/lib/bridge-suite.sh, docs/lab/BRIDGE-TRIXIE-MIGRATION.md).
#   * THE 6.3 GB IRIX DISK IS AN ASSET, NOT OVERLAY CONTENT. It is staged by
#     streamhost/tiles/indyr4400/fetch-assets.sh as a READ-ONLY ext4 image and
#     attached as a second, read-only virtio drive; the guest mounts it at
#     /srv/irix and Iris opens /srv/irix/disk.raw through a symlink in its own
#     writable dir, with `overlay = true` so its copy-on-write file lands on the
#     tile's disk instead. Read-only drives are invisible to `savevm`, so the
#     golden stays small and the asset can never be dirtied.
#   * The disk image is DERIVED from this lab's own irix-tile golden CHD via
#     `chdman extracthd` — no third-party download, same preservation-class
#     media the gallery already runs. It is NEVER committed (the repo is
#     public); provenance + measured sha256 live in docs/lab/ASSETS-MANIFEST.md.
#   * Iris renders through OpenGL; the host has NO GPU, so launch.sh forces
#     llvmpipe software GL (LIBGL_ALWAYS_SOFTWARE=1). Iris is a winit window on
#     the bare X root with NO window manager, sized to the emulated framebuffer,
#     so the capture is 1:1 at 1280x1024 with no resampling — verify it.
#   * NO WINDOW MANAGER means nothing calls XSetInputFocus, and winit (unlike
#     SDL, which every other bridge tile uses) DROPS key events for a window it
#     does not consider focused. The pointer keeps working because winit takes
#     it from XI2 raw device events, which ignore focus -- so the exhibit looks
#     alive with a silently dead keyboard. launch.sh focuses the iris window
#     explicitly with xdotool, which this script installs into the overlay.
#   * `xset r off`: every key this tile sees is an injected press/release pair,
#     and a late release makes X's typematic repeat hammer the held key (the
#     Oric Atmos failure). Off before the emulator starts.
#   * Audio is OFF for this phase (Iris `--noaudio`, no AC97 in the device set).
#   * ACCEPTANCE is a REAL framebuffer screenshot of the IRIX login/desktop —
#     never disk/log inference.
#
# HYGIENE: overlay (no full copy), unique qmp.sock/pidfile, kill ONLY by
# pidfile, idempotent, --force to rebuild the overlay. Touches ONLY the
# indyr4400 tile dir, its asset dir, and its own chroot work dir.
#
# Usage:  indyr4400.sh [--force] [--build-iris] [-h]
# =============================================================================
set -euo pipefail

# ---- assigned namespacing (fixed — no collisions) ---------------------------
TILE=indyr4400
VMID=239
UDP=54136
SSH_PORT=5839
WEB_PORT=8136
MEM=2048
KEY="/data/vms/bridge/bridge_key"
TILE_DIR="/data/vms/streamhost/tiles/${TILE}"
OVERLAY="${TILE_DIR}/overlay.qcow2"
QMP="${TILE_DIR}/qmp.sock"
PID="${TILE_DIR}/qemu.pid"
ASSET_DIR="/data/gallery-guests/IrisIndy"
ASSET="${ASSET_DIR}/irix65-r4400-disk.ext4"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-suite.sh"
SUITE="$(bridge_suite_for "$TILE")"
# The overlay backs onto the SAME suite the binary was linked against.
BRIDGE_BASE="${BRIDGE_BASE:-$(bridge_base_for "$SUITE")}" # env override wins
# The binary is named after the suite it was linked against, so a migration
# cannot silently reuse the wrong-ABI one that is already sitting in ASSET_DIR.
IRIS_BIN="${ASSET_DIR}/iris-${SUITE}" # ABI-matched binary, built by --build-iris
IRIS_REPO="https://github.com/techomancer/iris"
IRIS_COMMIT="1e05210" # pinned; features lightning,rex-jit,chd
CHROOT="/data/vms/soltest/indyr4400-${SUITE}"

FORCE=0
BUILD_IRIS=0
while [ $# -gt 0 ]; do case "$1" in
  --force)
    FORCE=1
    shift
    ;;
  --build-iris)
    BUILD_IRIS=1
    shift
    ;;
  -h | --help)
    sed -n '2,69p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

log() { echo "[indyr4400 $(date +%H:%M:%S)] $*"; }
guest() { ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"; }

# The Iris/IRIX kiosk launcher (overlaid onto the base's /etc/bridge/launch.sh).
# stdout deliberately stays on tty1 (see the VICE trap in the playbook 7.2.1).
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# SGI Indy (R4400) / IRIX 6.5 kiosk launcher (bridge tile).
# See scripts/build-guests/tiles/indyr4400.sh for rationale.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export LIBGL_ALWAYS_SOFTWARE=1 # GPU-less host: llvmpipe software OpenGL
export GALLIUM_DRIVER=llvmpipe
# The Indy's XL framebuffer is 1280x1024; match the X root exactly so streamhost
# captures the emulated picture 1:1 with no window-manager resampling.
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 1280x1024 2>/dev/null || true
xset s off -dpms s noblank 2>/dev/null || true
xset r off 2>/dev/null || true # synthetic keys: typematic repeat corrupts input
xsetroot -solid black 2>/dev/null || true
# THERE IS NO WINDOW MANAGER, so nothing ever calls XSetInputFocus and the X
# focus stays PointerRoot. Iris is a winit app and winit DROPS key events for a
# window it does not consider focused -- the pointer still works (it comes from
# XI2 raw device events, which ignore focus), so the tile looks alive while the
# keyboard is silently dead. Focus the window explicitly once it appears.
(
  for _ in $(seq 1 90); do
    W=$(xdotool search --class iris 2>/dev/null | head -1)
    if [ -n "$W" ]; then xdotool windowfocus "$W" 2>/dev/null && break; fi
    sleep 1
  done
) &
cd /var/lib/iris
exec iris --config /var/lib/iris/iris.toml --noaudio
EOS

read -r -d '' IRISTOML <<'EOS' || true
# iris.toml — SGI Indy R4400 / IRIX 6.5 gallery exhibit.
# The PROM is embedded in the binary; nvram.bin is created here on first run.
headless = false
no_audio = true
scale    = 1
banks    = [128, 128, 0, 0]   # 256 MB, a real Indy's maximum
nvram    = "/var/lib/iris/nvram.bin"

# disk.raw is a SYMLINK to the read-only asset mounted at /srv/irix. overlay=true
# keeps every guest write in /var/lib/iris/disk.raw.overlay on the tile's own
# writable disk, so the 6.3 GB asset is never modified.
[scsi.1]
path    = "/var/lib/iris/disk.raw"
cdrom   = false
overlay = true
EOS

# ---- boot the tile QEMU (exact device set; conditional -loadvm golden) -------
boot_tile() {
  [ -f "$PID" ] && kill "$(cat "$PID")" 2>/dev/null || true
  sleep 0.5
  rm -f "$QMP" "$PID"
  local LOADVM=""
  qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden"
  # shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
  nohup qemu-system-x86_64 \
    -name streamhost-${TILE} -enable-kvm -m ${MEM} -smp 4 -machine pc-i440fx-11.0,vmport=off -cpu host \
    -rtc base=localtime \
    -drive file="${OVERLAY}",if=ide,format=qcow2 -boot c \
    -drive file="${ASSET}",if=virtio,format=raw,readonly=on \
    -vga std \
    -display dbus,p2p=on \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 -device e1000,netdev=n0 \
    $LOADVM \
    -qmp unix:${QMP},server=on,wait=off -pidfile ${PID} \
    >"${TILE_DIR}/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  log "tile booted (loadvm='${LOADVM:-<none: cold>}')"
}

# ---- build iris against the GUEST's glibc, outside the tile ------------------
# Two paths, chosen by the tile's suite. They differ ONLY in where cargo runs:
# same repo, same pinned commit, same feature set, same installed binary.
build_iris() {
  if [ "$SUITE" = bookworm ]; then build_iris_chroot; else build_iris_native; fi
  log "iris built: $IRIS_BIN ($(stat -c %s "$IRIS_BIN") bytes)"
}

# TRIXIE suite: the host IS the guest's generation (both glibc 2.41), so a
# host-built binary loads in the guest unchanged. No debootstrap, no chroot, no
# second rustup — the ~10-minute bootstrap that only ever existed to dodge
# "GLIBC_2.39 not found" simply does not happen. If the host ever moves ahead of
# the guest again, this tile goes back on a chroot, which is what the suite
# ledger is for.
build_iris_native() {
  log "building iris ${IRIS_COMMIT} on the host (suite ${SUITE}: host and guest"
  log "  are the same Debian generation, so no ABI chroot is needed) ..."
  command -v cargo >/dev/null || {
    echo "cargo not found on the host; install rustup or a rustc/cargo package" >&2
    exit 1
  }
  # $CHROOT is only a scratch dir here -- nothing is ever chrooted into. Same
  # layout as the bookworm path so the two produce the same tree.
  rm -rf "$CHROOT"
  mkdir -p "$CHROOT"
  git clone "$IRIS_REPO" "$CHROOT/build"
  (
    cd "$CHROOT/build"
    git checkout "$IRIS_COMMIT"
    unset CARGO_TARGET_DIR # the box sets a shared target dir; keep ours local
    cargo build --release --features lightning,rex-jit,chd
  )
  install -d -m 0755 "$ASSET_DIR"
  install -m 0755 "$CHROOT/build/target/release/iris" "$IRIS_BIN"
  rm -rf "$CHROOT"
}

# BOOKWORM suite: unchanged. The host is trixie (glibc 2.41) and the frozen
# bridge base is bookworm (2.36), so iris must be linked in a bookworm userland
# or it dies in the guest with "GLIBC_2.39 not found". Hence debootstrap.
build_iris_chroot() {
  log "building iris ${IRIS_COMMIT} in a bookworm chroot (host is trixie; the"
  log "  bridge base is bookworm, and a trixie-built iris needs GLIBC_2.39) ..."
  rm -rf "$CHROOT"
  mkdir -p "$CHROOT"
  debootstrap --variant=minbase bookworm "$CHROOT" http://deb.debian.org/debian
  mount -t proc proc "$CHROOT/proc"
  mount --rbind /sys "$CHROOT/sys"
  mount --rbind /dev "$CHROOT/dev"
  cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"
  chroot "$CHROOT" /bin/bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq build-essential pkg-config libasound2-dev curl ca-certificates git
    curl -sSf https://sh.rustup.rs -o /tmp/ru.sh
    sh /tmp/ru.sh -y --default-toolchain none --profile minimal'
  chroot "$CHROOT" /bin/bash -lc "
    set -e
    export PATH=/root/.cargo/bin:\$PATH
    unset CARGO_TARGET_DIR   # the box sets a shared target dir; keep ours local
    git clone ${IRIS_REPO} /build
    cd /build && git checkout ${IRIS_COMMIT}
    cargo build --release --features lightning,rex-jit,chd"
  install -d -m 0755 "$ASSET_DIR"
  install -m 0755 "$CHROOT/build/target/release/iris" "$IRIS_BIN"
  umount -l "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/dev" 2>/dev/null || true
  rm -rf "$CHROOT"
}

# ---- main -------------------------------------------------------------------
[ -f "$BRIDGE_BASE" ] || {
  echo "no $SUITE bridge base: $BRIDGE_BASE (run bridge-base.sh --suite $SUITE)"
  exit 1
}
bash "$(dirname "$0")/../../../streamhost/tiles/${TILE}/fetch-assets.sh"
[ -f "$IRIS_BIN" ] || BUILD_IRIS=1
[ "$BUILD_IRIS" -eq 1 ] && build_iris
mkdir -p "$TILE_DIR"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 0 ]; then
  log "overlay exists: $OVERLAY (use --force to recreate — DESTROYS the golden snapshot)"
else
  log "creating thin overlay on the frozen bridge base ..."
  rm -f "$OVERLAY"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

# 1. cold boot (no golden yet): install iris + the IRIX kiosk launcher
if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for guest ssh ..."
  for _ in $(seq 1 40); do
    guest true 2>/dev/null && break
    sleep 3
  done
  log "installing xdotool (the kiosk focus fix -- see the header) ..."
  guest "export DEBIAN_FRONTEND=noninteractive; apt-get update -o Acquire::Retries=3 >/tmp/apt.log 2>&1; apt-get install -y xdotool libxkbcommon-x11-0 libxcb-xkb1 >>/tmp/apt.log 2>&1; command -v xdotool"
  log "installing the iris binary and the read-only IRIX disk mount ..."
  scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -P "$SSH_PORT" "$IRIS_BIN" root@127.0.0.1:/usr/local/bin/iris
  guest "bash -s" <<'REMOTE'
set -e
chmod 0755 /usr/local/bin/iris
ldd /usr/local/bin/iris | grep -q 'not found' && { echo "iris ABI mismatch"; exit 1; }
mkdir -p /srv/irix /var/lib/iris
grep -q '^LABEL=IRISINDY' /etc/fstab || \
  echo 'LABEL=IRISINDY /srv/irix ext4 ro,nofail 0 0' >> /etc/fstab
mountpoint -q /srv/irix || mount /srv/irix
[ -f /srv/irix/disk.raw ] || { echo "asset drive did not mount"; exit 1; }
ln -sfn /srv/irix/disk.raw /var/lib/iris/disk.raw
# The kiosk runs as 'bridge'. A root-owned working dir means iris cannot create
# its COW overlay or its nvram and the guest never boots.
chown -R bridge:bridge /var/lib/iris
REMOTE
  printf '%s\n' "$IRISTOML" | guest "cat > /var/lib/iris/iris.toml; chown bridge:bridge /var/lib/iris/iris.toml"
  log "installing /etc/bridge/launch.sh (Iris / SGI Indy R4400, 1280x1024) ..."
  printf '%s\n' "$LAUNCH" | guest "cat > /etc/bridge/launch.sh; chmod +x /etc/bridge/launch.sh; chown root:root /etc/bridge/launch.sh"
  guest "pkill -u bridge iris 2>/dev/null; sleep 1; systemctl reset-failed getty@tty1; systemctl restart getty@tty1" || true
  log "IRIX 6.5 boots in ~3-5 min (PROM -> autoconfig -> 4Dwm login). VERIFY via framebuffer:"
  log "   python3 /root/qmp_hmp.py $QMP 'screendump /tmp/${TILE}.ppm'   # -> png -> look: IRIS login box?"
  log "   the captured frame MUST be exactly 1280x1024 with no black border."
  log "Then BAKE the golden fixture (with the IRIX login showing and nothing typed):"
  log "   python3 /root/qmp_hmp.py $QMP 'savevm golden'"
  log "   python3 /root/qmp_hmp.py $QMP 'loadvm golden'   # verify restore lands on the login"
  log "Re-run this script after baking to boot straight into the golden fixture (-loadvm golden)."
  log "Emit + start the tile:"
  log "   /data/vms/streamhost/scripts/streamhost-tile.sh --tile ${TILE} --vmid ${VMID} --udp ${UDP} \\"
  log "       --pointer rel --audio off --mem ${MEM} --smp 4 --cpu host --vga std --fps 30"
  log "   # then replace qemu-streamhost.sh with streamhost/tiles/${TILE}/qemu-streamhost.sh"
  log "   bash ${TILE_DIR}/qemu-streamhost.sh ; systemctl start streamhost@${TILE}"
fi

log "done. tile dir: $TILE_DIR  (VMID $VMID, udp $UDP, ssh $SSH_PORT, web $WEB_PORT)"
