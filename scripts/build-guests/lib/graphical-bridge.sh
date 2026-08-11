#!/usr/bin/env bash
# Build a heavy graphical-emulator bridge as a thin, isolated overlay.
#
# This is deliberately a scratch-first template. It never writes below the
# production station tree and never changes the frozen shared bridge base. Future
# OS workers fork the generated station.env/qemu-streamhost.sh after framebuffer,
# audio, and checkpoint validation.
#
# Usage:
#   graphical-bridge.sh --tile NAME --vmid 99NNN --udp PORT --ssh-port PORT \
#     --install-script GUEST_INSTALL.sh --launch-script KIOSK_LAUNCH.sh \
#     [--payload-dir DIR] [--out-dir /data/vms/soltest/NAME] [--force]
set -euo pipefail

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard

TILE=""
VMID=""
UDP_PORT=""
SSH_PORT=""
WEB_PORT=""
OUT_DIR=""
INSTALL_SCRIPT=""
LAUNCH_SCRIPT=""
PAYLOAD_DIR=""
MEM_MB=4096
SMP=4
SCOPE_MEMORY_MAX=6G
FPS=60
FORCE=0
NO_BOOT=0

usage() {
  sed -n '2,13p' "$0"
}

die() {
  echo "graphical-bridge: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
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
      UDP_PORT="$2"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="$2"
      shift 2
      ;;
    --web-port)
      WEB_PORT="$2"
      shift 2
      ;;
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --install-script)
      INSTALL_SCRIPT="$2"
      shift 2
      ;;
    --launch-script)
      LAUNCH_SCRIPT="$2"
      shift 2
      ;;
    --payload-dir)
      PAYLOAD_DIR="$2"
      shift 2
      ;;
    --mem)
      MEM_MB="$2"
      shift 2
      ;;
    --smp)
      SMP="$2"
      shift 2
      ;;
    --scope-memory-max)
      SCOPE_MEMORY_MAX="$2"
      shift 2
      ;;
    --fps)
      FPS="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-boot)
      NO_BOOT=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$TILE" ] || die "--tile is required"
case "$TILE" in
  *[!a-z0-9-]*) die "tile must contain only lowercase letters, digits, and hyphens" ;;
esac
[ -n "$VMID" ] || die "--vmid is required"
[ -n "$UDP_PORT" ] || die "--udp is required"
[ -n "$SSH_PORT" ] || die "--ssh-port is required"
[ -n "$INSTALL_SCRIPT" ] || die "--install-script is required"
[ -n "$LAUNCH_SCRIPT" ] || die "--launch-script is required"
[ -f "$INSTALL_SCRIPT" ] || die "install script not found: $INSTALL_SCRIPT"
[ -f "$LAUNCH_SCRIPT" ] || die "launch script not found: $LAUNCH_SCRIPT"
[ -z "$PAYLOAD_DIR" ] || [ -d "$PAYLOAD_DIR" ] || die "payload directory not found: $PAYLOAD_DIR"

OUT_DIR="${OUT_DIR:-/data/vms/soltest/$TILE}"
WEB_PORT="${WEB_PORT:-$((UDP_PORT - 46000))}"
for value in "$VMID" "$UDP_PORT" "$SSH_PORT" "$WEB_PORT" "$MEM_MB" "$SMP" "$FPS"; do
  case "$value" in
    '' | *[!0-9]*) die "numeric option has invalid value: $value" ;;
  esac
done
case "$SCOPE_MEMORY_MAX" in
  *[!0-9GM]*) die "invalid --scope-memory-max: $SCOPE_MEMORY_MAX" ;;
esac

clone_guard_assert_clone_path "$OUT_DIR" "graphical bridge output"
clone_guard_assert_clone_vmid "$VMID"

# This library has no single station id, so the base follows the LEDGER DEFAULT
# suite (registry/bridge-suites.json). A caller whose station is on another suite
# must pass BRIDGE_BASE= itself, matched to the emulator build it stages.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bridge-suite.sh"
BRIDGE_SUITE_ID="$(bridge_suite_default)"
BRIDGE_BASE="${BRIDGE_BASE:-$(bridge_base_for "$BRIDGE_SUITE_ID")}"
KEY=/data/vms/bridge/bridge_key
OVERLAY="$OUT_DIR/overlay.qcow2"
QMP="$OUT_DIR/qmp.sock"
PIDFILE="$OUT_DIR/qemu.pid"
[ -r "$BRIDGE_BASE" ] || die "no $BRIDGE_SUITE_ID bridge base: $BRIDGE_BASE (bridge-base.sh --suite $BRIDGE_SUITE_ID)"
[ -r "$KEY" ] || die "missing bridge SSH key: $KEY"

mkdir -p "$OUT_DIR"
clone_guard_kill_pidfile "$PIDFILE"
rm -f "$QMP"
if [ "$FORCE" -eq 1 ]; then
  rm -f "$OVERLAY"
fi
if [ ! -f "$OVERLAY" ]; then
  qemu-img create -f qcow2 -b "$BRIDGE_BASE" -F qcow2 "$OVERLAY" >/dev/null
fi

cat >"$OUT_DIR/qemu-streamhost.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
BASE=$OUT_DIR
OVERLAY="\$BASE/overlay.qcow2"
PIDFILE="\$BASE/qemu.pid"
QMP="\$BASE/qmp.sock"
clone_guard_assert_clone_path "\$BASE" "graphical bridge clone"
clone_guard_assert_clone_vmid $VMID
clone_guard_kill_pidfile "\$PIDFILE"
rm -f "\$QMP"
LOADVM=()
qemu-img snapshot -l "\$OVERLAY" 2>/dev/null | grep -qw golden && LOADVM=(-loadvm golden)
export SH_DBUS_UPDATE_MS="\${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-$TILE-vmid-$VMID \
  -enable-kvm -m $MEM_MB -smp $SMP -machine pc-i440fx-11.0 -cpu host \
  -rtc base=localtime \
  -drive file="\$OVERLAY",if=ide,format=qcow2 -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device AC97,audiodev=snd0 \
  -usb -device usb-tablet \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22 \
  -device e1000,netdev=n0 \
  "\${LOADVM[@]}" \
  -qmp unix:"\$QMP",server=on,wait=off -pidfile "\$PIDFILE" \
  >"\$BASE/qemu.log" 2>&1 &
for _ in \$(seq 1 60); do
  [ -S "\$QMP" ] && [ -f "\$PIDFILE" ] && exit 0
  sleep 0.5
done
echo "QMP/pidfile did not appear for $TILE" >&2
exit 1
EOF
chmod +x "$OUT_DIR/qemu-streamhost.sh"

cat >"$OUT_DIR/launch-scoped.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone_guard_assert_clone_path "$OUT_DIR" "graphical bridge clone"
exec systemd-run --scope --unit "qcap-$TILE-\$(date +%s)" \
  -p MemoryMax=$SCOPE_MEMORY_MAX bash "$OUT_DIR/qemu-streamhost.sh"
EOF
chmod +x "$OUT_DIR/launch-scoped.sh"

cat >"$OUT_DIR/station.env" <<EOF
# Scratch graphical-bridge contract. This is not a registry/production station.
SH_STATION=$TILE
SH_QMP=$QMP
SH_PORT=$UDP_PORT
SH_FPS=$FPS
SH_ENCODER_PRESET=ultrafast
SH_HOST_IP=192.0.2.10
SH_ADVERTISE_HOST=192.0.2.10
SH_POINTER=abs
SH_CURSOR_SCALE=1.0
SH_CURSOR_OFF_X=0
SH_CURSOR_OFF_Y=0
SH_ABS_PACE_MS=0
SH_AUDIO=on
SH_AUDIO_BITRATE=96000
SH_HASH_FILE=$OUT_DIR/cert_hash_b64.txt
SH_SIGNALING_JSON=$OUT_DIR/signaling.json
SH_CERT_ROTATE_DAYS=10
SH_RESET_MODE=loadvm
SH_GOLDEN_SNAPSHOT=golden
SH_IDLE_PAUSE_SECS=0
SH_QEMU_RSS_GUARD_MB=4096
EOF

cat >"$OUT_DIR/BUILD-INFO.txt" <<EOF
tile=$TILE
vmid=$VMID
udp=$UDP_PORT
ssh_port=$SSH_PORT
web_port=$WEB_PORT
memory_mb=$MEM_MB
smp=$SMP
scope_memory_max=$SCOPE_MEMORY_MAX
overlay=$OVERLAY
backing=$BRIDGE_BASE
pointer=dbus-abs/usb-tablet
EOF

if [ "$NO_BOOT" -eq 1 ]; then
  echo "emitted scratch template: $OUT_DIR"
  exit 0
fi

if qemu-img snapshot -l "$OVERLAY" 2>/dev/null | grep -qw golden; then
  "$OUT_DIR/qemu-streamhost.sh"
  echo "golden snapshot exists; booted it without modifying the overlay: $OUT_DIR"
  exit 0
fi

"$OUT_DIR/qemu-streamhost.sh"
for _ in $(seq 1 80); do
  if ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -p "$SSH_PORT" \
    root@127.0.0.1 true 2>/dev/null; then
    break
  fi
  sleep 3
done

guest() {
  ssh -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p "$SSH_PORT" \
    root@127.0.0.1 "$@"
}
guest true || die "guest SSH did not become ready on port $SSH_PORT"

if [ -n "$PAYLOAD_DIR" ]; then
  tar -C "$PAYLOAD_DIR" -cf - . | guest \
    "install -d -m 0755 /tmp/graphical-bridge-payload; tar -C /tmp/graphical-bridge-payload -xf -"
fi
guest "GB_PAYLOAD_DIR=/tmp/graphical-bridge-payload bash -s" <"$INSTALL_SCRIPT"
guest "install -m 0755 /dev/stdin /etc/bridge/launch.sh" <"$LAUNCH_SCRIPT"
guest "systemctl reset-failed getty@tty1; systemctl restart getty@tty1"

echo "graphical bridge ready for framebuffer/audio/golden validation: $OUT_DIR"
echo "scope launcher: $OUT_DIR/launch-scoped.sh (MemoryMax=$SCOPE_MEMORY_MAX)"
