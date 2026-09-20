#!/bin/bash
# Builder for linux012 — Linux 0.12 (Jan 1992), booted from its original kernel
# floppy with the root filesystem on an IDE partition.
#
# Fetches the 2004 oldlinux.org repackaged raw floppy images (the SAME bytes
# named in docs/lab/integration-seeds/linux012.md), verifies their hash, and
# composes the guest media under assets/linux012/.
#
# WHY THE ROOT FILESYSTEM IS ON A HARD DISK (measured 2026-09-20, the whole of
# docs/lab/LINUX012-WAVE.md is the evidence trail):
#   Booting bootimage + rootimage as two floppies is the 1992 "insert root
#   floppy" dance, and it does NOT complete under QEMU 11. The kernel reaches
#   mount_root(), prompts, takes the keypress, issues its first floppy read and
#   never returns: IRQ6 fires ~43 times and Linux 0.12's floppy.c retries in
#   silence. floppy.c has NO I/O timeout, so a controller it cannot drive is an
#   unbreakable hang rather than an error. Reproduced on both drives, on
#   -M isapc and the default machine, under TCG and KVM, with and without
#   fdtypeA/B forced (7 distinct configurations).
#   Putting the root filesystem on an IDE partition sidesteps floppy.c entirely
#   and uses hd.c, which QEMU drives correctly. This is not a workaround grafted
#   onto the exhibit: it is step 4-7 of Linus's own RELNOTES-0.12 install
#   procedure ("use mkfs ... copy over the root filesystem to the harddisk ...
#   change the bootdisk to understand which partition it should use as a root"),
#   i.e. exactly what a 0.12 user did once they had the system running.
#
# TWO IDE DISKS ARE MANDATORY — DO NOT "SIMPLIFY" THIS TO ONE (measured):
#   hd.c's hd_out() calls controller_ready() BEFORE it writes the drive-select
#   register, so it reads the status port of whichever device the BIOS happened
#   to leave selected. With a master only, that read returns 0x00 for the absent
#   slave and 0.12 dies on `panic("HD controller not ready")` (frame
#   race/D-ide-lba2048/fb1.png). Attaching ANY valid slave makes the same boot
#   reach the root shell (frame race/G-ide-slave/fb1.png). The slave is
#   deliberately blank apart from an MBR signature, which hd.c requires or it
#   panics "Bad partition table".
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OS_ID="linux012"
WORK="${WORK:-/data/vms/build-${OS_ID}}"
ASSETS="${ASSETS:-/data/vms/streamhost/assets/${OS_ID}}"
BASE_URL="${BASE_URL:-https://mirror.math.princeton.edu/pub/oldlinux/Linux.old/images}"
BOOT_NAME="${BOOT_NAME:-bootimage-0.12-20040306}"
ROOT_NAME="${ROOT_NAME:-rootimage-0.12-20040306}"
BOOT_SHA256="${BOOT_SHA256:-1df233ade3c71b6622b138622c81128460e84351b80ee7d54fb4fdad71e05425}"
ROOT_SHA256="${ROOT_SHA256:-4e79e37b074f2ed1de5aea212e282b6970c41d1c731903aa01ff1431b8ea0713}"

# Disk geometry, in 512-byte sectors. Both IDE images are 16 MiB.
DISK_SECTORS=32768
ROOT_START=2048 # /dev/hd1 — partition 1, the minix root filesystem
SWAP_START=8192 # /dev/hd2 — partition 2, matches SWAP_DEV already in the boot sector
SWAP_SECTORS=8192

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

mkdir -p "$WORK" "$ASSETS"

for pair in "$BOOT_NAME:$BOOT_SHA256" "$ROOT_NAME:$ROOT_SHA256"; do
  name="${pair%%:*}"
  want_sha="${pair##*:}"
  dest="$WORK/$name"
  if [ ! -f "$dest" ]; then
    log "fetching $name"
    curl -fL --retry 3 -o "$dest" "$BASE_URL/$name" ||
      die "could not fetch $name from $BASE_URL — the seed doc's Linux-0.12/images/ path 404s; images/ at the Linux.old root is correct as of 2026-09-20"
  fi
  got_sha="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$got_sha" = "$want_sha" ] ||
    die "$name sha256 mismatch: got $got_sha want $want_sha"
done

# ---- the kernel floppy -------------------------------------------------------
# Two edits to the 512-byte boot sector, both to fields bootsect.S itself
# defines; the kernel image behind them is byte-for-byte the 1992 original.
#   508: ROOT_DEV 0x0000 -> 0x0301 (/dev/hd1). At 0 bootsect auto-detects the
#        drive it booted from (0x021c = fd0) and mount_root() then prints
#        "Insert root floppy and press ENTER" and hangs on floppy.c forever.
#        With major 3 the prompt never appears and hd.c serves the root.
#   Padding to a full 1.44M floppy is required for the boot chain to get past
#        the SVGA-mode prompt at all (measured; a short raw image leaves QEMU's
#        track wrap in an indeterminate state).
log "composing kernel floppy"
BOOT_IMG="$WORK/boot.img"
cp -f "$WORK/$BOOT_NAME" "$BOOT_IMG"
truncate -s 1474560 "$BOOT_IMG"
printf '\x01\x03' | dd of="$BOOT_IMG" bs=1 seek=508 conv=notrunc status=none

# ---- the root/swap disk and the mandatory slave ------------------------------
log "composing IDE disks"
python3 - "$WORK" "$WORK/$ROOT_NAME" "$DISK_SECTORS" "$ROOT_START" "$SWAP_START" "$SWAP_SECTORS" <<'PY'
import struct, sys

work, rootimg, disk_sectors, root_start, swap_start, swap_sectors = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]),
    int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]))

root = open(rootimg, 'rb').read()
root_sectors = len(root) // 512


def part(bootable, ptype, start, nsect):
    e = bytearray(16)
    e[0] = 0x80 if bootable else 0x00
    e[4] = ptype
    # hd.c reads start_sect/nr_sects only and ignores the CHS triplets.
    e[1:4] = b'\xff\xff\xff'
    e[5:8] = b'\xff\xff\xff'
    struct.pack_into('<II', e, 8, start, nsect)
    return bytes(e)


# hda: partition 1 = minix root filesystem, partition 2 = swap.
hda = bytearray(disk_sectors * 512)
hda[0x1BE:0x1CE] = part(True, 0x81, root_start, root_sectors)   # 0x81 Minix
hda[0x1CE:0x1DE] = part(False, 0x82, swap_start, swap_sectors)  # 0x82 swap
hda[510], hda[511] = 0x55, 0xAA
hda[root_start * 512:root_start * 512 + len(root)] = root

# Swap signature page, in the format mm/swap.c's init_swapping() validates:
# one 4096-byte bitmap page at the head of the partition, bit N set = page N
# free. Bit 0 stays clear (it IS the bitmap), bits 1..swap_size-1 are free, and
# every bit from swap_size up must be clear. swap_size = (blocks in the
# partition) >> 2, and blocks = nr_sects >> 1.
swap_size = (swap_sectors >> 1) >> 2
bm = bytearray(4096)
for i in range(1, swap_size):
    bm[i >> 3] |= 1 << (i & 7)
bm[4086:4096] = b'SWAP-SPACE'
hda[swap_start * 512:swap_start * 512 + 4096] = bm
open(f'{work}/hda.img', 'wb').write(bytes(hda))

# hdb: blank, but with the MBR signature hd.c insists on. Its only job is to
# answer the status port when 0.12 reads it before selecting a drive.
hdb = bytearray(disk_sectors * 512)
hdb[510], hdb[511] = 0x55, 0xAA
open(f'{work}/hdb.img', 'wb').write(bytes(hdb))

print(f'hda: root part1 start={root_start} sectors={root_sectors}, '
      f'swap part2 start={swap_start} sectors={swap_sectors} '
      f'({swap_size - 1} free swap pages)', file=sys.stderr)
PY

# ---- publish as qcow2 --------------------------------------------------------
# qcow2 for every writable device, because the station's reset is `loadvm
# golden` and QEMU refuses to snapshot a raw drive (AGENTS.md rule 6: the
# checkpoint, the binary and the device set are ONE combination).
log "converting to qcow2"
qemu-img convert -f raw -O qcow2 "$BOOT_IMG" "$ASSETS/boot.qcow2"
qemu-img convert -f raw -O qcow2 "$WORK/hda.img" "$ASSETS/hda.qcow2"
qemu-img convert -f raw -O qcow2 "$WORK/hdb.img" "$ASSETS/hdb.qcow2"
sha256sum "$ASSETS/boot.qcow2" "$ASSETS/hda.qcow2" "$ASSETS/hdb.qcow2" |
  tee "$ASSETS/MANIFEST.sha256"
log "done — assets in $ASSETS"
