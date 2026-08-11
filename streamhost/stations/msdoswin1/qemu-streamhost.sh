#!/bin/bash
# Launch tile 'msdoswin1' (VMID 113) QEMU with the streamhost display wiring.
# Kill only by pidfile. Stop/restore procedure for this one tile: ROLLBACK.md.
#
# GOLDEN TEST FIXTURE: this tile is a curated deterministic fixture. Its disk is a
# single snapshottable qcow2 that carries an internal live-RAM snapshot named
# "golden" (Windows 1.01 MS-DOS Executive GUI, 640x350 EGA). We therefore run
# WITHOUT -snapshot (so savevm/loadvm persist) and loadvm "golden" on boot so the
# tile comes up exactly at the fixture. Test reset = QMP `loadvm golden`
# (resetMode=loadvm) -- see golden.json. If the snapshot is ever missing, the guest
# cold-boots and AUTOEXEC.BAT auto-launches Windows, landing at the same GUI.
set -e
TILEDIR=/data/vms/streamhost/tiles/msdoswin1
S="$TILEDIR/qmp.sock"
[ -f "$TILEDIR/qemu.pid" ] && kill "$(cat "$TILEDIR/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$S" "$TILEDIR/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
nohup qemu-system-x86_64 \
  -name streamhost-msdoswin1 \
  -enable-kvm -m 16 -smp 1 \
  -machine pc-i440fx-11.0,pcspk-audiodev=snd0 -cpu host \
  -rtc base=localtime \
  -boot c \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive file=/data/gallery-guests/MSDOSWin1/msdos-win1.qcow2,format=qcow2,if=ide \
  -qmp unix:"$S",server=on,wait=off \
  -pidfile "$TILEDIR/qemu.pid" \
  >"$TILEDIR/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$S" ] && [ -f "$TILEDIR/qemu.pid" ] && break
  sleep 0.5
done
# Jump straight to the golden fixture (live-RAM snapshot) and leave it FROZEN
# (~0 CPU): stop first so a successful loadvm ends with vCPUs stopped at the
# fixture — the first visitor session's cont (idle.rs) wakes it sub-second.
# Tolerant: if the snapshot is absent (fresh build before savevm), loadvm
# errors and the `cont` resumes the interrupted cold boot RUNNING so
# golden-bake.sh can drive it, same recovery as before.
sleep 1
python3 "$TILEDIR/qmpc.py" "$S" raw '{"execute":"stop"}' >/dev/null 2>&1 || true
# qmpc always exits 0 and prints the QMP result; HMP loadvm success is exactly
# {"return": ""} — anything else (Error text, timeout, empty) takes the cont.
LV=$(python3 "$TILEDIR/qmpc.py" "$S" loadvm golden 2>/dev/null || true)
if [ "$LV" != '{"return": ""}' ]; then
  python3 "$TILEDIR/qmpc.py" "$S" raw '{"execute":"cont"}' >/dev/null 2>&1 || true
fi
echo "tile msdoswin1 qemu pid=$(cat "$TILEDIR/qemu.pid" 2>/dev/null) qmp=$S udp=54113 (loadvm golden, frozen until first visit; cold boot resumes RUNNING if no snapshot)"
