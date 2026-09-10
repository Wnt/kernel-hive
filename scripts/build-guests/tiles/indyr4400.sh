#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/indyr4400.sh — stage the HOST-NATIVE SGI Indy (MIPS R4400)
# / IRIX 6.5 station: the Iris binary, the nspawn container's rootfs skeleton,
# and the read-only IRIX disk asset. No overlay, no kiosk, no QEMU, no chroot.
#
# WHAT THIS USED TO BE, AND WHY IT ISN'T. Until the 2026-09 de-bridging this
# script built a captured Debian 12 kiosk: a thin qcow2 overlay on the shared
# bridge base, an Iris binary linked inside a bookworm debootstrap so it would
# load against the frozen guest's glibc, an /etc/bridge/launch.sh full of X
# workarounds (no window manager, so winit dropped every key until xdotool
# focused the window; `xset r off` so a late release did not trigger typematic
# repeat; llvmpipe because the host has no GPU), and an INTERNAL `savevm golden`
# checkpoint. All of it existed to carry ONE userspace emulator, and it cost the
# exhibit 361 ms of pointer latency against the host-native MAME `irix`
# sibling's 68 ms. Rule 13: the end state is host-native. The kiosk is gone, and
# with it the bridge base, the ABI chroot, the qcow2 overlay, the ssh channel on
# 5839 and the whole bookworm suite dependency.
#
# WHAT IT PRODUCES
#   $OUT/iris            the emulator binary at its HOST path — bound read-only
#                        into the container there, so /proc/<pid>/exe and the
#                        daemon's SH_IDLE_PAUSE_PROC_MATCH read the same inside
#                        and out (docs/guests/lisa.md §Sandbox)
#   $OUT/rootfs          the systemd-nspawn skeleton: mount points and symlinks
#                        only. The host's /usr is bound in read-only at launch
#                        and the root is mounted --read-only, so there is no
#                        debootstrap here and nothing in the root is writable.
#                        Every bind the launcher makes needs its mount point to
#                        EXIST in the skeleton, because a read-only root cannot
#                        have one created for it — that is why the station and
#                        asset paths below are pre-made, and the two file binds
#                        are pre-made as empty FILES.
#   the IRIX disk        staged and verified by stations/indyr4400/fetch-assets.sh
#
# THE BINARY. github.com/Wnt/iris (fork of techomancer/iris, BSD-3) built by
# scripts/build-guests/emulators/build-iris-native.sh when that exists; until
# then, point IRIS_SRC_BIN at a pre-built binary — the perf wave left
# /data/gallery-guests/IrisIndy/iris-bookworm-0540991-jitv2 staged, and a
# bookworm-linked binary runs fine on the trixie host (glibc is backward
# compatible; it was the other direction that needed the chroot).
#
# usage: indyr4400.sh [--rootfs] [--assets] [--build-iris] [-h]
#        with no flag: everything.
# =============================================================================
set -euo pipefail

TILE=indyr4400
OUT="${OUT:-/data/vms/streamhost/assets/$TILE}"
STATION="${STATION:-/data/vms/streamhost/stations/$TILE}"
ASSET_DIR="${IRISINDY_ASSETS:-/data/gallery-guests/IrisIndy}"
DISK="$ASSET_DIR/irix65-r4400-disk.raw"
IRIS_BIN="$OUT/iris"
IRIS_BUILDER="$(dirname "${BASH_SOURCE[0]}")/../emulators/build-iris-native.sh"
IRIS_SRC_BIN="${IRIS_SRC_BIN:-}"
FETCH="$(dirname "${BASH_SOURCE[0]}")/../../../streamhost/stations/$TILE/fetch-assets.sh"

DO_ROOTFS=0
DO_ASSETS=0
DO_IRIS=0
while [ $# -gt 0 ]; do case "$1" in
  --rootfs)
    DO_ROOTFS=1
    shift
    ;;
  --assets)
    DO_ASSETS=1
    shift
    ;;
  --build-iris)
    DO_IRIS=1
    shift
    ;;
  -h | --help)
    sed -n '2,45p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done
if [ $((DO_ROOTFS + DO_ASSETS + DO_IRIS)) -eq 0 ]; then
  DO_ROOTFS=1
  DO_ASSETS=1
  DO_IRIS=1
fi

log() { printf '[build:%s] %s\n' "$TILE" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

install -d -m 0755 "$OUT" "$STATION"

# ---- the emulator ------------------------------------------------------------
if [ "$DO_IRIS" -eq 1 ]; then
  # IRIS_SRC_BIN FIRST, and deliberately: an explicitly named binary is a
  # decision, and a rebuild is a default. A rig proving a build it has in hand
  # must not be sent back to the network for a different one.
  if [ -n "$IRIS_SRC_BIN" ]; then
    log "staging a pre-built binary from $IRIS_SRC_BIN"
    [ -x "$IRIS_SRC_BIN" ] || die "IRIS_SRC_BIN is not an executable: $IRIS_SRC_BIN"
    install -m 0755 "$IRIS_SRC_BIN" "$IRIS_BIN"
  elif [ -x "$IRIS_BUILDER" ]; then
    log "building the fork through $IRIS_BUILDER"
    # POSITIONAL, not IRIS_OUT: build-iris-native.sh takes its output path as
    # $1 and has no IRIX_OUT knob at all, so the env form silently built into
    # the builder's OWN default -- /data/vms/streamhost/assets/indyr4400/iris,
    # i.e. THE LIVE STATION'S BINARY -- whenever OUT was overridden for a rig.
    # Its work dir is namespaced for the same reason (concurrent agents).
    bash "$IRIS_BUILDER" "$IRIS_BIN" "${IRIS_WORK_DIR:-/data/vms/sandbox/iris-native-build}"
  else
    die "no IRIS_SRC_BIN and no $IRIS_BUILDER — nothing to stage as the emulator"
  fi
  # The binary is half of every checkpoint (rule 6: golden + binary + device set
  # are ONE combination), so record which one this is where a restore guard can
  # read it back.
  md5sum "$IRIS_BIN" | cut -d' ' -f1 >"$OUT/iris.md5"
  log "iris staged: $IRIS_BIN ($(stat -c %s "$IRIS_BIN") bytes, md5 $(cat "$OUT/iris.md5"))"
fi

# ---- the container's rootfs skeleton ----------------------------------------
if [ "$DO_ROOTFS" -eq 1 ]; then
  log "nspawn rootfs skeleton (read-only; the host's /usr is bound in at launch)"
  RF="$OUT/rootfs"
  # /state is the PERSISTENT snapshot store (the golden and its CAS chunk
  # store). It is a separate mount point from /work precisely because /work is
  # wiped on every launch — see the launcher's STATE_DIR comment.
  mkdir -p "$RF"/{usr,etc/fonts,etc/alternatives,tmp/.X11-unix,var/tmp,run,proc,sys,dev,root,work,state} \
    "$RF$OUT" "$RF$STATION/run" "$RF$STATION/state" "$RF$ASSET_DIR"
  for l in bin sbin lib lib64; do [ -e "$RF/$l" ] || ln -s "usr/$l" "$RF/$l"; done
  : >"$RF/etc/ld.so.cache"
  : >"$RF/etc/localtime"
  # The TWO FILE binds (the emulator binary and the IRIX disk) need their mount
  # points to be files, not directories — nspawn will not
  # turn one into the other, and a read-only root cannot create either. Missing
  # any one of them is `Failed to create mount point ...: Read-only file system`
  # and a container that dies before Iris ever runs.
  : >"$RF$DISK"
  : >"$RF$IRIS_BIN"
  [ -f "$RF/etc/os-release" ] || cp /etc/os-release "$RF/etc/os-release"
  printf 'root:x:0:0:root:/root:/bin/bash\nnobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin\n' >"$RF/etc/passwd"
  printf 'root:x:0:\nnogroup:x:65534:\n' >"$RF/etc/group"
  # MODES ARE EXPLICIT, NEVER THE UMASK'S. The container's root is host uid
  # $UIDBASE (--private-users), so every directory it must traverse has to be
  # o+rx. `mkdir -p` obeys the caller's umask, and a sandbox shell's 0077 leaves
  # the whole skeleton 0700 root-owned: nspawn then dies with the useless
  # "Failed to resolve /proc: Permission denied" before the payload ever runs.
  find "$RF" -type d -exec chmod 0755 {} +
  find "$RF" -type f -exec chmod 0644 {} +
  chmod 1777 "$RF/tmp" "$RF/var/tmp" "$RF/tmp/.X11-unix"
  log "skeleton: $RF"
fi

# ---- the IRIX disk -----------------------------------------------------------
if [ "$DO_ASSETS" -eq 1 ]; then
  bash "$FETCH"
  [ -f "$DISK" ] || die "fetch-assets.sh did not leave $DISK"
fi

log "done. assets: $OUT   station dir: $STATION"
log "next: emit + start through the registry row (runtime.x11.emitArgs), then"
log "      streamhost/stations/$TILE/x11-runtime.sh owns the lifecycle."
