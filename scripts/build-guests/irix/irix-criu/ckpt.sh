#!/usr/bin/env bash
# ckpt.sh — CRIU checkpoint/restore for a cloned IRIX station, as one coherent pair
# of operations. Reset the exhibit in ~1.2 s instead of a ~4.5 min cold boot.
#
#   ckpt.sh bake    <tag>   freeze -> ZFS snapshot INSIDE the freeze window ->
#                           criu dump --leave-running. The clone keeps running.
#   ckpt.sh restore <tag>   roll the station dataset back to the paired snapshot ->
#                           criu restore -> measure time-to-INTERACTIVE.
#   ckpt.sh cycle   <tag>   kill + restore, i.e. the reset a visitor triggers.
#   ckpt.sh kill            clone-guard kill of the emulator.
#   ckpt.sh quiesce         stand the watchdogs down (bake does this itself).
#
# NOT SHIPPED. This is the procedure and its traps, preserved as a working
# script; the live station still resets by relaunching. See README.md for the
# evidence, the required launcher deltas and the reasons a smoke test passes
# while three of the traps below are active.
#
# Configuration — all required, all namespaced to YOUR clone:
#   IRIX_CRIU_W    work dir, must be under /data/vms/sandbox
#   IRIX_CRIU_TILE station dir inside the ZFS dataset being snapshotted
#                  (default $IRIX_CRIU_W/tile)
#   IRIX_CRIU_ZDS  the ZFS dataset holding the station dir, e.g. data/vms/mycriu
#   IRIX_CRIU_NS   network namespace the emulator runs in (see nsnet.sh)
#   IRIX_CRIU_SHM  the shm framebuffer file — MUST be outside the dataset
#                  (default $IRIX_CRIU_W/fb.shm)
#
# INVARIANTS THIS ENCODES. Each one was measured, and each one has a failure
# mode that looks healthy:
#  * the SNAPSHOT UNIT is the whole station directory, not just the CHD. criu
#    size-validates every open regular file, and mame.log / geo.log / irix_cmd
#    all grow. Rolling the directory back restores their sizes for free, which
#    is also what makes the command-file size trap unreachable.
#  * fb.shm lives OUTSIDE that unit, so its inode survives the rollback and a
#    running streamhost never loses its mapping. Deleting and re-creating it at
#    the same path RESTORES FINE AND STREAMS A FROZEN PICTURE FOREVER: MAME
#    writes the header only on its own mmap path, which restore bypasses.
#  * the CRIU image dir lives OUTSIDE that unit, or `zfs rollback -r` eats it.
#  * the launcher's start_mame() is NOT on the restore path — it removes
#    fb.shm, truncates the command file and re-copies the disk.
#  * the watchdogs are stood down FIRST. Their liveness probe WRITES a MOVEP
#    into the command file, and a one-byte size change inside the freeze window
#    fails the restore outright.
set -u

W="${IRIX_CRIU_W:?set IRIX_CRIU_W to a namespaced dir under /data/vms/sandbox}"
case "$W" in
  /data/vms/sandbox/*) : ;;
  *)
    echo "refusing to work outside /data/vms/sandbox" >&2
    exit 1
    ;;
esac
T="${IRIX_CRIU_TILE:-$W/tile}"
ZDS="${IRIX_CRIU_ZDS:?set IRIX_CRIU_ZDS to the ZFS dataset holding $T}"
NS="${IRIX_CRIU_NS:?set IRIX_CRIU_NS to the network namespace MAME runs in}"
SHM="${IRIX_CRIU_SHM:-$W/fb.shm}"
CG="${CLONE_GUARD:-/usr/local/bin/clone-guard}"
RIG="$(cd -- "$(dirname -- "$0")" && pwd)"
LOG="$W/ckpt.log"

say() { echo "$(date +'%F %T.%3N') $*" | tee -a "$LOG"; }
now() { date +%s.%N; }
el() { echo "$(now) - $1" | bc; }

quiesce() {
  # 1. Stand the watchdogs down. A generation bump is what production would use;
  #    killing the pidfiles makes it deterministic for a rig.
  date +%s%N >"$T/bootwatch.gen"
  local pf p
  for pf in bootwatch.pid livewatch.pid; do
    p="$(cat "$T/$pf" 2>/dev/null || true)"
    if [ -n "$p" ] && [ -e "/proc/$p" ]; then kill "$p" 2>/dev/null || true; fi
    : >"$T/$pf"
  done
  # 2. Nobody may hold the serial slave across the window: a holder keeps the
  #    pts index allocated and the restore fails outright.
  local pts
  pts="$(cat "$T/serial.pts" 2>/dev/null || true)"
  if [ -n "$pts" ] && fuser "$pts" >/dev/null 2>&1; then
    say "QUIESCE: WARNING $pts is held by $(fuser "$pts" 2>&1)"
  fi
  say "QUIESCE: watchdogs down, cmd=$(stat -c %s "$T/irix_cmd") bytes, pts=$pts"
}

# criu installs a CRIU chain (DROP everything not marked 0xc114) inside the net
# namespace to freeze the network for the duration of a dump or restore, and
# removes it on the way out. An ABORTED restore leaves it behind, and the guest
# is then silently network-dead behind a perfectly healthy desktop, a working
# serial console and a correct in-guest `ifconfig`. Always sweep it.
clean_criu_chain() {
  local t
  for t in iptables ip6tables; do
    ip netns exec "$NS" "$t" -S 2>/dev/null | grep -q '^-N CRIU' || continue
    ip netns exec "$NS" "$t" -D INPUT -j CRIU 2>/dev/null || true
    ip netns exec "$NS" "$t" -D OUTPUT -j CRIU 2>/dev/null || true
    ip netns exec "$NS" "$t" -F CRIU 2>/dev/null || true
    ip netns exec "$NS" "$t" -X CRIU 2>/dev/null || true
    say "NETNS: swept a leftover CRIU $t chain"
  done
}

# Disk atomicity is solved BY CONSTRUCTION, because a mismatched (memory, disk)
# pair is undetectable — invisible to criu, to the guest and to `xfs_repair -n`;
# the guest just serves stale data behind a healthy uptime/df/desktop. So the
# snapshot is taken inside criu's own freeze window via the post-dump action
# script, and the pair is named together. Restore hard-fails without the marker.
bake() {
  local tag="$1" img="$W/img/$1" rc dt bytes t0 P
  rm -rf "$img"
  mkdir -p "$img"
  P="$(cat "$T/mame.pid")"
  quiesce
  cat >"$W/snap-$tag.sh" <<EOF
#!/usr/bin/env bash
[ "\$CRTOOLS_SCRIPT_ACTION" = post-dump ] || exit 0
s=\$(date +%s.%N)
zfs snapshot $ZDS@$tag; rc=\$?
echo "snap $tag rc=\$rc wall=\$(echo "\$(date +%s.%N) - \$s" | bc)" >>$W/snap.log
exit \$rc
EOF
  chmod +x "$W/snap-$tag.sh"
  t0="$(now)"
  criu dump -t "$P" -D "$img" -o dump.log --shell-job --file-locks \
    --leave-running --action-script "$W/snap-$tag.sh"
  rc=$?
  dt="$(el "$t0")"
  bytes="$(du -sb --apparent-size "$img" | cut -f1)"
  say "BAKE tag=$tag rc=$rc freeze_wall=${dt}s img=$bytes [$(tail -1 "$W/snap.log")]"
  [ $rc = 0 ] || {
    grep -iE '^Error' "$img/dump.log" | tail -6
    return 1
  }
  cp "$T/serial.pts" "$img/serial.pts" 2>/dev/null || true
  echo "$ZDS@$tag" >"$img/PAIRED-SNAPSHOT"
}

restore() {
  local tag="$1" img="$W/img/$1" snap rc t0 t_disk t_proc P
  [ -f "$img/PAIRED-SNAPSHOT" ] || {
    say "RESTORE tag=$tag REFUSED: no paired snapshot recorded"
    return 1
  }
  snap="$(cat "$img/PAIRED-SNAPSHOT")"
  zfs list -t snapshot -H -o name "$snap" >/dev/null 2>&1 || {
    say "RESTORE tag=$tag REFUSED: snapshot $snap is gone"
    return 1
  }
  # --- the emulator is already gone at this point (killed by the caller) ---
  clean_criu_chain
  t0="$(now)"
  zfs rollback -r "$snap"
  t_disk="$(el "$t0")"
  rm -f "$T/mame.pid"
  # --manage-cgroups=ignore: the dump recorded whatever cgroup MAME was in (in
  # production, the station's `systemd-run --scope` qcap; in a rig, the launching
  # ssh session scope, long dead by restore time). criu cannot re-create a dead
  # scope — it fails with "cgroupd: recv req error" — so the restore wrapper
  # owns cgroup placement and must re-apply the memory cap and the taskset pin
  # itself.
  criu restore -D "$img" -o restore.log --shell-job --file-locks -d \
    --manage-cgroups=ignore \
    --join-ns "net:/run/netns/$NS" --pidfile "$T/mame.pid"
  rc=$?
  t_proc="$(el "$t0")"
  if [ $rc != 0 ]; then
    say "RESTORE tag=$tag FAILED rc=$rc after ${t_proc}s"
    grep -iE '^Error' "$img/restore.log" | tail -8
    clean_criu_chain
    return 1
  fi
  P="$(cat "$T/mame.pid")"
  # Re-publish the serial slave from the restored pid exactly as the launcher
  # does. criu keeps the same /dev/pts index and the termios settings, but the
  # path must never be cached across a restore.
  local f idx pts=""
  for f in /proc/"$P"/fd/*; do
    [ "$(readlink "$f" 2>/dev/null || true)" = /dev/ptmx ] || continue
    idx="$(awk '/^tty-index:/ { print $2 }' "/proc/$P/fdinfo/$(basename "$f")" 2>/dev/null || true)"
    [ -n "$idx" ] && pts="/dev/pts/$idx" && echo "$pts" >"$T/serial.pts"
  done
  # --- time to INTERACTIVE, not time to "the process exists": nudge the pointer
  #     through the REAL command file a visitor's mouse uses, and stop the clock
  #     only when the guest redraws the cursor somewhere else in a real capture.
  local c0 c1 t_int="TIMEOUT" i
  c0="$("$RIG/curs.py" "$SHM" 2>/dev/null || echo "")"
  echo "MOVEP 140 -90" >>"$T/irix_cmd"
  for i in $(seq 1 400); do
    c1="$("$RIG/curs.py" "$SHM" 2>/dev/null || echo "")"
    if [ -n "$c1" ] && [ "$c1" != "$c0" ] && [ "$c1" != "none" ]; then
      t_int="$(el "$t0")"
      break
    fi
    sleep 0.05
  done
  echo "MOVEP -140 90" >>"$T/irix_cmd"
  say "RESTORE tag=$tag rc=0 pid=$P pts=$pts disk_wall=${t_disk}s proc_wall=${t_proc}s INTERACTIVE=${t_int}s cursor:$c0 -> $c1"
}

killmame() {
  local p i
  p="$(cat "$T/mame.pid" 2>/dev/null || true)"
  [ -n "$p" ] || return 0
  "$CG" kill-pidfile "$T/mame.pid" >/dev/null 2>&1 || kill -9 "$p" 2>/dev/null || true
  for i in $(seq 40); do
    [ -e "/proc/$p" ] || break
    sleep 0.25
  done
  [ -e "/proc/$p" ] && {
    say "KILL: pid $p SURVIVED"
    return 1
  }
  say "KILL: pid $p gone"
}

case "${1:-}" in
  bake)
    shift
    bake "${1:?tag}"
    ;;
  restore)
    shift
    restore "${1:?tag}"
    ;;
  cycle)
    shift
    killmame && restore "${1:?tag}"
    ;;
  kill) killmame ;;
  quiesce) quiesce ;;
  *)
    echo "usage: ckpt.sh bake|restore|cycle|kill|quiesce [<tag>]" >&2
    exit 2
    ;;
esac
