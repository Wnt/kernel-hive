#!/usr/bin/env bash
###############################################################################
# build-guests/stages/finnish-games.sh
#   Offline-inject the Finnish freeware pair — Death Rally (Remedy, 1996; the
#   2009 Windows freeware build) and Porrasturvat / Stair Dismount (tAAt/Secret
#   Exit, 2002) — into an NT-family gallery disk, and surface BOTH as visible
#   All-Users desktop shortcuts.
#
# WHY. Every Windows station in the hive ships US shareware (DOOM, Quake, Duke,
#   GTA1) and nothing Finnish, in a Finnish museum. These two are the strongest
#   candidates from the PixLauncher catalogue: both are freeware with a clean
#   provenance, both have a single-player mode (a two-players-one-keyboard game
#   is a dead exhibit for one remote visitor), and both are self-contained
#   folders after extraction, so they inject offline with no in-guest installer
#   run at all:
#     * Death Rally's 2009 rerelease installer is an NSIS 2.45 archive -> 7z
#       extracts the finished program folder. dr.exe is an SDL build whose PE
#       MinimumOSVersion is 4.0, so it is in-spec on both Win2000 and XP.
#     * Porrasturvat 1.0.3 ships as a plain SDL program folder in a zip.
#   Neither needs 3D acceleration, which matters: these stations run QEMU std
#   VGA / VBEMP with no hardware accelerator, so anything OpenGL-hungry is out.
#
# USAGE
#   DISK=/path/to/guest.qcow2 finnish-games.sh
#   env: DISK (required, qcow2, NOT in use by a running guest)
#        CACHE      payload cache dir (default /data/vms/tools/cache/finnish-games)
#        GAMES_DIR  in-guest parent for the payloads (default C:\Games)
#        DRY=1      fetch + verify + extract only; never touch the disk
#
#   The guest MUST be stopped, and — because these stations boot `-loadvm
#   golden` — the golden has to be RECAPTURED after this runs (rule 6:
#   `ssh lab 'checkpoint-guard recapture <station>'`). A vmstate captured
#   before the injection has NTFS metadata that predates it; restoring it over
#   the edited disk is how you corrupt a station.
#
# DEPS (host): qemu-nbd, ntfs-3g, 7z, unzip, curl, plus scripts/dev/lnk-venv.sh
#   (pylnk3, for minting the .lnk files offline — never the system python).
#
# LEGAL: both titles are freeware, redistributable, and fetched from a pinned
#   URL + sha256 at build time. The bits never enter this repo.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISK="${DISK:?set DISK=/path/to/guest.qcow2}"
CACHE="${CACHE:-/data/vms/tools/cache/finnish-games}"
GAMES_DIR="${GAMES_DIR:-Games}" # relative to C:\, backslash-free here
DRY="${DRY:-0}"
RUN_DIR="${RUN_DIR:-/tmp/finnish-games.$$}"

# --- pinned payloads ---------------------------------------------------------
# Death Rally for Windows 1.0 — Remedy's 2009 freeware rerelease (NSIS installer).
DR_URL="${DR_URL:-https://archive.org/download/death-rally-win-10/DeathRallyWin_10.exe}"
DR_SHA256="cad032de50e47a15e361b0b593b7a27ef47b7790bc29df109b8d249ee070f60d"
# Porrasturvat - Stair Dismount 1.0.3 (tAAt / Secret Exit), Suomipelit mirror.
PT_URL="${PT_URL:-https://archive.org/download/suomipelit-porra103.zip/porra103.zip}"
PT_SHA256="0f8f4f0174977c485affbff6eca689513f77309d8ad3689cbf98faa74f1450d2"

log() { printf '[finnish-games] %s\n' "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

NBD_DEV=""
MNT=""
cleanup() {
  [[ -n "$MNT" ]] && mountpoint -q "$MNT" && { umount "$MNT" || true; }
  [[ -n "$NBD_DEV" ]] && { qemu-nbd --disconnect "$NBD_DEV" >/dev/null 2>&1 || true; }
  return 0
}
trap cleanup EXIT

for c in curl 7z unzip; do command -v "$c" >/dev/null || die "missing $c"; done
mkdir -p "$CACHE" "$RUN_DIR"

fetch() { # url sha256 dest
  local url="$1" want="$2" dest="$3" got
  if [[ -s "$dest" ]]; then
    got="$(sha256sum "$dest" | awk '{print $1}')"
    [[ "$got" == "$want" ]] && {
      log "cached: $(basename "$dest")"
      return 0
    }
    log "cache sha mismatch for $(basename "$dest") — refetching"
    rm -f "$dest"
  fi
  log "fetch: $url"
  curl -fSL --retry 3 --retry-delay 3 -o "${dest}.part" "$url" || die "download failed: $url"
  got="$(sha256sum "${dest}.part" | awk '{print $1}')"
  [[ "$got" == "$want" ]] || die "sha256 mismatch for $url (want $want, got $got)"
  mv "${dest}.part" "$dest"
}

fetch "$DR_URL" "$DR_SHA256" "${CACHE}/DeathRallyWin_10.exe"
fetch "$PT_URL" "$PT_SHA256" "${CACHE}/porra103.zip"

# --- extract to a staging tree ----------------------------------------------
STAGE="${RUN_DIR}/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/DeathRally" "$STAGE/Porrasturvat"

# NSIS archive -> the finished program folder. $PLUGINSDIR / $SMPROGRAMS /
# uninstall.exe.nsis are installer scaffolding, not game files.
7z x -y -o"$STAGE/DeathRally" "${CACHE}/DeathRallyWin_10.exe" >/dev/null || die "7z failed on the Death Rally installer"
rm -rf "$STAGE/DeathRally/\$PLUGINSDIR" "$STAGE/DeathRally/\$SMPROGRAMS" "$STAGE/DeathRally/uninstall.exe.nsis"
[[ -s "$STAGE/DeathRally/dr.exe" ]] || die "dr.exe missing after extract"

unzip -q -o "${CACHE}/porra103.zip" -d "$RUN_DIR/pt" || die "unzip failed on porra103.zip"
cp -r "$RUN_DIR/pt/porrasturvat/." "$STAGE/Porrasturvat/"
[[ -s "$STAGE/Porrasturvat/porrasturvat.exe" ]] || die "porrasturvat.exe missing after extract"

log "staged: DeathRally $(du -sh "$STAGE/DeathRally" | cut -f1), Porrasturvat $(du -sh "$STAGE/Porrasturvat" | cut -f1)"
[[ "$DRY" == "1" ]] && {
  log "DRY=1 — stopping before the disk"
  exit 0
}

# --- first-boot shortcut writer ---------------------------------------------
#   NOT pylnk3. An offline-minted .lnk (assets/common/mklnk.py, and the same
#   workaround in assets/winxp/make_shortcuts.py) renders its icon on the XP
#   desktop but DOES NOT LAUNCH: double-click does nothing, Enter on the
#   selected icon does nothing, and the same file in the Startup folder is
#   skipped at logon. Proven on a winxp clone 2026-09-24 with a control: a
#   pylnk3 shortcut to the stock C:\WINDOWS\system32\sol.exe did not start
#   Solitaire either, while a .bat in the same Startup folder started it
#   instantly. The shell wants a shortcut Windows itself wrote, so we ship a
#   one-shot WSH script that mints both .lnk files IN the guest on the first
#   boot (the boot the golden recapture does anyway) and then removes its own
#   trigger.
###############################################################################
write_firstboot() {
  local games="C:\\${GAMES_DIR}"
  cat >"${MNT}/${GAMES_DIR}/kh-finnish-games.vbs" <<VBS
' kh-finnish-games.vbs — mint the two Finnish-freeware desktop shortcuts.
' Written offline by build-guests/stages/finnish-games.sh; runs ONCE at the
' first logon after the injection, from the All Users Startup folder.
Set sh = CreateObject("WScript.Shell")
desk = sh.SpecialFolders("AllUsersDesktop")

Set l = sh.CreateShortcut(desk & "\\Death Rally.lnk")
l.TargetPath = "${games}\\DeathRally\\dr.exe"
' -window: the fullscreen path sets an OpenGL video mode that CRASHES dr.exe on
' these guests (no accelerated GL on QEMU std VGA / VBEMP). Windowed 640x480 is
' the mode that runs — proven on a winxp clone 2026-09-24.
l.Arguments = "-window"
l.WorkingDirectory = "${games}\\DeathRally"
l.IconLocation = "${games}\\DeathRally\\DR.ICO"
l.Description = "Death Rally (Remedy, 1996) — freeware Windows release"
l.Save

Set l = sh.CreateShortcut(desk & "\\Porrasturvat (Stair Dismount).lnk")
l.TargetPath = "${games}\\Porrasturvat\\porrasturvat.exe"
l.WorkingDirectory = "${games}\\Porrasturvat"
l.Description = "Porrasturvat - Stair Dismount (tAAt, 2002)"
l.Save
VBS
  unix2dos "${MNT}/${GAMES_DIR}/kh-finnish-games.vbs" 2>/dev/null ||
    sed -i 's/$/\r/' "${MNT}/${GAMES_DIR}/kh-finnish-games.vbs"

  local startup
  startup="$(find "$MNT/Documents and Settings" -maxdepth 5 -type d -ipath '*All Users*' -iname Startup -print -quit 2>/dev/null || true)"
  [[ -n "$startup" ]] || die "no All Users Startup folder under $MNT"
  printf '@echo off\r\ncscript //nologo %s\\kh-finnish-games.vbs\r\ndel "%%~f0"\r\n' \
    "C:\\${GAMES_DIR}" >"${startup}/kh-finnish-games.bat"
  log "first-boot shortcut writer armed in ${startup#"$MNT"}"
}

# --- open the disk -----------------------------------------------------------
command -v qemu-nbd >/dev/null || die "missing qemu-nbd"
[[ -f "$DISK" ]] || die "no disk at $DISK"
modprobe nbd max_part=8 2>/dev/null || true
for n in $(seq 0 15); do
  [[ "$(cat "/sys/block/nbd$n/size" 2>/dev/null || echo 0)" == "0" ]] || continue
  if qemu-nbd --connect="/dev/nbd$n" -f qcow2 "$DISK" 2>/dev/null; then
    NBD_DEV="/dev/nbd$n"
    break
  fi
done
[[ -n "$NBD_DEV" ]] || die "no free nbd node"
sleep 2
partprobe "$NBD_DEV" 2>/dev/null || true

MNT="${RUN_DIR}/mnt"
mkdir -p "$MNT"
mounted=""
for part in "${NBD_DEV}p1" "${NBD_DEV}p2" "$NBD_DEV"; do
  [[ -b "$part" ]] || continue
  if mount -t ntfs-3g "$part" "$MNT" 2>/dev/null || mount "$part" "$MNT" 2>/dev/null; then
    # the system volume, not a stray recovery/data partition
    if [[ -d "$MNT/Documents and Settings" ]]; then
      mounted="$part"
      break
    fi
    umount "$MNT"
  fi
done
[[ -n "$mounted" ]] || die "could not mount a Windows system volume from $DISK"
log "mounted $mounted"

# --- copy the payloads -------------------------------------------------------
for g in DeathRally Porrasturvat; do
  rm -rf "${MNT:?}/${GAMES_DIR}/$g"
  mkdir -p "${MNT}/${GAMES_DIR}"
  cp -r "$STAGE/$g" "${MNT}/${GAMES_DIR}/$g"
  log "staged C:\\${GAMES_DIR}\\$g"
done

# --- shortcuts: armed for the first boot, not written offline -----------------
# Clean out any earlier offline-minted (non-launching) copies before arming.
for d in "$MNT"/Documents\ and\ Settings/*/Desktop; do
  [[ -d "$d" ]] || continue
  rm -f "$d/Death Rally.lnk" "$d/Porrasturvat (Stair Dismount).lnk"
done
write_firstboot

sync
log "done — REMEMBER: recapture the station golden (checkpoint-guard recapture <station>)"
