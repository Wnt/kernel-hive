#!/bin/bash
# (Re)bake the 'golden' snapshot for tile magiccap from a COLD boot of the base disk.
# ONLY needed if the golden snapshot inside the qcow2 disks was lost (e.g. a rebuild
# that did NOT preserve magiccap-c.qcow2 / magiccap-d.qcow2). Normally the snapshot
# travels INSIDE those qcow2s and qemu-streamhost.sh just '-loadvm golden'.
#
# UNLIKE win98se (whose bake is a bare-desktop Notepad fixture), this station's
# fixture is General Magic's Magic Cap desk view reached by installing and
# launching MCW.EXE inside the guest first. That in-guest sequence (import
# C:\MC.REG, reboot, dismiss the modem-setup and Getting-Started overlays, then
# savevm) is owned by scripts/build-guests/tiles/magiccap.sh and the station
# lead's own bake work under /data/vms/sandbox/magiccap/{smoke,inject,build} —
# see docs/lab/MAGICCAP-WAVE.md for the proven steps once they land.
#
# This script intentionally does NOT encode a blind QMP sendkey/screendump
# sequence for that fixture: copying win98se's Notepad-banner sequence here
# would bake the WRONG (win98se-shaped) fixture over a Magic Cap disk. Use
# qmp.py / sk.py / shot.sh directly (or the lead's proven bake script, once
# committed) to drive and prove the actual Magic Cap desk fixture.
echo "golden-bake.sh: no generic bake sequence for magiccap — see the header" >&2
echo "comment in this file and docs/lab/MAGICCAP-WAVE.md for the real steps." >&2
exit 1
