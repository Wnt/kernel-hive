#!/usr/bin/env bash
# Launch an isolated NT 3.51 clone with the Cirrus trace/fix QEMU.
set -euo pipefail

readonly INSTALLED_QEMU=/opt/qemu-cirrusfix/bin/qemu-system-i386
readonly INSTALLED_DATADIR=/usr/share/kvm

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ $# -eq 2 ]] || die "usage: $0 <qcirrus-trace-clone-dir> <local-qemu-bin>"
D=${1%/}
QEMU_BIN=$2
QEMU_DATADIR=${QEMU_DATADIR:-$D/build/pve-qemu-kvm-11.0.2/build/qemu-bundle/usr/share/kvm}

case "$D/" in
  /data/vms/sandbox/qcirrus-trace-*/*) ;;
  *) die "refusing non-trace clone path: $D" ;;
esac
case "$QEMU_BIN" in
  "$INSTALLED_QEMU") ;;
  "$D"/build/*) ;;
  *) die "QEMU binary must be the installed Cirrus-fix binary or inside $D/build: $QEMU_BIN" ;;
esac
case "$QEMU_DATADIR" in
  "$INSTALLED_DATADIR") ;;
  "$D"/build/*) ;;
  *) die "QEMU data directory must be /usr/share/kvm or inside $D/build: $QEMU_DATADIR" ;;
esac

# shellcheck source=/dev/null
source /usr/local/bin/clone-guard
clone-guard assert-path "$D"
clone-guard assert-qmp "$D/qmp.sock"
clone_guard_kill_pidfile "$D/qemu.pid"
[[ -x "$QEMU_BIN" ]] || die "QEMU binary is not executable: $QEMU_BIN"
[[ -r "$QEMU_DATADIR/bios.bin" ]] || die "QEMU BIOS not found in $QEMU_DATADIR"
[[ -r "$D/nt351-golden.qcow2" ]] || die "clone disk not found"

rm -f "$D/qmp.sock" "$D/qemu.pid"
loadvm=()
if qemu-img snapshot -l "$D/nt351-golden.qcow2" | grep -qw golden; then
  loadvm=(-loadvm golden)
fi

if [[ "$QEMU_BIN" != "$INSTALLED_QEMU" ]]; then
  export QEMU_CIRRUS_BLT_TRACE=1
fi
nohup "$QEMU_BIN" \
  -L "$QEMU_DATADIR" \
  -name "qcirrus-$(basename "$D")" \
  -accel tcg -m 64 -smp 1 \
  -machine isapc -cpu 486 \
  -rtc base=localtime \
  -cdrom /data/gallery-guests/Nt351/NTWKS351_UPD.iso \
  -boot order=c,menu=off \
  -device isa-cirrus-vga,global-vmstate=on \
  -display none \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -drive file="$D/nt351-golden.qcow2",format=qcow2,if=ide \
  -net nic,model=ne2k_isa -net user \
  "${loadvm[@]}" \
  -qmp unix:"$D/qmp.sock",server=on,wait=off \
  -pidfile "$D/qemu.pid" \
  >"$D/qemu.log" 2>&1 &

for _ in $(seq 1 40); do
  [[ -S "$D/qmp.sock" && -r "$D/qemu.pid" ]] && break
  sleep 0.5
done
[[ -S "$D/qmp.sock" && -r "$D/qemu.pid" ]] ||
  die "QEMU failed to create its namespaced QMP socket and pidfile"

qemu_pid=$(<"$D/qemu.pid")
qemu_argv=$(tr '\0' ' ' <"/proc/$qemu_pid/cmdline")
case "$qemu_argv" in
  "$QEMU_BIN "*) ;;
  *) die "running process does not use the local binary: $qemu_argv" ;;
esac

printf 'pid=%s qmp=%s binary=%s loadvm=%s\n' \
  "$qemu_pid" "$D/qmp.sock" "$QEMU_BIN" \
  "$([[ ${#loadvm[@]} -gt 0 ]] && printf golden || printf none)"
