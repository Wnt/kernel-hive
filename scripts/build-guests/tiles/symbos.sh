#!/bin/bash
# SymbOS 4.0 MSX installer + official apps, with a separately curated boot master.
# Third-party binaries stay in private assets. See docs/guests/symbos.md.
set -euo pipefail
STAGING="${STAGING:-/data/assets-staging/symbos}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/symbos}"
MASTER="${SYMBOS_MASTER:-$STAGING/media/symbos4-installed.dsk}"
MODE="${1:-}"
mkdir -p "$STAGING/media" "$STAGING/apps" "$STAGING/work" "$ASSETS/media"
fetch() {
  local file="$1" url="$2" hash="$3"
  if [ ! -f "$file" ] || ! echo "$hash  $file" | sha256sum -c --status; then
    curl -fLsS -A 'Mozilla/5.0' "$url" -o "$file.tmp"
    echo "$hash  $file.tmp" | sha256sum -c --status
    mv "$file.tmp" "$file"
  fi
}
fetch "$STAGING/media/symbos-msx40.zip" \
  https://www.symbos.org/download/20250131-V40/symbos-msx40.zip \
  27fa0201e0dbf08bdeb951a4aaa22e61a43ec3fc29c20a89bc7299478d322d6a
fetch "$STAGING/media/msxdos1.zip" https://msxhub.com/api/MSXDOS1/1.03-2/get/MSXDOS1.zip \
  89722f4038a4ea93d3515fa0891f60f957f4ba9aad8760e4baaaa46d4393e10c
fetch "$STAGING/media/msxdos101-108.zip" \
  'https://download.file-hunter.com/OS/MSXDOS/MSX-DOS%201%20original%20versions/msxdos101-108%20clean.zip' \
  88953799ca8a196c0b22596e99b6c39620a50576990ede9a3adbd990dd0571bf
fetch "$STAGING/apps/completion40.zip" \
  https://www.symbos.org/download/20250131-V40/SymbOS-40-MassStorageCompletion.zip \
  65b24b3b955a6a2ff1dc51f20b8226b68c516da2e6e31ef3c312bd10ca2187e4
if [ "$MODE" = --prepare ]; then
  unzip -p "$STAGING/media/symbos-msx40.zip" SymbOS-MSX40-Setup.ZIP >"$STAGING/work/setup.zip"
  unzip -jo "$STAGING/work/setup.zip" -d "$STAGING/work"
  unzip -jo "$STAGING/media/msxdos1.zip" -d "$STAGING/work"
  unzip -p "$STAGING/media/msxdos101-108.zip" 'msxdos101-108 clean.dsk' >"$STAGING/work/dos1.dsk"
  DISK="$STAGING/media/symbos4-setup.dsk"
  truncate -s 737280 "$DISK"
  mformat -i "$DISK" -f 720 ::
  # Keep mformat's 720K BPB; copy the original DOS1 boot code around it.
  python3 - "$STAGING/work/dos1.dsk" "$DISK" <<'PY'
import sys
from pathlib import Path
boot = Path(sys.argv[1]).read_bytes()[:512]
with open(sys.argv[2], "r+b") as disk:
    disk.write(boot[:11])
    disk.seek(30)
    disk.write(boot[30:])
PY
  mcopy -o -i "$DISK" "$STAGING/work/MSXDOS.SYS" "$STAGING/work/COMMAND.COM" \
    "$STAGING/work/"[sS][yY][mM][sS][eE][tT][uU][pP].[cC][oO][mM] \
    "$STAGING/work/"[sS][yY][mM][sS][eE][tT][uU][pP].[dD][aA][tT] ::
  mkdir -p "$STAGING/apps/release40"
  unzip -jo "$STAGING/apps/completion40.zip" 'symbos/APPS/notepad.*' \
    'symbos/APPS/calc.*' 'symbos/APPS/gamelife.*' -d "$STAGING/apps/release40"
  echo "Installer prepared: $DISK. Install on an isolated nms8250 clone using docs/guests/symbos.md."
  exit 0
fi
if [ "$MODE" = --stage-installed ]; then
  MASTER="${2:?pass the installed, cleanly flushed master disk}"
fi
[ -f "$MASTER" ] || {
  echo 'No curated master. Run --prepare, install per docs/guests/symbos.md, then --stage-installed FILE.' >&2
  exit 1
}
[ "$(stat -c %s "$MASTER")" = 737280 ]
# The exact validated fixture hash is recorded beside the private immutable master.
[ -f "$MASTER.sha256" ] || {
  echo "Missing $MASTER.sha256 provenance" >&2
  exit 1
}
echo "$(cat "$MASTER.sha256")  $MASTER" | sha256sum -c --status
install -m 444 "$MASTER" "$ASSETS/media/symbos4.dsk"
sha256sum "$ASSETS/media/symbos4.dsk" >"$ASSETS/media/symbos4.dsk.sha256"
echo "PASS: private SymbOS master staged at $ASSETS/media/symbos4.dsk"
