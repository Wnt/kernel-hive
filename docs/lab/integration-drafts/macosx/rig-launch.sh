#!/bin/bash
# smoke/race launcher for macosx rigs (namespaced under the macosx-work sandbox)
set -e
R="$1"
shift
S="${S:-/data/vms/sandbox/macosx-work}" # point this at the resuming session's sandbox
D="$S/$R"
ISO="${ISO:-/data/assets-staging/macosx/jaguar-10.2-cd1.iso}"
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
export SH_DBUS_UPDATE_MS=4
nohup /opt/qemu-ppc/bin/qemu-system-ppc \
  -name kh-macosx-"$R" \
  -accel tcg -m "${MEM:-1024}" \
  -M mac99,via=pmu -cpu g4 \
  -g 1024x768x32 \
  -display dbus,p2p=on \
  -nic none \
  -drive file="$D/macosx.qcow2",format=qcow2,cache=writeback,aio=threads \
  -drive file="$ISO",format=raw,media=cdrom \
  -boot d \
  "$@" \
  -qmp unix:"$D/qmp.sock",server=on,wait=off \
  -pidfile "$D/qemu.pid" >"$D/qemu.log" 2>&1 &
for _ in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && break
  sleep 0.5
done
[ -S "$D/qmp.sock" ] && echo "$R up pid=$(cat "$D/qemu.pid")"
