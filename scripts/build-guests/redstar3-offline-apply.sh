#!/bin/sh
# Applied from a virtual ext2 helper disk while the Red Star install ISO is
# booted in rescue TTY mode.  No network device or in-guest network service is
# used at any point.
set -eu

root=${1:?usage: redstar3-offline-apply.sh TARGET_ROOT}
kdm="$root/etc/X11/xdm/kdmrc"

[ -f "$kdm" ]
cp -p "$kdm" "$kdm.pre-gallery"
sed -i \
  -e 's/^#\?AutoLoginEnable=.*/AutoLoginEnable=true/' \
  -e 's/^#\?AutoLoginUser=.*/AutoLoginUser=gallery/' \
  -e 's/^#\?AutoLoginSession=.*/AutoLoginSession=kde/' \
  "$kdm"

# The QEMU-incompatible greeter crashes before accepting input.  Auto-login
# avoids that guest bug.  With audio deliberately absent, these two KDE
# autostarts would otherwise put crash, audio, or delayed integrity-warning
# modals over the fixture.
for desktop in esavermanager kmix intcheck_kde; do
  path="$root/usr/share/autostart/$desktop.desktop"
  if [ -f "$path" ]; then
    mv "$path" "$path.disabled"
  fi
done

sync
