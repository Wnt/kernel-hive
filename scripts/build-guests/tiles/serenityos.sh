#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/serenityos.sh
#
# FROM-SOURCE reproducer for the "SerenityOS" Kernel Hive guest.
# Rebuilds the guest end-to-end on a FRESH Proxmox host that already has the
# gallery infra (ZFS pool `data`, `/data/gallery-guests/`, qemu-system-x86_64).
# NO image backup is used -- everything is compiled from git source.
#
# WHAT IT DOES (fully automated, no interactive step):
#   1. Ensures an ISOLATED privileged build LXC (default CTID 112), Debian 13,
#      nesting=1, and installs the SerenityOS build dependencies.
#   2. git-clones SerenityOS from the REAL upstream URL (re-download every run)
#      and checks out a pinned known-good commit.
#   3. Builds the GCC cross-toolchain + the whole OS as the unprivileged
#      `builder` user via SerenityOS' own Meta/serenity.sh (this also
#      re-downloads the binutils/gcc source tarballs from upstream).
#   4. Assembles the raw ext2 root disk via Meta/build-image-qemu.sh -- run as
#      ROOT so the genext2fs path's chown/setuid steps succeed (the ONE thing
#      the original ad-hoc run got wrong: it ran the image step as `builder`
#      and died on `chown: Operation not permitted`). Loop/fuse mount is
#      unavailable in an LXC, so build-image-qemu.sh auto-falls-back to
#      genext2fs; running it as root makes that fallback actually complete.
#   4c. Adds VISIBLE desktop shortcuts (fast symlinks in /home/anon/Desktop ->
#      /bin/<App>, owned by anon) for the shipped games (Solitaire, Minesweeper,
#      Snake, Chess, 2048, Spider) + Calculator & PixelPaint, via debugfs offline,
#      so a first-time viewer sees launchable icons, not a bare desktop. All
#      targets are built-in BSD-2-licensed SerenityOS apps (nothing downloaded).
#   5. Pulls the artifacts (Kernel/Kernel, Kernel/Kernel.efi, _disk_image) to
#      /data/gallery-guests/SerenityOS/, writes boot.sh + MANIFEST.md.
#   6. Framebuffer-verifies: boots headless (multiboot kernel + NVMe ext2 root)
#      on a unique VNC/QMP socket, waits for WindowServer, captures a screenshot,
#      then shuts down cleanly (QMP quit, fallback: kill by pidfile).
#
# AUTOMATION HONESTY: this build is 100% automated -- there is NO autounattend,
# no sendkey macro, no vncdotool click, no one-time interactive step. The guest
# boots straight to its desktop. The only "cost" is that it is HEAVY: the
# toolchain+OS compile takes ~20-60 min and wants many cores + lots of RAM.
#
# HYGIENE: creates/uses only its own build CT and its own namespaced Unix
# VNC/QMP/pidfile under WORK_DIR. It NEVER pkills by name, and it refuses
# to touch the osgallery CT (110) or any VM. Kills only via QMP quit or the
# pidfile it wrote. Idempotent + re-runnable.
#
# Streamhost-equivalent runtime args are emitted at the end (also in MANIFEST.md).
###############################################################################
set -euo pipefail

# ---------------------------------------------------------------------------
# Parameters (override via env)
# ---------------------------------------------------------------------------
KEY="serenityos"
GUEST_DIR_NAME="SerenityOS"
OUT_DIR="${OUT_DIR:-${SERENITY_OUT_DIR:-/data/gallery-guests/${GUEST_DIR_NAME}}}"
WORK_DIR="${WORK_DIR:-${OUT_DIR}/.build-work}"

# --- build LXC ---
CTID="${SERENITY_CTID:-112}"
CT_HOSTNAME="${SERENITY_CT_HOSTNAME:-serenity-build}"
CT_MEMORY_MB="${SERENITY_CT_MEMORY_MB:-32768}" # GCC + OS build is RAM-hungry
CT_CORES="${SERENITY_CT_CORES:-16}"            # parallel ninja
CT_ROOTFS_GB="${SERENITY_CT_ROOTFS_GB:-25}"    # build tree ~7 GB + toolchain
CT_STORAGE="${SERENITY_CT_STORAGE:-data}"      # Proxmox storage id for the CT rootfs
CT_BRIDGE="${SERENITY_CT_BRIDGE:-vmbr0}"
CT_TEMPLATE_STORE="${SERENITY_CT_TEMPLATE_STORE:-local}"
CT_TEMPLATE="${SERENITY_CT_TEMPLATE:-debian-13-standard_13.6-1_amd64.tar.zst}"

# --- SerenityOS source ---
SERENITY_REPO="${SERENITY_REPO:-https://github.com/SerenityOS/serenity.git}"
# Pinned to the exact commit that produced the shipped guest (2026-07-02).
# Set SERENITY_REF=master to track upstream (may drift / break).
SERENITY_REF="${SERENITY_REF:-55c5f6336d074a8fa2402fc897e859a9b7458ceb}"
ARCH="x86_64"
BUILD_USER="builder"
SRC="/home/${BUILD_USER}/serenity"

# --- verification ---
VNC_TARGET="${SERENITY_VNC_TARGET:-unix:${WORK_DIR}/vnc.sock}"
BOOT_ACCEL="${SERENITY_ACCEL:-kvm}"              # kvm (~2s) or tcg (slower, portable)
VERIFY="${SERENITY_VERIFY:-1}"                   # set 0 to skip the boot test
VERIFY_TIMEOUT="${SERENITY_VERIFY_TIMEOUT:-180}" # seconds to reach WindowServer
DESKTOP_SETTLE="${SERENITY_DESKTOP_SETTLE:-12}"  # finish desktop/terminal paint

# ---------------------------------------------------------------------------
# Guardrails: never clobber protected guests
# ---------------------------------------------------------------------------
for protected in 110 900 920; do
  if [[ "$CTID" == "$protected" ]]; then
    echo "REFUSING: CTID $CTID is a protected guest (osgallery/VMs). Pick another SERENITY_CTID." >&2
    exit 2
  fi
done

log() { printf '\n=== %s ===\n' "$*"; }
in_ct_root() { pct exec "$CTID" -- bash -lc "$1"; }
in_ct_builder() { pct exec "$CTID" -- runuser -u "$BUILD_USER" -- bash -lc "$1"; }

mkdir -p "$OUT_DIR" "$WORK_DIR"

# ---------------------------------------------------------------------------
# 1. Ensure the isolated build LXC exists and is running
# ---------------------------------------------------------------------------
log "1. Build LXC (CTID $CTID)"
if pct status "$CTID" >/dev/null 2>&1; then
  echo "CT $CTID already exists -- reusing."
else
  # Make sure the template is present (download from the Proxmox mirror if not).
  if ! pveam list "$CT_TEMPLATE_STORE" 2>/dev/null | grep -q "$CT_TEMPLATE"; then
    echo "Downloading template $CT_TEMPLATE ..."
    pveam update || true
    pveam download "$CT_TEMPLATE_STORE" "$CT_TEMPLATE"
  fi
  echo "Creating privileged CT $CTID (nesting=1) ..."
  pct create "$CTID" "${CT_TEMPLATE_STORE}:vztmpl/${CT_TEMPLATE}" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY_MB" \
    --swap 0 \
    --rootfs "${CT_STORAGE}:${CT_ROOTFS_GB}" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=dhcp" \
    --features nesting=1 \
    --ostype debian \
    --unprivileged 0 \
    --onboot 0
  # NB: privileged (--unprivileged 0) is REQUIRED so the root-run genext2fs
  # image step can chown files to uid 0 and set setuid bits inside the image.
fi

if [[ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]]; then
  echo "Starting CT $CTID ..."
  pct start "$CTID"
fi

# Wait for network (DHCP + DNS) inside the CT.
echo "Waiting for CT network ..."
for i in $(seq 1 30); do
  if in_ct_root "getent hosts github.com >/dev/null 2>&1"; then break; fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 2. Install build dependencies (idempotent)
# ---------------------------------------------------------------------------
log "2. Build dependencies"
in_ct_root '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build ccache curl unzip rsync texinfo \
    libmpfr-dev libmpc-dev libgmp-dev libssl-dev \
    e2fsprogs genext2fs fuse2fs git python3 qemu-utils sudo ca-certificates zlib1g-dev
  id '"$BUILD_USER"' >/dev/null 2>&1 || useradd -m -s /bin/bash '"$BUILD_USER"'
'

# ---------------------------------------------------------------------------
# 3. Clone SerenityOS from upstream + check out the pinned commit
# ---------------------------------------------------------------------------
log "3. Clone SerenityOS ($SERENITY_REF)"
in_ct_builder '
  set -e
  if [ -d '"$SRC"'/.git ]; then
    cd '"$SRC"'
    git fetch --all --tags --prune
  else
    git clone '"$SERENITY_REPO"' '"$SRC"'
    cd '"$SRC"'
  fi
  git checkout --force '"$SERENITY_REF"'
  git submodule update --init --recursive || true
  git log -1 --format="checked out %H (%ci)"
'

# ---------------------------------------------------------------------------
# 4a. Build toolchain + OS as the UNPRIVILEGED builder user.
#     Meta/serenity.sh build compiles the GCC cross-toolchain (re-downloading
#     the binutils/gcc tarballs), builds every binary, and runs `install` to
#     populate Build/x86_64/Root. It will also *attempt* the disk-image step
#     and fail there as non-root (chown EPERM) -- that failure is EXPECTED and
#     harmless; we redo the image step as root next. We therefore tolerate a
#     non-zero exit here and gate on the Kernel artifact actually existing.
# ---------------------------------------------------------------------------
log "4a. Compile toolchain + OS (as $BUILD_USER)"
# shellcheck disable=SC2016 # deliberate: $HOME/etc inside the single-quoted body are meant to expand INSIDE the container (in_ct_builder), not here; $SRC/$ARCH are spliced in via the '"$VAR"' concatenation trick
in_ct_builder '
  cd '"$SRC"'
  export SERENITY_ARCH='"$ARCH"'
  export CCACHE_DIR=$HOME/.ccache
  # Meta/serenity.sh treats an existing Local/<arch> directory as a finished
  # toolchain. Recover safely if a prior interrupted build left it half-built.
  if [ -d Toolchain/Local/'"$ARCH"' ] && \
     [ ! -x Toolchain/Local/'"$ARCH"'/bin/'"$ARCH"'-serenity-ld ]; then
    echo "Removing incomplete '"$ARCH"' cross-toolchain from a prior run..."
    rm -rf Toolchain/Local/'"$ARCH"' Toolchain/Build/'"$ARCH"'
  fi
  # Do not let a failed incremental build pass by finding a stale prior Kernel.
  rm -f Build/'"$ARCH"'/Kernel/Kernel
  # Non-zero exit tolerated: the trailing qemu-image target fails as non-root.
  Meta/serenity.sh build '"$ARCH"' || echo "serenity.sh build returned non-zero (expected at the image step); verifying binaries..."
  test -f Build/'"$ARCH"'/Kernel/Kernel || { echo "FATAL: Kernel not built" >&2; exit 1; }
  # Ensure Root/ is fully populated before we pack the image.
  ninja -C Build/'"$ARCH"' install
  echo "Kernel + Root ready."
'

# ---------------------------------------------------------------------------
# 4b. Assemble the raw ext2 root disk as ROOT via build-image-qemu.sh.
#     This is the exact ninja invocation SerenityOS uses, minus ninja:
#       cmake -E env SERENITY_SOURCE_DIR=... SERENITY_ARCH=x86_64 \
#             SERENITY_TOOLCHAIN=GNU Meta/build-image-qemu.sh
#     Loop/fuse mount is blocked in the LXC, so the script auto-falls-back to
#     the genext2fs path. Running as root makes build-root-filesystem.sh's
#     chown/setuid steps succeed, producing a proper root-owned 1.5 GB image.
#     `setsid` detaches it from any controlling terminal so a stray signal
#     cannot kill the finalize step mid-run (the original build's failure mode).
# ---------------------------------------------------------------------------
log "4b. Pack disk image via genext2fs (as root)"
in_ct_root '
  set -e
  cd '"$SRC"'/Build/'"$ARCH"'
  rm -f _disk_image
  setsid env SERENITY_SOURCE_DIR='"$SRC"' SERENITY_ARCH='"$ARCH"' SERENITY_TOOLCHAIN=GNU \
    '"$SRC"'/Meta/build-image-qemu.sh
  test -s _disk_image || { echo "FATAL: _disk_image not produced" >&2; exit 1; }
  ls -l _disk_image Kernel/Kernel
'

# ---------------------------------------------------------------------------
# 4c. Surface the shipped games + a couple of apps as VISIBLE desktop shortcuts.
#     SerenityOS renders ~/Desktop (FileManager in desktop mode) and launches a
#     double-clicked entry through LaunchServer. The stock image ships only four
#     shortcuts (Browser, Text Editor, Help, Home); a first-time gallery viewer
#     would otherwise never see the built-in games. We add the shipped games
#     (Solitaire, Minesweeper, Snake, Chess, 2048, Spider) plus Calculator &
#     PixelPaint as fast symlinks in /home/anon/Desktop -> /bin/<App>, owned by
#     anon (uid/gid 100), mode 0777 -- identical in form to the stock shortcuts,
#     so FileManager resolves each to the correct app icon and double-click runs
#     the target. Every target is a built-in, BSD-2-licensed SerenityOS app that
#     is already in the image (nothing is downloaded or staged).
#
#     Done OFFLINE with debugfs (already installed as a build dep) directly on
#     the packed _disk_image: NO loop/fuse mount (blocked in the LXC anyway) and
#     therefore NO risk of the host ext4 driver upgrading the plain-ext2 feature
#     set that SerenityOS' Ext2FS understands. Idempotent: existing shortcuts are
#     left untouched. This exactly reproduces the manual edit applied to the
#     shipped golden on 2026-07-06.
# ---------------------------------------------------------------------------
log "4c. Add visible desktop shortcuts for the built-in games + apps"
# shellcheck disable=SC2016 # deliberate: this body is meant to expand INSIDE the container (in_ct_root); $SRC/$ARCH are spliced in via the '"$VAR"' concatenation trick
in_ct_root '
  set -e
  IMG='"$SRC"'/Build/'"$ARCH"'/_disk_image
  for pair in \
    "Solitaire:/bin/Solitaire" \
    "Minesweeper:/bin/Minesweeper" \
    "Snake:/bin/Snake" \
    "Chess:/bin/Chess" \
    "2048:/bin/2048" \
    "Spider:/bin/Spider" \
    "Calculator:/bin/Calculator" \
    "PixelPaint:/bin/PixelPaint"; do
    name="${pair%%:*}"; target="${pair#*:}"
    # Idempotent: skip if the shortcut already exists (e.g. re-run, or upstream added it).
    # debugfs itself exits 0 even when ext2_lookup reports "File not found";
    # require the stat output Inode field before treating an entry as present.
    if debugfs -R "stat /home/anon/Desktop/$name" "$IMG" 2>&1 | grep -q "^Inode:"; then
      echo "shortcut already present, skipping: $name"; continue
    fi
    debugfs -w -R "symlink /home/anon/Desktop/$name $target" "$IMG" >/dev/null 2>&1
    debugfs -w -R "sif /home/anon/Desktop/$name uid 100" "$IMG" >/dev/null 2>&1
    debugfs -w -R "sif /home/anon/Desktop/$name gid 100" "$IMG" >/dev/null 2>&1
    echo "desktop shortcut: $name -> $target"
  done
  echo "Desktop entries now:"; debugfs -R "ls /home/anon/Desktop" "$IMG" 2>/dev/null
  # Sanity: the fs must still be clean plain-ext2 after the offline edit.
  e2fsck -fn "$IMG" >/dev/null 2>&1 && echo "e2fsck: clean" || { echo "FATAL: e2fsck failed after shortcut edit" >&2; exit 1; }
'

# ---------------------------------------------------------------------------
# 4d. Set the WindowServer display resolution to 1920x1080 (16:9, full-era).
#     WindowServer reads [Screen0] Width/Height from /etc/WindowServer.ini at
#     start. The stock build ships 1024x768; the gallery station runs the single-head
#     BochsDisplay/VBE packed framebuffer (QEMU -vga std, default 16 MB vgamem
#     covers 1920x1080x32bpp = 7.9 MB), which the display path drives 1:1 (see
#     docs/lab/tile-resolution-responsiveness.md). Done OFFLINE with debugfs on
#     the packed _disk_image (no loop/fuse mount, same as step 4c), preserving the
#     file's uid/gid/mode. Idempotent. e2fsck confirms the fs stays plain ext2.
# ---------------------------------------------------------------------------
log "4d. Set WindowServer display resolution to 1920x1080 (single head)"
# shellcheck disable=SC2016 # deliberate: this body expands INSIDE the container (in_ct_root); $SRC/$ARCH are spliced in via the '"$VAR"' concatenation trick
in_ct_root '
  set -e
  IMG='"$SRC"'/Build/'"$ARCH"'/_disk_image
  TMP="$(mktemp)"
  debugfs -R "dump /etc/WindowServer.ini $TMP" "$IMG" >/dev/null 2>&1
  # Rewrite Width/Height (only [Screen0] carries them; [Workspaces] uses Rows/Columns).
  sed -e "s/^Width=[0-9]*/Width=1920/" -e "s/^Height=[0-9]*/Height=1080/" "$TMP" >"$TMP.new"
  if cmp -s "$TMP" "$TMP.new"; then
    echo "WindowServer.ini already at target resolution, skipping"
  else
    # Preserve the original owner/mode across the debugfs rm+write (window user = 13).
    uid="$(debugfs -R "stat /etc/WindowServer.ini" "$IMG" 2>/dev/null | grep -oE "User: +[0-9]+" | grep -oE "[0-9]+")"
    gid="$(debugfs -R "stat /etc/WindowServer.ini" "$IMG" 2>/dev/null | grep -oE "Group: +[0-9]+" | grep -oE "[0-9]+")"
    debugfs -w "$IMG" >/dev/null 2>&1 <<EOF
rm /etc/WindowServer.ini
write $TMP.new /etc/WindowServer.ini
sif /etc/WindowServer.ini uid ${uid:-13}
sif /etc/WindowServer.ini gid ${gid:-13}
sif /etc/WindowServer.ini mode 0100664
EOF
    echo "WindowServer.ini resolution set to 1920x1080 (owner ${uid:-13}:${gid:-13})"
  fi
  debugfs -R "cat /etc/WindowServer.ini" "$IMG" 2>/dev/null | grep -E "^(Width|Height)="
  e2fsck -fn "$IMG" >/dev/null 2>&1 && echo "e2fsck: clean" || { echo "FATAL: e2fsck failed after resolution edit" >&2; exit 1; }
'

# ---------------------------------------------------------------------------
# 5. Pull artifacts to the gallery guest dir
# ---------------------------------------------------------------------------
log "5. Copy artifacts to $OUT_DIR"
mkdir -p "$OUT_DIR/Kernel"
pct pull "$CTID" "$SRC/Build/$ARCH/_disk_image" "$OUT_DIR/_disk_image"
pct pull "$CTID" "$SRC/Build/$ARCH/Kernel/Kernel" "$OUT_DIR/Kernel/Kernel"
# Kernel.efi is optional (unused by the multiboot boot path) -- copy if present.
EFI_KERNEL="$SRC/Build/$ARCH/Kernel/EFIPrekernel/Kernel.efi"
if in_ct_root "test -f $EFI_KERNEL"; then
  pct pull "$CTID" "$EFI_KERNEL" "$OUT_DIR/Kernel/Kernel.efi"
fi
echo "Artifacts:"
ls -l "$OUT_DIR" "$OUT_DIR/Kernel"

# ---------------------------------------------------------------------------
# 5b. Write the headless boot script (used for verify + as the run recipe)
# ---------------------------------------------------------------------------
cat >"$OUT_DIR/boot.sh" <<'BOOTSH'
#!/bin/bash
# Boot SerenityOS x86_64 headlessly for framebuffer capture.
# Kernel loaded via QEMU multiboot (-kernel); the root disk is attached as NVMe.
#
# CRITICAL: SerenityOS mounts its Ext2FS root READ-WRITE. Booting the golden
# _disk_image directly therefore MUTATES it, and a hard kill mid-write CORRUPTS the
# ext2 superblock (this is exactly what happened to the first shipped image: its
# build verify booted the golden rw, got killed, and left a bad-magic superblock so
# every later boot panicked at StorageManagement::create_first_vfs_root_context).
# So we NEVER boot the golden directly: we boot a FRESH throwaway copy-on-write
# qcow2 overlay backed by the read-only _disk_image. The golden stays pristine, and
# the writable footprint is only tens of KB. The streamhost station does the same
# on every launch (see streamhost/stations-manifest.sh).
set -e
BASE="$(cd "$(dirname "$0")" && pwd)"
VNC_TARGET=${1:-unix:${BASE}/.build-work/vnc.sock}
ACCEL=${2:-kvm}
RUN_DIR=${3:-${BASE}/.build-work}
mkdir -p "$RUN_DIR"
rm -f "$RUN_DIR/qmp-sock" "$RUN_DIR/vnc.sock" "$RUN_DIR/debug.log" \
  "$RUN_DIR/serial.log" "$RUN_DIR/qemu.log" "$RUN_DIR/qemu.pid" \
  "$RUN_DIR/verify-overlay.qcow2"
# writable CoW overlay over the read-only golden raw (golden is never written)
qemu-img create -q -f qcow2 -F raw -b "$BASE/_disk_image" "$RUN_DIR/verify-overlay.qcow2"
nice -n 15 ionice -c3 qemu-system-x86_64 \
  -accel "${ACCEL}" \
  -machine q35 \
  -cpu host \
  -m 2G \
  -smp 2 \
  -rtc base=localtime \
  -kernel "$BASE/Kernel/Kernel" \
  -append "root=nvme0:1:0" \
  -drive file="$RUN_DIR/verify-overlay.qcow2",if=none,format=qcow2,id=boot-drive \
  -device i82801b11-bridge,id=bridge4 \
  -device nvme,serial=deadbeef,drive=boot-drive,bus=bridge4,logical_block_size=4096,physical_block_size=4096 \
  -vga std \
  -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
  -display none \
  -vnc "$VNC_TARGET" \
  -qmp unix:"$RUN_DIR/qmp-sock",server,nowait \
  -debugcon file:"$RUN_DIR/debug.log" \
  -serial file:"$RUN_DIR/serial.log" \
  -name SerenityOS \
  -d guest_errors \
  >"$RUN_DIR/qemu.log" 2>&1 &
echo $! > "$RUN_DIR/qemu.pid"
echo "started SerenityOS pid $(cat "$RUN_DIR/qemu.pid") on VNC ${VNC_TARGET}"
BOOTSH
chmod +x "$OUT_DIR/boot.sh"

# ---------------------------------------------------------------------------
# 5c. Write MANIFEST.md (build provenance + neko-qemu args)
# ---------------------------------------------------------------------------
cat >"$OUT_DIR/MANIFEST.md" <<MANIFEST
# SerenityOS - gallery guest

- OS: SerenityOS $ARCH, built from source (git $SERENITY_REF) in build LXC $CTID.
  Toolchain: GCC cross-compiler (x86_64-serenity), built from tarballs. License: BSD-2-Clause.
- Model: multiboot kernel + raw ext2 root disk. NO bootloader in the image; QEMU loads the
  kernel directly (-kernel) and the disk is attached as NVMe. Stateless for kiosk use.
- Artifacts (host):
  - $OUT_DIR/_disk_image       (raw ext2 root fs, no partition table, no bootloader)
  - $OUT_DIR/Kernel/Kernel     (x86_64 multiboot kernel)
  - $OUT_DIR/Kernel/Kernel.efi (UEFI kernel, unused by this boot path, if present)
- Reproducer: scripts/build-guests/tiles/serenityos.sh (this file's source of truth).
- Desktop shortcuts: /home/anon/Desktop holds fast symlinks -> /bin/<App> for the shipped
  games (Solitaire, Minesweeper, Snake, Chess, 2048, Spider) + Calculator & PixelPaint,
  alongside the stock Browser/Text Editor/Help/Home. Added offline with debugfs (step 4c);
  FileManager (desktop mode) resolves each to its app icon and double-click launches it.
  Verified launching on 2026-07-06 (Snake + Solitaire opened from their icons).

## Headless verify command
See boot.sh in this directory. Usage: ./boot.sh <vnc_target> <accel> <work_dir>

## Exact guest-visible QEMU device model for the streamhost gallery station
# The station boots a FRESH per-container qcow2 overlay backed by the READ-ONLY golden
# _disk_image (writable root, tiny footprint, clean on every restart). -vga std gives a single
# clean 1920x1080 framebuffer (resolution set in /etc/WindowServer.ini, step 4d; bochs-display
# exposes a dual-head desktop that half-fills the stream canvas; std avoids that).
# See streamhost/stations-manifest.sh.
qemu-system-x86_64 \\
  -machine q35 -cpu host -enable-kvm -m 2G -smp 2 -vga std \\
  -kernel Kernel/Kernel -append "root=nvme0:1:0" \\
  -drive file=/tmp/serenity.qcow2,if=none,format=qcow2,id=boot-drive \\
  -device i82801b11-bridge,id=bridge4 \\
  -device nvme,serial=deadbeef,drive=boot-drive,bus=bridge4,logical_block_size=4096,physical_block_size=4096 \\
  -device AC97,audiodev=snd0 -audiodev <neko-backend>,id=snd0
# where /tmp/serenity.qcow2 = qemu-img create -f qcow2 -F raw -b <golden>/_disk_image

## Pitfalls
- WRITABLE ROOT REQUIRED: SerenityOS mounts its Ext2FS root read-WRITE and PANICS
  ("StorageManagement::create_first_vfs_root_context failed") if the root device is not
  writable -- BOTH -drive readonly=on AND snapshot=on on the shared /guests image panic.
  Boot a per-container qcow2 overlay over the read-only golden instead (writable, clean).
- NEVER boot the golden _disk_image rw. A hard kill mid-write corrupts the ext2 superblock
  (bad magic -> every later boot panics). boot.sh + the tile both boot a throwaway overlay.
- _disk_image is raw ext2 (plain features: no journal/extents/64bit/metadata_csum -- all
  SerenityOS' Ext2FS supports) with NO partition table / NO bootloader. Do NOT boot it with
  -boot c. You MUST pass -kernel Kernel/Kernel and attach it as NVMe (root=nvme0:1:0).
- "multiboot knows VBE. we don't", SpiceAgent "Failed to find spice device file!", vmmouse
  warnings, and AudioServer EACCES are all EXPECTED / harmless.
- Disk image: assembled by SerenityOS' Meta/build-image-qemu.sh. In the build LXC loop/fuse
  mount is blocked so it falls back to genext2fs (run as ROOT for chown/setuid) -- step 4b.
  On a real host that path loop-mounts + mke2fs instead; both yield the same plain ext2.
MANIFEST

# ---------------------------------------------------------------------------
# 6. Framebuffer verification: boot -> WindowServer -> screenshot -> clean quit
# ---------------------------------------------------------------------------
if [[ "$VERIFY" == "1" ]]; then
  log "6. Framebuffer verify (VNC $VNC_TARGET, accel $BOOT_ACCEL)"
  rm -f "$OUT_DIR/verify.png" "$OUT_DIR/verify.ppm"
  bash "$OUT_DIR/boot.sh" "$VNC_TARGET" "$BOOT_ACCEL" "$WORK_DIR"
  QPID="$(cat "$WORK_DIR/qemu.pid")"

  cleanup() {
    # Kill ONLY via QMP quit, fallback to the pidfile we wrote. Never pkill.
    if [[ -S "$WORK_DIR/qmp-sock" ]] && command -v python3 >/dev/null 2>&1; then
      python3 - "$WORK_DIR/qmp-sock" <<'PY' 2>/dev/null || true
import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1]); s.recv(4096)
    s.sendall(b'{"execute":"qmp_capabilities"}\n'); s.recv(4096)
    s.sendall(b'{"execute":"quit"}\n')
except Exception:
    pass
PY
    fi
    sleep 2
    if kill -0 "$QPID" 2>/dev/null; then kill "$QPID" 2>/dev/null || true; fi
  }
  trap cleanup EXIT

  echo "Waiting up to ${VERIFY_TIMEOUT}s for WindowServer ..."
  reached=0
  for i in $(seq 1 "$VERIFY_TIMEOUT"); do
    if grep -q "Entering WindowServer main loop" "$WORK_DIR/debug.log" 2>/dev/null; then
      reached=1
      break
    fi
    if ! kill -0 "$QPID" 2>/dev/null; then
      echo "FATAL: QEMU exited before WindowServer. Tail of qemu.log:" >&2
      tail -20 "$WORK_DIR/qemu.log" >&2 || true
      exit 1
    fi
    sleep 1
  done

  if [[ "$reached" != "1" ]]; then
    echo "FATAL: WindowServer not reached within ${VERIFY_TIMEOUT}s." >&2
    tail -20 "$WORK_DIR/debug.log" >&2 || true
    exit 1
  fi

  # Let the desktop + applets paint, then capture the framebuffer over QMP.
  sleep "$DESKTOP_SETTLE"
  if [[ -S "$WORK_DIR/qmp-sock" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$WORK_DIR/qmp-sock" "$OUT_DIR/verify.ppm" <<'PY' 2>/dev/null || true
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1]); s.recv(4096)
s.sendall(b'{"execute":"qmp_capabilities"}\n'); s.recv(4096)
import json
s.sendall(json.dumps({"execute":"screendump","arguments":{"filename":sys.argv[2]}}).encode()+b'\n')
s.recv(4096)
PY
  fi

  if [[ -s "$OUT_DIR/verify.png" || -s "$OUT_DIR/verify.ppm" ]]; then
    echo "VERIFY OK: WindowServer reached; screenshot captured."
    grep -E "WindowServer|ResourceGraph|LoginServer" "$WORK_DIR/debug.log" | tail -5 || true
  else
    echo "WARN: WindowServer log line found but QMP screenshot capture failed." >&2
  fi
  # cleanup runs on EXIT
else
  log "6. Verify skipped (SERENITY_VERIFY=0)"
fi

log "DONE"
echo "Guest built at: $OUT_DIR"
echo
echo "Streamhost runtime args (also in $OUT_DIR/MANIFEST.md). Tile boots a per-launch"
echo "qcow2 overlay over the READ-ONLY golden _disk_image (writable root, clean restarts):"
cat <<'NEKO'
# seed once per boot:  qemu-img create -f qcow2 -F raw -b <golden>/_disk_image /tmp/serenity.qcow2
qemu-system-x86_64 \
  -machine q35 -cpu host -enable-kvm -m 2G -smp 2 -vga std \
  -kernel Kernel/Kernel -append "root=nvme0:1:0" \
  -drive file=/tmp/serenity.qcow2,if=none,format=qcow2,id=boot-drive \
  -device i82801b11-bridge,id=bridge4 \
  -device nvme,serial=deadbeef,drive=boot-drive,bus=bridge4,logical_block_size=4096,physical_block_size=4096 \
  -device AC97,audiodev=snd0 -audiodev <streamhost-backend>,id=snd0
NEKO
