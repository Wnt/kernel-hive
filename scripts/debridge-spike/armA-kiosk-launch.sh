#!/bin/bash
# De-bridging spike ARM A kiosk launcher (tier 2). Overlays the bridge base's
# placeholder /etc/bridge/launch.sh. Runs THE SAME MAME ST binary arm B runs on
# the host (sha256 is asserted equal by the rig), rendered by SDL into a window
# that exactly fills the 1024x768 bare-X root, which streamhost then captures
# through the QEMU dbus display like any other bridge tile.
#
# The flags that are NOT free choices:
#   -resolution 1024x768 -nomaximize   the captured surface must equal arm B's
#                                      MAME_SHM_SIZE, or the A/B measures
#                                      resolution instead of the bridge.
#   -video soft                        the software renderer, i.e. the same
#                                      rasteriser drawshm uses. accel/opengl
#                                      would put llvmpipe in one arm only.
#   -frameskip 0 -noautoframeskip      fixed and identical in both arms;
#                                      anything adaptive is load-dependent and
#                                      arm B is by construction less loaded.
#   -throttle                          MAME's own 100%-speed governor, on in
#                                      both arms, so a "win" cannot be the
#                                      emulator simply running faster.
#   -sound none                        audio is off in both arms; one variable
#                                      fewer, and the spike measures video.
#   -mouse                             tier 2's input plane IS the host mouse:
#                                      usb-tablet -> kiosk X -> SDL -> MAME. Arm
#                                      B deliberately does NOT set it, because
#                                      there the ctlsock module writes the same
#                                      ioports directly and two injectors would
#                                      fight over one analog field.
#
# THE BLANK X CURSOR IS LOAD-BEARING, not tidiness. The bare-X root draws its
# own pointer into the captured framebuffer, and that pointer moves as soon as
# the usb-tablet does -- WITHOUT the emulator being involved at all. Left
# visible it would satisfy a damage-based latency detector several milliseconds
# before the ST's own GEM cursor moved, making the BRIDGE arm look faster than
# it is. Arm B has no such second pointer. Hiding it makes both arms measure the
# same event: the EMULATED cursor moving.
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
export SDL_RENDER_DRIVER=software
export SDL_VIDEODRIVER=x11
export SDL_VIDEO_CENTERED=1
M=/opt/bridge/atarist-mame
printf '#define b_width 1\n#define b_height 1\nstatic char b_bits[] = { 0x00 };\n' >"$M/blank.xbm"
xsetroot -cursor "$M/blank.xbm" "$M/blank.xbm" 2>/dev/null || true
exec "$M/atarist" st \
  -rompath "$M/roms" -inipath "$M" -homepath "$M" \
  -cfg_directory "$M/cfg" -nvram_directory "$M/nvram" \
  -video soft -window -nomaximize -resolution 1024x768 -nofilter \
  -sound none -skip_gameinfo -throttle -frameskip 0 -noautoframeskip -mouse
