#!/bin/bash
# build-pve-qemu-fastpoll.sh — reproduce the patched pve-qemu-kvm .deb that the
# whole station fleet runs. Despite the historical name it now carries ALL
# streamhost pve-qemu quilt patches from source, each appended after the final
# numbered pve patch and each inserted only if not already in the series:
#   0001-dbus-display-fast-poll.patch   -> pve/0047  SH_DBUS_UPDATE_MS fast-poll
#   0002-sphinx-serial-doc-build.patch  -> pve/0048  serial Sphinx build fix
#   0003-gallery-hid-device.patch       -> pve/0049  gallery-hid-pci device
# (AS FIRST BUILT 2026-07-13 in /data/vms/qemu-fastpoll-build/ on the box;
# procedure captured from its builddir*.log / dpkg-build*.log and
# streamhost/qemu-patches/README.md.)
#
#   RUN ON THE BOX (needs the pve build-dep set + ~20 min).
#   Output: $WORK/pve-qemu/pve-qemu-kvm_<ver>_amd64.deb
#
# WHY fast-poll: stations capture via `-display dbus,p2p=on`; stock QEMU polls the
# guest framebuffer every 30 ms. The patch (streamhost/qemu-patches/
# 0001-dbus-display-fast-poll.patch) adds the SH_DBUS_UPDATE_MS knob (1..29 ms,
# inert when unset) + a run-state idle gate. An upstream QEMU can't `loadvm
# golden` (pve-only pbs-state vmstate section), so it MUST ship as a pve-qemu
# quilt patch after the final numbered pve patch.
#
# WHY gallery-hid: solaris streams input over a bespoke PCI device (1b36:0015,
# class ff00, BAR0 regs + BAR2 GLIN ring; streamhost/qemu-patches/gallery-hid/).
# 0003 adds ONLY that optional device (guarded by CONFIG_GALLERY_HID) plus its
# qtest, so the rebuilt binary is a superset of the fleet binary — every existing
# station behaves identically, solaris additionally gets `-device gallery-hid-pci`.
# It ships as a quilt patch (not the old standalone qemu-gallery-hid binary) so it
# survives QEMU version bumps and is built from source alongside fast-poll.
#
# ORIGINAL VALIDATED PINS (for reference only; defaults resolve the installed
# package version now):
#   pve-qemu git   684796e835289dab11af8606fbf7358b93526dd6  "bump version to 11.0.0-3"
#   qemu submodule 98b060da3a4f92b2a994ead5b16a87e783baf77c  (auto: pinned by the above)
# By default the script finds the pve-qemu commit whose debian/changelog version
# exactly matches the installed pve-qemu-kvm package, derives the next quilt
# number after the final pve/NNNN patch, and verifies both fast-poll code paths
# in the assembled tree. PVE_QEMU_REF may override source selection explicitly.
#
# ROLLOUT (after the deb builds) — see streamhost/qemu-patches/README.md §
# "Production rollout": stage the stock same-version .deb as rollback first,
# dpkg -i the patched deb (running QEMUs keep the old binary until relaunch),
# then canary one station before the fleet. The per-station relaunch procedure the
# 2026-07-13 fleet cutover used (knob injection + qcap-scope handling +
# loadvm-golden verify) is vendored at streamhost/qemu-patches/rollout-fastpoll.sh.
set -euo pipefail

PVE_QEMU_VERSION="${PVE_QEMU_VERSION:-$(dpkg-query -W -f='${Version}' pve-qemu-kvm)}"
PVE_QEMU_REF="${PVE_QEMU_REF:-${PVE_QEMU_COMMIT:-}}"
WORK="${WORK:-/data/vms/qemu-fastpoll-build.$$}"
JOBS="${JOBS:-$(nproc)}"
NICE_LEVEL="${NICE_LEVEL:-15}"
CEPH_RELEASE="${CEPH_RELEASE:-squid}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
QEMU_PATCH_DIR="$HERE/../streamhost/qemu-patches"
# Published fork submodule (github.com/Wnt/qemu, branch `kernel-hive`): the
# same three patches also land as standalone commits there, in order
# (fast-poll, sphinx, gallery-hid). If it's checked out, regenerate the loose
# patch files from its commits with `git format-patch` instead of reading the
# committed .patch files directly -- both paths produce the same text, the
# submodule is just the published, reviewable form. See
# streamhost/qemu-patches/README.md "Patch vs. fork" for which one to edit.
QEMU_SUBMODULE="$REPO_ROOT/third_party/qemu-kernel-hive"
log() { printf '[fastpoll-deb] %s\n' "$*"; }

mkdir -p "$WORK"

if [ -e "$QEMU_SUBMODULE/.git" ]; then
  log "regenerating the patch trio from the published qemu-kernel-hive submodule (kernel-hive branch)"
  git -C "$QEMU_SUBMODULE" fetch -q origin kernel-hive 2>/dev/null || true
  mkdir -p "$WORK/submodule-patches"
  PATCH="$WORK/submodule-patches/0001-dbus-display-fast-poll.patch"
  DOCS_PATCH="$WORK/submodule-patches/0002-sphinx-serial-doc-build.patch"
  GHID_PATCH="$WORK/submodule-patches/0003-gallery-hid-device.patch"
  fp() {
    git -C "$QEMU_SUBMODULE" log --format='%H' origin/kernel-hive |
      while read -r sha; do
        subj="$(git -C "$QEMU_SUBMODULE" log -1 --format='%s' "$sha")"
        case "$subj" in
          "$1"*) echo "$sha" && break ;;
        esac
      done
  }
  git -C "$QEMU_SUBMODULE" format-patch -1 --stdout \
    "$(fp 'ui/dbus,ui/console:')" >"$PATCH"
  git -C "$QEMU_SUBMODULE" format-patch -1 --stdout \
    "$(fp 'docs: build Sphinx')" >"$DOCS_PATCH"
  git -C "$QEMU_SUBMODULE" format-patch -1 --stdout \
    "$(fp 'hw/misc: add gallery-hid-pci')" >"$GHID_PATCH"
else
  log "submodule not initialized at $QEMU_SUBMODULE -- falling back to the committed loose patch files"
  log "run 'git submodule update --init third_party/qemu-kernel-hive' to build from the published fork instead"
  PATCH="${PATCH:-$QEMU_PATCH_DIR/0001-dbus-display-fast-poll.patch}"
  DOCS_PATCH="${DOCS_PATCH:-$QEMU_PATCH_DIR/0002-sphinx-serial-doc-build.patch}"
  GHID_PATCH="${GHID_PATCH:-$QEMU_PATCH_DIR/0003-gallery-hid-device.patch}"
fi

for p in "$PATCH" "$DOCS_PATCH" "$GHID_PATCH"; do
  [ -f "$p" ] || {
    echo "patch not found: $p" >&2
    exit 1
  }
done

RADOS_VERSION="$(dpkg-query -W -f='${Version}' librados2)"
RBD_VERSION="$(dpkg-query -W -f='${Version}' librbd1)"
if ! apt-cache show "librados-dev=$RADOS_VERSION" 2>/dev/null | grep -q '^Package:' ||
  ! apt-cache show "librbd-dev=$RBD_VERSION" 2>/dev/null | grep -q '^Package:'; then
  . /etc/os-release
  CEPH_REPO_FILE="/etc/apt/sources.list.d/ceph-${CEPH_RELEASE}-no-subscription.sources"
  log "configure Ceph $CEPH_RELEASE no-subscription repo for matching dev libraries"
  {
    printf 'Types: deb\n'
    printf 'URIs: http://download.proxmox.com/debian/ceph-%s\n' "$CEPH_RELEASE"
    printf 'Suites: %s\n' "$VERSION_CODENAME"
    printf 'Components: no-subscription\n'
    printf 'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg\n'
  } >"$CEPH_REPO_FILE"
  apt-get update
fi

log "bootstrap source checkout and exact Ceph development libraries"
apt-get install -y --no-install-recommends git dpkg-dev \
  "librbd-dev=$RBD_VERSION" "librados-dev=$RADOS_VERSION" \
  >"$WORK/build-deps.log" 2>&1 || {
  tail -50 "$WORK/build-deps.log" >&2
  echo "NOTE: bootstrap failed; librbd/librados-dev were pinned to installed" >&2
  echo "runtime versions $RBD_VERSION / $RADOS_VERSION via Ceph $CEPH_RELEASE." >&2
  exit 1
}
tail -1 "$WORK/build-deps.log"

log "clone pve-qemu packaging (no deb-src exists for Proxmox)"
cd "$WORK"
[ -d pve-qemu ] || git clone https://git.proxmox.com/git/pve-qemu.git
cd pve-qemu

if [ -z "$PVE_QEMU_REF" ]; then
  log "resolve pve-qemu source for installed version $PVE_QEMU_VERSION"
  while IFS= read -r commit; do
    version="$(git show "$commit:debian/changelog" |
      sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p')"
    if [ "$version" = "$PVE_QEMU_VERSION" ]; then
      PVE_QEMU_REF="$commit"
      break
    fi
  done < <(git log --format=%H --all -- debian/changelog)
  [ -n "$PVE_QEMU_REF" ] || {
    echo "no pve-qemu commit found for installed version $PVE_QEMU_VERSION" >&2
    exit 1
  }
fi
log "checkout pve-qemu @ $PVE_QEMU_REF"
git checkout -q "$PVE_QEMU_REF"
log "install Build-Depends from the matched debian/control"
apt-get build-dep -y --no-install-recommends ./ >>"$WORK/build-deps.log" 2>&1 || {
  tail -80 "$WORK/build-deps.log" >&2
  exit 1
}
tail -1 "$WORK/build-deps.log"
git submodule update --init --recursive # qemu @ the pinned mirror commit (slow: roms/edk2 etc.)

VER="$(dpkg-parsechangelog -l debian/changelog -S Version)" # e.g. 11.0.0-3
UPSTREAM="${VER%-*}"
log "packaging version $VER (upstream $UPSTREAM)"
[ "$VER" = "$PVE_QEMU_VERSION" ] || {
  echo "source version $VER does not match requested/installed $PVE_QEMU_VERSION" >&2
  exit 1
}

PATCH_REL="$(sed -n '/streamhost-dbus-display-fast-poll\.patch$/p' debian/patches/series | tail -1)"
if [ -z "$PATCH_REL" ]; then
  LAST_PVE_REL="$(sed -n '/^pve\/[0-9][0-9][0-9][0-9]-.*\.patch$/p' \
    debian/patches/series | tail -1)"
  [ -n "$LAST_PVE_REL" ] || {
    echo "cannot determine final numbered pve patch in debian/patches/series" >&2
    exit 1
  }
  LAST_PVE_NO="$(basename "$LAST_PVE_REL" | cut -d- -f1)"
  printf -v PATCH_NO '%04d' "$((10#$LAST_PVE_NO + 1))"
  PATCH_REL="pve/${PATCH_NO}-streamhost-dbus-display-fast-poll.patch"
  log "insert fast-poll after $LAST_PVE_REL as $PATCH_REL"
  install -m 0644 "$PATCH" "debian/patches/$PATCH_REL"
  echo "$PATCH_REL" >>debian/patches/series
else
  log "reuse existing fast-poll series entry $PATCH_REL"
  install -m 0644 "$PATCH" "debian/patches/$PATCH_REL"
fi

DOCS_PATCH_REL="$(sed -n '/streamhost-sphinx-serial-doc-build\.patch$/p' \
  debian/patches/series | tail -1)"
if [ -z "$DOCS_PATCH_REL" ]; then
  PATCH_NO="$(basename "$PATCH_REL" | cut -d- -f1)"
  printf -v DOCS_PATCH_NO '%04d' "$((10#$PATCH_NO + 1))"
  DOCS_PATCH_REL="pve/${DOCS_PATCH_NO}-streamhost-sphinx-serial-doc-build.patch"
  log "insert serial Sphinx build fix as $DOCS_PATCH_REL"
  install -m 0644 "$DOCS_PATCH" "debian/patches/$DOCS_PATCH_REL"
  echo "$DOCS_PATCH_REL" >>debian/patches/series
else
  log "reuse existing serial Sphinx series entry $DOCS_PATCH_REL"
  install -m 0644 "$DOCS_PATCH" "debian/patches/$DOCS_PATCH_REL"
fi

GHID_PATCH_REL="$(sed -n '/streamhost-gallery-hid-device\.patch$/p' \
  debian/patches/series | tail -1)"
if [ -z "$GHID_PATCH_REL" ]; then
  PATCH_NO="$(basename "$DOCS_PATCH_REL" | cut -d- -f1)"
  printf -v GHID_PATCH_NO '%04d' "$((10#$PATCH_NO + 1))"
  GHID_PATCH_REL="pve/${GHID_PATCH_NO}-streamhost-gallery-hid-device.patch"
  log "insert gallery-hid device as $GHID_PATCH_REL"
  install -m 0644 "$GHID_PATCH" "debian/patches/$GHID_PATCH_REL"
  echo "$GHID_PATCH_REL" >>debian/patches/series
else
  log "reuse existing gallery-hid series entry $GHID_PATCH_REL"
  install -m 0644 "$GHID_PATCH" "debian/patches/$GHID_PATCH_REL"
fi

log "make pve-qemu-kvm-$UPSTREAM (assembles the source tree)"
nice -n "$NICE_LEVEL" make "pve-qemu-kvm-$UPSTREAM" 2>&1 | tee "$WORK/make-source.log"

ASSEMBLED="pve-qemu-kvm-$UPSTREAM"
cd "$ASSEMBLED"
log "apply the complete quilt series, incl. $PATCH_REL, $DOCS_PATCH_REL, $GHID_PATCH_REL"
QUILT_PATCHES=debian/patches quilt push -a 2>&1 | tee "$WORK/quilt-apply.log"
grep -Fq 'getenv("SH_DBUS_UPDATE_MS")' ui/dbus-listener.c
grep -Fq 'interval < GUI_REFRESH_INTERVAL_DEFAULT && !runstate_is_running()' ui/console.c
log "verified SH_DBUS_UPDATE_MS listener path and run-state idle gate in patched source"
test -f hw/misc/gallery-hid-pci.c
test -f include/hw/misc/gallery-hid.h
grep -Fq "CONFIG_GALLERY_HID" hw/misc/meson.build
grep -Fq "config GALLERY_HID" hw/misc/Kconfig
log "verified gallery-hid-pci device sources and Kconfig/meson wiring in patched source"

log "download Meson subprojects required by the packaging --disable-download configure"
meson subprojects download 2>&1 | tee "$WORK/meson-subprojects.log"

log "dpkg-buildpackage (parallel=$JOBS nocheck; nice=$NICE_LEVEL; ~20 min)"
DEB_BUILD_OPTIONS="parallel=$JOBS nocheck" \
  nice -n "$NICE_LEVEL" dpkg-buildpackage -b -us -uc 2>&1 | tee "$WORK/dpkg-build.log"

cd ..
ls -la ./pve-qemu-kvm_*_amd64.deb
{
  printf 'version=%s\n' "$VER"
  printf 'pve_qemu_commit=%s\n' "$(git -C "$WORK/pve-qemu" rev-parse HEAD)"
  printf 'qemu_commit=%s\n' "$(git -C "$WORK/pve-qemu/qemu" rev-parse HEAD)"
  printf 'patch=%s\n' "$PATCH_REL"
  printf 'docs_patch=%s\n' "$DOCS_PATCH_REL"
  printf 'ghid_patch=%s\n' "$GHID_PATCH_REL"
  printf 'nice_level=%s\n' "$NICE_LEVEL"
} >"$WORK/fastpoll-build-metadata.txt"
log "DONE. Next (gated): keep a stock ${VER} .deb as rollback, dpkg -i the new deb,"
log "then per-tile relaunch via streamhost/qemu-patches/rollout-fastpoll.sh (canary first)."
