#!/bin/sh
# install-webbrowser.sh — make Netscape Communicator 4.76 the DISCOVERABLE
# retronet web browser on the tru64 (Tru64 UNIX 5.1B / CDE) exhibit desktop.
#
# WHERE THIS RUNS: inside the Tru64 guest, as root. Deliver it over the exec
# channel (`labctl exec tru64` / streamhost/guest-agents/tru64/tru64exec.py) or
# fetch it in-guest (`/usr/local/bin/httpfetch <gw> /install-webbrowser.sh
# /tmp/x 80`) and run it: `/bin/ksh /tmp/x`. It is applied to the golden as a
# coordinated follow-up (see docs/lab/retronet/WEB-BROWSER-tru64.md).
#
# WHY NETSCAPE 4.76: it is the period-correct browser for Tru64 UNIX 5.x on
# Alpha (DEC/Compaq shipped Netscape Communicator 4.7x with Tru64 5.1B; the
# software catalog independently names Communicator 4.x "the definitive late-90s
# web tile"). It speaks plain HTTP/1.0 with no TLS, exactly what the retronet
# corpus proxy serves on :80. Netscape 6 on this box never maps a window — do
# not chase it. The binary already ships in the base 5.1B install at
# /usr/bin/X11/netscape (-> netscape4); this script does NOT install a binary,
# it makes the installed one discoverable and points it at the corpus.
#
# WHAT IT DOES (every step is idempotent — safe to re-run):
#   1. verify Netscape 4.76 is present (guidance to setld it from the OS CD if not)
#   2. point the browser at the retronet corpus (wrapper default + Netscape prefs)
#   3. add a DISCOVERABLE launcher, three ways a visitor cannot miss:
#        - a labelled "Web" icon on the MAIN CDE Front Panel row
#        - a "Web Browser (Netscape)" entry on the dtwm Workspace (root) menu
#        - (the stock Personal-Applications subpanel Netscape control stays too)
#   4. clear stale Netscape locks left by the pre-retronet internet config
#
# KNOBS (env overrides, all optional):
#   RN_HOME   corpus home-page URL   (default http://search.retronet/ — the
#             AltaVista/Yahoo-style portal the gateway serves; any corpus site,
#             e.g. http://www.spacejam.com/, also works)
#   RN_USER   the CDE autologin user (default guest)
#
# Tru64's /bin/sh is the legacy Bourne shell and lacks $(...); re-exec under ksh.
if [ -z "${_WB_UNDER_KSH:-}" ] && [ -x /bin/ksh ]; then
  _WB_UNDER_KSH=1
  export _WB_UNDER_KSH
  exec /bin/ksh "$0" "$@"
fi

set -u

RN_HOME="${RN_HOME:-http://search.retronet/}"
RN_USER="${RN_USER:-guest}"

NETSCAPE=/usr/bin/X11/netscape
WRAPPER=/usr/local/bin/webbrowser
DT_TYPES=/etc/dt/appconfig/types/C
DT_CONFIG=/etc/dt/config/C
SYS_DTWMRC=/usr/dt/config/C/sys.dtwmrc
MARK="# retronet-web-browser (install-webbrowser.sh) — regenerated, do not hand-edit"

say() { echo "install-webbrowser: $*"; }
die() {
  echo "install-webbrowser: FATAL: $*" >&2
  exit 1
}

[ "$(id -u)" = 0 ] || die "must run as root (writes /etc/dt, /usr/local/bin, /home/$RN_USER)"

USER_HOME="$(eval echo "~$RN_USER" 2>/dev/null)"
case "$USER_HOME" in
  /*) : ;;
  *) USER_HOME="/home/$RN_USER" ;;
esac
NS_DIR="$USER_HOME/.netscape"

# ---------------------------------------------------------------------------
# 1. Netscape present?  (verify — the base 5.1B install carries it)
# ---------------------------------------------------------------------------
if [ -x "$NETSCAPE" ] || [ -h "$NETSCAPE" ]; then
  say "Netscape found at $NETSCAPE"
else
  echo "install-webbrowser: Netscape is NOT installed at $NETSCAPE." >&2
  echo "  It ships in the Tru64 UNIX 5.1B Operating System media (the OS CD is" >&2
  echo "  attached to this guest as DKA400). Install its subset, then re-run:" >&2
  echo "      mount -r -t cdfs -o noversion /dev/disk/cdrom0c /mnt" >&2
  echo "      setld -l /mnt        # select the Netscape Communicator subset" >&2
  echo "      umount /mnt" >&2
  die "Netscape binary missing — install it from the OS CD (see above) and re-run."
fi

# ---------------------------------------------------------------------------
# 2a. webbrowser wrapper — opens Netscape at the corpus home by default
# ---------------------------------------------------------------------------
mkdir -p /usr/local/bin
cat >"$WRAPPER" <<EOF
#!/bin/sh
$MARK
# webbrowser - open the exhibit's graphical browser: Netscape Communicator 4.76,
# pointed at the retronet corpus. Run as '$RN_USER'. An explicit URL wins.
DISPLAY=\${DISPLAY:-:0}
export DISPLAY
URL=\${1:-$RN_HOME}
exec $NETSCAPE "\$URL"
EOF
chmod 755 "$WRAPPER"
say "wrote $WRAPPER (default home: $RN_HOME)"

# ---------------------------------------------------------------------------
# 2b. Netscape preferences — corpus home page, open-at-home, NO proxy
#     (seamless DNS: every name -> gateway -> :80 origin -> corpus). The corpus
#     needs no proxy; force direct so a stale pre-retronet proxy can't linger.
# ---------------------------------------------------------------------------
mkdir -p "$NS_DIR"
PREFS="$NS_DIR/preferences.js"
TMP="$NS_DIR/.preferences.js.wb$$"
[ -f "$PREFS" ] || : >"$PREFS"
# drop any prior copies of the keys we own, then append the desired values.
grep -v \
  -e 'browser\.startup\.homepage' \
  -e 'browser\.startup\.page' \
  -e 'browser\.startup\.homepage_override' \
  -e 'network\.proxy\.type' \
  "$PREFS" >"$TMP" 2>/dev/null || : >"$TMP"
cat >>"$TMP" <<EOF
user_pref("browser.startup.homepage", "$RN_HOME");
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage_override", false);
user_pref("network.proxy.type", 0);
EOF
mv "$TMP" "$PREFS"
say "set $PREFS home -> $RN_HOME (open-at-home, direct/no-proxy)"

# ---------------------------------------------------------------------------
# 2c. clear stale Netscape lock(s) — the pre-retronet config left a
#     lock -> <old-ip>:<pid> symlink that makes Netscape think it is running.
# ---------------------------------------------------------------------------
rm -f "$NS_DIR/lock"
say "cleared stale Netscape lock (if any)"

# ---------------------------------------------------------------------------
# 3a. CDE action — RetronetWeb: launch the wrapper (corpus home)
# ---------------------------------------------------------------------------
mkdir -p "$DT_TYPES"
cat >"$DT_TYPES/RetronetWeb.dt" <<EOF
set DtDbVersion=1.0
$MARK
#
# RetronetWeb — open Netscape Communicator on the retronet corpus.
#
ACTION RetronetWeb
{
	LABEL		Web Browser
	TYPE		COMMAND
	EXEC_STRING	$WRAPPER
	WINDOW_TYPE	NO_STDIO
	ICON		Netscape
	DESCRIPTION	Browse the retronet with Netscape Communicator 4.76
}
EOF
say "wrote $DT_TYPES/RetronetWeb.dt"

# ---------------------------------------------------------------------------
# 3b. MAIN Front-Panel icon — override the Top-box spacer "Blank1" (position 6)
#     with a labelled, clickable "Web" control. Site /etc/dt overrides the
#     stock /usr/dt/appconfig/types/C/dtwm.fp record of the same name.
# ---------------------------------------------------------------------------
cat >"$DT_TYPES/RetronetWeb.fp" <<EOF
set DtDbVersion=1.0
$MARK
#
# A prominent Web control on the MAIN front-panel row. It reuses the "Blank1"
# spacer slot (Top box, position 6) so it lands among the standard icons
# instead of being buried in a subpanel.
#
CONTROL Blank1
{
	TYPE		icon
	CONTAINER_NAME	Top
	CONTAINER_TYPE	BOX
	POSITION_HINTS	6
	ICON		Netscape
	LABEL		Web
	PUSH_ACTION	RetronetWeb
	HELP_STRING	Browse the retronet with Netscape Communicator 4.76
}
EOF
say "wrote $DT_TYPES/RetronetWeb.fp (main-panel 'Web' icon at Top:6)"

# ---------------------------------------------------------------------------
# 3c. dtwm Workspace (root) menu — add "Web Browser (Netscape)" near the top.
#     Regenerate the site copy from the system default each run so re-running
#     never double-inserts.
# ---------------------------------------------------------------------------
mkdir -p "$DT_CONFIG"
[ -f "$SYS_DTWMRC" ] || die "system dtwmrc missing: $SYS_DTWMRC"
awk '
	{ print }
	/"Workspace Menu"[ \t]+f\.title/ && !done {
		print "    \"Web Browser (Netscape)\"\tf.exec \"/usr/local/bin/webbrowser\""
		done = 1
	}
' "$SYS_DTWMRC" >"$DT_CONFIG/sys.dtwmrc.wb$$"
if grep -q 'Web Browser (Netscape)' "$DT_CONFIG/sys.dtwmrc.wb$$"; then
  # stamp the marker on line 1 for provenance, then install atomically
  {
    echo "$MARK"
    cat "$DT_CONFIG/sys.dtwmrc.wb$$"
  } >"$DT_CONFIG/sys.dtwmrc.wb2$$"
  mv "$DT_CONFIG/sys.dtwmrc.wb2$$" "$DT_CONFIG/sys.dtwmrc"
  rm -f "$DT_CONFIG/sys.dtwmrc.wb$$"
  say "wrote $DT_CONFIG/sys.dtwmrc (Workspace-menu 'Web Browser (Netscape)')"
else
  rm -f "$DT_CONFIG/sys.dtwmrc.wb$$"
  die "could not find the Workspace-menu title in $SYS_DTWMRC to anchor the entry"
fi

# ---------------------------------------------------------------------------
# 4. ownership — the guest user must own its own dot-files
# ---------------------------------------------------------------------------
if [ -d "$NS_DIR" ]; then
  chown "$RN_USER" "$NS_DIR" "$PREFS" 2>/dev/null || true
  # match the group to the user's primary group where possible
  GRP="$(id -gn "$RN_USER" 2>/dev/null || echo users)"
  chgrp "$GRP" "$NS_DIR" "$PREFS" 2>/dev/null || true
fi

say "DONE. To make the launcher appear, restart the CDE session/panel:"
say "  restart the workspace manager (root menu -> Restart Workspace Manager),"
say "  or restart dtlogin: /sbin/init.d/xlogin stop && /sbin/init.d/xlogin start"
say "The exhibit golden should be RE-BAKED from a session started after this runs."
