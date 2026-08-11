#!/usr/bin/env bash
#
# vm-idle-watch.sh — idle auto-pause for bridge-fronted Proxmox VMs.
# ---------------------------------------------------------------------------
# The streamhost stations pause their own guests (QMP stop) when no WebTransport
# session is connected (streamhost/docs/IDLE-PAUSE.md). VMs that are NOT
# streamhost stations but are exposed through TCP bridges need the same treatment
# from the outside. This watcher polls the configured bridge ports for
# ESTABLISHED client connections and drives `qm suspend` / `qm resume`:
#
#   * viewers present  -> `qm resume <vmid>` immediately (if paused). QEMU's
#     VNC server answers on a paused VM, so the visitor's session connects to a
#     frozen frame and comes alive within one poll (<= POLL_SECS, default 2 s).
#   * zero viewers for GRACE seconds -> `qm suspend <vmid>` (pause, NOT
#     --todisk: vCPUs freeze, RAM/state kept, resume is sub-second).
#
# Suspend/resume are keyed off `qm status --verbose` qmpstatus, so an external
# resume (admin console work) simply re-arms the idle clock — the watcher
# re-suspends GRACE seconds after the last bridge viewer leaves. NOTE: only
# the listed bridge ports count as "viewers"; a Proxmox-web-console session
# does NOT keep the VM awake — `qm resume <vmid>` by hand (or just wait for a
# bridge viewer) if you are driving the VM outside the gallery.
#
# Run ON the Proxmox host, e.g. as a transient unit:
#   systemd-run --unit=vm-idle-watch-940 \
#     /data/vms/streamhost/serve/vm-idle-watch.sh 940 60 8120,8121
#
# Usage: vm-idle-watch.sh <vmid> <grace_secs> <port>[,<port>...]
set -euo pipefail

VMID="${1:?usage: vm-idle-watch.sh <vmid> <grace_secs> <port>[,<port>...]}"
GRACE="${2:?grace seconds (e.g. 60)}"
PORTS="${3:?comma-separated bridge listen ports (e.g. 8120,8121)}"
POLL_SECS="${POLL_SECS:-2}"

msg() { echo "[vm-idle-watch:${VMID}] $(date -Is) $*"; }

# ss filter, for example: "( sport = :8120 or sport = :8121 )"
FILTER="("
first=1
for p in ${PORTS//,/ }; do
  [ "$first" = 1 ] || FILTER+=" or"
  FILTER+=" sport = :${p}"
  first=0
done
FILTER+=" )"

viewer_count() {
  # ESTABLISHED TCP connections TO the bridge ports (the LISTEN row never
  # matches state established). No viewers -> 0.
  ss -Htn state established "$FILTER" 2>/dev/null | wc -l
}

qmp_state() {
  # "running" | "paused" | "" (VM absent/stopped — leave it alone entirely)
  qm status "$VMID" --verbose 2>/dev/null | awk '/^qmpstatus:/ {print $2}'
}

msg "watching ports ${PORTS} for VM ${VMID}: suspend after ${GRACE}s idle, resume on viewer (poll ${POLL_SECS}s)"
last_active=$(date +%s)
while true; do
  n=$(viewer_count)
  st=$(qmp_state)
  now=$(date +%s)
  if [ "$n" -gt 0 ]; then
    last_active=$now
    if [ "$st" = "paused" ]; then
      msg "viewer connected (${n}) -> qm resume ${VMID}"
      qm resume "$VMID" || msg "WARN: qm resume failed"
    fi
  elif [ "$st" = "running" ] && [ $((now - last_active)) -ge "$GRACE" ]; then
    msg "no viewers for ${GRACE}s -> qm suspend ${VMID} (pause; RAM kept, resume on next viewer)"
    qm suspend "$VMID" || msg "WARN: qm suspend failed"
  fi
  sleep "$POLL_SECS"
done
