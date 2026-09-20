#!/bin/bash
# Launch station 'linux012' (VMID 205) — Linux 0.12 (January 1992), QEMU text console.
# Kill only by pidfile.
#
# GOLDEN TEST FIXTURE (2026-09-20): runs WITHOUT -snapshot (writes persist to the
# qcow2) and boots into the 'golden' live snapshot when it exists.
# resetMode=loadvm: the reset harness issues QMP `loadvm golden` to revert the
# guest to the fixture (a root shell at the `[/usr/root]#` prompt with the boot
# banner still on screen). Without the snapshot the launcher cold-boots the
# original 1992 kernel floppy, which stops at
# "Press <RETURN> to see SVGA-modes available or any other key to continue."
# and WAITS for a keypress — that is the 1992 boot chain, not a fault, and it is
# what scripts/coldboot/linux012-bootrec-arm.sh is calibrated against.
#
# DEVICE SET IS FROZEN WITH THE GOLDEN (AGENTS.md rule 6). Every line below was
# measured during the bring-up race; docs/lab/LINUX012-WAVE.md is the evidence.
#
#   - BOOT IS FROM THE FLOPPY, ROOT IS FROM IDE. The 1992 two-floppy "insert
#     root floppy" dance does not complete under QEMU 11: the kernel prompts,
#     takes the keypress, issues its first read through kernel/blk_drv/floppy.c
#     and never returns — IRQ6 fires ~43 times while 0.12's driver retries in
#     silence, and that driver has NO I/O timeout, so it hangs rather than
#     erroring. Measured identically on both drives, under TCG and KVM, on the
#     default machine and -M isapc, with and without fdtypeA/B forced.
#     The boot sector's ROOT_DEV word (offset 508) is therefore set to 0x0301
#     (/dev/hd1) by the builder, which routes the root filesystem through hd.c
#     instead. That is step 4-7 of Linus's own RELNOTES-0.12 install procedure.
#
#   - TWO IDE DISKS, ALWAYS. hd.c's hd_out() calls controller_ready() BEFORE it
#     writes the drive-select register, so it polls whichever device the BIOS
#     left selected. With a master only, the absent slave's status port reads
#     0x00 and 0.12 dies on `panic("HD controller not ready")`. hdb.qcow2 is
#     blank apart from an MBR signature (hd.c panics "Bad partition table"
#     without one) and exists ONLY to answer that poll. Do not remove it.
#
#   - EXPLICIT CHS 64/16/32 on both disks: 0.12's hd.c does its own CHS division
#     from the BIOS drive table, so the geometry must be pinned rather than left
#     to QEMU's size-based guess, which a future qemu-img could change.
#
#   - -m 16 -smp 1: 0.12 is uniprocessor and caps at 16 MB. Partition 2 of hda
#     is a real swap area (SWAP_DEV 0x0302 was already in the 1992 boot sector),
#     so the kernel prints "Swap device ok" and 0.12's headline feature — it was
#     the first Linux with demand paging to disk — is genuinely live.
#
#   - -vga std, no NIC, no pointer device. Linux 0.12 predates every Linux
#     networking stack (0.96b, mid-1992) and has no mouse driver at all, so
#     retronet and a pointer surface are not "not done yet", they do not exist.
#
#   - pcspk via the dbus audiodev: kernel/chr_drv/console.c's sysbeep is the
#     only audio source this guest has.
set -e
[ -f "/data/vms/streamhost/stations/linux012/qemu.pid" ] && kill "$(cat "/data/vms/streamhost/stations/linux012/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "/data/vms/streamhost/stations/linux012/qmp.sock" "/data/vms/streamhost/stations/linux012/qemu.pid"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms (default 4).
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
LOADVM=""
qemu-img snapshot -l /data/vms/streamhost/stations/linux012/hda.qcow2 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-i386 \
  -name streamhost-linux012 \
  -enable-kvm -m 16 -smp 1 \
  -machine pc-i440fx-11.0,acpi=off,pcspk-audiodev=snd0 \
  -rtc base=localtime \
  -boot a \
  $LOADVM \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  \
  -drive file=/data/vms/streamhost/stations/linux012/boot.qcow2,format=qcow2,if=floppy,index=0 \
  -drive file=/data/vms/streamhost/stations/linux012/hda.qcow2,format=qcow2,if=none,id=hd0 \
  -device ide-hd,drive=hd0,bus=ide.0,unit=0,cyls=64,heads=16,secs=32 \
  -drive file=/data/vms/streamhost/stations/linux012/hdb.qcow2,format=qcow2,if=none,id=hd1 \
  -device ide-hd,drive=hd1,bus=ide.0,unit=1,cyls=64,heads=16,secs=32 \
  -qmp unix:/data/vms/streamhost/stations/linux012/qmp.sock,server=on,wait=off \
  -pidfile /data/vms/streamhost/stations/linux012/qemu.pid \
  >"/data/vms/streamhost/stations/linux012/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "/data/vms/streamhost/stations/linux012/qmp.sock" ] && [ -f "/data/vms/streamhost/stations/linux012/qemu.pid" ] && break
  sleep 0.5
done
echo "tile linux012 qemu pid=$(cat /data/vms/streamhost/stations/linux012/qemu.pid 2>/dev/null) qmp=/data/vms/streamhost/stations/linux012/qmp.sock udp=54205"
