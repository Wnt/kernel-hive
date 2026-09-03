#!/bin/sh
# Kernel Hive 'openbsd' golden scene: fvwm (base Xenocara) with the classic X apps open.
# Screen is 1024x768 (QEMU EDID preferred mode; Xorg vesa driver).
xset s off -dpms
xset b off
xsetroot -solid '#2d4f7c'
xterm -geometry 80x24+16+40 -title 'root@openbsd' -fa monospace -fs 11 &
xclock -geometry 120x120-16+16 -update 1 &
xeyes -geometry 160x100-16+150 &
xcalc -geometry -16-16 &
exec fvwm
