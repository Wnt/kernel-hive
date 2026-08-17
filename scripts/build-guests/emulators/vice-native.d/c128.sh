# shellcheck shell=bash
# vice-native.d/c128.sh — host-native conversion stanza for the Commodore 128.
# Sourced by build-vice-native.sh; not executable on its own.
#
# THE ONLY TWO-CANVAS STATION IN THE WAVE, and the only one that must SAY which
# screen it publishes. x128 creates a VICII canvas AND a VDC canvas. `-80col`
# decides which one the MACHINE boots into, but it does not decide which one
# refreshes first, and the shm publisher takes the canvas that claims the
# mapping. Measured on 2026-08-17 with the pinned binary:
#
#   no selector          -> chip VICII, 768x544  — the 40-column screen, WRONG
#   VICE_SHM_CHIP=VDC    -> chip VDC,   856x576  — the 80-column screen, right
#
# So the selector is not a preference here, it is the difference between
# shipping this exhibit and shipping a different machine's screen. It is set
# below for the gate and by VICE_NATIVE_SHM_CHIP=VDC in the station fixture; a
# name that matches no chip publishes NOTHING, which the gate reads as an empty
# mapping rather than as a quietly wrong picture.
#
# NO ROM PINS BY SHA: VICE carries the Commodore ROMs in its own tree, so the
# pin on the ROMs IS the pin on the fork commit. Only the CP/M disk is external,
# and that one is hash-pinned by the bridge-era builder that fetched it.

VICE_EMU=x128
# C128 alone: the C64-mode ROMs (basic64-901226-01, kernal64-901227-03) live in
# data/C128 too, so there is no second data dir to stage — and this exhibit
# never enters C64 mode anyway (GO64 works but paints the VICII, which with
# -80col is not the canvas being published; the SPA offers no button for it).
VICE_DATA_DIRS=(C128)
# The six images data/C128/default.vrs resolves for a PAL machine, its resource
# file, and the keymap the vicectl KEY verb resolves keysyms through. A headless
# build with no .vkm resolves nothing and the exhibit is a dead keyboard with a
# perfect picture.
VICE_ROM_REQUIRED=(
  C128/kernal-318020-05.bin
  C128/basiclo-318018-04.bin
  C128/basichi-318019-04.bin
  C128/chargen-390059-01.bin
  C128/basic64-901226-01.bin
  C128/kernal64-901227-03.bin
  C128/default.vrs
  C128/gtk3_sym.vkm
)

# The bridged kiosk's flags minus `-sounddev alsa` and minus `-remotemonitor`
# (the text monitor is dead in a headless build; the station needs no monitor at
# all, because restore-at-startup runs from -moncommands). NO -VDCdsize, for the
# cbm2 reason: the kiosk drew the VDC 1:1 in a 789x576 window on an 800x600 X
# root, and host-native there is no root, so the emulated screen simply IS the
# stream — the same glyph size the visitor has always seen, at a quarter of the
# encode cost of the 1712x1152 doubled surface.
VICE_GATE_ARGS=(-pal -80col)
# WITHOUT THIS THE GATE MEASURES THE VICII. See the header.
VICE_GATE_SHM_CHIP=VDC
# MEASURED off the shm mapping 2026-08-17: 1 972 288 B = 64 + 856*576*4.
VICE_GEOM_EXPECT=856x576
# A DARK machine: cyan text on black. Measured 8 719 lit and 11 263 non-dominant
# on a 493 056-pixel surface — a scene that fills under 3 % of the frame, which
# is why an absolute floor works here and a percentage-of-frame one would not.
# Floors at ~60 % of measured. The two are not redundant: "lit" counts pixels
# over the brightness threshold, "non-dominant" also counts the blend pixels
# around every glyph.
VICE_GATE_FLOOR=5000
VICE_GATE_INK_FLOOR=6500
VICE_GATE_CYCLES=20000000
# Position gate, the cbm2 pattern: measured ink bbox rows 93..203, cols
# 111..584 — the four banner lines, the READY. prompt, and the cursor on the
# line BELOW it. Containment with slack, not equality, and the slack is not
# decoration: the first pass of this stanza wrote 80:200 from a run that had
# sampled the cursor in its blink-OFF phase, and the gate rejected the build
# for an ink bbox 16 rows taller. That is the check working.
VICE_GATE_BBOX=80:215:100:600

# The CP/M Plus system disk — the ONE external file this station needs, and the
# only customer of this hook in the wave. It is NOT put on the command line and
# it is NOT in the checkpoint: the C128 KERNAL boots any CP/M disk it finds in
# drive 8 AT RESET, and this station's scene is the BASIC power-on screen. The
# bridged kiosk dodged that by attaching the disk ~10 s later over VICE's text
# monitor from a helper script inside the guest. Host-native the dodge is
# synchronous and needs no helper: the launcher's restore-at-startup command
# file attaches it right after the undump, at the READY breakpoint, which is
# past the boot-sector check (VICE_NATIVE_ATTACH8 in the fixture).
# The visitor still reaches CP/M by typing BOOT.
vice_stage_extra() {
  local out="$1"
  local src=/data/vms/streamhost/stations/c128/media/cpm.d64
  [ -s "$src" ] || die "CP/M system disk missing at $src (bridge-era builder
  scripts/build-guests/tiles/c128.sh stage_cpm_disk fetches and hash-pins it)"
  mkdir -p "$out/media"
  install -m 644 "$src" "$out/media/cpm.d64"
  [ "$(stat -c %s "$out/media/cpm.d64")" -eq 174848 ] ||
    die "cpm.d64 is not a 35-track .d64 after staging"
  echo "  staged: $out/media/cpm.d64 (CP/M 3.0 system disk, attached to drive 8 after restore)"
}
