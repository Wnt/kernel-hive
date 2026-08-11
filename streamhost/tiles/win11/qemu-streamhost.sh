#!/bin/bash
# Launch tile 'win11' (VMID 123) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm, see GOLDEN.md):
#   * Boots the persistent tile-LOCAL golden qcow2 (NO -snapshot) so QMP
#     savevm/loadvm can create/restore the live "golden" reset point IN it. The
#     pristine install stays untouched at /data/gallery-guests/Win11/win11.qcow2.
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden).
#
# WHY THIS DEVICE SET (it is NOT the install-time one — see docs/guests/win11.md):
#   * UEFI, not SeaBIOS: the disk is GPT with an EFI system partition, so the
#     OVMF pflash pair is load-bearing. unit 1 (the variable store) carries the
#     Windows Boot Manager entry written during install.
#   * The variable store is a WRITABLE QCOW2, and the system disk is declared
#     BEFORE it. Both halves are load-bearing:
#       - read-only pflash does not work. OVMF writes its varstore during init,
#         and a read-only one hangs the firmware before it ever initializes the
#         display ("Guest has not initialized the display (yet)" forever).
#       - raw pflash does not work either: `savevm` refuses a writable device
#         that cannot hold snapshots.
#       - qcow2 pflash works, but savevm picks its vmstate device by walking the
#         BlockBackends in creation order, i.e. command-line -drive order. With
#         the pflash first, the RAM image lands inside the 528 KiB variable store
#         instead of the system disk. Declaring the system disk first puts the
#         vmstate where every other tile in the fleet keeps it. Verify after any
#         reorder: `qemu-img snapshot -l` must show the VM STATE SIZE on
#         win11-golden.qcow2, not on OVMF_VARS.qcow2.
#     The NVRAM is snapshotted alongside the disk, so a reset restores the boot
#     entry and the Secure Boot state together with the desktop.
#   * NO vTPM. Windows 11 wants one to INSTALL, not to run, and BitLocker is off
#     (verified FullyDecrypted before it was dropped), so nothing measures boot.
#     Dropping it means no swtpm process to supervise per tile start.
#   * restrict=on isolates the guest: DHCP still answers so the adapter is up
#     with 10.0.2.15/24, but there is no default route and no DNS. An exhibit
#     nobody can dismiss dialogs on must not be able to phone home.
#   * ich9-intel-hda, not the fleet's AC97: Windows 11 has no in-box AC97 driver.
#   * The guest agent channel is kept — it is this tile's real exec channel.
set -e
D=/data/vms/streamhost/tiles/win11
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qga.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/win11-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-win11 \
  -enable-kvm -m 4096 -smp cores=4,sockets=1 \
  -machine pc-q35-11.0,smm=on -cpu host,hv_ipi,hv_relaxed,hv_reset,hv_runtime,hv_spinlocks=0x1fff,hv_stimer,hv_synic,hv_time,hv_vapic,hv_vpindex \
  -rtc base=localtime,driftfix=slew \
  -global driver=cfi.pflash01,property=secure,value=on -global ICH9-LPC.disable_s3=1 \
  -drive file=$D/win11-golden.qcow2,if=none,id=drive-scsi0,format=qcow2,cache=writeback,aio=threads,discard=unmap,detect-zeroes=unmap \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/pve-edk2-firmware/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,unit=1,format=qcow2,file=$D/OVMF_VARS.qcow2 \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device ich9-intel-hda,id=hda -device hda-duplex,bus=hda.0,audiodev=snd0 \
  -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
  -object iothread,id=iothread0 \
  -device virtio-scsi-pci,id=scsihw0,iothread=iothread0 \
  -device scsi-hd,bus=scsihw0.0,drive=drive-scsi0,id=scsi0,rotation_rate=1,bootindex=200 \
  -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0,id=net0 \
  -device virtio-serial-pci,id=vioserial0 \
  -chardev socket,path=$D/qga.sock,server=on,wait=off,id=qga0 \
  -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
  $LOADVM \
  -boot menu=off,strict=on \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile win11 qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54123 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
