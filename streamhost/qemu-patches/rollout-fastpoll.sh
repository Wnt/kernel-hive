#!/bin/bash
# Roll ONE tile onto the patched pve-qemu (SH_DBUS_UPDATE_MS=4).
# Usage: rollout.sh <tile>
set -u
T="$1"
D="/data/vms/streamhost/stations/$T"
L="$D/qemu-streamhost.sh"
PID="$D/qemu.pid"
QMP="$D/qmp.sock"
QEMU_BIN="${QEMU_BIN:-$(command -v qemu-system-x86_64)}"
strings "$QEMU_BIN" | grep -Fxq SH_DBUS_UPDATE_MS || {
  echo "installed qemu lacks SH_DBUS_UPDATE_MS: $QEMU_BIN"
  exit 3
}
PATCHED_SHA256="$(sha256sum "$QEMU_BIN" | cut -d" " -f1)"
[ -f "$L" ] || {
  echo "[$T] NO LAUNCHER"
  exit 3
}

# 1. idempotent knob injection (production: SH_DBUS_UPDATE_MS only, no trace)
if ! grep -q "SH_DBUS_UPDATE_MS" "$L"; then
  cp "$L" "$L.pre-fastpoll.bak"
  python3 - "$L" <<PY
import sys
p=sys.argv[1]; s=open(p).read()
a="nohup qemu-system-x86_64 \\\\\n"
ins=("# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.\n"
     "export SH_DBUS_UPDATE_MS=\"\${SH_DBUS_UPDATE_MS:-4}\"\n")
assert a in s, "anchor missing"
open(p,"w").write(s.replace(a, ins+a, 1))
PY
  echo "[$T] knob injected"
else
  echo "[$T] knob already present"
fi

# detect bridge (qcap scope) membership from current process
SCOPE=""
if [ -f "$PID" ]; then
  cp=$(cat "/proc/$(cat "$PID")/cgroup" 2>/dev/null)
  case "$cp" in *qcap-*) SCOPE="yes" ;; esac
fi

# 2. stop daemon
systemctl stop "streamhost@$T"

# 3. relaunch qemu (bridge under 3G scope)
if [ -n "$SCOPE" ]; then
  systemd-run --scope --slice=system.slice --unit="qcap-$T-$(date +%s)" -p MemoryMax=3G bash "$L" >/dev/null 2>&1
else
  bash "$L" >/dev/null 2>&1
fi

# 4. wait for qmp + verify patched exe
ok=""
for i in $(seq 1 60); do
  [ -S "$QMP" ] && [ -f "$PID" ] && ok=1 && break
  sleep 0.5
done
if [ -z "$ok" ]; then
  echo "[$T] FAIL: qemu did not come up"
  exit 1
fi
NP=$(cat "$PID")
EXE_SHA256=$(sha256sum "/proc/$NP/exe" 2>/dev/null | cut -d" " -f1)
[ "$EXE_SHA256" = "$PATCHED_SHA256" ] || {
  echo "[$T] FAIL: exe sha256 $EXE_SHA256 != installed patched $PATCHED_SHA256"
  exit 1
}

# 5. loadvm golden if a golden snapshot exists (restore + prove golden-health)
GV=$({
  printf "%s\n%s\n" "{\"execute\":\"qmp_capabilities\"}" "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"loadvm golden\"}}"
  sleep 6
} | timeout 15 socat - "UNIX-CONNECT:$QMP" 2>/dev/null)
if printf "%s" "$GV" | grep -qE "Error|does not exist|not found|no such|Device .golden"; then GOLDEN="no-golden(cold-boot)"; elif printf "%s" "$GV" | grep -q "\"return\": \"\""; then GOLDEN="loadvm-golden:OK"; else GOLDEN="loadvm-golden:UNCLEAR"; fi

# 6. restart daemon
systemctl start "streamhost@$T"
sleep 1
DA=$(systemctl is-active "streamhost@$T")
echo "[$T] OK exe=patched scope=${SCOPE:-no} $GOLDEN daemon=$DA pid=$NP"
