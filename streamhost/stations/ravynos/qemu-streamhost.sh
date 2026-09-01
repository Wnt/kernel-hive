#!/bin/bash
# Launch tile 'ravynos' (VMID 173) QEMU with the streamhost display wiring.
# Kill only by pidfile.
#
# GOLDEN FIXTURE MODE (resetMode=loadvm):
#   * If a 'golden' snapshot exists, boots STRAIGHT INTO it (-loadvm golden -S).
#   * Otherwise cold-boots the live ISO, which lands on the LoginWindow and
#     WAITS THERE for a human. See scripts/coldboot/ravynos-zero-input-prep.md:
#     this station's cold boot is deliberately NOT zero-input, and the golden is
#     what makes it an exhibit.
#
# WHY THIS IS A LIVE-ISO STATION AND NOT AN INSTALLED ONE
#   ravynOS 0.6.1's own disk installer (/bin/install.sh) completes — GPT + EFI +
#   swap + a ZFS pool, ~1.38 GB copied, services enabled, bootloader written —
#   but the resulting system never reaches a desktop. It mounts
#   zfs:ravynOS/ROOT/default, prints 'pid 1 comm launchd: nosys 689' and stalls
#   there for good (two captures 150 s apart were byte-identical, and rc never
#   emits a line). virtio-rng does not change it, so it is not the entropy stall
#   it first resembles. That is pre-alpha breakage in ravynOS's disk-install
#   path, recorded in docs/guests/ravynos.md. Booting the live ISO is both the
#   working path and the more faithful one: it is upstream's own distribution
#   form, and 0.6.1 is the LAST FreeBSD-based ravynOS — the project deleted every
#   release of this line from GitHub and SourceForge four days after it shipped.
#
# WHY THIS DEVICE SET (every line is load-bearing — docs/guests/ravynos.md)
#   * UEFI, not SeaBIOS: ravynOS has NO legacy/BIOS boot path at all. A BIOS boot
#     dies at the mountroot> prompt, so the OVMF pflash pair is mandatory.
#   * q35, not i440fx: on i440fx + OVMF the guest paints a black screen with a
#     white rectangle and never reaches the desktop (upstream issue #433).
#   * The variable store is a WRITABLE QCOW2. Read-only pflash hangs OVMF before
#     it initialises the display, and raw pflash makes `savevm` refuse: it will
#     not accept a writable device that cannot hold snapshots.
#   * THE CARRIER DISK IS DECLARED FIRST, before the pflash pair. A live ISO is
#     read-only and cannot hold a vmstate, so this station carries an otherwise
#     unused qcow2 purely to hold the golden's RAM image. `savevm` chooses its
#     vmstate device by walking BlockBackends in command-line order, so with the
#     pflash first the RAM image lands inside the 528 KiB variable store instead.
#     Verify after ANY reorder: `qemu-img snapshot -l` must show the VM_SIZE on
#     ravynos-golden.qcow2 (~579 MiB) and 0 B on OVMF_VARS.qcow2.
#   * -vga std and nothing cleverer: ravynOS ships NO GPU driver of any kind.
#     Since 0.5.1 WindowServer renders directly into the framebuffer that OVMF's
#     EFI GOP hands it. The canvas is fixed at boot by the firmware (1280x800
#     here); the guest cannot change it and there is no OpenGL or DRM/KMS.
#   * USB input, not PS/2 and not virtio: upstream's 0.6.1 notes say PS/2 or
#     virtio input "may cause input lag. Use USB devices." The QEMU tablet is
#     upstream's own preferred pointer for KVM/QEMU guests and gives this station
#     its absolute pointer (dmesg: hms0 ... 5 buttons and [XYW] coordinates).
#   * intel-hda is real here: the guest attaches it as pcm0 (play/rec). The 0.6.1
#     desktop itself emits no sounds, but the hardware and driver are present.
#   * virtio-rng because upstream's own VM script ships one.
#   * restrict=on isolates the guest. An exhibit nobody can supervise must not be
#     able to phone home, and ravynOS needs no network to reach its desktop.
set -e
D=/data/vms/streamhost/stations/ravynos
ISO=/data/isos/ravynOS_0.6.1_amd64.iso
[ -f "$D/qemu.pid" ] && kill "$(cat "$D/qemu.pid")" 2>/dev/null || true
sleep 0.3
rm -f "$D/qmp.sock" "$D/qemu.pid"
LOADVM=""
qemu-img snapshot -l "$D/ravynos-golden.qcow2" 2>/dev/null | grep -qw golden && LOADVM="-loadvm golden -S"
# streamhost display fast-poll (pve-qemu 0047): dbus poll every SH_DBUS_UPDATE_MS ms.
export SH_DBUS_UPDATE_MS="${SH_DBUS_UPDATE_MS:-4}"
# shellcheck disable=SC2086 # $LOADVM must word-split into -loadvm golden (or vanish when unset/cold-boot)
nohup qemu-system-x86_64 \
  -name streamhost-ravynos \
  -enable-kvm -m 4096 -smp cores=4,sockets=1 \
  -machine pc-q35-11.0 -cpu host \
  -drive file=$D/ravynos-golden.qcow2,if=none,id=hd0,format=qcow2,cache=writeback \
  -drive if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/pve-edk2-firmware/OVMF_CODE_4M.fd \
  -drive if=pflash,unit=1,format=qcow2,file=$D/OVMF_VARS.qcow2 \
  -device ide-hd,drive=hd0,bus=ide.0,bootindex=2 \
  -drive file=$ISO,media=cdrom,if=none,id=cd0,readonly=on \
  -device ide-cd,drive=cd0,bus=ide.1,bootindex=1 \
  -vga std \
  -display dbus,p2p=on,audiodev=snd0 \
  -audiodev dbus,id=snd0,out.frequency=48000,out.channels=2,out.format=s16 \
  -device intel-hda,id=hda -device hda-duplex,bus=hda.0,audiodev=snd0 \
  -device qemu-xhci,id=xhci \
  -device usb-kbd,bus=xhci.0 \
  -device usb-tablet,bus=xhci.0 \
  -object rng-random,id=rng0,filename=/dev/urandom \
  -device virtio-rng-pci,rng=rng0 \
  -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0,id=net0 \
  $LOADVM \
  -boot menu=off,strict=on \
  -qmp unix:$D/qmp.sock,server=on,wait=off \
  -pidfile $D/qemu.pid \
  >"$D/qemu.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$D/qmp.sock" ] && [ -f "$D/qemu.pid" ] && break
  sleep 0.5
done
echo "tile ravynos qemu pid=$(cat $D/qemu.pid 2>/dev/null) qmp=$D/qmp.sock udp=54173 loadvm='${LOADVM:-<none: cold boot>}' (golden, no -snapshot)"
