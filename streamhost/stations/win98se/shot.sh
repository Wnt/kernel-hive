#!/bin/bash
# shot.sh <name> : screendump the win98se tile framebuffer to /tmp/<name>.png and print md5
B=/data/vms/streamhost/stations/win98se
N=${1:-shot}
python3 "$B/qmp.py" "$B/qmp.sock" \
  "[{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"/tmp/$N.png\",\"format\":\"png\"}}]" >/dev/null
echo "/tmp/$N.png md5=$(md5sum "/tmp/$N.png" | cut -d' ' -f1)"
