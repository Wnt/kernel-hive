#!/usr/bin/env bash
# Bake QNX 6.5.0's production `golden` RAM snapshot from a cold LiveCD boot.
# Run after qemu-streamhost.sh has created a fresh golden.qcow2 and launched
# without -loadvm. The complete flow is keyboard-only: cirrus/devg-svga at
# 64K colour, 1024x768, Alt+A to accept the timed mode test, Alt+X to leave
# phgrafx, then root with an empty password. No tablet or old golden is required.
# The first boot menu waits indefinitely, so the conservative F2 delay is safe
# on a loaded host.
set -euo pipefail

BASE=/data/vms/streamhost/stations/qnx
BOOTMENU_WAIT="${BOOTMENU_WAIT:-75}"
PHOTON_WAIT="${PHOTON_WAIT:-50}"
LOGIN_WAIT="${LOGIN_WAIT:-7}"
DESKTOP_WAIT="${DESKTOP_WAIT:-18}"

[ -S "$BASE/qmp.sock" ] || {
  echo "QNX QMP socket missing: $BASE/qmp.sock" >&2
  exit 1
}

hmp() {
  python3 - "$BASE/qmp.sock" "$1" <<'PY'
import json, socket, sys
sock, command = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX)
s.settimeout(30)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    if "return" in json.loads(f.readline()):
        break
req = {"execute": "human-monitor-command", "arguments": {"command-line": command}}
f.write(json.dumps(req).encode() + b"\n")
while True:
    reply = json.loads(f.readline())
    if "return" in reply:
        if reply["return"]:
            print(reply["return"])
        break
    if "error" in reply:
        raise SystemExit("QMP error: " + json.dumps(reply["error"]))
s.close()
PY
}

echo "[qnx-bake] wait ${BOOTMENU_WAIT}s for stable Select? menu, then send F2 once"
sleep "$BOOTMENU_WAIT"
hmp "sendkey f2"

echo "[qnx-bake] wait ${PHOTON_WAIT}s for Photon Display Setup"
sleep "$PHOTON_WAIT"
echo "[qnx-bake] select devg-svga 64K 1024x768 and Apply"
for key in tab tab tab down down tab tab tab tab tab spc; do
  hmp "sendkey $key"
  sleep .3
done
sleep 2
echo "[qnx-bake] accept the timed mode test by mnemonic (Alt+A)"
hmp "sendkey alt-a"
sleep 12
echo "[qnx-bake] exit phgrafx by mnemonic (Alt+X)"
hmp "sendkey alt-x"

echo "[qnx-bake] wait ${LOGIN_WAIT}s for login, then enter root with an empty password"
sleep "$LOGIN_WAIT"
for key in r o o t ret ret; do
  hmp "sendkey $key"
  sleep .3
done
sleep "$DESKTOP_WAIT"

PROOF="$BASE/golden-proof.ppm"
rm -f "$PROOF"
hmp "screendump $PROOF"
python3 - "$PROOF" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    magic = f.readline().strip()
    dims = f.readline().split()
if magic != b"P6" or dims != [b"1024", b"768"]:
    raise SystemExit("QNX framebuffer proof is not 1024x768")
print("[qnx-bake] framebuffer proof: 1024x768 Photon desktop")
PY

echo "[qnx-bake] savevm golden"
hmp "savevm golden"
hmp "info snapshots"
echo "[qnx-bake] done; future launcher runs auto-load golden"
