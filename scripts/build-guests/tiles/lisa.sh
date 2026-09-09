#!/bin/bash
# =============================================================================
# tiles/lisa.sh — stage the host-native LisaEm station (Apple Lisa 2, Lisa
# Office System 3.1). No QEMU anywhere: LisaEm is a wxGTK application the
# station runs inside a pinned Xvfb (stations/lisa/x11-runtime.sh).
#
# What this builder does (stage: assemble — the only stage; LOS 3.1 ships
# pre-installed on a ProFile image, and the from-scratch install floppies are
# staged for provenance and a rebuild, not run here):
#   * media gate — every input hash-checked against docs/lab/LISA-WAVE.md's
#     ledger (see also docs/lab/ASSETS-MANIFEST.md), staged at $ASSETS
#     (/data/vms/sandbox/lisa/media by default; fetch with --fetch);
#   * the upstream LisaEm 2.0.0 Linux AppImage is extracted
#     (--appimage-extract; the binary is UPX-packed, so nothing is patched)
#     into $OUT/lisaem/;
#   * the GTK 3 closure labhost lacks is copied from THIS container's Ubuntu
#     24.04 packages into $OUT/lib/ (seven objects, measured with
#     `LD_DEBUG=libs lisaem --help` on CT950 against labhost's /lib);
#   * the Rev H boot ROM is assembled from the MAME lisa2 romset halves
#     (341-0175-h high, 341-0176-h low, byte-interleaved) and hash-checked;
#   * LisaEm's config template and the golden ProFile image are staged.
#
# Output (ONE combination with the launcher and the fixture):
#   $OUT/lisaem/          the extracted AppImage (usr/local/bin/lisaem + tools)
#   $OUT/lib/             GTK 3 closure + gconv/UTF-32.so
#   $OUT/rom/lisaboot-revH.rom
#   $OUT/lisaem.conf.template
#   $OUT/rootfs/          the nspawn sandbox skeleton (mount points + symlinks;
#                         the host's /usr is bound in read-only by the launcher)
#   $STATION/disk/lisa-profile.dc42.golden   (the pristine LOS 3.1 image)
#
# Run from CT950 (the libraries come from this container); $OUT and $STATION
# are bind-mounted so labhost sees the result immediately.
# =============================================================================
set -euo pipefail

OS_ID=lisa
ASSETS="${ASSETS:-/data/vms/sandbox/lisa/media}"
OUT="${OUT:-/data/vms/streamhost/assets/lisa}"
STATION="${STATION:-/data/vms/streamhost/stations/lisa}"
FETCH=0
[ "${1:-}" = "--fetch" ] && FETCH=1

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

APPIMAGE="LisaEm-2.0.0-2026.01.25-Linux_x86_64.AppImage"
APPIMAGE_URL="https://github.com/arcanebyte/lisaem/releases/download/2.0.0/$APPIMAGE"
APPIMAGE_SHA="a9dc5674fbbb0174920b21e8b8a6c543074e239f205af1cdd61ca17628e2ade8"
ROMSET="lisa2.zip"
ROMSET_URL="https://archive.org/download/mame-0.264-roms-non-merged/MAME%200.264%20ROMs%20%28non-merged%29/lisa2.zip"
ROMSET_SHA="3f324d5f041c8f1e70210bf278b4d963550730e75c4fcd24214f4b16bbce3034"
ROM_SHA="4eb245a5a133a202cb07757a7430437a996d91acddfba2c1a3b787e8b5b9d8f5"
PROFILE_ZIP="LisaEM_LOS3.1with7LisaApps.zip"
PROFILE_URL="https://archive.org/download/apple-lisa-profile-hd-disk-images-for-lisaem-and-idle-lisa-office-system-3.1-lis/$PROFILE_ZIP"
PROFILE_ZIP_SHA="3536d79794b121614015b95705e9f63767a7c37cfb82a307f5c397ab4a563aad"
PROFILE_SHA="bbc97e82d544050c156057fd80e28a7f66a8e24429e7ed28442fe9d62b84e2ae"
FLOPPIES_ZIP="los-3.1-en.zip"
FLOPPIES_URL="https://archive.org/download/los-3.1-en/$FLOPPIES_ZIP"
FLOPPIES_SHA="7cc3b9e1b62ae49ec3e520be915383c63c9516d638570a70599c3e2e798a57f3"

fetch() { # url dest
  [ -f "$2" ] && return 0
  [ "$FETCH" = 1 ] || die "missing $2 — re-run with --fetch"
  log "fetching $1"
  curl -sSL --retry 5 --retry-delay 5 -m 900 -o "$2.part" "$1" && mv "$2.part" "$2"
}
check() { # file sha
  local got
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || die "sha256 mismatch for $1: got $got want $2"
  log "ok $(stat -c '%s' "$1") B  $(basename "$1")"
}

mkdir -p "$ASSETS/rom" "$OUT/rom" "$OUT/lib/gconv" "$STATION/disk"
cd "$ASSETS"

log "media gate"
fetch "$APPIMAGE_URL" "$ASSETS/$APPIMAGE" && check "$ASSETS/$APPIMAGE" "$APPIMAGE_SHA"
fetch "$ROMSET_URL" "$ASSETS/rom/$ROMSET" && check "$ASSETS/rom/$ROMSET" "$ROMSET_SHA"
fetch "$PROFILE_URL" "$ASSETS/$PROFILE_ZIP" && check "$ASSETS/$PROFILE_ZIP" "$PROFILE_ZIP_SHA"
fetch "$FLOPPIES_URL" "$ASSETS/$FLOPPIES_ZIP" && check "$ASSETS/$FLOPPIES_ZIP" "$FLOPPIES_SHA"

log "LisaEm: extract the AppImage"
chmod +x "$ASSETS/$APPIMAGE"
rm -rf "$ASSETS/squashfs-root"
(cd "$ASSETS" && "./$APPIMAGE" --appimage-extract >/dev/null)
[ -x "$ASSETS/squashfs-root/usr/local/bin/lisaem" ] || die "no lisaem in the extracted AppImage"
rm -rf "$OUT/lisaem"
cp -a "$ASSETS/squashfs-root" "$OUT/lisaem"

log "GTK 3 closure from this container"
for so in libatk-1.0.so.0 libatk-bridge-2.0.so.0 libatspi.so.0 libgdk-3.so.0 libgtk-3.so.0 libjpeg.so.8; do
  [ -e "/lib/x86_64-linux-gnu/$so" ] || die "missing /lib/x86_64-linux-gnu/$so on this container (apt: libgtk-3-0t64 libatk-bridge2.0-0t64 libjpeg8)"
  cp -L "/lib/x86_64-linux-gnu/$so" "$OUT/lib/"
done
cp -L /usr/lib/x86_64-linux-gnu/gconv/UTF-32.so "$OUT/lib/gconv/"

log "boot ROM rev H from the MAME lisa2 halves"
python3 - "$ASSETS/rom/$ROMSET" "$OUT/rom/lisaboot-revH.rom" <<'PY'
import sys, zipfile, zlib
z = zipfile.ZipFile(sys.argv[1])
hi, lo = z.read("341-0175-h"), z.read("341-0176-h")
assert zlib.crc32(hi) & 0xFFFFFFFF == 0xADFD4516, "341-0175-h CRC"
assert zlib.crc32(lo) & 0xFFFFFFFF == 0x546D6603, "341-0176-h CRC"
open(sys.argv[2], "wb").write(bytes(b for pair in zip(hi, lo) for b in pair))
PY
check "$OUT/rom/lisaboot-revH.rom" "$ROM_SHA"

log "golden ProFile image"
rm -rf "$ASSETS/profile7" && mkdir -p "$ASSETS/profile7"
unzip -oq "$ASSETS/$PROFILE_ZIP" -d "$ASSETS/profile7" && rm -rf "$ASSETS/profile7/__MACOSX"
check "$ASSETS/profile7/lisaem-profile.dc42" "$PROFILE_SHA"
cp "$ASSETS/profile7/lisaem-profile.dc42" "$STATION/disk/lisa-profile.dc42.golden"
unzip -oq "$ASSETS/$FLOPPIES_ZIP" -d "$ASSETS" # provenance only: five 419284-byte DC42 install floppies

log "sandbox rootfs skeleton (systemd-nspawn: read-only, the host /usr bound in at launch)"
RF="$OUT/rootfs"
mkdir -p "$RF"/{usr,etc/fonts,etc/alternatives,tmp/.X11-unix,var/tmp,run,proc,sys,dev,root,home,work} \
  "$RF/data/vms/streamhost/assets/lisa"
for l in bin sbin lib lib64; do [ -e "$RF/$l" ] || ln -s "usr/$l" "$RF/$l"; done
: >"$RF/etc/ld.so.cache"
: >"$RF/etc/localtime"
[ -f "$RF/etc/os-release" ] || cp /etc/os-release "$RF/etc/os-release"
printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >"$RF/etc/passwd"
printf 'root:x:0:\nnogroup:x:65534:\n' >"$RF/etc/group"
chmod 1777 "$RF/tmp" "$RF/var/tmp"

log "config template"
if [ -f "$ASSETS/lisaem.conf.template" ]; then
  cp "$ASSETS/lisaem.conf.template" "$OUT/lisaem.conf.template"
else
  [ -f "$OUT/lisaem.conf.template" ] || die "no lisaem.conf.template: run LisaEm once (it writes \$HOME/lisaem.conf), blank ROMFILE=/path=/dirpath=, set MemoryKB=1024, save it as $ASSETS/lisaem.conf.template"
fi

(cd "$ASSETS" && sha256sum "$APPIMAGE" "rom/$ROMSET" "$PROFILE_ZIP" "$FLOPPIES_ZIP" profile7/lisaem-profile.dc42 >MANIFEST.sha256)
log "staged: $OUT (lisaem/ lib/ rom/ rootfs/ lisaem.conf.template) and $STATION/disk/lisa-profile.dc42.golden"
