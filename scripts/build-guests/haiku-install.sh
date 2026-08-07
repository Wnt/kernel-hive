#!/usr/bin/env bash
# =============================================================================
# build-guests/haiku-install.sh — install the fetched Haiku anyboot ISO onto the
# persistent streamhost disk, provision sshd + the gallery key, apply the
# deterministic fixture settings, and bake the internal `golden` savevm point.
#
# PROOF STATUS: PROVEN on-box 2026-07-14 in an isolated repro-haiku-* run.
# Evidence: clean ISO install; disk-only 1280x720 boot; gallery-key SSH before
# and after clean reboot; `savevm golden`; dirty input; `loadvm golden` restored
# x<1000 byte-exactly; stopped qcow2 passed qemu-img check. Repro dir deleted.
#
# Input (produced by build-guests/haiku.sh):
#   /data/gallery-guests/Haiku/haiku.iso
# Output (consumed by streamhost/tiles-manifest.sh):
#   /data/vms/streamhost/tiles/haiku/haiku-persist.qcow2
#
# The disk-only phase uses the launcher's exact guest-visible device set:
# pc-i440fx-11.0, KVM/host CPU, one IDE qcow2, VGA with a 1280x720 EDID,
# intel-hda+hda-output, USB tablet, and e1000. The proof uses headless display
# and audio backends and a unique hostfwd port; those are host backends, not
# guest devices, so the saved VM state loads under the production DBus backends.
# The install-only CD-ROM is removed before fixture setup and `savevm golden`.
#
# Safety:
#   * all transient files/sockets/pidfiles live in a unique repro-haiku-* dir;
#   * QEMU runs at nice 15 and is stopped only through its QMP/pidfile;
#   * no live tile process/socket is touched;
#   * an existing output is refused unless FORCE=1 (then it is backed up).
#
# Usage:
#   scripts/build-guests/haiku.sh
#   scripts/build-guests/haiku-install.sh
#
# Useful overrides:
#   HAIKU_ISO=... HAIKU_OUTPUT_DISK=... HAIKU_WORK_DIR=...
#   HAIKU_GALLERY_KEY=... HAIKU_MACHINE=... FORCE=1 KEEP_WORK=1
# =============================================================================
set -euo pipefail

ISO="${HAIKU_ISO:-/data/gallery-guests/Haiku/haiku.iso}"
OUTPUT_DISK="${HAIKU_OUTPUT_DISK:-/data/vms/streamhost/tiles/haiku/haiku-persist.qcow2}"
GALLERY_KEY="${HAIKU_GALLERY_KEY:-/root/.ssh/gallery_guest_key}"
GALLERY_PUBKEY="${HAIKU_GALLERY_PUBKEY:-${GALLERY_KEY}.pub}"
MACHINE="${HAIKU_MACHINE:-pc-i440fx-11.0}"
QEMU="${HAIKU_QEMU:-qemu-system-x86_64}"
DISK_SIZE="${HAIKU_DISK_SIZE:-6G}"
INSTALL_WAIT="${HAIKU_INSTALL_WAIT:-120}"
DESKTOP_WAIT="${HAIKU_DESKTOP_WAIT:-45}"
FORCE="${FORCE:-0}"
KEEP_WORK="${KEEP_WORK:-0}"
STAMP="$(date +%s)"
WORK="${HAIKU_WORK_DIR:-/data/vms/soltest/repro-haiku-${STAMP}}"
DISK="$WORK/haiku-persist.qcow2"
QMP="$WORK/qmp.sock"
PIDFILE="$WORK/qemu.pid"
QEMU_LOG="$WORK/qemu.log"
ASSET_B64="$(cd "$(dirname "$0")" && pwd)/assets/haiku/fixture-settings.tar.base64"
ISO_BUILDER="$(cd "$(dirname "$0")" && pwd)/haiku.sh"
FIXTURE_TAR="$WORK/fixture-settings.tar"
FIXTURE_SHA="d9073d23f4ef2574724d6085ba1993878f2e4903ac4cf9d0f83dda85c88de5a8"

log() { printf '[haiku-install %(%H:%M:%S)T] %s\n' -1 "$*"; }
die() {
  printf '[haiku-install ERROR] %s\n' "$*" >&2
  exit 1
}

# Make this script a complete build-all entry while still accepting a supplied
# ISO. The canonical path reuses haiku.sh's pinned download/checksum/GUI proof;
# a custom HAIKU_ISO is taken as-is. HAIKU_SKIP_ISO_STAGE=1 also skips this.
if [ -z "${HAIKU_ISO+x}" ] && [ "${HAIKU_SKIP_ISO_STAGE:-0}" != 1 ]; then
  iso_args=(--dir "$(dirname "$ISO")")
  [ "$FORCE" = 1 ] && iso_args+=(--force)
  if [ "${DO_VERIFY:-1}" = 0 ] || [ "${VERIFY:-1}" = 0 ]; then iso_args+=(--no-verify); fi
  log "stage 0: fetch/verify canonical ISO via haiku.sh"
  bash "$ISO_BUILDER" "${iso_args[@]}"
fi

for b in "$QEMU" qemu-img python3 base64 sha256sum ssh scp timeout; do
  command -v "$b" >/dev/null 2>&1 || die "missing host tool: $b"
done
[ -s "$ISO" ] || die "Haiku ISO missing: $ISO (run haiku.sh first)"
[ -s "$GALLERY_KEY" ] || die "gallery private key missing: $GALLERY_KEY"
[ -s "$GALLERY_PUBKEY" ] || die "gallery public key missing: $GALLERY_PUBKEY"
[ -s "$ASSET_B64" ] || die "fixture asset missing: $ASSET_B64"
[ ! -e "$WORK" ] || die "work dir already exists: $WORK"
mkdir -p "$WORK"
base64 -d "$ASSET_B64" >"$FIXTURE_TAR"
[ "$(sha256sum "$FIXTURE_TAR" | awk '{print $1}')" = "$FIXTURE_SHA" ] ||
  die "fixture-settings.tar checksum mismatch"

SSH_PORT="${HAIKU_SSH_PORT:-$(
  python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)}"

qmp_raw() {
  python3 - "$QMP" "$1" <<'PY'
import json,socket,sys
sock,raw=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock)
f=s.makefile('rwb', buffering=0)
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    obj=json.loads(f.readline())
    if 'return' in obj or 'error' in obj: break
f.write(raw.encode()+b'\n')
while True:
    obj=json.loads(f.readline())
    if 'return' in obj:
        value=obj['return']
        if value not in ({}, ''): print(value)
        break
    if 'error' in obj:
        raise SystemExit('QMP error: '+json.dumps(obj['error']))
s.close()
PY
}

hmp() {
  local encoded
  encoded="$(
    python3 - "$1" <<'PY'
import json,sys
print(json.dumps({'execute':'human-monitor-command','arguments':{'command-line':sys.argv[1]}}))
PY
  )"
  qmp_raw "$encoded"
}

shot() {
  qmp_raw "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/$1.ppm\"}}" >/dev/null
}

move_abs() {
  local ax ay
  ax=$(($1 * 32767 / 1279))
  ay=$(($2 * 32767 / 719))
  qmp_raw "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"abs\",\"data\":{\"axis\":\"x\",\"value\":$ax}},{\"type\":\"abs\",\"data\":{\"axis\":\"y\",\"value\":$ay}}]}}" >/dev/null
}

button() {
  qmp_raw "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"btn\",\"data\":{\"down\":$1,\"button\":\"left\"}}]}}" >/dev/null
}

click() {
  move_abs "$1" "$2"
  button true
  sleep .2
  button false
  sleep .6
}

type_text() {
  # ASCII-only QEMU key injection. The public key is passed as an argv value and
  # is never logged; do not run this script with shell tracing enabled.
  python3 - "$QMP" "$1" <<'PY'
import json,socket,sys,time
sock,text=sys.argv[1],sys.argv[2]
special={' ':'spc','\n':'ret','-':'minus','/':'slash','.':'dot',
         '_':'shift-minus',':':'shift-semicolon',';':'semicolon',
         '>':'shift-dot','<':'shift-comma','|':'shift-backslash',
         '+':'shift-equal','=':'equal','~':'shift-grave','$':'shift-4'}
def key(c):
    if c in special: return special[c]
    if c.isdigit(): return c
    if 'a' <= c.lower() <= 'z': return ('shift-' if c.isupper() else '')+c.lower()
    raise SystemExit('unsupported input character')
s=socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(sock)
f=s.makefile('rwb', buffering=0)
f.readline(); f.write(b'{"execute":"qmp_capabilities"}\n')
while True:
    o=json.loads(f.readline())
    if 'return' in o or 'error' in o: break
for c in text:
    q={'execute':'human-monitor-command','arguments':{'command-line':'sendkey '+key(c)}}
    f.write(json.dumps(q).encode()+b'\n')
    while True:
        o=json.loads(f.readline())
        if 'return' in o or 'error' in o: break
    time.sleep(.018)
s.close()
PY
}

stop_qemu() {
  local pid=""
  [ -s "$PIDFILE" ] && pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -S "$QMP" ]; then qmp_raw '{"execute":"quit"}' >/dev/null 2>&1 || true; fi
  if [ -n "$pid" ]; then
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep .2
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 2
    fi
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  fi
  rm -f "$QMP" "$PIDFILE"
}

cleanup() {
  stop_qemu
  if [ "$KEEP_WORK" != 1 ]; then rm -rf "$WORK"; else log "KEEP_WORK=1: $WORK"; fi
}
trap cleanup EXIT INT TERM

start_qemu() {
  local phase="$1"
  shift
  rm -f "$QMP" "$PIDFILE"
  log "start QEMU phase=$phase (nice=15, ssh hostfwd=$SSH_PORT)"
  nice -n15 "$QEMU" \
    -name "repro-haiku-${STAMP}-${phase}" \
    -enable-kvm -m 2048 -smp 2 -machine "$MACHINE" -cpu host \
    -rtc base=localtime \
    -drive "file=$DISK,format=qcow2,if=ide" "$@" \
    -display none \
    -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 \
    -usb -device usb-tablet \
    -device VGA,id=vga0,edid=on,xres=1280,yres=720 \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device e1000,netdev=n0 \
    -qmp "unix:$QMP,server=on,wait=off" -pidfile "$PIDFILE" \
    >"$QEMU_LOG" 2>&1 &
  for _ in $(seq 1 60); do
    [ -S "$QMP" ] && [ -s "$PIDFILE" ] && return 0
    sleep .5
  done
  tail -n 40 "$QEMU_LOG" >&2 || true
  die "QEMU did not create QMP socket/pidfile"
}

SSH_OPTS=(-i "$GALLERY_KEY" -p "$SSH_PORT" -o BatchMode=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
SCP_OPTS=(-q -i "$GALLERY_KEY" -P "$SSH_PORT" -o BatchMode=yes
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# shellcheck disable=SC2029 # arguments are intentionally the remote command
guest_ssh() { ssh "${SSH_OPTS[@]}" user@127.0.0.1 "$@"; }
wait_for_ssh() {
  local tries="${1:-45}"
  for _ in $(seq 1 "$tries"); do
    timeout 5 ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 user@127.0.0.1 true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

log "work=$WORK"
log "ISO -> installed persistent disk"
qemu-img create -q -f qcow2 "$DISK" "$DISK_SIZE"
start_qemu install -cdrom "$ISO" -boot order=d,menu=off
sleep 50
shot welcome

# Welcome -> Installer -> DriveSetup.
click 780 542 # Install Haiku
sleep 3
click 890 555 # Continue
sleep 3
hmp 'sendkey ret' >/dev/null # no suitable partitions modal
sleep 1
click 410 476 # Set up partitions...
sleep 3

# Initialize the raw IDE disk with an Intel partition map.
click 300 313 # /dev/disk/ata/0/master/raw
click 158 132 # Disk menu
move_abs 190 154
sleep 1       # Initialize submenu
click 330 174 # Intel Partition Map...
sleep 1
click 684 300 # Continue
sleep 1
click 646 312 # Write changes
sleep 3
hmp 'sendkey ret' >/dev/null # initialized OK
sleep 1

# Full-disk active BFS partition, then format it as "Haiku".
click 400 329                  # Empty space
hmp 'sendkey alt-c' >/dev/null # Partition > Create
sleep 1
hmp 'sendkey ret' >/dev/null # full size/BFS/active defaults -> Create
sleep 1
click 646 312 # Write partition table changes
sleep 3
click 400 329 # select new partition
click 210 132 # Partition menu
move_abs 220 173
sleep 1       # Format submenu
click 450 173 # Be File System...
sleep 1
click 684 288 # Continue
sleep 1
hmp 'sendkey ret' >/dev/null # name Haiku/default block size -> Format
sleep 1
click 646 312 # Write format changes
sleep 4
hmp 'sendkey ret' >/dev/null # formatted OK
sleep 1
click 148 104 # close DriveSetup
sleep 3

# Select the new target, install, then use the guest Restart button so BFS is
# cleanly unmounted before the install QEMU is stopped.
click 550 388 # Onto dropdown
hmp 'sendkey down' >/dev/null
hmp 'sendkey ret' >/dev/null
sleep 2
click 890 476 # Begin
log "installer copying files (wait ${INSTALL_WAIT}s)"
sleep "$INSTALL_WAIT"
shot installed
click 890 476 # Restart
sleep 15
stop_qemu

log "cold-boot installed disk with the production device set"
start_qemu disk -boot order=c,menu=off
sleep 50
shot disk-boot

# Open Terminal through the stock Deskbar and bootstrap sshd. Haiku's packaged
# sshd overrides AuthorizedKeysFile to config/settings/ssh/authorized_keys.
click 1241 13 # Deskbar leaf
move_abs 1050 225
sleep 1       # Applications submenu
click 881 671 # Terminal
sleep 3
PUB64="$(base64 -w0 "$GALLERY_PUBKEY")"
type_text "mkdir -p /boot/home/config/settings/ssh
echo $PUB64 | base64 -d > /boot/home/config/settings/ssh/authorized_keys
chmod 700 /boot/home/config/settings/ssh
chmod 600 /boot/home/config/settings/ssh/authorized_keys
ssh-keygen -A
/bin/sshd
clear
"
unset PUB64
sleep 4
wait_for_ssh 20 || die "gallery-key SSH bootstrap failed"
log "gallery key authenticated to fresh Haiku install"

scp "${SCP_OPTS[@]}" "$FIXTURE_TAR" user@127.0.0.1:/boot/home/fixture-settings.tar
# shellcheck disable=SC2016 # this whole block is evaluated by the guest shell
guest_ssh 'set -e
mkdir -p /boot/home/config/settings/boot /boot/home/config/settings/Terminal /boot/home/config/settings/deskbar
printf "#!/bin/sh\n/bin/sshd\n" > /boot/home/config/settings/boot/UserBootscript
chmod 755 /boot/home/config/settings/boot/UserBootscript
tar xf /boot/home/fixture-settings.tar -C /boot/home/config/settings
sync
test "$(tar tf /boot/home/fixture-settings.tar | wc -l)" -eq 5
test "$(stat -c %a /boot/home/config/settings/ssh/authorized_keys)" = 600'

log "clean reboot: prove sshd/key autostart and load fixture settings"
guest_ssh 'shutdown -r' >/dev/null 2>&1 || true
wait_for_ssh 45 || die "sshd/gallery key did not survive clean reboot"
guest_ssh 'test -f /boot/home/config/settings/Terminal/Default
test -f /boot/home/config/settings/ScreenSaver_settings
test -x /boot/home/config/settings/boot/UserBootscript'
log "sshd is up; wait ${DESKTOP_WAIT}s for app_server/Deskbar before opening Terminal"
sleep "$DESKTOP_WAIT"
shot post-reboot-desktop
timeout 8 ssh "${SSH_OPTS[@]}" user@127.0.0.1 \
  '/system/apps/Terminal >/dev/null 2>&1 &' >/dev/null 2>&1 || true
sleep 5

log "bake and prove internal snapshot golden"
shot baseline
hmp 'savevm golden' >/dev/null
SNAPS="$(hmp 'info snapshots')"
grep -qw golden <<<"$SNAPS" || die "savevm did not create golden"
type_text $'DIRTY\n'
sleep 1
shot dirty
hmp 'loadvm golden' >/dev/null
sleep 2
shot restored

# The Deskbar network replicant can repaint a few pixels independently. Compare
# the input-reactive surface/desktop region (x < 1000): dirty must differ and
# loadvm must restore it byte-for-byte.
python3 - "$WORK/baseline.ppm" "$WORK/dirty.ppm" "$WORK/restored.ppm" <<'PY'
import sys
def read(path):
    data=open(path,'rb').read(); i=0; tok=[]
    while len(tok)<4:
        while data[i:i+1] in b' \t\r\n': i+=1
        if data[i:i+1]==b'#':
            i=data.index(b'\n',i)+1; continue
        j=i
        while data[j:j+1] not in b' \t\r\n': j+=1
        tok.append(data[i:j]); i=j
    while data[i:i+1] in b' \t\r\n': i+=1
    w,h=int(tok[1]),int(tok[2]); px=data[i:]
    return b''.join(px[y*w*3:y*w*3+1000*3] for y in range(h))
b,d,r=map(read,sys.argv[1:])
if b==d: raise SystemExit('dirty frame did not change')
if b!=r: raise SystemExit('loadvm did not restore the fixture region exactly')
print('[haiku-install] snapshot proof: dirty changed; loadvm restored x<1000 byte-exactly')
PY
wait_for_ssh 10 || die "gallery-key SSH failed after loadvm golden"
stop_qemu
qemu-img snapshot -l "$DISK" | grep -qw golden || die "golden missing from stopped output disk"

mkdir -p "$(dirname "$OUTPUT_DISK")"
if [ -e "$OUTPUT_DISK" ]; then
  [ "$FORCE" = 1 ] || die "output exists: $OUTPUT_DISK (set FORCE=1 to replace safely)"
  backup="$OUTPUT_DISK.bak-$(date +%Y%m%d-%H%M%S)"
  log "backup existing output -> $backup"
  mv "$OUTPUT_DISK" "$backup"
fi
part="$OUTPUT_DISK.part-${STAMP}"
mv "$DISK" "$part"
mv "$part" "$OUTPUT_DISK"
log "PROVEN output: $OUTPUT_DISK"
qemu-img info "$OUTPUT_DISK" | sed -n '1,6p'
qemu-img snapshot -l "$OUTPUT_DISK"
