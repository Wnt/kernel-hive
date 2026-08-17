#!/bin/bash
# Stand up an ISOLATED win311 clone for freeze-repro work.
#
# Never experiment on a live station: this copies the golden disks into a
# namespaced sandbox dir with private sockets and its own pidfile. The guest
# DEVICE SET is byte-for-byte the live one (so `loadvm golden` still matches);
# only the host-side display/audio BACKEND differs, which is not part of vmstate.
#
# The generated launch.sh honours, at launch time:
#   COLD=1        cold-boot instead of `-loadvm golden`
#   SNAP=<tag>    restore a different internal snapshot
#   BIOS=<file>   ROM to boot; default is the live station's patched SeaBIOS
#                 (/data/vms/streamhost/firmware/bios-256k-int16if.bin).
#                 BIOS=stock boots QEMU's stock ROM — the one the freeze
#                 reproduces on. NOTE: a golden baked on one ROM restores THAT
#                 ROM's bytes whatever -bios says (pc.bios is in the vmstate),
#                 so compare ROMs on COLD=1 boots only.
#   QEMU_BIN=...  alternative qemu binary;  QEMU_EXTRA='...'  extra args (-d int …)
set -euo pipefail

NS="${NS:-w311frz-a1}"
SRC=/data/vms/streamhost/stations/win311
D="/data/vms/sandbox/$NS"

mkdir -p "$D"
if [ ! -f "$D/win311-golden.qcow2" ]; then
  echo "[setup] copying golden disks (reflink where possible)"
  cp --reflink=auto "$SRC/win311-golden.qcow2" "$D/win311-golden.qcow2"
  cp --reflink=auto "$SRC/games-golden.qcow2" "$D/games-golden.qcow2"
fi

cat >"$D/launch.sh" <<EOF
#!/bin/bash
set -e
D="$D"
[ -f "\$D/qemu.pid" ] && kill "\$(cat "\$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "\$D/qmp.sock" "\$D/qemu.pid" "\$D/serial.sock"
LOADVM=""
if [ "\${COLD:-0}" != 1 ]; then
  qemu-img snapshot -l "\$D/win311-golden.qcow2" 2>/dev/null | grep -qw "\${SNAP:-golden}" \
    && LOADVM="-loadvm \${SNAP:-golden}"
fi
BIOS="\${BIOS:-/data/vms/streamhost/firmware/bios-256k-int16if.bin}"
BIOSARG=""
if [ "\$BIOS" != stock ]; then
  [ -s "\$BIOS" ] || { echo "missing \$BIOS (BIOS=stock for QEMU's own ROM)" >&2; exit 1; }
  BIOSARG="-bios \$BIOS"
fi
# shellcheck disable=SC2086
nohup \${QEMU_BIN:-qemu-system-i386} \${QEMU_EXTRA:-} \
  -name w311-freeze-repro-$NS \
  -accel tcg -m 64 -smp 1 \
  -machine pc-i440fx-11.0 -cpu pentium \
  \$BIOSARG \
  -rtc base=localtime \
  -boot c \
  \$LOADVM \
  -vga std \
  -display none \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -drive file=\$D/win311-golden.qcow2,format=qcow2,if=ide \
  -drive file=\$D/games-golden.qcow2,format=qcow2,if=ide,index=1 \
  -nic user,ipv6=off,model=ne2k_pci \
  -chardev socket,id=ser0,path=\$D/serial.sock,server=on,wait=off \
  -serial chardev:ser0 \
  -qmp unix:\$D/qmp.sock,server=on,wait=off \
  -pidfile \$D/qemu.pid \
  >"\$D/qemu.log" 2>&1 &
for i in \$(seq 1 60); do
  [ -S "\$D/qmp.sock" ] && [ -f "\$D/qemu.pid" ] && break
  sleep 0.5
done
echo "clone $NS pid=\$(cat \$D/qemu.pid 2>/dev/null) qmp=\$D/qmp.sock"
EOF
chmod +x "$D/launch.sh"
echo "[setup] ready: $D"
