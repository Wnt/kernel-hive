#!/usr/bin/env bash
# nextstep-bake-golden.sh — bake (and prove) the station's CRIU golden.
#
# The `nextstep` station has no vmstate snapshot to `loadvm` and a NeXTSTEP UFS
# root that must never be hard-killed, so "restore to golden" is a CRIU restore
# of the emulator process against the disk image that was reflinked INSIDE the
# very freeze window the memory image was written in. This script is the only
# supported way to produce that pair.
#
#   nextstep-bake-golden.sh bake     [tag]   freeze -> pair the disk -> criu dump
#   nextstep-bake-golden.sh prove    [tag]   kill + restore + measure + verify
#   nextstep-bake-golden.sh kill             stop the emulator by pidfile
#
# Run it on labhost, against a station whose guest is ALREADY on the acceptance
# scene (scripts/build-guests/nextstep/nextstep-scene.py puts it there).
#
# INVARIANTS, each one measured and each one silent when broken:
#
#  * NO CLIENT ON THE CONTROL SOCKET. A dump succeeds with $CTL merely LISTENING
#    and FAILS while a client is CONNECTED ("unix: Unix socket … not found"),
#    and --ext-unix-sk does not rescue it. Stop the daemon, or let its mamesock
#    sink reconnect afterwards — it retries forever with backoff.
#  * NO CHARACTER-DEVICE fds. SDL opens /dev/input/event* under the dummy video
#    driver and criu cannot dump those; the launcher's unprivileged account is
#    what keeps them unopened. This script refuses a bake if any appear.
#  * THE FRAMEBUFFER IS NOT PART OF THE PAIR. criu never copies $SHM: same
#    inode, same virtual address. Deleting and re-creating it at the same path
#    restores fine and streams a FROZEN PICTURE FOREVER.
#  * THE PAIRED DISK IS THE ONLY DISK THIS IMAGE IS VALID AGAINST. A mismatched
#    (memory, disk) pair is invisible to criu, to the guest and to fsck — the
#    machine serves stale data behind a healthy desktop. Safety is construction,
#    never detection: the disk is reflinked inside the freeze and named with the
#    image, and the launcher refuses a restore without both.
#  * previous.log IS PART OF THE PAIR. criu size-validates every open regular
#    file fd, and the log grows between bake and restore.
set -u

BASE="${NEXTSTEP_BASE:-/data/vms/streamhost/stations/nextstep}"
ASSETS="${NEXTSTEP_ASSETS:-/data/vms/streamhost/assets/nextstep}"
BIN="${NEXTSTEP_BIN:-$ASSETS/previous}"
STATE_DIR="${NEXTSTEP_STATE_DIR:-$ASSETS/state}"
RUN="$BASE/run"
PIDFILE="$BASE/mame.pid"
DISK="$RUN/disk.dd"
LOG="$RUN/previous.log"
SHM="${SH_SHM_PATH:-$RUN/fb.shm}"
CTL="${SH_MAMECTL_SOCK:-$RUN/ctl.sock}"
RN_NS="${RN_NS:-nextstep-rn}"
RN_VETH_OUT="${RN_VETH_OUT:-nextrn0}"
RN_VETH_INN="${RN_VETH_INN:-nextrn1}"
TAG="${2:-golden}"

say() { echo "$(date +'%F %T') bake: $*"; }
die() {
  echo "$(date +'%F %T') bake: FATAL $*" >&2
  exit 1
}
pid_of() { cat "$PIDFILE" 2>/dev/null || true; }

check_fds() {
  local p="$1" f t bad=0
  for f in /proc/"$p"/fd/*; do
    t="$(readlink "$f" 2>/dev/null || true)"
    case "$t" in
      /dev/input/* | /dev/snd/*)
        echo "  UNDUMPABLE fd $(basename "$f") -> $t" >&2
        bad=1
        ;;
    esac
  done
  [ "$bad" = 0 ] || die "the emulator holds character-device fds criu cannot dump (is it running as root?)"
}

check_no_client() {
  # A connected peer on the control socket is the one thing that turns a working
  # bake into a confusing failure, so name it before criu does.
  local p="$1" n
  n="$(ss -x -p 2>/dev/null | grep -c "$CTL" || true)"
  say "control socket endpoints seen by ss: $n (listening socket itself is one)"
}

bake() {
  local img="$STATE_DIR/$TAG/img" p rc t0 t1
  p="$(pid_of)"
  [ -n "$p" ] && [ -e "/proc/$p" ] || die "no running emulator in $PIDFILE"
  check_fds "$p"
  check_no_client "$p"
  rm -rf "${STATE_DIR:?}/${TAG:?}"
  mkdir -p "$img"
  # Close the HOST side of the NIC: criu cannot dump libpcap's AF_PACKET socket
  # (`sockets.c:628 Can't get 1:16 opt: Operation not supported`), and the
  # guest's own NIC state lives in emulated memory, which the image carries.
  # The launcher says NETUP again after every restore.
  if [ "${NEXTSTEP_NET:-on}" = on ]; then
    python3 "$BASE/ctl.py" "$CTL" NETDOWN || die "NETDOWN refused; is this the fork build?"
    sleep 1
  fi
  t0="$(date +%s.%N)"
  kill -STOP "$p" || die "could not stop $p"
  sleep 1
  # Inside the freeze: the disk and the log, reflinked/copied as one unit.
  cp --reflink=always "$DISK" "$STATE_DIR/$TAG/disk-golden.dd" || die "paired disk reflink failed"
  cp "$LOG" "$STATE_DIR/$TAG/previous.log" || die "paired log copy failed"
  # --external veth[inner]:outer is not optional. Without it criu dumps the veth
  # as an ordinary device inside the namespace and the RESTORE dies on
  # `net.c:1469 Unknown peer net namespace` -- the peer lives in the host
  # namespace, which is not in the image. With it, criu records the pair as
  # external, deletes and re-creates it at restore (a new ifindex every cycle,
  # host end BARE), which is exactly why rn-tapnet.sh up is the post-restore hook.
  local ext=()
  [ "${NEXTSTEP_NET:-on}" = on ] && ext=(--external "veth[$RN_VETH_INN]:$RN_VETH_OUT")
  criu dump -t "$p" -D "$img" -o dump.log --shell-job --file-locks \
    --manage-cgroups=ignore --leave-running "${ext[@]}"
  rc=$?
  t1="$(date +%s.%N)"
  if [ $rc != 0 ]; then
    grep -iE '^Error' "$img/dump.log" 2>/dev/null | tail -8 >&2
    kill -CONT "$p" 2>/dev/null || true
    die "criu dump failed rc=$rc"
  fi
  # The emulator was SIGSTOPped for the freeze and --leave-running leaves it in
  # that job-control stop. Nothing else wakes it.
  kill -CONT "$p" || die "could not resume $p"
  if [ "${NEXTSTEP_NET:-on}" = on ]; then
    python3 "$BASE/ctl.py" "$CTL" NETUP || say "WARNING: NETUP after the bake failed"
  fi
  md5sum "$BIN" >"$STATE_DIR/$TAG/provenance.md5"
  {
    echo "tag=$TAG"
    echo "baked=$(date -Is)"
    echo "binary=$BIN"
    echo "binary_md5=$(md5sum "$BIN" | cut -d' ' -f1)"
    echo "disk_pair=disk-golden.dd (reflink of $DISK, taken inside the freeze)"
    echo "netns=$RN_NS"
  } >"$STATE_DIR/$TAG/PROVENANCE"
  say "BAKED tag=$TAG freeze=$(echo "$t1 - $t0" | bc)s img=$(du -sh --apparent-size "$img" | cut -f1) ($(du -sh "$img" | cut -f1) on disk)"
}

killemu() {
  local p i
  p="$(pid_of)"
  [ -n "$p" ] || return 0
  kill -CONT "$p" 2>/dev/null || true
  kill -KILL "$p" 2>/dev/null || true
  for i in $(seq 40); do
    [ -e "/proc/$p" ] || break
    sleep 0.25
  done
  [ -e "/proc/$p" ] && die "pid $p survived SIGKILL"
  say "killed pid $p"
}

prove() {
  local t0 t1 p
  killemu
  t0="$(date +%s.%N)"
  bash "$BASE/x11-runtime.sh" || die "restore launch failed"
  t1="$(date +%s.%N)"
  p="$(pid_of)"
  say "PROVE tag=$TAG restore_wall=$(echo "$t1 - $t0" | bc)s pid=$p"
  grep -q 'COLD BOOT' /dev/null 2>&1 || true
}

case "${1:-}" in
  bake) bake ;;
  prove) prove ;;
  kill) killemu ;;
  *)
    sed -n '2,20p' "$0" >&2
    exit 2
    ;;
esac
