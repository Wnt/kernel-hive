#!/bin/sh
# Reload galleryhid while Xorg has /dev/gallerymouse open.
set -eu

exec >/var/tmp/galleryhid-reload.log 2>&1
SERVICE=svc:/application/graphical-login/cde-login:default

restart_login() {
  svcadm enable "$SERVICE" 2>/dev/null || true
}
trap restart_login EXIT HUP INT TERM

svcadm disable -s "$SERVICE"
cd /var/tmp/galleryhid
./build.sh
./install.sh
svcadm enable "$SERVICE"
trap - EXIT HUP INT TERM
