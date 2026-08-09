#!/bin/bash
set -e
D=/data/vms/soltest/NSPTR-previous-patch
K=/data/vms/bridge/bridge_key
O="-i $K -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
scp -q $O -P 5937 "$D/abspointer.c" root@127.0.0.1:/usr/local/src/previous-code/src/abspointer.c
scp -q $O -P 5937 "$D/abspointer.h" root@127.0.0.1:/usr/local/src/previous-code/src/includes/abspointer.h
scp -q $O -P 5937 "$D/patchsrc.py" root@127.0.0.1:/tmp/patchsrc.py
ssh $O -p 5937 root@127.0.0.1 "cd /usr/local/src/previous-code && python3 /tmp/patchsrc.py && grep -n 'abspointer\|AbsPointer' src/CMakeLists.txt src/main.c && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DENABLE_RENDERING_THREAD=1 >/tmp/prev-cmake.log 2>&1 && (cmake --build build -j4 >/tmp/prev-build.log 2>&1 || (tail -40 /tmp/prev-build.log; exit 1)) && ls -l build/src/previous"
