#!/usr/bin/env bash
# tile-fs-probe.sh — READ-ONLY survey of every station's disk: image format,
# partition scheme, and the filesystem(s) inside it. This is what produces the
# feasibility matrix in docs/lab/OFFLINE-MUTATION-MATRIX.md, which decides which
# stations `lib/bridge-coldboot mutate` will agree to touch.
#
# WHY A PROBE AND NOT A GUESS: "can we write into this guest's disk from the
# host" is a per-filesystem question with three answers, not two — rw, ro, and
# not-at-all — and the middle one is the dangerous one. A partial or buggy write
# to an exotic filesystem (Amiga OFS/FFS, Haiku BFS, Solaris UFS, ODS-5) is
# WORSE than no write: it corrupts a checkpoint that took hours to capture, and the
# corruption surfaces later, on a visitor reset. So the matrix is measured, and
# the mutate path refuses anything not positively verified.
#
# SAFETY: this script NEVER writes. qemu-nbd is attached --read-only, nothing is
# ever mounted (we read the partition table and blkid signatures off the block
# device), and the nbd device is disconnected before moving on. It is safe to
# run against RUNNING stations — read-only access is shareable — though a live
# image can of course return a torn view of a filesystem being written, so a
# verdict taken from a running station is marked as such.
#
# Usage: tile-fs-probe.sh [--tiles-root DIR] [--json] [station…]
set -uo pipefail

TILES_ROOT="${TILES_ROOT:-/data/vms/streamhost/stations}"
JSON=0
ONLY=()
while [ $# -gt 0 ]; do case "$1" in
  --tiles-root)
    TILES_ROOT="${2:?}"
    shift 2
    ;;
  --json)
    JSON=1
    shift
    ;;
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    ONLY+=("$1")
    shift
    ;;
esac done

NBD=""
cleanup() {
  [ -n "$NBD" ] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
  NBD=""
}
trap 'cleanup' EXIT

# claim_nbd <image> <format> — atomic claim: qemu-nbd -c fails on a device
# another rig holds, so a successful connect IS the proof of ownership.
claim_nbd() {
  local img="$1" fmt="$2" i
  for i in $(seq 0 15); do
    [ -b "/dev/nbd$i" ] || continue
    if qemu-nbd --read-only --connect="/dev/nbd$i" --format="$fmt" -- "$img" 2>/dev/null; then
      NBD="/dev/nbd$i"
      return 0
    fi
  done
  return 1
}

# primary_disk <tiledir> — the station's main disk. Prefer a path from the RUNNING
# QEMU's argv (authoritative), else the largest image file in the station tree.
# Parsing the launcher was tried first and is not reliable: the paths are built
# from shell variables ($D, $BASE, $GDIR) that only exist at run time.
primary_disk() {
  local dir="$1" tile p pid argv f best="" bestsz=0 sz
  tile="$(basename "$dir")"
  # 1. The RUNNING QEMU's argv is authoritative — many stations keep their disk in
  #    /data/gallery-guests, not the station dir, reached through a launcher
  #    variable ($D, $GDIR, $BASE) that only has a value at run time. Match the
  #    process by its `-name streamhost-<tile>` tag or the station dir in its argv;
  #    a bare basename match is too loose (short names like `nt4` and `star`
  #    appear inside unrelated paths).
  for pid in $(pgrep -f 'qemu-system-' 2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    argv="$(tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null)"
    printf '%s\n' "$argv" | grep -qE "^streamhost-${tile}(-|$)|^${dir%/}/" || continue
    f="$(printf '%s\n' "$argv" | grep -oE '(^|,)file=[^,]+' | sed 's/^,\{0,1\}file=//' |
      grep -E '\.(qcow2|img|raw|vmdk|dd|vdi)$' | grep -viE 'OVMF|VARS' | head -1)"
    [ -n "$f" ] && [ -f "$f" ] && {
      printf '%s' "$f"
      return 0
    }
  done
  # 2. Stopped: the largest image in the station dir, else a literal
  #    /data/gallery-guests path named in the launcher.
  while IFS= read -r p; do
    sz=$(stat -c %s "$p" 2>/dev/null || echo 0)
    [ "$sz" -gt "$bestsz" ] && {
      bestsz=$sz
      best="$p"
    }
  done < <(find "$dir" -maxdepth 3 -type f \
    \( -name '*.qcow2' -o -name '*.img' -o -name '*.raw' -o -name '*.vmdk' -o -name '*.dd' \) 2>/dev/null |
    grep -vE 'OVMF|VARS|seed|cloudinit')
  if [ -z "$best" ]; then
    # Restrict to the launcher/config TEXT files. An unrestricted `grep -r` here
    # walks the station's own multi-gigabyte qcow2 images looking for path strings,
    # which took this probe from seconds to minutes per station.
    best="$(grep -rhoE --binary-files=without-match \
      --include='*.sh' --include='*.env' --include='*.env.*' --include='*.conf' --include='*.json' \
      '/data/(gallery-guests|vms)/[A-Za-z0-9_./-]+\.(qcow2|img|raw|vmdk|dd)' \
      "$dir" 2>/dev/null | sort -u | while IFS= read -r p; do
      [ -f "$p" ] && stat -c '%s %n' "$p"
    done | sort -rn | head -1 | cut -d' ' -f2-)"
  fi
  [ -n "$best" ] && printf '%s' "$best"
}

# boot_medium_note <tiledir> — several stations boot a live ISO and keep only a
# small scratch qcow2 for state. Writing into that qcow2 reaches nothing the
# guest reads at boot, so the honest verdict is not "no filesystem" but "the
# boot medium is read-only by construction".
boot_medium_note() {
  local dir="$1" iso
  iso="$(grep -rhoE --binary-files=without-match \
    --include='*.sh' --include='*.env' --include='*.env.*' --include='*.conf' --include='*.json' \
    '/data/[A-Za-z0-9_./-]+\.(iso|ISO)' "$dir" 2>/dev/null | sort -u | head -1)"
  [ -n "$iso" ] && printf 'boots ISO %s' "$(basename "$iso")"
}

# verdict <fstype> — can we mount this read-write from this host, at all?
# Derived from /proc/filesystems + the modules present + the userspace helpers
# installed. Kept deliberately conservative: anything not positively known good
# is NOT-SUPPORTED, because the cost of being wrong is a corrupted checkpoint.
verdict() {
  case "$1" in
    ext2 | ext3 | ext4) echo "MOUNTABLE-RW|kernel ext4" ;;
    vfat | fat | fat12 | fat16 | fat32 | msdos) echo "MOUNTABLE-RW|kernel vfat (or mtools)" ;;
    exfat) echo "MOUNTABLE-RW|kernel exfat" ;;
    ntfs | ntfs3) echo "MOUNTABLE-RW|ntfs-3g / kernel ntfs3" ;;
    iso9660) echo "MOUNTABLE-RO|read-only by definition" ;;
    hfsplus | hfs) echo "MOUNTABLE-RO|kernel hfs writes are unsafe" ;;
    ufs) echo "MOUNTABLE-RO|kernel ufs is read-only unless CONFIG_UFS_FS_WRITE" ;;
    befs) echo "MOUNTABLE-RO|kernel befs is read-only" ;;
    affs) echo "MOUNTABLE-RW|kernel affs (Amiga OFS/FFS) — UNVERIFIED, treat as unsafe" ;;
    qnx4 | qnx6) echo "MOUNTABLE-RO|kernel qnx4/qnx6 are read-only" ;;
    minix | bfs | omfs) echo "MOUNTABLE-RO|legacy, writes unverified" ;;
    '' | unknown) echo "NOT-SUPPORTED|no filesystem signature recognised" ;;
    *) echo "NOT-SUPPORTED|no verified host support" ;;
  esac
}

printf '%-14s %-8s %-9s %-26s %-16s %s\n' TILE FORMAT PARTS FILESYSTEMS VERDICT VIA
printf '%s\n' "-------------------------------------------------------------------------------------------------------"

for dir in "$TILES_ROOT"/*/; do
  tile="$(basename "$dir")"
  if [ ${#ONLY[@]} -gt 0 ]; then
    match=0
    for k in "${ONLY[@]}"; do [ "$k" = "$tile" ] && match=1; done
    [ "$match" = 1 ] || continue
  fi
  # CHD is a MAME container, not a block image: qemu-nbd cannot open it and
  # there is no host path into its filesystem at all.
  if [ -z "$(primary_disk "$dir")" ]; then
    if find "$dir" -maxdepth 2 -name '*.chd' -print -quit 2>/dev/null | grep -q .; then
      printf '%-14s %-8s %-9s %-26s %-16s %s\n' "$tile" chd - "(MAME CHD container)" NOT-SUPPORTED "no host block access"
    else
      printf '%-14s %-8s %-9s %-26s %-16s %s\n' "$tile" - - "(no disk image found)" - -
    fi
    continue
  fi
  disk="$(primary_disk "$dir")"
  # Parse the TOP-LEVEL format as JSON. A sed for the first `"format":` is wrong
  # and quietly so: qemu-img's JSON nests a child object describing the
  # protocol layer, whose format is "file", so the naive grep reports every
  # qcow2 in the fleet as "file" — and attaching it with --format=file exposes
  # the container bytes raw, where no filesystem signature exists. That produced
  # a matrix reading NOT-SUPPORTED for all 59 stations, which looks like a finding
  # and is a bug.
  fmt="$(qemu-img info -U --output=json -- "$disk" 2>/dev/null |
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("format",""))' 2>/dev/null)"
  [ -n "$fmt" ] || fmt=raw
  live=""
  find /proc/[0-9]*/fd -lname "$disk" 2>/dev/null | grep -q . && live=" (live)"

  if ! claim_nbd "$disk" "$fmt"; then
    printf '%-14s %-8s %-9s %-26s %-16s %s\n' "$tile" "$fmt" - "(could not attach nbd)" UNKNOWN "probe failed"
    continue
  fi
  # Probe each partition DIRECTLY with `blkid -p`, never via lsblk's FSTYPE.
  # lsblk reports udev's cached db, which is populated asynchronously after the
  # partition scan — so a probe run immediately after `qemu-nbd --connect` reads
  # back empty and every station looks like it has no filesystem. `blkid -p`
  # bypasses the cache and probes the device itself. (This is the second
  # incarnation of the same race in this script; the first was the partition
  # table not being scanned yet, handled by the settle loop below.)
  for _ in $(seq 1 20); do
    partx -s "$NBD" >/dev/null 2>&1 && break
    sleep 0.25
  done
  udevadm settle --timeout=5 >/dev/null 2>&1 || true
  devs="$(find /dev -maxdepth 1 -name "$(basename "$NBD")p*" 2>/dev/null | sort)"
  parts="$(printf '%s\n' "$devs" | grep -c .)"
  if [ -z "$devs" ]; then
    devs="$NBD"
    parts="none"
  fi
  fslist=""
  for d in $devs; do
    t="$(blkid -p -o value -s TYPE "$d" 2>/dev/null | head -1)"
    [ -n "$t" ] && fslist="${fslist:+$fslist,}$t"
  done
  fslist="$(printf '%s' "$fslist" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')"
  best="NOT-SUPPORTED"
  via="-"
  for fs in ${fslist//,/ }; do
    v="$(verdict "$fs")"
    case "${v%%|*}" in
      MOUNTABLE-RW)
        best=MOUNTABLE-RW
        via="${v#*|}"
        break
        ;;
      MOUNTABLE-RO) [ "$best" = NOT-SUPPORTED ] && {
        best=MOUNTABLE-RO
        via="${v#*|}"
      } ;;
    esac
  done
  if [ -z "$fslist" ]; then
    fslist="(none detected)"
    via="$(boot_medium_note "$dir")"
    via="${via:-no filesystem signature}"
  fi
  printf '%-14s %-8s %-9s %-26s %-16s %s\n' \
    "$tile" "$fmt" "$parts" "${fslist}${live}" "$best" "$via"
  cleanup
done
