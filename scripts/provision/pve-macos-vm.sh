#!/usr/bin/env bash
# ============================================================================
# pve-macos-vm.sh — reproducible macOS (Sequoia) install on Proxmox VE,
#                   headless, driven entirely by scripted VNC + screenshots.
#                   No GPU required. Drive-by-pixels.
#
# Target: Supermicro Xeon D-2146NT (Skylake-D, NO GPU), Proxmox VE 9.x, ZFS
#         pool `data`. Proven flow, VMID 925, 2026-07-04.
#         Full root-causes / pitfalls: the macOS guest doc in docs/guests/
# Status: the VMID 925 instance was deleted 2026-07-14. This script remains the
#         optional recreation path and creates a new guest when invoked.
#
# THE PROVEN RECIPE (what makes this work where earlier attempts black-screened):
#   * OpenCore : kholia/OSX-KVM version-agnostic image (NOT osx-proxmox-next —
#                that config caused the black-screen/no-install failures).
#   * macOS    : Sequoia (15). Tahoe (26) does NOT composite on QEMU's
#                unaccelerated vmware-VGA (only the cursor renders). `-s sequoia`
#                maps to Sequoia's own board-id so Apple serves Sequoia, NOT the
#                "latest" recovery (which is now Tahoe).
#   * CPU      : --cpu host (real Skylake-D). *** DO NOT *** append
#                `-cpu Skylake-Server-v4,...` in --args: it overrides --cpu host
#                and triggers a kernel MP-rendezvous spinlock -> black screen.
#                (This was the single bug in the pre-925 recipe.) The applesmc
#                OSK still goes in --args; just no -cpu there.
#   * NIC      : vmxnet3 (e1000-82545em yields no en0 on modern macOS).
#   * Drive    : socat-bridge the PVE VNC unix sock -> 127.0.0.1, set the VNC
#                password via QMP, vncdo for click/type/key, and SCREENSHOT-
#                VERIFY every step (never infer from logs).
#   * Admin    : bypass Setup Assistant with a RunAtLoad LaunchDaemon on the
#                installed volume that dscl-creates an admin and touches
#                /var/db/.AppleSetupDone -> boots straight to a usable account.
#
# GOLDEN RULES (the original 6h agent failed by trusting logs over pixels):
#   * Verify EVERY step with a real framebuffer screenshot before proceeding.
#   * cores = power of 2 (2/4/8); a non-power-of-2 (e.g. 6) hangs the boot.
#   * Recovery boot is SLOW here (software-rendered, ~10-15 min to Utilities).
#
# DISK: pool `data` is only 83.5 GiB. Reinstall downloads ~14 GiB AND lays the
#   OS down while the payload is present => ~24 GiB transient peak on the target.
#   This script ABORTS if the pool is >= 85% or has < 25 GiB free, and runs a
#   watchdog that `qm stop`s the VM at CAP_STOP% (default 88).
#
# HYGIENE on a shared box: pass your OWN VMID and a UNIQUE VNCPORT. This script
#   only ever touches the VMID you give it. It never pkills by name.
#
# USAGE (run ON the Proxmox host as root, or: ssh root@host bash -s -- <args>):
#   VMID=925 VNCPORT=5925 ./pve-macos-vm.sh all      # fetch+build+boot+drive
#   VMID=925 ./pve-macos-vm.sh create                # build only, drive by hand
#   VMID=925 ./pve-macos-vm.sh drive                 # (re)run the GUI automation
#   VMID=925 ./pve-macos-vm.sh reselect              # re-pick OpenCore entry after a reboot
#   VMID=925 ./pve-macos-vm.sh admin                 # inject the local-admin bypass daemon
#   VMID=925 ./pve-macos-vm.sh shot 20               # framebuffer screenshot
#   VMID=925 ./pve-macos-vm.sh destroy               # stop + purge (reclaim disk)
# ============================================================================
set -euo pipefail

# ---- Parameters (all env-overridable) --------------------------------------
VMID="${VMID:-925}"       # USE YOUR ASSIGNED VMID on a shared box
POOL="${POOL:-data}"      # ZFS storage pool for the VM disks
OSVER="${OSVER:-sequoia}" # sequoia(recommended here) | sonoma | ventura | monterey
DISK="${DISK:-48}"        # target system disk (GiB, sparse); install peaks ~24 GiB
RAM="${RAM:-8192}"
CORES="${CORES:-4}" # MUST be a power of 2
BRIDGE="${BRIDGE:-vmbr0}"
VNCPORT="${VNCPORT:-59${VMID: -2}}" # unique per-VM (VMID 925 -> 5925)
VNCPW="${VNCPW:-labpass}"
WD="${WD:-/data/gallery-guests/macos}"
OSXKVM="${OSXKVM:-$WD/OSX-KVM}"
POOL_CAP_ABORT="${POOL_CAP_ABORT:-85}" # abort at start if pool >= this %
CAP_STOP="${CAP_STOP:-88}"             # watchdog stops the VM at this CAP%
NEED_FREE_GIB="${NEED_FREE_GIB:-25}"   # abort if free < this
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:?set ADMIN_PASS — guest admin password (no default)}"
# Reuse an existing OSX-KVM checkout (has OpenCore.qcow2 + fetch-macOS-v2.py).
SEED_OSXKVM="${SEED_OSXKVM:-/data/gallery-guests/macos-prebuilt-image/OSX-KVM}"
MAC="BC:24:11:00:$(printf '%02x:%02x' $(((VMID / 100) % 100)) $((VMID % 100)))"
OSK='ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc'

log() { echo "[pve-macos-vm $(date +%H:%M:%S)] $*"; }
die() {
  echo "[pve-macos-vm] ABORT: $*" >&2
  exit 1
}

# ---- Disk-safety gate (shared-pool citizen) --------------------------------
check_space() {
  local cap free freeb
  cap=$(zpool list -H -o capacity "$POOL" | tr -d '%')
  free=$(zpool list -H -o free "$POOL")
  freeb=$(zpool list -Hp -o free "$POOL")
  log "pool $POOL: ${cap}% used, ${free} free"
  [ "$cap" -lt "$POOL_CAP_ABORT" ] || die "pool at ${cap}% (>= ${POOL_CAP_ABORT}%). Free space first."
  [ "$freeb" -gt $((NEED_FREE_GIB * 1024 * 1024 * 1024)) ] ||
    die "only ${free} free; need >= ${NEED_FREE_GIB} GiB for the install peak."
}

# ---- VNC helpers (input + screenshots over the PVE VNC unix socket) ---------
# PVE launches qemu with `-vnc unix:<sock>,password=on`; you MUST set a password
# via QMP or all connections are refused. Then bridge the unix sock to TCP.
vnc() { vncdo -s 127.0.0.1::"$VNCPORT" -p "$VNCPW" "$@" 2>/dev/null; }
shot() { vnc capture "$WD/shot-${1:-x}.png" && log "screenshot -> $WD/shot-${1:-x}.png ($(stat -c%s "$WD/shot-${1:-x}.png" 2>/dev/null) bytes)"; }
setpw() { printf '%s\n' '{"execute":"qmp_capabilities"}' \
  "{\"execute\":\"set_password\",\"arguments\":{\"protocol\":\"vnc\",\"password\":\"$VNCPW\"}}" \
  '{"execute":"expire_password","arguments":{"protocol":"vnc","time":"never"}}' |
  socat - UNIX-CONNECT:/var/run/qemu-server/"$VMID".qmp >/dev/null; }
bridge() { ss -ltn 2>/dev/null | grep -q ":$VNCPORT " || {
  nohup socat TCP-LISTEN:"$VNCPORT",bind=127.0.0.1,reuseaddr,fork \
    UNIX-CONNECT:/var/run/qemu-server/"$VMID".vnc >"$WD/socat.log" 2>&1 &
  echo $! >"$WD/socat.pid"
}; }
watchdog() {
  nohup bash -c "
    while true; do
      C=\$(zpool list -Hpo capacity $POOL)
      if [ \"\$C\" -ge $CAP_STOP ]; then
        echo \"\$(date) TRIP cap=\${C}% -> stopping $VMID\" >> $WD/watchdog.log
        qm stop $VMID >> $WD/watchdog.log 2>&1
        touch $WD/WATCHDOG_TRIPPED; exit 0
      fi; sleep 15
    done" >/dev/null 2>&1 &
  echo $! >"$WD/watchdog.pid"
  log "watchdog pid $(cat "$WD/watchdog.pid") @ CAP ${CAP_STOP}%"
}
# wait until the framebuffer PNG grows past a threshold (a real window painted)
wait_paint() {
  local out=$1 thr=${2:-40000} max=${3:-70} i sz
  for i in $(seq 1 "$max"); do
    sleep 18
    vnc capture "$out" >/dev/null 2>&1
    sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
    [ "$sz" -gt "$thr" ] && {
      log "painted ($sz bytes) after $((i * 18))s"
      return 0
    }
  done
  log "wait_paint timed out (last $sz bytes)"
  return 1
}

# ---- 1. tooling + recovery image (no re-download if already present) --------
do_fetch() {
  mkdir -p "$WD"
  cd "$WD"
  if [ ! -d "$OSXKVM" ]; then
    if [ -d "$SEED_OSXKVM" ]; then
      log "reusing $SEED_OSXKVM"
      cp -a "$SEED_OSXKVM" "$OSXKVM"
    else git clone --depth 1 https://github.com/kholia/OSX-KVM.git "$OSXKVM"; fi
  fi
  if [ ! -f "$WD/rec/BaseSystem.img" ] && ! qm config "$VMID" >/dev/null 2>&1; then
    log "fetching $OSVER recovery (~0.8 GiB BaseSystem.dmg -> ~3 GiB img)..."
    # NOTE: fetch-macOS-v2.py prints a benign 'Image verification failed
    # ([Errno 25] Inappropriate ioctl for device)' after the DMG downloads fully
    # in this environment; the DMG is complete and usable.
    python3 "$OSXKVM/fetch-macOS-v2.py" --action download -s "$OSVER" -o "$WD/rec" || true
    [ -s "$WD/rec/BaseSystem.dmg" ] || die "BaseSystem.dmg missing after fetch"
    dmg2img -i "$WD/rec/BaseSystem.dmg" -o "$WD/rec/BaseSystem.img"
  fi
}

# ---- 2. build the VM -------------------------------------------------------
do_create() {
  qm status "$VMID" >/dev/null 2>&1 && die "VMID $VMID already exists; destroy it or pick another."
  local UUID
  UUID=$(tr '[:lower:]' '[:upper:]' </proc/sys/kernel/random/uuid)
  # applesmc OSK + q35/OVMF; NIC vmxnet3 (REQUIRED); VGA vmware (renders Sequoia);
  # SMBIOS MacPro7,1 (product/family/mfr base64) so OpenCore is satisfied.
  qm create "$VMID" --name "macos-$VMID" --memory "$RAM" --cores "$CORES" --sockets 1 \
    --cpu host --ostype other --machine q35 --bios ovmf --scsihw virtio-scsi-pci \
    --net0 "vmxnet3=$MAC,bridge=$BRIDGE,firewall=0" \
    --vga vmware --tablet 0 --balloon 0 --agent enabled=1 \
    --smbios1 "uuid=$UUID,base64=1,serial=QzdHS0tTNjRUMzNa,manufacturer=QXBwbGUgSW5jLg==,product=TWFjUHJvNywx,family=TWFj"
  qm set "$VMID" --efidisk0 "$POOL:0,efitype=4m,pre-enrolled-keys=0"
  # applesmc device + xhci HID + q35 quirks.  *** CRITICAL: no `-cpu ...` here ***
  # A trailing -cpu would be the LAST on the qemu line and override `--cpu host`,
  # reintroducing the Skylake-Server-v4 MP-rendezvous spinlock (black screen).
  qm set "$VMID" --args "-device isa-applesmc,osk=\"$OSK\" -smbios type=2 -device qemu-xhci -device usb-kbd -device usb-tablet -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
  qm importdisk "$VMID" "$OSXKVM/OpenCore/OpenCore.qcow2" "$POOL" # -> disk-1
  qm set "$VMID" --ide0 "$POOL:vm-${VMID}-disk-1,cache=unsafe,media=disk"
  qm importdisk "$VMID" "$WD/rec/BaseSystem.img" "$POOL" # -> recovery
  local REC
  REC=$(qm config "$VMID" | sed -n 's/^unused0: //p')
  qm set "$VMID" --ide2 "${REC},cache=unsafe,media=disk"
  # discard=on lets guest TRIM (Disk Utility erase) reclaim thin-zvol blocks in
  # ZFS -- essential on a small shared pool so a stale/failed install can be
  # freed. If an attempt is stale, fastest reclaim is host-side:
  #   qm stop $VMID; qm set $VMID --delete virtio0; zfs destroy data/vm-$VMID-disk-3
  #   qm set $VMID --virtio0 $POOL:${DISK},discard=on,cache=unsafe   # fresh slate
  qm set "$VMID" --virtio0 "$POOL:${DISK},discard=on,cache=unsafe" # blank target
  qm set "$VMID" --boot order='ide0;ide2;virtio0'
  # reclaim the transient source copies (data now lives in the zvols)
  rm -f "$WD/rec/BaseSystem.dmg" "$WD/rec/BaseSystem.img" "$WD/rec/BaseSystem.chunklist"
  log "VM $VMID built. target=${DISK} GiB sparse, NIC=vmxnet3, VGA=vmware, cpu=host."
}

do_boot() {
  qm start "$VMID" 2>/dev/null || true
  sleep 4
  setpw
  bridge
  watchdog
  log "booted $VMID; VNC on 127.0.0.1:$VNCPORT (pw $VNCPW)"
}

# ---- 3. boot & drive the install -------------------------------------------
# Coordinates are for a 1280x800 framebuffer and DRIFT between point releases.
# ALWAYS verify each step with shot() before trusting the next blind send.
do_drive() {
  do_boot
  sleep 14
  shot 10-opencore
  vnc key right
  sleep 1
  vnc key enter # OpenCore -> "macOS Base System"
  log "booting recovery (SLOW here, ~10-15 min to Utilities)..."
  wait_paint "$WD/shot-20-utilities.png" 40000 70 || true
  vnc key enter
  sleep 3           # accept language (English) if shown
  shot 20-utilities # expect "macOS Utilities" window
  # Disk Utility: erase target -> APFS "Macintosh HD"
  vnc move 548 451 click 1
  sleep 1
  vnc move 821 520 click 1
  sleep 6
  vnc move 223 208 click 1
  sleep 1
  vnc move 968 150 click 1
  sleep 2
  vnc type "Macintosh HD"
  sleep 1
  vnc move 827 513 click 1
  sleep 8
  vnc move 821 468 click 1
  sleep 2
  vnc key super-q
  sleep 3
  shot 30-erased
  # Reinstall macOS -> Continue -> Agree -> Agree(sheet) -> pick disk -> Continue
  vnc move 590 267 click 1
  sleep 1
  vnc move 821 520 click 1
  sleep 6
  vnc move 640 642 click 1
  sleep 25
  vnc move 684 642 click 1
  sleep 2
  vnc move 698 452 click 1
  sleep 3
  # DISK-SELECT CAVEAT: the two disk icons ("macintosh hd" and "macOS Base
  # System") SWAP left/right between runs -- ALWAYS shot() and pick the icon
  # labelled "macintosh hd" (~544,490 or ~700,490). Never blind-click.
  # Also: NEVER resume a half-written install by re-running Reinstall on a
  # non-empty target -- the installer treats stale "macOS Install Data" as
  # occupied and demands +16 GB it can't get. Wipe the target (host-side zvol
  # destroy+recreate, see do_create) and install clean in one pass.
  vnc move 544 490 click 1
  sleep 1
  vnc move 684 642 click 1
  shot 40-installing
  log "installer launched: downloads ~14 GiB then writes the OS (~24 GiB peak),"
  log "then self-reboots (multiple times). Run 'reselect' after each reboot."
}

# After each install-phase reboot, OpenCore gains a target entry. Boot the
# 'macOS Installer' / 'Macintosh HD' entry (verify by screenshot).
do_reselect() {
  setpw
  bridge
  sleep 12
  shot 50-reboot
  vnc key right
  vnc key right
  sleep 1
  vnc key enter
  log "re-selected; verify shot-50."
}

# ---- 4. local admin: bypass Setup Assistant --------------------------------
# Preferred headless bypass: from a Recovery Terminal, mount the INSTALLED
# volume and drop a RunAtLoad LaunchDaemon that creates the admin on first boot
# and marks setup done, so the system boots straight to a usable account.
# Run this AS ROOT inside the guest's Recovery Terminal (target at
# /Volumes/Macintosh\ HD).  It is emitted here for copy/paste or `type`-driving.
admin_payload() {
  cat <<EOF
V="/Volumes/Macintosh HD"
mkdir -p "\$V/usr/local/bin" "\$V/Library/LaunchDaemons"
cat > "\$V/usr/local/bin/lab-firstboot.sh" <<'SH'
#!/bin/bash
dscl . -create /Users/$ADMIN_USER
dscl . -create /Users/$ADMIN_USER UserShell /bin/zsh
dscl . -create /Users/$ADMIN_USER RealName "Lab Admin"
dscl . -create /Users/$ADMIN_USER UniqueID 501
dscl . -create /Users/$ADMIN_USER PrimaryGroupID 20
dscl . -create /Users/$ADMIN_USER NFSHomeDirectory /Users/$ADMIN_USER
dscl . -passwd /Users/$ADMIN_USER '$ADMIN_PASS'
dscl . -append /Groups/admin GroupMembership $ADMIN_USER
createhomedir -c -u $ADMIN_USER >/dev/null 2>&1
# enable auto-login so the box boots straight to a logged-in desktop
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$ADMIN_USER"
python3 - "$ADMIN_PASS" <<'PY'
import sys
# generate /etc/kcpassword (Apple's XOR-cipher for auto-login)
pw=sys.argv[1].encode()
key=bytes([0x7d,0x89,0x52,0x23,0xd2,0xbc,0xdd,0xea,0xa3,0xb9,0x1f])
pw=pw+b"\x00"*(((len(pw)//12)+1)*12-len(pw))
out=bytes(pw[i]^key[i%len(key)] for i in range(len(pw)))
open("/etc/kcpassword","wb").write(out)
import os; os.chmod("/etc/kcpassword",0o600)
PY
touch /var/db/.AppleSetupDone
rm -f /Library/LaunchDaemons/com.lab.firstboot.plist /usr/local/bin/lab-firstboot.sh
SH
chmod +x "\$V/usr/local/bin/lab-firstboot.sh"
cat > "\$V/Library/LaunchDaemons/com.lab.firstboot.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.lab.firstboot</string>
  <key>RunAtLoad</key><true/>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>/usr/local/bin/lab-firstboot.sh</string></array>
</dict></plist>
PL
echo "firstboot daemon installed on \$V"
EOF
}
do_admin() {
  echo "# paste/type the following in the guest's Recovery Terminal (as root):"
  admin_payload
}

do_destroy() {
  [ -f "$WD/socat.pid" ] && kill "$(cat "$WD/socat.pid")" 2>/dev/null || true
  [ -f "$WD/watchdog.pid" ] && kill "$(cat "$WD/watchdog.pid")" 2>/dev/null || true
  qm stop "$VMID" 2>/dev/null || true
  qm destroy "$VMID" --purge 2>/dev/null || true
  log "VM $VMID destroyed. pool free now: $(zpool list -H -o free "$POOL")."
}

case "${1:-all}" in
  fetch)
    check_space
    do_fetch
    ;;
  create)
    check_space
    do_fetch
    do_create
    ;;
  boot) do_boot ;;
  drive) do_drive ;;
  reselect) do_reselect ;;
  admin) do_admin ;;
  shot)
    bridge
    setpw
    shot "${2:-x}"
    ;;
  all)
    check_space
    do_fetch
    do_create
    do_drive
    ;;
  destroy) do_destroy ;;
  *) die "usage: $0 {all|fetch|create|boot|drive|reselect|admin|shot N|destroy}  (env: VMID VNCPORT OSVER DISK)" ;;
esac
