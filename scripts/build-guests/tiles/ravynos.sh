#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/ravynos.sh — build the ravynOS 0.6.1 (amd64) exhibit.
#
# WHAT THIS BUILD IS: a LIVE-ISO exhibit, not an installed one. The station boots
# upstream's own ISO under UEFI and carries a small empty qcow2 whose ONLY job is
# to hold the `golden` vmstate (a live ISO is read-only and cannot hold one).
#
# WHY LIVE, NOT INSTALLED (evidence, on-box 2026-09-01):
#   * The disk installer (/bin/install.sh, bash, four prompts) COMPLETES: GPT +
#     256 MB EFI + 4 GB swap + ZFS pool `ravynOS`, 1,382,801,565 bytes / 40,988
#     items copied in ~182 s, zfs_enable/zfsd_enable/sshd_enable=YES, bootloader
#     written.
#   * The installed system NEVER reaches a desktop. It boots
#     `zfs:ravynOS/ROOT/default [rw]`, prints `pid 1 comm launchd: nosys 689`, and
#     stalls there forever — two captures 150 s apart were byte-identical, and `rc`
#     produces no output. virtio-rng-pci did NOT help (the entropy hypothesis is
#     refuted). /etc/rc.conf differs from the live one only by those three service
#     lines, but the installed /System/Library/LaunchDaemons tree does not match
#     the live one (the live tree carries com.ravynos.ws.seatd.json and
#     org.freebsd.ttyv0.json). This is pre-alpha breakage in ravynOS's own
#     disk-install path, not a lab misconfiguration.
#   * So the exhibit ships the live ISO — also the exact artifact upstream deleted,
#     and upstream's own distribution form.
#
# PROOF STATUS: every step below was performed first-hand on labhost 2026-09-01 in
# an isolated sandbox: ISO fetch + SHA-256; UEFI/q35 cold boot to the LoginWindow;
# the activate-then-click-then-click-again focus sequence; `liveuser` (no password)
# login to the desktop; `savevm golden` landing 579 MiB on the CARRIER disk and 0 B
# on OVMF_VARS.qcow2; dirty (Terminal from the Dock) != baseline; loadvm restored
# baseline BYTE-EXACTLY.
#
# REPRODUCIBILITY RISK (recorded on purpose): the GitHub release and the
# SourceForge mirror are BOTH 404 — the project deleted every FreeBSD-era release.
# The ISO now exists only on volunteer mirrors (see RAVYNOS_ISO_URLS). Keep the
# staged copy under $STAGE_DIR; treat its loss as a real risk to this station.
#
# Inputs:
#   /data/assets-staging/ravynos/ravynOS_0.6.1_amd64.iso  (762972160 bytes,
#     sha256 e7a2b90e8d87c073857bce6f65ec5023542ec76d4f694b55f49af981c4ff9516)
#   /usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd, OVMF_VARS_4M.fd
# Outputs (consumed by the station launcher):
#   /data/gallery-guests/RavynOS/ravynos-golden.qcow2  (carrier; holds `golden`)
#   /data/gallery-guests/RavynOS/OVMF_VARS.qcow2       (writable UEFI varstore)
#
# PINNED DEVICE SET — the production launcher MUST enumerate the same
# guest-visible devices, in this order, or `loadvm golden` is invalid:
#   * -machine pc-q35-11.0 — REQUIRED. i440fx + OVMF paints a black screen with a
#     white rectangle (upstream issue #433).
#   * UEFI REQUIRED — ravynOS has no BIOS/legacy boot at all. The varstore MUST be
#     qcow2 and writable: `savevm` refuses a writable device that cannot hold
#     snapshots, and a read-only pflash hangs OVMF before it initialises display.
#   * The CARRIER DISK IS DECLARED FIRST, before the pflash pair. `savevm` picks
#     its vmstate device by walking BlockBackends in command-line order; with the
#     pflash first, the RAM image would land in the 528 KiB variable store. This
#     builder asserts the placement rather than trusting it.
#   * -vga std at 1280x800 — there is no GPU driver of any kind; WindowServer
#     paints straight into the framebuffer OVMF's EFI GOP hands it, and the guest
#     cannot change the mode.
#   * USB-only input (qemu-xhci + usb-kbd + usb-tablet) — upstream's 0.6.1 notes
#     say PS/2 and virtio input lag. Verified: hkbd0 <QEMU USB Keyboard>,
#     hms0 <QEMU USB Tablet ... 5 buttons and [XYW] coordinates>.
#   * intel-hda + hda-duplex — verified: /dev/sndstat pcm0 <Generic (0x1af40022)
#     (Analog)> (play/rec) default. Here the BACKEND is headless (-audiodev none);
#     production uses the dbus audiodev. Backends are host-side, not guest devices.
#   * virtio-rng-pci (upstream's own VM script ships one) and a SLIRP NIC with
#     restrict=on, so an exhibit nobody supervises cannot phone home.
#
# INPUT TRAPS (both cost real time; do not "simplify" them away):
#   * Absolute pointer injection MUST use QMP input-send-event with abs axes
#     scaled to 0..32767. labqmp.mouse_relative_from_origin drifts — it landed a
#     click 300 px off target — so this builder has its own inline abs helper.
#   * labqmp's `button` action takes a BITMASK (`button 1`, then `button 0`).
#     `button left` silently does nothing.
#   * The LoginWindow must be ACTIVATED before a field click takes focus: click
#     the panel body, then the Username field, then the Username field AGAIN.
#     Clicking straight into the field swallows the typing and yields "Try Again".
#
# Safety: everything transient lives in one namespaced /data/vms/sandbox dir; QEMU
# is stopped ONLY through this build's own pidfile (never pkill); no live station
# process, socket or disk is touched; an existing output is refused unless FORCE=1
# (then it is backed up first).
#
# Usage:
#   scripts/build-guests/tiles/ravynos.sh
#
# Useful overrides:
#   RAVYNOS_ISO=... RAVYNOS_STAGE_DIR=... RAVYNOS_GUEST_DIR=... RAVYNOS_WORK_DIR=...
#   OVMF_CODE=... OVMF_VARS_TEMPLATE=... RAVYNOS_MEMORY=... RAVYNOS_CORES=...
#   RAVYNOS_LOGIN_WAIT=... RAVYNOS_DESKTOP_WAIT=... FORCE=1 KEEP_WORK=1
# =============================================================================
set -euo pipefail

OS_ID="ravynos"
HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="${LABQMP:-$HERE/../../lib/labqmp.py}"

STAGE_DIR="${RAVYNOS_STAGE_DIR:-/data/assets-staging/ravynos}"
ISO="${RAVYNOS_ISO:-$STAGE_DIR/ravynOS_0.6.1_amd64.iso}"
ISO_SHA256="${RAVYNOS_ISO_SHA256:-e7a2b90e8d87c073857bce6f65ec5023542ec76d4f694b55f49af981c4ff9516}"
ISO_BYTES="${RAVYNOS_ISO_BYTES:-762972160}"
# Canonical first; the other two are volunteer mirrors that also answer 200.
ISO_URLS=(
  "http://ftp.nvg.ntnu.no/pub/mirrors2/mirrors.nomadlogic.org/www/releases/0.6.1/ravynOS_0.6.1_amd64.iso"
  "https://mirrors.nomadlogic.org/ravynOS/releases/0.6.1/ravynOS_0.6.1_amd64.iso"
  "https://mirror.clarkson.edu/ravynos/releases/0.6.1/ravynOS_0.6.1_amd64.iso"
)

GUEST_DIR="${RAVYNOS_GUEST_DIR:-/data/gallery-guests/RavynOS}"
OUT_CARRIER="$GUEST_DIR/ravynos-golden.qcow2"
OUT_VARS="$GUEST_DIR/OVMF_VARS.qcow2"

QEMU="${RAVYNOS_QEMU:-qemu-system-x86_64}"
MACHINE="${RAVYNOS_MACHINE:-pc-q35-11.0}"
MEMORY="${RAVYNOS_MEMORY:-4096}"
CORES="${RAVYNOS_CORES:-4}"
CARRIER_SIZE="${RAVYNOS_CARRIER_SIZE:-24G}"
OVMF_CODE="${OVMF_CODE:-/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-/usr/share/pve-edk2-firmware/OVMF_VARS_4M.fd}"

# Framebuffer geometry OVMF hands the guest; every coordinate below is in it.
FB_W=1280
FB_H=800
LOGIN_WAIT="${RAVYNOS_LOGIN_WAIT:-240}"    # cap; the window appears ~95-110 s in
LOGIN_MIN="${RAVYNOS_LOGIN_MIN:-90}"       # never declare "logged in" before this
DESKTOP_WAIT="${RAVYNOS_DESKTOP_WAIT:-45}" # desktop appears ~20-25 s after Log In
LIVE_USER="${RAVYNOS_LIVE_USER:-liveuser}" # upstream documents: no password

FORCE="${FORCE:-0}"
KEEP_WORK="${KEEP_WORK:-0}"
STAMP="$(date +%s)"
WORK="${RAVYNOS_WORK_DIR:-/data/vms/sandbox/build-${OS_ID}-${STAMP}}"
CARRIER="$WORK/ravynos-golden.qcow2"
VARS="$WORK/OVMF_VARS.qcow2"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
QEMU_LOG="$WORK/qemu.log"
SERIAL_LOG="$WORK/serial.log"

log() { printf '[build:%s %(%H:%M:%S)T] %s\n' "$OS_ID" -1 "$*" >&2; }
die() {
  printf '[build:%s ERROR] %s\n' "$OS_ID" "$*" >&2
  exit 1
}
qmp() { python3 "$LABQMP" "$QMP" "$@"; }
shot() { qmp shot "$WORK/$1.ppm" >/dev/null; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }

# --- absolute pointer -------------------------------------------------------
# QMP input-send-event with abs axes scaled to 0..32767. This exists because
# labqmp.mouse_relative_from_origin drifts (see INPUT TRAPS above).
click() {
  python3 - "$QMP" "$1" "$2" "$FB_W" "$FB_H" <<'PY'
import json, socket, sys, time

sock, x, y, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
ax, ay = x * 32767 // (w - 1), y * 32767 // (h - 1)
s = socket.socket(socket.AF_UNIX)
s.settimeout(20)
s.connect(sock)
f = s.makefile('rwb', buffering=0)
f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    o = json.loads(f.readline())
    if 'return' in o or 'error' in o:
        break


def send(events):
    f.write(json.dumps({'execute': 'input-send-event', 'arguments': {'events': events}}).encode() + b'\n')
    while True:
        o = json.loads(f.readline())
        if 'return' in o:
            return
        if 'error' in o:
            raise SystemExit('QMP error: ' + json.dumps(o['error']))


send([{'type': 'abs', 'data': {'axis': 'x', 'value': ax}},
      {'type': 'abs', 'data': {'axis': 'y', 'value': ay}}])
time.sleep(0.25)
send([{'type': 'btn', 'data': {'down': True, 'button': 'left'}}])
time.sleep(0.12)
send([{'type': 'btn', 'data': {'down': False, 'button': 'left'}}])
s.close()
PY
  sleep 0.7
}

# --- process control (this build's pidfile ONLY; never pkill) ---------------
stop_qemu() {
  local pid=""
  if [ -s "$PIDFILE" ]; then pid="$(cat "$PIDFILE" 2>/dev/null || true)"; fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$QMP" "$PIDFILE"
}

cleanup() {
  stop_qemu
  if [ "$KEEP_WORK" = 1 ]; then log "KEEP_WORK=1: kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT INT TERM

# --- preflight --------------------------------------------------------------
for b in "$QEMU" qemu-img python3 sha256sum curl awk; do
  command -v "$b" >/dev/null 2>&1 || die "missing host tool: $b"
done
[ -s "$LABQMP" ] || die "labqmp helper missing: $LABQMP"
[ -s "$OVMF_CODE" ] || die "missing OVMF code: $OVMF_CODE"
[ -s "$OVMF_VARS_TEMPLATE" ] || die "missing OVMF vars template: $OVMF_VARS_TEMPLATE"
[ ! -e "$WORK" ] || die "work dir already exists: $WORK"
mkdir -p "$WORK"
log "work=$WORK"

# --- stage 0: media ---------------------------------------------------------
# Size alone is never accepted: the SHA-256 decides, always.
verify_iso() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(stat -c %s "$f")" = "$ISO_BYTES" ] || return 1
  [ "$(sha_of "$f")" = "$ISO_SHA256" ] || return 1
}

if verify_iso "$ISO"; then
  log "stage 0: staged ISO verified: $ISO"
else
  [ ! -e "$ISO" ] || die "staged ISO present but FAILS sha256/size: $ISO"
  mkdir -p "$(dirname "$ISO")"
  tmp="$ISO.part-$STAMP"
  ok=0
  for url in "${ISO_URLS[@]}"; do
    log "stage 0: fetching $url"
    if curl -fL --retry 2 --connect-timeout 20 -o "$tmp" "$url"; then
      if verify_iso "$tmp"; then
        ok=1
        break
      fi
      log "stage 0: checksum mismatch from this mirror; trying the next"
    fi
    rm -f "$tmp"
  done
  [ "$ok" = 1 ] || die "no mirror produced ravynOS_0.6.1_amd64.iso with sha256 $ISO_SHA256"
  mv "$tmp" "$ISO"
  log "stage 0: fetched and verified -> $ISO"
fi

# --- stage 1: carrier disk + writable UEFI varstore -------------------------
# The carrier exists ONLY to hold the vmstate of a read-only live ISO.
log "stage 1: create $CARRIER_SIZE vmstate carrier and qcow2 UEFI varstore"
qemu-img create -q -f qcow2 "$CARRIER" "$CARRIER_SIZE"
qemu-img convert -f raw -O qcow2 "$OVMF_VARS_TEMPLATE" "$VARS"

# --- stage 2: launch with the pinned device set -----------------------------
start_qemu() {
  rm -f "$QMP" "$PIDFILE"
  log "stage 2: cold boot the live ISO (q35 + UEFI, headless)"
  nice -n15 "$QEMU" \
    -name "build-${OS_ID}-${STAMP}" \
    -enable-kvm -machine "$MACHINE" -cpu host \
    -m "$MEMORY" -smp "cores=${CORES},sockets=1" \
    -drive "file=$CARRIER,if=none,id=hd0,format=qcow2,cache=writeback" \
    -device "ide-hd,drive=hd0,bus=ide.0,bootindex=2" \
    -drive "if=pflash,unit=0,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,unit=1,format=qcow2,file=$VARS" \
    -drive "file=$ISO,media=cdrom,if=none,id=cd0,readonly=on" \
    -device "ide-cd,drive=cd0,bus=ide.1,bootindex=1" \
    -boot menu=off,strict=on \
    -vga std \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
    -audiodev none,id=snd0 \
    -device intel-hda,id=hda -device hda-duplex,bus=hda.0,audiodev=snd0 \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0 \
    -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0,id=net0 \
    -display none -serial "file:$SERIAL_LOG" \
    -qmp "unix:$QMP,server=on,wait=off" -pidfile "$PIDFILE" \
    >"$QEMU_LOG" 2>&1 &
  for _ in $(seq 1 80); do
    [ -S "$QMP" ] && [ -s "$PIDFILE" ] && return 0
    sleep 0.5
  done
  tail -n 40 "$QEMU_LOG" >&2 || true
  die "QEMU did not create its QMP socket/pidfile"
}
start_qemu

# --- stage 3: wait for the LoginWindow --------------------------------------
# Poll the framebuffer instead of trusting a fixed sleep: the window appears
# ~95-110 s in, and it is settled once two samples 5 s apart are identical.
log "stage 3: poll for the LoginWindow (min ${LOGIN_MIN}s, cap ${LOGIN_WAIT}s)"
sleep "$LOGIN_MIN"
prev=""
settled=0
waited="$LOGIN_MIN"
while [ "$waited" -lt "$LOGIN_WAIT" ]; do
  shot poll
  cur="$(sha_of "$WORK/poll.ppm")"
  if [ -n "$prev" ] && [ "$cur" = "$prev" ]; then
    settled=1
    break
  fi
  prev="$cur"
  sleep 5
  waited=$((waited + 5))
done
[ "$settled" = 1 ] || die "LoginWindow never settled within ${LOGIN_WAIT}s (see $SERIAL_LOG, $WORK/poll.ppm)"
shot loginwindow
log "stage 3: LoginWindow settled after ~${waited}s"

# --- stage 4: log in --------------------------------------------------------
# ACTIVATE FIRST. Clicking straight into the Username field loses the typing.
log "stage 4: activate the LoginWindow, focus Username, log in as $LIVE_USER"
click 640 160 # panel body: activates the window
click 640 267 # Username field
click 640 267 # ... and again: the first click only moves focus into the panel
qmp type "$LIVE_USER"
sleep 1
shot username-typed
click 640 396 # Log In (there is no password)
log "stage 4: wait ${DESKTOP_WAIT}s for the desktop"
sleep "$DESKTOP_WAIT"
shot desktop

# --- stage 5: bake and prove `golden` ---------------------------------------
# Sampling at a FIXED machine instant (stop -> loadvm -> stop -> screendump ->
# cont) is what makes the comparison exact despite the blinking terminal cursor
# and the menu-bar clock.
log "stage 5: stop at the ready scene and savevm golden"
qmp stop >/dev/null
shot baseline
qmp savevm golden >/dev/null
snaps="$(qmp querysnap)"
grep -qw golden <<<"$snaps" || die "savevm did not create the golden tag: $snaps"

# The vmstate MUST be on the carrier, not in the 528 KiB variable store.
snap_vmsize() { qemu-img snapshot -l -U "$1" | awk -v t=golden '$2 == t {print $3 " " $4}'; }
carrier_size="$(snap_vmsize "$CARRIER")"
vars_size="$(snap_vmsize "$VARS")"
[ -n "$carrier_size" ] || die "golden tag missing from the carrier disk"
case "$carrier_size" in
  0\ *) die "vmstate landed with 0 bytes on the carrier — check device declaration order" ;;
esac
case "$vars_size" in
  "" | 0\ *) : ;;
  *) die "vmstate landed in OVMF_VARS.qcow2 ($vars_size) — the carrier must be declared FIRST" ;;
esac
log "stage 5: vmstate on carrier=$carrier_size, varstore=${vars_size:-none} (correct)"

qmp cont >/dev/null
sleep 2
click 599 757 # Dock: Terminal — dirties the framebuffer
sleep 6
shot dirty
qmp stop loadvm golden stop >/dev/null
shot restored
qmp cont >/dev/null

base_h="$(sha_of "$WORK/baseline.ppm")"
dirty_h="$(sha_of "$WORK/dirty.ppm")"
rest_h="$(sha_of "$WORK/restored.ppm")"
[ "$base_h" != "$dirty_h" ] || die "dirty frame did not change — the click never reached the guest"
[ "$base_h" = "$rest_h" ] || die "loadvm golden did not restore the ready scene byte-exactly"
log "stage 5: PROVEN — dirty differed; loadvm restored baseline byte-exactly"

stop_qemu
qemu-img snapshot -l "$CARRIER" | grep -qw golden || die "golden missing from the stopped carrier"

# --- stage 6: atomic publish ------------------------------------------------
mkdir -p "$GUEST_DIR"
for out in "$OUT_CARRIER" "$OUT_VARS"; do
  [ -e "$out" ] || continue
  [ "$FORCE" = 1 ] || die "output exists: $out (set FORCE=1 to replace it safely)"
  backup="$out.bak-$(date +%Y%m%d-%H%M%S)"
  log "stage 6: backup existing output -> $backup"
  mv "$out" "$backup"
done
for pair in "$CARRIER:$OUT_CARRIER" "$VARS:$OUT_VARS"; do
  src="${pair%%:*}"
  dst="${pair#*:}"
  part="$dst.part-$STAMP"
  mv "$src" "$part"
  mv "$part" "$dst"
done

log "PROVEN outputs: $OUT_CARRIER + $OUT_VARS"
qemu-img info "$OUT_CARRIER" | sed -n '1,6p'
qemu-img snapshot -l "$OUT_CARRIER"
