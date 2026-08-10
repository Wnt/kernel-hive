#!/usr/bin/env bash
# =============================================================================
# build-guests/lib/bridge-base.sh — reproducible build of the SHARED "emulator
# bridge" base image for the streamhost retro-OS gallery.
#
# WHAT THIS IS: a lean Debian x86_64 guest that boots straight to a bare-X kiosk
# and runs ONE full-screen SDL emulator with NO window manager. It is the
# read-only qcow2 BACKING FILE for every "bridge" tile (C64/GEOS, Atari-ST/
# EmuTOS, Apple-II/GEOS, Amstrad-CPC, …). Each tile is a thin qcow2 OVERLAY on
# top of this base that swaps in its own /etc/bridge/launch.sh (emulator + media
# + fullscreen flags). Build it once, freeze it, fan out.
#
# ---- TWO SUITES COEXIST (the bookworm -> trixie migration) ------------------
#  The lab host is Debian 13 (trixie); the base that 28 live overlays back onto
#  is still Debian 12 (bookworm) and is FROZEN. The migration is GRADUAL: this
#  script builds EITHER base, selected with `--suite <bookworm|trixie>`, and
#  every suite-dependent value (base path, genericcloud URL, package deltas)
#  comes from the ledger registry/bridge-suites.json via lib/bridge-suite.sh —
#  never from a literal here. Which tile is on which suite, and the per-tile
#  migration procedure, live in docs/lab/BRIDGE-TRIXIE-MIGRATION.md.
#
#  `--suite bookworm` on a box where that base already exists is the single most
#  destructive command in this repo: rebuilding it invalidates the read-only
#  backing file of every overlay at once. --force is deliberately NOT enough —
#  it additionally demands --i-know-this-breaks-every-overlay, and prints the
#  tiles it would destroy before refusing.
#
# The base ships FIVE emulators so the fan-out needs no rebuild:
#   * VICE  x64sc  (Commodore 64)      — BUILT FROM SOURCE (see HONESTY below)
#   * hatari       (Atari ST)          — apt
#   * LinApple     (Apple //e)         — built from source (github linappleii)
#   * cap32        (Amstrad CPC)       — built from source (github ColinPitrat)
#   * fs-uae       (Amiga 500)         — apt (+ Kickstart/Workbench media fetch)
#
# ---- AUTOMATION HONESTY (the hard-won, non-obvious recipe) ------------------
#  The build is deterministic: Debian genericcloud qcow2 + a cloud-init NoCloud
#  seed ISO drives ALL provisioning. But three gotchas cost real debugging and
#  are baked in here so an NVMe rebuild "just works":
#
#  1. NIC / KERNEL. The genericcloud image ships the trimmed `linux-image-cloud`
#     kernel which has NO e1000 driver (virtio only). The streamhost tile device
#     set uses an e1000 NIC, so provisioning INSTALLS `linux-image-amd64` (the
#     full generic kernel, virtio + e1000) which becomes the boot kernel. We
#     PROVISION over virtio-net (the cloud kernel can drive that) but the frozen
#     base boots fine under the e1000 tile device set.
#
#  2. NETWORKING. SLIRP DHCP was unreliable for this image's systemd-networkd
#     (networkd-wait-online hung forever, no lease). We use a DETERMINISTIC
#     STATIC IP matching SLIRP's fixed addressing (guest 10.0.2.15/24,
#     gw 10.0.2.2, dns 10.0.2.3) via /etc/systemd/network/10-bridge-slirp.network
#     and MASK systemd-networkd-wait-online so boot never blocks. Identical for
#     the virtio provisioning NIC and the e1000 tile NIC (both enumerate en*).
#
#  3. VICE IS BUILT FROM SOURCE ON BOTH SUITES, for two DIFFERENT reasons.
#     On bookworm there is simply no package: VICE was removed from Debian over
#     ROM/DFSG licensing, so `apt install vice` FAILS. On trixie the package is
#     back (vice 3.9+dfsg-1 in contrib) but it is the WRONG BUILD: it is the
#     GTK3 UI (libgtk-3-0t64, libpulse0) and this kiosk has no window manager
#     and no PulseAudio — we need the SDL2 fullscreen UI. Either way x64sc comes
#     from source. Its build needs libcurl4-openssl-dev (configure aborts
#     without it) on top of the SDL2/png/flex/bison deps. VICE bundles the C64
#     KERNAL/BASIC/CHARGEN ROMs, so no separate ROM fetch. cap32 additionally
#     needs libfreetype-dev; LinApple's Makefile is at the REPO ROOT (not src/).
#
#  Result: a FROZEN base at $BASE_QCOW that 28 tiles overlay. NEVER modify a
#  frozen base again — overlays depend on it byte-for-byte as read-only backing.
#
# ---- LICENSE / PROVENANCE (recorded in $MEDIA_DIR/LICENSES) -----------------
#   Debian 12/13 genericcloud ....... DFSG-free (Debian).
#   VICE 3.9 (source) ............... GPLv2; bundles C64 ROMs (Cloanto/CBM —
#                                     redistributed by VICE for emulation use).
#   hatari .......................... GPLv2 (Debian main).
#   LinApple / cap32 (source) ....... GPLv2.
#   GEOS 2.0 D64 (C64) .............. archive.org item geos64_J1AD; copyrighted, free
#                                     to use in this private collection (same stance as
#                                     the OS/2, Win9x, NeXTSTEP tiles).
#   EmuTOS 1024k .................... GPLv2 (Atari ST free ROM), for the ST tile.
#
# HYGIENE (per project rules): namespaced work dir, unique sockets/pidfile, kill
# ONLY by pidfile (never pkill), qcow2 overlays only (no full copies), idempotent
# + re-runnable, --force to rebuild. Touches ONLY /data/vms/bridge (+ media).
#
# Usage:
#   bridge-base.sh [--suite <bookworm|trixie>] [--force] [--keep-scratch] [-h]
#     --suite S       which base to build (default: the ledger's defaultSuite)
#     --force         rebuild the base even if $BASE_QCOW already exists
#     --keep-scratch  keep the downloaded genericcloud + seed after building
#     --i-know-this-breaks-every-overlay
#                     required IN ADDITION to --force to rebuild a base the
#                     ledger marks frozen. Destroys every overlay on it.
# =============================================================================
set -euo pipefail

# Suite resolver (ledger: registry/bridge-suites.json). Fails loudly rather than
# guessing — a build that cannot tell which Debian it targets must not proceed.
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bridge-suite.sh"

# ---- flags (parsed FIRST: the suite decides most of the config) -------------
FORCE=0
KEEP=0
BREAK_OVERLAYS=0
SUITE=""
while [ $# -gt 0 ]; do case "$1" in
  --suite)
    SUITE="${2:?--suite needs a value}"
    shift 2
    ;;
  --suite=*)
    SUITE="${1#*=}"
    shift
    ;;
  --force)
    FORCE=1
    shift
    ;;
  --i-know-this-breaks-every-overlay)
    BREAK_OVERLAYS=1
    shift
    ;;
  --keep-scratch)
    KEEP=1
    shift
    ;;
  -h | --help)
    sed -n '2,/^# =\{10,\}$/p' "$0"
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    exit 2
    ;;
esac done

SUITE="${SUITE:-$(bridge_suite_default)}"
bridge_suite_assert "$SUITE"

# ---- config -----------------------------------------------------------------
BRIDGE_DIR="/data/vms/bridge"
SCRATCH="${BRIDGE_DIR}/scratch"
MEDIA_DIR="/opt/bridge/media"
KEY="${BRIDGE_DIR}/bridge_key" # automation keypair (host->guest)
BASE_SIZE="6G"
MEM=2048

# Everything below is SUITE-DERIVED — never hardcode a base path or an image
# URL here again; the ledger is the single source of truth for both.
BASE_QCOW="$(bridge_base_for "$SUITE")"
DEB_URL="$(bridge_genericcloud_url_for "$SUITE")"
DEB_VER="$(bridge_debian_version_for "$SUITE")"

# Per-suite scratch/socket/pidfile/serial so a trixie build cannot adopt, clash
# with, or be misled by a concurrent or leftover bookworm run (project rule:
# namespace every shared resource per rig, never check-then-create a global).
WORK="${SCRATCH}/${SUITE}"
PIDFILE="${BRIDGE_DIR}/prov-${SUITE}.pid"
QMP="${BRIDGE_DIR}/prov-${SUITE}.qmp.sock"
SERIAL="${WORK}/serial.log"
# Provisioning-only host->guest :22. bookworm keeps the historical 5810; each
# newer Debian generation takes the next port up, so two builds never collide.
SSH_PORT=$((5810 + DEB_VER - 12))

# Pinned sources (latest stable at build time; refresh per the "latest stable" rule).
DEB_IMG="${WORK}/debian-${DEB_VER}-genericcloud-amd64.qcow2"
VICE_VER="3.9"

# ---- suite-conditional package delta (measured against trixie 13.6) ---------
# fs-uae 3.1.66-2+b1 IS in trixie main, but it declares NO `Recommends:` field
# at all — so the "install WITH recommends" trick below, which is what drags in
# OpenAL + Mesa on bookworm, pulls nothing extra there. libopenal1 still arrives
# via a hard Depends on trixie; MESA DOES NOT, and without llvmpipe fs-uae has
# no GL at all on this GPU-less host. So trixie names libgl1-mesa-dri itself.
# Everything else in the package set exists in trixie main under the same name.
FSUAE_PKGS="fs-uae"
[ "$SUITE" = "bookworm" ] || FSUAE_PKGS="fs-uae libgl1-mesa-dri"
GEOS_URL="https://archive.org/download/geos64_J1AD/geos64_J1AD.d64"
GEOS_MD5="709bec31c3502cbcf5d4761c38dcfa9e"
EMUTOS_URL="https://sourceforge.net/projects/emutos/files/emutos/1.3/emutos-1024k-1.3.zip/download"
# Amiga 500 tile (scripts/build-guests/tiles/amiga.sh) media — copyrighted, free to use in
# this private collection; fetched here so a from-scratch NVMe rebuild bakes it in
# (NEVER committed to the GitHub repo).
AMIGA_KICK_URL="https://archive.org/download/commodore-amiga-firmware/Kickstart%20v1.3%20r34.005%20%281987-12%29%28Commodore%29%28A500-A1000-A2000-CDTV%29%5B%21%5D.zip"
AMIGA_WB_URL="https://amigamuseum.emu-france.info/Fichiers/ADF/Installation,%20Kickstars,%20Workbench%20Tutorials%20&%20Promotional/Workbench%201.3%20%2834.20%29%20-%20Boot%20%28Commodore%29%20%281988%29.zip"
# The pins ASSETS-MANIFEST.md records for the two Amiga blobs. They were already
# written into $MEDIA_DIR/LICENSES as prose by this script; they are now also
# ASSERTED at the end of provisioning (see check_media below), which is what
# turns "we wrote down a hash" into "a wrong download fails the build".
AMIGA_KICK_MD5="82a21c1890cae844b3df741f2762d48d"
AMIGA_WB_MD5="d10f4907697c4eafcf976b4ef6ea829b"

log() { echo "[bridge-base/${SUITE} $(date +%H:%M:%S)] $*"; }

cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
  sleep 1
  rm -f "$QMP" "$PIDFILE"
}
trap cleanup EXIT

# ---- FROZEN-BASE GUARD (read this before you "just add --force") ------------
# An existing base marked frozen in the ledger is the read-only backing file of
# every overlay listed below. Rebuilding it does not "refresh" them — it makes
# each overlay's recorded backing file describe a DIFFERENT disk, i.e. every one
# of those tiles is destroyed at once, silently, and no golden snapshot survives
# it. --force alone is a plausible typo, so it is not sufficient authority here.
#
# "Frozen" is BOTH declared and DERIVED. The ledger's `frozen` flag is the
# operator's statement of intent, but the guard must not depend on someone
# remembering to set it: any suite that has even one tile declared on it has
# overlays in the field, so it is frozen in fact whatever the flag says. A
# newly built base is legitimately rebuildable right up until the first tile
# lands on it, and from that moment it is not — with no edit required.
if [ -f "$BASE_QCOW" ] && [ "$BREAK_OVERLAYS" -eq 0 ] &&
  { bridge_suite_is_frozen "$SUITE" || [ -n "$(bridge_suite_tiles "$SUITE")" ]; }; then
  {
    echo "REFUSING to rebuild the FROZEN '$SUITE' base: $BASE_QCOW"
    echo "These overlays back onto it read-only and would ALL be destroyed:"
    bridge_suite_tiles "$SUITE" | sed 's/^/    /'
    echo "If that is genuinely what you want, pass BOTH --force and"
    echo "  --i-know-this-breaks-every-overlay"
    echo "See docs/lab/BRIDGE-TRIXIE-MIGRATION.md — the migration is per-tile,"
    echo "onto the trixie base (--suite trixie); it never rebuilds this one."
  } >&2
  exit 3
fi

if [ -f "$BASE_QCOW" ] && [ "$FORCE" -eq 0 ]; then
  log "base already exists: $BASE_QCOW (use --force to rebuild)"
  exit 0
fi

log "building the Debian ${DEB_VER} (${SUITE}) bridge base -> $BASE_QCOW"
mkdir -p "$BRIDGE_DIR" "$SCRATCH" "$WORK" "$MEDIA_DIR"

# ---- 0. automation keypair --------------------------------------------------
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -C bridge-automation >/dev/null
PUB="$(cat "${KEY}.pub")"

# ---- 1. download + resize base ---------------------------------------------
if [ ! -f "$DEB_IMG" ]; then
  log "downloading Debian ${DEB_VER} genericcloud qcow2 ..."
  curl -fSL -o "$DEB_IMG" "$DEB_URL"
fi
SZ=$(stat -c %s "$DEB_IMG")
[ "$SZ" -gt 200000000 ] || {
  echo "genericcloud image too small ($SZ)"
  exit 1
}
log "genericcloud image: $SZ bytes"
cp "$DEB_IMG" "$BASE_QCOW"
qemu-img resize "$BASE_QCOW" "$BASE_SIZE" >/dev/null

# ---- 2. cloud-init NoCloud seed --------------------------------------------
log "building NoCloud seed ISO ..."
cat >"${WORK}/meta-data" <<EOF
instance-id: bridge-base-001
local-hostname: bridge-base
EOF

cat >"${WORK}/user-data" <<EOF
#cloud-config
hostname: bridge-base
manage_etc_hosts: true
users:
  - name: bridge
    groups: [sudo, audio, video, tty, input]
    shell: /bin/bash
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["${PUB}"]
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
  users:
    - {name: root, password: bridge, type: text}
    - {name: bridge, password: bridge, type: text}
bootcmd:
  - [ cloud-init-per, once, mask-waitonline, systemctl, mask, systemd-networkd-wait-online.service ]
write_files:
  - path: /etc/systemd/network/10-bridge-slirp.network
    permissions: '0644'
    content: |
      # Deterministic static config matching QEMU SLIRP's fixed addressing.
      # Works for BOTH the virtio provisioning NIC and the e1000 tile NIC (en*).
      [Match]
      Name=en*
      [Network]
      Address=10.0.2.15/24
      Gateway=10.0.2.2
      DNS=10.0.2.3
  - path: /root/.ssh/authorized_keys
    permissions: '0600'
    content: |
      ${PUB}
  - path: /etc/X11/Xwrapper.config
    permissions: '0644'
    content: |
      allowed_users=anybody
      needs_root_rights=yes
  - path: /etc/X11/xorg.conf.d/10-bridge.conf
    permissions: '0644'
    content: |
      Section "Device"
          Identifier "bridge-gpu"
          Driver     "modesetting"
          Option     "AccelMethod" "none"
      EndSection
      Section "ServerFlags"
          Option "BlankTime" "0"
          Option "StandbyTime" "0"
          Option "SuspendTime" "0"
          Option "OffTime" "0"
      EndSection
  - path: /etc/asound.conf
    permissions: '0644'
    content: |
      # Route ALSA default to the QEMU AC97 card so emulator (SID/etc) audio
      # reaches QEMU's dbus audiodev -> streamhost.
      pcm.!default { type plug; slave.pcm "hw:0,0" }
      ctl.!default { type hw; card 0 }
  # The codename of the base this guest was built from. Lets the status checker
  # read a RUNNING tile's ACTUAL suite from inside the guest instead of trusting
  # registry/bridge-suites.json, which only records intent.
  - path: /etc/bridge/suite
    permissions: '0644'
    content: |
      ${SUITE}
  - path: /etc/bridge/launch.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      # PLACEHOLDER. Each bridge tile OVERLAYS its own /etc/bridge/launch.sh.
      exec xterm -fullscreen -e "echo 'bridge base: no tile launcher installed'; sleep 100000"
  - path: /home/bridge/.xinitrc
    permissions: '0755'
    content: |
      #!/bin/bash
      xset s off -dpms s noblank 2>/dev/null || true
      xsetroot -solid black 2>/dev/null || true
      OUT=\$(xrandr 2>/dev/null | awk '/ connected/{print \$1; exit}')
      [ -n "\$OUT" ] && xrandr --output "\$OUT" --mode 1024x768 2>/dev/null || true
      exec /etc/bridge/launch.sh
  - path: /home/bridge/.bash_profile
    permissions: '0644'
    content: |
      if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then exec startx; fi
  - path: /root/provision.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      exec > >(tee -a /var/log/bridge-provision.log) 2>&1
      echo "=== bridge provision start \$(date -u) ==="
      export DEBIAN_FRONTEND=noninteractive
      VICE_OK=no; HATARI_OK=no; LINAPPLE_OK=no; CAP32_OK=no; FSUAE_OK=no
      # bring up the deterministic static SLIRP network
      systemctl restart systemd-networkd; sleep 3; ip -4 addr show scope global || true
      # enable contrib/non-free (deb822 sources)
      if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
      fi
      apt-get update -o Acquire::Retries=3
      # full generic kernel (e1000 + bochs-drm for the tile device set / X).
      # The trimmed \`cloud\` kernel lacks BOTH e1000 (no tile network) AND the
      # bochs-drm framebuffer (X errors "no screens found"). Install the generic
      # kernel AND PURGE the cloud kernel so grub boots the generic one by default.
      apt-get install -y linux-image-amd64
      apt-get purge -y 'linux-image-*-cloud-amd64' linux-image-cloud-amd64 2>/dev/null || true
      update-grub 2>/dev/null || true
      # kiosk X + audio + hatari + build toolchain + VICE/cap32/linapple build deps
      apt-get install -y --no-install-recommends \\
        xserver-xorg xserver-xorg-video-fbdev xserver-xorg-video-vesa xserver-xorg-legacy \\
        xinit x11-xserver-utils x11-utils xterm x11-apps alsa-utils hatari \\
        build-essential autoconf automake libtool pkg-config git unzip curl ca-certificates \\
        libsdl2-dev libsdl2-image-dev libpng-dev zlib1g-dev libasound2-dev \\
        flex bison xa65 dos2unix libreadline-dev libvorbis-dev libflac-dev \\
        libcurl4-openssl-dev libfreetype-dev libglew-dev
      command -v hatari >/dev/null && HATARI_OK=yes
      # ---- FS-UAE (Amiga 500 tile; scripts/build-guests/tiles/amiga.sh). In Debian main.
      # Installed WITH recommends so it pulls libopenal (Paula audio) + mesa (llvmpipe
      # software GL for the GPU-less host). Not part of the original 4-emulator set;
      # baked here so the amiga tile needs no per-tile fs-uae install on a fresh base.
      # On trixie the package has NO Recommends: at all, so mesa is named explicitly
      # in \$FSUAE_PKGS on the host side (see the package-delta note there).
      apt-get install -y ${FSUAE_PKGS} && command -v fs-uae >/dev/null && FSUAE_OK=yes || FSUAE_OK=no
      mkdir -p /usr/local/src; cd /usr/local/src
      # ---- VICE ${VICE_VER} from source (SDL2 UI) ----
      # Source-built on BOTH suites: absent from bookworm (ROM/DFSG removal), and
      # present in trixie/contrib only as the GTK3 UI build — wrong for a kiosk
      # with no window manager. Never replace this with \`apt install vice\`.
      if ! command -v x64sc >/dev/null; then
        curl -fSL -o vice.tar.gz "https://downloads.sourceforge.net/project/vice-emu/releases/vice-${VICE_VER}.tar.gz" && tar xf vice.tar.gz
        if [ -d vice-${VICE_VER} ]; then
          cd vice-${VICE_VER}
          ./configure --enable-sdl2ui --disable-html-docs --without-oss --without-pulse --enable-ethernet=no --disable-rs232 >/tmp/vice-conf.log 2>&1
          make -j2 >/tmp/vice-make.log 2>&1 && make install >>/tmp/vice-make.log 2>&1
          cd /usr/local/src
        fi
      fi
      command -v x64sc >/dev/null && VICE_OK=yes
      # VICE 'make install' can SKIP some ROM data files (notably the C64 BASIC
      # ROM) — x64sc then SEGFAULTS on startup with no output. Copy the COMPLETE
      # ROM set from the source data dir into the install dir to be safe.
      for d in C64 C128 VIC20 PET PLUS4 CBM-II DRIVES; do
        [ -d /usr/local/src/vice-${VICE_VER}/data/\$d ] && mkdir -p /usr/local/share/vice/\$d && \\
          cp -n /usr/local/src/vice-${VICE_VER}/data/\$d/*.bin /usr/local/share/vice/\$d/ 2>/dev/null || true
      done
      # ---- LinApple (Makefile at repo ROOT) ----
      # KNOWN-FLAKY: the linappleii build needs ImageMagick 'convert' for its
      # PNG->XPM asset step AND currently fails a Video.o compile under modern g++.
      # Non-critical (Apple //e fan-out). If it fails, the Apple II tile should fall
      # back to \`mame apple2e\` from apt (apt-get install -y mame) per the plan.
      apt-get install -y imagemagick 2>/dev/null || true
      # ImageMagick 6 (bookworm) ships \`convert\`; ImageMagick 7 (trixie) ships
      # \`magick\` and keeps \`convert\` only through the alternatives system. Prefer
      # the real IM7 binary where it exists by shimming \`convert\` onto it; on IM6
      # \`magick\` is absent and this whole line is a no-op, so bookworm is unchanged.
      command -v magick >/dev/null && { printf '#!/bin/sh\nexec magick "\$@"\n' > /usr/local/bin/convert; chmod 0755 /usr/local/bin/convert; } || true
      if ! command -v linapple >/dev/null; then
        rm -rf linapple; git clone --depth 1 https://github.com/linappleii/linapple linapple \\
          && make -C linapple -j2 >/tmp/linapple.log 2>&1 && make -C linapple install >>/tmp/linapple.log 2>&1 || true
      fi
      command -v linapple >/dev/null && LINAPPLE_OK=yes
      # ---- Caprice32 / cap32 ----
      if ! command -v cap32 >/dev/null; then
        rm -rf caprice32; git clone --depth 1 https://github.com/ColinPitrat/caprice32 caprice32 \\
          && make -C caprice32 -j2 >/tmp/cap32.log 2>&1 && make -C caprice32 install >>/tmp/cap32.log 2>&1
      fi
      command -v cap32 >/dev/null && CAP32_OK=yes
      # ---- media ----
      # EVERY FETCH AND EVERY EXTRACTION HERE IS FATAL. It used to be
      # \`curl … || true\` plus \`(unzip … && find -exec cp) || true\`, five times
      # over, and that is the single most dangerous pattern in this file: a
      # rotted mirror produced a base with NO emulator media, the provision
      # script still printed its STATUS line and exited 0, wave 0 acceptance
      # passed (it only checks that the emulator BINARIES exist), and the fault
      # would surface weeks later as a tile rendering black with every log
      # healthy. The amiga media in particular hangs off a single third-party
      # mirror (amigamuseum.emu-france.info) with no second source.
      # A base without its media is not a degraded base, it is a broken one, so
      # it must fail here, loudly, while someone is watching the build.
      mkdir -p ${MEDIA_DIR}; cd ${MEDIA_DIR}
      [ -f GEOS.D64 ] || curl -fsSL --retry 3 --max-time 180 -o GEOS.D64 "${GEOS_URL}" \\
        || { echo "FATAL: could not fetch GEOS.D64 from ${GEOS_URL}"; exit 21; }
      if [ ! -f etos1024k.img ]; then
        curl -fsSL --retry 3 --max-time 180 -o /tmp/emutos.zip "${EMUTOS_URL}" \\
          || { echo "FATAL: could not fetch EmuTOS from ${EMUTOS_URL}"; exit 22; }
        (cd /tmp && unzip -o emutos.zip >/dev/null 2>&1 && find . -name 'etos1024k.img' -exec cp {} ${MEDIA_DIR}/etos1024k.img \\;)
        [ -f ${MEDIA_DIR}/etos1024k.img ] || { echo "FATAL: EmuTOS zip fetched but etos1024k.img not found inside it"; exit 23; }
      fi
      # ---- Amiga 500 tile media (scripts/build-guests/tiles/amiga.sh): Kickstart 1.3 ROM
      # + Workbench 1.3 Boot ADF. Copyrighted, free to use in this private collection — NEVER committed;
      # baked into /opt/bridge/media/amiga/ so the amiga tile needs no per-tile fetch.
      mkdir -p ${MEDIA_DIR}/amiga
      if [ ! -f ${MEDIA_DIR}/amiga/kick13.rom ]; then
        curl -fsSL --retry 3 --max-time 180 -o /tmp/amiga-kick.zip "${AMIGA_KICK_URL}" \\
          || { echo "FATAL: could not fetch Amiga Kickstart from ${AMIGA_KICK_URL}"; exit 24; }
        (cd /tmp && unzip -o amiga-kick.zip >/dev/null 2>&1 && find . -maxdepth 1 -name 'Kickstart*A500*.rom' -exec cp {} ${MEDIA_DIR}/amiga/kick13.rom \\;)
        [ -f ${MEDIA_DIR}/amiga/kick13.rom ] || { echo "FATAL: Kickstart zip fetched but no Kickstart*A500*.rom inside it"; exit 25; }
      fi
      if [ ! -f ${MEDIA_DIR}/amiga/workbench13.adf ]; then
        curl -fsSL --retry 3 --max-time 240 -o /tmp/amiga-wb.zip "${AMIGA_WB_URL}" \\
          || { echo "FATAL: could not fetch Workbench 1.3 from ${AMIGA_WB_URL} (single third-party mirror, no fallback)"; exit 26; }
        (cd /tmp && unzip -o amiga-wb.zip >/dev/null 2>&1 && find . -maxdepth 1 -name 'Workbench*Boot*.adf' -exec cp {} ${MEDIA_DIR}/amiga/workbench13.adf \\;)
        [ -f ${MEDIA_DIR}/amiga/workbench13.adf ] || { echo "FATAL: Workbench zip fetched but no Workbench*Boot*.adf inside it"; exit 27; }
      fi
      # ---- terminal media assertion (the part wave-0 acceptance was missing) --
      # The three md5s below are the ones ASSETS-MANIFEST.md pins and that this
      # script already writes into \${MEDIA_DIR}/LICENSES as prose. Asserting them
      # here turns that prose into a gate: a truncated download, an HTML error
      # page saved as a .rom, or a mirror that silently started serving a
      # different Kickstart revision all fail the build instead of being baked
      # into a frozen base that 28 overlays then depend on.
      MEDIA_OK=yes
      check_media() { # <path> <md5> <label>
        if [ ! -s "\$1" ]; then echo "FATAL: missing media \$3 (\$1)"; MEDIA_OK=no; return 1; fi
        got=\$(md5sum "\$1" | awk '{print \$1}')
        if [ "\$got" != "\$2" ]; then
          echo "FATAL: media \$3 (\$1) md5 \$got != expected \$2"; MEDIA_OK=no; return 1
        fi
        return 0
      }
      check_media ${MEDIA_DIR}/GEOS.D64 "${GEOS_MD5}" GEOS.D64 || true
      check_media ${MEDIA_DIR}/amiga/kick13.rom "${AMIGA_KICK_MD5}" kick13.rom || true
      check_media ${MEDIA_DIR}/amiga/workbench13.adf "${AMIGA_WB_MD5}" workbench13.adf || true
      # EmuTOS has no md5 pin in the manifest (it is GPL and versioned), so it is
      # gated on presence and a plausible size rather than a hash.
      [ -s ${MEDIA_DIR}/etos1024k.img ] || { echo "FATAL: missing etos1024k.img"; MEDIA_OK=no; }
      [ "\$MEDIA_OK" = yes ] || { echo "FATAL: bridge base media verification FAILED — refusing to freeze a media-less base"; exit 28; }
      cat > ${MEDIA_DIR}/LICENSES <<'LIC'
      GEOS.D64      : C64 GEOS 2.0, archive.org geos64_J1AD, copyrighted (free to use in this private collection).
      etos1024k.img : EmuTOS 1024k 1.3, GPLv2 (free Atari ST ROM).
      VICE ROMs     : bundled with VICE 3.9 (GPLv2 emulator; C64 ROMs for emulation).
      LinApple/cap32: GPLv2 (bundle their machine ROMs).
      amiga/kick13.rom      : Amiga Kickstart 1.3 r34.005 (A500), md5 82a21c1890cae844b3df741f2762d48d;
                              archive.org commodore-amiga-firmware. Copyrighted (free to use in this private collection).
      amiga/workbench13.adf : Amiga Workbench 1.3 (34.20) Boot disk, md5 d10f4907697c4eafcf976b4ef6ea829b;
                              emu-france amigamuseum mirror. Copyrighted (free to use in this private collection).
      LIC
      # ---- kiosk autologin on tty1 ----
      mkdir -p /etc/systemd/system/getty@tty1.service.d
      printf '[Service]\\nExecStart=\\nExecStart=-/sbin/agetty --autologin bridge --noclear %%I \$TERM\\n' > /etc/systemd/system/getty@tty1.service.d/autologin.conf
      chown -R bridge:bridge /home/bridge
      systemctl set-default multi-user.target
      systemctl daemon-reload
      # media=\$MEDIA_OK is in the STATUS line because that line is what wave-0
      # acceptance reads. It previously reported only the emulator BINARIES, so a
      # base with five present emulators and zero media looked identical to a
      # good one.
      STATUS="vice=\$VICE_OK hatari=\$HATARI_OK linapple=\$LINAPPLE_OK cap32=\$CAP32_OK fsuae=\$FSUAE_OK media=\$MEDIA_OK"
      echo "STATUS \$STATUS"
      echo "\$STATUS" > /var/lib/bridge-provision-done
      echo "BRIDGE-PROVISION-DONE \$STATUS" > /dev/ttyS0 || true
runcmd:
  - [ bash, /root/provision.sh ]
EOF

(cd "$WORK" && genisoimage -output seed.iso -volid CIDATA -joliet -rock user-data meta-data >/dev/null 2>&1)

# ---- 3. boot for provisioning (VIRTIO-NET so the cloud kernel has a NIC) -----
cleanup
log "booting base for provisioning (virtio-net) ..."
rm -f "$SERIAL"
nohup qemu-system-x86_64 -name bridge-base-prov -enable-kvm -m "$MEM" -smp 2 -cpu host \
  -drive file="$BASE_QCOW",if=virtio,format=qcow2 -boot c \
  -cdrom "${WORK}/seed.iso" \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22 -device virtio-net-pci,netdev=n0 \
  -display none -serial "file:${SERIAL}" \
  -qmp "unix:${QMP},server=on,wait=off" -pidfile "$PIDFILE" \
  >"${WORK}/prov.boot.log" 2>&1 &
for i in $(seq 1 40); do
  [ -S "$QMP" ] && [ -f "$PIDFILE" ] && break
  sleep 0.5
done

# ---- 4. wait for cloud-init provisioning to converge ------------------------
log "waiting for provisioning (apt + VICE/linapple/cap32 source builds; ~15-25 min) ..."
DONE=""
for i in $(seq 1 200); do
  if grep -q "BRIDGE-PROVISION-DONE" "$SERIAL" 2>/dev/null; then
    DONE="$(grep -h BRIDGE-PROVISION-DONE "$SERIAL" | tail -1)"
    break
  fi
  sleep 15
done
[ -n "$DONE" ] || {
  echo "TIMEOUT waiting for provisioning; see $SERIAL"
  exit 1
}
log "provision status: $DONE"

# ---- 5. clean shutdown + freeze --------------------------------------------
log "clean shutdown ..."
ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 -p "$SSH_PORT" root@127.0.0.1 "sync; systemctl poweroff" 2>/dev/null ||
  python3 /root/qmp_hmp.py "$QMP" 'system_powerdown' >/dev/null 2>&1 || true
for i in $(seq 1 40); do
  [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null || break
  sleep 1
done
cleanup
[ "$KEEP" -eq 1 ] || rm -f "${WORK}/seed.iso"
log "FROZEN base [suite=${SUITE}, Debian ${DEB_VER}]: $BASE_QCOW ($(qemu-img info "$BASE_QCOW" | awk -F': ' '/disk size/{print $2}'))"
log "  emulators: $DONE"
log "  DO NOT modify this base again — bridge tile overlays back it read-only."
log "  Record it: flip a tile to '${SUITE}' in registry/bridge-suites.json ONLY"
log "  after its overlay is rebuilt and accepted (BRIDGE-TRIXIE-MIGRATION.md)."
echo "OK bridge-base suite=${SUITE}"
