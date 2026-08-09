#!/bin/sh
# irix-net-bake.sh — the IN-GUEST half of the IRIX networking golden bake.
#
# Ran inside IRIX to produce irix65-apps-v5.chd from v3. Kept in the repo
# because the rest of the bake is a manual sequence that has to be repeatable:
#
#   1. Boot a namespaced clone of the current golden with IRIX_NET=on
#      (streamhost/tiles/irix/x11-runtime.sh does the tap + cfg seeding).
#   2. Log in on the real framebuffer, Toolchest -> Desktop -> Open Unix Shell,
#      and type ONE command through the key matrix (natkeyboard drops shifted
#      characters -- see scripts/build-guests/irix-apps/keys.py):
#        ifconfig ec0 inet 172.31.20.2 netmask 0xfffffffc up
#      This is the bootstrap and the only step that needs the GUI: until the
#      hosts file below is fixed, IRIX brings the interface up and then takes it
#      straight back down in standalone mode.
#   3. From the host: scripts/build-guests/irix-net-exec.py <ip> root --push
#      THIS FILE  (telnet, because ftpd refuses root).
#   4. /etc/shutdown -y -g0 -i0, wait for "Okay to power off", kill MAME by
#      pidfile, and promote the clone's disk.chd.
#
# Full record, evidence and the isolation design: docs/guests/irix.md.
#
# Runs IN THE GUEST. Idempotent.

set -x

# ---- 1. networking -------------------------------------------------------
# /etc/init.d/network resolves the PRIMARY interface's address by looking the
# hostname up in /etc/hosts (netif.options leaves if1addr=$HOSTNAME at its
# default). As shipped that is SGI's 192.0.2.1 placeholder, and the script's
# `netstate=loopback` branch then prints
#   "IRIS's Internet address is the default. Using standalone network mode."
# So the fix is the hosts entry, not an ifconfig anywhere.
test -f /etc/hosts.preNET || cp /etc/hosts /etc/hosts.preNET
sed 's/^192\.0\.2\.1/172.31.20.2/' /etc/hosts.preNET >/etc/hosts.new
grep -v '^172\.31\.20\.1[ 	]' /etc/hosts.new >/etc/hosts
cat >>/etc/hosts <<'EOF'

# The host end of the point-to-point tap this machine lives on. There is no
# gateway and no other host: the /30 is the whole network.
172.31.20.1	labhost
EOF
rm -f /etc/hosts.new

# The default mask for 172.31.20.2 is classful (0xffff0000), which would make
# the guest ARP for 172.31.x.x addresses that do not exist. The link is a /30.
echo 'netmask 0xfffffffc' >/etc/config/ifconfig-1.options

chkconfig network on

# NO default route and no route daemon: routed would both advertise and ACCEPT
# routes on this link, which is exactly the property the isolation depends on
# not having. There is nothing to route to.
chkconfig routed off
rm -f /etc/config/static-route.options

# ---- 2. root web servers -------------------------------------------------
# webface_apache is the "Internet Gateway" admin server; it prints
#   "Warning:  Internet Gateway web server running as root."
# at every boot, and it is an httpd running as root on :80 for nobody.
# sgi_apache is the SECOND root web server on the same machine, same story.
chkconfig webface_apache off
chkconfig sgi_apache off

# ---- 3. show the result --------------------------------------------------
set +x
echo "--- hosts"
grep -v '^#' /etc/hosts | grep .
echo "--- ifconfig-1.options"
cat /etc/config/ifconfig-1.options
echo "--- chkconfig"
# IRIX 6.5's grep predates -E; egrep is the portable spelling in the GUEST.
# shellcheck disable=SC2196
chkconfig | egrep 'network|routed|apache|webface'
