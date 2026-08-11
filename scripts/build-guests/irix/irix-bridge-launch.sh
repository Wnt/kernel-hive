#!/usr/bin/env bash
# Kiosk launcher for the SGI IRIX 6.5 graphical-kiosk (issue #20).
# Installed as /etc/bridge/launch.sh; run full-screen on the bare-X kiosk.
#
# Runs MAME 0.288 (indy_4610, XL 24-bit graphics) auto-booting the IRIX 6.5 CHD
# straight to the 4Dwm desktop. The Indy renders 1280x1024, so the kiosk X is
# forced to 1280x1024 for a 1:1 (unscaled) framebuffer.
#
# NOTE: this only runs on the ONE-TIME golden bake. In production the station boots
# via `qemu -loadvm golden`, which restores the whole kiosk (MAME already at the
# IRIX desktop) — launch.sh is not re-executed.
set -euo pipefail

XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export SDL_VIDEODRIVER=x11

# Match the emulated Indy resolution 1:1 (best-effort; std-vga supports it).
xrandr -s 1280x1024 2>/dev/null || true

# A minimal WM so MAME's SDL window holds keyboard focus (so streamed keystrokes
# reach the emulated IRIX).
matchbox-window-manager -use_titlebar no >/dev/null 2>&1 &

# MAME 0.288 is run through a bundled glibc loader: MAME's SGI/Indy emulation
# miscompiles under bookworm's gcc-12 (IRIX hits a GIO2 graphics-interrupt kernel
# panic during boot), while the gcc-14 build of identical source boots clean. So the
# station ships the gcc-14 binary (/opt/mame/sgi-trixie) plus its glibc 2.41 (in
# /opt/mame/glibc); glibc is backward-compatible so the kiosk's own SDL2/X11 still
# load. -inipath /opt/irix -> ui.ini sets skip_warnings 1 (patched to always apply),
# skipping the startup warning so IRIX boots with no input (clearing it by click also
# trips the GIO2 panic).
exec /opt/mame/glibc/ld-linux-x86-64.so.2 \
  --library-path /opt/mame/glibc:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu \
  /opt/mame/sgi-trixie indy_4610 \
  -bios b10 \
  -rompath /opt/irix/roms \
  -gio64_gfx xl24 \
  -hard1 /opt/irix/irix65.chd \
  -diff_directory /opt/irix/diff \
  -nvram_directory /opt/irix/nvram \
  -inipath /opt/irix \
  -skip_gameinfo \
  -video soft \
  -nomaximize \
  -sound none \
  -mouse
