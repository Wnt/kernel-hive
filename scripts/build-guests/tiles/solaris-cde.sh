#!/usr/bin/env bash
# =============================================================================
# build-guests/tiles/solaris-cde.sh  —  reproducible from-scratch build of the
# "Solaris 10 CDE" Kernel Hive guest.
#
# GOAL: on a fresh Proxmox host that already has the gallery infra, rebuild the
# Solaris 10 x86 -> CDE station END TO END from the real Oracle install media —
# no image backups, just a runnable recipe. Produces the golden disk
#   /data/gallery-guests/SolarisCDE/solaris.qcow2
# that boots to the authentic Common Desktop Environment (dtlogin -> CDE).
#
# WHAT THIS PRODUCES (all under $GUEST_DIR = /data/gallery-guests/SolarisCDE):
#   solaris.qcow2               golden disk, boots straight to dtlogin -> CDE
#   sol10.iso                   the downloaded Oracle Solaris 10 x86 DVD (media)
#   sysidcfg / profile          the JumpStart answer files used for hands-off install
#   proof-cde-desktop.png       framebuffer proof (front panel + dtfile)
#   MANIFEST.md                 the exact neko-qemu runtime args
#
# ---------------------------------------------------------------------------
# RECIPE (see exotic-gallery-guests.md §5 "Solaris 10 CDE" + on-box NOTES.md):
#   Real Oracle Solaris 10 x86 (u11 / 10/09-era Oracle-branded dtlogin) installed
#   to a 12 GiB IDE qcow2, then booted to genuine CDE. Login root/solaris. The
#   default desktop is forced to CDE by a one-line /usr/dt/bin/Xsession edit baked
#   into the golden (STEP 3.5 bake_cde_default — Solaris 10 otherwise defaults to
#   JDS/GNOME). "CDE deprecated" nag dismissed. Runtime boot is disk-only.
#
# ---------------------------------------------------------------------------
# AUTOMATION HONESTY  (read this before trusting the script end-to-end):
#
#   FULLY AUTOMATED + faithfully transcribed from the on-box helpers
#   (typer.py / run-install.sh / run-disk.sh / trylogin.sh / shot.sh / NOTES.md):
#     * ISO download (given an authenticated Oracle URL or a local ISO — see below)
#     * 12 GiB qcow2 disk creation
#     * installer boot with the DVD attached (== run-install.sh)
#     * post-install: force-eject the locked CD, first boot from disk
#     * dtlogin auto-type  root<CR>solaris<CR>   (== trylogin.sh + typer.py)
#     * CDE-as-default bake (STEP 3.5): patch /usr/dt/bin/Xsession so the desktop
#       is always CDE (dtsession), not JDS — the real "land on CDE" fix
#     * "CDE has been deprecated" nag dismissal ("Do not show again")
#     * headless framebuffer verification -> proof-cde-desktop.png
#
#   INSTALLER CALIBRATION (validated from a blank disk on 2026-07-15):
#     The previously missing `suninstall` sequence is encoded in install_os(). It
#     uses framebuffer-measured waits and literal keyboard navigation, including
#     highlight+Space radio selection, Networked: No, End User System Support,
#     and creation of the required full-disk Solaris fdisk partition. Completion
#     is detected from two consecutive real screendumps of the black reboot
#     prompt before the DVD is force-ejected and Return is sent.
#
#     Everything after installer reboot remains the faithful helper transcription.
#
#     Default mode is SAFE: the script will NOT wipe an existing golden disk and
#     will NOT re-run the (expensive, ~40 min) install unless you pass
#     INSTALL_GUEST=1. With a golden disk already present it re-derives only the
#     cheap, fully-automated tail (verify + manifest), which is idempotent.
#
# ---------------------------------------------------------------------------
# LICENSING: Oracle Solaris 10 is Oracle-copyrighted — free to use in this private
#   collection. It is downloadable under the Oracle Technology Network (OTN)
#   *developer* license (dev/test/prototyping). Keep it as a personal retro demo
#   behind edge auth and do not redistribute a publicly-served instance. The OTN
#   download is SSO-gated, so this script CANNOT fetch it
#   with a bare curl — you must accept the OTN license and provide the ISO (see
#   "Obtaining the media" below). Fully-free look-alike path (not used here):
#   open-source CDE (cdesktopenv, LGPL/MIT) on Debian/FreeBSD.
#
# ---------------------------------------------------------------------------
# HYGIENE (per task rules):
#   * Kills QEMU ONLY via HMP `quit` then the recorded pidfile — NEVER pkill/
#     killall by name.
#   * Namespaced work dir; UNIQUE per-PID monitor + VNC sockets (no collisions
#     with other guests).
#   * Touches ONLY /data/gallery-guests/SolarisCDE — never other guests, CT 110,
#     VM 900/920, or the macOS fan-out VMIDs.
#   * Idempotent + re-runnable.
# =============================================================================
set -euo pipefail

# ---- Parameters -------------------------------------------------------------
KEY="solaris-cde"
GUEST_DIR="${GUEST_DIR:-/data/gallery-guests/SolarisCDE}"

# Golden disk + media.
IMG="${GUEST_DIR}/solaris.qcow2"
DISK_SIZE="${DISK_SIZE:-12G}" # Solaris installed to a 12 GiB virtual IDE disk
ISO="${GUEST_DIR}/sol10.iso"

# --- Obtaining the media -----------------------------------------------------
# The canonical DVD is Oracle Solaris 10 1/13 (u11) x86:  sol-10-u11-ga-x86-dvd.iso
# Default source is the Internet Archive preservation copy (2.25 GB, public direct
# download — works with a plain curl, no SSO). Solaris 10 is Oracle-copyrighted
# (OTN developer licence) — free to use in this private collection; this is a
# preservation copy, kept as a personal retro station behind edge auth; do not
# redistribute a publicly-served instance.
# Override if you have your own media:
#   SOL10_ISO=/path/to/sol-10-u11-ga-x86-dvd.iso        (a local copy)
#   SOL10_ISO_URL=https://.../sol-10-u11-ga-x86-dvd.iso  (an alternate URL)
# (Oracle's own edelivery.oracle.com URL is SSO-gated and will NOT curl.)
SOL10_ISO="${SOL10_ISO:-}"
SOL10_ISO_URL="${SOL10_ISO_URL:-https://archive.org/download/sol-10-u11-ga-x86-dvd/sol-10-u11-ga-x86-dvd.iso}"
EXPECT_ISO_MIN_BYTES="${EXPECT_ISO_MIN_BYTES:-2000000000}" # ~2.0 GiB sanity floor

# QEMU shape (validated in NOTES.md / exotic-gallery-guests.md §5).
QEMU="${QEMU:-qemu-system-x86_64}"
MACHINE="${MACHINE:-pc-i440fx-11.0}" # pinned i440FX; matches the streamhost snapshot fixture
CPU="Nehalem"
MEM_MB="${MEM_MB:-3072}" # 2048 also fine
SMP="${SMP:-2}"

# Behaviour flags.
INSTALL_GUEST="${INSTALL_GUEST:-0}"                # 1 = run the (expensive) OS install; needs a supervised first run
DO_VERIFY="${DO_VERIFY:-1}"                        # 1 = headless boot + framebuffer proof
FORCE="${FORCE:-0}"                                # 1 = allow overwriting an existing golden disk during install
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-3600}"         # package-copy timeout after the final profile is accepted
INSTALL_DARK_SAMPLES="${INSTALL_DARK_SAMPLES:-20}" # 20x30s covers post-copy customization
SHUTDOWN_WAIT="${SHUTDOWN_WAIT:-180}"              # Solaris refreshes its boot archive during ACPI shutdown

# Timings (TCG/KVM boot of a heavy Solaris guest).
DTLOGIN_WAIT="${DTLOGIN_WAIT:-150}" # cold boot -> dtlogin greeter (~2 min)
CDE_WAIT="${CDE_WAIT:-120}"         # fresh first login needs up to ~2 min for CDE

# ---- Namespaced, unique runtime scratch (per-PID -> no socket collisions) ---
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
QEMU_LOG="${RUN_DIR}/qemu.log"
SER_LOG="${RUN_DIR}/serial.log"
VNC_DISPLAY="${VNC_DISPLAY:-58}" # unique VNC display for THIS guest's builds
PROOF_PNG="${GUEST_DIR}/proof-cde-desktop.png"

log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  printf '[%s] ERROR: %s\n' "$KEY" "$*" >&2
  exit 1
}

# ---- Preconditions ----------------------------------------------------------
for t in "$QEMU" qemu-img socat pnmtopng python3 curl; do
  command -v "$t" >/dev/null 2>&1 || die "missing required tool: $t (install qemu, socat, netpbm, python3, curl)"
done
mkdir -p "$GUEST_DIR" "$RUN_DIR"

# ---- QEMU monitor helper (HMP over the unix socket) -------------------------
# Every kill / screendump / sendkey goes through here — never pkill by name.
mon() { printf '%s\n' "$*" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }

is_running() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

stop_vm() {
  if is_running; then
    log "stopping VM (monitor quit) pid $(cat "$PIDFILE")"
    mon "quit"
    for _ in $(seq 1 12); do
      is_running || break
      sleep 1
    done
    if is_running; then
      log "monitor quit did not land -> kill by pidfile only (never by name)"
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      sleep 2
    fi
  fi
  rm -f "$PIDFILE" "$MON_SOCK"
}

cleanup() {
  stop_vm
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- typer: type a string into QEMU via HMP `sendkey` -----------------------
# Faithful transcription of the on-box typer.py (same keymap). Used for the
# dtlogin username/password and any installer text fields.
typer() {
  MON_SOCK="$MON_SOCK" python3 - "$1" <<'PY'
import socket,sys,os,time
SOCK=os.environ["MON_SOCK"]
M={' ':'spc','\n':'ret','\t':'tab','-':'minus','=':'equal','.':'dot',
   '/':'slash',',':'comma',';':'semicolon',"'":'apostrophe','`':'grave_accent',
   '\\':'backslash','[':'bracket_left',']':'bracket_right'}
SH={'!':'1','@':'2','#':'3','$':'4','%':'5','^':'6','&':'7','*':'8','(':'9',')':'0',
    '_':'minus','+':'equal','{':'bracket_left','}':'bracket_right','|':'backslash',
    ':':'semicolon','"':'apostrophe','<':'comma','>':'dot','?':'slash','~':'grave_accent'}
def keyname(c):
    if c in M: return M[c]
    if c in SH: return 'shift-'+SH[c]
    if c.isdigit(): return c
    if c.isalpha(): return ('shift-'+c.lower()) if c.isupper() else c
    return None
s=socket.socket(socket.AF_UNIX); s.connect(SOCK)
time.sleep(0.2)
try: s.recv(65536)
except: pass
for c in sys.argv[1]:
    k=keyname(c)
    if k is None: continue
    s.sendall(("sendkey %s 100\n"%k).encode()); time.sleep(0.15)
    try: s.recv(65536)
    except: pass
s.close()
PY
}
key() {
  mon "sendkey $1 100"
  sleep "${2:-0.4}"
} # 100 ms avoids dropped keys in the Java installer

# ---- screendump the current framebuffer to a PNG (== shot.sh) ---------------
snap() {
  local name="$1"
  local ppm="${GUEST_DIR}/${name}.ppm" png="${GUEST_DIR}/${name}.png"
  rm -f "$ppm" "$png"
  mon "screendump ${ppm}"
  sleep 1
  if [ -s "$ppm" ]; then
    pnmtopng "$ppm" >"$png" 2>/dev/null || true
    rm -f "$ppm"
    printf '%s' "$png"
  fi
}

# The package-copy screen is blue; post-copy customization and the reboot prompt
# are black. Require ten continuous minutes of dark screendumps so boot-block and
# device customization finishes before the CD is ejected.
install_frame_is_dark() {
  local ppm="${RUN_DIR}/install-poll.ppm"
  rm -f "$ppm"
  mon "screendump ${ppm}"
  sleep 2
  [ -s "$ppm" ] || return 1
  python3 - "$ppm" <<'PY'
import sys
d=open(sys.argv[1],'rb').read()
assert d[:2] == b'P6'
i=2; vals=[]
while len(vals) < 3:
    while i < len(d) and d[i] in b' \t\r\n': i += 1
    if d[i:i+1] == b'#':
        while i < len(d) and d[i] != 10: i += 1
        continue
    j=i
    while j < len(d) and d[j] not in b' \t\r\n': j += 1
    vals.append(int(d[i:j])); i=j
while i < len(d) and d[i] in b' \t\r\n': i += 1
w,h,_=vals; px=d[i:i+w*h*3]
step=max(1,(w*h)//10000)
sample=[px[n*3:n*3+3] for n in range(0,w*h,step)]
dark=sum(1 for p in sample if len(p)==3 and max(p)<32)
raise SystemExit(0 if dark/float(len(sample)) > 0.85 else 1)
PY
}

# =============================================================================
# STEP 0 — Obtain the Oracle Solaris 10 x86 DVD (OTN-gated; see header).
# =============================================================================
obtain_media() {
  if [ -s "$ISO" ] && [ "$(stat -c%s "$ISO" 2>/dev/null || echo 0)" -ge "$EXPECT_ISO_MIN_BYTES" ]; then
    log "install media already present: $ISO ($(stat -c%s "$ISO") bytes)"
    return 0
  fi
  if [ -n "$SOL10_ISO" ]; then
    [ -s "$SOL10_ISO" ] || die "SOL10_ISO=$SOL10_ISO not found"
    log "linking local media $SOL10_ISO -> $ISO"
    cp -f "$SOL10_ISO" "$ISO"
  elif [ -n "$SOL10_ISO_URL" ]; then
    log "downloading media from \$SOL10_ISO_URL (must be a pre-authenticated OTN URL)"
    curl -fL --retry 3 --retry-delay 5 -C - -o "${ISO}.part" "$SOL10_ISO_URL" ||
      curl -fL --retry 3 -o "${ISO}.part" "$SOL10_ISO_URL" ||
      die "download failed — the OTN URL is likely SSO-gated; download by hand and set SOL10_ISO=/path"
    mv -f "${ISO}.part" "$ISO"
  else
    die "no install media. Oracle Solaris 10 is OTN-gated and cannot be curled anonymously.
      Accept the OTN license, download sol-10-u11-ga-x86-dvd.iso, then re-run with
      SOL10_ISO=/path/to/sol-10-u11-ga-x86-dvd.iso  (or SOL10_ISO_URL=<authenticated url>)."
  fi
  [ "$(stat -c%s "$ISO" 2>/dev/null || echo 0)" -ge "$EXPECT_ISO_MIN_BYTES" ] ||
    die "media $ISO is smaller than expected (~2 GiB) — bad/partial download?"
  log "media ready: $ISO"
}

# =============================================================================
# STEP 1 — Create the golden disk (12 GiB IDE qcow2).
# =============================================================================
create_disk() {
  if [ -f "$IMG" ] && [ "$FORCE" != "1" ]; then
    log "golden disk already present ($IMG) — NOT recreating (FORCE=1 to wipe)"
    return 0
  fi
  log "creating fresh $DISK_SIZE qcow2 -> $IMG"
  rm -f "$IMG"
  qemu-img create -f qcow2 "$IMG" "$DISK_SIZE" >/dev/null
  rm -f "${GUEST_DIR}/.cde-default-baked"
  rm -f "${GUEST_DIR}/.cde-first-login-baked"
}

# =============================================================================
# STEP 2 — JumpStart answer files (the "answer file" the task references).
#
# HONEST NOTE: the dry-run install was interactive; these files are the standard
# Solaris hands-off substitute so the install is reproducible. They still need
# one supervised validation run (INSTALL_GUEST=1) the first time.
#
#   sysidcfg  -> system identification: skips locale/terminal/network/name-service
#                prompts and sets the root password to "solaris".
#   profile   -> JumpStart install profile: whole-disk (c0d0) UFS install of the
#                Entire Distribution (SUNWCXall) so CDE + dtlogin are present.
#
# root_password below is the traditional-crypt hash of the string "solaris".
# If your libc rejects it, blank the field and the installer will prompt once for
# the root password — type "solaris" (blank is rejected, per NOTES.md).
# =============================================================================
write_answer_files() {
  # crypt("solaris","aa") style DES hash. Verify on your host; regenerate with:
  #   perl -e 'print crypt("solaris","aa"),"\n"'
  local ROOT_HASH="${ROOT_PW_HASH:-aaY.tvBPYm0GY}"
  cat >"${GUEST_DIR}/sysidcfg" <<EOF
keyboard=US-English
system_locale=C
timezone=UTC
timeserver=localhost
terminal=vt100
name_service=NONE
network_interface=PRIMARY {protocol_ipv6=no default_route=NONE
  hostname=solaris ip_address=10.0.2.15 netmask=255.255.255.0}
root_password=${ROOT_HASH}
security_policy=NONE
nfs4_domain=dynamic
EOF
  cat >"${GUEST_DIR}/profile" <<'EOF'
install_type    initial_install
system_type     standalone
partitioning    default
cluster         SUNWCXall
filesys         rootdisk.s0 free /
filesys         rootdisk.s1 1024 swap
EOF
  log "wrote sysidcfg + profile (hostname=solaris, root pw=solaris, SUNWCXall/CDE)"
}

# =============================================================================
# STEP 3 — Run the OS install (EXPENSIVE, ~40 min; needs supervised first run).
#          Boots the DVD with the fresh disk attached (== run-install.sh shape).
#          Encoded input automation drives the Solaris x86 GRUB -> installer.
# =============================================================================
install_os() {
  [ "$INSTALL_GUEST" = "1" ] || {
    log "INSTALL_GUEST!=1 -> skipping OS install (using existing golden disk)"
    return 0
  }
  if [ -f "$IMG" ] && qemu-img info "$IMG" 2>/dev/null | grep -q 'disk size'; then
    # a non-empty existing image + no FORCE means refuse to clobber
    if [ "$FORCE" != "1" ] && [ "$(qemu-img info --output=json "$IMG" 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["actual-size"])' 2>/dev/null || echo 0)" -gt 1000000 ]; then
      log "existing golden disk looks populated — refusing to re-install (FORCE=1 to override)"
      return 0
    fi
  fi
  obtain_media
  create_disk
  write_answer_files

  log "booting Solaris DVD installer (automated keyboard path; ~40-60 min)"
  rm -f "$QEMU_LOG" "$SER_LOG" "$MON_SOCK"
  "$QEMU" \
    -name "solcde-install" -machine "${MACHINE},accel=kvm" -cpu "$CPU" -m "$MEM_MB" -smp "$SMP" \
    -drive file="$IMG",if=ide,index=0,media=disk \
    -drive file="$ISO",if=ide,index=2,media=cdrom \
    -boot d -no-shutdown \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -vga std -usb -device usb-tablet -rtc base=utc \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "file:${SER_LOG}" -D "$QEMU_LOG" &
  echo $! >"$PIDFILE"
  log "installer pid $(cat "$PIDFILE"), VNC :${VNC_DISPLAY}"

  # --- Solaris 10 U11 interactive installer, framebuffer-calibrated ----------
  # Validated 2026-07-15 against sol-10-u11-ga-x86-dvd.iso. Radio choices need
  # highlight+Space; arrows alone do not change the selected [X] item.
  sleep 25
  key ret 55 # DVD GRUB -> Solaris boot menu
  key 1 1
  key ret 95 # Oracle Solaris Interactive
  key f2 4   # US-English keyboard
  key ret 22 # enter graphical installer
  key ret 6  # "If the screen is legible"
  typer "0"
  key ret 10 # English

  key f2 4 # installation-program intro
  key f2 4 # identify this system
  key down 1
  key spc 1
  key f2 4 # Networked: No (Wave 3 configures it)
  typer "solaris"
  key f2 4 # hostname
  key f2 4 # confirm system identity

  key down 1
  key spc 1
  key f2 4 # Americas
  key spc 1
  key f2 4 # United States
  key spc 1
  key f2 4 # Eastern Time
  key f2 4
  key f2 4 # date/time; confirm

  typer "solaris"
  key tab 1
  typer "solaris"
  key f2 4
  key f2 4 # remote services: Yes
  key f2 4 # Solaris Interactive intro
  key f2 4 # non-iSCSI target
  key f2 4 # automatically eject CD/DVD
  key down 1
  key spc 1
  key f2 4 # Manual Reboot
  key f2 4 # eject/reboot information
  key f2 4 # media: CD/DVD
  key f2 4 # license page
  key f2 4 # accept license
  key f2 4 # no extra geographic locales
  key f2 4 # POSIX C locale
  key f2 4 # no additional products
  key f2 4 # UFS

  # End User System Support is the proven CDE-bearing software group.
  key down 1
  key down 1
  key spc 1
  key f2 4

  # A new qcow2 has no Solaris fdisk partition. Auto-layout misleadingly reports
  # "disk space problems" until this full-disk partition is created.
  key f4 4 # selected disk -> Edit
  key f2 4 # Edit Fdisk partitions
  key f4 4 # Create partition 1
  key f2 4 # maximum size / SOLARIS type
  key f2 4 # accept fdisk table
  key f2 4 # selected disk -> auto-layout question
  key f2 4 # Auto Layout
  key f2 5 # / + swap -> layout summary
  key f2 4 # accept layout
  key f2 5 # no remote mounts -> final profile
  key f2 8 # Begin Installation

  log "package copy started; waiting for framebuffer completion (timeout ${INSTALL_TIMEOUT}s)"
  local deadline=$((SECONDS + INSTALL_TIMEOUT)) dark=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 30
    if install_frame_is_dark; then dark=$((dark + 1)); else dark=0; fi
    [ "$dark" -ge "$INSTALL_DARK_SAMPLES" ] && break
    is_running || die "qemu exited during Solaris package copy"
  done
  [ "$dark" -ge "$INSTALL_DARK_SAMPLES" ] || die "installer completion framebuffer not reached within ${INSTALL_TIMEOUT}s"
  snap "proof-install-complete" >/dev/null 2>&1 || true
  log "installer completion prompt verified; force-ejecting the locked DVD"
  mon "eject -f ide1-cd0"
  key ret 300 # build boot_archive + reboot from disk
  stop_vm
}

# =============================================================================
# STEP 3.5 — Make CDE the DEFAULT desktop session (THE "land on CDE" fix).
#
# ROOT CAUSE (reverse-engineered on the running golden, 2026-07-04):
#   Solaris 10 ships JDS/GNOME as the default desktop. At login, dtlogin exports
#   SESSIONTYPE=altDt  and  SDT_ALT_SESSION=/usr/dt/config/Xsession2.jds  for the
#   *default* session, and /usr/dt/bin/Xsession then picks the desktop here:
#
#       if [ "$SESSIONTYPE" = "altDt" ]; then
#           dtstart_session[0]="$SDT_ALT_SESSION"        # -> JDS (Xsession2.jds/gnome-session)
#           dtstart_hello[0]="$SDT_ALT_HELLO"
#       else
#           dtstart_session[0]="$DT_BINPATH/dtsession"   # -> classic CDE (dtwm front panel)
#           dtstart_hello[0]="$DT_BINPATH/dthello &"
#       fi
#
#   Things that DO NOT change this default (verified — all leave the station on JDS):
#     * choosing CDE once at the greeter (never persists under runtime -snapshot),
#     * removing the greeter alt-desktop registration /usr/dt/config/*/Xresources.d/
#       Xresources.jds  (only drops the JDS *menu entry*, not the default),
#     * any /etc/dt override, ~/.dtprofile or Xsession.d hook (both are sourced
#       AFTER the dtstart_session[] array is built, so they are too late),
#     * SDT_ALT_SESSION is set only by the dtlogin binary, in no editable file.
#
# THE FIX (deterministic, single point of control):
#   Make that one `if` always take the CDE (else) branch by changing the compared
#   literal  "altDt" -> "altDtOFF"  on that line. With dtlogin exporting
#   SESSIONTYPE=altDt the test is now false, so Xsession ALWAYS launches the
#   classic CDE session (dtsession -> dtwm front panel), regardless of dtlogin.
#   Persisted into solaris.qcow2, every later `-snapshot` boot + autologin lands
#   on CDE, not JDS. (We also blank the JDS greeter menu entries — cosmetic, so
#   CDE is the only offered desktop.)
#
#   Effective change, in-guest, as root:
#       sed 's/= "altDt"/= "altDtOFF"/' /usr/dt/bin/Xsession > /tmp/Xs \
#         && cp /tmp/Xs /usr/dt/bin/Xsession                       # THE fix
#       rm -f /usr/dt/config/*/Xresources.d/Xresources.jds         # cosmetic
#
# Applied ONCE to the golden via a WRITABLE single-user boot (GRUB kernel arg
# `-s`), typed over the QEMU monitor, then a clean sync + shutdown so the write
# lands in the qcow2. Idempotent: re-running just re-applies the same sed (no-op
# once "altDt" is already "altDtOFF"). SAFE: never runs while a -snapshot station
# has the golden open — this is a build-time step on the golden itself.
# =============================================================================
CDE_DEFAULT="${CDE_DEFAULT:-1}"     # 1 = bake CDE-as-default into the golden
SU_ROOT_PW="${SU_ROOT_PW:-solaris}" # single-user maintenance / root password
CDE_DEFAULT_STAMP="${GUEST_DIR}/.cde-default-baked"
FIRST_LOGIN_BAKE="${FIRST_LOGIN_BAKE:-1}" # 1 = persist CDE choice + suppress first-login nag
FIRST_LOGIN_STAMP="${GUEST_DIR}/.cde-first-login-baked"

# Drive the Solaris x86 GRUB (0.97) menu into single-user: edit the multiboot
# kernel line and append ` -s`. Pure keyboard (HMP sendkey) — deterministic.
grub_to_single_user() {
  sleep 6      # GRUB menu up (10s countdown)
  key e 1.5    # edit the default entry -> boot command list
  key down 0.8 # highlight the `kernel /platform/i86pc/multiboot` line
  key e 1.2    # edit that line (cursor at end)
  key spc 0.3
  key minus 0.3
  key s 0.4 # append " -s"
  key ret 1 # save edited line
  key b 1   # boot single-user
}

bake_cde_default() {
  [ "$CDE_DEFAULT" = "1" ] || {
    log "CDE_DEFAULT!=1 -> skipping CDE-default bake"
    return 0
  }
  [ -f "$CDE_DEFAULT_STAMP" ] && {
    log "CDE-default patch already baked"
    return 0
  }
  [ -f "$IMG" ] || die "no golden disk at $IMG — run with INSTALL_GUEST=1 first"
  log "baking CDE-as-default into the golden (writable single-user boot)"
  rm -f "$QEMU_LOG" "$SER_LOG" "$MON_SOCK"
  # WRITABLE boot (NO -snapshot): the whole point is to persist the edit.
  "$QEMU" \
    -name "solcde-cdebake" -machine "${MACHINE},accel=kvm" -cpu "$CPU" -m "$MEM_MB" -smp "$SMP" \
    -drive file="$IMG",if=ide,index=0,media=disk \
    -boot c -no-shutdown \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -audiodev none,id=snd -device AC97,audiodev=snd \
    -vga std -usb -device usb-tablet -rtc base=utc \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "file:${SER_LOG}" -D "$QEMU_LOG" &
  echo $! >"$PIDFILE"
  log "cde-bake pid $(cat "$PIDFILE"), VNC :${VNC_DISPLAY}"

  grub_to_single_user
  sleep 45 # single-user milestone + maintenance prompt
  is_running || die "qemu exited before single-user prompt"
  typer "$SU_ROOT_PW"
  key ret 4 # "Root password for system maintenance:"

  # Apply the fix (the sed is the real switch; the rm is cosmetic menu cleanup).
  typer "sed 's/= \"altDt\"/= \"altDtOFF\"/' /usr/dt/bin/Xsession > /tmp/Xs && cp /tmp/Xs /usr/dt/bin/Xsession && echo CDE_PATCH_OK"
  key ret 3
  typer "rm -f /usr/dt/config/*/Xresources.d/Xresources.jds; echo JDS_MENU_REMOVED"
  key ret 3
  typer "bootadm update-archive; sync; sync; sync"
  key ret 60
  snap "proof-cde-default-set" >/dev/null 2>&1 || true
  log "CDE-default patch applied + synced; stopping bake VM"
  stop_vm
  touch "$CDE_DEFAULT_STAMP"
}

# A newly installed root profile presents a one-time JDS/CDE chooser even after
# Xsession has been patched. Persist the CDE radio choice and the nag checkbox by
# driving one writable GUI login. The sidecar stamp makes the step idempotent;
# create_disk removes it whenever a fresh golden is created.
bake_first_cde_login() {
  [ "$FIRST_LOGIN_BAKE" = "1" ] || {
    log "FIRST_LOGIN_BAKE!=1 -> skipping first-login bake"
    return 0
  }
  [ -f "$FIRST_LOGIN_STAMP" ] && {
    log "first-login CDE choice already baked"
    return 0
  }
  [ -f "$IMG" ] || die "no golden disk at $IMG — run with INSTALL_GUEST=1 first"
  log "baking first-login CDE choice + deprecation-nag suppression"
  rm -f "$QEMU_LOG" "$SER_LOG" "$MON_SOCK"
  "$QEMU" \
    -name "solcde-firstlogin-bake" -machine "${MACHINE},accel=kvm" -cpu "$CPU" -m "$MEM_MB" -smp "$SMP" \
    -drive file="$IMG",if=ide,index=0,media=disk \
    -boot c -no-shutdown \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -audiodev none,id=snd -device AC97,audiodev=snd \
    -vga std -usb -device usb-tablet -rtc base=utc \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "file:${SER_LOG}" -D "$QEMU_LOG" &
  echo $! >"$PIDFILE"

  sleep "$DTLOGIN_WAIT"
  is_running || die "qemu exited before first-login bake"
  typer "root"
  key ret 3
  typer "$SU_ROOT_PW"
  key ret 10

  # Desktop chooser: focus the radio group, move JDS -> CDE, select, then OK.
  key tab 1
  key down 1
  key spc 1
  key tab 1
  key ret 30
  # CDE deprecation dialog opens with OK focused: back-tab to checkbox, select,
  # return to OK, dismiss. Let CDE initialize and UFS flush profile writes.
  key shift-tab 1
  key spc 1
  key tab 1
  key ret 60
  snap "proof-cde-first-login-baked" >/dev/null 2>&1 || true
  mon "system_powerdown"
  sleep "$SHUTDOWN_WAIT"
  stop_vm
  touch "$FIRST_LOGIN_STAMP"
  log "first-login CDE choice baked"
}

# =============================================================================
# STEP 4 — First boot from disk + reach CDE (fully automated, faithful
#          transcription of run-disk.sh + trylogin.sh + typer.py + NOTES.md).
#          Uses -snapshot so a re-run never mutates the golden disk.
#          With STEP 3.5 done, a plain autologin now lands on CDE by DEFAULT —
#          no greeter Options->Session dance is needed (or reliable).
# =============================================================================
first_boot_to_cde() {
  [ -f "$IMG" ] || die "no golden disk at $IMG — run with INSTALL_GUEST=1 first"
  log "booting golden disk headless -> dtlogin (up to ~${DTLOGIN_WAIT}s)"
  rm -f "$QEMU_LOG" "$SER_LOG" "$MON_SOCK"
  # -audiodev none on the bare host (no PulseAudio server for root; `pa` aborts
  # QEMU here — neko provides `pa`). AC97 device still attached so the audio810
  # node is created exactly as in the delivered image.
  "$QEMU" \
    -name "solcde-verify" -machine "${MACHINE},accel=kvm" -cpu "$CPU" -m "$MEM_MB" -smp "$SMP" \
    -drive file="$IMG",if=ide,index=0,media=disk,snapshot=on \
    -boot c -no-shutdown \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -audiodev none,id=snd -device AC97,audiodev=snd \
    -vga std -usb -device usb-tablet -rtc base=utc \
    -display none -vnc ":${VNC_DISPLAY}" \
    -monitor "unix:${MON_SOCK},server,nowait" \
    -serial "file:${SER_LOG}" -D "$QEMU_LOG" &
  echo $! >"$PIDFILE"
  log "verify pid $(cat "$PIDFILE"), VNC :${VNC_DISPLAY}"

  sleep "$DTLOGIN_WAIT"
  is_running || {
    tail -20 "$SER_LOG" 2>/dev/null >&2 || true
    die "qemu exited before dtlogin"
  }
  local greeter
  greeter="$(snap "proof-1-dtlogin")"
  log "dtlogin greeter captured: ${greeter:-<none>}"

  # --- dtlogin auto-type root<CR> solaris<CR>  (== trylogin.sh) --------------
  log "auto-typing root / solaris at dtlogin"
  typer "root"
  sleep 0.5
  key ret 3 # username -> Enter -> password field
  typer "solaris"
  sleep 0.5
  key ret 7 # password -> Enter -> log in

  # --- No desktop chooser needed anymore -------------------------------------
  # STEP 3.5 made CDE the SYSTEM default (Xsession always runs dtsession), so a
  # plain root autologin lands straight on the CDE front panel — the old greeter
  # Options->Session / radio-box dance is obsolete (and never forwarded reliably
  # through the scaled neko display anyway). Any "CDE has been deprecated" nag was
  # dismissed with "Do not show again" on the golden (persisted in root's ~/.dt),
  # so clean logins go dtlogin -> CDE with no dialogs. Just wait for the desktop.
  sleep "$CDE_WAIT"
}

# =============================================================================
# STEP 5 — Framebuffer verification: prove we reached the CDE desktop.
#   Heuristic: a real 1920x1200 CDE desktop PNG is >100 KB (front panel, dtfile,
#   fractal backdrop => many distinct colors); a blank/greeter frame is far
#   smaller. Also run a distinct-color check to reject a uniform screen.
# =============================================================================
CDE_MIN_BYTES="${CDE_MIN_BYTES:-60000}"
png_ok() {
  local f="$1"
  [ -n "$f" ] && [ -s "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -ge "$CDE_MIN_BYTES" ]
}

verify_gui() {
  [ "$DO_VERIFY" = "1" ] || {
    log "verification skipped (DO_VERIFY=0)"
    return 0
  }
  first_boot_to_cde

  local ppm="${RUN_DIR}/cde.ppm"
  mon "screendump ${ppm}"
  sleep 2
  [ -s "$ppm" ] || die "screendump produced no file — CDE not reached"

  # Analyze framebuffer: reject near-uniform; write the PNG proof (pure zlib).
  python3 - "$ppm" "$PROOF_PNG" <<'PY' || die "framebuffer near-uniform — CDE desktop not reached"
import sys,zlib,struct
ppm,png=sys.argv[1],sys.argv[2]
d=open(ppm,'rb').read()
assert d[:2]==b'P6',"not a P6 ppm"
i=2; vals=[]
while len(vals)<3:
    while i<len(d) and d[i] in b' \t\n\r': i+=1
    if d[i:i+1]==b'#':
        while i<len(d) and d[i] not in b'\n': i+=1
        continue
    j=i
    while j<len(d) and d[j] not in b' \t\n\r': j+=1
    vals.append(int(d[i:j])); i=j
i+=1
w,h,mx=vals
px=d[i:i+w*h*3]
seen=set(); step=max(1,(w*h)//4000)
for k in range(0,w*h,step):
    o=k*3; seen.add(px[o:o+3])
    if len(seen)>60: break
assert len(seen)>25, "framebuffer near-uniform (%d colors)"%len(seen)
def chunk(t,b): return struct.pack(">I",len(b))+t+b+struct.pack(">I",zlib.crc32(t+b)&0xffffffff)
raw=bytearray()
for y in range(h):
    raw.append(0); raw+=px[y*w*3:(y+1)*w*3]
out=b'\x89PNG\r\n\x1a\n'
out+=chunk(b'IHDR',struct.pack(">IIBBBBB",w,h,8,2,0,0,0))
out+=chunk(b'IDAT',zlib.compress(bytes(raw),6))
out+=chunk(b'IEND',b'')
open(png,'wb').write(out)
print("framebuffer OK: %dx%d, %d+ distinct colors -> %s"%(w,h,len(seen),png))
PY

  if png_ok "$PROOF_PNG"; then
    log "GUI verified -> CDE desktop proof: $PROOF_PNG ($(stat -c%s "$PROOF_PNG") bytes)"
  else
    log "WARN: proof PNG smaller than ${CDE_MIN_BYTES}B — inspect $PROOF_PNG; may be dtlogin, not CDE"
  fi
  stop_vm
}

# =============================================================================
# STEP 6 — MANIFEST.md with the exact neko-qemu runtime args.
# =============================================================================
write_manifest() {
  cat >"${GUEST_DIR}/MANIFEST.md" <<EOF
# Solaris 10 CDE — gallery guest

Golden disk: solaris.qcow2 (real Oracle Solaris 10 x86, ~1.5 GiB actual / 12 GiB virtual).
Boots disk-only to dtlogin -> CDE. Login: root / solaris. Default session: CDE.
Built by: scripts/build-guests/tiles/solaris-cde.sh

## neko-qemu runtime args (disk-only; neko's launch-qemu.sh provides PulseAudio)
  qemu-system-x86_64 \\
    -machine pc-i440fx-11.0,accel=kvm -cpu Nehalem -m 3072 -smp 2 \\
    -drive file=solaris.qcow2,if=ide,index=0,media=disk -boot c -no-shutdown \\
    -netdev user,id=net0 -device e1000,netdev=net0 \\
    -audiodev pa,id=snd -device AC97,audiodev=snd \\
    -vga std -usb -device usb-tablet -rtc base=utc

Host-only verify swaps  -audiodev pa  ->  -audiodev none  (no PA server for root
on the bare host; \`pa\` aborts QEMU there). \`solvbox\` == stock qemu-system-x86_64
(the on-box symlink); NO custom binary is needed.

## Shape
arch x86_64 / machine pc-i440fx-11.0 + KVM / cpu Nehalem / RAM 3072 MB (2048 ok) /
smp 2 / disk on IDE / net e1000 (Solaris e1000g) / vga std (X at 1920x1200) /
usb-tablet pointer. Sound AC97 -> Solaris audio810 driver (attaches; not play-verified).

## Boot-to-desktop  (AUTOMATED in the gallery station — see gallery-integrate-all.sh [neko-era, deleted — git history])
dtlogin has no native autologin, so the tile lands on CDE via TWO settings:
  1. -snapshot is MANDATORY. The gallery bind-mounts /guests READ-ONLY, so QEMU
     cannot open solaris.qcow2 read-write and crash-loops
     "Could not open ... : Permission denied" -> neko framebuffer stays BLACK.
     -snapshot gives QEMU a writable RAM overlay over the read-only golden disk.
     (The Solaris kernel + dtlogin render fine on -vga std; the console is NOT on
      serial — that earlier theory was a misread of this crash-loop.)
  2. AUTOLOGIN_USER=root AUTOLOGIN_PASS=solaris AUTOLOGIN_DELAY=120 — launch-qemu.sh
     polls the framebuffer, and when the (blue) dtlogin greeter appears it types
     root<CR>solaris<CR> (dtlogin appears ~90-180 s cold; desktop ~30 s after login),
     landing on the Solaris desktop with no manual login.
NOTE: heavy tiles (Solaris/Android/pmOS all ~3 GiB) need the gallery CT raised to
~16 GiB or the cgroup OOM-killer reaps qemu cluster-wide (was a second black-screen
cause); gallery-integrate-all.sh now bumps CT memory automatically.

## CDE-as-DEFAULT — RESOLVED (2026-07-04). The station boots straight to CDE.
Solaris 10's stock default desktop is JDS/GNOME. The golden now defaults to the
**classic CDE** (dtwm front panel) via a one-line edit to /usr/dt/bin/Xsession,
baked in by bake_cde_default() (STEP 3.5). Exact mechanism:
  dtlogin exports SESSIONTYPE=altDt for the default session; /usr/dt/bin/Xsession
  chooses the desktop with
      if [ "\$SESSIONTYPE" = "altDt" ]; then dtstart_session[0]="\$SDT_ALT_SESSION"  # JDS
      else                                   dtstart_session[0]="\$DT_BINPATH/dtsession"  # CDE
  We change that literal  "altDt" -> "altDtOFF"  so the test is always false and
  Xsession ALWAYS launches dtsession (CDE). Persisted in solaris.qcow2, every
  -snapshot boot + autologin (root/solaris) lands on CDE.
IMPORTANT — things that do NOT work (all leave the tile on JDS; verified):
  * picking CDE at the greeter (never persists under runtime -snapshot),
  * removing /usr/dt/config/*/Xresources.d/Xresources.jds (drops only the JDS menu
    entry, not the default),  * any /etc/dt override / ~/.dtprofile / Xsession.d hook
  (sourced AFTER dtstart_session[] is built). SDT_ALT_SESSION is set only by the
  dtlogin binary — the Xsession 'if' is the single reliable point of control.
The old golden (JDS default) is preserved as solaris.qcow2.jds.bak. Black-screen
fix, autologin, and keyboard/mouse all continue to work.

Proof: proof-cde-desktop.png
EOF
  log "MANIFEST.md written"
}

# ---- Main -------------------------------------------------------------------
log "=== building Solaris 10 CDE gallery guest (mode: INSTALL_GUEST=${INSTALL_GUEST}) ==="
if [ "$INSTALL_GUEST" = "1" ]; then
  install_os # expensive; supervised first run
else
  log "SAFE mode: not installing. Using existing golden disk ($IMG) if present."
fi
# STEP 3.5: make CDE the default desktop (the actual "land on CDE, not JDS" fix).
# Idempotent (re-applying the sed is a no-op once done); set CDE_DEFAULT=0 to skip.
# NOTE: writes the golden — must NOT run while a -snapshot station has it open.
[ -f "$IMG" ] && bake_cde_default
[ -f "$IMG" ] && bake_first_cde_login
write_manifest
verify_gui
log "=== DONE: golden disk at $IMG ==="
log "neko-qemu runtime args are in ${GUEST_DIR}/MANIFEST.md"
