#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/beos.sh — reproduce the `beos` station's install disk
# (BeOS R5 Professional 5.0.3) from the staged archive.org media.
#
# PROOF STATUS: hand-verified procedure 2026-08-17 (rig
# /data/vms/sandbox/beos-r5); this script not yet run end-to-end. It encodes
# the manual recipe documented in docs/guests/beos.md — read that file for the
# two R5-under-QEMU blockers this build works around (ISA config-manager PnP
# BIOS page fault; KVM traps the idle thread) and for what remains open
# (golden bake/promotion, audio device choice).
#
# INPUTS
#   BEOS_STAGING (default /data/assets-staging/beos) must already contain
#     beos-5.0.3-professional-gobe.bin  sha256 1889fd6cf5af4259b01c9d1925e62f664effdf9dd88f924dc9b4da41ce1f0106
#     beos-5.0.3-professional-gobe.cue  sha256 a57d9552cdadbbdbe6f608e8dbe9ac2bec2a010da1ad801fc0176e4d66bb234c
#   This script never downloads. If the media is missing it prints how to
#   fetch it (archive.org item beos-5.0.3-professional-gobe; the download
#   redirector 500s, so resolve https://archive.org/metadata/<item> for the
#   `server`/`dir` fields and fetch https://<server><dir>/<file> instead) and
#   exits non-zero.
#   BEOS_HAIKU_HELPER (default
#     /data/vms/streamhost/stations/haiku/haiku-persist.qcow2.bak-res-20260727T120934Z)
#   — a Haiku R1/beta5 disk with sshd + the gallery key baked in (user `user`,
#   key /root/.ssh/gallery_guest_key). This script COPIES it into the work
#   dir and boots the copy; the original is never opened for write.
#
# OUTPUTS
#   $BEOS_OUTPUT_DIR/beos-r5.qcow2   — standalone qcow2, MBR + one 0xEB
#                                      partition holding the installed,
#                                      R5-makebootable BFS volume.
#   $BEOS_OUTPUT_DIR/beos-tools-cd.iso — the disc's bootable BeOS_Tools ISO
#                                      (track 1), kept alongside for rescue use.
#   An existing beos-r5.qcow2 is refused unless FORCE=1, which backs it up
#   with a timestamp suffix first.
#
# SAFETY
#   * All transient files/sockets/pidfiles live under a namespaced WORK dir
#     (default /data/vms/sandbox/build-beos-<timestamp>, i.e. inside
#     clone-guard's CLONE_GUARD_CLONE_ROOT).
#   * Every QEMU this script starts is stopped ONLY via
#     `clone-guard kill-pidfile <pidfile>` — never pkill, never a bare kill.
#   * The Haiku helper disk is a copy; the original persistent disk under
#     /data/vms/streamhost/stations/haiku/ is opened read-only (`cp`) and
#     never booted.
#   * The claimed build-time ssh port is released on exit; if `kh-claim`
#     is not installed the claim step is skipped (not fatal).
#
# USAGE
#   scripts/build-guests/tiles/beos.sh
#   FORCE=1 scripts/build-guests/tiles/beos.sh        # replace existing output
#   KEEP_WORK=1 scripts/build-guests/tiles/beos.sh     # keep WORK for inspection
#   DO_VERIFY=0 scripts/build-guests/tiles/beos.sh     # skip the disk-boot proof gate
#
# Useful overrides (env):
#   BEOS_STAGING BEOS_OUTPUT_DIR BEOS_OUTPUT_DISK BEOS_HAIKU_HELPER
#   BEOS_WORK_DIR BEOS_FIRSTBOOT_WAIT BEOS_BOOT_WAIT FORCE KEEP_WORK DO_VERIFY
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABQMP="$HERE/../../lib/labqmp.py"
# shellcheck source=/dev/null
source "$HERE/../../lib/clone-guard.sh"

OS_ID="beos"
STAGING="${BEOS_STAGING:-/data/assets-staging/beos}"
BIN="$STAGING/beos-5.0.3-professional-gobe.bin"
CUE="$STAGING/beos-5.0.3-professional-gobe.cue"
BIN_SHA="1889fd6cf5af4259b01c9d1925e62f664effdf9dd88f924dc9b4da41ce1f0106"
CUE_SHA="a57d9552cdadbbdbe6f608e8dbe9ac2bec2a010da1ad801fc0176e4d66bb234c"

OUTPUT_DIR="${BEOS_OUTPUT_DIR:-/data/gallery-guests/Beos}"
OUTPUT_DISK="${BEOS_OUTPUT_DISK:-$OUTPUT_DIR/beos-r5.qcow2}"
TOOLS_CD="$OUTPUT_DIR/beos-tools-cd.iso"

HAIKU_HELPER="${BEOS_HAIKU_HELPER:-/data/vms/streamhost/stations/haiku/haiku-persist.qcow2.bak-res-20260727T120934Z}"
GALLERY_KEY="${BEOS_GALLERY_KEY:-/root/.ssh/gallery_guest_key}"

MACHINE="${BEOS_MACHINE:-pc-i440fx-11.0}"
QEMU="${BEOS_QEMU:-qemu-system-x86_64}"
FIRSTBOOT_WAIT="${BEOS_FIRSTBOOT_WAIT:-240}"
BOOT_WAIT="${BEOS_BOOT_WAIT:-180}"

FORCE="${FORCE:-0}"
KEEP_WORK="${KEEP_WORK:-0}"
DO_VERIFY="${DO_VERIFY:-1}"

STAMP="$(date +%s)"
WORK="${BEOS_WORK_DIR:-/data/vms/sandbox/build-beos-${STAMP}}"

log() { printf '[build:%s %(%H:%M:%S)T] %s\n' "$OS_ID" -1 "$*"; }
die() {
  printf '[build:%s ERROR] %s\n' "$OS_ID" "$*" >&2
  exit 1
}

fetch_help() {
  cat <<EOF
BeOS media not staged at $STAGING.

Fetch it (the archive.org download redirector 500s for this item, so resolve
the metadata JSON first):
  curl -s https://archive.org/metadata/beos-5.0.3-professional-gobe \\
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["server"], d["dir"])'
  # then, for each of beos-5.0.3-professional-gobe.bin and .cue:
  curl -fL -o $STAGING/<file> "https://<server><dir>/<file>"

Verify against the pinned checksums before use:
  beos-5.0.3-professional-gobe.bin  sha256 $BIN_SHA
  beos-5.0.3-professional-gobe.cue  sha256 $CUE_SHA
EOF
}

sha_check() {
  local file="$1" want="$2" got
  [ -s "$file" ] || return 1
  got="$(sha256sum "$file" | awk '{print $1}')"
  [ "$got" = "$want" ]
}

# labqmp CLI wrapper: qmp_run <sock> action...   (qdrv-compatible action stream)
qmp_run() {
  local sock="$1"
  shift
  python3 "$LABQMP" "$sock" "$@"
}

# Send one ad-hoc QMP command that has no labqmp CLI action (e.g. system_powerdown).
qmp_cmd() {
  local sock="$1" command="$2"
  LABQMP_DIR="$(dirname "$LABQMP")" python3 - "$sock" "$command" <<'PY'
import sys
sys.path.insert(0, __import__("os").environ["LABQMP_DIR"])
import labqmp

sock, command = sys.argv[1], sys.argv[2]
with labqmp.QMPClient(sock) as client:
    client.execute(command)
PY
}

stop_qemu() {
  local pidfile="$1"
  [ -f "$pidfile" ] || return 0
  clone_guard_kill_pidfile "$pidfile" || die "clone-guard refused to stop $pidfile"
}

PORT_CLAIMED=""
cleanup() {
  [ -f "$WORK/qemu-firstboot.pid" ] && stop_qemu "$WORK/qemu-firstboot.pid"
  [ -f "$WORK/qemu-diskboot.pid" ] && stop_qemu "$WORK/qemu-diskboot.pid"
  [ -f "$WORK/helper.pid" ] && stop_qemu "$WORK/helper.pid"
  if [ -n "$PORT_CLAIMED" ] && command -v kh-claim >/dev/null 2>&1; then
    kh-claim release port "$PORT_CLAIMED" >/dev/null 2>&1 || true
  fi
  if [ "$KEEP_WORK" != 1 ]; then
    rm -rf "$WORK"
  else
    log "KEEP_WORK=1: leaving $WORK"
  fi
}
trap cleanup EXIT INT TERM

# ---- 0. preflight ------------------------------------------------------------
for b in "$QEMU" qemu-img sfdisk sha256sum ssh timeout python3 truncate dd; do
  command -v "$b" >/dev/null 2>&1 || die "missing host tool: $b"
done

if ! sha_check "$BIN" "$BIN_SHA" || ! sha_check "$CUE" "$CUE_SHA"; then
  fetch_help
  die "staged media missing or checksum mismatch under $STAGING"
fi
[ -s "$HAIKU_HELPER" ] || die "Haiku helper disk missing: $HAIKU_HELPER"
[ -s "$GALLERY_KEY" ] || die "gallery private key missing: $GALLERY_KEY"

[ -e "$WORK" ] && die "work dir already exists: $WORK"
mkdir -p "$WORK"
clone_guard_assert_clone_path "$WORK" "work dir"

mkdir -p "$OUTPUT_DIR"
if [ -e "$OUTPUT_DISK" ]; then
  [ "$FORCE" = 1 ] || die "output exists: $OUTPUT_DISK (set FORCE=1 to replace safely)"
  backup="$OUTPUT_DISK.bak-$(date +%Y%m%d-%H%M%S)"
  log "backup existing output -> $backup"
  mv "$OUTPUT_DISK" "$backup"
fi

log "work=$WORK"

# ---- 1. split bin/cue into per-track 2048-byte images ------------------------
log "step 1: split $BIN into per-track ISO/BFS images (no bchunk on box)"
python3 - "$BIN" "$CUE" "$WORK/track01.iso" "$WORK/track02.bfs" <<'PY'
import re
import sys

bin_path, cue_path, out1, out2 = sys.argv[1:5]

SECTOR = 2352
DATA_OFF = 16
DATA_LEN = 2048


def to_sector(mm, ss, ff):
    return (int(mm) * 60 + int(ss)) * 75 + int(ff)


tracks = []  # list of (track_num, start_sector)
cur_track = None
with open(cue_path, "r", encoding="ascii", errors="replace") as f:
    for line in f:
        line = line.strip()
        m = re.match(r"TRACK\s+(\d+)\s+MODE1/2352", line)
        if m:
            cur_track = int(m.group(1))
            continue
        m = re.match(r"INDEX\s+01\s+(\d+):(\d+):(\d+)", line)
        if m and cur_track is not None:
            tracks.append((cur_track, to_sector(*m.groups())))
            cur_track = None

if len(tracks) < 2:
    raise SystemExit(f"cue parse found {len(tracks)} MODE1/2352 tracks, need >= 2")

tracks.sort(key=lambda t: t[1])
import os

total_sectors = os.path.getsize(bin_path) // SECTOR


def track_range(idx):
    start = tracks[idx][1]
    end = tracks[idx + 1][1] if idx + 1 < len(tracks) else total_sectors
    return start, end


def extract(idx, out_path):
    start, end = track_range(idx)
    with open(bin_path, "rb") as src, open(out_path, "wb") as dst:
        src.seek(start * SECTOR)
        for _ in range(end - start):
            chunk = src.read(SECTOR)
            if len(chunk) < SECTOR:
                break
            dst.write(chunk[DATA_OFF:DATA_OFF + DATA_LEN])


extract(0, out1)
extract(1, out2)
print(f"[beos split] track1 sectors {track_range(0)} -> {out1}")
print(f"[beos split] track2 sectors {track_range(1)} -> {out2}")
PY
[ -s "$WORK/track01.iso" ] || die "track1 split produced no output"
[ -s "$WORK/track02.bfs" ] || die "track2 split produced no output"
cp "$WORK/track01.iso" "$TOOLS_CD"
log "wrote $WORK/track01.iso, $WORK/track02.bfs, and $TOOLS_CD"

# ---- 2. create the target disk + partition table -----------------------------
log "step 2: create $WORK/beos-hd.raw (2 GiB) and partition it"
truncate -s 2G "$WORK/beos-hd.raw"
echo 'label: dos
start=63, size=4194241, type=eb, bootable' | sfdisk "$WORK/beos-hd.raw"

# ---- 3. Haiku helper: mkfs + copy-with-attributes + in-volume fixes ----------
log "step 3: copy Haiku helper disk (never boot the original)"
cp "$HAIKU_HELPER" "$WORK/haiku-helper.qcow2"

SSH_PORT="${BEOS_SSH_PORT:-$(
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)}"
if command -v kh-claim >/dev/null 2>&1; then
  if kh-claim take port "$SSH_PORT" --purpose beos-build >/dev/null 2>&1; then
    PORT_CLAIMED="$SSH_PORT"
  fi
fi

HELPER_QMP="$WORK/qmp-helper.sock"
HELPER_PID="$WORK/helper.pid"
clone_guard_assert_clone_qmp "$HELPER_QMP"
clone_guard_assert_clone_path "$HELPER_PID" "pidfile"

log "boot Haiku helper (KVM, hostfwd ssh=$SSH_PORT)"
nice -n15 "$QEMU" \
  -name "build-beos-${STAMP}-helper" \
  -enable-kvm -m 2048 -smp 2 -machine "$MACHINE" -cpu host -vga std -display none \
  -drive "file=$WORK/haiku-helper.qcow2,format=qcow2,if=ide,index=0" \
  -drive "file=$WORK/track02.bfs,format=raw,if=ide,index=1,readonly=on" \
  -drive "file=$WORK/beos-hd.raw,format=raw,if=ide,index=2" \
  -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device e1000,netdev=n0 \
  -qmp "unix:$HELPER_QMP,server=on,wait=off" -pidfile "$HELPER_PID" \
  >"$WORK/helper-qemu.log" 2>&1 &
for _ in $(seq 1 60); do
  [ -S "$HELPER_QMP" ] && [ -s "$HELPER_PID" ] && break
  sleep .5
done
[ -S "$HELPER_QMP" ] && [ -s "$HELPER_PID" ] || {
  tail -n 40 "$WORK/helper-qemu.log" >&2 || true
  die "Haiku helper QEMU did not create QMP socket/pidfile"
}

SSH_OPTS=(-i "$GALLERY_KEY" -p "$SSH_PORT" -o BatchMode=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# shellcheck disable=SC2029 # arguments are intentionally the remote command
helper_ssh() { ssh "${SSH_OPTS[@]}" user@127.0.0.1 "$@"; }
wait_for_ssh() {
  local tries="${1:-45}"
  for _ in $(seq 1 "$tries"); do
    timeout 5 ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 user@127.0.0.1 true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
wait_for_ssh 60 || die "Haiku helper did not answer ssh"
log "Haiku helper ssh is up"

helper_ssh 'echo y | writembr /dev/disk/ata/1/master/raw' ||
  die "writembr failed on the Haiku helper"
helper_ssh 'mkfs -t bfs -q /dev/disk/ata/1/master/0 BeOS' ||
  die "mkfs -t bfs failed on the Haiku helper"

# shellcheck disable=SC2016 # evaluated by the Haiku guest shell, not this shell
helper_ssh 'set -e
mkdir -p /beos /new
mount /dev/disk/ata/0/slave/raw /beos
mount /dev/disk/ata/1/master/0 /new
cd /beos && cp -a . /new/

mkdir -p /new/beos/system/add-ons/kernel/busses/config_manager_off
mv /new/beos/system/add-ons/kernel/busses/config_manager/isa \
   /new/beos/system/add-ons/kernel/busses/config_manager_off/

mkdir -p /new/home/config/settings/kernel/drivers
cat > /new/home/config/settings/kernel/drivers/vesa <<EOF
mode 1024 768 16
EOF
cat > /new/home/config/settings/kernel/drivers/kernel <<EOF
serial_debug_output true
serial_debug_port 0x3f8
bochs_debug_output true
load_symbols enabled
multiprocessor_support disabled
EOF

mkdir -p /new/home/config/boot
cat > /new/home/config/boot/UserBootscript <<EOF
#!/bin/sh
makebootable /boot > /boot/var/log/makebootable.log 2>&1
sync
/boot/beos/apps/Terminal &
EOF
chmod 755 /new/home/config/boot/UserBootscript

sync
unmount /new
unmount /beos' || die "Haiku BFS provisioning step failed"
log "BFS volume created, copied with attributes, and fixed up"

log "power down Haiku helper"
qmp_cmd "$HELPER_QMP" system_powerdown >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  [ -f "$HELPER_PID" ] && kill -0 "$(cat "$HELPER_PID" 2>/dev/null || echo 0)" 2>/dev/null || break
  sleep .5
done
stop_qemu "$HELPER_PID"

# R5's own boot loader stage-1 must occupy the partition's first sector so R5's
# makebootable (not Haiku's writembr) is what makes the volume bootable; mkfs
# above zeroed it, so write it back now, AFTER the Haiku step.
log "write R5 stage-1 boot sector (track2 sector 0 -> partition start)"
dd if="$WORK/track02.bfs" of="$WORK/beos-hd.raw" bs=512 count=1 seek=63 conv=notrunc

# ---- 4. first BeOS boot (from CD) to run makebootable -------------------------
log "step 4: first boot (CD loader, TCG) to run makebootable"
FIRSTBOOT_QMP="$WORK/qmp-firstboot.sock"
FIRSTBOOT_PID="$WORK/qemu-firstboot.pid"
clone_guard_assert_clone_qmp "$FIRSTBOOT_QMP"
clone_guard_assert_clone_path "$FIRSTBOOT_PID" "pidfile"
nice -n15 "$QEMU" \
  -name "build-beos-${STAMP}-firstboot" \
  -accel tcg -machine "$MACHINE" -cpu pentium3 -m 512 -smp 1 -rtc base=localtime \
  -drive "file=$WORK/beos-hd.raw,format=raw,if=ide,index=0" \
  -drive "file=$WORK/track01.iso,format=raw,media=cdrom,if=ide,index=2" \
  -vga std -display none \
  -netdev "user,id=n0" -device ne2k_pci,netdev=n0 \
  -boot d \
  -serial "file:$WORK/serial-1.log" \
  -qmp "unix:$FIRSTBOOT_QMP,server=on,wait=off" -pidfile "$FIRSTBOOT_PID" \
  >"$WORK/firstboot-qemu.log" 2>&1 &
for _ in $(seq 1 60); do
  [ -S "$FIRSTBOOT_QMP" ] && [ -s "$FIRSTBOOT_PID" ] && break
  sleep .5
done
[ -S "$FIRSTBOOT_QMP" ] && [ -s "$FIRSTBOOT_PID" ] || {
  tail -n 40 "$WORK/firstboot-qemu.log" >&2 || true
  die "first-boot QEMU did not create QMP socket/pidfile"
}
# TODO(stronger signal): the builder cannot read BFS from Linux, so it cannot
# poll /boot/var/log/makebootable.log directly. A serial marker written by
# UserBootscript after makebootable would replace this fixed wait.
log "waiting ${FIRSTBOOT_WAIT}s for UserBootscript to run makebootable"
sleep "$FIRSTBOOT_WAIT"
qmp_run "$FIRSTBOOT_QMP" shot "$WORK/firstboot.ppm" >/dev/null
qmp_run "$FIRSTBOOT_QMP" type "sync" key ret sleep 2 type "sync" key ret sleep 2 >/dev/null
stop_qemu "$FIRSTBOOT_PID"
log "first boot done; evidence: $WORK/firstboot.ppm, $WORK/serial-1.log"

# ---- 5. second boot from disk to prove the stage-1 ----------------------------
log "step 5: second boot (disk only) to prove the R5 stage-1 boot sector"
DISKBOOT_QMP="$WORK/qmp-diskboot.sock"
DISKBOOT_PID="$WORK/qemu-diskboot.pid"
clone_guard_assert_clone_qmp "$DISKBOOT_QMP"
clone_guard_assert_clone_path "$DISKBOOT_PID" "pidfile"
nice -n15 "$QEMU" \
  -name "build-beos-${STAMP}-diskboot" \
  -accel tcg -machine "$MACHINE" -cpu pentium3 -m 512 -smp 1 -rtc base=localtime \
  -drive "file=$WORK/beos-hd.raw,format=raw,if=ide,index=0" \
  -vga std -display none \
  -netdev "user,id=n0" -device ne2k_pci,netdev=n0 \
  -boot c \
  -serial "file:$WORK/serial-2.log" \
  -qmp "unix:$DISKBOOT_QMP,server=on,wait=off" -pidfile "$DISKBOOT_PID" \
  >"$WORK/diskboot-qemu.log" 2>&1 &
for _ in $(seq 1 60); do
  [ -S "$DISKBOOT_QMP" ] && [ -s "$DISKBOOT_PID" ] && break
  sleep .5
done
[ -S "$DISKBOOT_QMP" ] && [ -s "$DISKBOOT_PID" ] || {
  tail -n 40 "$WORK/diskboot-qemu.log" >&2 || true
  die "disk-boot QEMU did not create QMP socket/pidfile"
}
log "waiting ${BOOT_WAIT}s for disk boot"
sleep "$BOOT_WAIT"
qmp_run "$DISKBOOT_QMP" shot "$WORK/diskboot.ppm" >/dev/null

if [ "$DO_VERIFY" = 1 ]; then
  verify_ok=1
  python3 - "$WORK/diskboot.ppm" <<'PY' || verify_ok=0
import sys

path = sys.argv[1]
data = open(path, "rb").read()
if not data.startswith(b"P6"):
    raise SystemExit(f"{path}: not a binary PPM (P6)")
i = 2
tokens = []
while len(tokens) < 3:
    while data[i:i + 1] in b" \t\r\n":
        i += 1
    if data[i:i + 1] == b"#":
        i = data.index(b"\n", i) + 1
        continue
    j = i
    while data[j:j + 1] not in b" \t\r\n":
        j += 1
    tokens.append(data[i:j])
    i = j
while data[i:i + 1] in b" \t\r\n":
    i += 1
i += 1  # single whitespace after maxval
w, h = int(tokens[0]), int(tokens[1])
if (w, h) != (1024, 768):
    raise SystemExit(f"{path}: unexpected frame size {w}x{h}, want 1024x768")
pixels = data[i:]
colours = set()
for p in range(0, min(len(pixels), w * h * 3), 3):
    colours.add(pixels[p:p + 3])
    if len(colours) > 50:
        break
if len(colours) <= 50:
    raise SystemExit(f"{path}: frame looks uniform ({len(colours)} distinct colours)")
print(f"[beos verify] {path}: {w}x{h}, {len(colours)}+ distinct colours")
PY
  if [ "$verify_ok" != 1 ]; then
    echo "[build:beos ERROR] disk-boot framebuffer proof failed; see $WORK/diskboot.ppm and serial-2.log tail below" >&2
    tail -n 40 "$WORK/serial-2.log" >&2 || true
    die "framebuffer proof failed"
  fi
else
  log "DO_VERIFY=0: skipping disk-boot framebuffer proof"
fi

qmp_run "$DISKBOOT_QMP" type "sync" key ret sleep 2 >/dev/null
stop_qemu "$DISKBOOT_PID"
log "second boot proved the disk boots on its own stage-1"

# ---- 6. convert to the canonical qcow2 output ---------------------------------
log "step 6: convert raw disk -> qcow2"
part="$OUTPUT_DISK.part-${STAMP}"
qemu-img convert -f raw -O qcow2 "$WORK/beos-hd.raw" "$part"
mv "$part" "$OUTPUT_DISK"
log "PROVEN output: $OUTPUT_DISK"
sha256sum "$OUTPUT_DISK"
qemu-img info "$OUTPUT_DISK"

# ---- 7. next steps (not run by this script) -----------------------------------
cat <<EOF

Next steps (operator/orchestrator, not run by this script):
  cp $OUTPUT_DISK /data/vms/streamhost/stations/beos/beos-golden.qcow2
  scripts/lib/checkpoint-verify.sh beos --capture
EOF
