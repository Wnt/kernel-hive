#!/usr/bin/env bash
#===============================================================================
# build-guests/tiles/alpine.sh — reproduce the Alpine Kernel Hive station from upstream
#===============================================================================
#
# GUEST : alpine (streamhost VMID 81, udp/54081)
# OS    : Alpine Linux, latest STABLE x86_64 "standard" LiveCD (resolved at
#         build time from dl-cdn.alpinelinux.org latest-releases.yaml).
# MODEL : LIVE ISO (runs entirely in guest RAM) + a scratch qcow2 (state.qcow2)
#         whose ONLY purpose is to hold the live `savevm golden` VM-state
#         snapshot. The LiveCD has no writable root disk, so that qcow2 is the
#         only block device QEMU can store the golden reset point into.
#         resetMode=loadvm — `loadvm golden` restores the fixture live.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh Proxmox host w/ gallery infra)
#   1. Resolves + downloads the latest stable alpine-standard x86_64 ISO from
#      the official CDN (sha256-verified from latest-releases.yaml) -> ISO_DIR.
#      The STANDARD flavor matters: it carries the apk repo ON the ISO
#      (/media/cdrom/apks), so `apk add openssh` works with no network repo.
#   2. Creates the scratch state.qcow2 (2G) in OUT_DIR.
#   3. Boots the LiveCD headless with EXACTLY the production station device set
#      (see DEVICE-SET CONTRACT below; only display/audio BACKENDS differ,
#      which are not part of vmstate — so the snapshot is loadvm-portable to
#      the production dbus launcher).
#   4. Bakes the golden fixture fully automated over QMP + an in-guest payload
#      fetched from this host over SLIRP (guest reaches us at 10.0.2.2):
#        - log in as root (LiveCD, no password)
#        - static eth0 10.0.2.15/24, gw 10.0.2.2 (no DHCP client in fixture)
#        - apk add openssh (from the ISO's own apks) + ssh-keygen -A
#        - install the gallery pubkey as /root/.ssh/authorized_keys + start sshd
#        - fixture tweaks: fbcon cursor_blink OFF (steady caret), console
#          blank + VESA powerdown OFF (no idle animation, DPMS-proof)
#        - clean ASCII fixture banner + fresh root prompt (the keyboard-
#          reactive surface), then `savevm golden`
#   5. PROVES the contract before declaring success:
#        - ssh probe with the gallery key through a QMP-added hostfwd
#        - idle determinism: two screendumps 5 s apart byte-identical
#        - golden round-trip: dirty the screen -> `loadvm golden` -> frame
#          byte-identical to the baked fixture; ssh still answers after loadvm
#   6. Leaves state.qcow2 (golden inside) + PNG proof + BUILD-INFO in OUT_DIR.
#
# AUTOMATION HONESTY
#   FULLY AUTOMATED — zero human interaction. Login + all in-guest setup is
#   driven over QMP input-send-event; the bulk of the setup runs as a payload
#   script the guest fetches from a one-shot loopback http.server via SLIRP
#   (10.0.2.2), so only four short lines are ever "typed" at the console.
#
# DEVICE-SET CONTRACT (matches tiles/alpine/qemu-streamhost.sh EXACTLY):
#   -enable-kvm -m 1024 -smp 2 -cpu host -rtc base=localtime
#   -cdrom <ISO> -boot d -drive file=state.qcow2,if=ide,format=qcow2
#   -vga std -device AC97,audiodev=snd0 -usb -device usb-tablet
#   NO -machine (QEMU default pc), NO explicit -netdev (QEMU default SLIRP
#   user NIC — the guest sees 10.0.2.0/24; the host->guest ssh forward is
#   added POST-BOOT via QMP hostfwd_add, never as a -device, so
#   `-loadvm golden` always matches). Do not "fix" any of this: the golden
#   snapshot records the device set and the production launcher must match.
#
# IDEMPOTENT / RE-RUNNABLE
#   - ISO download skipped when the sha256 already matches (FORCE_DOWNLOAD=1
#     to refetch). Bake skipped when state.qcow2 already has a 'golden'
#     snapshot (REBAKE=1 to rebake; the old disk is moved aside, not deleted).
#   - All sockets/pidfiles live in a per-run mktemp dir; QEMU is killed ONLY
#     via its own pidfile (never pkill); the payload http.server dies with us.
#
# HYGIENE (per gallery rules)
#   - Never touches /data/vms/streamhost/tiles/* — this builds the ARTIFACT
#     (canonical /data/gallery-guests/Alpine + /data/isos); wiring a live station
#     to it is the station launcher's job (see PRODUCTION WIRING at the end).
#   - OUT_DIR / WORK_DIR / ISO_DIR / ports are env-overridable so trial runs can be fully
#     namespaced (e.g. under /data/vms/soltest/).
#
# Usage:
#   scripts/build-guests/tiles/alpine.sh
#     OUT_DIR=…        artifact dir           (default /data/gallery-guests/Alpine)
#     WORK_DIR=…       disposable work dir    (default: a private dir under TMPDIR)
#     ISO_DIR=…        ISO cache dir          (default /data/isos)
#     ALPINE_BRANCH=…  e.g. v3.24             (default: latest-stable)
#     BAKE_SSH_PORT=…  host loopback ssh fwd  (default 58811 — NOT the live 5881)
#     HTTP_PORT=…      payload server port    (default 58810)
#     GALLERY_KEY=…    ssh keypair            (default /root/.ssh/gallery_guest_key)
#     REBAKE=1         force a fresh golden bake
#===============================================================================
set -euo pipefail

#------------------------------------------------------------------------------
# Parameters (all overridable from the environment)
#------------------------------------------------------------------------------
KEY_NAME="alpine"
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
OUT_DIR="${OUT_DIR:-${GUESTS_ROOT}/Alpine}"
ISO_DIR="${ISO_DIR:-/data/isos}"

ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_BRANCH="${ALPINE_BRANCH:-latest-stable}"   # or pin e.g. v3.24
ALPINE_FLAVOR="${ALPINE_FLAVOR:-alpine-standard}" # standard = apks on the ISO
ALPINE_ARCH="${ALPINE_ARCH:-x86_64}"
ISO_URL="${ISO_URL:-}" # full override (skips resolve)
ISO_SHA256="${ISO_SHA256:-}"

STATE_NAME="${STATE_NAME:-state.qcow2}"
STATE_SIZE="${STATE_SIZE:-2G}"
MEM_MB="${MEM_MB:-1024}"
SMP="${SMP:-2}"

GALLERY_KEY="${GALLERY_KEY:-/root/.ssh/gallery_guest_key}"
BAKE_SSH_PORT="${BAKE_SSH_PORT:-58811}" # bake-time only; production adds its own (5881)
HTTP_PORT="${HTTP_PORT:-58810}"         # payload one-shot http.server (127.0.0.1)
BOOT_WAIT="${BOOT_WAIT:-30}"            # seconds before login-prompt polling starts
REBAKE="${REBAKE:-0}"

STATE_PATH="${OUT_DIR}/${STATE_NAME}"
if [[ -n "${WORK_DIR:-}" ]]; then
  WORK="$WORK_DIR"
  mkdir -p "$WORK"
else
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/alpine-bake.XXXXXX")"
fi
QMP_SOCK="${WORK}/qmp.sock"
PIDFILE="${WORK}/qemu.pid"
HTTPPID="${WORK}/http.pid"
QLOG="${WORK}/qemu.log"

log() { printf '\033[1;36m[alpine]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[alpine][warn]\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m[alpine][err]\033[0m %s\n' "$*" >&2
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
command -v sha256sum >/dev/null 2>&1 || die "need sha256sum"
mkdir -p "$OUT_DIR" "$ISO_DIR"

#==============================================================================
# STEP 1 — resolve the latest STABLE alpine-standard release (official CDN)
#   latest-releases.yaml is the canonical machine-readable pointer: per-flavor
#   version, file name and sha256. Pin with ALPINE_BRANCH=vX.Y, or bypass the
#   resolver entirely with ISO_URL=… ISO_SHA256=….
#==============================================================================
if [[ -z "$ISO_URL" ]]; then
  REL_YAML_URL="${ALPINE_MIRROR}/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/latest-releases.yaml"
  log "resolving latest stable from ${REL_YAML_URL}"
  curl -fsSL --retry 3 --connect-timeout 20 -o "${WORK}/latest-releases.yaml" "$REL_YAML_URL" ||
    die "cannot fetch latest-releases.yaml"
  # Tiny YAML pluck: the block whose flavor: matches ALPINE_FLAVOR.
  read -r ALPINE_VERSION ISO_FILE ISO_SHA256 < <(
    python3 - "$ALPINE_FLAVOR" "${WORK}/latest-releases.yaml" <<'PY'
import sys
flavor = sys.argv[1]
blocks, cur = [], {}
for ln in open(sys.argv[2]).read().splitlines():
    if ln.startswith('-'):
        cur = {}; blocks.append(cur); continue
    if ':' in ln:
        k, v = ln.split(':', 1)
        cur[k.strip()] = v.strip().strip('"')
for b in blocks:
    if b.get('flavor') == flavor:
        print(b['version'], b['file'], b['sha256']); break
else:
    sys.exit(1)
PY
  ) || die "flavor '${ALPINE_FLAVOR}' not found in latest-releases.yaml"
  ISO_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION%.*}/releases/${ALPINE_ARCH}/${ISO_FILE}"
else
  ISO_FILE="$(basename "$ISO_URL")"
  ALPINE_VERSION="${ALPINE_VERSION:-unknown}"
fi
ISO_PATH="${ISO_DIR}/${ISO_FILE}"
CANONICAL_ISO="${ISO_DIR}/Alpine.iso"
log "release: Alpine ${ALPINE_VERSION} (${ALPINE_FLAVOR}, ${ALPINE_ARCH}) — ${ISO_FILE}"

#==============================================================================
# STEP 2 — download the ISO (sha256-verified, skip when already valid)
#==============================================================================
iso_ok() {
  [[ -s "$ISO_PATH" && -n "$ISO_SHA256" ]] || return 1
  [[ "$(sha256sum "$ISO_PATH" | awk '{print $1}')" == "$ISO_SHA256" ]]
}
if [[ "${FORCE_DOWNLOAD:-0}" != "1" ]] && iso_ok; then
  log "ISO present + sha256 OK — skipping download"
else
  log "downloading ${ISO_URL}"
  tmp="${ISO_PATH}.part"
  rm -f "$tmp"
  curl -fL --retry 3 --connect-timeout 20 -o "$tmp" "$ISO_URL"
  if [[ -n "$ISO_SHA256" ]]; then
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    [[ "$got" == "$ISO_SHA256" ]] || die "SHA256 mismatch: got=$got want=$ISO_SHA256"
    log "sha256 verified OK"
  else
    warn "no sha256 available for override URL — size-only sanity"
  fi
  mv -f "$tmp" "$ISO_PATH"
fi

# The emitted launcher uses /data/isos/Alpine.iso. Keep the versioned file for
# provenance and converge the canonical name within ISO_DIR for both normal and
# namespaced trial builds. Replace an obsolete regular-file copy only when it no
# longer matches the resolved stable ISO.
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
# STEP 4 — scratch state.qcow2 (the golden snapshot container)
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
#==============================================================================
mkdir -p "${WORK}/payload"
cat >"${WORK}/payload/alpine-payload.sh" <<PAYLOAD
#!/bin/sh
# osgallery alpine golden-bake payload — runs IN-GUEST as root on tty1.
set -e
apk add openssh                       # from the standard ISO's own /media/cdrom/apks
ssh-keygen -A
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '${PUBKEY}' > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
rc-update add sshd default 2>/dev/null || true
pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd
cat > /root/fixture-tweaks.sh <<'EOF'
#!/bin/sh
# Alpine golden test fixture tweaks (idempotent). Captured in savevm 'golden'.
echo 0 > /sys/class/graphics/fbcon/cursor_blink   # steady caret: kill the only idle animation
printf '\033[9;0]\033[14;0]' > /dev/tty1          # no console blank / no VESA powerdown
EOF
chmod +x /root/fixture-tweaks.sh
sh /root/fixture-tweaks.sh
cat > /root/banner <<'EOF'
  ============================================================
   ALPINE LINUX @VER@  --  GOLDEN TEST FIXTURE (resetMode=loadvm)
  ============================================================
   Keyboard-reactive surface: type below. Characters echo at the
   steady (non-blinking) caret; Left/Right arrows move the caret.
   Reset: QMP 'loadvm golden' restores this exact screen, live.
  ============================================================
EOF
echo PAYLOAD-OK
PAYLOAD
sed -i "s/@VER@/${ALPINE_VERSION}/" "${WORK}/payload/alpine-payload.sh"

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
#==============================================================================
launch_vm() { # $@ = extra args (e.g. -loadvm golden). Device set NEVER varies.
  rm -f "$QMP_SOCK" "$PIDFILE" "${WORK}/vnc.sock"
  qemu-system-x86_64 \
    -name "bake-${KEY_NAME}" \
    -enable-kvm -m "$MEM_MB" -smp "$SMP" \
    -cpu host \
    -rtc base=localtime \
    -cdrom "$ISO_PATH" -boot d \
    -drive file="$STATE_PATH",if=ide,format=qcow2 \
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

# Wait for the login prompt: minimum BOOT_WAIT, then frame-stability polling.
log "waiting ${BOOT_WAIT}s + frame-stable for the LiveCD login prompt"
sleep "$BOOT_WAIT"
prev=""
for _ in $(seq 1 30); do
  qdrv shot "${WORK}/poll.ppm" >/dev/null
  cur="$(md5sum "${WORK}/poll.ppm" | awk '{print $1}')"
  [[ -n "$prev" && "$cur" == "$prev" ]] && break
  prev="$cur"
  sleep 3
done

#==============================================================================
# STEP 8 — drive the bake: login, network, payload, fixture, ssh
#==============================================================================
log "logging in as root + configuring the SLIRP NIC statically"
qdrv key ret sleep 1
typeline "root"
sleep 2
typeline "ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up"
sleep 1
typeline "route add default gw 10.0.2.2"
sleep 1

log "fetching + running the in-guest payload (openssh + key + fixture tweaks)"
typeline "while ! wget -qO- http://10.0.2.2:${HTTP_PORT}/alpine-payload.sh | sh; do sleep 2; done"
sleep 8

log "adding bake-time ssh forward 127.0.0.1:${BAKE_SSH_PORT} -> 10.0.2.15:22"
qdrv hostfwd "tcp:127.0.0.1:${BAKE_SSH_PORT}-10.0.2.15:22" >/dev/null

SSH=(ssh -i "$GALLERY_KEY" -p "$BAKE_SSH_PORT" -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes
  -o LogLevel=ERROR root@127.0.0.1)
probe=""
for _ in $(seq 1 30); do
  probe="$("${SSH[@]}" 'uname -sr && cat /etc/alpine-release' 2>/dev/null)" && break
  sleep 3
done
[[ -n "$probe" ]] || {
  qdrv shot "${OUT_DIR}/bake-failed.ppm" >/dev/null
  die "ssh probe never succeeded — payload failed? (screendump: ${OUT_DIR}/bake-failed.ppm)"
}
log "ssh probe OK: $(echo "$probe" | tr '\n' ' ')"
tweak="$("${SSH[@]}" 'cat /sys/class/graphics/fbcon/cursor_blink' 2>/dev/null || echo '?')"
[[ "$tweak" == "0" ]] || warn "cursor_blink=$tweak (expected 0)"

log "painting the clean fixture screen (banner + fresh prompt)"
typeline "clear; cat /root/banner"
sleep 2

#==============================================================================
# STEP 9 — determinism check + savevm golden, then kill the bake VM
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
# STEP 10 — COLD-START VERIFICATION (exact production semantics)
#   Fresh QEMU process, `-loadvm golden` at launch, hostfwd re-added via QMP —
#   precisely what the production station launcher does on every start. All final
#   proofs run here (a fresh process also sidesteps stale display-surface
#   artifacts a long-lived clientless bake VM can accumulate: the guest never
#   re-dirties untouched regions, so only a fresh surface shows vmstate truth).
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
# STEP 11 — shut the verify VM down; the artifact is the disk, not the process
#==============================================================================
teardown
trap - EXIT

cat >"${OUT_DIR}/BUILD-INFO.txt" <<EOF
alpine tile artifact — built $(date -u +%Y-%m-%dT%H:%M:%SZ) by scripts/build-guests/tiles/alpine.sh
  guest      : Alpine Linux ${ALPINE_VERSION} ${ALPINE_FLAVOR} ${ALPINE_ARCH} LiveCD (RAM-only)
  iso        : ${ISO_PATH}
  iso sha256 : ${ISO_SHA256}
  state disk : ${STATE_PATH} (holds the internal 'golden' savevm snapshot — NEVER delete)
  ssh        : root@guest via gallery key ${GALLERY_KEY}.pub baked in authorized_keys;
               guest eth0 static 10.0.2.15/24 on the DEFAULT SLIRP NIC; forward is
               host-side (QMP hostfwd_add), production port 5881
  fixture    : root tty1 console, ASCII banner, steady caret, blank/DPMS off
  verified   : cold-start -loadvm golden (fresh QEMU) -> idle-deterministic,
               ssh, dirty->loadvm byte-identical, ssh again after loadvm
EOF

cat <<EOF

[alpine] BUILD COMPLETE
  ISO (boot medium)     : ${ISO_PATH}
  Golden state disk     : ${STATE_PATH}
  Fixture proof         : ${OUT_DIR}/fixture-golden.png
  Build manifest        : ${OUT_DIR}/BUILD-INFO.txt

  ---- PRODUCTION WIRING (streamhost tile 'alpine', VMID 81, udp/54081) -------
  # tiles-manifest.sh emit stanza (only the --cdrom path changes vs today):
  #   --cdrom ${ISO_PATH} --boot d
  # The station launcher (hand-baked golden launcher) must:
  #   * copy/point at ${STATE_PATH} as its state.qcow2 (create-if-missing ONLY)
  #   * keep the EXACT device set in this script's STEP 7 (swap -display none
  #     for -display dbus,p2p=on,audiodev=snd0 and -audiodev none for
  #     -audiodev dbus,… — backends are not part of vmstate)
  #   * boot with -loadvm golden when the snapshot exists
  #   * after boot: QMP  hostfwd_add tcp:127.0.0.1:5881-10.0.2.15:22
  # ssh exec channel:  ssh -i ${GALLERY_KEY} -p 5881 root@127.0.0.1
  -----------------------------------------------------------------------------
EOF
