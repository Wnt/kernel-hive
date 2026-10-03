#!/bin/bash
# Finish ONLY a stopped, cleanly flushed installation clone. No live disk edits.
set -euo pipefail
DISK="${1:?usage: symbos-finish-media.sh installed.dsk release40-apps-dir}"
APPS="${2:?pass apps extracted by symbos.sh --prepare}"
[ "$(stat -c %s "$DISK")" = 737280 ]
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for f in SYMSETUP.COM SYMSETUP.DAT NOTEPAD.LNG APP-GA~1.DAT; do
  mdel -i "$DISK" "::$f" 2>/dev/null || true
done
mcopy -o -i "$DISK" "$APPS"/{notepad.exe,notepad.dat,notepad.hlp,calc.exe,calc.hlp,gamelife.exe,gamelife.dat,gamelife.hlp} ::
printf 'SYM\r\n' >"$WORK/AUTOEXEC.BAT"
mcopy -o -i "$DISK" "$WORK/AUTOEXEC.BAT" ::AUTOEXEC.BAT
mcopy -i "$DISK" ::SYMBOS.INI "$WORK/SYMBOS.INI"
# Classic desktop stores paths in 32-byte slots and two 12-byte label lines.
# Preserve the installer-selected storage driver, mapper and video settings.
python3 - "$WORK/SYMBOS.INI" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
b = bytearray(p.read_bytes())
for pos, old, new in [(1434, b"%cmd.exe", b"%notepad.exe"),
                      (1466, b"%cp.exe", b"%calc.exe"),
                      (1498, b"%taskmgr.exe", b"%gamelife.exe")]:
    assert bytes(b[pos:pos + len(old)]) == old or bytes(b[pos:pos + len(new)]) == new
    b[pos:pos + 32] = new.ljust(32, b"\0")
for pos, first, second in [(1682, b"Notepad", b""),
                           (1706, b"Pocket", b"Calculator"),
                           (1730, b"Game of", b"Life")]:
    b[pos:pos + 24] = first.ljust(12, b"\0") + second.ljust(12, b"\0")
p.write_bytes(b)
PY
mcopy -o -i "$DISK" "$WORK/SYMBOS.INI" ::SYMBOS.INI
sha256sum "$DISK" | awk '{print $1}' >"$DISK.sha256"
mdir -i "$DISK" ::
echo 'Finished master; prove cold boot, apps, input and reset before staging.'
