#!/usr/bin/env bash
# Build the Amstrad CPC 6128 + Locomotive BASIC streamhost station as a thin
# overlay on the frozen bridge base. The proof artifacts are real QEMU
# framebuffer dumps; no disk/log state is accepted as visual evidence.
#
# Usage: amstradcpc.sh [--force]
set -euo pipefail

TILE=amstradcpc
VMID=219
UDP=54119
SSH_PORT=5819
WEB_PORT=8119
BRIDGE_BASE="${BRIDGE_BASE:-$("$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-base-for" "$TILE")}" # suite: registry/bridge-suites.json
KEY=/data/vms/bridge/bridge_key
TILE_DIR=/data/vms/streamhost/stations/amstradcpc
OVERLAY="$TILE_DIR/overlay.qcow2"
QMP="$TILE_DIR/qmp.sock"
PID="$TILE_DIR/qemu.pid"
EVIDENCE="$TILE_DIR/evidence"
MEM=1536

FORCE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h | --help)
      sed -n '2,28p' "$0"
      exit 0
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

log() { echo "[amstradcpc $(date +%H:%M:%S)] $*"; }
die() {
  echo "[amstradcpc] ERROR: $*" >&2
  exit 1
}
guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "$@"
}
hmp() { python3 /root/qmp_hmp.py "$QMP" "$1"; }

# cap32 has no --fullscreen option. Its verified scale-3 SDL/X11 window captures
# in colour on the black 1024x768 root; SDL real-fullscreen is deliberately not
# used because the sibling bridge emulators render black in std-VGA capture.
read -r -d '' LAUNCH <<'EOS' || true
#!/bin/bash
# Amstrad CPC 6128 + Locomotive BASIC kiosk launcher.
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
export LIBGL_ALWAYS_SOFTWARE=1
exec cap32 -O video.scr_green_mode=0 -O video.scr_scale=3
EOS

stop_qemu() {
  if [ -S "$QMP" ]; then
    hmp quit >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
      [ ! -S "$QMP" ] && break
      sleep 0.25
    done
  fi
  if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    die "QEMU still owns $PID; refusing to kill it (stop only this tile safely)"
  fi
  rm -f "$QMP" "$PID"
}

boot_tile() {
  stop_qemu
  local loadvm=()
  if qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
    loadvm=(-loadvm golden)
  fi
  nohup qemu-system-x86_64 \
    -name streamhost-amstradcpc \
    -enable-kvm -machine pc-i440fx-11.0,vmport=off \
    -m "$MEM" -smp 2 -cpu host \
    -rtc base=localtime \
    -drive file="$OVERLAY",if=ide,format=qcow2 -boot c \
    -vga std \
    -display dbus,p2p=on,audiodev=snd0 \
    -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
    -device AC97,audiodev=snd0 \
    -usb \
    -netdev user,id=n0,hostfwd=tcp:127.0.0.1:"$SSH_PORT"-:22 \
    -device e1000,netdev=n0 \
    "${loadvm[@]}" \
    -qmp unix:"$QMP",server=on,wait=off \
    -pidfile "$PID" \
    >"$TILE_DIR/qemu.log" 2>&1 &
  for _ in $(seq 1 40); do
    [ -S "$QMP" ] && [ -f "$PID" ] && break
    sleep 0.5
  done
  [ -S "$QMP" ] && [ -f "$PID" ] || die "QEMU did not create its QMP socket/pidfile"
  log "QEMU started (loadvm='${loadvm[*]:-<none: cold boot>}')"
}

capture() {
  local name=$1
  local ppm="$EVIDENCE/$name.ppm"
  hmp "screendump $ppm" >/dev/null
  pnmtopng "$ppm" >"$EVIDENCE/$name.png"
  log "framebuffer proof: $EVIDENCE/$name.png"
}

yellow_count() {
  ppmhist "$1" |
    awk '$1 == 255 && $2 == 255 && $3 == 0 { print $5 }'
}

frame_is_cpc_colour() {
  ppmhist "$1" |
    awk '
      $1 == 0 && $2 == 0 && $3 == 127 { blue = $5 }
      $1 == 255 && $2 == 255 && $3 == 0 { yellow = $5 }
      END { exit !(blue > 700000 && yellow > 10000) }
    '
}

wait_for_cpc() {
  local name=$1
  for _ in $(seq 1 40); do
    capture "$name"
    if frame_is_cpc_colour "$EVIDENCE/$name.ppm"; then
      return
    fi
    sleep 2
  done
  die "no yellow-on-blue CPC framebuffer after 80 seconds"
}

# This mirrors the browser/streamhost path: explicit key down/up events. QMP
# send-key's overlapping timed releases drop CPC keystrokes at typing speed.
keyboard_proof() {
  local base_yellow proof_yellow
  base_yellow=$(yellow_count "$EVIDENCE/ready-before-golden.ppm")
  {
    printf '%s\n' '{"execute":"qmp_capabilities"}'
    sleep 0.2
    local token modifier key
    for token in \
      shift+p shift+r shift+i shift+n shift+t spc \
      shift+apostrophe shift+h shift+e shift+l shift+l shift+o \
      shift+apostrophe ret shift+r shift+u shift+n ret; do
      if [[ "$token" == *+* ]]; then
        modifier=${token%%+*}
        key=${token#*+}
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$modifier"
        sleep 0.05
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$key"
        sleep 0.08
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$key"
        sleep 0.05
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$modifier"
      else
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":true,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$token"
        sleep 0.10
        printf '{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":false,"key":{"type":"qcode","data":"%s"}}}]}}\n' "$token"
      fi
      sleep 0.10
    done
  } | socat - UNIX-CONNECT:"$QMP" >"$EVIDENCE/keyboard-qmp.jsonl"
  sleep 2
  capture keyboard-print-run
  proof_yellow=$(yellow_count "$EVIDENCE/keyboard-print-run.ppm")
  [ "$proof_yellow" -gt $((base_yellow + 3000)) ] ||
    die "keyboard proof did not add the expected framebuffer text"
}

[ -f "$BRIDGE_BASE" ] || die "missing bridge base $BRIDGE_BASE (build it: lib/bridge-base.sh --suite <registry/bridge-suites.json>)"
[ -f "$KEY" ] || die "missing bridge SSH key: $KEY"
if systemctl is-active --quiet "streamhost@$TILE"; then
  die "streamhost@$TILE is active; stop only this new tile before rebuilding"
fi
mkdir -p "$TILE_DIR" "$EVIDENCE"

if [ -f "$OVERLAY" ] && [ "$FORCE" -eq 1 ]; then
  log "--force requested; stopping only $TILE before replacing its overlay"
  stop_qemu
  rm -f "$OVERLAY"
fi
if [ ! -f "$OVERLAY" ]; then
  log "creating thin overlay on the frozen bridge base"
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

if ! qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  boot_tile
  log "waiting for bridge SSH"
  ssh_ready=0
  for _ in $(seq 1 40); do
    if guest true 2>/dev/null; then
      ssh_ready=1
      break
    fi
    sleep 3
  done
  [ "$ssh_ready" -eq 1 ] || die "bridge SSH did not become ready"
  guest "test -x /usr/local/bin/cap32 &&
    test -f /usr/local/share/caprice32/rom/cpc6128.rom &&
    grep -Eq '^[[:space:]]*model[[:space:]]*=[[:space:]]*2' /etc/cap32.cfg" ||
    die "cap32, CPC 6128 ROM, or model=2 config missing from bridge base"
  printf '%s\n' "$LAUNCH" |
    guest "cat > /etc/bridge/launch.sh && chmod 755 /etc/bridge/launch.sh &&
      chown root:root /etc/bridge/launch.sh"
  guest "pkill -u bridge cap32 2>/dev/null || true
    sleep 1
    systemctl reset-failed getty@tty1
    systemctl restart getty@tty1"
  wait_for_cpc ready-before-golden
  # Disk checkpoint before savevm golden below; see lib/bridge-coldboot. Unlike
  # the VICE siblings, this station has no pre-bake rehearsal boot to plug into
  # (it bakes straight off the live provisioning VM), so one is added here.
  stop_qemu
  "$(dirname "${BASH_SOURCE[0]}")/../lib/bridge-coldboot" snapshot "$OVERLAY" --allow-tile
  boot_tile
  sleep 3
  wait_for_cpc coldboot-rehearsal
  hmp "savevm golden" >"$EVIDENCE/savevm-golden.txt"
  hmp "info snapshots" >"$EVIDENCE/info-snapshots.txt"
  grep -qw golden "$EVIDENCE/info-snapshots.txt" ||
    die "savevm golden did not create an internal snapshot"
  keyboard_proof
fi

# A real cold QEMU restart, not an in-process loadvm, proves launcher/device-set
# parity and the conditional -loadvm golden path.
stop_qemu
boot_tile
sleep 3
wait_for_cpc golden-cold-loadvm
hmp "info snapshots" >"$EVIDENCE/cold-info-snapshots.txt"
grep -qw golden "$EVIDENCE/cold-info-snapshots.txt" ||
  die "cold -loadvm boot cannot see the golden snapshot"

log "PASS: CPC colour Ready, keyboard PRINT/RETURN/RUN, and cold golden restore"
log "tile=$TILE vmid=$VMID udp=$UDP ssh=$SSH_PORT web=$WEB_PORT evidence=$EVIDENCE"
