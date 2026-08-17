#!/bin/bash
# nsh.sh <file-with-one-shell-line> [tag] [settle_s] — type the line into the
# NeXTSTEP Terminal (which must already hold the key focus) and screenshot.
# The line travels as a FILE all the way to xdotool --file, so nothing in it is
# ever re-parsed by a shell.
# shellcheck source=/dev/null  # box-only rig library, not in the repo
source /data/vms/sandbox/NSPTR-flatten-accel/lib.sh
F=$1
TAG=${2:-nsh}
S=${3:-4}
g "cat > /tmp/nsline" <"$F"
x "xdotool type --delay 90 --file /tmp/nsline; sleep 0.4; xdotool key Return" >/dev/null 2>&1
sleep "$S"
shot "$TAG"
python3 -c "
from PIL import Image
Image.open('$E/$TAG.ppm').crop((200,255,710,600)).save('$E/$TAG.png')"
echo "$E/$TAG.png"
