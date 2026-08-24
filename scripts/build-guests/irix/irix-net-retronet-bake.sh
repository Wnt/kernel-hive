#!/bin/sh
# irix-net-retronet-bake.sh — the IN-GUEST half of joining irix to the retronet.
#
# Runs IN THE GUEST, on top of irix-net-bake.sh (v5: the interface + hosts fix)
# and irix-net-egress-bake.sh (v6: resolver + nsswitch + Netscape direct). It
# REPLACES that pair's addressing: the guest moves off the host-only /30
# (172.31.20.2, default route to labhost, public resolvers) and onto the
# retronet bridge vmbr-rn (10.99.0.24/24, NO default route, the gateway's own
# wildcard resolver). Idempotent.
#
# EVERY line here is guest-side CONFIG, not policy — the same contract the
# egress bake states. What the guest can actually reach is decided on the host
# by streamhost/stations/irix/rn-tapnet.sh + labhost's retronet-fw: with the
# station launched in its sandbox mode this golden reaches nothing at all, and
# with it in retronet mode it reaches 10.99.0.2 and nothing else. Keeping the
# guest config a plain statement of "where I live" is what makes IRIX_NET_MODE
# the single reviewable switch.
#
# THE ONE THING THIS RETIRES. The v6/v7 golden could dial the LAN and the
# internet (IRIX_NET_EGRESS=on, telnet to telehack.com, ping 1.1.1.1). The
# retronet is offline by construction — RETRONET-BRIEF.md §1 — so a station on
# it has no WAN path, and this bake removes the default route that was the
# guest's half of that. Rolling back is the sandbox golden, not an edit here.
#
# The bake sequence around it (same shape as v7's, docs/guests/irix.md):
#   1. scripts/build-guests/irix/irix-serial-rig.sh boot <name> --chd <current>
#   2. irix-serial-rig.sh exec <name> "..."  (or --push this file) and run it
#   3. /etc/shutdown -y -g0 -i0, wait for "Okay to power off", halt the rig
#   4. promote the clone's disk.chd as the next seed, then rebake the savestate
#      (scripts/build-guests/irix/irix-savestate/capture-checkpoint.sh)

set -x

# ---- 1. the address ------------------------------------------------------
# /etc/init.d/network resolves the PRIMARY interface's address by looking the
# hostname up in /etc/hosts (netif.options leaves if1addr=$HOSTNAME), so the
# address of this machine IS its hosts entry — the same lever irix-net-bake.sh
# used to get off SGI's 192.0.2.1 placeholder.
test -f /etc/hosts.preRN || cp /etc/hosts /etc/hosts.preRN
# Move the hostname's address, drop the old /30 peer, and name the gateway.
sed -e 's/^172\.31\.20\.2/10.99.0.24/' /etc/hosts.preRN >/etc/hosts.new
grep -v '^172\.31\.20\.1[ 	]' /etc/hosts.new | grep -v '^10\.99\.0\.2[ 	]' >/etc/hosts
cat >>/etc/hosts <<'EOF'

# The retronet gateway: wildcard DNS, the :80 corpus origin, and OSCAR :5190.
# It is the only host this machine can reach, and it is on-link, so there is
# no route to it and no route anywhere else.
10.99.0.2	retronet-gw
EOF
rm -f /etc/hosts.new

# vmbr-rn is a /24, not the /30 the sandbox link was. Leaving the old mask here
# makes the guest ARP for a 4-address network and never find the gateway.
echo 'netmask 0xffffff00' >/etc/config/ifconfig-1.options

chkconfig network on

# ---- 2. NO default route -------------------------------------------------
# Containment Lock 1, and it is the guest's own stack that enforces it: with no
# default route IRIX cannot form a packet to anything off 10.99.0.0/24, so the
# retronet's no-WAN posture does not depend on a firewall rule holding. The
# egress bake put this file here; the retronet takes it away again.
rm -f /etc/config/static-route.options

# routed would both advertise and ACCEPT routes on a link shared with a dozen
# other era guests — including a default route handed over by anything that
# felt like it. Off, and stays off.
chkconfig routed off

# ---- 3. resolver ---------------------------------------------------------
# The gateway answers EVERY name with its own address (retronet-dns is a
# wildcard resolver), which is what makes the corpus browsable by typing a URL
# instead of configuring a proxy. retrans/retry stay fast-failing for the same
# reason the egress bake gave: a guest that BLOCKS on a dead resolver presents
# to a visitor as a frozen application. One nameserver, because there is
# exactly one, and 1000ms x 1 try bounds a doomed lookup at ~1 s.
cat >/etc/resolv.conf <<'EOF'
nameserver 10.99.0.2
retrans 1000
retry 1
EOF

# nsswitch: files before dns, NIS nowhere (irix-net-egress-bake.sh's reasoning
# holds harder on a shared bridge). Re-asserted here so this bake is complete
# on its own rather than depending on which earlier bake ran.
test -f /etc/nsswitch.conf.preEGRESS || cp /etc/nsswitch.conf /etc/nsswitch.conf.preEGRESS
sed 's/^hosts:.*/hosts:			files dns/' /etc/nsswitch.conf.preEGRESS >/etc/nsswitch.conf

# ---- 4. Netscape: direct, quiet, and pointed at SGI's own web -------------
# EVERY interactive account, not just root. A visitor picks a user at the
# iconlogin chooser and opens Netscape from the Toolchest, so the account whose
# prefs matter is THEIRS — and an account with no preferences.js gets Netscape
# 4's FIRST-RUN flow instead of a browser: it opens
# home.netscape.com/home/first.html ("SmartUpdate"), then su_setup.html, both of
# which are not in the corpus and render the museum's miss page, after a long
# wait. That is the "warning dialogs then eventually a browser" the exhibit
# showed (observed on the live station 2026-08-24, as demos).
#
# What each pref is for:
#   network.proxy.type 0     direct. The gateway's wildcard DNS does the naming;
#                            a proxy would be a second layer aimed at a port
#                            this station never uses.
#   browser.startup.page 1   open the home page (0 = blank window).
#   browser.startup.homepage www.sgi.com, as the corpus holds it.
#   security.warn_*  false   the era's modal "you are about to submit / enter /
#                            leave a secure document" boxes. On a plane that
#                            serves no https at all these can only ever fire
#                            spuriously, and a modal box a visitor must dismiss
#                            is the worst thing an exhibit can open with.
# The `lock` is removed with them: it is a SYMLINK naming host:pid that Netscape
# leaves behind when it does not exit cleanly, and the next launch greets the
# visitor with "Netscape has detected a .netscape/lock file ... another user is
# running Netscape". Nothing in the golden should carry one.
# NOTE ON SHELL: this runs under IRIX 6.5's /bin/sh, a real Bourne shell — no
# `$(...)` command substitution (it prints the text literally instead of running
# it, which is how the first version of this block silently skipped its chown)
# and no `${var%%pattern}`. So: a function with explicit arguments, and no
# substitution anywhere.
seed_netscape() { # $1 = account, $2 = its .netscape directory
  test -d "$2" || mkdir -p "$2" || return 0
  rm -f "$2/lock"
  cat >"$2/preferences.js" <<'EOF'
// Netscape User Preferences
user_pref("network.proxy.type", 0);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "http://www.sgi.com/");
user_pref("browser.cache.disk_cache_size", 8192);
user_pref("security.warn_entering_secure", false);
user_pref("security.warn_leaving_secure", false);
user_pref("security.warn_submit_insecure", false);
user_pref("security.warn_viewing_mixed", false);
EOF
  # The profile must belong to the account that reads it: Netscape REWRITES
  # preferences.js on exit, and a root-owned file in a visitor's home means it
  # cannot — which is its own source of complaints.
  chown -R "$1" "$2" || true
}

seed_netscape root /.netscape
seed_netscape demos /usr/demos/.netscape
seed_netscape guest /usr/people/guest/.netscape
seed_netscape chronic /usr/people/chronic/.netscape

# ---- 5. show the result --------------------------------------------------
set +x
echo "--- hosts"
grep -v '^#' /etc/hosts | grep .
echo "--- ifconfig-1.options"
cat /etc/config/ifconfig-1.options
echo "--- static-route.options (must be absent)"
ls -l /etc/config/static-route.options 2>&1
echo "--- resolv.conf"
cat /etc/resolv.conf
echo "--- nsswitch hosts"
grep '^hosts:' /etc/nsswitch.conf
echo "--- netscape (every interactive account: path, owner)"
ls -l /.netscape/preferences.js /usr/demos/.netscape/preferences.js \
  /usr/people/guest/.netscape/preferences.js \
  /usr/people/chronic/.netscape/preferences.js 2>&1
echo "--- stale locks (must be none)"
for f in /.netscape/lock /usr/demos/.netscape/lock \
  /usr/people/guest/.netscape/lock /usr/people/chronic/.netscape/lock; do
  test -h "$f" || test -f "$f" && echo "  STALE: $f"
done
echo "  (nothing listed above = none)"
cat /.netscape/preferences.js
echo "--- chkconfig"
# IRIX 6.5's grep predates -E; egrep is the portable spelling in the GUEST.
# shellcheck disable=SC2196
chkconfig | egrep 'network|routed|apache|webface'
