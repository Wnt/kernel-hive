#!/usr/bin/env bash
# check-media-archive.sh — verify the persistent media archive, and the media
# baked INSIDE the two bridge bases (which nothing checked before this).
#
# Sibling of check-assets.sh, deliberately not folded into it: check-assets.sh
# answers "can a build start?" by looking at staged paths, this answers "is the
# archive still intact, and does the frozen base still contain what we think?".
# The two failure modes are different and so are the audiences.
#
#   check-media-archive.sh              # verify every blob + the base media
#   check-media-archive.sh --quick      # skip full re-hashing of every blob
#   check-media-archive.sh --manifest   # cross-reference docs/lab/ASSETS-MANIFEST.md
#
# Exit: 0 = archive intact; 1 = a blob is corrupt, or base media is missing/wrong.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/media-cache.sh
. "$HERE/lib/media-cache.sh"

MANIFEST="${MANIFEST:-$HERE/../../docs/lab/ASSETS-MANIFEST.md}"
QUICK=0
XREF=0
while [ $# -gt 0 ]; do case "$1" in
  --quick)
    QUICK=1
    shift
    ;;
  --manifest)
    XREF=1
    shift
    ;;
  -h | --help)
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
esac done

c_r=$'\e[31m'
c_g=$'\e[32m'
c_y=$'\e[33m'
c_0=$'\e[0m'
fail=0

# ---- 1. every blob still hashes to its own name -----------------------------
# Content addressing makes this the whole integrity check: a blob whose contents
# no longer hash to its filename is corrupt, full stop. Worth running because
# this dataset is the ONLY copy of several of these files.
echo "== archive integrity =="
n=0
bad=0
for p in "$MEDIA_ARCHIVE_ROOT"/blobs/*/*; do
  [ -f "$p" ] || continue
  n=$((n + 1))
  h="$(basename "$p")"
  if [ "$QUICK" = 1 ]; then
    [ -s "$p" ] || {
      echo "${c_r}EMPTY${c_0}    $h"
      bad=$((bad + 1))
    }
  elif ! media_cache_verify "$h"; then
    echo "${c_r}CORRUPT${c_0}  $h — contents no longer hash to its name"
    bad=$((bad + 1))
  fi
done
if [ "$bad" = 0 ]; then
  echo "${c_g}ok${c_0}       $n blobs, $(du -sh "$MEDIA_ARCHIVE_ROOT" 2>/dev/null | cut -f1)"
else
  echo "${c_r}$bad of $n blobs FAILED${c_0}"
  fail=1
fi

# ---- 2. media inside the bridge bases ---------------------------------------
# The bases are FROZEN and back every bridge overlay read-only, so this is a
# read-only inspection: qemu-nbd --read-only plus debugfs, which opens the
# filesystem read-only and needs no mount at all. Never mount a frozen base.
NBD=""
cleanup() {
  [ -n "$NBD" ] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
  NBD=""
}
trap cleanup EXIT

check_base_media() {
  local base="$1" tag="$2" i part tmp f got want label
  [ -f "$base" ] || {
    echo "${c_y}skip${c_0}     $tag base absent ($base)"
    return 0
  }
  for i in $(seq 0 15); do
    [ -b "/dev/nbd$i" ] || continue
    qemu-nbd --read-only --connect="/dev/nbd$i" --format=qcow2 -- "$base" 2>/dev/null && {
      NBD="/dev/nbd$i"
      break
    }
  done
  [ -n "$NBD" ] || {
    echo "${c_r}FAIL${c_0}     could not attach $tag base read-only"
    fail=1
    return 1
  }
  sleep 1
  part="$(find /dev -maxdepth 1 -name "$(basename "$NBD")p*" | sort | head -1)"
  [ -n "$part" ] || part="$NBD"
  tmp="$(mktemp -d)"
  # The md5 pins ASSETS-MANIFEST.md records for the three copyrighted blobs.
  # etos1024k.img is GPL EmuTOS with no pin, so it is checked for presence only.
  for spec in \
    "GEOS.D64:709bec31c3502cbcf5d4761c38dcfa9e" \
    "amiga/kick13.rom:82a21c1890cae844b3df741f2762d48d" \
    "amiga/workbench13.adf:d10f4907697c4eafcf976b4ef6ea829b" \
    "etos1024k.img:"; do
    f="${spec%%:*}"
    want="${spec#*:}"
    label="$tag:/opt/bridge/media/$f"
    mkdir -p "$tmp/$(dirname "$f")"
    if ! debugfs -R "dump /opt/bridge/media/$f $tmp/$f" "$part" >/dev/null 2>&1 || [ ! -s "$tmp/$f" ]; then
      echo "${c_r}MISSING${c_0}  $label"
      fail=1
      continue
    fi
    if [ -n "$want" ]; then
      got="$(md5sum "$tmp/$f" | awk '{print $1}')"
      if [ "$got" != "$want" ]; then
        echo "${c_r}MISMATCH${c_0} $label md5 $got != $want"
        fail=1
        continue
      fi
    fi
    # Also assert the archive holds a copy, so the base is not the only one.
    if media_cache_have "$(sha256sum "$tmp/$f" | awk '{print $1}')"; then
      echo "${c_g}ok${c_0}       $label (pin ok, archived)"
    else
      echo "${c_y}warn${c_0}     $label (pin ok, NOT in the archive — run media-archive-populate.sh)"
    fi
  done
  rm -rf "$tmp"
  cleanup
}

echo
echo "== media inside the frozen bridge bases (read-only inspection) =="
check_base_media /data/vms/bridge/bridge-base.qcow2 bookworm
check_base_media /data/vms/bridge/bridge-base-trixie.qcow2 trixie

# ---- 3. cross-reference the manifest ----------------------------------------
# ASSETS-MANIFEST.md stays the INDEX OF RECORD. Rather than duplicating it, pull
# every sha256 it names and report which are held. A manifest hash absent from
# the archive is the actionable output: it is a file we are trusting an upstream
# to still be serving.
if [ "$XREF" = 1 ]; then
  echo
  echo "== cross-reference: docs/lab/ASSETS-MANIFEST.md =="
  if [ ! -f "$MANIFEST" ]; then
    echo "${c_y}skip${c_0}     manifest not found at $MANIFEST"
  else
    held=0
    absent=0
    while IFS= read -r h; do
      if media_cache_have "$h"; then held=$((held + 1)); else
        absent=$((absent + 1))
        echo "  not archived: $h"
      fi
    done < <(grep -ohE '\b[0-9a-f]{64}\b' "$MANIFEST" | sort -u)
    echo "manifest sha256s: $held archived, $absent not archived"
  fi
fi

echo
if [ "$fail" = 0 ]; then
  echo "${c_g}check-media-archive: OK${c_0}"
else
  echo "${c_r}check-media-archive: FAILED${c_0}"
fi
exit $fail
