# shellcheck shell=bash
# native.d/newsos.sh — host-native stanza for Sony NEWS-OS 4.2.1aRD on the
# NWS-3260 (MAME `nws3260`, src/mame/sony/news_r3k.cpp). Chosen over the
# nws5000x the candidate doc first named because the 3260 driver has a REAL
# local framebuffer (news_lcdfb, 1120x780 mono LCD) and is not
# MACHINE_NOT_WORKING — direct framebuffer capture + ctlsock input, the lab's
# host-native end state, with no XDMCP/XTEST detour. docs/guests/newsos.md.
#
# Romset: sha1-pinned blobs the operator/agent stages under
# /data/assets-staging/newsos (see the guest doc's ROM section for the source
# archive); stage-romset.py matches them against THIS binary's listxml.
# The driver is status good apart from sound, but idrom.bin is a BAD_DUMP
# (machine-specific, per MAME) and that "ROM NEEDS REDUMP" panel is a MODAL
# wait — skip_warnings alone does not cover ROM warnings, the patch does.

NATIVE_DRIVER=nws3260
NATIVE_SUBTARGET=newsos
NATIVE_SOURCES=src/mame/sony/news_r3k.cpp
# The LCD's native raster; the station streams it 1:1.
NATIVE_GEOM=1120x780
NATIVE_MAME_ARGS=()
# mame-news-hid-kbd-order.patch: the news_hid HLE keyboard is a scanned matrix,
# so a modifier and the character it qualifies pressed in the same scan cycle
# could reach the guest character-first and mistype it (HUP->HUp, shift-7 &->7,
# $HOME->$hOME) — worst in the X server. The patch delivers modifier edges
# before/after the characters they qualify and deepens the 8-byte key FIFO
# (which silently dropped on overflow) so fast bursts survive. docs/guests/newsos.md.
NATIVE_EXTRA_PATCHES=(mame-irix-skip-warnings.patch mame-news-hid-kbd-order.patch)
NATIVE_SKIP_WARNINGS=1

native_stage_roms() {
  local roms="$1"
  python3 "$HERE/../../debridge-convert/stage-romset.py" \
    "$OUT" nws3260 /data/assets-staging/newsos "$roms" nws3260
}

# The ROM monitor paints its banner on the LCD within a few emulated seconds
# (or, with no boot device, its prompt): a low floor proves "the machine
# draws on the published surface"; the exhibit scene is the operator's call.
native_boot_gate() {
  native_gate_nonblack "$1" "$2" "$3" 2000 15
}
