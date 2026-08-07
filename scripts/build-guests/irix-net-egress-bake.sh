#!/bin/sh
# IRIX 6.5 golden bake, step 2: give the guest what it needs to USE an outbound
# path — a default route, a resolver that fails fast, and a browser pointed at
# the host-side TLS proxy. Runs IN THE GUEST, on top of irix-net-bake.sh's
# result (the v5 golden). Idempotent.
#
# EVERY line here is guest-side CONFIG, not policy. Whether the guest can
# actually reach anything is decided entirely on the host by tapnet.sh
# (IRIX_NET_EGRESS): with the host in its default sandbox mode this golden
# still cannot reach the LAN or the internet — that exact case was tested
# adversarially and the packets die in the host's IRIXNET-IN/FWD chains. So a
# golden carrying a default route is not a golden that has been opened up, and
# keeping the guest config identical across both host modes is what makes the
# host flag the single, reviewable switch.
set -x

# ---- 1. default route ----------------------------------------------------
# /etc/init.d/network SOURCES this file as shell, after the interface is up and
# before any routing daemon starts. routed stays off (irix-net-bake.sh): the
# route is static and nothing on this link may advertise anything.
cat >/etc/config/static-route.options <<'EOF'
# The host end of the point-to-point tap. Whether traffic sent here goes
# anywhere is the HOST's decision (tapnet.sh IRIX_NET_EGRESS); from in here it
# is simply where "not on my /30" is handed off to.
${ROUTE:-/usr/etc/route} ${QUIET:--q} add default 172.31.20.1
EOF

# ---- 2. resolver ---------------------------------------------------------
# retrans/retry are the load-bearing part, not the nameservers. A guest that
# BLOCKS on a dead resolver presents to a visitor as a frozen application, which
# is a far worse exhibit bug than a lookup that simply fails: 1000 ms x 1 try x
# 2 servers bounds a doomed lookup at ~2 s, which is what it does when the host
# is in sandbox mode and there is no path to a resolver at all.
cat >/etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
retrans 1000
retry 1
EOF

# nsd's shipped order is `hosts: nis dns files` — NIS FIRST, on a machine with
# no NIS domain and now with a route off-link. It resolves fast today, but the
# first lookup of anything is not the place to consult a service this machine
# does not use and could, on a live network, be answered by a stranger.
test -f /etc/nsswitch.conf.preEGRESS || cp /etc/nsswitch.conf /etc/nsswitch.conf.preEGRESS
sed 's/^hosts:.*/hosts:			files dns/' /etc/nsswitch.conf.preEGRESS >/etc/nsswitch.conf

# ---- 3. Netscape, connecting DIRECTLY ------------------------------------
# The host-side TLS-terminating proxy was DROPPED by user decision (2026-08-03),
# so this browser now talks to the network itself. `network.proxy.type 0` is
# therefore not a default being restated, it is the load-bearing line: prefs
# left pointing at 172.31.20.1:8080 with nothing listening there would fail
# EVERY page load, including ones the browser could otherwise serve.
#
# The known consequence, accepted: Communicator 4.8a speaks SSL 2/3 and TLS 1.0
# with a root store that expired last decade, so https:// sites fail at the
# handshake. Plain http:// works. `browser.startup.page 0` opens a blank window
# rather than dialling a home page that may not answer.
mkdir -p /.netscape
rm -f /.netscape/lock
cat >/.netscape/preferences.js <<'EOF'
// Netscape User Preferences
user_pref("network.proxy.type", 0);
user_pref("browser.startup.page", 0);
user_pref("browser.cache.disk_cache_size", 8192);
EOF

# ---- 4. show the result --------------------------------------------------
set +x
echo "--- static-route.options"
cat /etc/config/static-route.options
echo "--- resolv.conf"
cat /etc/resolv.conf
echo "--- nsswitch hosts"
grep '^hosts:' /etc/nsswitch.conf
echo "--- netscape proxy"
grep proxy /.netscape/preferences.js
