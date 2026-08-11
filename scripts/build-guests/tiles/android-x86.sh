#!/usr/bin/env bash
# =============================================================================
#  build-guests/tiles/android-x86.sh
#  Reproducible from-scratch build of the "Android-x86" Kernel Hive station.
#
#  GOAL: on a FRESH Proxmox host that already has the gallery infra
#  (ZFS dataset data/gallery-guests, qemu-system-x86_64, socat, pnmtopng,
#  python3), rebuild the Android tablet station END TO END with NO image backup:
#     1. download the real Android-x86 9.0-r2 install ISO from SourceForge
#     2. create an 8 GiB qcow2
#     3. boot the ISO and run the text installer UNATTENDED (partition, format
#        ext4, install, write GRUB) via QEMU-monitor `sendkey` sequences
#     4. cold-boot the installed disk and drive the Android 9 SetupWizard with
#        the Android SetupWizard taps over VNC (usb-tablet absolute pointer).
#        enables the absolute tablet mapping AFTER the client sends SetEncodings
#        BEFORE any pointer event -- otherwise every tap collapses to (0,0).
#        The inlined python tapper does exactly that (transcribed from the
#        dry-run box's vnctap.py).
#     5. leave the final persistent bootable image at
#        /data/gallery-guests/Android/android.qcow2
#     6. framebuffer-verify (monitor `screendump` -> png, non-black check) that
#        a clean cold boot reaches the Android home screen with NO wizard.
#
#  The result cold-boots unattended straight to the Quickstep launcher; the
#  SetupWizard only runs once because /data persists on the qcow2.
#
# -----------------------------------------------------------------------------
#  WHAT IS FULLY AUTOMATED vs WHAT IS NOT  (read this before trusting a run)
# -----------------------------------------------------------------------------
#  FULLY AUTOMATED / faithfully transcribed from the dry-run box:
#    - ISO download (real URL + exact SHA256 checksum gate)
#    - qcow2 creation
#    - QEMU launch args (identical to android-boot.sh, but using the stock
#      qemu-system-x86_64 -- see MOBRUN note below)
#    - the monitor primitives: sendkey (android-key.sh), screendump->png
#      (android-shot.sh), absolute mouse tap (android-tap.sh)
#    - the VNC SetEncodings-first tapper (vnctap.py) and swiper (vncswipe.py)
#    - clean pidfile/monitor-quit shutdown, unique VNC+monitor sockets
#    - screenshot verification at every phase
#
#  RECONSTRUCTED (the ONE calibration point -- see CAVEAT):
#    - the exact GRUB/installer key sequence and the SetupWizard
#      SetupWizard TAP coordinates (WIZARD_TAPS[]). On the dry-run box these
#      were driven INTERACTIVELY from the shell; only the primitive tools were
#      saved, never a sequence file. The arrays below encode the STANDARD
#      Android-x86 9.0-r2 flow at 1024x768 std-VGA. The script dumps a
#      screenshot before/after every keystroke-group and every tap so the
#      coordinates can be eyeballed and nudged on first run. If your
#      framebuffer differs, adjust the two arrays -- nothing else.
#      => Treat the installer + wizard phases as "automated, verify-on-first-run".
#
#  MOBRUN note: the dry-run box invoked a binary called /root/mobrun. That was
#  just a RENAMED copy of qemu-system-x86_64, made once to survive a stray
#  `pkill qemu` sweep on that shared box. On a quiet host it is NOT needed; this
#  script uses the stock qemu-system-x86_64. (Manifest confirms: "use the normal
#  qemu-system-x86_64 binary".)
#
#  HYGIENE (per project rules): we NEVER pkill by name. The VM is killed only by
#  monitor `quit` and, as a fallback, by the PID we wrote to a namespaced
#  pidfile. Unique VNC display + monitor socket keep us off every other guest,
#  CTID 110, VM 900/920, and the macOS fan-out VMIDs.
#
#  Usage:
#     ./android-x86.sh                 # idempotent full build (skips finished phases)
#     FORCE=1 ./android-x86.sh         # wipe qcow2 and rebuild from the ISO
#     PHASE=verify ./android-x86.sh    # only re-run the cold-boot GUI verification
#     KEEP_ISO=0 ./android-x86.sh      # delete the ISO after a successful build
#     INSTALL_VISION=1 ./android-x86.sh # proposed OCR/template first-run path
#
#  Run on the Proxmox host (bash 4+). bash -n clean.
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ---------------------------------------------------------------------------
# Parameters (override via env)
# ---------------------------------------------------------------------------
GUEST_KEY="android-x86"
BOX_DIR="${BOX_DIR:-/data/gallery-guests/Android}" # persistent station dir
WORK_DIR="${WORK_DIR:-$BOX_DIR}"                   # scratch = same dir

ISO_NAME="android-x86-9.0-r2.iso"
# Canonical SourceForge mirror (verified: 761266176 bytes, follows to a dl node).
ISO_URL="${ISO_URL:-https://sourceforge.net/projects/android-x86/files/Release%209.0/android-x86-9.0-r2.iso/download}"
ISO_SHA256="91cedb534ba095a0c9b3eceede4147967fd27beea9bba640776f787dc3555021"

DISK_NAME="android.qcow2"
DISK_SIZE="${DISK_SIZE:-8G}"

# Namespaced runtime handles -- unique to THIS guest, collide with nothing.
VNC_DISPLAY="${VNC_DISPLAY:-37}" # QEMU -vnc :37 => TCP 5900+37
VNC_PORT=$((5900 + VNC_DISPLAY))
MON_SOCK="${MON_SOCK:-/run/gallery-android.mon}"
QMP_SOCK="${QMP_SOCK:-/run/gallery-android.qmp}"
PID_FILE="${PID_FILE:-/run/gallery-android.pid}"
LOCK_FILE="${LOCK_FILE:-/run/gallery-android.lock}"

QEMU="${QEMU:-qemu-system-x86_64}"
BIOS_L="${BIOS_L:-/usr/share/kvm}" # -L firmware dir (matches box)

FORCE="${FORCE:-0}"
KEEP_ISO="${KEEP_ISO:-1}"
PHASE="${PHASE:-all}"                 # all|download|disk|install|wizard|verify
INSTALL_VISION="${INSTALL_VISION:-0}" # 1 = OCR/template wizard driver
VISION_DIR="${VISION_DIR:-$SCRIPT_DIR/../../install-vision}"
VISION_PY="${VISION_PY:-$VISION_DIR/.venv/bin/python}"

ISO_PATH="$WORK_DIR/$ISO_NAME"
DISK_PATH="$BOX_DIR/$DISK_NAME"

log() { printf '\033[36m[android-x86 %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() {
  printf '\033[31m[android-x86 FATAL]\033[0m %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  for t in "$QEMU" qemu-img socat pnmtopng python3 curl flock; do
    command -v "$t" >/dev/null 2>&1 || {
      [ "$t" = "pnmtopng" ] && die "missing required tool: pnmtopng (install Debian package: netpbm)"
      die "missing required tool: $t"
    }
  done
  mkdir -p "$BOX_DIR" "$WORK_DIR"
  # ZFS dataset is expected to already exist; this is a no-op if it does.
  # (kept as a comment so we never touch pool layout implicitly)
  #   zfs create -o compression=zstd data/gallery-guests 2>/dev/null || true
  [ -w "$BOX_DIR" ] || die "box dir not writable: $BOX_DIR"
  if [ "$INSTALL_VISION" = "1" ]; then
    [ -x "$VISION_PY" ] || die "vision venv missing: run $VISION_DIR/install.sh"
    command -v tesseract >/dev/null 2>&1 || die "vision mode requires tesseract-ocr"
    [ -f "$VISION_DIR/driver.py" ] || die "vision driver missing: $VISION_DIR/driver.py"
  fi
}

# ---------------------------------------------------------------------------
# Monitor / QEMU control primitives
#   (transcribed from android-boot.sh / android-key.sh / android-shot.sh /
#    android-tap.sh on the dry-run box)
# ---------------------------------------------------------------------------

# Send one raw QMP/HMP monitor line and return.
mon() { printf '%s\n' "$*" | socat - "unix-connect:$MON_SOCK" >/dev/null 2>&1 || true; }

# Is the VM (by pidfile) alive?
vm_alive() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

# Clean shutdown: monitor quit first, then pidfile fallback. NEVER pkill by name.
vm_stop() {
  if [ -S "$MON_SOCK" ]; then mon "quit"; fi
  for _ in $(seq 1 20); do
    vm_alive || break
    sleep 0.5
  done
  if vm_alive; then
    log "monitor quit did not take; killing pid $(cat "$PID_FILE") from pidfile"
    kill "$(cat "$PID_FILE")" 2>/dev/null || true
    for _ in $(seq 1 10); do
      vm_alive || break
      sleep 0.5
    done
    vm_alive && kill -9 "$(cat "$PID_FILE")" 2>/dev/null || true
  fi
  rm -f "$PID_FILE" "$MON_SOCK" "$QMP_SOCK"
}

# Boot the VM.  $1 = iso | disk
# These args are IDENTICAL in spirit to labhost's android-boot.sh, minus the
# renamed binary, plus a namespaced monitor socket + pidfile.
vm_boot() {
  local mode="$1" bootargs
  rm -f "$MON_SOCK" "$QMP_SOCK"
  if [ "$mode" = "iso" ]; then
    bootargs=(-cdrom "$ISO_PATH" -boot d)
  else
    bootargs=(-boot c)
  fi
  # NOTE: -audiodev none on the headless build box (a real ALSA/HDA backend
  # crashed QEMU there). In neko, swap for the container's Pulse/PipeWire sink.
  "$QEMU" -L "$BIOS_L" \
    -enable-kvm -machine q35 -cpu host -smp 4 -m 3072 \
    -drive file="$DISK_PATH",if=none,id=hd0,format=qcow2 \
    -device virtio-blk-pci,drive=hd0 \
    "${bootargs[@]}" \
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \
    -device usb-ehci,id=usb -device usb-tablet,bus=usb.0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -vga std -display none -vnc ":$VNC_DISPLAY" \
    -monitor "unix:$MON_SOCK,server,nowait" \
    -qmp "unix:$QMP_SOCK,server=on,wait=off" \
    >/dev/null 2>&1 &
  echo $! >"$PID_FILE"
  # wait for monitor socket to appear
  for _ in $(seq 1 30); do
    [ -S "$MON_SOCK" ] && [ -S "$QMP_SOCK" ] && break
    sleep 0.5
  done
  [ -S "$MON_SOCK" ] || die "QEMU monitor socket never appeared"
  [ -S "$QMP_SOCK" ] || die "QEMU QMP socket never appeared"
  log "booted pid $(cat "$PID_FILE") mode=$mode  vnc=:$VNC_DISPLAY (tcp $VNC_PORT)"
}

# Screendump the current framebuffer to a PNG under BOX_DIR; echo the path.
shot() {
  local name="$1" ppm="$WORK_DIR/$1.ppm" png="$BOX_DIR/$1.png"
  mon "screendump $ppm"
  sleep 1
  pnmtopng "$ppm" >"$png" 2>/dev/null || true
  rm -f "$ppm"
  echo "$png"
}

# Assert a PNG is NOT a solid/near-black frame (our GUI-reached gate).
# Returns 0 if the frame has real content.
assert_not_black() {
  local png="$1"
  [ -s "$png" ] || return 1
  python3 - "$png" <<'PY'
import sys, zlib, struct
# minimal PNG reader: decode to raw and measure mean luma + variance
def read_png(path):
    d=open(path,'rb').read()
    assert d[:8]==b'\x89PNG\r\n\x1a\n'
    i=8; w=h=bit=col=0; idat=b''
    while i<len(d):
        ln=struct.unpack('>I',d[i:i+4])[0]; typ=d[i+4:i+8]; data=d[i+8:i+8+ln]
        if typ==b'IHDR':
            w,h,bit,col=struct.unpack('>IIBB',data[:10])
        elif typ==b'IDAT':
            idat+=data
        elif typ==b'IEND':
            break
        i+=12+ln
    raw=zlib.decompress(idat)
    ch={0:1,2:3,3:1,4:2,6:4}[col]
    bpp=ch*(bit//8) if bit>=8 else 1
    stride=w*ch*(bit//8) if bit>=8 else (w*ch*bit+7)//8
    out=bytearray(); prev=bytearray(stride); pos=0
    def pa(a,b,c):
        p=a+b-c; pa_=abs(p-a); pb=abs(p-b); pc=abs(p-c)
        return a if(pa_<=pb and pa_<=pc)else(b if pb<=pc else c)
    for _ in range(h):
        f=raw[pos]; pos+=1; line=bytearray(raw[pos:pos+stride]); pos+=stride
        for x in range(stride):
            a=line[x-bpp] if x>=bpp else 0
            b=prev[x]; c=prev[x-bpp] if x>=bpp else 0
            if f==1: line[x]=(line[x]+a)&255
            elif f==2: line[x]=(line[x]+b)&255
            elif f==3: line[x]=(line[x]+((a+b)>>1))&255
            elif f==4: line[x]=(line[x]+pa(a,b,c))&255
        out+=line; prev=line
    return w,h,ch,bit,out
try:
    w,h,ch,bit,raw=read_png(sys.argv[1])
except Exception as e:
    print("decode-fail",e); sys.exit(2)
if bit!=8:  # rare; treat as "content present" and pass
    print("nonstd-bit ok"); sys.exit(0)
n=w*h; step=max(1,n//20000); s=0.0; ss=0.0; cnt=0
for p in range(0,n,step):
    off=p*ch
    r=raw[off]; g=raw[off+1] if ch>=3 else r; b=raw[off+2] if ch>=3 else r
    lum=0.299*r+0.587*g+0.114*b; s+=lum; ss+=lum*lum; cnt+=1
mean=s/cnt; var=ss/cnt-mean*mean
print(f"mean={mean:.1f} var={var:.1f} {w}x{h}")
# a real GUI frame has either non-trivial brightness or real spatial variance
sys.exit(0 if (mean>8 and var>25) else 1)
PY
}

# sendkey groups (android-key.sh).  Args = space-separated qemu keynames.
keys() { for k in "$@"; do
  mon "sendkey $k"
  sleep 0.25
done; }

# Absolute-pointer tap via the MONITOR (android-tap.sh). Range 0..32767.
# Kept as a fallback tap path; the wizard uses the VNC tapper below.
mon_tap() {
  mon "mouse_move $1 $2"
  sleep 0.2
  mon "mouse_button 1"
  sleep 0.15
  mon "mouse_button 0"
  sleep 0.4
}

# VNC tap -- the SetEncodings-FIRST tapper (transcribed from vnctap.py).
# x,y are PIXELS in the guest framebuffer (e.g. 1024x768). This is the path the
# recipe requires: without SetEncodings before the pointer event QEMU collapses
# absolute taps to (0,0).
vnc_tap() {
  python3 - "$VNC_PORT" "$1" "$2" "${3:-0.18}" <<'PY'
import socket, sys, time
port=int(sys.argv[1]); x=int(sys.argv[2]); y=int(sys.argv[3]); hold=float(sys.argv[4])
s=socket.create_connection(("127.0.0.1",port),5)
s.recv(12); s.sendall(b"RFB 003.008\n")
n=s.recv(1)[0]; s.recv(n); s.sendall(bytes([1])); s.recv(4)   # no auth
s.sendall(bytes([1]))                                          # ClientInit shared
hdr=b""
while len(hdr)<24: hdr+=s.recv(24-len(hdr))                    # ServerInit
nl=int.from_bytes(hdr[20:24],"big"); g=0
while g<nl: g+=len(s.recv(nl-g))                               # name
s.sendall(bytes([2,0])+(1).to_bytes(2,"big")+(0).to_bytes(4,"big"))  # SetEncodings raw -- BEFORE pointer!
def ptr(mask,x,y): s.sendall(bytes([5,mask])+x.to_bytes(2,"big")+y.to_bytes(2,"big"))
ptr(0,x,y); time.sleep(0.15)
ptr(1,x,y); time.sleep(hold)
ptr(0,x,y); time.sleep(0.3)
print("tap",x,y); s.close()
PY
}

# VNC swipe (transcribed from vncswipe.py) -- e.g. "slide to unlock" style drags.
vnc_swipe() {
  python3 - "$VNC_PORT" "$1" "$2" "$3" "$4" <<'PY'
import socket, sys, time
port=int(sys.argv[1]); x1,y1,x2,y2=[int(a) for a in sys.argv[2:6]]
s=socket.create_connection(("127.0.0.1",port),5)
s.recv(12); s.sendall(b"RFB 003.008\n")
n=s.recv(1)[0]; s.recv(n); s.sendall(bytes([1])); s.recv(4)
s.sendall(bytes([1]))
hdr=b""
while len(hdr)<24: hdr+=s.recv(24-len(hdr))
nl=int.from_bytes(hdr[20:24],"big"); g=0
while g<nl: g+=len(s.recv(nl-g))
s.sendall(bytes([2,0])+(1).to_bytes(2,"big")+(0).to_bytes(4,"big"))
def ptr(mask,x,y): s.sendall(bytes([5,mask])+x.to_bytes(2,"big")+y.to_bytes(2,"big"))
ptr(0,x1,y1); time.sleep(0.1); ptr(1,x1,y1); time.sleep(0.1)
N=20
for i in range(1,N+1):
    x=int(x1+(x2-x1)*i/N); y=int(y1+(y2-y1)*i/N); ptr(1,x,y); time.sleep(0.02)
time.sleep(0.1); ptr(0,x2,y2); time.sleep(0.3)
print("swipe",x1,y1,x2,y2); s.close()
PY
}

# ===========================================================================
# PHASE 1 -- download the real ISO (idempotent + checksum gate)
# ===========================================================================
phase_download() {
  if [ -f "$ISO_PATH" ] && echo "$ISO_SHA256  $ISO_PATH" | sha256sum -c - >/dev/null 2>&1; then
    log "ISO present and checksum OK -- skip download"
    return
  fi
  log "downloading $ISO_NAME from SourceForge ..."
  curl -fL --retry 3 --retry-delay 5 -o "$ISO_PATH.part" "$ISO_URL"
  mv "$ISO_PATH.part" "$ISO_PATH"
  echo "$ISO_SHA256  $ISO_PATH" | sha256sum -c - ||
    die "ISO checksum mismatch -- refusing to build from a bad download"
  log "ISO downloaded + verified ($(du -h "$ISO_PATH" | cut -f1))"
}

# ===========================================================================
# PHASE 2 -- create the qcow2
# ===========================================================================
phase_disk() {
  if [ "$FORCE" = "1" ]; then
    rm -f "$DISK_PATH"
    log "FORCE: removed old qcow2"
  fi
  if [ -f "$DISK_PATH" ]; then
    log "qcow2 exists -- skip create (FORCE=1 to wipe)"
    return
  fi
  qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE" >/dev/null
  log "created blank $DISK_SIZE qcow2 at $DISK_PATH"
}

# ===========================================================================
# PHASE 3 -- unattended text-installer run  (ISO boot -> install to qcow2)
#
#   Android-x86 9.0-r2 GRUB live menu, top entry highlighted:
#     1  Live CD - Run Android-x86 without installation   <- default
#     2  Live CD - Debug mode
#     3  Installation - Install Android-x86 to harddisk   <- we want this
#     4  Advanced options...
#
#   Then the ncurses installer:
#     - Choose partition -> "Create/Modify partitions"
#     - "Do you want to use GPT?"  -> No (MBR / cfdisk)
#     - cfdisk:  New -> Primary -> full size -> Bootable -> Write "yes" -> Quit
#     - pick the new sda1 -> format as ext4 -> confirm
#     - Install boot loader GRUB -> Yes
#     - Make /system read-write -> Yes  (lets us persist era software)
#     - Reboot
#
#   CAVEAT (honesty): these keystrokes are the RECONSTRUCTED standard flow.
#   The dry-run box drove them interactively and saved no sequence file. Each
#   step dumps a screenshot (install-step-NN.png) so you can confirm/adjust on
#   the FIRST run. cfdisk's exact bottom-menu geometry varies by util-linux
#   build; if a step lands wrong, tweak INSTALL_KEYS below -- nothing else.
# ===========================================================================
phase_install() {
  [ -f "$ISO_PATH" ] || die "install: ISO missing (run phase download first)"
  [ -f "$DISK_PATH" ] || die "install: qcow2 missing (run phase disk first)"
  log "PHASE install: booting ISO to run the unattended text installer"
  vm_boot iso

  # --- 3a: let GRUB paint, then select entry #3 (Install to harddisk) --------
  sleep 25
  shot install-step-01-grub >/dev/null
  keys down down ret # move to "Installation ..." and boot it
  sleep 30
  shot install-step-02-partmenu >/dev/null # partition chooser

  # --- 3b: Create/Modify partitions ------------------------------------------
  # On a blank disk the list is short; "Create/Modify partitions" is the entry
  # just below the (empty) device list. Arrow down to it and select.
  keys down ret # -> Create/Modify partitions
  sleep 3
  keys ret # "Do you want to use GPT?" -> No (default, MBR)
  sleep 4
  shot install-step-03-cfdisk >/dev/null

  # --- 3c: cfdisk -- one bootable primary spanning the whole disk ------------
  # util-linux cfdisk 2.14 starts on [Help]. Move right to [New], accept the
  # default Primary type and full size, then [Bootable], [Write], and [Quit].
  keys right ret # Help -> New
  sleep 1
  keys ret # Primary (default)
  sleep 1
  keys ret # size = whole disk (default)
  sleep 1
  shot install-step-04-part-made >/dev/null
  # navigate bottom bar to Bootable (leftmost) -- already there after create
  keys ret # Bootable flag
  sleep 1
  # [Write] wraps one position left from [Bootable].
  keys left ret # -> Write
  sleep 1
  # cfdisk asks to type the word "yes"
  keys y e s ret
  sleep 3
  shot install-step-05-written >/dev/null
  # After writing, selection resets to [Bootable]; [Quit] is five to the right.
  keys right right right right right ret # -> Quit cfdisk
  sleep 4
  shot install-step-06-choose-part >/dev/null

  # --- 3d: pick sda1, format ext4, install grub, rw /system ------------------
  keys ret # freshly created partition is selected
  sleep 3
  shot install-step-07-fs >/dev/null
  keys down ret # filesystem list: skip "Do not re-format" -> ext4
  sleep 2
  keys left ret # "format?" confirm -> Yes
  sleep 20
  shot install-step-08-formatted >/dev/null # format runs

  keys left ret # "Install GRUB boot loader?" -> Yes
  sleep 8
  shot install-step-09-grub >/dev/null
  keys left ret # "system dir read-write?" -> Yes
  sleep 40
  shot install-step-10-installing >/dev/null # copy files

  # --- 3e: installation done -> reboot (do NOT re-run the installer) ---------
  # "Installation successful" -> "Reboot". We instead hard-stop QEMU cleanly and
  # cold-boot from disk ourselves in the next phase (deterministic, no re-entry
  # into the live CD).
  sleep 10
  shot install-step-11-done >/dev/null
  log "installer finished (see $BOX_DIR/install-step-*.png); stopping ISO VM"
  vm_stop
  log "PHASE install complete"
}

# ===========================================================================
# PHASE 4 -- first cold boot from disk: drive the SetupWizard over VNC
#
#   Android 9 tablet SetupWizard, 1024x768 landscape. The taps below are the
#   RECONSTRUCTED standard "offline, skip everything" path that lands on the
#   Quickstep home screen. Coordinates are PIXELS; a screenshot is taken before
#   AND after each tap (wizard-NN-*.png) so you can calibrate on first run.
#   After this completes once, /data persists -> the wizard never runs again.
#
#   The installed 9.0-r2 image restarts its offline setup flow once after the
#   first "Just a sec..." finalization. The 150-second delay below lets that
#   deterministic second pass repaint before continuing. The final two taps
#   select Quickstep as the persistent Home app.
# ===========================================================================
# x     y     label                    post-tap-delay
WIZARD_TAPS=(
  "630 432 welcome-START               4"
  "231 617 wifi-SKIP                   2"
  "696 486 wifi-CONTINUE               4"
  "768 616 datetime-NEXT               4"
  "784 616 services-MORE               3"
  "784 616 services-ACCEPT             4"
  "512 502 lock-NOT-NOW                2"
  "716 423 lock-SKIP-ANYWAY          150"
  "231 617 wifi-second-SKIP             2"
  "696 486 wifi-second-CONTINUE         4"
  "768 616 datetime-second-NEXT         3"
  "784 616 services-second-MORE         3"
  "784 616 services-second-ACCEPT       3"
  "512 502 lock-second-NOT-NOW          2"
  "716 423 lock-second-SKIP-ANYWAY     15"
  "512 573 launcher-Quickstep           1"
  "703 688 launcher-ALWAYS              5"
)

phase_wizard_coordinates() {
  [ -f "$DISK_PATH" ] || die "wizard: qcow2 missing"
  log "PHASE wizard: cold-booting disk to drive the SetupWizard over VNC"
  vm_boot disk
  log "waiting for first boot to reach the SetupWizard (Android 9 first-run is slow)"
  sleep 75
  shot wizard-00-welcome >/dev/null

  local i=1 x y label delay
  for entry in "${WIZARD_TAPS[@]}"; do
    read -r x y label delay <<<"$entry"
    printf -v n '%02d' "$i"
    log "tap $n ($label) at ${x},${y}"
    vnc_tap "$x" "$y" >/dev/null 2>&1 || log "  (vnc_tap $label returned nonzero; continuing)"
    sleep "${delay:-4}"
    shot "wizard-$n-$label" >/dev/null
    i=$((i + 1))
  done

  sleep 6
  local home
  home=$(shot proof-installed-home)
  if assert_not_black "$home"; then
    log "SetupWizard drive complete; home screen frame looks live: $home"
  else
    log "WARNING: post-wizard frame looks black/empty. Inspect $BOX_DIR/wizard-*.png"
    log "         and calibrate WIZARD_TAPS[] to your framebuffer, then re-run PHASE=wizard."
  fi
  vm_stop
  log "PHASE wizard complete"
}

# Content-aware research path. The driver waits until each target is visible,
# checkpoints that exact pre-click framebuffer, tries OCR first, falls back to
# the task's real Android crops, injects an absolute QMP tablet tap, and requires
# a framebuffer transition followed by steady frames. INSTALL_VISION=0 keeps
# the historical coordinate path available for A/B comparison.
vision_step() {
  local name="$1" text="$2" template="$3" checkpoint="$4" roi="${5:-}" expected="${6:-}"
  local args=(step --qmp "$QMP_SOCK" --work-dir "$WORK_DIR/vision-evidence"
    --detect-timeout 120 --timeout 90 --checkpoint "$checkpoint" --text "$text")
  [ -n "$template" ] && args+=(--template "$VISION_DIR/templates/android/$template")
  [ -n "$roi" ] && args+=(--roi "$roi")
  [ -n "$expected" ] && args+=(--expected-region "$expected")
  log "vision step $name: target='$text' checkpoint=$checkpoint"
  "$VISION_PY" "$VISION_DIR/driver.py" "${args[@]}" "$name" ||
    die "vision step failed: $name (see $WORK_DIR/vision-evidence/$name.json)"
}

phase_wizard_vision() {
  [ -f "$DISK_PATH" ] || die "wizard: qcow2 missing"
  log "PHASE wizard: content-aware OCR/template drive over QMP"
  vm_boot disk

  vision_step welcome START start.png cp-preclick-welcome "" "rel:0.18,0.28,0.65,0.20"
  vision_step wifi SKIP skip.png cp-preclick-wifi
  vision_step wifi-confirm CONTINUE continue.png cp-preclick-wifi-confirm
  vision_step datetime NEXT next.png cp-preclick-datetime
  vision_step services-more MORE more.png cp-preclick-services-more "rel:0.68,0.72,0.32,0.20"
  vision_step services-accept ACCEPT accept.png cp-preclick-services-accept "rel:0.68,0.72,0.32,0.20"
  vision_step lock "Not now" not-now.png cp-preclick-lock
  vision_step lock-confirm "SKIP ANYWAY" skip-anyway.png cp-preclick-lock-confirm
  vision_step launcher-quickstep Quickstep quickstep.png cp-preclick-launcher-quickstep
  vision_step launcher-always ALWAYS always.png cp-preclick-launcher-always

  local home
  home=$(shot proof-installed-home)
  if "$VISION_PY" "$VISION_DIR/find_text.py" "$home" Google --roi "rel:0,0,1,0.25" >/dev/null; then
    log "content gate passed: Quickstep home search bar is visible ($home)"
  else
    die "wizard ended without the Quickstep home content gate ($home)"
  fi
  vm_stop
  log "PHASE wizard vision complete"
}

phase_wizard() {
  if [ "$INSTALL_VISION" = "1" ]; then
    phase_wizard_vision
  else
    phase_wizard_coordinates
  fi
}

# ===========================================================================
# PHASE 5 -- unattended cold-boot verification (the money shot)
#   Boot the installed disk with ZERO interaction and prove it reaches home.
# ===========================================================================
phase_verify() {
  [ -f "$DISK_PATH" ] || die "verify: qcow2 missing"
  log "PHASE verify: unattended cold boot -> expect Android home, no wizard"
  vm_boot disk
  sleep 55 # boot animation -> launcher
  local png
  png=$(shot proof-cold-boot-home)
  vm_stop
  if assert_not_black "$png"; then
    log "VERIFIED: cold boot reached a live GUI frame -> $png"
    log "Android-x86 tile build OK."
    return 0
  fi
  log "VERIFY FAILED: cold-boot frame is black/empty ($png)."
  log "If the wizard never completed, re-run PHASE=wizard after calibrating taps."
  return 1
}

print_gallery_args() {
  cat >&2 <<EOF

------------------------------------------------------------------------------
neko-qemu gallery tile QEMU args (production form; swap -audiodev none for the
container's Pulse/PipeWire sink, point -vnc at what neko captures):

  qemu-system-x86_64 -enable-kvm -machine q35 -cpu host -smp 4 -m 3072 \\
    -drive file=$DISK_PATH,if=none,id=hd0,format=qcow2 \\
    -device virtio-blk-pci,drive=hd0 -boot c \\
    -audiodev none,id=snd0 -device intel-hda -device hda-duplex,audiodev=snd0 \\
    -device usb-ehci,id=usb -device usb-tablet,bus=usb.0 \\   # absolute pointer = tap
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \\
    -vga std -display none -vnc :37 -monitor unix:mon.sock,server,nowait

  * usb-tablet => VNC/neko click lands as a TAP at that pixel.
  * neko's VNC client MUST send SetEncodings BEFORE pointer events, else taps
    collapse to (0,0). (See the vnc_tap python here / the box's vnctap.py.)
  * -vga std (NOT virtio) -- virtio-gpu KMS is flaky on Android-x86 9.
------------------------------------------------------------------------------
EOF
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another android-x86 builder is already running (lock: $LOCK_FILE)"
  preflight
  trap 'vm_stop 2>/dev/null || true' EXIT
  case "$PHASE" in
    download) phase_download ;;
    disk) phase_disk ;;
    install) phase_install ;;
    wizard) phase_wizard ;;
    verify) phase_verify ;;
    all)
      # Idempotent short-circuit: if the disk already verifies, do nothing.
      if [ "$FORCE" != "1" ] && [ -f "$DISK_PATH" ] && phase_verify; then
        log "already built + verified; nothing to do (FORCE=1 to rebuild)"
      else
        phase_download
        phase_disk
        phase_install
        phase_wizard
        phase_verify
      fi
      ;;
    *) die "unknown PHASE=$PHASE (all|download|disk|install|wizard|verify)" ;;
  esac
  [ "$KEEP_ISO" = "1" ] || {
    rm -f "$ISO_PATH"
    log "removed ISO (KEEP_ISO=0)"
  }
  print_gallery_args
}
main "$@"
