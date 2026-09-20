#!/bin/bash
# tiles/multics.sh — build the `multics` station: Multics MR12.8 on DPS8M.
#
# Like vax43bsd/medley/perq this is a host application in a container, not a
# QEMU guest with a checkpoint. The builder's job is to produce inert, hashed
# artifacts:
#
#   bin/dps8              the pinned dps8m R3.1.0 simulator (static ELF)
#   media/12.8MULTICS.tap the MR12.8 QuickStart install tape
#   media/root.dsk        THE BAKED RPV — never staged here, see --disk below
#   rootfs/                the Debian tree the station container runs inside
#
# root.dsk is not built by this script. It is baked separately by
# tiles/multics-bake-golden.py (a real Multics install, driven over the
# simulator console) and this script only checks for the result.
#
# Every labhost step goes through scripts/dev/labrun. Never nest `ssh lab`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABRUN="$HERE/../../dev/labrun"
OS_ID="multics"

ASSETS="${MULTICS_ASSETS:-/data/vms/streamhost/assets/$OS_ID}"
STAGING="${MULTICS_STAGING:-/data/assets-staging/$OS_ID}"
WORK="${WORK:-/data/vms/build-$OS_ID}"
ROOTFS="${MULTICS_ROOTFS:-$ASSETS/rootfs}"

# uid base 2555904 = 39*65536; clear of every other contained station's base
# (medley 1966080, mvs38 2097152, vision 2162688, perq 2359296, its 2424832,
# vax43bsd 2490368). The rootfs was first built at 2031616, which collided
# with another station's base — see docs/lab/OPERATING-RULES.md rule 2 on
# contained stations sharing a uid range: each can then write the other's
# files. OLD_UIDBASE is the value to migrate away from; it is not reused.
UIDBASE="${MULTICS_UIDBASE:-2555904}"
OLD_UIDBASE="${MULTICS_OLD_UIDBASE:-2031616}"
UID_SHIFT=$((UIDBASE - OLD_UIDBASE))

# Upstream pins — measured 2026-09-20.
QUICKSTART_URL="${QUICKSTART_URL:-https://s3.amazonaws.com/eswenson-multics/public/releases/MR12.8/QuickStart_MR12.8.zip}"
QUICKSTART_ZIP=QuickStart_MR12.8.zip
QUICKSTART_SIZE=143942587
QUICKSTART_SHA=0c67af417950ca529249ce16568e8cc97cd8b4d7fde34081bd25af03cf64fac2

DPS8M_URL="${DPS8M_URL:-https://dps8m.gitlab.io/dps8m-r3.1.0-archive/R3.1.0/dps8m-r3.1.0-linux-641.tar.gz}"
DPS8M_TGZ=dps8m-r3.1.0-linux-641.tar.gz
DPS8M_SIZE=2678491
DPS8M_SHA=ce6104ac20349ca6d25fa4f3df9afb52714334b506c7dba911a178d7cbbb0ed7

# Simulator banner, for anyone diffing a future re-pin:
#   DPS8/M simulator R3.1.0 (64-bit)  Commit: a834c552e9046ed485fabbefa3139dc5ea08e64d

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }

usage() {
  cat >&2 <<EOF
usage: $0 [--media] [--bin] [--disk] [--rootfs] [--all]
  --media   fetch + verify QuickStart_MR12.8.zip and the dps8m tarball, unpack
  --bin     stage bin/dps8 and media/12.8MULTICS.tap into $ASSETS
  --disk    check for the baked media/root.dsk (never fabricated here)
  --rootfs  ensure the container rootfs exists and sits at uid $UIDBASE
  --all     all of the above, in order (default)
EOF
  exit 2
}

do_media=0 do_bin=0 do_disk=0 do_rootfs=0
if [ $# -eq 0 ]; then
  do_media=1 do_bin=1 do_disk=1 do_rootfs=1
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --media) do_media=1 ;;
    --bin) do_bin=1 ;;
    --disk) do_disk=1 ;;
    --rootfs) do_rootfs=1 ;;
    --all) do_media=1 do_bin=1 do_disk=1 do_rootfs=1 ;;
    *) usage ;;
  esac
  shift
done

# --------------------------------------------------------------------------
# 1. media — fetch, verify, unpack
# --------------------------------------------------------------------------
if [ "$do_media" = 1 ]; then
  log "staging QuickStart_MR12.8 + dps8m-r3.1.0 into $STAGING"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
mkdir -p "$STAGING"
cd "$STAGING"

fetch_verify() {
  name="\$1" url="\$2" size="\$3" sha="\$4"
  if [ -s "\$name" ] && [ "\$(stat -c %s "\$name")" = "\$size" ] && \
     echo "\$sha  \$name" | sha256sum -c - >/dev/null 2>&1; then
    return 0
  fi
  curl -fsSL -o "\$name" "\$url"
  got="\$(stat -c %s "\$name")"
  [ "\$got" = "\$size" ] || { echo "\$name: \$got bytes, expected \$size" >&2; exit 1; }
  echo "\$sha  \$name" | sha256sum -c - >/dev/null
}

fetch_verify "$QUICKSTART_ZIP" "$QUICKSTART_URL" "$QUICKSTART_SIZE" "$QUICKSTART_SHA"
fetch_verify "$DPS8M_TGZ" "$DPS8M_URL" "$DPS8M_SIZE" "$DPS8M_SHA"

if [ ! -s dps8m-r3.1.0/dps8 ]; then
  rm -rf dps8m-r3.1.0
  tar xzf "$DPS8M_TGZ"
fi
[ -s dps8m-r3.1.0/dps8 ] || { echo "no dps8 binary after unpacking $DPS8M_TGZ" >&2; exit 1; }

if [ ! -s QuickStart_MR12.8/12.8MULTICS.tap ]; then
  mkdir -p QuickStart_MR12.8
  unzip -o "$QUICKSTART_ZIP" 'QuickStart_MR12.8/12.8MULTICS.tap' -d .
fi
[ -s QuickStart_MR12.8/12.8MULTICS.tap ] || { echo "no install tape after unzipping $QUICKSTART_ZIP" >&2; exit 1; }

echo "media staged in $STAGING"
EOF
fi

# --------------------------------------------------------------------------
# 2. bin + tape media
# --------------------------------------------------------------------------
if [ "$do_bin" = 1 ]; then
  log "staging bin/dps8 + media/12.8MULTICS.tap into $ASSETS"
  "$LABRUN" <<EOF
set -euo pipefail
umask 022
mkdir -p "$ASSETS/bin" "$ASSETS/media"
install -m 0755 "$STAGING/dps8m-r3.1.0/dps8" "$ASSETS/bin/dps8"
install -m 0444 "$STAGING/QuickStart_MR12.8/12.8MULTICS.tap" "$ASSETS/media/12.8MULTICS.tap"
file "$ASSETS/bin/dps8"
EOF
fi

# --------------------------------------------------------------------------
# 3. the baked RPV disk — never built here
# --------------------------------------------------------------------------
if [ "$do_disk" = 1 ]; then
  log "checking for the baked media/root.dsk"
  "$LABRUN" <<EOF
set -euo pipefail
if [ -s "$ASSETS/media/root.dsk" ]; then
  echo "$ASSETS/media/root.dsk present (\$(stat -c %s "$ASSETS/media/root.dsk") bytes)"
else
  echo "$ASSETS/media/root.dsk not baked yet — run tiles/multics-bake-golden.py" >&2
fi
EOF
fi

# --------------------------------------------------------------------------
# 4. container rootfs — already debootstrapped; ensure the uid base is right
# --------------------------------------------------------------------------
if [ "$do_rootfs" = 1 ]; then
  log "checking container rootfs at $ROOTFS (target uid base $UIDBASE)"
  "$LABRUN" <<EOF
set -euo pipefail
R="$ROOTFS"
[ -x "\$R/usr/bin/xterm" ] || { echo "no \$R/usr/bin/xterm — rootfs is not built; this script does not debootstrap it" >&2; exit 1; }

current="\$(stat -c %u "\$R")"
if [ "\$current" = "$UIDBASE" ]; then
  echo "rootfs already at uid base $UIDBASE — nothing to do"
elif [ "\$current" = "$OLD_UIDBASE" ]; then
  echo "rootfs at colliding uid base $OLD_UIDBASE — shifting by $UID_SHIFT to $UIDBASE"
  python3 - "\$R" "$UID_SHIFT" <<'PY'
import os
import sys

root, shift = sys.argv[1], int(sys.argv[2])
n = 0
for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
    entries = list(dirnames) + list(filenames)
    for name in entries:
        p = os.path.join(dirpath, name)
        st = os.lstat(p)
        os.lchown(p, st.st_uid + shift, st.st_gid + shift)
        n += 1
    st = os.lstat(dirpath)
    os.lchown(dirpath, st.st_uid + shift, st.st_gid + shift)
print(f"shifted {n + 1} paths under {root}")
PY
  new="\$(stat -c %u "\$R")"
  [ "\$new" = "$UIDBASE" ] || { echo "rootfs top dir is uid \$new after the shift, expected $UIDBASE" >&2; exit 1; }
else
  echo "rootfs is at unexpected uid base \$current (neither $UIDBASE nor $OLD_UIDBASE) — refusing to shift blind" >&2
  exit 1
fi
echo "container rootfs at \$R (\$(du -sh "\$R" | cut -f1), uid \$(stat -c %u "\$R"))"
EOF
fi

# --------------------------------------------------------------------------
# 5. manifest — only meaningful once bin/dps8 + the tape are staged
# --------------------------------------------------------------------------
if [ "$do_bin" = 1 ]; then
  log "writing MANIFEST.sha256"
  "$LABRUN" <<EOF
set -euo pipefail
cd "$ASSETS"
{
  sha256sum bin/dps8 media/12.8MULTICS.tap
  [ -s media/root.dsk ] && sha256sum media/root.dsk || true
} > MANIFEST.sha256
cat MANIFEST.sha256
EOF
fi

log "done"
