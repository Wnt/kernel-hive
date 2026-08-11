#!/bin/bash
# ensure-station-qemu.sh <tile> — idempotent systemd ExecStartPre for streamhost@.
# A daemon-only restart must not restart its guest. If the pidfile-owned QEMU
# and QMP socket are both live, this is a no-op; otherwise the emitted launcher
# owns cleanup/startup and continues to enforce pidfile-only termination.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 <tile>" >&2
  exit 2
}
TILE="$1"
case "$TILE" in
  *[!a-zA-Z0-9_-]* | '')
    echo "invalid tile name: $TILE" >&2
    exit 2
    ;;
esac

# x11 tiles (SH_CAPTURE=x11, IRIX/issue #20) have no QEMU/QMP: hand off to the
# Xvfb+emulator lifecycle helper. Keyed on the SH_STATION_RUNTIME marker the
# EnvironmentFile provides, so the QEMU fleet is untouched.
if [ "${SH_STATION_RUNTIME:-}" = "x11" ]; then
  exec "$(dirname "$0")/ensure-station-x11.sh" "$TILE"
fi

BASE="/data/vms/streamhost/stations/$TILE"
PIDFILE="$BASE/qemu.pid"
QMP="$BASE/qmp.sock"
LAUNCHER="$BASE/qemu-streamhost.sh"

if [ "${SH_QEMU_MODE:-}" = "pve" ]; then
  case "${SH_PVE_VMID:-}" in
    '' | *[!0-9]*)
      echo "invalid or missing SH_PVE_VMID for PVE tile $TILE" >&2
      exit 1
      ;;
  esac
  # streamhost's idle policy may QMP-pause an otherwise live VM. PVE reports
  # that as `paused`; it must not be passed to `qm start` or treated as dead.
  case "$(qm status "$SH_PVE_VMID")" in
    'status: running' | 'status: paused') ;;
    *) qm start "$SH_PVE_VMID" ;;
  esac
  for _ in $(seq 1 60); do
    [ -S "$QMP" ] && exit 0
    sleep 0.5
  done
  echo "PVE tile $TILE VM $SH_PVE_VMID is running but QMP did not appear at $QMP" >&2
  exit 1
fi

if [ -f "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  case "$PID" in
    '' | *[!0-9]*) ;;
    *)
      if kill -0 "$PID" 2>/dev/null && [ -S "$QMP" ]; then
        exit 0
      fi
      ;;
  esac
fi

[ -x "$LAUNCHER" ] || {
  echo "missing launcher: $LAUNCHER" >&2
  exit 1
}
case "$TILE" in
  c64 | atarist | apple2 | amiga)
    # Bridge kiosks keep their QEMU in a transient 3 GiB qcap scope after the
    # emitted launcher exits.
    #
    # BindsTo= ties that scope's lifetime to this service. Without it the scope
    # is a cgroup systemd will never associate with the unit, so `systemctl stop`
    # can only reach what ExecStop happens to find by pidfile — the same defect
    # that left an orphaned IRIX watchdog running after a stop. See the long note
    # in ensure-station-x11.sh (including why this must NOT be After=).
    exec systemd-run --scope --unit "qcap-${TILE}-$(date +%s)" \
      -p "BindsTo=streamhost@${TILE}.service" \
      -p MemoryMax=3G bash "$LAUNCHER"
    ;;
  *)
    exec bash "$LAUNCHER"
    ;;
esac
