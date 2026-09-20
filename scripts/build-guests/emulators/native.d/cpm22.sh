# shellcheck shell=bash
# native.d/kayproii.sh — host-native conversion stanza for the Kaypro II, the
# cpm22 wave's `native` stream. Driver `kayproii` lives in
# src/mame/kaypro/kaypro.cpp (MACHINE_SUPPORTS_SAVE — the golden checkpoint
# restore applies unmodified).
#
# IMPORTANT correction on the integration seed: the driver short name is
# `kayproii`, NOT `kaypro2` as docs/lab/integration-seeds/cpm22.md guessed —
# confirmed with -listxml against a stock MAME 0.276 system package on
# labhost (2026-09-20). `kaypro2` is only the FLOPPY FORMAT's internal name
# (formats/kaypro_dsk.cpp's kayproii_format::name()), not a driver.
#
# CORRECTION 2026-09-20 (post-landing incident): this stanza's header used to
# say "no skip-warnings patch is needed" — WRONG, proven by a black-screen
# live station. kayproii flags "imperfect sound" (its beeper device), which
# makes MAME's ui.cpp display_startup_screens() show a MODAL "known problems
# with this system... Press any key to continue" panel that `-skip_gameinfo`
# does NOT suppress (it only gates the SEPARATE game-info screen, `state 0`
# in that function — the warnings screen is `state 1`, gated by a totally
# different, always-false-on-a-fresh-process persistence check). With
# MAME_NO_UI=1 the panel renders as nothing (kiosk-no-ui strips ALL UI
# compositing) but the modal input-wait behind it still blocks the machine
# from ever reaching machine_phase::RUNNING — so ctlsock's on_frame() setup()
# never fires, no verb ever gets acked, and the framebuffer stays solid
# black forever. `-str` under 300s or `-video none` are the ONLY conditions
# upstream disables this screen under (ui.cpp: `str > 0 && str < 60*5`) —
# neither applies to a real production launch. `mame-irix-skip-warnings.patch`
# (originally written for irix) makes ui.ini's `skip_warnings 1` unconditional
# instead of gated on a same-warnings-within-14-days memory that a fresh
# process never satisfies — REQUIRED here, exactly as domainos/newsos (the
# fleet's other two audio-off MAME-native stations) already carry it.

NATIVE_DRIVER=kayproii
NATIVE_SUBTARGET=kayproii
NATIVE_SOURCES=src/mame/kaypro/kaypro.cpp
NATIVE_GEOM=1024x768
# Device set: default bios "149" (81-149.u47, board 81-110, CRC 28264bc1) has
# no surviving dump on the mirrors checked 2026-09-20 (retroarchive.org/
# maslin/roms/kaypro/ only carries 149b/149c); ship bios=149c, the same
# revision archive.org's dedicated "81149c_KayproII_ROM" item preserves, on
# the SAME 81-110 board family as the default. NATIVE_MAME_ARGS carries it so
# every launch (builder gate, smoke rig, production fixture) agrees.
NATIVE_MAME_ARGS=(-bios 149c)
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  # CORRECTED 2026-09-20 after building the actual fleet-pinned mame0289
  # binary: on THIS tree the keyboard device is `kayproiikbd`
  # (devices/bus/keytronic/keytronic_l2207.cpp, an Intel i8048 HLE) needing
  # `kaypro_ii-ins8048.bin` (1024 bytes, CRC f65e1ca5, sha1
  # 7919385fe8badbb610b793a3f5e4077982094aaa) — NOT `kaypro10kbd`/
  # `m5l8049.bin`, which is what a STOCK MAME 0.276 SYSTEM PACKAGE (used
  # only for the early smoke proof, see docs/lab/CPM22-WAVE.md) resolves to.
  # Different MAME trees renamed this device between versions; always trust
  # -listxml on the BINARY THAT WILL ACTUALLY RUN, never an earlier smoke
  # test on a different build. Two romsets feed this scene: kayproii.zip
  # itself (81-149c.u47 BIOS + 81-146.u43 chargen) and the device romset
  # kayproiikbd.zip (kaypro_ii-ins8048.bin).
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" kayproii /data/assets-staging/cpm22/roms "$roms" \
    kayproii kayproiikbd
}

# Power-on with no floppy attached is the "* KAYPRO II *  Please place your
# diskette into Drive" banner, green text on a black field — text-only, so
# the lit-pixel floor is set low like the other text-console MAME stations
# (apple2e/mpf2), not the SAM Coupé's solid-colour floor. An early smoke
# proof on a STOCK MAME 0.276 system package (bios=149c) measured "well
# above a few thousand" lit px, but that ran at the driver's native
# 560x240 raster, not this station's published 1024x768 drawshm surface.
# MEASURED 2026-09-20 against the ACTUAL fleet-pinned mame0289 binary at
# the real 1024x768 geometry (2 short lines of text on an otherwise black
# field): 3163 lit px. Floor set to 2500 — comfortably below the measured
# banner, comfortably above zero/garbage.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 2500 6
}
