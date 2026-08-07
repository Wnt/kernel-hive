#!/bin/sh
set -eu

id | grep '^uid=0(' >/dev/null 2>&1 || {
  echo "install-xorg.sh must run as root" >&2
  exit 1
}
test -f xorg.conf.gallerymouse || {
  echo "xorg.conf.gallerymouse must be in the current directory" >&2
  exit 1
}

ROLLBACK=/etc/X11/xorg.conf.pre-gallerymouse
ABSENT=/etc/X11/xorg.conf.pre-gallerymouse.absent
if test -f "$ROLLBACK" || test -f "$ABSENT"; then
  :
elif test -f /etc/X11/xorg.conf; then
  cp -p /etc/X11/xorg.conf "$ROLLBACK"
else
  touch "$ABSENT"
fi

install -f /etc/X11 -m 0644 xorg.conf.gallerymouse
mv /etc/X11/xorg.conf.gallerymouse /etc/X11/xorg.conf
echo "installed=/etc/X11/xorg.conf"
echo "restart=svcadm restart svc:/application/graphical-login/cde-login:default"
