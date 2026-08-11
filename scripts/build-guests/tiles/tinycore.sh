#!/usr/bin/env bash
#===============================================================================
# build-guests/tiles/tinycore.sh — reproduce the TinyCore Kernel Hive station from upstream
#===============================================================================
#
# GUEST : tinycore (streamhost VMID 82, udp/54082)
# OS    : Tiny Core Linux, latest STABLE x86 (32-bit) "TinyCore" GUI LiveCD
#         (FLWM + wbar desktop; version resolved at build time from
#         tinycorelinux.net/downloads.html).
# MODEL : LIVE ISO (runs entirely in guest RAM) + a scratch qcow2 (state.qcow2,
#         virtio) whose ONLY purpose is to hold the live `savevm golden`
#         VM-state snapshot. The LiveCD has no writable disk, so the fixture
#         (open terminal + xset tweaks) lives in the snapshot's RAM/device
#         state, NOT on disk. resetMode=loadvm.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh Proxmox host w/ gallery infra)
#   1. Resolves + downloads the latest stable TinyCore-<ver>.iso (x86) from the
#      official site (md5-verified via the upstream .md5.txt sidecar) -> ISO_DIR.
#   2. Creates the scratch state.qcow2 (3G, virtio) in OUT_DIR.
#   3. Boots the LiveCD headless with EXACTLY the production station device set
#      (see DEVICE-SET CONTRACT below; only display/audio BACKENDS differ,
#      which are not part of vmstate — snapshot is loadvm-portable to the
#      production dbus launcher; verified for this station family 2026-07-06).
#   4. Bakes the golden fixture fully automated:
#        - at the ISOLINUX menu: TAB to edit the default 'tc' entry and append
#          the official `text` bootcode -> GUI extensions still load (cde) but
#          X does NOT autostart; we land at a driveable tc@box:~$ text shell.
#        - in-guest payload fetched from this host over SLIRP (10.0.2.2):
#          `tce-load -wi openssh` (version-matched upstream tcz repo), sshd
#          config from .orig, gallery pubkey -> /home/tc/.ssh/authorized_keys,
#          start sshd, and drop ~/.X.d/gallery-fixture (xset s off / noblank /
#          -dpms + `aterm &`) so the desktop comes up ALREADY curated.
#        - `startx` -> FLWM desktop + wbar + an open aterm terminal.
#        - park the pointer inside the aterm and click (FLWM focus-follows-
#          mouse; tinyX ignores the usb-tablet, so the pointer is driven over
#          the legacy QMP relative path, exactly like the live station's bake).
#        - clean the prompt, then `savevm golden`.
#   5. PROVES the contract before declaring success:
#        - ssh probe (user tc) with the gallery key through a QMP hostfwd
#        - keyboard reactivity: typed probe visibly changes the framebuffer
#        - idle determinism: two screendumps 5 s apart byte-identical
#        - golden round-trip: dirty -> `loadvm golden` -> byte-identical frame;
#          ssh still answers after loadvm
#   6. Leaves state.qcow2 (golden inside) + PNG proof + BUILD-INFO in OUT_DIR.
#
# AUTOMATION HONESTY
#   FULLY AUTOMATED — zero human interaction. The only console-typed lines are
#   the boot-menu edit, the payload fetch line, `startx`, a focus probe and
#   `clear`; everything heavyweight runs in the fetched payload script.
#
# DEVICE-SET CONTRACT (matches tiles/tinycore/qemu-streamhost.sh EXACTLY):
#   -enable-kvm -m 768 -smp 2 -machine pc -cpu host -rtc base=localtime
#   -drive file=state.qcow2,if=virtio,format=qcow2 -cdrom <ISO> -boot d
#   -vga std -device AC97,audiodev=snd0 -usb -device usb-tablet
#   NO explicit -netdev (QEMU default SLIRP user NIC; the host->guest ssh
#   forward is added POST-BOOT via QMP hostfwd_add, never as a -device, so
#   `-loadvm golden` always matches).
#
# IDEMPOTENT / RE-RUNNABLE
#   - ISO download skipped when the md5 already matches (FORCE_DOWNLOAD=1 to
#     refetch). Bake skipped when state.qcow2 already has a 'golden' snapshot
#     (REBAKE=1 rebakes; the old disk is moved aside, not deleted).
#   - All sockets/pidfiles live in a per-run mktemp dir; QEMU is killed ONLY
#     via its own pidfile (never pkill); the payload http.server dies with us.
#
# HYGIENE (per gallery rules)
#   - Never touches /data/vms/streamhost/stations/* — this builds the ARTIFACT
#     (canonical /data/gallery-guests/TinyCore + /data/isos); wiring the live
#     station is the launcher's job (see PRODUCTION WIRING at the end).
#   - OUT_DIR / WORK_DIR / ISO_DIR / ports are env-overridable for fully namespaced trials.
#
# Usage:
#   scripts/build-guests/tiles/tinycore.sh
#     OUT_DIR=…        artifact dir           (default /data/gallery-guests/TinyCore)
#     WORK_DIR=…       disposable work dir    (default: a private dir under TMPDIR)
#     ISO_DIR=…        ISO cache dir          (default /data/isos)
#     TC_VERSION=…     e.g. 17.0              (default: resolve from downloads.html)
#     BAKE_SSH_PORT=…  host loopback ssh fwd  (default 58821 — NOT the live 5882)
#     HTTP_PORT=…      payload server port    (default 58820)
#     GALLERY_KEY=…    ssh keypair            (default /root/.ssh/gallery_guest_key)
#     REBAKE=1         force a fresh golden bake
#===============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# Parameters (all overridable from the environment)
#------------------------------------------------------------------------------
KEY_NAME="tinycore"
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
OUT_DIR="${OUT_DIR:-${GUESTS_ROOT}/TinyCore}"
ISO_DIR="${ISO_DIR:-/data/isos}"

TC_SITE="${TC_SITE:-http://tinycorelinux.net}"                     # upstream does not serve HTTPS
TC_MIRROR="${TC_MIRROR:-https://distro.ibiblio.org/tinycorelinux}" # official HTTPS mirror, preferred
TC_VERSION="${TC_VERSION:-}"                                       # e.g. 17.0; empty = resolve latest stable
TC_ARCH="${TC_ARCH:-x86}"                                          # the station is the 32-bit x86 GUI ISO
ISO_URL="${ISO_URL:-}"                                             # full override (skips resolve)
ISO_MD5="${ISO_MD5:-}"

STATE_NAME="${STATE_NAME:-state.qcow2}"
STATE_SIZE="${STATE_SIZE:-3G}"
MEM_MB="${MEM_MB:-768}"
SMP="${SMP:-2}"

GALLERY_KEY="${GALLERY_KEY:-/root/.ssh/gallery_guest_key}"
BAKE_SSH_PORT="${BAKE_SSH_PORT:-58821}" # bake-time only; production adds its own (5882)
HTTP_PORT="${HTTP_PORT:-58820}"         # payload one-shot http.server (127.0.0.1)
MENU_WAIT="${MENU_WAIT:-6}"             # seconds for the ISOLINUX menu to paint
TEXT_BOOT_WAIT="${TEXT_BOOT_WAIT:-20}"  # seconds to the text-mode shell
X_WAIT="${X_WAIT:-12}"                  # seconds for startx -> desktop
REBAKE="${REBAKE:-0}"

STATE_PATH="${OUT_DIR}/${STATE_NAME}"
if [[ -n "${WORK_DIR:-}" ]]; then
  WORK="$WORK_DIR"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/tinycore-bake.XXXXXX")"
fi
QMP_SOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"
HTTPPID="${WORK}/http.pid"
QLOG="${WORK}/qemu.log"

log() { printf '\033[1;36m[tinycore]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[tinycore][warn]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[tinycore][err]\033[0m %s\n' "$*" >&2
  exit 1
}

#------------------------------------------------------------------------------
# Teardown — QEMU by ITS OWN pidfile only (never pkill), then the http server.
#------------------------------------------------------------------------------
teardown() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
  fi
  if [[ -f "$HTTPPID" ]]; then kill "$(cat "$HTTPPID")" 2>/dev/null || true; fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap teardown EXIT

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "need qemu-system-x86_64"
command -v qemu-img >/dev/null 2>&1 || die "need qemu-img"
command -v curl >/dev/null 2>&1 || die "need curl"
command -v python3 >/dev/null 2>&1 || die "need python3"
command -v md5sum >/dev/null 2>&1 || die "need md5sum"
mkdir -p "$OUT_DIR" "$ISO_DIR"

#==============================================================================
# STEP 1 — resolve the latest STABLE TinyCore x86 release
#   downloads.html carries "The Core x86 Project … Version N.N" for the current
#   stable. Pin with TC_VERSION=N.N, or bypass with ISO_URL=… [ISO_MD5=…].
#==============================================================================
if [[ -z "$ISO_URL" ]]; then
  if [[ -z "$TC_VERSION" ]]; then
    log "resolving latest stable from ${TC_SITE}/downloads.html"
    TC_VERSION="$(curl -fsSL --retry 3 --connect-timeout 20 "${TC_SITE}/downloads.html" |
      sed -e 's/<[^>]*>/ /g' |
      grep -A4 -i "core ${TC_ARCH} project" |
      grep -o 'Version [0-9][0-9]*\.[0-9][0-9]*' | head -1 | awk '{print $2}')" || true
    [[ -n "$TC_VERSION" ]] || die "could not resolve the current TinyCore ${TC_ARCH} version (pin TC_VERSION=…)"
  fi
  TC_MAJOR="${TC_VERSION%%.*}"
  ISO_FILE="TinyCore-${TC_VERSION}.iso"
  REL_PATH="${TC_MAJOR}.x/${TC_ARCH}/release"
  # Resolve the version from upstream's HTTP-only page, but prefer its HTTPS
  # ibiblio mirror for the ISO and checksum bytes.
  ISO_URL="${TC_MIRROR}/${REL_PATH}/${ISO_FILE}"
  ISO_URL_FALLBACK="${TC_SITE}/${REL_PATH}/${ISO_FILE}"
  if [[ -z "$ISO_MD5" ]]; then
    ISO_MD5="$(curl -fsSL --retry 3 --connect-timeout 20 "${ISO_URL}.md5.txt" 2>/dev/null | awk '{print $1}')" ||
      ISO_MD5="$(curl -fsSL --retry 3 --connect-timeout 20 "${ISO_URL_FALLBACK}.md5.txt" 2>/dev/null | awk '{print $1}')" ||
      true
  fi
else
  ISO_FILE="$(basename "$ISO_URL")"
  ISO_URL_FALLBACK=""
  TC_VERSION="${TC_VERSION:-unknown}"
fi
ISO_PATH="${ISO_DIR}/${ISO_FILE}"
CANONICAL_ISO="${ISO_DIR}/TinyCore.iso"
log "release: Tiny Core ${TC_VERSION} (${TC_ARCH} GUI LiveCD) — ${ISO_FILE}${ISO_MD5:+ md5=${ISO_MD5}}"

#==============================================================================
# STEP 2 — download the ISO (md5-verified, skip when already valid)
#==============================================================================
iso_ok() {
  [[ -s "$ISO_PATH" && -n "$ISO_MD5" ]] || return 1
  [[ "$(md5sum "$ISO_PATH" | awk '{print $1}')" == "$ISO_MD5" ]]
}
if [[ "${FORCE_DOWNLOAD:-0}" != "1" ]] && iso_ok; then
  log "ISO present + md5 OK — skipping download"
else
  tmp="${ISO_PATH}.part"
  rm -f "$tmp"
  ok=0
  for url in "$ISO_URL" ${ISO_URL_FALLBACK:+"$ISO_URL_FALLBACK"}; do
    log "downloading ${url}"
    curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$url" && {
      ok=1
      break
    }
    warn "mirror failed, trying next"
  done
  [[ "$ok" == "1" ]] || die "all mirrors failed for ${ISO_FILE}"
  if [[ -n "$ISO_MD5" ]]; then
    got="$(md5sum "$tmp" | awk '{print $1}')"
    [[ "$got" == "$ISO_MD5" ]] || die "MD5 mismatch: got=$got want=$ISO_MD5"
    log "md5 verified OK"
  else
    warn "no md5 sidecar available — size-only sanity"
    [[ "$(stat -c%s "$tmp")" -gt 15000000 ]] || die "downloaded ISO suspiciously small"
  fi
  mv -f "$tmp" "$ISO_PATH"
fi

# The emitted launcher uses /data/isos/TinyCore.iso. Keep the versioned file
# for provenance and converge that canonical name inside the selected ISO_DIR.
if [[ "$ISO_PATH" != "$CANONICAL_ISO" ]]; then
  if [[ -e "$CANONICAL_ISO" && ! -L "$CANONICAL_ISO" ]]; then
    if cmp -s "$ISO_PATH" "$CANONICAL_ISO"; then
      log "canonical ISO copy already matches: ${CANONICAL_ISO}"
    else
      rm -f "$CANONICAL_ISO"
      ln -s "$(basename "$ISO_PATH")" "$CANONICAL_ISO"
      log "canonical ISO updated: ${CANONICAL_ISO} -> $(basename "$ISO_PATH")"
    fi
  else
    ln -sfn "$(basename "$ISO_PATH")" "$CANONICAL_ISO"
    log "canonical ISO: ${CANONICAL_ISO} -> $(basename "$ISO_PATH")"
  fi
fi

#==============================================================================
# STEP 3 — gallery ssh keypair (shared by all ssh-exec stations; generate if absent)
#==============================================================================
if [[ ! -f "${GALLERY_KEY}.pub" ]]; then
  log "generating gallery guest keypair at ${GALLERY_KEY}"
  ssh-keygen -t ed25519 -N "" -C gallery_guest -f "$GALLERY_KEY" >/dev/null
fi
PUBKEY="$(cat "${GALLERY_KEY}.pub")"

#==============================================================================
# STEP 4 — scratch state.qcow2 (the golden snapshot container, virtio)
#==============================================================================
if [[ -f "$STATE_PATH" ]] && qemu-img snapshot -l "$STATE_PATH" 2>/dev/null | grep -qw golden; then
  if [[ "$REBAKE" != "1" ]]; then
    log "state.qcow2 already holds a 'golden' snapshot — nothing to do (REBAKE=1 to rebake)"
    exit 0
  fi
  warn "REBAKE=1 — moving old golden disk aside"
  mv -f "$STATE_PATH" "${STATE_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
fi
[[ -f "$STATE_PATH" ]] || qemu-img create -q -f qcow2 "$STATE_PATH" "$STATE_SIZE"

#==============================================================================
# STEP 5 — payload the guest will fetch over SLIRP (10.0.2.2 = this host's lo)
#   Runs as user tc in the text-mode shell. Drops ~/.X.d/gallery-fixture so the
#   later `startx` brings the desktop up ALREADY curated (xset tweaks + aterm —
#   the same plain `aterm` the wbar Terminal icon execs).
#==============================================================================
mkdir -p "${WORK}/payload"
cat >"${WORK}/payload/tc-payload.sh" <<PAYLOAD
#!/bin/sh
# osgallery tinycore golden-bake payload — runs IN-GUEST as tc (text mode).
set -e
n=0; until tce-load -wi openssh; do n=\$((n+1)); [ \$n -ge 5 ] && exit 1; sleep 3; done
sudo cp -p /usr/local/etc/ssh/sshd_config.orig /usr/local/etc/ssh/sshd_config
mkdir -p /home/tc/.ssh && chmod 700 /home/tc/.ssh
echo '${PUBKEY}' > /home/tc/.ssh/authorized_keys
chmod 600 /home/tc/.ssh/authorized_keys
sudo /usr/local/etc/init.d/openssh start   # generates host keys on first start
mkdir -p /home/tc/.X.d
cat > /home/tc/.X.d/gallery-fixture <<'EOF'
# osgallery golden fixture: no screensaver/blank/DPMS, one open terminal.
xset s off; xset s noblank; xset -dpms
aterm &
EOF
echo PAYLOAD-OK
PAYLOAD

log "starting payload http.server on 127.0.0.1:${HTTP_PORT}"
(cd "${WORK}/payload" && exec python3 -m http.server --bind 127.0.0.1 "$HTTP_PORT") \
  >"${WORK}/http.log" 2>&1 &
echo $! >"$HTTPPID"

#==============================================================================
# STEP 6 — shared build-time QMP driver (runtime /root/cdrv.py stays separate)
#==============================================================================
LABQMP="$(cd "$(dirname "$0")/../../lib" && pwd)/labqmp.py"
[[ -f "$LABQMP" ]] || die "shared QMP helper missing: $LABQMP"
QDRV_BIN=(python3 "$LABQMP" "$QMP_SOCK")
qdrv() { "${QDRV_BIN[@]}" "$@"; }
typeline() { qdrv typeb64 "$(printf '%s' "$1" | base64 | tr -d '\n')" key ret; }

#==============================================================================
# STEP 7 — boot the LiveCD with the PRODUCTION device set (headless backends)
#   -vnc gives QEMU an active graphic console: the legacy relative-mouse path
#   (HMP mouse_move) needs one, and tinyX is relative-only (ignores usb-tablet).
#==============================================================================
launch_vm() { # $@ = extra args (e.g. -loadvm golden). Device set NEVER varies.
  rm -f "$QMP_SOCK" "$PIDFILE" "${WORK}/vnc.sock"
  qemu-system-x86_64 \
    -name "bake-${KEY_NAME}" \
    -enable-kvm -m "$MEM_MB" -smp "$SMP" \
    -machine pc -cpu host \
    -rtc base=localtime \
    -drive file="$STATE_PATH",if=virtio,format=qcow2 -cdrom "$ISO_PATH" -boot d \
    -vga std \
    -display none -vnc "unix:${WORK}/vnc.sock" \
    -audiodev none,id=snd0 -device AC97,audiodev=snd0 \
    -usb -device usb-tablet \
    -qmp "unix:${QMP_SOCK},server=on,wait=off" \
    -pidfile "$PIDFILE" \
    "$@" \
    >"$QLOG" 2>&1 &
  for _ in $(seq 1 40); do
    [[ -S "$QMP_SOCK" && -f "$PIDFILE" ]] && break
    sleep 0.5
  done
  [[ -S "$QMP_SOCK" ]] || die "QMP socket never appeared (see $QLOG)"
}
stop_vm() { # kill the bake/verify VM by ITS OWN pidfile, wait it out
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    fi
    rm -f "$PIDFILE"
  fi
  rm -f "$QMP_SOCK" "${WORK}/vnc.sock"
}

log "booting bake VM (qmp ${QMP_SOCK})"
launch_vm

#==============================================================================
# STEP 8 — boot menu: TAB-edit the default entry, append the `text` bootcode
#   The ISO's isolinux uses menu.c32 (default label 'tc', APPEND "loglevel=3
#   cde"). TAB opens the editable cmdline; we append " text" so the onboard
#   GUI extensions still install but X does not autostart.
#==============================================================================
log "waiting ${MENU_WAIT}s for the ISOLINUX menu, then TAB + ' text'"
sleep "$MENU_WAIT"
qdrv shot "${WORK}/menu.ppm" >/dev/null
qdrv key tab sleep 0.8
qdrv type " text" sleep 0.3 key ret

log "waiting ${TEXT_BOOT_WAIT}s + frame-stable for the text-mode tc shell"
sleep "$TEXT_BOOT_WAIT"
prev=""
for _ in $(seq 1 30); do
  qdrv shot "${WORK}/poll.ppm" >/dev/null
  cur="$(md5sum "${WORK}/poll.ppm" | awk '{print $1}')"
  [[ -n "$prev" && "$cur" == "$prev" ]] && break
  prev="$cur"
  sleep 3
done
# Prove the shell is live: a bare Enter must paint a fresh prompt line.
alive=0
for _ in $(seq 1 10); do
  qdrv shot "${WORK}/pre-ret.ppm" >/dev/null
  qdrv key ret sleep 1 shot "${WORK}/post-ret.ppm" >/dev/null
  cmp -s "${WORK}/pre-ret.ppm" "${WORK}/post-ret.ppm" || {
    alive=1
    break
  }
  sleep 3
done
[[ "$alive" == "1" ]] || {
  qdrv shot "${OUT_DIR}/bake-failed.ppm" >/dev/null
  die "text-mode shell never became reactive (screendump: ${OUT_DIR}/bake-failed.ppm)"
}

#==============================================================================
# STEP 9 — payload (ssh + fixture autostart), then ssh probe
#==============================================================================
log "fetching + running the in-guest payload (openssh.tcz + key + ~/.X.d fixture)"
typeline "while ! wget -qO- http://10.0.2.2:${HTTP_PORT}/tc-payload.sh | sh; do sleep 2; done"

log "adding bake-time ssh forward 127.0.0.1:${BAKE_SSH_PORT} -> 10.0.2.15:22"
qdrv hostfwd "tcp:127.0.0.1:${BAKE_SSH_PORT}-10.0.2.15:22" >/dev/null

SSH=(ssh -i "$GALLERY_KEY" -p "$BAKE_SSH_PORT" -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes
  -o LogLevel=ERROR tc@127.0.0.1)
probe=""
for _ in $(seq 1 40); do
  probe="$("${SSH[@]}" 'uname -sr; cat /usr/share/doc/tc/release.txt 2>/dev/null; true' 2>/dev/null)" && [[ -n "$probe" ]] && break
  sleep 3
done
[[ -n "$probe" ]] || {
  qdrv shot "${OUT_DIR}/bake-failed.ppm" >/dev/null
  die "ssh probe never succeeded — payload failed? (screendump: ${OUT_DIR}/bake-failed.ppm)"
}
log "ssh probe OK: $(echo "$probe" | tr '\n' ' ')"

#==============================================================================
# STEP 10 — startx -> curated desktop (fixture applied by ~/.X.d), focus aterm
#==============================================================================
log "startx (desktop comes up with xset tweaks + aterm via ~/.X.d)"
typeline "startx"
sleep "$X_WAIT"
prev=""
for _ in $(seq 1 20); do
  qdrv shot "${WORK}/xpoll.ppm" >/dev/null
  cur="$(md5sum "${WORK}/xpoll.ppm" | awk '{print $1}')"
  [[ -n "$prev" && "$cur" == "$prev" ]] && break
  prev="$cur"
  sleep 3
done

xq="$("${SSH[@]}" 'DISPLAY=:0.0 xset q 2>/dev/null | grep -A2 "Screen Saver"' 2>/dev/null || true)"
echo "$xq" | grep -Eq 'timeout: +0' || warn "xset q did not confirm screensaver-off (got: ${xq:-n/a})"

log "parking pointer inside the aterm + click (FLWM focus-follows-mouse)"
qdrv mouserel 250 150 sleep 0.3 button 1 sleep 0.15 button 0 sleep 0.5

log "keyboard focus probe (typed chars must change the framebuffer)"
qdrv shot "${WORK}/prefocus.ppm" >/dev/null
typeline "echo FOCUSPROBE"
sleep 1
qdrv shot "${WORK}/postfocus.ppm" >/dev/null
cmp -s "${WORK}/prefocus.ppm" "${WORK}/postfocus.ppm" &&
  die "typing did not reach the aterm (focus failed — is the terminal open?)"

typeline "clear"
sleep 1.5

#==============================================================================
# STEP 11 — determinism check + savevm golden, then kill the bake VM
#==============================================================================
log "idle-determinism check (two screendumps 5 s apart must be byte-identical)"
qdrv shot "${WORK}/g1.ppm" >/dev/null
sleep 5
qdrv shot "${WORK}/g2.ppm" >/dev/null
cmp -s "${WORK}/g1.ppm" "${WORK}/g2.ppm" || die "idle animation detected — fixture not deterministic"
log "  OK: zero idle animation"

log "savevm golden"
qdrv delvm golden >/dev/null 2>&1 || true
qdrv savevm golden >/dev/null
qdrv querysnap | grep -qw golden || die "savevm golden did not stick"
stop_vm

#==============================================================================
# STEP 12 — COLD-START VERIFICATION (exact production semantics)
#   Fresh QEMU process, `-loadvm golden` at launch, hostfwd re-added via QMP —
#   precisely what the production station launcher does on every start. All final
#   proofs run here (a fresh process also sidesteps stale display-surface
#   artifacts a long-lived clientless bake VM can accumulate). Keyboard input
#   still lands in the aterm: pointer position and window focus are part of
#   the restored vmstate.
#==============================================================================
log "cold-start verify: fresh QEMU with -loadvm golden"
launch_vm -loadvm golden
sleep 3
qdrv hostfwd "tcp:127.0.0.1:${BAKE_SSH_PORT}-10.0.2.15:22" >/dev/null

qdrv shot "${WORK}/v1.ppm" >/dev/null
sleep 5
qdrv shot "${WORK}/v2.ppm" >/dev/null
cmp -s "${WORK}/v1.ppm" "${WORK}/v2.ppm" || die "restored fixture not idle-deterministic"
log "  OK: restored fixture idle-deterministic"

probe2=""
for _ in $(seq 1 10); do
  probe2="$("${SSH[@]}" 'echo SSH-RESTORED-OK' 2>/dev/null)" && break
  sleep 2
done
[[ "$probe2" == "SSH-RESTORED-OK" ]] || die "ssh dead after cold -loadvm golden start"
log "  OK: ssh answers after a cold -loadvm golden start"

log "golden round-trip: dirty -> loadvm golden -> byte-identical frame"
typeline "echo DIRTY"
sleep 1
qdrv shot "${WORK}/vd.ppm" >/dev/null
cmp -s "${WORK}/v1.ppm" "${WORK}/vd.ppm" && die "typing did not change the frame (input dead?)"
qdrv loadvm golden sleep 2 shot "${WORK}/vr.ppm" >/dev/null
cmp -s "${WORK}/v1.ppm" "${WORK}/vr.ppm" || die "loadvm golden != restored fixture frame"
log "  OK: loadvm golden restores the exact fixture frame"

probe3="$("${SSH[@]}" 'echo SSH-AFTER-LOADVM-OK' 2>/dev/null || true)"
[[ "$probe3" == "SSH-AFTER-LOADVM-OK" ]] || die "ssh dead after loadvm golden"
log "  OK: ssh still answers after loadvm golden"

# Canonical PNG proof of the ready-to-serve fixture (from the verify process).
if command -v pnmtopng >/dev/null 2>&1; then
  pnmtopng "${WORK}/v1.ppm" >"${OUT_DIR}/fixture-golden.png" 2>/dev/null || true
elif command -v convert >/dev/null 2>&1; then
  convert "${WORK}/v1.ppm" "${OUT_DIR}/fixture-golden.png" 2>/dev/null || true
else
  cp "${WORK}/v1.ppm" "${OUT_DIR}/fixture-golden.ppm"
fi

#==============================================================================
# STEP 13 — shut the verify VM down; the artifact is the disk, not the process
#==============================================================================
teardown
trap - EXIT

cat >"${OUT_DIR}/BUILD-INFO.txt" <<EOF
tinycore tile artifact — built $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/build-guests/tiles/tinycore.sh
  guest      : Tiny Core Linux ${TC_VERSION} ${TC_ARCH} GUI LiveCD (FLWM+wbar, RAM-only)
  iso        : ${ISO_PATH}
  iso md5    : ${ISO_MD5:-unverified}
  state disk : ${STATE_PATH} (virtio; holds the internal 'golden' savevm snapshot — NEVER delete)
  ssh        : tc@guest via gallery key ${GALLERY_KEY}.pub baked in authorized_keys;
               guest eth0 DHCP 10.0.2.15 on the DEFAULT SLIRP NIC; forward is
               host-side (QMP hostfwd_add), production port 5882
  fixture    : FLWM desktop + wbar + open aterm, steady caret, xset s off/noblank/-dpms
  verified   : cold-start -loadvm golden (fresh QEMU) -> idle-deterministic,
               ssh, keyboard-reactive, dirty->loadvm byte-identical, ssh again
EOF

cat <<EOF

[tinycore] BUILD COMPLETE
  ISO (boot medium)     : ${ISO_PATH}
  Golden state disk     : ${STATE_PATH}
  Fixture proof         : ${OUT_DIR}/fixture-golden.png
  Build manifest        : ${OUT_DIR}/BUILD-INFO.txt

  ---- PRODUCTION WIRING (streamhost tile 'tinycore', VMID 82, udp/54082) -----
  # stations-manifest.sh emit stanza (only the --cdrom path changes vs today):
  #   --cdrom ${ISO_PATH} --boot d
  # The station launcher (hand-baked golden launcher) must:
  #   * copy/point at ${STATE_PATH} as its state.qcow2 (create-if-missing ONLY)
  #   * keep the EXACT device set in this script's STEP 7 (swap -display/-vnc
  #     for -display dbus,p2p=on,audiodev=snd0 and -audiodev none for
  #     -audiodev dbus,… — backends are not part of vmstate)
  #   * boot with -loadvm golden when the snapshot exists
  #   * after boot: QMP  hostfwd_add tcp:127.0.0.1:5882-10.0.2.15:22
  # ssh exec channel:  ssh -i ${GALLERY_KEY} -p 5882 tc@127.0.0.1
  # POINTER NOTE: SH_POINTER=abs with cursor calibration (scale 0.5, off
  # 138/250) is the station's streamhost transport config — re-verify it after
  # any TinyCore major bump (Xvesa maps abs input at 2x with an origin shift).
  -----------------------------------------------------------------------------
EOF
