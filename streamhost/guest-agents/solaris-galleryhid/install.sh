#!/bin/sh
set -eu

id | grep '^uid=0(' >/dev/null 2>&1 || {
  echo "install.sh must run as root" >&2
  exit 1
}
test -f galleryhid || {
  echo "build galleryhid first" >&2
  exit 1
}

install -f /usr/kernel/drv/amd64 -m 0755 galleryhid
install -f /usr/kernel/drv -m 0644 galleryhid.conf

OLD_DEVLINK_RULE='type=ddi_mouse;name=galleryhid;minor=mouse'
DEVLINK_RULE='type=ddi_mouse;name=pci1af4,1100;minor=mouse'
grep -v "^${OLD_DEVLINK_RULE}" /etc/devlink.tab |
  grep -v "^${DEVLINK_RULE}" >/etc/devlink.tab.galleryhid
printf '%s\t%s\n' "$DEVLINK_RULE" gallerymouse \
  >>/etc/devlink.tab.galleryhid
chmod 0644 /etc/devlink.tab.galleryhid
mv /etc/devlink.tab.galleryhid /etc/devlink.tab

if grep '^galleryhid ' /etc/name_to_major >/dev/null 2>&1; then
  rem_drv galleryhid
fi
add_drv -m '* 0600 root sys' -i '"pci1b36,15"' galleryhid
devfsadm -i galleryhid
