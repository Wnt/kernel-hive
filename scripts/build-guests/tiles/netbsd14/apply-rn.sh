#!/bin/sh
# apply-rn.sh — in-guest: join netbsd14 to the retronet (web + ICQ planes).
# Run from the transfer CD:  sh /mnt/apply-rn.sh <icq-password>
# Idempotent. Companion of apply-x.sh; see docs/lab/retronet/STATION-netbsd14.md.
set -e
PASS="$1"
# --- link: ne1 is the tap on vmbr-rn; ne0 stays the SLIRP X-pointer channel but
#     is NO LONGER a route anywhere. The launcher runs that netdev with
#     restrict=on, so 10.0.2.2 is not a gateway and 10.0.2.3 is not a resolver;
#     ne0 keeps its address only, so the guest's X server still answers on
#     10.0.2.15:6000 through the host-initiated loopback forward. ---
echo "inet 10.99.0.32 netmask 255.255.255.0" >/etc/ifconfig.ne1
ifconfig ne1 inet 10.99.0.32 netmask 255.255.255.0 up 2>/dev/null || true
echo "inet 10.0.2.15 netmask 255.255.255.0" >/etc/ifconfig.ne0
# --- the ONLY default route is the retronet gateway ---
echo 10.99.0.2 >/etc/mygate
route delete default >/dev/null 2>&1 || true
route add default 10.99.0.2 >/dev/null 2>&1 || true
# --- resolver: the retronet wildcard DNS (SLIRP's 10.0.2.3 is unreachable under
#     restrict=on and must not be listed). files stays FIRST so the SLIRP peer
#     that X reverse-resolves on every connection never leaves the host table ---
cat >/etc/resolv.conf <<'R'
domain retronet.lab
nameserver 10.99.0.2
R
cat >/etc/nsswitch.conf <<'N'
group: compat
hosts: files dns
netgroup: files
passwd: compat
shells: files
N
grep -q slirphost /etc/hosts || echo "10.0.2.2 slirphost" >>/etc/hosts
grep -q retronet-gw /etc/hosts || echo "10.99.0.2 retronet-gw search.retronet" >>/etc/hosts
grep -q "10.99.0.32" /etc/hosts || echo "10.99.0.32 netbsd14.retronet.lab netbsd14" >>/etc/hosts
# --- ICQ account (mICQ reads ~/.micq/micqrc; password from local.env) ---
if [ -n "$PASS" ]; then
  mkdir -p /root/.micq
  sed -e "s/__PASS__/$PASS/" /mnt/micqrc.tmpl >/root/.micq/micqrc
  chmod 600 /root/.micq/micqrc
fi
# --- the exhibit session ---
cp /mnt/kh-xsession /etc/kh-xsession && chmod 755 /etc/kh-xsession
sync
netstat -rn | head -14
echo APPLY-RN-DONE
