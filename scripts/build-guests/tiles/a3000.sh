#!/bin/bash
# =============================================================================
# tiles/a3000.sh — build the Workbench 2.04 system disk for the host-native
# FS-UAE Amiga 3000 station (no QEMU anywhere in this builder).
#
# What is FULLY automated (stage: assemble — this is the ONLY stage; unlike
# amigaos35 there is no click-scripted install, Workbench 2.04 ships pre-
# installed on its own floppy set):
#   * media gate — the four Workbench 2.04 ADFs + the A3000 Kickstart 2.04
#     ROM, hash-checked against MANIFEST.sha256 staged at
#     /data/vms/sandbox/a3000/media (see docs/lab/ASSETS-MANIFEST.md);
#   * the four ADFs are unpacked host-side with amitools' xdftool and merged
#     into a fresh 256 MiB FFS hardfile: Disk 1 (Workbench) is the SYS: root,
#     Disk 2 (Extras)'s Tools/System/Prefs merge into the matching Workbench
#     dirs, Disk 3 (Fonts) merges into SYS:Fonts, Disk 4 (Install) lands under
#     SYS:Install (kept for HDToolBox/Installer, not used at runtime);
#   * the smoke rig proved the *floppy* boots to Workbench 2.04's first-run
#     "KeyMap Selection" prompt (a `S/Startup-Sequence` step, see
#     docs/lab/A3000-WAVE.md) — this builder removes exactly that step from
#     the copy of S/Startup-Sequence written onto the hardfile so the HDF
#     boots straight to the Workbench desktop with LoadWB still in place.
#
# Output (ONE combination with the emulator binary):
#   $OUT/a3000-system.hdf — the system disk (golden master).
#   No statefile: like amigaos35/amix this station's device set is the ADF-
#   derived hardfile plus the A3000 Kickstart 2.04 ROM, no floppies.
#   After composing, the FFS root bm_flag is already clean — this hardfile is
#   written and closed by xdftool, never booted before being staged (the
#   amigaos35 trap: a golden captured from a RUNNING session has a dirty
#   root bm_flag, set only on flush/unmount — composing host-side avoids it
#   entirely, see docs/lab/A3000-WAVE.md "Walls hit").
#
# docs/lab/A3000-WAVE.md is the ledger; the sibling recipe is
# tiles/amigaos35.sh's assemble stage (Workbench 3.1, same shape, one fewer
# disk).
# =============================================================================
set -euo pipefail

OS_ID=a3000
ASSETS="${ASSETS:-/data/vms/sandbox/a3000/media}"
OUT="${OUT:-/data/gallery-guests/A3000}"
WORK="${WORK:-/data/vms/sandbox/build-$OS_ID}"
XDFTOOL="${XDFTOOL:-xdftool}"

ROM_NAME="Kickstart v2.04 r37.175 (1991-05)(Commodore)(A3000).rom"
ADF_WB="Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 1 of 4)(Workbench).adf"
ADF_EXTRAS="Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 2 of 4)(Extras).adf"
ADF_FONTS="Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 3 of 4)(Fonts).adf"
ADF_INSTALL="Workbench v2.04 rev 37.67 (1991)(Commodore)(Disk 4 of 4)(Install).adf"

log() { printf '[build:%s] %s\n' "$OS_ID" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}

check_assets() {
  [ -d "$ASSETS" ] || die "no staged media at $ASSETS"
  (cd "$ASSETS" && sha256sum -c MANIFEST.sha256 >/dev/null) || die "media manifest mismatch in $ASSETS"
  log "media gate OK ($ASSETS)"
}

[ "${1:-}" = --check-assets ] && {
  check_assets
  exit 0
}
check_assets
command -v "$XDFTOOL" >/dev/null || die "amitools xdftool not on PATH (pip install amitools)"

mkdir -p "$WORK" "$OUT"

HDF="$WORK/a3000-system.hdf"
rm -f "$HDF"
log "assembling Workbench 2.04 system HDF (volume: System)"
"$XDFTOOL" "$HDF" create size=256Mi + format System ffs

ADF="$WORK/adf"
rm -rf "$ADF"
mkdir -p "$ADF/wb" "$ADF/extras" "$ADF/fonts" "$ADF/install"
"$XDFTOOL" "$ASSETS/$ADF_WB" unpack "$ADF/wb/"
"$XDFTOOL" "$ASSETS/$ADF_EXTRAS" unpack "$ADF/extras/"
"$XDFTOOL" "$ASSETS/$ADF_FONTS" unpack "$ADF/fonts/"
"$XDFTOOL" "$ASSETS/$ADF_INSTALL" unpack "$ADF/install/"

# --- stage host-side merge tree ---------------------------------------------
S="$WORK/sys-stage"
rm -rf "$S"
mkdir "$S"
# Workbench disk 1 is the SYS: root (the volume it ships as is Workbench2.0).
cp -r "$ADF/wb/Workbench2.0/." "$S/"
# Extras disk: only its Tools/System/Prefs subdirs merge into the matching
# Workbench ones (measured layout has no Prefs on the Extras disk; Devs/
# Keymaps and MonitorStore are not needed for boot-to-desktop and are left
# off SYS: — the Install disk keeps its own copy of the installer tree).
EX="$ADF/extras"
EXVOL="$(find "$EX" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$EXVOL" ] || die "Extras ADF unpacked with no top-level volume dir"
mkdir -p "$S/Tools" "$S/System"
cp -r "$EXVOL/Tools/." "$S/Tools/"
cp -r "$EXVOL/System/." "$S/System/"
[ -d "$EXVOL/Prefs" ] && {
  mkdir -p "$S/Prefs"
  cp -r "$EXVOL/Prefs/." "$S/Prefs/"
}
[ -f "$EXVOL/Tools.info" ] && cp "$EXVOL/Tools.info" "$S/Tools.info"
[ -f "$EXVOL/System.info" ] && cp "$EXVOL/System.info" "$S/System.info"
# Fonts disk -> SYS:Fonts (merge its own Fonts/ subdir only).
FONTVOL="$(find "$ADF/fonts" -mindepth 1 -maxdepth 1 -type d | head -1)"
mkdir -p "$S/Fonts"
cp -r "$FONTVOL/Fonts/." "$S/Fonts/"
# Install disk -> SYS:Install, kept whole (Installer + HDToolBox scripts:
# FormatHD/InstallHD/PrepHD/UpdateWB etc.) — NOT merged into the root, so it
# cannot shadow the Workbench disk's own C/Devs/L/Libs at boot time.
INSTVOL="$(find "$ADF/install" -mindepth 1 -maxdepth 1 -type d | head -1)"
mkdir -p "$S/Install"
cp -r "$INSTVOL/." "$S/Install/"
rm -f "$S/Install/disk.info"

# --- remove the floppy's first-run KeyMap Selection step --------------------
# The Workbench disk ships TWO startup scripts in S/: `Startup-sequence` (the
# floppy boot the smoke rig proved — its tail is
# `if ${sys/keyboard} NOT EQ "*${sys/keyboard}" then setmap else PickMap sys:
# initial` — PickMap IS the first-run "KeyMap Selection" requester, run
# whenever the `keyboard` ENV var is unset, which it always is on a fresh
# boot) and `Startup-sequence.HD` (Commodore's own hard-disk variant: same
# structure, but the "else" branch is simply omitted — no keyboard var means
# no setmap and no PickMap, straight through to `rexxmast` + `LoadWB` +
# `endcli`). Use the HD variant as SYS:S/Startup-sequence so the hardfile
# never shows the requester.
SS="$S/S/Startup-sequence"
SSHD="$S/S/Startup-sequence.HD"
[ -f "$SS" ] || die "no S/Startup-sequence on the Workbench disk"
[ -f "$SSHD" ] || die "no S/Startup-sequence.HD on the Workbench disk"
diff -u "$SS" "$SSHD" >"$WORK/startup-sequence.diff" || true
cp "$SSHD" "$SS"
log "Startup-Sequence edit (floppy Startup-sequence -> Startup-sequence.HD, no PickMap branch):"
cat "$WORK/startup-sequence.diff" >&2

# --- write the merge tree onto the hardfile ---------------------------------
(cd "$S" && find . -mindepth 1 -maxdepth 1) | sed 's|^\./||' | while read -r c; do
  "$XDFTOOL" "$HDF" write "$S/$c" "$c"
done

cp "$ASSETS/$ROM_NAME" "$WORK/kick204.a3000.rom"

log "assembled $HDF"
log "output expected: $OUT/a3000-system.hdf (golden master, no statefile) +"
log "  the A3000 Kickstart 2.04 ROM at streamhost/assets/a3000/."
