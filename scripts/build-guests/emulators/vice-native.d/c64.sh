# shellcheck shell=bash
# vice-native.d/c64.sh — host-native conversion stanza for the Commodore 64
# running the GEOS 2.0 deskTop. Sourced by build-vice-native.sh.
#
# THE ONLY IN-APPLICATION SCENE IN THE WAVE. Every other VICE station's exhibit
# is an untouched cold boot, so every other station could fall back to
# VICE_NATIVE_CHECKPOINT=0 when its restore misbehaved. This one cannot: a cold
# boot reaches a BASIC prompt, not a deskTop, and getting from one to the other
# is ~90 s of emulated true-drive disk loading. c64 is therefore the station
# that actually needs the checkpoint plane, and it is the reason the restore bug
# had to be fixed rather than worked around (DEBRIDGE-HANDOVER.md §The restore
# bug). Its restore was proven to hold before this stanza existed.
#
# TRUE DRIVE EMULATION IS NOT OPTIONAL. GEOS drives the 1541 itself and hangs
# under VICE's fast-loader shortcut, which is why `-drive8truedrive` was in the
# bridged launcher and why `-autostart-handle-tde` has to keep it on ACROSS the
# autostart (autostart otherwise switches TDE off for speed and GEOS breaks).
#
# KEYBOARD-ONLY, DELIBERATELY, AND THAT IS A CHANGE FROM THE BRIDGED STATION.
# The bridged exhibit had a COMM 1351 proportional mouse on control port 1. The
# vicesock daemon path has no pointer verb at all — neither vice_sock.rs nor
# vicectl — and the browser sends ABSOLUTE coordinates while the 1351's POT
# lines are driven from RELATIVE host motion, so wiring the mouse is a design
# decision plus two new verbs, not a knob. Converting keyboard-only is the right
# trade today; the mouse is scoped as follow-up work in the handover.
#
# NO ROM PINS BY SHA: the C64 ROMs ride in VICE's own tree, so the pin on the
# ROMs is the pin on the fork commit. The GEOS disk is the one external file.

VICE_EMU=x64sc
VICE_DATA_DIRS=(C64)
# The three images data/C64/default.vrs resolves, its resource file, and the
# keymap the vicectl KEY verb resolves keysyms through — a headless build with
# no .vkm resolves nothing and the exhibit is a dead keyboard with a perfect
# picture.
VICE_ROM_REQUIRED=(
  C64/kernal-901227-03.bin
  C64/basic-901226-01.bin
  C64/chargen-901225-01.bin
  C64/default.vrs
  C64/gtk3_sym.vkm
)

# The bridged kiosk's flags minus `-sounddev alsa` and minus the two mouse flags
# (`-mouse -controlport1device 1351`), which have nothing to drive them on this
# path. -VICIIdsize is the kiosk's own double-size draw and is what makes the
# published surface 768x544. The gate appends `-autostart <d64>` below.
VICE_GATE_ARGS=(-drive8truedrive -autostart-handle-tde -VICIIdsize)
# MEASURED off the shm mapping: 1 671 232 B = 64 + 768*544*4. Same VIC-II
# geometry cold or restored, which is what made this station's restore
# trustworthy in the first place.
VICE_GEOM_EXPECT=768x544
# THE GATE MEASURES THE REAL SCENE, not a cold boot: it autostarts the GEOS disk
# and runs long enough for the true-drive load to finish, so the build proves
# the deskTop and not merely that the machine draws something. GEOS's own
# grey/white deskTop is a BUSY frame — 256 429 lit and 258 645 non-dominant of
# 417 792 pixels, 315 colours — so both floors sit at ~60 % of measured and the
# ink floor is doing real work: a C64 that failed to load GEOS sits on a flat
# blue BASIC screen with ~2 000 non-dominant pixels and would fail it.
VICE_GATE_FLOOR=150000
VICE_GATE_INK_FLOOR=150000
# ~120 s of emulated time at 985 248 Hz. The deskTop appears at ~90 s; the
# margin is for a loaded box, which slows the WALL clock and not this one.
VICE_GATE_CYCLES=120000000

# The GEOS boot disk — the ONE external file this station needs. It is the
# 1351 variant the bridged station built (`c1541 -delete joystick`, so COMM 1351
# is the only input driver on the disk) and it is kept as-is even though the
# mouse is not wired yet: changing the disk would change what the checkpoint was
# baked against, for no gain the visitor can see.
#
# A SNAPSHOT DOES NOT CARRY THE DISK IMAGE — `dump` stores the drive's state but
# not its media — so the live station must have the same image attached (`-8`)
# or the restored GEOS comes back with nothing under the head. That is why the
# fixture's VICE_NATIVE_ARGS carries `-8 <this file>` while the gate below uses
# `-autostart` instead: the gate has no checkpoint to restore and has to reach
# the deskTop the slow way.
vice_stage_extra() {
  local out="$1"
  local src=/data/vms/streamhost/stations/c64/media/GEOS-1351.D64
  [ -s "$src" ] || die "GEOS boot disk missing at $src (extracted from the
  bridge-era guest image, which built it with c1541 -delete joystick)"
  mkdir -p "$out/media"
  install -m 644 "$src" "$out/media/GEOS-1351.D64"
  [ "$(stat -c %s "$out/media/GEOS-1351.D64")" -eq 174848 ] ||
    die "GEOS-1351.D64 is not a 35-track .d64 after staging"
  VICE_GATE_ARGS+=(-autostart "$out/media/GEOS-1351.D64")
  echo "  staged: $out/media/GEOS-1351.D64 (GEOS 2.0 boot disk, 1351 driver only)"
}
