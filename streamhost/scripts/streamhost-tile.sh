#!/bin/bash
# streamhost-tile.sh — emit one streamhost gallery tile's files. Materializes the
# per-tile config the systemd unit (deploy/streamhost@.service) consumes, and a
# QEMU launch script wired for streamhost. The authoritative ledger of every
# tile's emit invocation is ../stations-manifest.sh.
#
# THIS SCRIPT NEVER STARTS A TILE ON ITS OWN. It only writes files + (with
# --install) drops the systemd unit. Starting is a deliberate
# `systemctl start streamhost@<tile>` (or the ordered ../bring-up-all.sh).
# (Historical: written for the neko-era pilot cutover, one tile at a time; the
# gallery is now fully streamhost and the neko stack is gone — 2026-07.)
#
# THREE LAUNCHER MODES:
#   generic   (default) the qemu-streamhost.sh is GENERATED from the media/
#             machine/audio/input flags below — for tiles whose wiring fits the
#             standard template.
#   verbatim  (--launcher-file <path>) the qemu-streamhost.sh is INSTALLED
#             byte-for-byte from a tracked per-tile source (../tiles/<tile>/
#             qemu-streamhost.sh). Used for the golden-fixture / bridge /
#             state-disk tiles whose launchers carry bespoke logic (conditional
#             -loadvm golden, state-qcow2 create-if-missing, per-boot overlays,
#             post-boot QMP hostfwd_add, serial chardevs, reset monitors). The
#             launcher file itself is the device-set ledger for those tiles.
#   pve       (--pve-vmid <id>) PVE owns QEMU and its lifecycle. Only tile.env
#             and ROLLBACK.md are emitted; no qemu-streamhost.sh is generated.
#
# Usage:
#   scripts/streamhost-tile.sh --tile reactos --vmid 106 --udp 54106 \
#       [--advertise 192.0.2.12] [--pointer abs|rel|warpd|none] \
#       [--input-backend disabled|dbus-abs|dbus-rel|warpd|gallery-hid] [--audio on|off] \
#       [--vga std|cirrus|vmware|qxl|virtio|none] [--extra "raw qemu args"] \
#       [--fps 60] [--disk /path/tile.qcow2 | --disk-raw "raw media args"] \
#       [--accel kvm|tcg] [--launcher-file path | --pve-vmid id] \
#       [--env-append-file path] \
#       [--aux-file path]... [--out-root dir] [--pin-machine] [--install]
#
# Outputs under <out-root>/<tile>/ (default /data/vms/streamhost/tiles/<tile>/):
#   tile.env             SH_* environment consumed by streamhost@<tile>.service
#   qemu-streamhost.sh   local modes only: QEMU with streamhost display wiring
#   ROLLBACK.md          per-tile stop/restore procedure
#
# --out-root ONLY changes where the files are WRITTEN (e.g. a /tmp scratch dir
# for scripts/dev/verify-emit.sh); the file CONTENTS always reference the live
# runtime root /data/vms/streamhost/tiles/<tile>/.
#
# --pin-machine (or SH_PIN_MACHINE=1): emit VERSIONED machine types instead of
# the bare aliases — pc -> pc-i440fx-11.0, q35 -> pc-q35-11.0, and tiles that
# pass no -machine get an explicit -machine pc-i440fx-11.0 (QEMU's default).
# On today's pve-qemu 11.0.x this resolves to the IDENTICAL machine, but it
# immunizes the goldens against a future QEMU bump silently retargeting the
# alias (savevm/loadvm snapshots require an exact device-set match). Default
# OFF so verify-emit byte-parity against the live tiles holds; the NVMe
# rebuild emits with pinning ON (see docs/lab/MASTER-REPRODUCE.md Phase 5).
set -e

TILE=""
VMID=""
UDP=""
ADVERTISE=""
POINTER="abs"
INPUT_BACKEND=""
AUDIO="on"
FPS=60
WARPD_ADDR="127.0.0.1:7790" # host:port of the in-guest warpd agent (POINTER=warpd only)
WARPD_ADDR_SET=0            # SH_WARPD_ADDR is emitted only when --warpd-addr was passed
LOADVM_LAUNCH_DISK=""       # --loadvm-launch: qcow2 holding the `golden` savevm snapshot
# warpd fine-tuning (POINTER=warpd only). Empty = omit from tile.env so the
# daemon defaults rule; the manifest passes them for win311/os2warp.
WARPD_BUTTONS=""
WARPD_WHEEL=""
WARPD_PACE_MS=""
# dbus-abs inject pacing (SH_ABS_PACE_MS). The 2026-07-26 drag investigation
# hand-set 30 on the old GUI tiles and the manifest never learned it — the
# 2026-08-11 drift sweep found 10 live tiles a re-emit would have silently
# unpaced. Per-tile via --abs-pace-ms; empty = no line (daemon default 0).
ABS_PACE_MS=""
WARPD_BUTTON_DELAY_MS=""
# Higher-quality / ABR encoder knobs (SECTION 1 + 5b). The preset and the
# bufsize ratio are ALWAYS emitted because they are canonical fleet values
# (registry-v1.json fleetEncoder; the 2026-08-11 drift sweep found 23 live
# tiles whose hand-applied 0.5 a re-emit would have silently reverted to the
# daemon's 1.0). The remaining encoder block is emitted only when one of its
# flags is passed; otherwise the daemon defaults still rule (CQP q10 at
# tier 0, high/zerolatency, auto maxrate, ABR on with 25 s dwell + 480p
# floor; see config.rs).
# ultrafast matches the daemon's own default (config/parse.rs) — operator
# decision 2026-08-11: every tile streams ultrafast; the box is GPU-less and
# a busier preset buys latency, not quality a museum stream can show. The
# 2026-07/08 emits shipped "veryfast" here and seeded 29 live tile.envs +
# 4 registry tileEnv records with it (all re-set to ultrafast the same day).
ENCODER_PRESET="ultrafast"
PROFILE="high"
CRF=""
MAXRATE=0
BUFSIZE_RATIO="0.5" # fleet value; registry-v1.json fleetEncoder.bufsizeRatio
ABR="on"
ENC_SET=0
# Per-guest absolute-pointer calibration (FIX 3). Identity by default (daemon
# defaults 1.0/0/0); the SH_CURSOR_* lines are emitted only when a --cursor-*
# flag is passed (tinycore's non-identity mapping; helenos + the bridge tiles
# pin the identity explicitly). daemon: inject = round(client*scale) + off.
CURSOR_SCALE="1.0"
CURSOR_OFF_X=0
CURSOR_OFF_Y=0
CURSOR_SET=0
DISK=""
DISK_RAW=""
INSTALL=0
TRANSPORT="streamhost"
HOST_IP="192.0.2.10"
HOST_IP_SET=0
# Guest-media / machine knobs so each real gallery tile can be reproduced exactly
# (a tile may boot a LiveCD `-cdrom ... -boot d` on `-machine pc -cpu host`
# with an AC97 codec, not a virtio qcow2). Defaults preserve the prior behavior.
CDROM=""
BOOT=""
MACHINE=""
CPU=""
MEM=2048
SMP=2
AUDIO_DEV="hda"
EXTRA=""
# Legacy-keyboard quirk (pre-1986 Win 1.x/2.x guests): SH_LEGACY_KBD makes the
# daemon remap the dedicated cursor cluster to bare numeric-keypad scancodes (those
# guests' KEYBOARD driver predates the 0xE0-prefixed Enhanced scancodes). The line
# is emitted only when --legacy-kbd is passed (daemon default off); the daemon
# accepts on|1|true.
LEGACY_KBD="off"
LEGACY_KBD_SET=0
# Accelerator. Default kvm (-enable-kvm) preserves every prior tile's behavior.
# A FEW guests must NOT use hardware virtualisation — notably IBM OS/2 Warp 4,
# which will NOT boot under KVM. --accel tcg emits `-accel tcg` instead of -enable-kvm.
ACCEL="kvm"        # kvm | tcg
INPUT_DEV="virtio" # virtio (modern Linux/Haiku) | usb (NT-era: ReactOS/Win2000) | ps2
# VGA card the emulated GPU exposes (dbus captures whatever this drives). Default
# `std` == QEMU's plain -vga std (1280x800 EDID). Use `none` to omit the built-in
# -vga entirely and let --extra supply a fully-configured display device — e.g.
# Haiku forces 1280x720 via `-device VGA,id=vga0,edid=on,...` in --extra.
VGA="std"                             # std | cirrus | vmware | qxl | virtio | none
OUT_ROOT="/data/vms/streamhost/tiles" # where files are WRITTEN (--out-root)
RUN_ROOT="/data/vms/streamhost/tiles" # runtime root REFERENCED in file contents
LAUNCHER_FILE=""
PVE_VMID=""
# x11 runtime (the first non-QEMU tile, IRIX/issue #20): an emulator managed by
# a tracked x11-runtime.sh instead of a QEMU/dbus display. --x11 switches the
# emit to write a QMP-less tile.env (SH_CAPTURE/SH_X11_*/SH_TILE_RUNTIME) and
# install that launcher.
#
# The FRAME SOURCE is a separate axis from the runtime kind: --capture x11 grabs
# the Xvfb root, --capture shm maps a framebuffer the emulator publishes itself
# (MAME -video none: no window and no X server at all). Default x11.
X11=0
X11_CAPTURE="x11"
X11_DISPLAY=":40"
X11_RUNTIME_FILE=""
ENV_APPEND_FILE=""
AUX_FILES=()
PIN_MACHINE="${SH_PIN_MACHINE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --tile)
      TILE="$2"
      shift 2
      ;;
    --vmid)
      VMID="$2"
      shift 2
      ;;
    --udp)
      UDP="$2"
      shift 2
      ;;
    --advertise)
      ADVERTISE="$2"
      shift 2
      ;;
    --host-ip)
      HOST_IP="$2"
      HOST_IP_SET=1
      shift 2
      ;;
    --pointer)
      POINTER="$2"
      shift 2
      ;; # abs | rel | warpd (in-guest agent)
    --input-backend)
      INPUT_BACKEND="$2"
      shift 2
      ;; # preferred unified daemon backend
    --warpd-addr)
      WARPD_ADDR="$2"
      WARPD_ADDR_SET=1
      shift 2
      ;; # host:port | unix:<path>
    --warpd-buttons)
      WARPD_BUTTONS="$2"
      shift 2
      ;; # agent | qemu (SH_WARPD_BUTTONS)
    --warpd-wheel)
      WARPD_WHEEL="$2"
      shift 2
      ;; # auto | agent | qemu (SH_WARPD_WHEEL)
    --warpd-pace-ms)
      WARPD_PACE_MS="$2"
      shift 2
      ;; # min ms between agent writes
    --abs-pace-ms)
      ABS_PACE_MS="$2"
      shift 2
      ;; # min ms between dbus-abs injects (SH_ABS_PACE_MS; 30 on the old GUI tiles)
    --warpd-button-delay-ms)
      WARPD_BUTTON_DELAY_MS="$2"
      shift 2
      ;; # hybrid-buttons race guard
    --cursor-scale)
      CURSOR_SCALE="$2"
      CURSOR_SET=1
      shift 2
      ;; # abs-pointer scale (FIX 3)
    --cursor-off-x)
      CURSOR_OFF_X="$2"
      CURSOR_SET=1
      shift 2
      ;; # abs-pointer X origin offset
    --cursor-off-y)
      CURSOR_OFF_Y="$2"
      CURSOR_SET=1
      shift 2
      ;; # abs-pointer Y origin offset
    --audio)
      AUDIO="$2"
      shift 2
      ;;
    --audio-dev)
      AUDIO_DEV="$2"
      shift 2
      ;; # hda | ac97 | sb16 | pcspk (guest must drive it)
    --legacy-kbd)
      LEGACY_KBD="$2"
      LEGACY_KBD_SET=1
      shift 2
      ;; # on|1 => SH_LEGACY_KBD
    --vga)
      VGA="$2"
      shift 2
      ;; # std | cirrus | vmware | qxl | virtio | none
    --input-dev)
      INPUT_DEV="$2"
      shift 2
      ;; # virtio | usb | ps2 (guest must have a driver)
    --fps)
      FPS="$2"
      shift 2
      ;;
    --preset | --encoder-preset)
      ENCODER_PRESET="$2"
      shift 2
      ;; # ultrafast..veryslow
    --profile)
      PROFILE="$2"
      ENC_SET=1
      shift 2
      ;; # baseline | main | high
    --crf)
      CRF="$2"
      ENC_SET=1
      shift 2
      ;; # per-tile pin; unset = CQP q10
    --maxrate)
      MAXRATE="$2"
      ENC_SET=1
      shift 2
      ;; # tier-0 maxrate kbps; 0 = auto
    --bufsize-ratio)
      BUFSIZE_RATIO="$2"
      ENC_SET=1
      shift 2
      ;; # VBV bufsize = ratio*maxrate
    --abr)
      ABR="$2"
      ENC_SET=1
      shift 2
      ;; # on | off
    --disk)
      DISK="$2"
      shift 2
      ;;
    --disk-raw)
      DISK_RAW="$2"
      shift 2
      ;; # RAW media args replacing the -drive/if=virtio
      # default (placed in the media slot; --cdrom/
      # --boot still append after it)
    --cdrom)
      CDROM="$2"
      shift 2
      ;; # boot a LiveCD ISO instead of a disk
    --boot)
      BOOT="$2"
      shift 2
      ;; # qemu -boot order, e.g. d (cdrom)
    --machine)
      MACHINE="$2"
      shift 2
      ;; # e.g. pc (alias; see --pin-machine)
    --cpu)
      CPU="$2"
      shift 2
      ;; # e.g. host
    --mem)
      MEM="$2"
      shift 2
      ;;
    --smp)
      SMP="$2"
      shift 2
      ;;
    --accel)
      ACCEL="$2"
      shift 2
      ;; # kvm | tcg  (tcg for OS/2 & other non-KVM guests)
    --extra)
      EXTRA="$2"
      shift 2
      ;; # extra raw qemu args
    --loadvm-launch)
      LOADVM_LAUNCH_DISK="$2"
      shift 2
      ;; # generic mode: launch into this qcow2's `golden` snapshot, FROZEN (-S)
    --launcher-file)
      LAUNCHER_FILE="$2"
      shift 2
      ;; # verbatim qemu-streamhost.sh source
    --pve-vmid)
      PVE_VMID="$2"
      shift 2
      ;; # PVE-owned QEMU; emit no launcher
    --x11)
      X11=1
      shift
      ;; # x11-capture runtime (Xvfb+emulator), no QEMU/QMP
    --x11-display)
      X11_DISPLAY="$2"
      shift 2
      ;; # X display the runtime serves + streamhost captures (e.g. :40)
    --capture)
      X11_CAPTURE="$2"
      shift 2
      ;; # x11 (grab the Xvfb root) | shm (map the emulator's published frame)
    --x11-runtime-file)
      X11_RUNTIME_FILE="$2"
      shift 2
      ;; # tracked x11-runtime.sh installed as the tile launcher
    --env-append-file)
      ENV_APPEND_FILE="$2"
      shift 2
      ;; # verbatim tile.env tail (fixture stanza)
    --aux-file)
      AUX_FILES+=("$2")
      shift 2
      ;; # extra helper copied into the tile dir (e.g. qmpc.py)
    --out-root)
      OUT_ROOT="$2"
      shift 2
      ;; # WRITE destination root (contents unaffected)
    --pin-machine)
      PIN_MACHINE=1
      shift
      ;; # versioned machine types (see header)
    --install)
      INSTALL=1
      shift
      ;;
    --transport)
      TRANSPORT="$2"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done
: "${TILE:?--tile required}"
: "${UDP:?--udp required}"

# ---- deployment-local override (registry/local.env, gitignored) ----
# The repo ships a placeholder HOST_IP (192.0.2.10) so the registry's outputs stay
# a deterministic public artifact (checked by `make station-registry-check`). An
# operator's real address lives ONLY in registry/local.env on the box, never in
# a tracked file. --host-ip on the command line still wins over both.
if [ "$HOST_IP_SET" != 1 ]; then
  LOCAL_ENV="$(cd "$(dirname "$0")/../.." && pwd)/registry/local.env"
  if [ -f "$LOCAL_ENV" ]; then
    # shellcheck disable=SC1090
    . "$LOCAL_ENV"
    [ -n "${SH_HOST_IP:-}" ] && HOST_IP="$SH_HOST_IP"
  fi
fi

# ===========================================================================
# x11 RUNTIME MODE (SH_CAPTURE=x11 tiles — IRIX / issue #20)
# Emits a QMP-less tile.env plus a tracked x11-runtime.sh launcher (Xvfb +
# emulator). Kept fully self-contained so the QEMU emit path below is byte-for-
# byte unchanged for the 30 QEMU tiles.
# ===========================================================================
if [ "$X11" = 1 ]; then
  [ -n "$X11_RUNTIME_FILE" ] || {
    echo "--x11 requires --x11-runtime-file <path>" >&2
    exit 2
  }
  [ -f "$X11_RUNTIME_FILE" ] || {
    echo "FATAL: --x11-runtime-file $X11_RUNTIME_FILE missing" >&2
    exit 1
  }
  [ -z "$ADVERTISE" ] && ADVERTISE="$HOST_IP"
  BASE="${RUN_ROOT}/${TILE}"
  BASE_OUT="${OUT_ROOT}/${TILE}"
  mkdir -p "$BASE_OUT"
  # Input backend defaults to x11test (XTEST 1:1 abs pointer + Lua cmd-file
  # buttons/keys) unless the caller passed one explicitly.
  [ -n "$INPUT_BACKEND" ] || INPUT_BACKEND="x11test"
  # One variable so the x11 emit stays BYTE-IDENTICAL (no stray blank line) while
  # the shm emit gains exactly one line.
  X11_PATHS="SH_X11_CMD_FILE=${BASE}/${TILE}_cmd"
  [ "$X11_CAPTURE" = shm ] && X11_PATHS="${X11_PATHS}
SH_SHM_PATH=${BASE}/fb.shm"
  cat >"${BASE_OUT}/tile.env" <<EOF
# streamhost per-tile config for '${TILE}' (x11 runtime). Consumed by streamhost@${TILE}.service.
# NON-QEMU tile: an emulator managed by x11-runtime.sh, not a QEMU VM; NO SH_QMP.
# SH_CAPTURE picks the frame source: x11 grabs the Xvfb root, shm maps the
# framebuffer the emulator publishes itself (no window, no X server).
SH_TILE=${TILE}
SH_TILE_RUNTIME=x11
SH_CAPTURE=${X11_CAPTURE}
SH_X11_DISPLAY=${X11_DISPLAY}
${X11_PATHS}
SH_PORT=${UDP}
SH_FPS=${FPS}
SH_ENCODER_PRESET=${ENCODER_PRESET}
SH_BUFSIZE_RATIO=${BUFSIZE_RATIO:-0.5}
SH_HOST_IP=${HOST_IP}
SH_ADVERTISE_HOST=${ADVERTISE}
SH_INPUT_BACKEND=${INPUT_BACKEND}
SH_AUDIO=${AUDIO}
SH_AUDIO_BITRATE=96000
SH_HASH_FILE=${BASE}/cert_hash_b64.txt
SH_SIGNALING_JSON=${BASE}/signaling.json
SH_CERT_ROTATE_DAYS=10
EOF
  if [ -n "$ENV_APPEND_FILE" ]; then
    cat "$ENV_APPEND_FILE" >>"${BASE_OUT}/tile.env"
  fi
  cp "$X11_RUNTIME_FILE" "${BASE_OUT}/x11-runtime.sh"
  chmod +x "${BASE_OUT}/x11-runtime.sh"
  # Remove any stale QEMU launcher an earlier mode may have left in this dir.
  rm -f -- "${BASE_OUT}/qemu-streamhost.sh"
  for aux in ${AUX_FILES[@]+"${AUX_FILES[@]}"}; do
    [ -f "$aux" ] || {
      echo "FATAL: --aux-file $aux missing" >&2
      exit 1
    }
    cp "$aux" "${BASE_OUT}/$(basename "$aux")"
  done
  cat >"${BASE_OUT}/ROLLBACK.md" <<EOF
# Tile ${TILE} — stop / restore (x11 runtime, Xvfb + emulator, no QEMU/QMP)

Everything here affects ONLY this tile.

## Stop this tile
1. systemctl stop streamhost@${TILE}          # ExecStop tears down Xvfb+emulator by pidfile

## Restore this tile
1. systemctl start streamhost@${TILE}          # ExecStartPre relaunches Xvfb+emulator, serves udp/${UDP}

## Reset (relaunch = pristine RAM overlay)
1. bash ${BASE}/x11-runtime.sh                 # kill-by-pidfile + fresh Xvfb + emulator
EOF
  echo "emitted: ${BASE_OUT}/{tile.env,x11-runtime.sh,ROLLBACK.md}  mode=x11 transport=${TRANSPORT}"
  if [ "$INSTALL" = "1" ]; then
    HERE="$(cd "$(dirname "$0")/.." && pwd)"
    cp "${HERE}/deploy/streamhost@.service" /etc/systemd/system/streamhost@.service
    systemctl daemon-reload
    echo "installed streamhost@.service (NOT started — systemctl start streamhost@<tile> / bring-up-all.sh)"
  fi
  echo "--- stop/restore for ${TILE}: see ${BASE}/ROLLBACK.md ---"
  exit 0
fi

if [ -n "$PVE_VMID" ]; then
  case "$PVE_VMID" in *[!0-9]* | '')
    echo "invalid --pve-vmid: $PVE_VMID" >&2
    exit 2
    ;;
  esac
  [ -z "$LAUNCHER_FILE" ] || {
    echo "--pve-vmid and --launcher-file are mutually exclusive" >&2
    exit 2
  }
  [ -z "$VMID" ] || [ "$VMID" = "$PVE_VMID" ] || {
    echo "--vmid $VMID disagrees with --pve-vmid $PVE_VMID" >&2
    exit 2
  }
  VMID="$PVE_VMID"
  QEMU_MODE="pve"
else
  : "${VMID:?--vmid required}"
  QEMU_MODE="generic"
  [ -n "$LAUNCHER_FILE" ] && QEMU_MODE="verbatim"
fi
[ -z "$ADVERTISE" ] && ADVERTISE="$HOST_IP"

BASE="${RUN_ROOT}/${TILE}"     # referenced INSIDE the emitted files
BASE_OUT="${OUT_ROOT}/${TILE}" # where the emitted files are written
mkdir -p "$BASE_OUT"
QMP="${BASE}/qmp.sock"
PID="${BASE}/qemu.pid"
MODE_LINES=""
if [ "$QEMU_MODE" = "pve" ]; then
  MODE_LINES="
SH_QEMU_MODE=pve
SH_PVE_VMID=${PVE_VMID}
SH_QEMU_PIDFILE=/var/run/qemu-server/${PVE_VMID}.pid"
fi

# ---- tile.env (consumed by streamhost@<tile>.service) ----
# Optional lines: emitted only when the corresponding flag was passed, so the
# daemon defaults rule otherwise (matches the live fleet's tile.envs).
OPT_LINES=""
[ "$LEGACY_KBD_SET" = 1 ] && OPT_LINES="${OPT_LINES}
SH_LEGACY_KBD=${LEGACY_KBD}"
[ "$WARPD_ADDR_SET" = 1 ] && OPT_LINES="${OPT_LINES}
SH_WARPD_ADDR=${WARPD_ADDR}"
[ -n "$WARPD_BUTTONS" ] && OPT_LINES="${OPT_LINES}
SH_WARPD_BUTTONS=${WARPD_BUTTONS}"
[ -n "$WARPD_WHEEL" ] && OPT_LINES="${OPT_LINES}
SH_WARPD_WHEEL=${WARPD_WHEEL}"
[ -n "$WARPD_PACE_MS" ] && OPT_LINES="${OPT_LINES}
SH_WARPD_PACE_MS=${WARPD_PACE_MS}"
[ -n "$ABS_PACE_MS" ] && OPT_LINES="${OPT_LINES}
SH_ABS_PACE_MS=${ABS_PACE_MS}"
[ -n "$WARPD_BUTTON_DELAY_MS" ] && OPT_LINES="${OPT_LINES}
SH_WARPD_BUTTON_DELAY_MS=${WARPD_BUTTON_DELAY_MS}"
[ "$CURSOR_SET" = 1 ] && OPT_LINES="${OPT_LINES}
SH_CURSOR_SCALE=${CURSOR_SCALE}
SH_CURSOR_OFF_X=${CURSOR_OFF_X}
SH_CURSOR_OFF_Y=${CURSOR_OFF_Y}"
ENC_BLOCK=""
if [ "$ENC_SET" = 1 ]; then
  if [ -n "$CRF" ]; then
    CRF_LINE="SH_CRF=${CRF}"
  else
    CRF_LINE="# SH_CRF unset -> daemon default (CQP q10 at tier 0; see config.rs)"
  fi
  ENC_BLOCK="
# Higher-quality / lower-latency / ABR encoder defaults (SECTION 1 + 5b).
# SH_MAXRATE_KBPS=0 => daemon auto-picks the per-resolution cap (SECTION 1.3).
SH_PROFILE=${PROFILE:-high}
SH_TUNE=zerolatency
${CRF_LINE}
SH_MAXRATE_KBPS=${MAXRATE:-0}
SH_ABR=${ABR:-on}
# DWELL between tier changes (anti-oscillation). 25 s so the ABR controller can
# never ping-pong; downshift is network-driven (loss / RTT growth) only.
SH_ABR_MIN_RESTART_MS=25000
SH_ABR_FLOOR_HEIGHT=480"
fi
if [ -n "$INPUT_BACKEND" ]; then
  INPUT_CONFIG_LINE="SH_INPUT_BACKEND=${INPUT_BACKEND}"
else
  # Preserve byte-identical legacy fixtures unless their manifest opts into the
  # unified backend spelling. The daemon continues to parse SH_POINTER.
  INPUT_CONFIG_LINE="SH_POINTER=${POINTER}"
fi
cat >"${BASE_OUT}/tile.env" <<EOF
# streamhost per-tile config for '${TILE}'. Consumed by streamhost@${TILE}.service.
SH_TILE=${TILE}
SH_QMP=${QMP}${MODE_LINES}
SH_PORT=${UDP}
SH_FPS=${FPS}
SH_ENCODER_PRESET=${ENCODER_PRESET}
SH_BUFSIZE_RATIO=${BUFSIZE_RATIO:-0.5}
SH_HOST_IP=${HOST_IP}
SH_ADVERTISE_HOST=${ADVERTISE}
${INPUT_CONFIG_LINE}${OPT_LINES}
SH_AUDIO=${AUDIO}
SH_AUDIO_BITRATE=96000
SH_HASH_FILE=${BASE}/cert_hash_b64.txt
SH_SIGNALING_JSON=${BASE}/signaling.json
SH_CERT_ROTATE_DAYS=10${ENC_BLOCK}
# SH_LOCAL_HTTP=1${UDP:1}   # uncomment for a plain-HTTP signaling endpoint (A/B only)
EOF
# Verbatim golden-fixture / metadata stanza (tracked per tile in ../tiles/<tile>/
# tile.env.fixture) appended byte-for-byte — the SH_RESET_MODE/SH_GOLDEN_* lines
# ARE read by the daemon + labctl, the rest documents the curated fixture.
if [ -n "$ENV_APPEND_FILE" ]; then
  cat "$ENV_APPEND_FILE" >>"${BASE_OUT}/tile.env"
fi

# ---- qemu-streamhost.sh ----
pin_machine_file() { # $1 = launcher file to pin IN PLACE (verbatim mode)
  # pc/q35 aliases -> the versioned types they resolve to on pve-qemu 11.0.x.
  sed -E -i \
    -e 's/-machine pc,/-machine pc-i440fx-11.0,/g' \
    -e 's/-machine pc([[:space:]])/-machine pc-i440fx-11.0\1/g' \
    -e 's/-machine q35,/-machine pc-q35-11.0,/g' \
    -e 's/-machine q35([[:space:]])/-machine pc-q35-11.0\1/g' "$1"
  # launchers that pass no -machine ride QEMU's default (== pc-i440fx-11.0
  # today): make it explicit right after the first `-smp N`.
  if ! grep -q -- '-machine ' "$1"; then
    sed -E -i '0,/-smp [0-9]+/s//& -machine pc-i440fx-11.0/' "$1"
  fi
}

if [ "$QEMU_MODE" = "pve" ]; then
  # A scratch/out-root may have been used for another mode previously. Ensure
  # PVE mode can never leave a stale launcher that implies local ownership.
  rm -f -- "${BASE_OUT}/qemu-streamhost.sh"
elif [ -n "$LAUNCHER_FILE" ]; then
  # VERBATIM mode: the tracked per-tile launcher is the device-set ledger.
  [ -f "$LAUNCHER_FILE" ] || {
    echo "FATAL: --launcher-file $LAUNCHER_FILE missing" >&2
    exit 1
  }
  cp "$LAUNCHER_FILE" "${BASE_OUT}/qemu-streamhost.sh"
  [ "$PIN_MACHINE" = 1 ] && pin_machine_file "${BASE_OUT}/qemu-streamhost.sh"
  chmod +x "${BASE_OUT}/qemu-streamhost.sh"
else
  # GENERIC mode: generate the launcher from the flags.
  TOUCH="off"
  [ "$POINTER" = "touch" ] && {
    POINTER="abs"
    TOUCH="on"
  }
  # Input devices are guest-dependent: virtio-input for modern Linux/Haiku, but
  # NT-era guests (ReactOS/Win2000) have no virtio-input driver — they use a USB
  # HID tablet + the default PS/2 keyboard (which the dbus Keyboard inject targets).
  # Win9x/DOS/OS2 predate inbox USB-HID too AND run on -machine ...,usb=off, so they
  # use ONLY the default i8042 PS/2 keyboard + PS/2 mouse (relative). No device line
  # is emitted; the dbus display injects into the built-in PS/2 devices. The absolute
  # cursor offset is corrected client-side in the SPA (per-guest cursor calibration).
  if [ "$INPUT_DEV" = "ps2" ]; then
    INPUT='' # bare i8042: PS/2 keyboard + PS/2 mouse are always present on -machine pc
  elif [ "$INPUT_DEV" = "usb" ]; then
    INPUT='-usb'
    # usb-tablet for abs guests; ALSO for warpd guests so `loadvm golden` matches the
    # snapshot's device set (warpd drives the X pointer directly, but the tablet must
    # still be present for the snapshot to load).
    { [ "$POINTER" = "abs" ] || [ "$POINTER" = "warpd" ]; } && INPUT="$INPUT -device usb-tablet"
    [ "$POINTER" = "rel" ] && INPUT="$INPUT -device usb-mouse"
    # keyboard = default PS/2 i8042 (no device line needed)
  else
    INPUT='-device virtio-keyboard-pci'
    [ "$POINTER" = "abs" ] && INPUT="$INPUT -device virtio-tablet-pci"
    [ "$TOUCH" = "on" ] && INPUT="$INPUT -device virtio-multitouch-pci"
  fi
  # The dbus DISPLAY must reference the audiodev or the Audio object is not exported.
  DISPLAY_ARG="dbus,p2p=on"
  AUDIO_ARGS=""
  if [ "$AUDIO" = "on" ]; then
    DISPLAY_ARG="dbus,p2p=on,audiodev=snd0"
    # The codec must be one the GUEST has a driver for or it stays silent:
    #   hda  -> intel-hda + hda-output   (modern Linux, Haiku, ...)
    #   ac97 -> AC97                      (ReactOS / Win2000-era NT guests)
    #   sb16 -> Sound Blaster 16 (ISA)    (Win9x/DOS: the inbox-driver codec these
    #                                      guests actually ship — AC97/HDA stay silent
    #                                      on Win95 OSR2, which has NO inbox AC97 driver)
    if [ "$AUDIO_DEV" = "ac97" ]; then
      AUDIO_ARGS='-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device AC97,audiodev=snd0'
    elif [ "$AUDIO_DEV" = "sb16" ]; then
      AUDIO_ARGS='-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device sb16,audiodev=snd0'
    elif [ "$AUDIO_DEV" = "pcspk" ]; then
      # PC speaker only (real MS-DOS games like Commander Keen 1). No sound CARD is
      # added — the isa-pcspk device already exists on -machine pc; it is routed to
      # the dbus audiodev by appending pcspk-audiodev=snd0 to -machine (below). This
      # is a BACKEND-only change, so a `loadvm golden` fixture survives it (no rebake).
      AUDIO_ARGS='-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16'
      PCSPK=1
    else
      AUDIO_ARGS='-audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 -device intel-hda -device hda-output,audiodev=snd0'
    fi
  fi
  # Guest media: a virtio qcow2 (--disk), RAW media args (--disk-raw), and/or a
  # bootable LiveCD (--cdrom [+ --boot d]).
  DISK_ARG=""
  [ -n "$DISK" ] && DISK_ARG="-drive file=${DISK},if=virtio"
  [ -n "$DISK_RAW" ] && DISK_ARG=" ${DISK_RAW}"
  [ -n "$CDROM" ] && DISK_ARG="${DISK_ARG} -cdrom ${CDROM}"
  [ -n "$BOOT" ] && DISK_ARG="${DISK_ARG} -boot ${BOOT}"
  # Machine-type pinning (generic mode): resolve the alias before any suffixes.
  if [ "$PIN_MACHINE" = 1 ]; then
    case "$MACHINE" in
      "" | pc) MACHINE="pc-i440fx-11.0" ;;
      pc,*) MACHINE="pc-i440fx-11.0,${MACHINE#pc,}" ;;
      q35) MACHINE="pc-q35-11.0" ;;
      q35,*) MACHINE="pc-q35-11.0,${MACHINE#q35,}" ;;
    esac
  fi
  # PC-speaker audio (--audio-dev pcspk) routes the isa-pcspk device to the dbus
  # audiodev via a -machine property; force a -machine (default pc) so it can attach.
  if [ "${PCSPK:-0}" = "1" ]; then
    [ -z "$MACHINE" ] && MACHINE="pc"
    MACHINE="${MACHINE},pcspk-audiodev=snd0"
  fi
  MACHINE_ARG=""
  [ -n "$MACHINE" ] && MACHINE_ARG="-machine ${MACHINE}"
  CPU_ARG=""
  [ -n "$CPU" ] && CPU_ARG="-cpu ${CPU}"
  # VGA: `none` omits the built-in card so --extra can supply an EDID-configured one.
  VGA_ARG=""
  [ "$VGA" != "none" ] && VGA_ARG="-vga ${VGA}"
  # Accelerator arg: -enable-kvm for KVM guests, `-accel tcg` for the TCG-only ones
  # (OS/2 Warp 4 refuses to boot under KVM).
  ACCEL_ARG="-enable-kvm"
  [ "$ACCEL" = "tcg" ] && ACCEL_ARG="-accel tcg"

  cat >"${BASE_OUT}/qemu-streamhost.sh" <<EOF
#!/bin/bash
# Launch tile '${TILE}' (VMID ${VMID}) QEMU with the streamhost display wiring.
# Kill only by pidfile. Stop/restore procedure for this one tile: ROLLBACK.md.
set -e
[ -f "${PID}" ] && kill "\$(cat "${PID}")" 2>/dev/null || true
sleep 0.3; rm -f "${QMP}" "${PID}"
# streamhost QEMU display-capture fast-poll (pve-qemu 0047 patch): dbus display
# polls every SH_DBUS_UPDATE_MS ms (default 4; clamp 1..29; 0/unset = stock 30 ms).
# Overridable per-tile by exporting SH_DBUS_UPDATE_MS before this launcher runs.
export SH_DBUS_UPDATE_MS="\${SH_DBUS_UPDATE_MS:-4}"
EOF
  # --loadvm-launch: emit the conditional golden-restore block. The \$LOADVM arg
  # splices into the qemu line via ${LOADVM_VAR} below, which stays EMPTY (and
  # byte-identical output) for tiles without the flag — verify-emit parity.
  LOADVM_VAR=""
  if [ -n "$LOADVM_LAUNCH_DISK" ]; then
    # shellcheck disable=SC2016 # literal on purpose: $LOADVM expands in the EMITTED launcher, not here
    LOADVM_VAR=' $LOADVM'
    cat >>"${BASE_OUT}/qemu-streamhost.sh" <<EOF
# Boot straight into the golden fixture when the snapshot exists; -S starts it
# FROZEN (~0 CPU) — the first visitor session's cont (idle.rs) wakes it
# sub-second. A first-ever bake (no snapshot yet) cold-boots RUNNING for the
# golden bake to drive. shellcheck disable=SC2086: \$LOADVM must word-split.
LOADVM=""
qemu-img snapshot -l "${LOADVM_LAUNCH_DISK}" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
EOF
  fi
  cat >>"${BASE_OUT}/qemu-streamhost.sh" <<EOF
nohup qemu-system-x86_64 \\
  -name streamhost-${TILE} \\
  ${ACCEL_ARG} -m ${MEM} -smp ${SMP} \\
  ${MACHINE_ARG} ${CPU_ARG} \\
  -rtc base=localtime \\
  ${DISK_ARG} \\
  ${VGA_ARG} \\
  -display ${DISPLAY_ARG} \\
  ${AUDIO_ARGS} \\
  ${INPUT} \\
  ${EXTRA}${LOADVM_VAR} \\
  -qmp unix:${QMP},server=on,wait=off \\
  -pidfile ${PID} \\
  >"${BASE}/qemu.log" 2>&1 &
for i in \$(seq 1 40); do [ -S "${QMP}" ] && [ -f "${PID}" ] && break; sleep 0.5; done
echo "tile ${TILE} qemu pid=\$(cat ${PID} 2>/dev/null) qmp=${QMP} udp=${UDP}"
EOF
  chmod +x "${BASE_OUT}/qemu-streamhost.sh"
fi

# ---- aux helper files the launcher needs at runtime (e.g. msdoswin1's qmpc.py) ----
for aux in ${AUX_FILES[@]+"${AUX_FILES[@]}"}; do
  [ -f "$aux" ] || {
    echo "FATAL: --aux-file $aux missing" >&2
    exit 1
  }
  cp "$aux" "${BASE_OUT}/$(basename "$aux")"
done

# ---- ROLLBACK.md (per-tile stop/restore, no effect on the other tiles) ----
if [ "$QEMU_MODE" = "pve" ]; then
  cat >"${BASE_OUT}/ROLLBACK.md" <<EOF
# Tile ${TILE} — PVE-owned lifecycle / golden restore

PVE VM ${PVE_VMID} owns the QEMU process. Stopping or restarting
streamhost@${TILE} does not stop the guest.

## Restore the golden RAM snapshot
1. qm rollback ${PVE_VMID} golden
2. systemctl restart streamhost@${TILE}.service

The service restart waits for ${QMP} and re-attaches streamhost to the QMP
socket recreated by PVE. Create the golden once with:

    qm snapshot ${PVE_VMID} golden --vmstate 1
EOF
else
  cat >"${BASE_OUT}/ROLLBACK.md" <<EOF
# Tile ${TILE} — stop / restore (streamhost is the only stack)

Everything here affects ONLY this tile. The SPA binding stays on the
'streamhost' transport (spa/src/three/archetypeRegistry.ts) throughout.

## Stop this tile
1. systemctl stop streamhost@${TILE}
2. kill \$(cat ${PID}) 2>/dev/null || true     # stop this tile's QEMU (ONLY by pidfile)

## Restore this tile
1. bash ${BASE}/qemu-streamhost.sh            # QEMU with dbus display + audio + input
2. systemctl start streamhost@${TILE}          # attaches to ${QMP}, serves udp/${UDP}
   (cert + signaling.json republished at ${BASE}/signaling.json)

Historical: this file used to document the per-tile neko<->streamhost pilot
cutover; the gallery is fully on streamhost and the neko stack is gone
(2026-07 restructure), so there is no container to fall back to.
EOF
fi

if [ "$QEMU_MODE" = "pve" ]; then
  echo "emitted: ${BASE_OUT}/{tile.env,ROLLBACK.md}  mode=pve transport=${TRANSPORT}"
else
  echo "emitted: ${BASE_OUT}/{tile.env,qemu-streamhost.sh,ROLLBACK.md}  mode=${QEMU_MODE} transport=${TRANSPORT}"
fi

if [ "$INSTALL" = "1" ]; then
  HERE="$(cd "$(dirname "$0")/.." && pwd)"
  cp "${HERE}/deploy/streamhost@.service" /etc/systemd/system/streamhost@.service
  systemctl daemon-reload
  echo "installed streamhost@.service (NOT started — systemctl start streamhost@<tile> / bring-up-all.sh)"
fi

echo "--- stop/restore for ${TILE}: see ${BASE}/ROLLBACK.md ---"
