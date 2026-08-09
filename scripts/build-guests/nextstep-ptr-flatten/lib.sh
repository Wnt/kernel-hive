#!/bin/bash
# NSPTR-flatten-accel helper library (box-side).
D=/data/vms/soltest/NSPTR-flatten-accel
E=$D/evidence
SSH_PORT=5948
KEY=/data/vms/bridge/bridge_key
g() { ssh -i $KEY -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -p $SSH_PORT root@127.0.0.1 "$@"; }
# run a command in the kiosk X session
x() { g "export XAUTHORITY=\$(ls -t /tmp/serverauth.* | head -1) DISPLAY=:0; $*"; }
hmp() { python3 /root/qmp_hmp.py $D/qmp.sock "$1" >/dev/null; }
shot() { hmp "screendump $E/$1.ppm"; }
