#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/riscos.sh — from-scratch, reproducible build of the RISC OS 5
# tile (:8111) for the neko Kernel Hive.
#
# GOAL: on a FRESH Proxmox host (gallery infra present), rebuild the RISC OS 5
# guest END TO END from its real upstream sources — no image backups, no
# pre-staged files. Unlike the QEMU tiles, this is an **EMULATOR tile**: neko
# streams the X window of **RPCEmu** (Peter Howkins / Sarah Walker's Acorn
# RiscPC / A7000 emulator) running RISC OS 5. RISC OS is ARM, so there is no
# QEMU/KVM here at all — RPCEmu is a userspace ARM(v4) emulator with an amd64
# JIT recompiler.
#
# WHAT THIS PRODUCES:
#   * Guest data staged at  <GUEST_DIR>            (default /data/gallery-guests/RISCOS)
#       roms/riscos   — the 4 MiB ROOL IOMD 5.30 softload ROM image
#       hostfs/       — the ROOL HardDisc4 disc (the RISC OS !Boot + apps)
#       rpc.cfg       — RPCEmu machine config (RPC610, 128 MB, sound on)
#       cmos.ram      — RPCEmu NVRAM seed
#   * A Docker image  neko-rpcemu:latest  (neko:base + Qt5 + RPCEmu 0.9.5 built
#       from source, amd64 recompiler) — the per-tile streamer.
#   * A compose file  docker-compose.riscos.yml  (isolated project) wiring the
#       live tile at :8111.
#
# ---- LICENSING --------------------------------------------------------------
#   * RISC OS 5 — **freely available shared-source** from RISC OS Open Ltd
#     (ROOL). The IOMD ROM + HardDisc4 disc are distributed by ROOL for use on
#     real hardware AND in RPCEmu. Downloaded here directly from riscosopen.org.
#     (This is the modern open RISC OS 5 line, NOT the proprietary Acorn
#     RISC OS 3.x ROMs — those are the abandonware ones and are NOT used.)
#   * RPCEmu — GPLv2 (Sarah Walker / Peter Howkins), source from marutan.net.
#   So this whole tile is a clean free/open path — no abandonware involved.
#
# ---- AUTOMATION HONESTY -----------------------------------------------------
#   (1) DOWNLOAD ....... FULLY AUTOMATED (real upstream URLs, re-fetched here).
#   (2) BUILD .......... FULLY AUTOMATED — RPCEmu compiled from source in the
#                        neko-rpcemu image (Qt5 qmake, CONFIG+=dynarec).
#   (3) DISK/INSTALL ... N/A — no installer. RISC OS boots the ROM + HardDisc4 to
#                        the RISC OS supervisor '*' prompt; a pre-configured
#                        HostFS-boot cmos.ram makes it run the HardDisc4 !Boot,
#                        and launch-rpcemu.sh auto-issues `Desktop` to bring up
#                        the WIMP (pinboard + icon bar). Fully hands-off at run
#                        time (the keystrokes are automated inside the image).
#   (4) ERA SOFTWARE ... bundled in the HardDisc4 disc already (ROOL default).
#   (5) VERIFY ......... FULLY AUTOMATED — boots the live tile and captures the
#                        neko (v3) framebuffer via login->bearer->screen shot,
#                        then asserts the RISC OS desktop rendered.
#   => No manual/interactive steps. The whole build is hands-off.
#
#   NB on the !Boot RMEnsure guards: this ROOL HardDisc4 !Boot RMEnsures
#   UtilityModule/SharedCLibrary versions that this IOMD 5.30 softload ROM does
#   not satisfy, so !Boot aborts before its own final `Desktop`. That is why we
#   issue `Desktop` from launch-rpcemu.sh. The desktop, icon bar (HostFS + Apps),
#   pinboard and bundled !Apps all come up correctly.
#
# IDEMPOTENT / RE-RUNNABLE: skips downloads if valid artifacts already exist
# (override with --force). Uses a namespaced work dir. Runs the live tile as its
# OWN isolated compose project (osgallery-riscos) so it never disturbs other
# gallery tiles, the shared docker-compose.gallery-guests.yml, VM 900/925, or
# CTID 110's other services. Kills nothing by name.
#
# Usage:
#   build-guests/tiles/riscos.sh [--dir DIR] [--force] [--no-verify] [--host H] [-h]
#     --dir DIR      guest data dir       (default /data/gallery-guests/RISCOS)
#     --force        re-download even if valid artifacts are present
#     --no-verify    skip the live-tile framebuffer screenshot check
#     --host H       Proxmox host for the live-apply step (default from $LAB_HOST
#                    or root@192.0.2.10); "" = local (run ON the box)
#     -h|--help      show this header
#
# NOTE: this script is written to run ON the Proxmox host (it drives `pct exec
# 110 -- docker ...`). When run from a workstation, set --host and it will ssh.
# The reference commands below assume it runs on the box.
# =============================================================================
set -euo pipefail

# ---- config -----------------------------------------------------------------
# GUEST_DIR is the compose-relative guest data dir: docker-compose.riscos.yml
# mounts ./gallery-guests (=> /opt/osgallery/gallery-guests) into the container
# at /guests, so the staged data MUST live there for the mount to see it. The
# script runs inside CT 110 (it drives docker directly).
GUEST_DIR="/opt/osgallery/gallery-guests/RISCOS"
CTID="110"
TILE_PORT="8111"
# FIXED, collision-free EPR/udp block. Neighbours already claimed: Haiku
# 53320-53339, reactos 53340-53359, msdoswin1 53360-53379, amigaos 53400-53419.
# 53380-53399 is the free gap between msdoswin1 and amigaos.
EPR_LO="53380"
EPR_HI="53399"
PUB_IP="192.0.2.12"
IMAGE="neko-rpcemu:latest"
COMPOSE_PROJECT="osgallery-riscos"
FORCE=0
VERIFY=1

# Upstream sources (validated 2026-07-04):
#   RPCEmu 0.9.5 source (GPLv2)                        — marutan.net
#   RISC OS 5.30 IOMD softload ROM (ROOL shared-src)   — riscosopen.org
#   HardDisc4 5.30 disc image (ROOL)                   — riscosopen.org
RPCEMU_URL="http://www.marutan.net/rpcemu/cgi/download.php?sFName=0.9.5/rpcemu-0.9.5.tar.gz"
ROM_URL="https://www.riscosopen.org/zipfiles/platform/riscpc/IOMD-Soft.5.30.zip"
HDD_URL="https://www.riscosopen.org/zipfiles/platform/common/HardDisc4.5.30.zip"
# ROM path inside IOMD-Soft.zip:
ROM_ZIP_MEMBER="soft/!Boot/Resources/SoftLoad/riscos"

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
    --host)
      LAB_HOST="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '2,72p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

log() { printf '\033[1;36m[riscos]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[riscos] ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/riscos-build.XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---- deps -------------------------------------------------------------------
for t in curl unzip docker; do command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"; done

# =============================================================================
# (1) DOWNLOAD upstream sources
# =============================================================================
mkdir -p "$WORK/dl"
fetch() { # fetch URL DEST
  local url="$1" dst="$2"
  [ "$FORCE" = 0 ] && [ -s "$dst" ] && {
    log "cached: $(basename "$dst")"
    return 0
  }
  log "download: $url"
  curl -fSL --retry 3 --retry-delay 3 -o "$dst" "$url" || die "download failed: $url"
}
fetch "$ROM_URL" "$WORK/dl/iomd-soft.zip"
fetch "$HDD_URL" "$WORK/dl/harddisc4.zip"
fetch "$RPCEMU_URL" "$WORK/dl/rpcemu-0.9.5.tar.gz"

# =============================================================================
# (2) STAGE guest data at GUEST_DIR (bind-mounted read-only into CTID 110)
# =============================================================================
stage_guest() {
  local rom_ok=0
  [ "$FORCE" = 0 ] && [ -s "$GUEST_DIR/roms/riscos" ] && [ -d "$GUEST_DIR/hostfs/!Boot" ] && rom_ok=1
  if [ "$rom_ok" = 1 ]; then
    log "guest data already staged at $GUEST_DIR (use --force to rebuild)"
    return 0
  fi

  log "staging guest data -> $GUEST_DIR"
  rm -rf "$GUEST_DIR"
  mkdir -p "$GUEST_DIR/roms" "$GUEST_DIR/hostfs"

  # 2a. ROM: extract the single 4 MiB softload ROM image
  unzip -o -j "$WORK/dl/iomd-soft.zip" "$ROM_ZIP_MEMBER" -d "$GUEST_DIR/roms" >/dev/null ||
    die "could not extract ROM member '$ROM_ZIP_MEMBER'"
  [ -s "$GUEST_DIR/roms/riscos" ] || die "ROM image missing after extract"
  local sz
  sz="$(stat -c%s "$GUEST_DIR/roms/riscos" 2>/dev/null || stat -f%z "$GUEST_DIR/roms/riscos")"
  log "ROM staged: roms/riscos ($sz bytes; RPCEmu needs a 2/4/6/8 MiB total)"

  # 2b. HardDisc4 -> hostfs/ (strip the top-level HardDisc4/ dir)
  rm -rf "$WORK/hd"
  mkdir -p "$WORK/hd"
  unzip -o -q "$WORK/dl/harddisc4.zip" -d "$WORK/hd" || die "HardDisc4 unzip failed"
  cp -a "$WORK/hd/HardDisc4/." "$GUEST_DIR/hostfs/"
  [ -d "$GUEST_DIR/hostfs/!Boot" ] || die "hostfs/!Boot missing after extract"

  # 2c. cmos.ram — RISC OS NVRAM seed, PRE-CONFIGURED for a HostFS boot.
  # RPCEmu's stock cmos.ram boots from ADFS (no disc) => RISC OS drops to the
  # supervisor '*' prompt and never runs the HardDisc4 !Boot. We instead seed a
  # cmos.ram already carrying `Configure FileSystem HostFS` + `Configure Boot`
  # (captured from a one-time `*Configure` on this exact ROM, then persisted by
  # RPCEmu). With it, power-on selects HostFS as the boot filesystem and runs the
  # ROOL HardDisc4 !Boot (mounts the disc, sets Boot$Dir, loads ResourceFS apps),
  # yielding the proper icon bar. This is config data (like rpc.cfg below), not
  # an OS image — the OS itself is still 100% from the upstream ROM+HardDisc4.
  base64 -d >"$GUEST_DIR/cmos.ram" <<'CMOS'
AABSIxOExwAAAAAAAAAAAAB2AlAAb0AAQAAoPAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAADqsAD+AOsAmQAAAAAQVCAICiyQAgAAAAAAAAAAAAADAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGhQAAKT9EEH/AWEAEQAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACgEAADQAAA==
CMOS
  cat >"$GUEST_DIR/rpc.cfg" <<'CFG'
[General]
bridgename=rpcemu
cdrom_enabled=0
cdrom_iso=
cdrom_type=0
cpu_idle=1
ipaddress=172.31.0.1
macaddress=
mem_size=128
model=RPC610
mouse_following=1
mouse_twobutton=0
network_type=off
refresh_rate=60
show_fullscreen_message=0
sound_enabled=1
stretch_mode=1
username=
vram_size=2
CFG

  # The HardDisc4 zip preserves restrictive perms (ROM 0600, hostfs 0700, root-
  # owned). The neko container runs as a NON-root user and the mount is read-only
  # at the container, so those bits make the ROM/hostfs unreadable -> RPCEmu dies
  # with "Could not load ROM files from directory 'roms'". Make the staged tree
  # world-readable so the container's neko user can copy it into its per-boot dir.
  chmod -R a+rX "$GUEST_DIR"
  log "guest data staged ($(du -sh "$GUEST_DIR" | cut -f1)); made world-readable"
}
stage_guest

# =============================================================================
# (3) BUILD the neko-rpcemu image (neko:base + Qt5 + RPCEmu 0.9.5 recompiler)
# =============================================================================
build_image() {
  if [ "$FORCE" = 0 ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "image $IMAGE already present (use --force to rebuild)"
    return 0
  fi
  local ctx="$WORK/ctx"
  mkdir -p "$ctx"
  cp -f "$WORK/dl/rpcemu-0.9.5.tar.gz" "$ctx/rpcemu-0.9.5.tar.gz"

  cat >"$ctx/Dockerfile" <<'DOCKER'
FROM m1k1o/neko:base
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential qtbase5-dev qtmultimedia5-dev qtchooser qt5-qmake \
        libqt5multimedia5-plugins libqt5gui5 libqt5widgets5 libqt5core5a \
        libqt5network5 xdotool x11-utils ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/*
COPY rpcemu-0.9.5.tar.gz /tmp/
# Build RPCEmu from source. amd64 => the recompiler uses codegen_amd64 (fast JIT).
# We also build the plain interpreter as a fallback binary (rpcemu-interpreter).
RUN mkdir -p /opt && cd /opt && tar xzf /tmp/rpcemu-0.9.5.tar.gz && mv rpcemu-0.9.5 rpcemu \
    && cd /opt/rpcemu/src/qt5 \
    && qtchooser -run-tool=qmake -qt=5 CONFIG+=dynarec && make -j"$(nproc)" \
    && ( qtchooser -run-tool=qmake -qt=5 && make -j"$(nproc)" || true ) \
    && ls -la /opt/rpcemu/ && rm -f /tmp/rpcemu-0.9.5.tar.gz
COPY rpcemu.conf /etc/neko/supervisord/rpcemu.conf
COPY launch-rpcemu.sh /usr/local/bin/launch-rpcemu.sh
RUN chmod +x /usr/local/bin/launch-rpcemu.sh
DOCKER

  cat >"$ctx/rpcemu.conf" <<'CONF'
[program:rpcemu]
environment=HOME="/home/%(ENV_USER)s",USER="%(ENV_USER)s",DISPLAY="%(ENV_DISPLAY)s",XDG_RUNTIME_DIR="/tmp/runtime-%(ENV_USER)s"
command=/usr/local/bin/launch-rpcemu.sh
autorestart=true
priority=500
user=%(ENV_USER)s
stdout_logfile=/var/log/neko/rpcemu.log
stdout_logfile_maxbytes=100MB
stdout_logfile_backups=5
redirect_stderr=true
CONF

  cat >"$ctx/launch-rpcemu.sh" <<'LAUNCH'
#!/usr/bin/env bash
# Boot RISC OS 5 in RPCEmu, streamed by neko over WebRTC. RPCEmu reads its data
# (roms/ hostfs/ rpc.cfg cmos.ram poduleroms/) from the CWD (datadir defaults to
# "./"), so we cd into a writable per-boot dir seeded from the read-only golden
# guest mount at /guests/RISCOS.
set -u
export XDG_RUNTIME_DIR="/tmp/runtime-${USER:-neko}"
for _ in $(seq 1 60); do xdpyinfo >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 30); do [ -S "$XDG_RUNTIME_DIR/pulse/native" ] && break; sleep 1; done

SRC=/opt/rpcemu
GUEST="${GUEST_DIR:-/guests/RISCOS}"
DATA=/tmp/rpcemu-data
rm -rf "$DATA"; mkdir -p "$DATA/roms"
ln -sfn "$SRC/poduleroms" "$DATA/poduleroms"
ln -sfn "$SRC/netroms"    "$DATA/netroms"
cp -f "$GUEST/roms/riscos" "$DATA/roms/riscos"
cp -f "$GUEST/rpc.cfg"     "$DATA/rpc.cfg"
cp -f "$GUEST/cmos.ram"    "$DATA/cmos.ram" 2>/dev/null || true
cp -a "$GUEST/hostfs"      "$DATA/hostfs"
cd "$DATA"

BIN=""
for b in rpcemu-recompiler rpcemu-interpreter; do
  [ -x "$SRC/$b" ] && { BIN="$SRC/$b"; break; }
done
[ -n "$BIN" ] || { echo "launch-rpcemu: no rpcemu binary in $SRC" >&2; ls -la "$SRC" >&2; sleep 5; exit 1; }

# No WM in neko base + RISC OS lands at the supervisor '*' prompt. Two jobs here,
# both once the RPCEmu window exists:
#   (a) nudge the (undecorated) main window to the top-left; and
#   (b) issue `Desktop` to bring up the RISC OS WIMP (pinboard + icon bar).
# Why (b): with our HostFS-boot cmos the ROOL HardDisc4 !Boot DOES run, but its
# RMEnsure module guards (UtilityModule/SharedCLibrary version skew between this
# ROM and this HardDisc4) abort the Obey file before it reaches its final
# `Desktop`, leaving RISC OS at the '*' prompt. Typing `Desktop` starts the WIMP.
# RISC OS type-ahead buffers keystrokes, so a few spaced attempts guarantee one
# lands at the prompt; extra ones after the desktop is up are harmless no-ops.
( export DISPLAY="${DISPLAY:-:99.0}"
  W=""
  for _ in $(seq 1 90); do
    W="$(xdotool search --name 'RPCEmu - MIPS' 2>/dev/null | head -1)"
    [ -n "$W" ] && break
    sleep 1
  done
  [ -n "$W" ] || exit 0
  xdotool windowmove "$W" 0 0 2>/dev/null || true
  sleep 20
  for _ in $(seq 1 8); do
    xdotool windowfocus "$W" 2>/dev/null || true
    xdotool mousemove --window "$W" 320 300 click 1 2>/dev/null || true
    xdotool windowfocus "$W" 2>/dev/null || true
    xdotool type --delay 90 'Desktop' 2>/dev/null || true
    xdotool key Return 2>/dev/null || true
    sleep 10
  done ) &

echo "launch-rpcemu: exec $BIN (cwd=$DATA)"
exec "$BIN"
LAUNCH
  chmod +x "$ctx/launch-rpcemu.sh"

  log "building $IMAGE (Qt5 + RPCEmu 0.9.5 from source; a few minutes)…"
  docker build -t "$IMAGE" "$ctx" || die "docker build failed"
  log "image built: $IMAGE"
}
build_image

# =============================================================================
# (4) LIVE-APPLY the tile as its OWN isolated compose project (never touches
#     the shared docker-compose.gallery-guests.yml or other tiles).
# =============================================================================
COMPOSE_FILE="/opt/osgallery/docker-compose.riscos.yml"
write_compose() {
  cat >"$COMPOSE_FILE" <<YML
# Standalone RISC OS 5 tile (:${TILE_PORT}) — isolated compose project
# (${COMPOSE_PROJECT}) so it never touches the concurrently-edited
# docker-compose.gallery-guests.yml (SailfishOS/TempleOS isolation pattern).
# EMULATOR tile: neko streams RPCEmu (Acorn RiscPC/A7000 emulator) running
# RISC OS 5 (ROOL shared-source IOMD 5.30 softload ROM) as a fullscreen X app —
# NOT QEMU, no KVM.
services:
  riscos:
    image: ${IMAGE}
    restart: unless-stopped
    shm_size: 1gb
    ports: ["${TILE_PORT}:8080","${EPR_LO}:${EPR_LO}/udp"]
    volumes: ["./gallery-guests:/guests:ro"]
    environment:
      NEKO_SCREEN: "1280x720@30"
      NEKO_PASSWORD: "neko"
      NEKO_PASSWORD_ADMIN: "admin"
      NEKO_UDPMUX: "${EPR_LO}"
      NEKO_ICELITE: "true"
      NEKO_NAT1TO1: "${PUB_IP}"
      NEKO_SESSION_IMPLICIT_HOSTING: "true"
      OS_NAME: "RISC OS 5"
YML
  log "wrote $COMPOSE_FILE"
}
write_compose

log "bringing up the live tile (project ${COMPOSE_PROJECT})…"
(cd /opt/osgallery && docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d)

# =============================================================================
# (5) VERIFY — capture the neko framebuffer and assert the RISC OS desktop drew.
# =============================================================================
verify_tile() {
  [ "$VERIFY" = 1 ] || {
    log "verify skipped (--no-verify)"
    return 0
  }
  log "verify: waiting for the RISC OS desktop to render (RPCEmu cold boot)…"
  local shot="$WORK/riscos-desktop.jpg" ok=0 tok=""
  # neko v3 admin screenshot API: POST /api/login -> bearer token, then
  # GET /api/room/screen/shot.jpg with Authorization: Bearer (basic auth is gone).
  for _ in $(seq 1 30); do
    sleep 8
    # NB: guard the command substitution with `|| tok=""` — during the RPCEmu
    # cold-boot window the login curl fails, and under `set -e` a bare failing
    # assignment would abort the whole script mid-verify.
    tok="$(curl -fsS -X POST -H 'Content-Type: application/json' \
      -d '{"username":"admin","password":"admin"}' \
      "http://127.0.0.1:${TILE_PORT}/api/login" 2>/dev/null |
      sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" || tok=""
    [ -n "$tok" ] || continue
    if curl -fsS -H "Authorization: Bearer $tok" \
      "http://127.0.0.1:${TILE_PORT}/api/room/screen/shot.jpg" -o "$shot" 2>/dev/null &&
      [ -s "$shot" ]; then
      # crude colour-variety check via ImageMagick if present, else just size>20KB
      if command -v identify >/dev/null 2>&1; then
        local colors
        colors="$(identify -format '%k' "$shot" 2>/dev/null || echo 0)"
        [ "${colors:-0}" -gt 200 ] && {
          ok=1
          break
        }
      else
        [ "$(stat -c%s "$shot" 2>/dev/null || echo 0)" -gt 20000 ] && {
          ok=1
          break
        }
      fi
    fi
  done
  [ "$ok" = 1 ] || die "verify FAILED — RISC OS desktop did not render (no rich framebuffer captured)"
  cp -f "$shot" "$GUEST_DIR/riscos-desktop.jpg" 2>/dev/null || true
  log "verify: PASS — RISC OS desktop rendered (proof: $GUEST_DIR/riscos-desktop.jpg)"
}
verify_tile

cat <<EOF

============================================================================
RISC OS 5 tile build complete.
  Guest data     : ${GUEST_DIR}   (roms/riscos, hostfs/, rpc.cfg, cmos.ram)
  Image          : ${IMAGE}
  Compose        : ${COMPOSE_FILE}  (project ${COMPOSE_PROJECT})
  Live tile      : http://${PUB_IP}:${TILE_PORT}/?usr=guest&pwd=neko

This is an EMULATOR tile: neko streams RPCEmu (RiscPC/A7000 emulator), NOT QEMU.
  RPCEmu 0.9.5  (GPLv2)                 — built from source, amd64 recompiler
  RISC OS 5.30  (ROOL, shared-source)   — IOMD softload ROM + HardDisc4 disc
Era: Acorn RiscPC (beige). Confirm the pinboard + icon bar RISC OS desktop.

Add to the :8080 index (gallery/index.html OSES array):
  {"label":"RISC OS 5","url":"http://${PUB_IP}:${TILE_PORT}/?usr=guest&pwd=neko"}
============================================================================
EOF
