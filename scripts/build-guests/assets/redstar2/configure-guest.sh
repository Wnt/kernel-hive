#!/bin/sh
set -eu

XORG=/etc/X11/xorg.conf
test -s "$XORG"

# Cirrus is the only tested clean installed-desktop path.  Red Star's generic
# VESA path tears large rectangles at 1024x768x24; 16-bit Cirrus plus software
# cursor/no acceleration is stable on the real framebuffer.
sed -i \
  -e 's/Driver[[:space:]]*"vesa"/Driver      "cirrus"/' \
  -e 's/DefaultDepth[[:space:]]*24/DefaultDepth 16/' \
  -e 's/Depth[[:space:]]*24/Depth 16/g' \
  "$XORG"
if ! grep -qi 'Option[[:space:]]*"swcursor"' "$XORG"; then
  sed -i '/Driver[[:space:]]*"cirrus"/a\        Option      "swcursor" "true"\
        Option      "noaccel" "true"' "$XORG"
fi

# The stock "mouse" driver treats QEMU's tablet as relative.  Bind the old
# evdev driver directly to the stable event node under the pinned topology.
sed -i \
  -e '0,/Driver[[:space:]]*"mouse"/s//Driver      "evdev"/' \
  -e '0,/\/dev\/input\/mice/s//\/dev\/input\/event3/' \
  "$XORG"

grep -qi 'Driver[[:space:]]*"cirrus"' "$XORG"
grep -q '/dev/input/event3' "$XORG"
grep -qi 'Option[[:space:]]*"swcursor"' "$XORG"

if ! id gallery >/dev/null 2>&1; then
  useradd -m gallery
fi

# KDM auto-login is the station contract: cold boot and checkpoint restore must both
# reach the logged-in gallery desktop without input. Keep the fixture static by
# removing the panel clock and disabling the screensaver in gallery's profile.
KDM=/etc/X11/xdm/kdmrc
test -s "$KDM"
cp -p "$KDM" "$KDM.pre-gallery-autologin"
sed -i \
  -e 's/^#\?AutoLoginEnable=.*/AutoLoginEnable=true/' \
  -e 's/^#\?AutoLoginUser=.*/AutoLoginUser=gallery/' \
  -e 's/^#\?AutoLoginSession=.*/AutoLoginSession=kde/' \
  -e 's/^#\?AutoLogin1st=.*/AutoLogin1st=true/' \
  "$KDM"

GALLERY_KDE=/home/gallery/.kde/share/config
mkdir -p "$GALLERY_KDE"
cp /usr/share/config/kickerrc "$GALLERY_KDE/kickerrc"
sed -i \
  -e 's/,Applet_5$//' \
  -e '/^\[Applet_5\]$/,/^$/d' \
  "$GALLERY_KDE/kickerrc"
cp /usr/share/config/kdesktoprc "$GALLERY_KDE/kdesktoprc"
sed -i \
  -e '/^\[ScreenSaver\]$/,/^\[/ { s/^Enabled=.*/Enabled=false/; s/^Timeout=.*/Timeout=0/; }' \
  "$GALLERY_KDE/kdesktoprc"
chown -R gallery:gallery /home/gallery/.kde

sync
echo 'REDSTAR2_GUEST_CONFIGURED'
