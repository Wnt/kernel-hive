#!/bin/bash
# (Re)bake the 'golden' snapshot for tile templeos from a COLD ISO boot. This is
# intentionally end-to-end: it stops the live tile (pidfile-owned QEMU included),
# installs the vendored launcher, deletes only the old golden snapshot, cold-boots,
# injects + starts the serial warpd agent, saves golden, and starts the tile again.
# Run from the box checkout:
#   nice -n15 bash streamhost/stations/templeos/golden-bake.sh
set -euo pipefail
BASE=/data/vms/streamhost/stations/templeos
HERE="$(cd "$(dirname "$0")" && pwd)"
STATE="$BASE/state.qcow2"
AGENT="$HERE/../../guest-agents/templeos/warpd.HC"
QMP=(python3 "$HERE/qmp.py" "$BASE/qmp.sock")
SK=(python3 "$HERE/sk.py" "$BASE/qmp.sock")
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
holyc() {
  "${SK[@]}" text64 "$(b64 "$1")" >/dev/null
  "${SK[@]}" key ret >/dev/null
  sleep 1
}

test -f "$AGENT"
test -f "$HERE/qemu-streamhost.sh"
test -f /data/gallery-guests/TempleOS/TempleOS.ISO
grep -qx 'SH_POINTER=warpd' "$BASE/station.env"
grep -qx "SH_WARPD_ADDR=unix:$BASE/serial.sock" "$BASE/station.env"

echo "[bake] stopping live tile and installing the vendored pinned launcher ..."
systemctl stop streamhost@templeos
install -m 0755 "$HERE/qemu-streamhost.sh" "$BASE/qemu-streamhost.sh"
if [ -f "$STATE" ] && qemu-img snapshot -l "$STATE" | awk '$2 == "golden" { found=1 } END { exit !found }'; then
  qemu-img snapshot -d golden "$STATE"
fi
echo "[bake] cold-booting TempleOS under nice -n15 ..."
nice -n15 bash "$BASE/qemu-streamhost.sh"
echo "[bake] waiting for TempleOS ISO to reach the first-boot welcome..."
sleep 20
# --- dismiss first-boot dialogs (single-key YorN prompts) ---
"${SK[@]}" key n >/dev/null
sleep 2 # Install onto hard drive (y or n)? -> NO (stay on live CD)
"${SK[@]}" key n >/dev/null
sleep 2 # Take Tour (y or n)?            -> n
# --- fixture tweaks (HolyC at the T:/Home> REPL) ---
holyc 'AutoComplete(FALSE);' # close the AutoComplete/"God" help+demo window (kills its idle animation)
holyc 'WinHorz(0,79);'       # maximize the main terminal to full width (collapses the 2nd terminal pane)
agent_one_line="$(sed -n '/^U0 WS()/,$ p' "$AGENT" | sed 's,//.*$, ,' | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')"
test -n "$agent_one_line"
echo "[bake] injecting and starting the TempleOS serial warpd agent ..."
holyc "$agent_one_line"
holyc 'Spawn(&WS);'
holyc 'DocClear;' # clear the welcome text -> pristine keyboard-reactive prompt
sleep 1
echo "[bake] savevm golden ..."
"${QMP[@]}" '[{"execute":"human-monitor-command","arguments":{"command-line":"savevm golden"}}]'
"${QMP[@]}" '[{"execute":"human-monitor-command","arguments":{"command-line":"info snapshots"}}]'
echo "[bake] starting streamhost@templeos ..."
systemctl start streamhost@templeos
labctl ls | awk '$1 == "templeos"'
echo "[bake] done. Future launches auto -loadvm golden with WS already running."
