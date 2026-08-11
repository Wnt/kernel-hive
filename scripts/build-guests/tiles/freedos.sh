#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/freedos.sh — reproduce the FreeDOS 1.3 retro-games gallery station
#                           FROM SOURCE on a fresh Proxmox host.
#
# GUEST : FreeDOS 1.3 — boots straight (no login/installer) to a CHOICE-driven
#         retro-games MENU. Payload: Doom (shareware) + Freedoom on FastDoom,
#         Duke Nukem 3D shareware, Quake shareware, Commander Keen 1 shareware,
#         Wolfenstein 3D shareware (staged), Cosmo's Cosmic Adventure ep.1
#         (Apogee shareware), Jill of the Jungle ep.1 (Epic MegaGames shareware),
#         and the Arachne 1.99 GPL DOS graphical web browser + NE2000 packet
#         driver. 8 one-keypress menu entries ([1]-[8]) + [A] Arachne.
# TYPE  : DISK IMAGE. Base = the official FD13-FullUSB.zip live-USB image (itself
#         a fully bootable FreeDOS). We turn it into a boot-to-games guest by
#         host-side surgery on its FAT16 filesystem (delete installer cache +
#         SETUP.BAT, append a boot block, add MENU.BAT, inject the games +
#         Arachne), then compress to freedos.qcow2. NO DOS boot is needed to
#         assemble it — every file goes in via a loopback FAT16 mount, which is
#         exactly how the validated dry-run box built it (all payload files share
#         one mtime).
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh host):
#   1. Re-DOWNLOAD every source from its real canonical URL (FreeDOS FullUSB,
#      FastDoom, Doom shareware WAD, Freedoom, Duke3D/Quake/Keen/Wolf3D
#      shareware, CWSDPMI, Arachne, FreeDOS choice/ctmouse pkgs). Cached +
#      idempotent (skips a source that is already downloaded).
#   2. Create the working disk: copy FD13FULL.img out of the FullUSB zip.
#   3. Attach it via qemu-nbd on a FREE /dev/nbdN and mount the FAT16 partition.
#      "Install automation" here = the deterministic filesystem edits below
#      (the DOS equivalent of an answer file): delete \PACKAGES + \FDOS-x86 +
#      \SETUP.BAT, append the sound/mouse/PATH/menu block to \FDAUTO.BAT, drop
#      in \MENU.BAT, and add CHOICE.EXE + CTMOUSE.EXE to \FREEDOS\BIN.
#   4. Inject the era software into \GAMES\* and the Arachne browser into
#      \ARACHNE. Three genuinely hand-authored config artifacts (the outputs of
#      interactive in-game SETUP utilities) are embedded below as gzip+base64
#      heredocs or written as text — these are answer files, not binaries:
#        - \GAMES\DOOM\FDOOM.CFG       (FastDoom SB16 digital-effects config)
#        - \GAMES\DUKE3D\DUKE3D.CFG   (Duke SETUP.EXE output: SB16 + keymap)
#        - \GAMES\QUAKE\ID1\CONFIG.CFG (Quake tuned config)
#   5. Unmount, disconnect nbd, and land the final artifact at
#      data/gallery-guests/FreeDOS/freedos.qcow2 (qemu-img convert -c).
#   6. FRAMEBUFFER-VERIFY: boot the qcow2 headless under the EXACT neko-qemu
#      retro profile (unique VNC + monitor socket), wait, `screendump` a PNG of
#      the boot menu, and sanity-check it.
#
# AUTOMATION HONESTY:
#   * Steps 1-6 are FULLY automated and reproduce with no human input, INCLUDING
#     the Arachne install. If the release is directly extractable, its non-empty
#     runtime tree is copied host-side. The current upstream archive embeds an
#     old solid-RAR DOS SFX which open host tools cannot decode; in that case a
#     private QEMU boot answers the SFX's two confirmation prompts and validates
#     non-empty ARACHNE.BAT + CORE.EXE before the final qcow2 is made.
#   * The ONLY manual touch is at RUNTIME, not build time: Arachne's first launch
#     shows a video-mode wizard whose "Try selected graphics mode" needs one
#     mouse click (CTMOUSE is loaded, so a gallery visitor does it once). This is
#     inherent to Arachne and does NOT block the games menu or the build.
#   * Wolfenstein 3D is STAGED only — it black-screens under QEMU (known Wolf3D
#     v1.4 timing/keyboard bug, not profile-fixable). Its download is best-effort
#     and NON-FATAL; the other five games do not depend on it.
#
# HYGIENE (per project rules):
#   * The verify VM is killed ONLY via its QEMU monitor `quit` (fallback: its own
#     pidfile). NEVER `pkill qemu*` — that would catch live gallery stations / the
#     macOS fan-out VMs / VM 900/920.
#   * A FREE nbd device is chosen dynamically and disconnected in cleanup; the
#     mount lives in a private, PID-namespaced run dir with a unique VNC display
#     and monitor socket, so concurrent guest builds never collide.
#   * Touches ONLY data/gallery-guests/FreeDOS/. Never CT 110, VM 900/920, the
#     macOS VMIDs, or any other guest dir.
#
# Idempotent + re-runnable. `bash -n` clean. Safe to run repeatedly.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="freedos"
DIR_NAME="FreeDOS" # matches the on-box dir + the live station path

GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${OUT_DIR:-${GUESTS_ROOT}/${DIR_NAME}}"
QCOW2_PATH="${GUEST_DIR}/freedos.qcow2"

WORK="${WORK_DIR:-${GUEST_DIR}/.build-work}" # sources + scratch (kept between runs = cache)
DL="${WORK}/dl"                              # downloaded sources cache
RAW_IMG="${WORK}/work.img"                   # writable raw disk we mutate then compress

# Behaviour knobs
FORCE="${FORCE:-0}"                                # FORCE=1 rebuilds even if freedos.qcow2 exists
VERIFY="${VERIFY:-1}"                              # VERIFY=0 skips the framebuffer boot
VERIFY_WAIT="${VERIFY_WAIT:-25}"                   # seconds for FreeDOS to reach the menu (TCG)
ARACHNE_INSTALL_WAIT="${ARACHNE_INSTALL_WAIT:-90}" # nested DOS SFX unpack (TCG-safe)
KEEP_WORK="${KEEP_WORK:-1}"                        # 1 = keep source cache; 0 = wipe $WORK at end

# ------------------------------------------------------------- source URLs (real)
# FreeDOS 1.3 official FullUSB live image (contains FD13FULL.img)
FULLUSB_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/official/FD13-FullUSB.zip"
# FreeDOS base packages that FullUSB's BIN lacked (CHOICE for the menu, CTMOUSE for Arachne)
CHOICE_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.3/base/choice.zip"
CTMOUSE_URL="https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.3/base/ctmouse.zip"
# FastDoom (the DOS Doom engine used for both Doom shareware and Freedoom).
# Resolved to the latest release asset at runtime; pin below is the validated one.
FASTDOOM_REPO="viti95/FastDoom"
FASTDOOM_PIN_URL="https://github.com/viti95/FastDoom/releases/download/1.3.0/FastDoom_1.3.0.zip"
# Doom shareware IWAD (id Software freely-redistributable shareware WAD)
DOOM1WAD_URL="https://distro.ibiblio.org/slitaz/sources/packages/d/doom1.wad"
# Freedoom (100% free BSD-licensed IWADs freedoom1.wad/freedoom2.wad -> FREEDM1/2.WAD)
FREEDOOM_REPO="freedoom/freedoom"
FREEDOOM_PIN_URL="https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip"
# Duke Nukem 3D shareware (Apogee/3D Realms freely-distributable ep.1)
DUKE3D_URL="https://archive.org/download/3dduke13/3dduke13.zip"
# Quake 1.06 shareware (id Software freely-distributable — DOS engine + ID1/PAK0.PAK)
QUAKE_URL="https://archive.org/download/quakeshareware/QUAKE_SW.zip"
QUAKE_EXPECT_SHA256="b8e3e9c9f875dc6dda5ebdb9c2434bdfb3ece86c516089ebfe5c12106fffe7c1"
# CWSDPMI (DPMI host for the DJGPP-built Quake, if the shareware zip lacks one)
CWSDPMI_URL="https://www.delorie.com/pub/djgpp/current/v2misc/csdpmi7b.zip"
# Commander Keen 1 shareware (Apogee/id freely-distributable)
KEEN1_URL="https://archive.org/download/msdos_Commander_Keen_1_-_Marooned_on_Mars_1990/Commander_Keen_1_-_Marooned_on_Mars_1990.zip"
# Wolfenstein 3D v1.4 shareware ep.1 — STAGED ONLY (black-screens under QEMU).
# The archive contains the original Apogee installer payload W3DSW14.SHR. Debian's
# `id-shr-extract` (package: dynamite) expands that PKWARE-DCL stream host-side.
WOLF3D_URL="${WOLF3D_URL:-https://www.classicdosgames.com/files/games/id/1wolf14.zip}"
WOLF3D_EXPECT_SHA256="${WOLF3D_EXPECT_SHA256:-cb2a2ef7ecef14152c65ff93cc3b84fbd3e8eb0c5c1de41a6fc8cdef559451a8}"
# Arachne 1.99 GPL DOS graphical browser (Glenn McCorkle's GPL release).
ARACHNE_URL="http://www.glennmcc.org/arachne/a199gpl.zip"
ARACHNE_EXPECT_SHA256="ecc820ddc33c2ecbe64113d773b05e8eaac8eedd32f1ac7768bf3091de1b5ac8"
# Cosmo's Cosmic Adventure — Forbidden Planet (Apogee shareware ep.1, freely
# distributable). Zip bundles ep.2/3 (registered/paid) — we stage ONLY ep.1.
# NOTE: this same zip also carries the registered ep.2/3 data (see COSMO_URL
# comment above check-assets.sh); not redistributed in the repo, fetched from
# archive.org and hash-pinned instead. See docs/guests/freedos.md.
COSMO_URL="https://archive.org/download/msdos_Cosmos_Cosmic_Adventure_-_Forbidden_Planet_1992/Cosmos_Cosmic_Adventure_-_Forbidden_Planet_1992.zip"
COSMO_EXPECT_SHA256="d7197b6b86170c808714e591faa29b028b7ad13bf45c34d66425934c0c5245f8"
# Jill of the Jungle (Epic MegaGames shareware ep.1, freely distributable).
JILL_URL="https://archive.org/download/msdos_Jill_of_the_Jungle_1992/Jill_of_the_Jungle_1992.zip"
JILL_EXPECT_SHA256="ab09c4674f7c43e3ea80b9e22b250da442f471c3877e5d5410c9ba6c1366f837"

# Offline asset fallback: if an operator has staged a local copy at
# build-guests/assets/freedos/{cosmo,jill}.zip (NOT shipped in the repo — see
# docs/guests/freedos.md), it is used instead of fetching. Otherwise fetched
# from archive.org above and verified against *_EXPECT_SHA256.
ASSETS_DIR="${ASSETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../assets/freedos}"

UA="Mozilla/5.0 (FreeDKernel Hive-build)"

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch args this station runs with in the live gallery.
# (validated headless on the dry-run box; emitted here for reference + reuse)
#
# PERF: this station was flipped TCG -> KVM (perf rollout, kvm-safe-flip: DOS
# tolerates KVM well). Live launch is now hardware-accelerated:
#   qemu-system-x86_64 -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd \
#     -enable-kvm -cpu host -m 64 -vga cirrus \
#     -drive file=freedos.qcow2,format=qcow2,if=ide,index=0 -boot c \
#     -audiodev pa,id=snd,out.buffer-length=100000,out.latency=50000 \
#     -device sb16,audiodev=snd \
#     -netdev user,id=n0 -device ne2k_pci,netdev=n0 -snapshot
#
# neko-qemu / launch-qemu.sh environment for this station:
#   OS_NAME=FreeDOS  QEMU_MACHINE="pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd"  QEMU_MEM=64
#   QEMU_VGA=cirrus  QEMU_SOUND="-device sb16,audiodev=snd"
#   ACCEL=kvm   (launch-qemu.sh emits -enable-kvm; /dev/kvm is mapped into the CT)
#   GUEST_DISK=/guests/FreeDOS/freedos.qcow2  GUEST_FMT=qcow2
#   GUEST_IF=ide  GUEST_BOOT=c
#   QEMU_EXTRA="-cpu host -netdev user,id=n0 -device ne2k_pci,netdev=n0 -snapshot"
# Notes: acpi=off replaces the removed -no-acpi (QEMU 11). launch-qemu.sh emits
#   audiodev id=snd with the gallery-wide 100ms buffer / 50ms latency hardening
#   (out.buffer-length/out.latency) baked into the base image. Mouse is PS/2 +
#   in-image CTMOUSE (int33h) — do NOT add usb-tablet. The in-image
#   SET BLASTER=A220 I5 D1 H5 T6 matches QEMU's sb16 defaults so games init sound.
#   pcspk-audiodev routes the already-present PC speaker to the same backend for
#   Keen 1 and Cosmo; it is an audio-backend property, not an added guest device.
#   The framebuffer-verify boot below intentionally stays TCG (-cpu pentium): it is
#   a portable build-HOST golden-image smoke test and must not require /dev/kvm.
###############################################################################

# --------------------------------------------------------------- tool checks
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }
need curl
need unzip
need sha256sum
need qemu-img
need qemu-nbd
need mount
need umount
need socat
need id-shr-extract
UNPACK_SFX="" # for the Arachne self-extractor
if command -v 7z >/dev/null 2>&1; then UNPACK_SFX="7z"; fi

# --------------------------------------------------------------- 0. workspace
mkdir -p "$GUEST_DIR" "$WORK" "$DL"

if [[ -f "$QCOW2_PATH" && "$FORCE" != "1" ]]; then
  log "freedos.qcow2 already present (FORCE=1 to rebuild) — jumping to verify."
else

  # ---------------------------------------------------------- 1. download sources
  # fetch URL DEST — cached; resumes/re-downloads only if missing or zero-size.
  fetch() {
    local url="$1" dest="$2"
    if [[ -s "$dest" ]]; then
      log "cached: $(basename "$dest")"
      return 0
    fi
    log "download: $url"
    curl -fL --retry 3 --retry-delay 2 -A "$UA" -e "https://archive.org/" \
      -o "${dest}.part" "$url"
    mv -f "${dest}.part" "$dest"
  }
  # resolve the latest GitHub release asset matching a regex (falls back to pin)
  gh_latest_asset() {
    local repo="$1" regex="$2" pin="$3"
    local u
    u="$(curl -fsSL -A "$UA" "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
      grep -oE '"browser_download_url": *"[^"]+"' | cut -d'"' -f4 |
      grep -iE "$regex" | head -1 || true)"
    [[ -n "$u" ]] && {
      printf '%s\n' "$u"
      return
    }
    printf '%s\n' "$pin"
  }

  FASTDOOM_URL="$(gh_latest_asset "$FASTDOOM_REPO" 'FastDoom.*\.zip$' "$FASTDOOM_PIN_URL")"
  FREEDOOM_URL="$(gh_latest_asset "$FREEDOOM_REPO" 'freedoom-[0-9].*\.zip$' "$FREEDOOM_PIN_URL")"

  fetch "$FULLUSB_URL" "$DL/FD13-FullUSB.zip"
  fetch "$CHOICE_URL" "$DL/choice.zip"
  fetch "$CTMOUSE_URL" "$DL/ctmouse.zip"
  fetch "$FASTDOOM_URL" "$DL/fastdoom.zip"
  fetch "$DOOM1WAD_URL" "$DL/DOOM1.WAD"
  fetch "$FREEDOOM_URL" "$DL/freedoom.zip"
  fetch "$DUKE3D_URL" "$DL/duke3d.zip"
  if [[ -s "$DL/quake.zip" ]]; then
    cached_quake_sha="$(sha256sum "$DL/quake.zip" | awk '{print $1}')"
    if [[ "$cached_quake_sha" != "$QUAKE_EXPECT_SHA256" ]]; then
      log "discarding stale/non-shareware Quake cache ($cached_quake_sha)"
      rm -f "$DL/quake.zip"
    fi
  fi
  fetch "$QUAKE_URL" "$DL/quake.zip"
  quake_sha="$(sha256sum "$DL/quake.zip" | awk '{print $1}')"
  [[ "$quake_sha" == "$QUAKE_EXPECT_SHA256" ]] ||
    die "Quake shareware archive hash mismatch (expected $QUAKE_EXPECT_SHA256, got $quake_sha)"
  fetch "$CWSDPMI_URL" "$DL/csdpmi7b.zip"
  fetch "$KEEN1_URL" "$DL/keen1.zip"
  if [[ -s "$DL/a199gpl.zip" ]]; then
    cached_arachne_sha="$(sha256sum "$DL/a199gpl.zip" | awk '{print $1}')"
    if [[ "$cached_arachne_sha" != "$ARACHNE_EXPECT_SHA256" ]]; then
      log "discarding stale/changed Arachne cache ($cached_arachne_sha)"
      rm -f "$DL/a199gpl.zip"
    fi
  fi
  fetch "$ARACHNE_URL" "$DL/a199gpl.zip"
  arachne_sha="$(sha256sum "$DL/a199gpl.zip" | awk '{print $1}')"
  [[ "$arachne_sha" == "$ARACHNE_EXPECT_SHA256" ]] ||
    die "Arachne archive hash mismatch (expected $ARACHNE_EXPECT_SHA256, got $arachne_sha)"
  # Wolf3D is staged-only + known-broken: download failure is non-fatal, but a
  # changed archive is refused rather than risking registered/commercial data.
  if [[ -s "$DL/wolf3d.zip" ]]; then
    cached_wolf_sha="$(sha256sum "$DL/wolf3d.zip" | awk '{print $1}')"
    if [[ "$cached_wolf_sha" != "$WOLF3D_EXPECT_SHA256" ]]; then
      log "discarding stale/non-shareware Wolf3D cache ($cached_wolf_sha)"
      rm -f "$DL/wolf3d.zip"
    fi
  fi
  if fetch "$WOLF3D_URL" "$DL/wolf3d.zip"; then
    wolf_sha="$(sha256sum "$DL/wolf3d.zip" | awk '{print $1}')"
    [[ "$wolf_sha" == "$WOLF3D_EXPECT_SHA256" ]] ||
      die "Wolf3D archive hash mismatch (expected $WOLF3D_EXPECT_SHA256, got $wolf_sha)"
  else
    log "WARN: Wolf3D download failed (staged-only, non-fatal)."
  fi

  # Cosmo + Jill: prefer an operator-staged local asset (air-gapped rebuild),
  # else download from archive.org and verify against the pinned hash.
  fetch_asset() { # url dest assetfile expect_sha256
    local url="$1" dest="$2" asset="$3" expect="$4" got
    if [[ -s "$dest" ]]; then
      log "cached: $(basename "$dest")"
      return 0
    fi
    if [[ -s "$ASSETS_DIR/$asset" ]]; then
      log "using local asset: $ASSETS_DIR/$asset"
      cp -f "$ASSETS_DIR/$asset" "$dest"
    else
      fetch "$url" "$dest"
    fi
    got="$(sha256sum "$dest" | awk '{print $1}')"
    [[ "$got" == "$expect" ]] ||
      die "$asset hash mismatch (expected $expect, got $got) — corrupt download or stale local asset"
  }
  fetch_asset "$COSMO_URL" "$DL/cosmo.zip" "cosmo.zip" "$COSMO_EXPECT_SHA256"
  fetch_asset "$JILL_URL" "$DL/jill.zip" "jill.zip" "$JILL_EXPECT_SHA256"

  # --------------------------------------------------- extract sources to $WORK/ex
  EX="$WORK/ex"
  rm -rf "$EX"
  mkdir -p "$EX"
  uz() { unzip -o -q "$1" -d "$2"; } # quiet, overwrite

  uz "$DL/FD13-FullUSB.zip" "$EX/fullusb"
  uz "$DL/choice.zip" "$EX/choice"
  uz "$DL/ctmouse.zip" "$EX/ctmouse"
  uz "$DL/fastdoom.zip" "$EX/fastdoom"
  uz "$DL/freedoom.zip" "$EX/freedoom"
  uz "$DL/duke3d.zip" "$EX/duke3d"
  uz "$DL/quake.zip" "$EX/quake"
  uz "$DL/csdpmi7b.zip" "$EX/cwsdpmi"
  uz "$DL/keen1.zip" "$EX/keen1"
  if [[ -s "$DL/wolf3d.zip" ]]; then
    uz "$DL/wolf3d.zip" "$EX/wolf3d"
    WOLF_SHR="$(find "$EX/wolf3d" -type f -iname 'W3DSW14.SHR' -print -quit)"
    if [[ -n "$WOLF_SHR" ]]; then
      command -v id-shr-extract >/dev/null 2>&1 ||
        die "Wolf3D shareware extraction needs id-shr-extract (Debian package: dynamite)"
      mkdir -p "$EX/wolf3d/shr"
      (cd "$EX/wolf3d/shr" && id-shr-extract "$WOLF_SHR" >/dev/null)
    fi
  fi
  uz "$DL/cosmo.zip" "$EX/cosmo"
  uz "$DL/jill.zip" "$EX/jill"

  # locate the FreeDOS raw disk image inside the FullUSB zip (name may drift)
  SRC_IMG="$(find "$EX/fullusb" -type f -iname '*.img' | head -1)"
  [[ -n "$SRC_IMG" ]] || die "FD13FULL.img not found inside FullUSB zip"
  log "base disk image: $(basename "$SRC_IMG")"

  # ------------------------------------------------ 2. create writable work disk
  log "copying base image to writable work disk ($RAW_IMG)"
  cp -f "$SRC_IMG" "$RAW_IMG"

  # ------------------------------------------------ 3. attach + mount FAT16 (rw)
  modprobe nbd max_part=8 2>/dev/null || true
  NBD_DEV=""
  for n in /sys/block/nbd*; do
    d="/dev/$(basename "$n")"
    # size==0 means the nbd device is free (not connected)
    if [[ "$(cat "$n/size" 2>/dev/null || echo 1)" == "0" ]]; then
      NBD_DEV="$d"
      break
    fi
  done
  [[ -n "$NBD_DEV" ]] || die "no free /dev/nbd* device available"
  MNT="$WORK/mnt"
  mkdir -p "$MNT"

  # shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM traps below
  disk_cleanup() {
    mountpoint -q "$MNT" && {
      sync
      umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null || true
    }
    [[ -n "${NBD_DEV:-}" ]] && qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
  }
  trap disk_cleanup EXIT INT TERM

  log "attaching $RAW_IMG on $NBD_DEV and mounting FAT16 partition rw"
  qemu-nbd -c "$NBD_DEV" -f raw "$RAW_IMG"
  # let the partition node appear
  for _ in $(seq 1 20); do
    [[ -b "${NBD_DEV}p1" ]] && break
    partprobe "$NBD_DEV" 2>/dev/null || true
    sleep 0.3
  done
  PART="${NBD_DEV}p1"
  [[ -b "$PART" ]] || PART="$NBD_DEV"
  mount -t vfat -o rw "$PART" "$MNT"

  # helper: write a DOS text file with CRLF line endings from a quoted heredoc
  crlf_to() { sed 's/$/\r/' >"$1"; }

  # helper: dir containing the first (case-insensitive) match of file $2 under $1;
  # EMPTY if none. NEVER use bare dirname "$(find …)" for this: dirname "" prints
  # ".", which once passed the -n/-d guards and cp -r'd the build CWD into the
  # guest FAT until it filled (found+fixed 2026-07-14).
  dir_of() {
    local f
    f="$(find "$1" -type f -iname "$2" 2>/dev/null | head -1)"
    [[ -n "$f" ]] && dirname "$f" || true
  }

  # Arachne's old RAR SFX makes 7z create a convincing directory tree of zero-byte
  # placeholders before returning "Unsupported Method". A usable tree must contain
  # both the launcher and browser core with data, not merely filenames.
  arachne_tree_of() {
    local bat tree core
    bat="$(find "$1" -type f -iname 'ARACHNE.BAT' -size +0c 2>/dev/null | head -1)"
    [[ -n "$bat" ]] || return 0
    tree="$(dirname "$bat")"
    core="$(find "$tree" -type f -iname 'CORE.EXE' -size +0c 2>/dev/null | head -1)"
    [[ -n "$core" ]] && printf '%s\n' "$tree"
  }

  # ------------------------------------------------ 3a. installer surgery ("answer file")
  # Free ~366 MB: drop the offline installer cache — not needed on a running system.
  for d in packages FDOS-x86; do
    p="$(find "$MNT" -maxdepth 1 -type d -iname "$d" -print -quit 2>/dev/null || true)"
    [[ -n "$p" ]] && {
      log "removing installer dir: $(basename "$p")"
      rm -rf "$p"
    }
  done
  # Delete SETUP.BAT so FDAUTO.BAT skips the install wizard and drops to our menu.
  sb="$(find "$MNT" -maxdepth 1 -type f -iname 'SETUP.BAT' -print -quit 2>/dev/null || true)"
  [[ -n "$sb" ]] && {
    log "deleting SETUP.BAT (skip installer)"
    rm -f "$sb"
  }

  # Locate FDAUTO.BAT and FREEDOS\BIN on the mount (case-insensitive).
  FDAUTO="$(find "$MNT" -maxdepth 1 -type f -iname 'fdauto.bat' -print -quit)"
  [[ -n "$FDAUTO" ]] || die "fdauto.bat not found on image"
  FDBIN="$(find "$MNT" -maxdepth 2 -type d -ipath '*/freedos/bin' -print -quit)"
  [[ -n "$FDBIN" ]] || die "FREEDOS\\BIN not found on image"

  # Append the boot block (idempotent — only if our marker is absent).
  if ! grep -qi 'call \\MENU.BAT' "$FDAUTO"; then
    log "appending sound/mouse/PATH/menu block to FDAUTO.BAT"
    crlf_to "$FDAUTO.append" <<'FDAUTO_BLOCK'

SET BLASTER=A220 I5 D1 H5 T6
CTMOUSE
PATH=%PATH%;C:\GAMES
call \MENU.BAT
FDAUTO_BLOCK
    cat "$FDAUTO.append" >>"$FDAUTO"
    rm -f "$FDAUTO.append"
  else
    log "FDAUTO.BAT already carries the menu block — leaving as is."
  fi

  # Write \MENU.BAT (the CHOICE-driven launcher). NOTE the doubled %% for CHOICE.
  crlf_to "$MNT/MENU.BAT" <<'MENU_BAT'
@echo off
:TOP
cls
echo.
echo    ============================================================
echo      F R E E D O S   1 . 3   --   R E T R O   G A M E S
echo    ============================================================
echo.
echo      [1]  Doom (shareware)         - FastDoom engine
echo      [2]  Freedoom  (100%% free)    - FastDoom engine
echo      [3]  Duke Nukem 3D  (shareware ep.1)
echo      [4]  Quake  (shareware ep.1)
echo      [5]  Wolfenstein 3D  (shareware ep.1)
echo      [6]  Commander Keen 1  (shareware)
echo      [7]  Cosmos Cosmic Adventure  (shareware ep.1)
echo      [8]  Jill of the Jungle  (shareware ep.1)
echo.
echo      [A]  Arachne - DOS graphical web browser
echo      [C]  Command prompt        [R]  Reboot
echo    ============================================================
echo.
choice /C:12345678ACR /N Pick a game (1-8), A, C, R?
if errorlevel 11 goto REBOOT
if errorlevel 10 goto PROMPT
if errorlevel 9 goto WEB
if errorlevel 8 goto JILL
if errorlevel 7 goto COSMO
if errorlevel 6 goto KEEN
if errorlevel 5 goto WOLF
if errorlevel 4 goto QUAKE
if errorlevel 3 goto DUKE
if errorlevel 2 goto FREEDOOM
if errorlevel 1 goto DOOM
goto TOP
:DOOM
cd \GAMES\DOOM
FDOOM.EXE -iwad DOOM1.WAD
cd \
goto TOP
:FREEDOOM
cd \GAMES\DOOM
FDOOM.EXE -iwad FREEDM1.WAD
cd \
goto TOP
:DUKE
cd \GAMES\DUKE3D
DUKE3D.EXE
cd \
goto TOP
:QUAKE
cd \GAMES\QUAKE
QUAKE.EXE
cd \
goto TOP
:WOLF
cd \GAMES\WOLF3D
WOLF3D.EXE
cd \
goto TOP
:KEEN
cd \GAMES\KEEN
KEEN1.EXE
cd \
goto TOP
:COSMO
cd \GAMES\COSMO
COSMO1.EXE
cd \
goto TOP
:JILL
cd \GAMES\JILL
JILL1.EXE
cd \
goto TOP
:WEB
cd \ARACHNE
if exist ARACHNE.BAT goto RUNWEB
echo Arachne is not unpacked yet. Run INSTALL.BAT in \GAMES\ARACHNE first.
pause
cd \
goto TOP
:RUNWEB
call ARACHNE.BAT
cd \
goto TOP
:PROMPT
cls
echo Type MENU to return to the games menu.
cd \
goto END
:REBOOT
fdapm warmboot
:END
MENU_BAT

  # CHOICE.EXE + CTMOUSE.EXE into FREEDOS\BIN (FullUSB's BIN lacked CHOICE).
  cp -f "$(find "$EX/choice" -type f -iname 'choice.exe' | head -1)" "$FDBIN/CHOICE.EXE"
  cp -f "$(find "$EX/ctmouse" -type f -iname 'ctmouse.exe' | head -1)" "$FDBIN/CTMOUSE.EXE"
  log "added CHOICE.EXE + CTMOUSE.EXE to FREEDOS\\BIN"

  # ------------------------------------------------ 4. inject era software (\GAMES)
  G="$MNT/GAMES"
  mkdir -p "$G"/{DOOM/DATA,DUKE3D,QUAKE/ID1,WOLF3D,KEEN,ARACHNE}

  # --- Doom / Freedoom (FastDoom engine) ---
  FD="$EX/fastdoom"
  cp -f "$(find "$FD" -type f -iname 'FDOOM.EXE' | head -1)" "$G/DOOM/FDOOM.EXE"
  cp -f "$(find "$FD" -type f -iname 'FDSETUP.EXE' | head -1)" "$G/DOOM/FDSETUP.EXE"
  cp -f "$(find "$FD" -type f -iname 'DOOM.TCF' | head -1)" "$G/DOOM/DOOM.TCF"
  cp -f "$(find "$FD" -type f -iname 'DOOM1.TCF' | head -1)" "$G/DOOM/DOOM1.TCF"
  # FastDoom sound-bank data dir (ADLIBFX/SC55/... .BIN)
  DATADIR="$(find "$FD" -type d -iname 'DATA' | head -1)"
  [[ -n "$DATADIR" ]] && cp -f "$DATADIR"/*.[Bb][Ii][Nn] "$G/DOOM/DATA/" 2>/dev/null || true
  # FastDoom defaults both devices to None when FDOOM.CFG is absent. QEMU's SB16
  # PCM DSP works, but its FM path is not detected by FastDoom, so enable digital
  # Sound Blaster effects and leave music off instead of aborting during FM init.
  crlf_to "$G/DOOM/FDOOM.CFG" <<'FASTDOOM_CFG'
snd_channels 8
snd_musicdevice 0
snd_sfxdevice 3
FASTDOOM_CFG
  # Doom shareware IWAD
  cp -f "$DL/DOOM1.WAD" "$G/DOOM/DOOM1.WAD"
  # Freedoom IWADs -> 8.3 names the menu expects
  cp -f "$(find "$EX/freedoom" -type f -iname 'freedoom1.wad' | head -1)" "$G/DOOM/FREEDM1.WAD"
  cp -f "$(find "$EX/freedoom" -type f -iname 'freedoom2.wad' | head -1)" "$G/DOOM/FREEDM2.WAD"
  log "staged Doom + Freedoom (FastDoom with SB16 digital effects)"

  # --- Duke Nukem 3D shareware --- copy the whole shareware payload dir
  # 3dduke13.zip is the raw Apogee distribution (INSTALL.EXE + DN3DSW13.SHR); the
  # .SHR is a zip-with-DOS-stub — unpack it host-side, judging success by file
  # presence (7z exits rc=2 on the stub even after a full extract). (2026-07-14)
  DUKESRC="$(dir_of "$EX/duke3d" 'DUKE3D.GRP')"
  if [[ -z "$DUKESRC" ]]; then
    DSHR="$(find "$EX/duke3d" -type f -iname '*.SHR' | head -1)"
    if [[ -n "$DSHR" ]]; then
      mkdir -p "$EX/duke3d/shr"
      [[ "$UNPACK_SFX" == "7z" ]] && { 7z x -y -o"$EX/duke3d/shr" "$DSHR" >/dev/null 2>&1 || true; }
      [[ -z "$(dir_of "$EX/duke3d/shr" 'DUKE3D.GRP')" ]] && { unzip -o -q "$DSHR" -d "$EX/duke3d/shr" >/dev/null 2>&1 || true; }
      DUKESRC="$(dir_of "$EX/duke3d/shr" 'DUKE3D.GRP')"
    fi
  fi
  [[ -n "$DUKESRC" && -d "$DUKESRC" ]] || die "DUKE3D.GRP not found in duke3d.zip"
  cp -f "$DUKESRC"/* "$G/DUKE3D/" 2>/dev/null || true
  # Baked SETUP.EXE output (answer file: VESA screen mode + SB16 + keymap)
  base64 -d <<'DUKE3D_CFG' | gunzip >"$G/DUKE3D/DUKE3D.CFG"
H4sIAEatSGoCA4VYS3PiOBC+pyr/wWEOe9gZFmMeSU3lQALZZBIyKSCPnakpSmAFVNiWV7aTsIf97dvdkowdmyw1BPvrr1utVqtbmp9Tnmbxr8ODr/TgXIiAO89SOcNsw51b+BM63vDwgKQPXCVCRs6p03CbbgOUHP39OV0qziMnN2bwrxofS58j8MU5XzMRcR+eWhp44Alz2s0WPLoaMabOsudnroja1oJZwqOVI+NUhOIfEnhacMcU80XCS7KOseaV0K5GJ9w/CzLuTFMYQgLQN+6pbZKywBlteQKvvdIsHoWfrp2YJQmYSqUD3sBcSpRLLlbrdB8Hvrt4QBDb9l1bPnW8dstCxhKQWq1inGUW+ZUwXzwN+YtYok0XYjLOErEsIRdPDzLIQhoUxyDGDsIhbrPwQYJGAkCHXmGtoogHifYUgDOR4gus01i8TVhK1t0Wao+FL+6kQodbb54HyFnAEojuwPcVTxLCaWiDz7Yxqvdy4CqCPyqL0UQ3R4chO9ZD7gC3V6KMwoys99D6hL9AjnKzrqdOMXbXfDvkzyISKeRwUgjfWL7w+YVUr0z5mNv3ccNpXMfMP24Y4Rlbbqx0KF8jI2+DfJapaH7Dn9HvBv4aWcfKJmYhG/SA0jvm90A6TRV75qQ2CFAwwR9YLKE0ep6qAGH6PTz4HnPaetOYLTngAE0yQm6ma0EDT/TD4cEgS6URnrP4ZrnR/G9ZGCM2gNc/4P1cyWyJmdf4oQk3Um7m98S5W+VxOLESnLuWDW0MPCuzMbiKEq5sFFpWmkdhyAOeciNu5mHI1T9rRwyaqzU1PBChce9ShtwEs28E1rtR5Bv7WKMeOYtlNHepamkrBmoj1C5BHkJeCeog1ClBXYS6JQhzstErQX2E+iUIc7lxXIJOEDopQW4LsZbGrqIXHqVSbfXMILFpbj48FqV5/H6+U9uF8JeWXMpAzqm6YxRNXvAUkmqDyDeN3KLWg7Dl/lajY+5fCzI21gBm+EBRUQLwjG2m8dIsII/8Mex8tqKBZsYAo8WbsYVhrZWINnNT80HyxazcFxCOooCpFS9IT430d8xdjsGYPwj+iiJMhG4+QywMcx1O2jJLle+B6Vq+zr/HIAEDSYH0mLsIxSAIgGXqdOPCTonPz6WMd2MaDZklfA4ZKKA/Yf0wsZGrVQAaSiYJtD1Fm8NmN1dS+AmVBQ3lZepcRqmCGRTbqMXKr4Euo7p1QXVbSCxRlU/ea3MKg+Uip3cUt4byTUI3FJAWmtKuofzJQg7rYa10aiijN5hsBE1VU7waykWA2TbVY+VNukSZrVWWpGOq+IXODN9yMHSzsJ7blmTWCHIyger/ItItddt+7xiyzPiHJ5+IUUNsjJ5mo8nt4KY5ehpRIrJFwCeZ73NVMJevuAXOsjSVEe1eLOKNEnwegEPcJ2lZQqVJF7xaFZJj9S9LqXwVe1etctuMZ0NS9bEseedmWVj2tFbR1T3AVJ8Ki9yBzrRPneTYpioErxCFWlUi6I5WoVARtz1in4FO7Zyp2O962D7lbq1yz457H+9T7NUq9vNR6UyxR7dfTKYBJLFcDd54QovH6HWeQoWGLLWkoVgJOOESa17KxZLErTfsFgyH8qXerrvXrpvbtbP5P58tr9btWuH+EWqdr7HhfjTAR1NoFwZIcJPsHaL90RDtD4bw9qt52mZ5b5Xk1iwWbeiW1ZjmZ9k9JDcn2a1QZZnovatLdTw359njdbkNhmHlogOgKenQjK7U33ApWVBJ/vfw4J6pdHfbAACZ05hzPJqc9PCWMoOePxTQiqhJTCVsobRoQj/fBWwLlwg9CB4BwlvTFuhcJaBRKdPpB7MfeN5g0SqLi+hl6xRPvjiWzAp8wLR1a3F4f40NZjKbFpEmvCN1Df7m/qEy9LqIL1PT6FoUkHDBoC8ulfxEgR9EjoiSWCiG1xy6yi+EguvlUvfJZuOdFi3DXzL7DW4dK7DPHF/o/wJI1yw9ek+nJL9KnXWm4DYIV9wFd7Yyq5ilTL3JlputMwU/5LPDHLhALtcVJpXdyzAMm/C5Y9sFnkThys4rzK5x1VlIKIKh47/yIMDQJsssdBIYjKuKEtXXIQujz+gnzjJbBdsKjUrpJXPW+A8cecSjhl+Z/rF1AUerSOkwPxhMJpM/L/FzdHSUryOs7ye76wsr+w5DllvDciusdg2rXWF5NSyvwurUsDoVVreG1a2wejWsXoXVr2H1K6zjGtZxhXVSw7LYf7B6//HgEgAA
DUKE3D_CFG
  # The historical blob incorrectly used device 13 (NumSoundCards/no sound) for
  # effects and an invalid 1-bit mixer. Keep music at 13 because this QEMU SB16
  # has no FM chip for Duke to detect; device 0 is the working SB16 PCM effects.
  sed -i \
    -e 's/^FXDevice = 13/FXDevice = 0/' \
    -e 's/^NumVoices = 4/NumVoices = 8/' \
    -e 's/^NumBits = 1/NumBits = 16/' \
    -e 's/^MixRate = 11000/MixRate = 22050/' \
    "$G/DUKE3D/DUKE3D.CFG"
  log "staged Duke Nukem 3D shareware (+ SB16 PCM DUKE3D.CFG)"

  # --- Quake shareware (DOS engine + ID1/PAK0.PAK + DPMI host) ---
  QPAK="$(find "$EX/quake" -type f -iname 'PAK0.PAK' | head -1)"
  [[ -n "$QPAK" ]] || die "Quake PAK0.PAK not found in quake.zip"
  cp -f "$QPAK" "$G/QUAKE/ID1/PAK0.PAK"
  QEXE="$(find "$EX/quake" -type f -iname 'QUAKE.EXE' | head -1)"
  [[ -n "$QEXE" ]] && cp -f "$QEXE" "$G/QUAKE/QUAKE.EXE" || log "WARN: QUAKE.EXE not in shareware zip (DJGPP build may be needed)."
  # DOS extender: prefer CWSDPMI from the zip, else the DJ Delorie package.
  QCWS="$(find "$EX/quake" -type f -iname 'CWSDPMI.EXE' | head -1)"
  [[ -z "$QCWS" ]] && QCWS="$(find "$EX/cwsdpmi" -type f -iname 'CWSDPMI.EXE' | head -1)"
  [[ -n "$QCWS" ]] && cp -f "$QCWS" "$G/QUAKE/CWSDPMI.EXE" || true
  # also carry a DOS4GW extender if the shareware engine is DOS4GW-based
  Q4GW="$(find "$EX/quake" -type f -iname 'DOS4GW.EXE' | head -1)"
  [[ -n "$Q4GW" ]] && cp -f "$Q4GW" "$G/QUAKE/DOS4GW.EXE" || true
  # Baked Quake config (answer file: tuned settings)
  base64 -d <<'QUAKE_CFG' | gunzip >"$G/QUAKE/ID1/CONFIG.CFG"
H4sIAEatSGoCA3WUUW/aMBDH35H4DhGv3bIALe1U7SEroa1EKYNUlaZJmUlM4taJU9uB0Yd99vkCsZ3CeCK//93ZPv99K1IkTi/0v/ec3pnI2FbEjGPR63ZWtRLMwmAB2kuVl4Yub/x5oLBkaUpxjotKa8u5fxMcZZwpIsg7rgz6BEE522CK11LTz4fAhG0LDd0mlJM0M7FfFCZ5WVGBnb6nsWdhQ/t2sKYDiw40HVp0qOm5Rc81vbDohaYji440vbTopaZXFr3S9Ntxx37VbaCMvWr0W19CzArBKNYKgmCItQrETR9b3U0aakVKxXIsBEpxzhJT9b2p2qrw97+7eJr7i8XjM2StGd8inmhp/Pg80+IKxeZQ02ASaqXljsX97Z2R2m7wp2FtYsnR2mzgJlxMASMp7SWWd/eTfXiJsdnTBFySYWoaMRnUnSiqSKCNKTsZNpgyZOWfN5iVkqheGOWiUfKKSlJStMPcqOAXHGfM+VGR+FUtRYrUdd1rZ4uIvHZgbecNJJPytZUC22jnAPmY04e3oZi0EBz5nbE8IoVF4dgi5hgXaiqY8PvZErr22jLhOJietMX8djw74cJgNlY0xoXEfEPwVgsPj0/LoH/itmphcMpEtTI8fhdzX3GFS1QJuDVU/QEdxkC388J2q0pKdT3wqLudPCqJjDM1OVxvAFNAqFMTSTZE7mAYdDuQuzcWjJfDd8lVw/ffMY3AwbWZ1FDxDuyw2xaOFI8ZZXyfCZ8FylVdY4k03zBaAYPdNv89F0YGNAzGgtL25TYkiRK8RspVETzVQ1nA4IMIpiYnDQdcsFI96zUlZbMFVqxJWmfnUYaKtFKKHzp3RyIpiHR6RzimGHFI+XkkJQRRuSvV8qGlxcputa6O4Xr174O6QhUM18uR550OIPxN3d5prWRcQoP6I6OnKM9RvRzcDWdCZIgcLuEfkiE5jQYHAAA=
QUAKE_CFG
  log "staged Quake shareware (+ baked CONFIG.CFG)"

  # --- Commander Keen 1 shareware ---
  KEENSRC="$(dir_of "$EX/keen1" 'KEEN1.EXE')"
  [[ -n "$KEENSRC" && -d "$KEENSRC" ]] || die "KEEN1.EXE not found in keen1.zip"
  cp -f "$KEENSRC"/* "$G/KEEN/" 2>/dev/null || true
  log "staged Commander Keen 1 shareware"

  # --- Wolfenstein 3D shareware --- STAGED ONLY (black-screens under QEMU), non-fatal
  if [[ -d "$EX/wolf3d" ]]; then
    WOLFSRC="$(dir_of "$EX/wolf3d" 'WOLF3D.EXE')"
    # LICENSE GUARD (2026-07-14): only the SHAREWARE episode (*.WL1) is freely
    # distributable. Items carrying registered *.WL6 data are refused outright.
    if [[ -n "$WOLFSRC" && -d "$WOLFSRC" ]] && find "$WOLFSRC" -maxdepth 1 -iname '*.WL1' 2>/dev/null | grep -q .; then
      cp -f "$WOLFSRC"/* "$G/WOLF3D/" 2>/dev/null || true
      log "staged Wolfenstein 3D shareware (known-broken under QEMU)"
    else
      log "WARN: no shareware (*.WL1) Wolf3D payload (registered .WL6 refused) — leaving \\GAMES\\WOLF3D empty (staged-only)."
    fi
  else
    log "WARN: no Wolf3D source — leaving \\GAMES\\WOLF3D empty (staged-only)."
  fi

  # --- Cosmo's Cosmic Adventure — EPISODE 1 ONLY (Apogee shareware) ---
  # The zip bundles COSMO2/3.* (registered/paid episodes); we copy ONLY the ep.1
  # payload so the guest ships strictly freely-distributable shareware.
  mkdir -p "$G/COSMO"
  CSRC="$(dir_of "$EX/cosmo" 'COSMO1.EXE')"
  [[ -n "$CSRC" && -d "$CSRC" ]] || die "COSMO1.EXE not found in cosmo.zip"
  for f in COSMO1.EXE COSMO1.VOL COSMO1.STN COSMO1.CFG COSMO.DOC; do
    s="$(find "$CSRC" -maxdepth 1 -type f -iname "$f" | head -1)"
    [[ -n "$s" ]] && cp -f "$s" "$G/COSMO/$(basename "$s" | tr '[:lower:]' '[:upper:]')"
  done
  log "staged Cosmo's Cosmic Adventure ep.1 shareware (ep.2/3 intentionally omitted)"

  # --- Jill of the Jungle — shareware ep.1 (Epic MegaGames) ---
  mkdir -p "$G/JILL"
  JSRC="$(dir_of "$EX/jill" 'JILL1.EXE')"
  [[ -n "$JSRC" && -d "$JSRC" ]] || die "JILL1.EXE not found in jill.zip"
  # copy the shareware payload; skip emulator cruft (dosbox.conf, *.ba1 metadata).
  for f in "$JSRC"/*; do
    b="$(basename "$f")"
    case "$b" in dosbox.conf | *.ba1 | *.BA1) continue ;; esac
    [[ -f "$f" ]] && cp -f "$f" "$G/JILL/$b" 2>/dev/null || true
  done
  log "staged Jill of the Jungle shareware ep.1"

  # ------------------------------------------------ 4a. Arachne browser (\ARACHNE)
  # a199gpl.zip contains either the Arachne tree directly, or the A199GPL.EXE
  # self-extractor. Detect and unpack host-side; copy the tree into \ARACHNE.
  AR="$EX/arachne"
  rm -rf "$AR"
  mkdir -p "$AR"
  uz "$DL/a199gpl.zip" "$AR"
  AR_TREE="$(arachne_tree_of "$AR")"
  if [[ -z "$AR_TREE" ]]; then
    # zip holds the self-extractor (upstream layout since ~2021: A199GPL.EXE +
    # asrc199.zip). Unpack host-side. Validate non-empty runtime files and NEVER
    # trust the exit code or filenames alone.
    SFX="$(find "$AR" -type f -iname 'A199GPL.EXE' | head -1)"
    if [[ -n "$SFX" ]]; then
      UNP="$AR/unpacked"
      mkdir -p "$UNP"
      [[ "$UNPACK_SFX" == "7z" ]] && { 7z x -y -o"$UNP" "$SFX" >/dev/null 2>&1 || true; }
      [[ -z "$(arachne_tree_of "$UNP")" ]] && { unzip -o -q "$SFX" -d "$UNP" >/dev/null 2>&1 || true; }
      AR_TREE="$(arachne_tree_of "$UNP")"
    fi
  fi
  mkdir -p "$MNT/ARACHNE" "$G/ARACHNE"
  ARACHNE_DOS_BOOTSTRAP=0
  if [[ -n "$AR_TREE" && -d "$AR_TREE" ]]; then
    cp -r "$AR_TREE"/. "$MNT/ARACHNE/"
    log "installed Arachne 1.99 GPL into \\ARACHNE (host-side extraction)"
  else
    # Current upstream fallback: stage the old solid-RAR SFX where it expects to
    # install, then add a one-boot FDAUTO block. The private boot below answers its
    # two prompts; the SFX deletes itself afterward so normal boots go to MENU.
    SFX="$(find "$AR" -type f -iname 'A199GPL.EXE' | head -1)"
    [[ -n "$SFX" && -s "$SFX" ]] || die "Arachne archive has neither a usable tree nor A199GPL.EXE"
    cp -f "$SFX" "$MNT/ARACHNE/A199GPL.EXE"
    awk '{
    sub(/\r$/, "")
    if ($0 == "call \\MENU.BAT") {
      print "if not exist \\ARACHNE\\A199GPL.EXE goto ARACHNE_READY"
      print "cd \\ARACHNE"
      print "A199GPL.EXE"
      print "del A199GPL.EXE"
      print "cd \\"
      print ":ARACHNE_READY"
    }
    print
  }' "$FDAUTO" | sed 's/$/\r/' >"$FDAUTO.new"
    mv -f "$FDAUTO.new" "$FDAUTO"
    ARACHNE_DOS_BOOTSTRAP=1
    log "Arachne needs its upstream DOS SFX; scheduled an isolated automatic install boot"
  fi

  # ------------------------------------------------ 5. finalize -> qcow2
  sync
  log "disk contents ready; unmounting + disconnecting nbd"
  umount "$MNT"
  qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
  NBD_DEV="" # so the EXIT trap doesn't double-disconnect
  trap - EXIT INT TERM

  if [[ "$ARACHNE_DOS_BOOTSTRAP" == "1" ]]; then
    BOOT_QEMU="${QEMU_BIN:-qemu-system-i386}"
    command -v "$BOOT_QEMU" >/dev/null 2>&1 || BOOT_QEMU="qemu-system-x86_64"
    command -v "$BOOT_QEMU" >/dev/null 2>&1 ||
      die "Arachne DOS extraction needs qemu-system-i386 or qemu-system-x86_64"

    AR_RUN="$WORK/arachne-install-run.$$"
    AR_MON="$AR_RUN/mon.sock"
    AR_PID="$AR_RUN/qemu.pid"
    mkdir -p "$AR_RUN"
    ar_mon() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${AR_MON}" >/dev/null 2>&1 || true; }
    ar_cleanup() {
      if [[ -S "$AR_MON" ]]; then
        ar_mon quit
        sleep 1
      fi
      if [[ -f "$AR_PID" ]]; then
        local p
        p="$(cat "$AR_PID" 2>/dev/null || true)"
        if [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null; then
          kill "$p" 2>/dev/null || true
          sleep 1
          kill -9 "$p" 2>/dev/null || true
        fi
      fi
      rm -rf "$AR_RUN"
    }
    trap ar_cleanup EXIT INT TERM

    AR_ACCEL=(-accel tcg -cpu pentium)
    if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then AR_ACCEL=(-enable-kvm -cpu host); fi
    log "Arachne install: booting private VM and answering the two upstream SFX confirmations"
    nice -n15 "$BOOT_QEMU" \
      -machine pc,acpi=off "${AR_ACCEL[@]}" -m 64 -vga cirrus \
      -drive file="$RAW_IMG",format=raw,if=ide,index=0 -boot c \
      -audiodev none,id=snd -device sb16,audiodev=snd \
      -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
      -monitor "unix:${AR_MON},server,nowait" -pidfile "$AR_PID" \
      -display none -daemonize
    for _ in $(seq 1 20); do
      [[ -S "$AR_MON" ]] && break
      sleep 0.5
    done
    [[ -S "$AR_MON" ]] || die "Arachne install VM monitor did not appear"
    sleep 25
    ar_mon "sendkey y"
    sleep 3
    ar_mon "sendkey y"
    log "Arachne install: waiting ${ARACHNE_INSTALL_WAIT}s for nested archive expansion"
    sleep "$ARACHNE_INSTALL_WAIT"
    ar_mon quit
    for _ in $(seq 1 20); do
      p="$(cat "$AR_PID" 2>/dev/null || true)"
      [[ -z "$p" ]] || ! kill -0 "$p" 2>/dev/null || {
        sleep 0.5
        continue
      }
      break
    done
    trap - EXIT INT TERM
    ar_cleanup

    # Re-open only our raw disk and prove that the SFX created real runtime data.
    NBD_DEV=""
    for n in /sys/block/nbd*; do
      d="/dev/$(basename "$n")"
      if [[ "$(cat "$n/size" 2>/dev/null || echo 1)" == "0" ]]; then
        NBD_DEV="$d"
        break
      fi
    done
    [[ -n "$NBD_DEV" ]] || die "no free /dev/nbd* device available for Arachne validation"
    trap disk_cleanup EXIT INT TERM
    qemu-nbd -c "$NBD_DEV" -f raw "$RAW_IMG"
    for _ in $(seq 1 20); do
      [[ -b "${NBD_DEV}p1" ]] && break
      partprobe "$NBD_DEV" 2>/dev/null || true
      sleep 0.3
    done
    PART="${NBD_DEV}p1"
    [[ -b "$PART" ]] || PART="$NBD_DEV"
    mount -t vfat -o rw "$PART" "$MNT"
    AR_BAT="$(find "$MNT/ARACHNE" -type f -iname 'ARACHNE.BAT' -size +0c -print -quit 2>/dev/null || true)"
    AR_CORE="$(find "$MNT/ARACHNE" -type f -iname 'CORE.EXE' -size +0c -print -quit 2>/dev/null || true)"
    [[ -n "$AR_BAT" && -n "$AR_CORE" ]] ||
      die "Arachne DOS SFX did not produce non-empty ARACHNE.BAT + CORE.EXE"
    # The installer launches its video wizard before returning to FDAUTO, so the
    # in-guest `del` is normally not reached before this private VM is stopped.
    # Runtime files are complete at this point; remove the now-redundant SFX here.
    rm -f "$MNT/ARACHNE/A199GPL.EXE"
    log "Arachne install validated: non-empty ARACHNE.BAT + CORE.EXE"
    sync
    umount "$MNT"
    qemu-nbd -d "$NBD_DEV" >/dev/null 2>&1 || true
    NBD_DEV=""
    trap - EXIT INT TERM
  fi

  log "compressing to qcow2 -> $QCOW2_PATH"
  rm -f "$QCOW2_PATH"
  qemu-img convert -c -O qcow2 "$RAW_IMG" "$QCOW2_PATH"
  log "built: $(qemu-img info "$QCOW2_PATH" | awk -F': ' '/disk size/{print $2}')"

  [[ "$KEEP_WORK" == "1" ]] || {
    rm -rf "$RAW_IMG" "$EX" "$MNT"
    log "wiped scratch (kept $DL cache)"
  }

fi # end build block

# ------------------------------------------------ 6. framebuffer verification
if [[ "$VERIFY" != "1" ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  echo "$QCOW2_PATH"
  exit 0
fi

QEMU_BIN="${QEMU_BIN:-qemu-system-i386}"
command -v "$QEMU_BIN" >/dev/null 2>&1 || QEMU_BIN="qemu-system-x86_64"
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  log "WARN: no qemu-system binary — cannot framebuffer-verify. Artifact still built."
  echo "$QCOW2_PATH"
  exit 0
fi

RUN_DIR="${GUEST_DIR}/.verify-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
VNC_DISP="${VNC_DISP:-62}" # VNC :62 -> tcp 5962; clear of gallery stations
SHOT_PNG="${GUEST_DIR}/verify-boot-menu.png"
mkdir -p "$RUN_DIR"

mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
vcleanup() {
  if [[ -S "$MON_SOCK" ]]; then
    mon_cmd "quit"
    sleep 1
  fi
  if [[ -f "$PIDFILE" ]]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null || true
      sleep 1
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  rm -rf "$RUN_DIR"
}
trap vcleanup EXIT INT TERM

log "framebuffer-verify: booting headless (VNC :${VNC_DISP}, monitor ${MON_SOCK})"
# EXACT neko-qemu retro profile, minus real audio backend (headless host):
"$QEMU_BIN" \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd -cpu pentium -m 64 -vga cirrus \
  -drive file="$QCOW2_PATH",format=qcow2,if=ide,index=0 -boot c \
  -audiodev none,id=snd -device sb16,audiodev=snd \
  -netdev user,id=n0 -device ne2k_pci,netdev=n0 \
  -snapshot \
  -vnc ":${VNC_DISP}" \
  -monitor "unix:${MON_SOCK},server,nowait" \
  -pidfile "$PIDFILE" \
  -display none -daemonize

for _ in $(seq 1 20); do
  [[ -S "$MON_SOCK" ]] && break
  sleep 0.5
done
log "waiting ${VERIFY_WAIT}s for FreeDOS to reach the games menu..."
sleep "$VERIFY_WAIT"

# Grab the framebuffer (text-mode menu -> small PNG; PPM fallback for old QEMU).
if mon_cmd "screendump -f png ${SHOT_PNG}" && [[ -s "$SHOT_PNG" ]]; then :; else
  ppm="${RUN_DIR}/shot.ppm"
  mon_cmd "screendump ${ppm}"
  sleep 1
  if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || {
      cp "$ppm" "${SHOT_PNG%.png}.ppm"
      SHOT_PNG="${SHOT_PNG%.png}.ppm"
    }
  elif [[ -s "$ppm" ]]; then
    cp "$ppm" "${SHOT_PNG%.png}.ppm"
    SHOT_PNG="${SHOT_PNG%.png}.ppm"
  fi
fi

# The boot menu is 80x25 text on cirrus — a valid capture is small but non-trivial
# (the reference 01-boot-menu.png is ~2.4 KB). Treat >1000 bytes as "reached GUI".
shot_bytes=0
[[ -f "$SHOT_PNG" ]] && shot_bytes="$(wc -c <"$SHOT_PNG" | tr -d ' ')"
if [[ "$shot_bytes" -gt 1000 ]]; then
  log "BOOT VERIFIED: framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
  verify_rc=0
else
  log "VERIFY WARN: capture empty/too small (${shot_bytes} bytes). Raise VERIFY_WAIT and re-run."
  verify_rc=2
fi

log "Done. Bootable artifact: ${QCOW2_PATH}"
echo "$QCOW2_PATH"
exit "$verify_rc"

###############################################################################
# PITFALLS / NOTES (from the validated dry-run box, NOTES-FreeDOS.md):
#  * Freedoom's FREEDM1.WAD (~28 MB) takes ~90 s to load under pure TCG; fine
#    once loaded. Doom shareware (4 MB) is instant.
#  * Quake is Pentium-class + CPU-heavy under TCG; runs but not smooth. If the
#    shareware DOS4GW build stutters, swap in a DJGPP QUAKE.EXE (uses the bundled
#    CWSDPMI.EXE) — the menu command is unchanged.
#  * Arachne: first launch runs a VESA video-mode wizard; "Try selected graphics
#    mode" needs ONE mouse click (CTMOUSE is loaded). One-time, per the notes.
#    Modern HTTPS won't render — point it at local/retro pages.
#  * Wolfenstein 3D: STAGED, does not run (black screen under pentium AND 486 —
#    known Wolf3D v1.4 shareware timing/keyboard bug, not profile-fixable).
#  * GTA 1 is intentionally absent: Rockstar's free release is a Windows PE, no
#    DOS build exists.
#  * Mouse: PS/2 + CTMOUSE (int33h). Do NOT add usb-tablet — CTMOUSE reads PS/2.
#  * Keen 1 is PC-speaker-only; Cosmo uses PC speaker for effects. Keep
#    pcspk-audiodev=snd on every runtime/verification launcher.
#  * QEMU 11 removed -no-acpi; ACPI is disabled in the pinned machine above.
###############################################################################
