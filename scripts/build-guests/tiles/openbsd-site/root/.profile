# $OpenBSD$ — Kernel Hive station: the console autologin lands here; start X once.
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/X11R6/bin:/usr/local/sbin:/usr/local/bin
export PATH HOME TERM
if [ "$(tty)" = /dev/ttyC0 ] && [ -z "$DISPLAY" ]; then
  exec startx
fi
