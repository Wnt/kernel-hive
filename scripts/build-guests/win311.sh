#!/usr/bin/env bash
###############################################################################
# build-guests/win311.sh — reproduce the Windows for Workgroups 3.11 gallery
#                          guest FROM SOURCE on a fresh Proxmox host.
#
# GUEST : Windows for Workgroups 3.11 + MS-DOS 6.22 (the "Win311" retro tile).
# TYPE  : PREBUILT-BASE + DISK INJECTION. There is NO free, automatable WfW/DOS
#         installer, so — exactly like the validated dry-run — this recipe does
#         NOT run Windows Setup. It consumes the community **rtts/win311**
#         prebuilt `hda.img` as the OS layer (MS-DOS 6.22 + WfW 3.11 with a
#         working TCP/IP-32 stack, Cirrus 1024x768 driver, ne2k NIC driver,
#         Netscape Navigator 3 / Mosaic / IE 3&5 already installed), then:
#           * patches C:\AUTOEXEC.BAT so exiting Windows drops to a DOS prompt
#             that advertises the games (instead of powering the VM off),
#           * adds a VISIBLE "Gallery Games" Program Manager group so a first-time
#             visitor can double-click to play — Solitaire + Minesweeper (already
#             on the base) plus a native 16-bit shareware game, Chris Pirih's 1991
#             "Ski" (the SkiFree ancestor), staged as C:\GAMES\SKI.EXE, and
#           * builds a SECOND FAT16 disk (D:) from scratch and stages the three
#             freely-redistributable shareware DOS games on it with launchers,
#           * cross-builds the Win16 serial pointer agent with OpenWatcom 1.9,
#             injects it as C:\AGENT.EXE, and registers it in WIN.INI load=, and
#           * cold-boots the emitted pinned-machine fixture and saves its
#             loadvm-compatible `golden` snapshot after framebuffer verification.
#
# WHAT THIS SCRIPT DOES (end to end, on a fresh host):
#   1. Re-DOWNLOAD the rtts/win311 base `hda.img` from its real URL (cached +
#      size-checked; -> C:  MS-DOS 6.22 + WfW 3.11).
#   2. Copy the base to the working hda.img and PATCH C:\AUTOEXEC.BAT
#      (preserve the original as C:\AUTOEXEC.RTT; drop `fdapm poweroff`; append
#      the "type DOOM, DUKE or QUAKE to play" tail + D: PATH).  <- exact input
#      automation the dry-run used, transcribed via mtools (no interactive step).
#   2b. PATCH C:\WINDOWS\SYSTEM.INI to use the CPU-rendered STANDARD VGA display
#      driver (display.drv=vga.drv, 386grabber=vga.3gr). The rtts base ships the
#      accelerated Cirrus 1024x768 driver, whose hardware text-blit path QEMU's
#      cirrus emulation does not implement -> icons render but ALL GUI TEXT is
#      BLANK. Standard VGA draws every glyph on the CPU, restoring all text.
#      (See the detailed root-cause note at step 2b in the body.)
#   3. CREATE the 64 MB D: disk from scratch: FAT16 filesystem (label GAMES),
#      wrapped in a DOS-partitioned raw image (partition @ sector 2048, type 06,
#      bootable) — byte-layout identical to the validated games.img.
#   4. Re-DOWNLOAD the three shareware ZIPs from archive.org (SHA-256 pinned).
#   5. INJECT the era games into D:\GAMES\{DOOM,DUKE3D,QUAKE} and write the root
#      launchers D:\DOOM.BAT / DUKE.BAT / QUAKE.BAT + D:\README.TXT (mtools).
#   6. Land the two bootable artifacts in data/gallery-guests/Win311/:
#         hda.img  (256 MB raw, C:)   games.img (64 MB raw, D:)
#   7. FRAMEBUFFER-VERIFY: boot headless under QEMU (unique VNC + monitor
#      socket), wait for the WfW 3.11 Program Manager desktop, `screendump` a
#      PNG and sanity-check it.
#
# AUTOMATION HONESTY:
#   * Steps 1-7 are FULLY AUTOMATED — zero keystrokes, zero VNC clicks. The
#     patched AUTOEXEC.BAT auto-runs `win`, so the guest boots straight to the
#     Program Manager desktop with no answer file / sendkey sequence needed.
#   * We deliberately do NOT install WfW from scratch: no free unattended DOS/
#     WfW installer exists, and the recipe (retro-gallery-guests.md) specifies
#     the rtts prebuilt base. That base is the ONLY non-self-authored input; its
#     internal MS binaries are copyrighted (free to use in this private collection)
#     and run behind the edge passkey.
#   * "Games staged, not auto-launched" is a RUNTIME gallery behaviour (visitor
#     exits Windows and types DOOM/DUKE/QUAKE), NOT a missing build step — the
#     build fully places the games + launchers.
#
# HYGIENE (per project rules):
#   * The verify VM is killed ONLY via its QEMU monitor `quit` (fallback: its
#     own pidfile). NEVER `pkill qemu*` — that would catch the live gallery
#     tiles, CT 110, VM 900/920 and the macOS fan-out VMs.
#   * Namespaced run dir + unique VNC display + unique monitor socket (per PID).
#   * Touches ONLY data/gallery-guests/Win311/ and the win311 tile fixture dir.
#     No other guest, CT or VM is modified.
#
# Idempotent + re-runnable: base image and ZIPs are cached-by-checksum and every
# output is rebuilt from those clean inputs. OpenWatcom embeds build metadata,
# so AGENT.EXE is source-reproducible but is not promised byte-identical.
###############################################################################
set -euo pipefail

# ------------------------------------------------------------------ parameters
KEY="win311"
DIR_NAME="Win311"

# Repo-local assets (prebuilt binaries that cannot be fetched/scripted).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSET_DIR="${SCRIPT_DIR}/assets/win311"
GALLERY_GRP_ASSET="${ASSET_DIR}/GALLERY.GRP" # Program Manager "Gallery Games" group
AGENT_SRC="${SCRIPT_DIR}/../../streamhost/guest-agents/win311/agent.c"
WATCOM_ROOT="${WATCOM:-/opt/watcom}"

# --- C: base image (rtts/win311 prebuilt WfW 3.11 + MS-DOS 6.22) -------------
# repo: https://github.com/rtts/win311  (256 MB raw, FAT16 @ sector 63, boot C:)
HDA_URL="https://rtts.eu/download/win311/hda.img"
HDA_SIZE_BYTES="268435456" # 256 MiB — cross-check the download
HDA_PART_OFFSET="32256"    # partition 1 starts at sector 63 (63*512)
# Upstream may re-roll the prebuilt base, so the base SHA is NOT hard-pinned by
# default. Set BASE_SHA256=<hash> to enforce a specific known-good base.
BASE_SHA256="${BASE_SHA256:-}"

# --- D: games disk geometry (matches the validated games.img exactly) --------
GAMES_TOTAL_MB="64"         # whole raw disk = 64 MiB
GAMES_PART_START="2048"     # partition 1 first sector
GAMES_PART_SECTORS="129024" # 63 MiB FAT16 partition (2048..131071)
GAMES_LABEL="GAMES"

# --- shareware game ZIPs (freely redistributable) — archive.org, SHA pinned --
DOOM_URL="https://archive.org/download/DoomsharewareEpisode/DoomV1.9sw1995idSoftwareInc.action.zip"
DOOM_SHA256="63ad7609f2e951fb2198f682e1226f003946c75c00b9785fa967ffb12c6745f7"
DOOM_ZIP="doom19.zip"

DUKE_URL="https://archive.org/download/3D_Realms_Duke_Nukem_3D_Shareware/3D%20Realms%20-%20Duke%20Nukem%203D%20%28Shareware%20Version%29.zip"
DUKE_SHA256="c7e380b2a2e3faed8b7008e3e1306b360405138ac7407cef2d3bb00b5663b65a"
DUKE_ZIP="duke3d.zip"

QUAKE_URL="https://archive.org/download/quakeshareware/QUAKE_SW.zip"
QUAKE_SHA256="b8e3e9c9f875dc6dda5ebdb9c2434bdfb3ece86c516089ebfe5c12106fffe7c1"
QUAKE_ZIP="quakesw.zip"

# --- native Win16 shareware game: "Ski" (Chris Pirih, 1991) — archive.org -----
# The self-contained shareware ancestor of SkiFree: a single 122 KB NE 16-bit
# Windows GUI executable that runs natively on WfW 3.11 (no DOS, no extender).
# Freely redistributable shareware. Staged as C:\GAMES\SKI.EXE and surfaced as a
# double-clickable Program Manager icon (see step 2c) so it launches from the
# desktop — unlike the DOS games on D:, which need an exit-to-DOS.
WINSKI_URL="https://archive.org/download/win3_WINSKI/WINSKI.ZIP"
WINSKI_SHA256="660beefbfffcb2321410124ea901c0d0195ebc1bada136a8730dc20ec6522058"
WINSKI_ZIP="winski.zip"

# Where the gallery keeps its guests (host dataset, bind-mounted into CT 110 as
# /opt/osgallery/guests-retro). Override GUESTS_ROOT to build elsewhere.
GUESTS_ROOT="${GUESTS_ROOT:-/data/gallery-guests}"
GUEST_DIR="${GUESTS_ROOT}/${DIR_NAME}"
DL_DIR="${GUEST_DIR}/dl"
HDA_BASE="${DL_DIR}/hda.base.img"  # pristine downloaded base (cache)
HDA_IMG="${GUEST_DIR}/hda.img"     # final C: artifact
GAMES_IMG="${GUEST_DIR}/games.img" # final D: artifact
FIXTURE_DIR="${WIN311_FIXTURE_DIR:-/data/vms/streamhost/tiles/win311}"
FIXTURE_C="${FIXTURE_DIR}/win311-golden.qcow2"
FIXTURE_D="${FIXTURE_DIR}/games-golden.qcow2"

# Verify-boot knobs
VERIFY="${VERIFY:-1}"            # VERIFY=0 to skip the framebuffer boot
VERIFY_WAIT="${VERIFY_WAIT:-90}" # WfW 3.11 under TCG needs ~60-90 s to desktop
QEMU_BIN="${QEMU_BIN:-qemu-system-i386}"

# Unique, namespaced runtime handles (never reused across concurrent builds)
RUN_DIR="${GUEST_DIR}/.build-run.$$"
MON_SOCK="${RUN_DIR}/mon.sock"
PIDFILE="${RUN_DIR}/qemu.pid"
VNC_DISP="${VNC_DISP:-62}" # VNC :62 -> tcp 5962; clear of gallery tiles
SHOT_PNG="${GUEST_DIR}/verify-desktop.png"

export MTOOLS_SKIP_CHECK=1 # let mtools work on partition-offset images
log() { printf '[%s] %s\n' "$KEY" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

###############################################################################
# The EXACT neko-qemu launch args this tile runs with in the live gallery.
# (from MANIFEST.md on the dry-run box; emitted here for reference + reuse)
#
#   qemu-system-i386 -machine pc -cpu pentium -m 64 \
#     -hda hda.img -hdb games.img -boot c \
#     -nic user,ipv6=off,model=ne2k_pci \
#     -device sb16 -vga cirrus -no-shutdown
#
# neko-qemu / launch-qemu.sh environment for this tile (retro-gallery-guests.md):
#   OS_NAME=Windows 3.11
#   QEMU_MACHINE=pc   QEMU_MEM=64   QEMU_VGA=cirrus
#   QEMU_SOUND="-device sb16"
#   GUEST_DISK=/guests-retro/Win311/hda.img  GUEST_FMT=raw  GUEST_IF=ide
#   GUEST_BOOT=c
#   QEMU_EXTRA="-cpu pentium
#               -drive file=/guests-retro/Win311/games.img,format=raw,if=ide,index=1
#               -nic user,ipv6=off,model=ne2k_pci -snapshot"
#   (Images are mounted read-only; -snapshot makes each visitor session
#    ephemeral. RAM 64M verified; <=128M OK; do NOT exceed ~256M — WfW chokes.
#    Baked NAT gateway is 192.0.2.20; QEMU user-net default is 10.0.2.2 —
#    change in Windows network settings if outbound browsing is required.)
#
# PERF: Win9x-under-KVM recipe APPLIED + framebuffer-verified (2026-07-04).
#   The live win311 tile now runs KVM-accelerated instead of TCG, via:
#     QEMU_MACHINE="pc,acpi=off,usb=off,kernel-irqchip=off,accel=kvm"
#     QEMU_VGA="std"   QEMU_SMP="1"   QEMU_EXTRA="-cpu pentium,-apic ..."
#   kernel-irqchip=off + -cpu pentium,-apic route the 8259/PIT in userspace so
#   IRQ0 ticks under KVM (else a Win9x delay loop freezes). -vga std is SAFE with
#   NO in-guest driver swap because step 2b below already forces the guest's
#   SYSTEM.INI to display.drv=vga.drv/386grabber=vga.3gr (the card-agnostic MS VGA
#   driver) — so unlike Win95, 3.11 needs no Cirrus->Standard golden swap.
#   Delivered as a compose override (scripts/tools/win311-perf-override.yml [neko-era, deleted — git history], mirror
#   at /opt/osgallery/win311-perf-override.yml on CT 110) to avoid touching the
#   sibling-managed shared compose; reconciliation should fold these four env
#   values into the win311 manifest row in gallery-integrate-all.sh [neko-era, deleted — git history]. Verified: KVM
#   engaged (/dev/kvm fd open), qemu ~10% of one core (not TCG-pegged), full
#   Program Manager desktop renders under -vga std, and injected Ctrl+Esc pops a
#   fully-painted Task List (input reaches the guest — no KVM hang). See
#   docs/guests/win9x.md for the root-cause + full recipe.
###############################################################################

need() { command -v "$1" >/dev/null 2>&1 || die "required tool '$1' not found"; }
for t in curl unzip mkfs.vfat mmd mcopy mattrib sfdisk dd sha256sum awk qemu-img file; do need "$t"; done
[[ -x "$WATCOM_ROOT/binl/wcl" ]] || die "OpenWatcom 1.9 wcl not found at $WATCOM_ROOT/binl/wcl"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
size_of() { wc -c <"$1" | tr -d ' '; }

# fetch <url> <dest> <sha256|""> <expected_size|"">  (cached-by-checksum)
fetch() {
  local url="$1" dest="$2" want_sha="$3" want_size="$4"
  if [[ -f "$dest" ]]; then
    if [[ -n "$want_sha" ]]; then
      [[ "$(sha_of "$dest")" == "$want_sha" ]] && {
        log "cached (sha ok): $(basename "$dest")"
        return 0
      }
      log "cache checksum mismatch, re-downloading $(basename "$dest")"
    elif [[ -n "$want_size" && "$(size_of "$dest")" == "$want_size" ]]; then
      log "cached (size ok): $(basename "$dest")"
      return 0
    fi
  fi
  local tmp="${dest}.part.$$"
  log "downloading $(basename "$dest") <- $url"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$url"
  if [[ -n "$want_sha" ]]; then
    local got
    got="$(sha_of "$tmp")"
    [[ "$got" == "$want_sha" ]] || {
      rm -f "$tmp"
      die "SHA-256 mismatch for $(basename "$dest") (got $got)"
    }
  fi
  if [[ -n "$want_size" ]]; then
    local gs
    gs="$(size_of "$tmp")"
    [[ "$gs" == "$want_size" ]] || log "WARN: $(basename "$dest") size $gs != expected $want_size"
  fi
  mv -f "$tmp" "$dest"
  log "downloaded ok: $(basename "$dest")"
}

# --------------------------------------------------------------- 0. workspace
mkdir -p "$GUEST_DIR" "$DL_DIR"

# ================================================================= 1. base C:
fetch "$HDA_URL" "$HDA_BASE" "$BASE_SHA256" "$HDA_SIZE_BYTES"

# ============================================== 2. build + patch the C: image
# Always rebuild from the pristine base so re-runs are deterministic and the
# AUTOEXEC patch is never applied twice.
log "assembling C: (hda.img) from base + AUTOEXEC patch"
cp -f "$HDA_BASE" "$HDA_IMG"

MTOOLSRC_C="${RUN_DIR}.mtoolsrc-c"
mkdir -p "$RUN_DIR"
printf 'drive c: file="%s" offset=%s\n' "$HDA_IMG" "$HDA_PART_OFFSET" >"$MTOOLSRC_C"

# Build the Win16 (NE) COM1 pointer agent with the pinned OpenWatcom 1.9. Win16
# headers are in h/win; the generic DOS/OS2 INCLUDE path cannot find windows.h.
AGENT_EXE="${RUN_DIR}/AGENT.EXE"
log "C: building Win16 serial agent with OpenWatcom 1.9"
(
  cd "$RUN_DIR"
  env WATCOM="$WATCOM_ROOT" \
    PATH="$WATCOM_ROOT/binl:$PATH" \
    INCLUDE="$WATCOM_ROOT/h/win:$WATCOM_ROOT/h" \
    wcl -q -bcl=windows -mc -fe="$AGENT_EXE" "$AGENT_SRC"
)
file "$AGENT_EXE" | grep -q 'NE .*MS Windows 3.00' || die "AGENT.EXE is not a Win16 NE executable"
log "C: agent built ($(size_of "$AGENT_EXE") bytes, sha256 $(sha_of "$AGENT_EXE"))"

orig_autoexec="${RUN_DIR}/AUTOEXEC.orig"
new_autoexec="${RUN_DIR}/AUTOEXEC.new"

# Pull the base AUTOEXEC.BAT (rtts original ends with `win` then `fdapm poweroff`)
MTOOLSRC="$MTOOLSRC_C" mcopy -n -o "c:/AUTOEXEC.BAT" "$orig_autoexec"

# Preserve the untouched original on-image as AUTOEXEC.RTT (idempotent overwrite)
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$orig_autoexec" "c:/AUTOEXEC.RTT"

# Transform: strip CR, drop the `fdapm poweroff` power-off line, append the
# games-advertising tail + D: PATH, then re-emit with DOS CRLF line endings.
# This yields byte-for-byte the AUTOEXEC.BAT captured on the validated build.
{
  tr -d '\r' <"$orig_autoexec" | grep -v -i '^[[:space:]]*fdapm[[:space:]]\+poweroff[[:space:]]*$'
  cat <<'TAIL'
PATH D:\;D:\GAMES;C:\MSBOB;C:\IE5;C:\WINDOWS;C:\DOS
ECHO.
ECHO Shareware DOS games on D: -- type DOOM, DUKE or QUAKE to play
ECHO.
TAIL
} | sed 's/$/\r/' >"$new_autoexec"

MTOOLSRC="$MTOOLSRC_C" mcopy -o "$new_autoexec" "c:/AUTOEXEC.BAT"
log "C: ready — AUTOEXEC.BAT patched, original saved as C:\\AUTOEXEC.RTT"

# Install and auto-start the serial pointer agent. The pristine base has an
# empty [windows] load= line; replacing that line is deterministic and starts
# the hidden Win16 app whenever AUTOEXEC.BAT launches Windows.
log "C: injecting C:\\AGENT.EXE and registering WIN.INI [windows] load="
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$AGENT_EXE" "c:/AGENT.EXE"
winini_orig="${RUN_DIR}/WIN.orig.ini"
winini_new="${RUN_DIR}/WIN.new.ini"
MTOOLSRC="$MTOOLSRC_C" mtype "c:/WINDOWS/WIN.INI" >"$winini_orig"
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$winini_orig" "c:/WINDOWS/WIN.RTT"
awk '
  BEGIN { in_windows=0; replaced=0 }
  {
    line=$0; sub(/\r$/, "", line)
    if (line ~ /^\[/) in_windows=(tolower(line) == "[windows]")
    if (in_windows && tolower(line) ~ /^load=/) {
      print "load=C:\\AGENT.EXE"; replaced=1; next
    }
    print line
  }
  END { if (!replaced) exit 42 }
' "$winini_orig" | sed 's/$/\r/' >"$winini_new" || die "WIN.INI [windows] load= line not found"
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$winini_new" "c:/WINDOWS/WIN.INI"
MTOOLSRC="$MTOOLSRC_C" mtype "c:/WINDOWS/WIN.INI" | tr -d '\r' | grep -xF 'load=C:\AGENT.EXE' >/dev/null ||
  die "WIN.INI agent autostart verification failed"
log "C: serial agent installed; Windows autostart is load=C:\\AGENT.EXE"

# ---------------------------------------------------------------------------
# 2b. FONT/TEXT FIX — force the CPU-rendered STANDARD VGA display driver.
#
# ROOT CAUSE (diagnosed 2026-07-04; re-verified on pve-qemu 11.0.2,
#   2026-07-15/16, from settled real framebuffer screendumps):
#   The rtts base ships SYSTEM.INI [boot] with display.drv=cirrus.drv +
#   386grabber=avga.3gr (an ACCELERATED Cirrus Logic 5446 1024x768 driver).
#   That driver renders GUI text via the chip's BitBLT / hardware-font path.
#   QEMU's `-vga cirrus` emulation does NOT implement that blit path, so under
#   QEMU every icon (CPU-drawn DIB) renders correctly but EVERY piece of GDI
#   text — window title bars, menus, icon captions, group titles — comes out
#   BLANK. It is NOT a missing/zero-byte .FON: the VGA font set
#   (VGASYS/VGAFIX/VGAOEM + SSERIFE/SERIFE/COURE/SMALLE/SYMBOLE) is all present
#   and [boot] fonts.fon/fixedfon.fon/oemfonts.fon already resolve to them.
#   Proof: swapping to the 8514 large-font set changed nothing (still blank);
#   swapping display.drv -> vga.drv made ALL text render immediately.
#
# FIX: point the display driver at the plain VGA.DRV / VGA.3GR that ship in
#   C:\WINDOWS\SYSTEM (73200-byte MS standard VGA 640x480x16 driver — draws
#   every glyph on the CPU, no chip blit). The existing VGA font set already
#   matches this driver's 96-DPI aspect, so fonts.fon/fixedfon.fon/oemfonts.fon
#   are left untouched. Trade-off: 640x480 instead of 1024x768 — the authentic,
#   bulletproof WfW resolution, and text now renders. (Any Cirrus-accelerated
#   mode stays broken under QEMU regardless of resolution or font set.)
#
# HIGH-RES RECHECK (do not delete these pins or turn this into an unattended
#   install until a clone passes both the framebuffer and golden-reset gates):
#   * Cirrus CL-GD5446 Windows 3.1x Drivers and Utilities v1.31, K54462E.ZIP
#     https://ftpmirror.infania.net/sites/ct_treiber_service/treiber/cirrus/desktop/5446/k54462e.zip
#     sha256 c5a1633f343029e38e79e4d32c0f99f0ac46fb75b8af08585dd6402eba549fac
#     Installed from C:\CIRRUS\INSTALL.EXE: Continue -> C:\WINDOWS\VGAUTIL ->
#     Install -> VGA Display group -> completion -> WinMode -> 256 colours ->
#     1024x768 (and separately 800x600) -> OK -> Restart Windows. Both modes
#     set correctly, but 1024 blanked all GDI text and 800 blanked title/menu
#     glyphs after the desktop settled.
#   * Cirrus GD5426/GD5428 Windows 3.1 Drivers v1.5 archive (Setup identifies
#     the display as "GD5426/28 v1.50e"; 256_1280.drv v1.74, 1995-05-27):
#     https://ftpmirror.infania.net/sites/Cirrus%20Logic/Cirrus%20Logic%20GD5426%20GD5428%20Windows%203.1%20Drivers%20v1.5.zip
#     sha256 c0947038d3cb4094c8b82fea2bec26f73484d3c154a3f34c5b5620aaac326889
#     Installed from C:\CIR542X\INSTALL.EXE, then DOS C:\WINDOWS\SETUP ->
#     Display -> "GD5426/28 v1.50e, 1024x768x256 Smlfnt" (and separately
#     "GD5426/28 v1.50e, 800x600x256") -> keep installed driver -> accept.
#     Both modes produced black client surfaces, broken palette/text, and an
#     unusable Program Manager after a full repaint.
#   QEMU Cirrus has 4 MiB VRAM by default; 1024*768*1 = 786432 bytes, so this
#   is not VRAM exhaustion. blitter=off made scanout black and fontcaching=128
#   produced only partial glyph strokes. A Microsoft CPU-rendered SVGA256 test
#   rendered a clean settled 800x600x256 desktop on the same device set, which
#   isolates the failure to the Cirrus accelerated driver/emulation path.
log "C: patching SYSTEM.INI -> standard VGA display driver (fixes blank-text under QEMU cirrus)"
sysini_orig="${RUN_DIR}/SYSTEM.orig.ini"
sysini_new="${RUN_DIR}/SYSTEM.new.ini"
MTOOLSRC="$MTOOLSRC_C" mtype "c:/WINDOWS/SYSTEM.INI" >"$sysini_orig"
# preserve the untouched original on-image for reference (idempotent)
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$sysini_orig" "c:/WINDOWS/SYSTEM.RTT"
# repoint display.drv + 386grabber to the CPU-rendered VGA pair; re-emit CRLF.
sed -e 's/^display.drv=.*/display.drv=vga.drv/I' \
  -e 's/^386grabber=.*/386grabber=vga.3gr/I' \
  "$sysini_orig" | tr -d '\r' | sed 's/$/\r/' >"$sysini_new"
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$sysini_new" "c:/WINDOWS/SYSTEM.INI"
log "C: SYSTEM.INI patched — display.drv=vga.drv, 386grabber=vga.3gr (original saved as C:\\WINDOWS\\SYSTEM.RTT)"

# ---------------------------------------------------------------------------
# 2c. DESKTOP GAME SHORTCUTS — a visible "Gallery Games" Program Manager group.
#
# GOAL: a first-time visitor should SEE game icons and double-click to play,
#   not have to exit Windows to a DOS prompt. This step surfaces the two games
#   that already ship in the base (Solitaire SOL.EXE + Minesweeper WINMINE.EXE)
#   AND adds a native 16-bit shareware game (Chris Pirih's 1991 "Ski"), all as
#   real Program Manager icons in one group.
#
# HOW: two on-image injections + one .INI patch (all offline via mtools):
#   * SKI.EXE           -> C:\GAMES\SKI.EXE   (fetched from archive.org, SHA-pinned)
#   * GALLERY.GRP       -> C:\WINDOWS\        (repo asset assets/win311/GALLERY.GRP)
#     A Program Manager group *binary* holding three items with embedded icons:
#       Solitaire      -> SOL.EXE      (C:\WINDOWS\SOL.EXE)
#       Minesweeper    -> WINMINE.EXE  (C:\WINDOWS\WINMINE.EXE)
#       Ski (SkiFree)  -> C:\GAMES\SKI.EXE
#     It is kept as a prebuilt asset because the Win3.x .GRP format is a binary
#     with embedded icon resources and has no free, scriptable authoring tool —
#     it was authored ONCE by driving Program Manager's File>New Program Group /
#     Program Item GUI (icons auto-extracted from each exe) and each icon was
#     framebuffer-verified to launch. To regenerate it, repeat that GUI flow and
#     re-copy C:\WINDOWS\GALLERY.GRP back over this asset.
#   * PROGMAN.INI patch: register the group (Group7=C:\WINDOWS\GALLERY.GRP under
#     [Groups]) and append its id to Order= so it is shown on the desktop.
#     (Group7 is unused in the rtts base; [Groups] is the file's last section, so
#     appending Group7 at EOF lands inside it. Idempotent: skipped if present.)
log "C: fetching + staging native Win16 shareware game 'Ski' (Chris Pirih 1991)"
fetch "$WINSKI_URL" "${DL_DIR}/${WINSKI_ZIP}" "$WINSKI_SHA256" ""
ski_stage="${RUN_DIR}/ski"
mkdir -p "$ski_stage"
unzip -qo "${DL_DIR}/${WINSKI_ZIP}" -d "$ski_stage"
[[ -f "$ski_stage/SKI.EXE" ]] || die "SKI.EXE not found inside ${WINSKI_ZIP}"
MTOOLSRC="$MTOOLSRC_C" mmd "c:/GAMES" 2>/dev/null || true # base already has it
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$ski_stage/SKI.EXE" "c:/GAMES/SKI.EXE"

log "C: injecting 'Gallery Games' Program Manager group + desktop icons"
[[ -f "$GALLERY_GRP_ASSET" ]] || die "missing asset: $GALLERY_GRP_ASSET"
MTOOLSRC="$MTOOLSRC_C" mcopy -o "$GALLERY_GRP_ASSET" "c:/WINDOWS/GALLERY.GRP"

progman_orig="${RUN_DIR}/PROGMAN.orig.ini"
progman_new="${RUN_DIR}/PROGMAN.new.ini"
MTOOLSRC="$MTOOLSRC_C" mtype "c:/WINDOWS/PROGMAN.INI" >"$progman_orig"
if grep -qi 'GALLERY\.GRP' "$progman_orig"; then
  log "C: PROGMAN.INI already registers GALLERY.GRP — leaving as-is"
else
  MTOOLSRC="$MTOOLSRC_C" mcopy -o "$progman_orig" "c:/WINDOWS/PROGMAN.RTT" 2>/dev/null || true
  {
    tr -d '\r' <"$progman_orig" | sed -e 's/^\(Order=.*\)$/\1 7/'
    printf 'Group7=C:\\WINDOWS\\GALLERY.GRP\n'
  } | sed 's/$/\r/' >"$progman_new"
  MTOOLSRC="$MTOOLSRC_C" mcopy -o "$progman_new" "c:/WINDOWS/PROGMAN.INI"
  log "C: PROGMAN.INI patched — Group7=GALLERY.GRP registered + shown on desktop"
fi
log "C: Gallery Games group ready (Solitaire + Minesweeper + Ski, double-clickable)"

# ================================================ 3+4+5. build the D: games disk
# Fetch the shareware payloads (checksum-pinned) ...
fetch "$DOOM_URL" "${DL_DIR}/${DOOM_ZIP}" "$DOOM_SHA256" ""
fetch "$DUKE_URL" "${DL_DIR}/${DUKE_ZIP}" "$DUKE_SHA256" ""
fetch "$QUAKE_URL" "${DL_DIR}/${QUAKE_ZIP}" "$QUAKE_SHA256" ""

# --- 3a. Build a bare FAT16 filesystem image (partition payload) -------------
FS_IMG="${RUN_DIR}/fat16.img"
log "creating FAT16 (${GAMES_PART_SECTORS} sectors, label ${GAMES_LABEL})"
dd if=/dev/zero of="$FS_IMG" bs=512 count="$GAMES_PART_SECTORS" status=none
mkfs.vfat -F 16 -n "$GAMES_LABEL" "$FS_IMG" >/dev/null

MTOOLSRC_D="${RUN_DIR}.mtoolsrc-d"
printf 'drive d: file="%s"\n' "$FS_IMG" >"$MTOOLSRC_D" # offset 0: bare fs
export MTOOLSRC="$MTOOLSRC_D"

# --- 5a. Extract + stage the three games into D:\GAMES\{DOOM,DUKE3D,QUAKE} ---
STAGE="${RUN_DIR}/stage"
mkdir -p "$STAGE"
mmd d:/GAMES

# DOOM: doom19.zip extracts FLAT -> copy every file into D:\GAMES\DOOM
log "staging DOOM"
d_doom="${STAGE}/doom"
mkdir -p "$d_doom"
unzip -qo "${DL_DIR}/${DOOM_ZIP}" -d "$d_doom"
mmd d:/GAMES/DOOM
mcopy -o -s "$d_doom"/* d:/GAMES/DOOM/

# DUKE3D: game files live under ".../DUKE3D/" inside the zip -> copy its contents
log "staging DUKE3D"
d_duke="${STAGE}/duke"
mkdir -p "$d_duke"
unzip -qo "${DL_DIR}/${DUKE_ZIP}" -d "$d_duke"
duke_sub="$(find "$d_duke" -type d -name 'DUKE3D' -print -quit)"
[[ -n "$duke_sub" ]] || die "DUKE3D subfolder not found inside ${DUKE_ZIP}"
mmd d:/GAMES/DUKE3D
mcopy -o -s "$duke_sub"/* d:/GAMES/DUKE3D/

# QUAKE: QUAKE_SW/ contents (incl. ID1/PAK0.PAK); drop macOS junk before copy
log "staging QUAKE"
d_quake="${STAGE}/quake"
mkdir -p "$d_quake"
unzip -qo "${DL_DIR}/${QUAKE_ZIP}" -d "$d_quake"
# strip Finder cruft so it doesn't land on the DOS disk
find "$d_quake" -name '__MACOSX' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$d_quake" -name '.DS_Store' -delete 2>/dev/null || true
find "$d_quake" -name '._*' -delete 2>/dev/null || true
quake_sub="$(find "$d_quake" -type d -name 'QUAKE_SW' -print -quit)"
[[ -n "$quake_sub" ]] || die "QUAKE_SW subfolder not found inside ${QUAKE_ZIP}"
mmd d:/GAMES/QUAKE
mcopy -o -s "$quake_sub"/* d:/GAMES/QUAKE/

# --- 5b. Root launchers + README (exact content from the validated disk) -----
log "writing D: launchers + README"
mk_dos() { printf '%b' "$2" | sed 's/$/\r/' >"$1"; } # LF text -> CRLF file

mk_dos "${STAGE}/DOOM.BAT" '@ECHO OFF\nD:\nCD \\GAMES\\DOOM\nDOOM %1 %2 %3\n'
mk_dos "${STAGE}/DUKE.BAT" '@ECHO OFF\nD:\nCD \\GAMES\\DUKE3D\nDUKE3D %1 %2 %3\n'
mk_dos "${STAGE}/QUAKE.BAT" '@ECHO OFF\nD:\nCD \\GAMES\\QUAKE\nQUAKE %1 %2 %3\n'
mk_dos "${STAGE}/README.TXT" \
  'Shareware DOS games on D:\n  DOOM   Doom shareware (id 1993)\n  DUKE   Duke Nukem 3D shareware (3D Realms 1996)\n  QUAKE  Quake shareware (id 1996)\nExit Windows to reach this DOS prompt.\n'

mcopy -o "${STAGE}/DOOM.BAT" "${STAGE}/DUKE.BAT" "${STAGE}/QUAKE.BAT" "${STAGE}/README.TXT" d:/
unset MTOOLSRC

# --- 3b. Wrap the FAT16 fs in a DOS-partitioned raw disk ---------------------
# partition 1: start sector 2048, type 06 (FAT16), bootable — mirrors games.img
log "wrapping FAT16 into partitioned games.img (${GAMES_TOTAL_MB} MiB)"
dd if=/dev/zero of="$GAMES_IMG" bs=1M count="$GAMES_TOTAL_MB" status=none
sfdisk --no-reread --no-tell-kernel "$GAMES_IMG" >/dev/null 2>&1 <<EOF
label: dos
${GAMES_PART_START},${GAMES_PART_SECTORS},6,*
EOF
dd if="$FS_IMG" of="$GAMES_IMG" bs=512 seek="$GAMES_PART_START" conv=notrunc status=none
log "D: ready -> ${GAMES_IMG}"

# ------------------------------------------------------------- 6. artifacts done
log "artifacts:"
log "  C:  ${HDA_IMG}   ($(size_of "$HDA_IMG") bytes)"
log "  D:  ${GAMES_IMG} ($(size_of "$GAMES_IMG") bytes)"
if [[ -d "$FIXTURE_DIR" ]]; then
  if [[ -s "$FIXTURE_DIR/qemu.pid" ]]; then
    fixture_pid="$(cat "$FIXTURE_DIR/qemu.pid" 2>/dev/null || true)"
    if [[ -n "$fixture_pid" ]] && kill -0 "$fixture_pid" 2>/dev/null; then
      die "win311 fixture is running (pid $fixture_pid); stop streamhost@win311 before rebuilding"
    fi
  fi
  log "creating standalone live fixture disks in $FIXTURE_DIR"
  rm -f "$FIXTURE_C" "$FIXTURE_D"
  nice -n15 qemu-img convert -f raw -O qcow2 "$HDA_IMG" "$FIXTURE_C"
  nice -n15 qemu-img convert -f raw -O qcow2 "$GAMES_IMG" "$FIXTURE_D"
  log "live fixture disks ready (the pinned-machine verify boot will savevm golden)"
fi

# ------------------------------------------------- 7. framebuffer verification
if [[ "$VERIFY" -ne 1 ]]; then
  log "VERIFY=0 — skipping framebuffer boot. Done."
  rm -rf "$RUN_DIR" "$MTOOLSRC_C" "$MTOOLSRC_D"
  echo "$HDA_IMG"
  exit 0
fi
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  log "WARN: $QEMU_BIN not found — cannot framebuffer-verify. Artifacts still built."
  rm -rf "$RUN_DIR" "$MTOOLSRC_C" "$MTOOLSRC_D"
  echo "$HDA_IMG"
  exit 0
fi

# Clean shutdown helper: monitor `quit` first, pidfile SIGTERM as fallback.
# NEVER pkill by name (would kill live gallery tiles / CT110 / macOS VMs).
mon_cmd() { printf '%s\n' "$1" | socat - "UNIX-CONNECT:${MON_SOCK}" >/dev/null 2>&1 || true; }
# shellcheck disable=SC2317 # invoked only via the EXIT/INT/TERM trap below
cleanup() {
  if [[ -S "$MON_SOCK" ]]; then
    mon_cmd "quit"
    sleep 1
  fi
  if [[ -f "$PIDFILE" ]]; then
    local p
    p="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ -n "${p:-}" ]] && kill -0 "$p" 2>/dev/null; then
      kill "$p" 2>/dev/null || true
      sleep 1
      kill -9 "$p" 2>/dev/null || true
    fi
  fi
  rm -rf "$RUN_DIR" "$MTOOLSRC_C" "$MTOOLSRC_D"
}
trap cleanup EXIT INT TERM

have_socat=1
command -v socat >/dev/null 2>&1 || have_socat=0
[[ "$have_socat" -eq 1 ]] || log "WARN: socat missing — will rely on pidfile for shutdown/screendump may be skipped"

VERIFY_C="$HDA_IMG"
VERIFY_D="$GAMES_IMG"
VERIFY_C_FMT=raw
VERIFY_D_FMT=raw
BAKE_GOLDEN=0
if [[ -s "$FIXTURE_C" && -s "$FIXTURE_D" ]]; then
  VERIFY_C="$FIXTURE_C"
  VERIFY_D="$FIXTURE_D"
  VERIFY_C_FMT=qcow2
  VERIFY_D_FMT=qcow2
  BAKE_GOLDEN=1
fi
SERIAL_SOCK="${RUN_DIR}/serial.sock"

log "framebuffer-verify: cold-booting pinned pc-i440fx-11.0 fixture (VNC :${VNC_DISP}, monitor ${MON_SOCK})"
# Match the live launcher's guest-visible device set and pinned machine type.
# Display/audio backends are headless here, but the cirrus, SB16, NE2K, IDE and
# COM1 devices exactly match qemu-streamhost.sh for loadvm compatibility.
nice -n15 "$QEMU_BIN" \
  -machine pc-i440fx-11.0 -accel tcg -cpu pentium -m 64 -smp 1 \
  -rtc base=localtime -boot c \
  -drive "file=${VERIFY_C},format=${VERIFY_C_FMT},if=ide" \
  -drive "file=${VERIFY_D},format=${VERIFY_D_FMT},if=ide,index=1" \
  -nic user,ipv6=off,model=ne2k_pci \
  -audiodev none,id=snd0 -device sb16,audiodev=snd0 \
  -vga cirrus -no-shutdown \
  -chardev "socket,id=ser0,path=${SERIAL_SOCK},server=on,wait=off" \
  -serial chardev:ser0 \
  -vnc ":${VNC_DISP}" \
  -monitor "unix:${MON_SOCK},server,nowait" \
  -pidfile "$PIDFILE" \
  -display none -daemonize

for _ in $(seq 1 20); do
  [[ -S "$MON_SOCK" ]] && break
  sleep 0.5
done
log "waiting ${VERIFY_WAIT}s for the WfW 3.11 Program Manager desktop..."
sleep "$VERIFY_WAIT"

verify_rc=0
if [[ "$have_socat" -eq 1 ]]; then
  if mon_cmd "screendump -f png ${SHOT_PNG}" && [[ -s "$SHOT_PNG" ]]; then :; else
    ppm="${RUN_DIR}/shot.ppm"
    mon_cmd "screendump ${ppm}"
    sleep 1
    if [[ -s "$ppm" ]] && command -v pnmtopng >/dev/null 2>&1; then
      pnmtopng "$ppm" >"$SHOT_PNG" 2>/dev/null || cp "$ppm" "${SHOT_PNG%.png}.ppm"
    elif [[ -s "$ppm" ]]; then
      cp "$ppm" "${SHOT_PNG%.png}.ppm"
      SHOT_PNG="${SHOT_PNG%.png}.ppm"
    fi
  fi
  shot_bytes=0
  [[ -f "$SHOT_PNG" ]] && shot_bytes="$(size_of "$SHOT_PNG")"
  # A live 1024x768 Cirrus Program Manager screendump is comfortably > 10 KB.
  if [[ "$shot_bytes" -gt 10000 ]]; then
    log "GUI VERIFIED: framebuffer captured (${shot_bytes} bytes) -> ${SHOT_PNG}"
  else
    log "VERIFY WARN: framebuffer empty/too small (${shot_bytes} bytes). Raise VERIFY_WAIT and re-run, or inspect ${SHOT_PNG}."
    verify_rc=2
  fi
else
  log "VERIFY WARN: socat unavailable — booted but could not screendump."
  verify_rc=2
fi

if [[ "$verify_rc" -eq 0 && "$BAKE_GOLDEN" -eq 1 ]]; then
  log "saving loadvm-compatible golden snapshot from the cold pinned-machine boot"
  mon_cmd "savevm golden"
  sleep 3
  if qemu-img snapshot -l "$FIXTURE_C" | awk '$2 == "golden" { found=1 } END { exit !found }'; then
    log "GOLDEN SAVED: $FIXTURE_C (pc-i440fx-11.0; agent already running on COM1)"
  else
    log "VERIFY FAIL: savevm golden did not create the fixture snapshot"
    verify_rc=2
  fi
fi

# cleanup() runs on EXIT (monitor quit -> pidfile fallback; no pkill).
log "Done. Bootable artifacts: ${HDA_IMG} + ${GAMES_IMG}"
echo "$HDA_IMG"
exit "$verify_rc"

###############################################################################
# LAYOUT PRODUCED (verified against the validated dry-run box):
#   C: hda.img (256 MB raw, FAT16 @ sector 63)
#      \AUTOEXEC.BAT       (patched: auto `win`, then games prompt + D: PATH)
#      \AUTOEXEC.RTT       (untouched rtts original, ends `fdapm poweroff`)
#      \AGENT.EXE          (Win16 COM1 pointer agent, OpenWatcom 1.9 NE binary)
#      \WINDOWS\WIN.INI    ([windows] load=C:\AGENT.EXE auto-start)
#      \WINDOWS\WIN.RTT    (untouched rtts original WIN.INI)
#      \WINDOWS\SYSTEM.INI (patched: display.drv=vga.drv, 386grabber=vga.3gr —
#                           CPU-rendered VGA so all GUI text renders under QEMU)
#      \WINDOWS\SYSTEM.RTT (untouched rtts original SYSTEM.INI, ships cirrus.drv)
#      \WINDOWS\GALLERY.GRP(repo asset: "Gallery Games" Program Manager group —
#                           Solitaire, Minesweeper, Ski (SkiFree) as icons)
#      \WINDOWS\PROGMAN.INI(patched: Group7=GALLERY.GRP registered + shown)
#      \GAMES\SKI.EXE       (Chris Pirih's 1991 "Ski", native 16-bit shareware)
#      + prebuilt WfW 3.11 desktop w/ Netscape Nav 3, Mosaic, IE 3/5, MS TCP/IP-32
#   D: games.img (64 MB raw; FAT16 partition @ sector 2048, type 06, bootable)
#      \DOOM.BAT \DUKE.BAT \QUAKE.BAT \README.TXT
#      \GAMES\DOOM\   (DOOM.EXE + DOOM1.WAD + DM.EXE ...)
#      \GAMES\DUKE3D\ (DUKE3D.EXE + DUKE3D.GRP ...)
#      \GAMES\QUAKE\  (QUAKE.EXE + CWSDPMI.EXE + ID1\PAK0.PAK ...)
#
# PITFALLS / NOTES:
#   * WfW/DOS is real-mode: exiting Windows lands at the DOS prompt where DOOM /
#     DUKE / QUAKE launchers are on PATH. This is intended gallery behaviour.
#   * Winamp N/A (needs Win95+); GTA1 omitted (Rockstar's free build is Win95 —
#     won't run on WfW/real-mode DOS). Both are documented, deliberate gaps.
#   * Do NOT exceed ~256 MB guest RAM (WfW 3.x chokes); 64 MB is the tested value.
#   * Live gallery mounts the images read-only and appends `-snapshot`, so each
#     visitor session is ephemeral. To persist a change instead: drop `-snapshot`
#     and `commit all` from the QEMU monitor.
###############################################################################
