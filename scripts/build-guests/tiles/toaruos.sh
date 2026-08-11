#!/usr/bin/env bash
###############################################################################
# build-guests/tiles/toaruos.sh — reproduce the ToaruOS gallery station from source
#
# GUEST : ToaruOS v2.3.2 (klange/toaruos) — composited "Yutani" desktop
# TYPE  : LIVE ISO, no disk/install. The prebuilt release ISO boots straight to
#         the Yutani desktop. "Building" this station == fetching + integrity-
#         checking the exact upstream ISO, then a small repeatable content
#         bake: inject repo-shipped desktop launcher stubs (assets/toaruos/) into
#         the live CD's ramdisk so ToaruOS's OWN built-in apps/games (Mines,
#         Pong, Julia, Plasma, Calculator, Image Viewer) show as visible desktop
#         icons — no third-party binaries added (stays freely-distributable) —
#         and framebuffer-proving it reaches the GUI.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh Proxmox host):
#   1. Re-DOWNLOAD the real release ISO from GitHub (idempotent; skips if the
#      on-disk copy already matches the pinned SHA-256).
#   2. Verify SHA-256 against the value captured from the validated dry-run box.
#   3. (disk create) — N/A: live ISO, boots with `-boot d`, no writable disk.
#   4. (install automation) — N/A: unattended by nature; zero keystrokes needed.
#   5. era software: bake desktop launcher stubs into /ramdisk.igz via xorriso
#      (replaying the El-Torito boot record) so built-in apps/games appear as
#      visible desktop icons. Idempotent; SKIPS cleanly to a plain desktop if
#      xorriso/assets are unavailable. Pristine download cached as image.stock.iso.
#   6. Land the final bootable artifact at data/gallery-guests/toaruos/image.iso
#   7. FRAMEBUFFER-VERIFY: boot headless under QEMU (unique VNC + monitor
#      socket), wait for the desktop, `screendump` a PNG, and sanity-check it.
#
# AUTOMATION HONESTY:
#   * Steps 1,2,6,7 are FULLY automated and reproduce with no human input.
#   * There is exactly ONE cosmetic, non-blocking manual footnote at RUNTIME
#     (not build time): first boot opens a "Welcome to ToaruOS!" tutorial
#     window over the desktop. It does NOT block the station and `esc` won't close
#     it (would need a VNC pointer click). We deliberately leave it — it is fine
#     for a gallery station and requires no build-time action. See PITFALLS below.
#
# HYGIENE (per project rules):
#   * The verify VM is killed ONLY via its QEMU monitor `quit` (fallback: its
#     own pidfile). NEVER `pkill qemu*` — that would catch the live gallery
#     stations and macOS fan-out VMs.
#   * Namespaced work dir + Unix VNC/monitor sockets, so concurrent guest builds
#     never collide or reserve a host TCP port.
#   * OUT_DIR and WORK_DIR can keep every write under an isolated trial path.
#
# Idempotent + re-runnable. Safe to run repeatedly.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="toaruos"
DIR_NAME="toaruos"
VERSION="v2.3.2"
ISO_URL="https://github.com/klange/toaruos/releases/download/${VERSION}/image.iso"
ISO_SHA256="b1dc51bd48f2b4613237185c9acb1a9beb13ab6acdd2e01d9722f77343e4c9ea"
ISO_SIZE_BYTES="7483392" # sanity cross-check against the validated dry-run box

# Where the gallery keeps its guests. OUT_DIR is the direct artifact-directory
# override; GUESTS_ROOT remains compatible with older invocations.
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${OUT_DIR:-${GUESTS_ROOT}/${DIR_NAME}}"
WORK_DIR="${WORK_DIR:-${GUEST_DIR}/.build-work}"
ISO_PATH="${GUEST_DIR}/image.iso"        # final, booted artifact (stock + desktop-games bake)
STOCK_ISO="${GUEST_DIR}/image.stock.iso" # pristine upstream download (SHA-verified, cached)

# Repo-shipped desktop launcher stubs surfaced as visible desktop icons (G2
# content pass). Each references a binary ALREADY inside the stock ToaruOS
# ramdisk (mines.krk/pong/julia/plasma/calculator/imgviewer) — no third-party
# game binaries are added, so this stays fully freely-distributable (ToaruOS =
# NCSA license). See assets/toaruos/PROVENANCE.txt.
ASSETS_DIR="${ASSETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../assets/toaruos}"
DESKTOP_LAUNCHERS=(4_mines 5_pong 6_julia 7_plasma 8_calculator 9_viewer)

# Verify-boot knobs
VERIFY="${VERIFY:-1}" # set VERIFY=0 to skip the framebuffer boot
# The production launcher uses KVM. Set VERIFY_ACCEL=tcg for a slower fallback.
VERIFY_WAIT="${VERIFY_WAIT:-60}" # seconds to let the Yutani desktop fully paint
VERIFY_ACCEL="${VERIFY_ACCEL:-kvm}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

# Unique, namespaced runtime handles (never reused across concurrent builds)
RUN_DIR="${WORK_DIR}/run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
VNC_TARGET="${VNC_TARGET:-unix:${RUN_DIR}/vnc.sock}"
SHOT_PNG="${GUEST_DIR}/verify-desktop.png"

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }

###############################################################################
# The current streamhost manifest contract (display/audio backends differ in the
# headless verifier, but the guest-visible device set is the same):
#
#   qemu-system-x86_64 -machine pc -enable-kvm -cpu host -m 1024 -smp 2 \
#     -audiodev dbus,id=snd -device AC97,audiodev=snd \
#     -usb -device usb-tablet -vga std -cdrom image.iso -boot d \
#     -rtc base=localtime
#
# PERF: KVM-safe flip (2026-07-04). Was pure TCG; flipped to hardware KVM
#   (ACCEL=kvm -> -enable-kvm, -cpu host). VERIFIED: full desktop render + live
#   input under KVM. The current manifest uses a USB tablet for absolute input.
#   Revert acceleration only by setting VERIFY_ACCEL=tcg in this verifier; the
#   production source of truth is streamhost/tiles-manifest.sh.
###############################################################################

# --------------------------------------------------------------- 0. workspace
mkdir -p "$GUEST_DIR" "$WORK_DIR"

# ---------------------------------------------------- 1+2. download + verify
sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

need_download=1
if [[ -f "$STOCK_ISO" ]]; then
  if [[ "$(sha_of "$STOCK_ISO")" == "$ISO_SHA256" ]]; then
    log "Pristine stock ISO already present and SHA-256 matches — skipping download."
    need_download=0
  else
    log "Existing stock ISO checksum mismatch — re-downloading."
  fi
fi

if [[ "$need_download" -eq 1 ]]; then
  tmp="${STOCK_ISO}.part.$$"
  log "Downloading ToaruOS ${VERSION} ISO from ${ISO_URL}"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$ISO_URL"
  got="$(sha_of "$tmp")"
  if [[ "$got" != "$ISO_SHA256" ]]; then
    rm -f "$tmp"
    log "FATAL: downloaded ISO SHA-256 mismatch."
    log "  expected: $ISO_SHA256"
    log "  got:      $got"
    exit 1
  fi
  mv -f "$tmp" "$STOCK_ISO"
  log "Download OK, checksum verified."
fi

# Cheap size cross-check (defensive; checksum already implies this)
actual_size="$(wc -c <"$STOCK_ISO" | tr -d ' ')"
if [[ "$actual_size" != "$ISO_SIZE_BYTES" ]]; then
  log "WARN: stock ISO size ${actual_size} != expected ${ISO_SIZE_BYTES} (checksum still matched?)"
fi

# ---------------------- 3/4. disk / install — N/A (live ISO) ------------------
# ---------------------- 5. ERA SOFTWARE: desktop games/apps bake -------------
# Surface built-in ToaruOS apps/games as VISIBLE desktop icons by injecting the
# repo-shipped launcher stubs into the live CD's /ramdisk.igz (gzip ustar), then
# remastering the ISO with xorriso REPLAYING the original El-Torito boot record.
# Idempotent (skips if the ISO already carries the launchers). Any failure
# (no xorriso / bad ramdisk) SKIPS cleanly, copying the pristine stock ISO
# through so the station still boots to a plain desktop. Proven 2026-07-06: a
# from-STOCK rebuild boots to the Yutani desktop with all six icons.
# The launchers live INSIDE the compressed /ramdisk.igz (a gzip ustar), not on
# the ISO filesystem, so we must extract the ramdisk and inspect its tar TOC.
iso_has_games() {
  local iso="$1" tmpr found=0
  command -v xorriso >/dev/null 2>&1 || return 1
  tmpr="$(mktemp "${WORK_DIR}/ram.XXXXXX")"
  if xorriso -osirrox on -indev "$iso" -extract /ramdisk.igz "$tmpr" 2>/dev/null && [[ -s "$tmpr" ]]; then
    gzip -dc "$tmpr" 2>/dev/null | tar tf - 2>/dev/null |
      grep -qi 'home/local/Desktop/5_pong.launcher' && found=1
  fi
  rm -f "$tmpr"
  [[ "$found" -eq 1 ]]
}

bake_desktop_games() {
  if [[ -f "$ISO_PATH" ]] && iso_has_games "$ISO_PATH"; then
    log "bake: ISO already carries the desktop launchers — skipping."
    return 0
  fi
  if ! command -v xorriso >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 &&
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xorriso >/dev/null 2>&1 || true
  fi
  if ! command -v xorriso >/dev/null 2>&1; then
    log "bake: xorriso unavailable — SKIPPING games bake (booting plain stock desktop)."
    cp -f "$STOCK_ISO" "$ISO_PATH"
    return 0
  fi
  local staged=1 f
  for f in "${DESKTOP_LAUNCHERS[@]}"; do
    [[ -f "$ASSETS_DIR/Desktop/$f.launcher" ]] || {
      staged=0
      break
    }
  done
  if [[ "$staged" -ne 1 ]]; then
    log "bake: assets/toaruos/Desktop launchers missing — SKIPPING games bake (plain desktop)."
    cp -f "$STOCK_ISO" "$ISO_PATH"
    return 0
  fi

  local bwd
  bwd="$(mktemp -d "${WORK_DIR}/bake.XXXXXX")"
  # 1. pull the ramdisk out of the stock ISO
  if ! xorriso -osirrox on -indev "$STOCK_ISO" -extract /ramdisk.igz "$bwd/ramdisk.igz" 2>/dev/null ||
    [[ ! -s "$bwd/ramdisk.igz" ]]; then
    log "bake: could not extract /ramdisk.igz — SKIPPING (plain desktop)."
    rm -rf "$bwd"
    cp -f "$STOCK_ISO" "$ISO_PATH"
    return 0
  fi
  # 2. decompress -> append the launcher stubs under home/local/Desktop -> recompress
  gzip -dc "$bwd/ramdisk.igz" >"$bwd/ramdisk.tar"
  mkdir -p "$bwd/stage/home/local/Desktop"
  for f in "${DESKTOP_LAUNCHERS[@]}"; do
    install -m0644 "$ASSETS_DIR/Desktop/$f.launcher" "$bwd/stage/home/local/Desktop/$f.launcher"
  done
  (cd "$bwd/stage" && tar --append --format=ustar -f "$bwd/ramdisk.tar" home/local/Desktop/*.launcher)
  gzip -c "$bwd/ramdisk.tar" >"$bwd/ramdisk.igz.new"
  # 3. remaster: overwrite /ramdisk.igz on a copy of the stock ISO, boot record intact
  rm -f "$ISO_PATH"
  if ! xorriso -indev "$STOCK_ISO" -outdev "$ISO_PATH" \
    -boot_image any replay \
    -update "$bwd/ramdisk.igz.new" /ramdisk.igz \
    -commit >/dev/null 2>&1; then
    log "bake: xorriso remaster failed — SKIPPING (plain desktop)."
    rm -rf "$bwd"
    cp -f "$STOCK_ISO" "$ISO_PATH"
    return 0
  fi
  rm -rf "$bwd"
  if iso_has_games "$ISO_PATH"; then
    log "bake: desktop games/apps surfaced (Mines, Pong, Julia, Plasma, Calculator, Image Viewer)."
  else
    log "bake: WARN launchers not found in remastered ISO — falling back to plain stock."
    cp -f "$STOCK_ISO" "$ISO_PATH"
  fi
}

bake_desktop_games

log "Artifact ready:"
log "  ${ISO_PATH}  (stock ToaruOS ${VERSION} + desktop games/apps bake)"

# ------------------------------------------------- 7. framebuffer verification
if [[ "$VERIFY" -ne 1 ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  echo "$ISO_PATH"
  exit 0
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  log "WARN: $QEMU_BIN not found — cannot framebuffer-verify. Artifact still built."
  echo "$ISO_PATH"
  exit 0
fi

mkdir -p "$RUN_DIR"
# Never let a failed capture pass by reusing a previous run's proof image.
rm -f "$SHOT_PNG" "${SHOT_PNG%.png}.ppm"

# Clean shutdown helper: monitor `quit` first, pidfile SIGTERM as fallback.
# NEVER pkill by name (would kill live gallery stations / macOS VMs).
mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }

# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
cleanup() {
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
trap cleanup EXIT INT TERM

accel_args=()
case "$VERIFY_ACCEL" in
  kvm) accel_args=(-enable-kvm -cpu host) ;;
  tcg) accel_args=(-accel tcg -cpu qemu64) ;;
  *)
    log "FATAL: VERIFY_ACCEL must be kvm or tcg"
    exit 2
    ;;
esac

log "Framebuffer-verify: booting headless (${VERIFY_ACCEL}, VNC ${VNC_TARGET}, monitor ${MON_SOCK})"
# Same args as the live station, minus real audio backend (headless host has no PA):
# use -audiodev none so the AC97 device still probes exactly as in production.
"$QEMU_BIN" \
  -machine pc "${accel_args[@]}" -m 1024 -smp 2 \
  -audiodev none,id=snd -device AC97,audiodev=snd \
  -usb -device usb-tablet \
  -vga std -cdrom "$ISO_PATH" -boot d -rtc base=localtime \
  -vnc "$VNC_TARGET" \
  -monitor "unix:${MON_SOCK},server,nowait" \
  -pidfile "$PIDFILE" \
  -display none -daemonize

# Wait for monitor socket, then let the desktop compositor come up.
for _ in $(seq 1 20); do
  [[ -S "$MON_SOCK" ]] && break
  sleep 0.5
done
log "Waiting ${VERIFY_WAIT}s for the Yutani desktop..."
sleep "$VERIFY_WAIT"

# Grab the framebuffer. QEMU >=7 supports `screendump -f png`; fall back to PPM.
# The one-shot HMP socket can return before the PNG writer has fully settled;
# do not let EXIT quit QEMU while the proof is still being produced.
mon_cmd "screendump -f png ${SHOT_PNG}"
sleep 3
if [[ -s "$SHOT_PNG" ]]; then
  :
else
  ppm="${RUN_DIR}/shot.ppm"
  mon_cmd "screendump ${ppm}"
  sleep 1
  if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
    pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || cp "$ppm" "${SHOT_PNG%.png}.ppm"
  elif [[ -s "$ppm" ]]; then
    cp "$ppm" "${SHOT_PNG%.png}.ppm"
    SHOT_PNG="${SHOT_PNG%.png}.ppm"
  fi
fi

# Sanity-verify we actually captured a real desktop framebuffer (not a blank/
# tiny image). A live 1920x1080 Yutani desktop screendump is well over 20 KB.
shot_bytes=0
[[ -f "$SHOT_PNG" ]] && shot_bytes="$(wc -c <"$SHOT_PNG" | tr -d ' ')"
if [[ "$shot_bytes" -gt 20000 ]]; then
  log "GUI VERIFIED: framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
  verify_rc=0
else
  log "VERIFY WARN: framebuffer capture empty/too small (${shot_bytes} bytes)."
  log "  Increase VERIFY_WAIT and re-run, or inspect ${SHOT_PNG}."
  verify_rc=2
fi

# cleanup() runs on EXIT (monitor quit -> pidfile fallback; no pkill).
log "Done. Bootable artifact: ${ISO_PATH}"
echo "$ISO_PATH"
exit "$verify_rc"

###############################################################################
# PITFALLS (from the validated dry-run notes):
#  * First boot opens a "Welcome to ToaruOS!" tutorial window over the desktop.
#    Harmless, does NOT block the station; `esc` will not close it (needs a VNC
#    pointer click). Leaving it is correct for a gallery station.
#  * -vga std defaults to 1920x1080 and scales fine in the neko view. 512 MB
#    RAM also works; 1024 MB is the validated value.
#  * Requires a 64-bit CPU (guest refuses on 32-bit); host or qemu64 is correct.
###############################################################################
