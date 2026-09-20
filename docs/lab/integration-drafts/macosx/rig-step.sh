#!/bin/bash
# step.sh <rig> <x> <y> [settle] — click at (x,y), wait for the screen to settle, emit PNG
set -e
S=/data/vms/sandbox/macosx-work
R="$1"; X="$2"; Y="$3"; ST="${4:-8}"
Q=$S/$R/qmp.sock
if [ "$X" != "-" ]; then
  python3 $S/drv.py $Q abs $X $Y sleep 0.4 click
fi
python3 $S/repo/scripts/dev/fb-wait.py --qmp $Q --settle $ST --timeout 900 >/dev/null 2>&1 || true
python3 $S/drv.py $Q shot $S/$R/step.ppm >/dev/null
python3 -c "from PIL import Image;Image.open('$S/$R/step.ppm').save('$S/$R/step.png')"
echo "step done"
