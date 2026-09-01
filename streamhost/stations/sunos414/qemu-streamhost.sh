#!/bin/bash
# Launch station 'sunos414' (slot 147) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# SunOS 4.1.4 (Solaris 1.1.2) with OpenWindows 3 on an emulated SPARCstation 5
# (sun4m) — a foreign-architecture QEMU station in the macos753/hpuxvue mould.
#
# THE BINARY IS NOT pve-qemu. The fleet package ships no sparc target, so this
# station runs a standalone build of the kernel-hive QEMU fork
# (github.com/Wnt/qemu, branch kernel-hive) installed at /opt/qemu-sparc; the
# OpenBIOS sparc32 firmware and the cgthree FCode ROM are the fork's own
# pc-bios blobs copied to /opt/qemu-sparc/share/qemu (-L). Rebuild:
#   ../configure --target-list=sparc-softmmu --enable-slirp --enable-dbus-display \
#     --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice \
#     --disable-opengl --disable-werror --disable-tools --prefix=/opt/qemu-sparc
#   ninja qemu-system-sparc; install it + pc-bios/openbios-sparc32,QEMU,cgthree.bin
#
# TCG, NO KVM. 32-bit SPARC has no acceleration path; the station burns a host
# core whenever the guest runs.
#
# THE FOUR LOAD-BEARING FLAGS (each one cost a boot attempt, see docs/guests):
#   -vga cg3                      The pinned framebuffer. NOT because SunOS lacks
#                                 a TCX driver -- it has one (tcx.c 1.48 94/08/22
#                                 SMI) and a cold boot with -vga tcx attaches it
#                                 ("SUNW,tcx0 ... tcx0: revision 0, screen
#                                 1024x768") and reaches the OpenWindows desktop.
#                                 TCX is rejected for a different, measured
#                                 reason: under QEMU that session is INPUT-DEAD
#                                 (injected motion and a root right-click change
#                                 zero framebuffer pixels) and the guest never
#                                 writes the THC hardware-cursor registers
#                                 (cursx/cursy stay at the 0xf000 reset value).
#                                 See docs/guests/sunos414.md "Why not TCX".
#   -m 64                         256 MB -> Trap 0x29 (Data Access Error) at boot.
#   scsi-id=3 disk / scsi-id=6 CD MUNIX/GENERIC hard-wire sd0=target 3, sr0=target 6.
#   physical_block_size=512 (CD)  SunOS's sr driver reads 512-byte blocks;
#                                 2048 -> "esp0: data transfer overrun".
#
# POINTER: there is no absolute input device and no hardware cursor on this
# platform, so the pointer is ABSOLUTE BY MEASUREMENT through the guest's own X
# server: xnews runs with -noauth and listens on TCP :6000, and the daemon
# (SH_INPUT_BACKEND=x11warp) drives it with XWarpPointer and reads it back with
# XQueryPointer over the loopback-only forward published below. Buttons and keys
# still ride the QEMU D-Bus PS/2 path -- this X server has no XTEST extension --
# so the sink CONFIRMS each warp with XQueryPointer before an edge is allowed
# through, which is what keeps a two-channel click from becoming a drag.
#
# The X channel exists only while the guest's X server does. If it is down (the
# console, a login prompt, X restarted) the sink reports BackendDown and the
# move is DROPPED -- there is no fallback: apply_move_abs returns as soon as a
# router exists, so this station never reaches the D-Bus relative path. Loud,
# but the pointer stops until X is back.
#
# BOOT: OpenBIOS will NOT auto-boot the target-3 SCSI disk (its `disk` alias is
# not sd@3, and SunOS must see the disk as sd0 = target 3), so there is no cold
# auto-boot. The golden loadvm IS the boot path: with a `golden` snapshot the
# launcher restores the booted system instantly (-loadvm golden -S, frozen
# until the first visitor); without one the guest sits at the OpenBIOS "0 >"
# prompt for a human/baker to drive `boot /iommu/sbus/espdma/esp/sd@3,0:a`.
# The CD stays attached with the same ISO either way, so the device set is
# loadvm-exact.
set -e
D=/data/vms/streamhost/stations/sunos414
A=/data/vms/streamhost/assets/sunos414
QEMU=/opt/qemu-sparc/bin/qemu-system-sparc
DISK=$D/sunos414-golden.qcow2
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid" "$D/serial.sock"
[ -f "$DISK" ] || qemu-img create -f qcow2 "$DISK" 4G >/dev/null
# Boot shape: a golden loadvm restores the booted SunOS instantly (the exhibit,
# frozen -S until the first visitor). Without a golden the guest lands at the
# OpenBIOS "0 >" prompt — OpenBIOS will not auto-boot the target-3 disk that
# SunOS needs to see as sd0, so the golden IS the boot path (bake it by driving
# `boot /iommu/sbus/espdma/esp/sd@3,0:a` once, then savevm golden). No -boot.
LOADVM=""
if qemu-img snapshot -l "$DISK" 2>/dev/null | grep -qw golden; then
  LOADVM="-loadvm golden -S"
fi
# Telnet exec forward (labctl exec sunos414 -> sunexec.py). SLIRP forwards are
# host-side, NOT in the loadvm snapshot, so re-add on every start (alpine does
# the same for its ssh forward). Guest is 10.0.2.15 (static in the golden);
# in.telnetd runs from inetd, root has no password.
EXEC_PORT=5947
# X pointer forward (SH_INPUT_BACKEND=x11warp -> SH_X11WARP_DISPLAY=127.0.0.1:47).
# Loopback-bound on the host; the guest's only interfaces are SLIRP le0
# (10.0.2.15) and lo0, so *:6000 inside the guest is reachable from nowhere else
# -- there is no retronet tap on this station.
X_PORT=6047
# streamhost display fast-poll: dbus poll every SH_DBUS_UPDATE_MS ms (fork
# patch; its run-state idle gate keeps a paused TCG station at ~0 cost).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into flags
nohup "$QEMU" -L /opt/qemu-sparc/share/qemu \
  -name streamhost-sunos414 \
  -M SS-5 -accel tcg -m 64 \
  -vga cg3 \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -drive if=none,id=hd0,file=$DISK,format=qcow2,cache=writeback,aio=threads \
  -device scsi-hd,scsi-id=3,drive=hd0 \
  -drive if=none,id=cd0,media=cdrom,file=$A/sunos414.iso,format=raw,readonly=on \
  -device scsi-cd,scsi-id=6,drive=cd0,physical_block_size=512 \
  -net nic,model=lance -net user \
  -serial unix:$D/serial.sock,server=on,wait=off \
  $LOADVM \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
# re-establish the host->guest telnet forward for labctl exec (best-effort;
# harmless if the guest is still at OpenBIOS with no telnetd yet).
[ -S "$D/qmp.sock" ] && python3 /root/qmp_hmp.py "$D/qmp.sock" \
  "hostfwd_add tcp:127.0.0.1:${EXEC_PORT}-10.0.2.15:23" >/dev/null 2>&1 || true
[ -S "$D/qmp.sock" ] && python3 /root/qmp_hmp.py "$D/qmp.sock" \
  "hostfwd_add tcp:127.0.0.1:${X_PORT}-10.0.2.15:6000" >/dev/null 2>&1 || true
# X-pointer bootstrap. xnews keeps access control ON and its list resolves NAMES,
# so the SLIRP peer 10.0.2.2 is refused with "Internal error during connection
# authorization check" (a reverse-lookup failure) until /etc/hosts names it. Both
# steps are idempotent and deliberately NOT `xhost +`: the grant stays scoped to
# the one peer that can reach the guest. (`grep -q` is a GNUism SunOS 4.1.4's
# grep rejects outright -- redirect instead.)
#
# It cannot run here: the launcher starts the guest FROZEN (-S) and there is no
# telnetd to talk to until a visitor resumes it. So a detached waiter applies it
# on the first resume, and logs every attempt -- if this fails the pointer must
# fail loudly, not silently degrade, and the daemon's own sink reports
# BackendDown independently. Bake both into the golden at the next recapture and
# this becomes a no-op that still self-heals.
# X-pointer CHECK, not configuration. The golden carries the X access state --
# `10.0.2.2 slirphost` in the guest's /etc/hosts and `xhost +10.0.2.2` in the
# running X server -- so a restore already has it and there is no per-restore
# step for the pointer to depend on. This only NOTICES if it is absent and says
# so loudly.
#
# It verifies FROM THE HOST, with a bare X11 connection-setup handshake over the
# forward above: 12 bytes out, and the first byte of the reply is success or
# refusal. That deliberately avoids logging into the guest, because every telnet
# login writes a "ROOT LOGIN" line into the cmdtool CONSOLE the visitor is
# looking at -- a check must not dirty the exhibit it checks.
#
# The repair path exists only for the window where a deployed launcher meets a
# golden recaptured before this state was baked in. It shouts, it does not
# whisper: bake it in with `checkpoint-guard recapture sunos414` and this line
# never runs again. The daemon's sink reports BackendDown independently, so an
# absent channel is loud at both ends.
#
# The two guest commands are one level of quoting deep, for the guest's csh: no
# nested `sh -c` (`2>/dev/null` inside one is an "Ambiguous output redirect" to
# csh) and no `grep -q` (a GNUism SunOS 4.1.4's grep rejects outright).
cat >"$D/x11warp-check.sh" <<'CHECK'
#!/bin/sh
# Verify the golden's X access state. Configure ONLY as a loud fallback.
X_PORT="$1"
EXEC_PORT="$2"
MARKER="$3"
probe() {
  python3 -c '
import socket, struct, sys
try:
    s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), 3)
    s.sendall(struct.pack(">ccHHHHH", b"B", b"\0", 11, 0, 0, 0, 0))
    head = s.recv(8)
    sys.exit(0 if head[:1] == b"\1" else 1)
except Exception:
    sys.exit(2)
' "$X_PORT"
}
n=0
while [ "$n" -lt 600 ]; do
  probe
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$MARKER"
    echo "$(date -u +%FT%TZ) x11warp ok: the golden carries the X access state"
    exit 0
  fi
  if [ "$rc" -eq 1 ]; then
    echo "$(date -u +%FT%TZ) x11warp STALE GOLDEN: the X server refused the SLIRP peer."
    echo "  The access state is NOT in the checkpoint. Repairing at runtime, which is"
    echo "  a workaround, not the design. Fix it properly:"
    echo "    ssh lab 'checkpoint-guard recapture sunos414'"
    python3 /root/sunexec.py 127.0.0.1 "$EXEC_PORT" \
      "grep slirphost /etc/hosts > /dev/null || echo 10.0.2.2 slirphost >> /etc/hosts" || true
    python3 /root/sunexec.py 127.0.0.1 "$EXEC_PORT" \
      "env DISPLAY=:0 /usr/openwin/bin/xhost +10.0.2.2" || true
    if probe; then
      # The marker is what makes this QUERYABLE: the daemon reads it and reports
      # golden-state=REPAIRED-AT-RUNTIME in STAT. A station repaired on every
      # restore works perfectly and therefore hides forever behind a log line.
      : >"$MARKER"
      echo "$(date -u +%FT%TZ) x11warp repaired at runtime -- RECAPTURE THE CHECKPOINT"
      exit 0
    fi
    echo "$(date -u +%FT%TZ) x11warp FAILED: repair did not take; the pointer will NOT move at all"
    exit 1
  fi
  n=$((n + 1))
  sleep 1
done
echo "$(date -u +%FT%TZ) x11warp TIMED OUT: the guest X server never answered on ${X_PORT}"
exit 1
CHECK
chmod +x "$D/x11warp-check.sh"
setsid nohup "$D/x11warp-check.sh" "$X_PORT" "$EXEC_PORT" "$D/x11warp-repaired" \
  >>"$D/x11warp-bootstrap.log" 2>&1 &
echo "station sunos414 qemu pid=$(cat "$D/qemu.pid" 2>/dev/null) qmp=$D/qmp.sock udp=54147 exec=127.0.0.1:${EXEC_PORT} x11=127.0.0.1:${X_PORT} loadvm='${LOADVM:-<none: OpenBIOS prompt>}'"
