#!/bin/bash
# win95 CLEAN-desktop offline prep (PHASE A step 1, offline portion).
# Copies the LIVE win95 checkpoint to a namespaced soltest clone, then OFFLINE (qemu-nbd):
#   - empty WIN.INI [windows] run= (kills the Notepad auto-launch)
#   - clear any StartUp-folder .lnk (belt & suspenders)
# Does NOT touch the live station. Registry (Windows-Logon) change is done GUI-side later.
set -euo pipefail
LIVE=/data/vms/streamhost/stations/win95/win95-golden.qcow2
PREP=/data/vms/soltest/win95-clean-prep
DISK="$PREP/win95-golden.qcow2"
NBD=/dev/nbd2
MNT=/mnt/win95clean

echo "== live golden md5 (for the record) =="
md5sum "$LIVE"

mkdir -p "$PREP"
echo "== copy live golden -> prep clone (reflink if supported) =="
cp --reflink=auto -f "$LIVE" "$DISK"
ls -la "$DISK"

echo "== attach via qemu-nbd ($NBD) =="
qemu-nbd -d "$NBD" >/dev/null 2>&1 || true
sleep 1
qemu-nbd -c "$NBD" "$DISK"
sleep 2
mkdir -p "$MNT"
mount -t vfat "${NBD}p1" "$MNT"
echo "-- mounted; WINDOWS dir present? --"
ls -d "$MNT/WINDOWS" >/dev/null && echo "  WINDOWS ok"

echo "== BEFORE: WIN.INI [windows] run= line =="
grep -in '^run=' "$MNT/WINDOWS/WIN.INI" || echo "  (no run= line found)"

echo "== edit WIN.INI: empty the [windows] run= (remove notepad auto-launch) =="
python3 - "$MNT/WINDOWS/WIN.INI" <<'PY'
import sys
p = sys.argv[1]
raw = open(p, 'rb').read().decode('latin-1')
lines = raw.split('\r\n')
out = []
inw = False
changed = False
for ln in lines:
    s = ln.strip().lower()
    if s.startswith('[') and s.endswith(']'):
        inw = (s == '[windows]')
    if inw and s.startswith('run='):
        out.append('run=')          # empty -> nothing auto-launches
        changed = True
        continue
    out.append(ln)
open(p, 'wb').write('\r\n'.join(out).encode('latin-1'))
print("  WIN.INI run= emptied" if changed else "  WARN: no run= line in [windows] to empty")
PY

echo "== AFTER: WIN.INI [windows] run= line =="
grep -in '^run=' "$MNT/WINDOWS/WIN.INI" || echo "  (no run= line found)"

echo "== StartUp folder contents (belt & suspenders) =="
SU="$MNT/WINDOWS/Start Menu/Programs/StartUp"
if [ -d "$SU" ]; then
  ls -la "$SU"
  # remove any non-hidden .lnk that would auto-launch on logon
  find "$SU" -maxdepth 1 -type f \( -iname '*.lnk' -o -iname '*.pif' \) -print -exec rm -f {} \; || true
  echo "-- StartUp after clear --"
  ls -la "$SU"
else
  echo "  (no StartUp folder at expected path; listing WINDOWS/Start Menu) "
  ls -la "$MNT/WINDOWS/Start Menu/Programs/" 2>/dev/null || true
fi

echo "== detach =="
sync
umount "$MNT"
qemu-nbd -d "$NBD" >/dev/null 2>&1
echo "== offline prep DONE. Prepped disk: $DISK =="
qemu-img snapshot -l "$DISK" 2>/dev/null || true
