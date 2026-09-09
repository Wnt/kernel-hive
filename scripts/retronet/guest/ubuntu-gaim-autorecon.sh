#!/bin/sh
# ubuntu-gaim-autorecon.sh — runs INSIDE the ubuntu (Warty 4.10) guest, once,
# during a golden bake. Loads Gaim 1.0's autorecon plugin and silences its
# disconnect dialogs, so `labctl reset ubuntu` (= loadvm golden) heals itself
# instead of leaving the exhibit on a "18300 has been disconnected" dialog with
# the Login window behind it. See docs/lab/retronet/STATION-ubuntu.md
# §Reset and reconnect.
#
# Delivery (the station has no exec channel):
#   pct push 951 scripts/retronet/guest/ubuntu-gaim-autorecon.sh /tmp/rn/s.sh
#   pct exec 951 -- systemd-run --unit=ubuntu-rn-dl python3 -m http.server 8099 --directory /tmp/rn
#   # in the guest terminal:
#   wget -qO- http://10.99.0.2:8099/s.sh | sh
#
# prefs.xml is rewritten by gaim on exit, so gaim MUST be stopped before the
# edit — hence the pkill + sleep.
P=$HOME/.gaim/prefs.xml
pkill gaim 2>/dev/null
sleep 3
cp "$P" "$P.bak"
sed -i "s#<item value='/usr/lib/gaim/docklet.so' />#<item value='/usr/lib/gaim/docklet.so' />\n\t\t\t\t<item value='/usr/lib/gaim/autorecon.so' />#" "$P"
sed -i "s#name='hide_connected_error' type='bool' value='0'#name='hide_connected_error' type='bool' value='1'#" "$P"
sed -i "s#name='hide_connecting_error' type='bool' value='0'#name='hide_connecting_error' type='bool' value='1'#" "$P"
echo "autorecon items: $(grep -c autorecon.so "$P")"
grep -o "hide_conne[a-z_]*' type='bool' value='[01]'" "$P"
xset m 1 1
xset s off
gnome-screensaver-command -d >/dev/null 2>&1
gaim >/dev/null 2>&1 &
echo STARTED
