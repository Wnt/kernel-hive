#!/bin/sh
# In-guest: sh /mnt/apply-x.sh   (xconf CD mounted on /mnt)
set -e
cp /mnt/XF86Config /usr/X11R6/lib/X11/XF86Config
ln -sf /usr/X11R6/bin/XF86_SVGA /usr/X11R6/bin/X
cp /mnt/kh-xsession /etc/kh-xsession && chmod 755 /etc/kh-xsession
echo 'inet 10.0.2.15 netmask 255.255.255.0' > /etc/ifconfig.ne2
echo 10.0.2.2 > /etc/mygate
echo netbsd14 > /etc/myname
grep slirphost /etc/hosts > /dev/null || echo '10.0.2.2 slirphost' >> /etc/hosts
grep kh-xsession /etc/rc.local > /dev/null || echo '(cd / && /usr/X11R6/bin/xinit /etc/kh-xsession -- /usr/X11R6/bin/X > /var/log/xinit.log 2>&1) &' >> /etc/rc.local
ls -l /usr/X11R6/bin/X /usr/X11R6/bin/ctwm /usr/X11R6/bin/twm 2>&1
sync
echo APPLY-X-DONE
