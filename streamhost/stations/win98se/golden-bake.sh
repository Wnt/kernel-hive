#!/bin/bash
# (Re)bake the 'golden' snapshot for tile win98se from a COLD boot of the base disk.
# ONLY needed if the golden snapshot inside the qcow2 disks was lost (e.g. a rebuild
# that did NOT preserve win98se-kvm.qcow2 / win98se-games.qcow2). Normally the
# snapshot travels INSIDE those qcow2s and qemu-streamhost.sh just '-loadvm golden'.
#
# This drives a Win98 GUI blind via QMP sendkey/screendump, so it is inherently
# timing-sensitive. Watch /tmp/bake_*.png checkpoints; bump sleeps if a step is early.
# Prereq: launch a COLD tile first (snapshot absent):  bash qemu-streamhost.sh
#
# Sequence encoded here == the validated manual bake:
#   nag-dismiss -> DOS regedit /s (screensaver off + steady caret) -> clean restart
#   -> nag-dismiss -> hide taskbar clock (GUI) -> Notepad + banner -> focus -> savevm.
set -e
B=/data/vms/streamhost/stations/win98se
SK="python3 $B/sk.py $B/qmp.sock"
QM="python3 $B/qmp.py $B/qmp.sock"
hmp() { $QM "[{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$1\"}}]" >/dev/null; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
typeln() {
  $SK text64 "$(b64 "$1")" >/dev/null
  $SK key ret >/dev/null
  sleep 0.5
}
shot() { bash $B/shot.sh "$1" >/dev/null 2>&1 || true; }

echo "[bake] waiting for cold boot (ScanDisk if dirty, then Win98 splash, then nag)..."
sleep 80
echo "[bake] dismiss 'display adapter not configured' nag (Esc opens Display Props, Esc closes)"
$SK key esc >/dev/null
sleep 3
$SK key esc >/dev/null
sleep 18
shot bake_desktop

echo "[bake] open DOS box and import registry tweaks (screensaver off + steady caret)"
$SK key ctrl-esc >/dev/null
sleep 1.2
$SK key r >/dev/null
sleep 1.2
typeln "command"
sleep 2.5
typeln 'echo REGEDIT4>c:\GOLDFIX.reg'
typeln 'echo.>>c:\GOLDFIX.reg'
typeln 'echo [HKEY_CURRENT_USER\Control Panel\Desktop]>>c:\GOLDFIX.reg'
typeln 'echo "ScreenSaveActive"="0">>c:\GOLDFIX.reg'
typeln 'echo "ScreenSaveTimeOut"="0">>c:\GOLDFIX.reg'
typeln 'echo "SCRNSAVE.EXE"="">>c:\GOLDFIX.reg'
typeln 'echo "CursorBlinkRate"="-1">>c:\GOLDFIX.reg'
typeln 'regedit /s c:\GOLDFIX.reg' # /s = silent; a MODAL regedit once wedged KVM
sleep 2
typeln 'exit'
sleep 1

echo "[bake] clean restart so HKCU caret/screensaver settings load fresh (avoids next-boot ScanDisk)"
$SK key ctrl-esc >/dev/null
sleep 1.2
$SK key u >/dev/null
sleep 2 # Start > Shut Down
$SK key down >/dev/null
sleep 0.6              # select 'Restart'
$SK key ret >/dev/null # OK
echo "[bake] waiting for restart + nag..."
sleep 70
$SK key esc >/dev/null
sleep 3
$SK key esc >/dev/null
sleep 20
shot bake_desktop2

echo "[bake] hide taskbar clock (Start > Settings > Taskbar & Start Menu > uncheck Show clock)"
$SK key ctrl-esc >/dev/null
sleep 1.2
$SK key up >/dev/null
sleep 0.4 # -> Shut Down (bottom)
for i in 1 2 3 4 5; do
  $SK key up >/dev/null
  sleep 0.3
done # up to 'Settings'
$SK key right >/dev/null
sleep 1 # open Settings submenu
$SK key down >/dev/null
sleep 0.3
$SK key down >/dev/null
sleep 0.5 # -> 'Taskbar & Start Menu...'
$SK key ret >/dev/null
sleep 2.5 # open Taskbar Properties
$SK key tab >/dev/null
sleep 0.4 # Auto hide
$SK key tab >/dev/null
sleep 0.4 # Show small icons
$SK key tab >/dev/null
sleep 0.4 # Show clock
$SK key spc >/dev/null
sleep 0.6 # uncheck it
$SK key ret >/dev/null
sleep 2
shot bake_clockoff # OK (apply)

echo "[bake] open Notepad and type the fixture banner"
$SK key ctrl-esc >/dev/null
sleep 1.2
$SK key r >/dev/null
sleep 1.2
typeln "notepad"
sleep 3
typeln "WINDOWS 98 SE -- GOLDEN TEST FIXTURE (resetMode=loadvm)"
typeln "Keyboard-reactive surface: type here. Characters echo at"
typeln "steady (non-blinking) caret; arrow keys move the caret."
typeln "Mouse-reactive: click in this text area to move the caret,"
typeln "or click Start / a desktop icon for a visible result."
typeln "Reset: QMP 'loadvm golden' restores this exact screen, live."
typeln "--------------------------------------------------------"
$SK text64 "$(b64 'Type below:')" >/dev/null
$SK key ret >/dev/null
sleep 0.5

echo "[bake] guarantee REAL edit focus (a non-blinking caret can be a stale visual)"
hmp "mouse_move -2000 -2000"
sleep 0.3 # park pointer at top-left (arrow, deterministic)
$SK key alt-tab >/dev/null
sleep 1.2 # genuinely (re)activate Notepad -> edit focus
$SK key shift-z >/dev/null
sleep 0.5 # prove focus: 'Z' should appear
$SK key backspace >/dev/null
sleep 0.5 # remove it -> clean fixture
shot bake_fixture

echo "[bake] savevm golden (persists into the base qcow2 disks)"
qemu-img snapshot -l /data/gallery-guests/Win98SE/win98se-kvm.qcow2 2>/dev/null | grep -qw golden && hmp "delvm golden"
hmp "savevm golden"
$QM '[{"execute":"human-monitor-command","arguments":{"command-line":"info snapshots"}}]'
echo "[bake] done. Verify: bash golden-reset.sh (loadvm) then type -> chars appear."
echo "[bake] Future launches auto '-loadvm golden' (see qemu-streamhost.sh)."
