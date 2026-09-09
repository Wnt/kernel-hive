#!/bin/bash
# compose.sh — build the Slackware 3.4 root filesystem HOST-SIDE (labhost, root) from the
# mirror .tgz packages: no interactive setup, no floppy dance. Slackware packages are plain
# tarballs relative to /; their install/doinst.sh scripts are written to run with cwd = the
# install root using relative paths, so we run them with the host sh and a no-op ldconfig.
set -euo pipefail
# Resolved BEFORE the script cds into the composed root — $0 is relative.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-/data/assets-staging/slackware/slakware}
OUT=${OUT:-/data/vms/sandbox/slackware/build}
ROOT=$OUT/root
DISK_MB=${DISK_MB:-400}
XDEPTH=${XDEPTH:-16}
XOPTS=${XOPTS:-no_bitblt} # extra Option lines for the Device section, e.g. noaccel
PKGS_A="aaa_base bash devs etc shadow hdsetup ide lilo sysvinit bin ldso getty gzip bzip2 ps aoutlibs elflibs util minicom cpio e2fsbn find grep kbd pnp sh_utils sysklogd tar tcsh txtutils zoneinfo less bsdlpr modules"
PKGS_AP="manpgs sudo joe bc diff sc zsh ash jpeg mc vim"
PKGS_X="fvwm fvwmicns x331bin x331cfg x331doc x331fnts x331lib x331man x331svga x331vg16 x331fscl xlock xpm"
PKGS_XAP="fvwm95 libgr xv xfm xpaint xgames arena"
PKGS_Y="bsdgames"
# n6 tcpip: ifconfig/route/rc.inet1 + inetd/in.telnetd -- the x11warp absolute pointer and
# the retronet link both need guest TCP/IP; n3 lynx is the text-mode web fallback.
PKGS_N="tcpip lynx"
# d series: gcc 2.7.2.3 + binutils + kernel headers + libc5 dev + GNU make + ncurses.
# A 1997 Linux workstation ships a C compiler, and the retronet ICQ client (micq) is
# BUILT IN THE GUEST with exactly this toolchain (docs/lab/retronet/STATION-slackware.md).
PKGS_D="binutils gcc2723 linuxinc libc gmake ncurses"
rm -rf "$ROOT"
mkdir -p "$ROOT" "$OUT/noop"
for t in ldconfig depmod chroot; do
  printf '#!/bin/sh\nexit 0\n' >"$OUT/noop/$t"
  chmod +x "$OUT/noop/$t"
done
inst() { # series pkg
  local f
  f=$(find "$SRC" -path "$SRC/$1*/$2.tgz" 2>/dev/null | head -1 || true)
  [ -n "$f" ] || {
    echo "MISSING $1/$2"
    return 1
  }
  tar xzpf "$f" --numeric-owner -C "$ROOT"
  mkdir -p "$ROOT/var/log/packages"
  tar tzf "$f" >"$ROOT/var/log/packages/$2"
  if [ -f "$ROOT/install/doinst.sh" ]; then
    (cd "$ROOT" && PATH="$OUT/noop:$PATH" COLOR=on sh install/doinst.sh >/dev/null 2>&1) || echo "  doinst[$2] rc=$?"
  fi
  rm -rf "$ROOT/install"
}
for p in $PKGS_A; do inst a "$p"; done
for p in $PKGS_AP; do inst ap "$p"; done
for p in $PKGS_X; do inst x "$p"; done
for p in $PKGS_XAP; do inst xap "$p"; done
for p in $PKGS_Y; do inst y "$p"; done
for p in $PKGS_N; do inst n "$p"; done
for p in $PKGS_D; do inst d "$p"; done
echo "packages: $(find "$ROOT/var/log/packages" -type f | wc -l)"

# ---- soname links: libc5-era Slackware leaves these to ldconfig (which we neutered) ----
cd "$ROOT"
for d in lib usr/lib usr/X11R6/lib usr/i486-linux-libc5/lib usr/lib/X11; do
  [ -d "$d" ] || continue
  for f in "$d"/*.so.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    so=$(readelf -d "$f" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p' | head -1 || true)
    [ -n "$so" ] || so=$(basename "$f" | sed -E 's/^(lib[^.]*\.so\.[0-9]+).*/\1/')
    [ -n "$so" ] && [ "$so" != "$(basename "$f")" ] && [ ! -e "$d/$so" ] && ln -s "$(basename "$f")" "$d/$so"
  done
done
[ -e lib/ld-linux.so.1 ] || ln -s ld-linux.so.1.9.5 lib/ld-linux.so.1
# shellcheck disable=SC2012 # diagnostic listing only
ls -la lib/ld-linux.so.1 lib/libc.so.5 lib/libm.so.5 usr/X11R6/lib/libX11.so.6 2>&1 | sed 's|^|  link: |' || true

# ---- site configuration ----
cd "$ROOT"
cat >etc/fstab <<'F'
/dev/hda1        /                ext2        defaults   1   1
none             /proc            proc        defaults   0   0
F
echo darkstar >etc/HOSTNAME
# ---- network: the RETRONET bridge, statically addressed ------------------------
# Slackware 3.4 predates DHCP on this media (no dhcpcd/pump anywhere in the a/n series),
# so the address is hand-configured here and the DHCP reservation on the gateway exists
# only as the plane's uniqueness ledger (docs/lab/retronet/WEB-PLANE-PLAN.md).
#   * 10.99.0.31/24 on vmbr-rn, NE2000 ISA (ne.o module at io 0x300), MAC 52:54:00:52:4e:1f.
#   * NO default route: every retronet target (gateway 10.99.0.2, labhost 10.99.0.1, the
#     other stations) is on-link, and no-default-route is retronet containment Lock 2.
#   * This ONE link carries three things: the x11warp absolute pointer (labhost dials
#     10.99.0.31:6000), the museum web (proxy 10.99.0.2:3128), and ICQ (10.99.0.2 UDP 4000).
RN_IP=${RN_IP:-10.99.0.31}
RN_GW_CT=${RN_GW_CT:-10.99.0.2}     # retronet gateway CT 951: proxy, DNS, :80 origin, OSCAR
RN_LABHOST=${RN_LABHOST:-10.99.0.1} # vmbr-rn's own address — the x11warp client's source IP
printf '127.0.0.1\tlocalhost\n%s\tdarkstar.retronet.lab darkstar\n%s\tgateway search.retronet\n%s\tlabhost\n' \
  "$RN_IP" "$RN_GW_CT" "$RN_LABHOST" >etc/hosts
cat >etc/rc.d/rc.inet1 <<F
#!/bin/sh
# Kernel Hive: static retronet address; the NE2000 module is loaded by rc.modules.
# No default route on purpose — see compose.sh and docs/lab/retronet/STATION-slackware.md.
/sbin/ifconfig lo 127.0.0.1
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo
/sbin/ifconfig eth0 $RN_IP broadcast 10.99.0.255 netmask 255.255.255.0
/sbin/route add -net 10.99.0.0 netmask 255.255.255.0 eth0
F
chmod 755 etc/rc.d/rc.inet1
# resolv.conf: retronet-dns answers EVERY name with the gateway. Arena/lynx only ever
# talk to the proxy by IP, so this is a convenience, not a dependency.
printf 'domain retronet.lab\nnameserver %s\n' "$RN_GW_CT" >etc/resolv.conf
# rc.inet2: inetd with telnet ONLY — this is the station's exec channel (labctl exec),
# dialled by labhost over the bridge. The containment chain (RN chain in rn-tapnet.sh)
# drops every NEW flow the guest starts toward labhost, so telnetd is reachable inward
# and grants the guest nothing outward.
cat >etc/rc.d/rc.inet2 <<'F'
#!/bin/sh
# Kernel Hive: no portmap, no rpc, no sendmail. inetd serves exactly one service.
if [ -x /usr/sbin/inetd ]; then
  /usr/sbin/inetd
  echo "inetd started (telnet only)"
fi
F
chmod 755 etc/rc.d/rc.inet2
# One service, and it is deliberate. Everything else stays commented out as shipped.
printf 'telnet\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\tin.telnetd\n' >etc/inetd.conf.kh
grep -v '^telnet' etc/inetd.conf >etc/inetd.conf.new || true
cat etc/inetd.conf.new etc/inetd.conf.kh >etc/inetd.conf
rm -f etc/inetd.conf.new etc/inetd.conf.kh
# login(1) refuses root on a tty that is not in securetty, which is every pty — so a
# telnet exec channel with the museum's empty root password needs the ptys listed.
for n in p q r s; do for c in 0 1 2 3 4 5 6 7 8 9 a b c d e f; do echo "tty$n$c"; done; done >>etc/securetty
# tcpd: labhost (the bridge address) is the ONLY client of the exec channel.
printf 'in.telnetd: %s\n' "$RN_LABHOST" >etc/hosts.allow
printf 'ALL: ALL\n' >etc/hosts.deny
cat >>etc/rc.d/rc.modules <<'F'

# Kernel Hive: QEMU ne2k_isa (io 0x300, irq 9) — the retronet link
/sbin/modprobe ne io=0x300
F
# ---- museum web: the corpus proxy, for every browser and every shell -------------
# Arena (libwww) and lynx both read http_proxy from the environment; lynx also reads
# /usr/lib/lynx/lynx.cfg. The gateway proxy is corpus-only and has no upstream.
cat >etc/profile.d.kh-proxy <<F
# Kernel Hive: the retronet museum web. There is no other internet.
http_proxy=http://$RN_GW_CT:3128/
ftp_proxy=http://$RN_GW_CT:3128/
no_proxy=localhost,127.0.0.1
WWW_HOME=http://search.retronet/
export http_proxy ftp_proxy no_proxy WWW_HOME
F
cat etc/profile.d.kh-proxy >>etc/profile
rm -f etc/profile.d.kh-proxy
if [ -f usr/lib/lynx/lynx.cfg ]; then
  printf '\n# Kernel Hive: the museum corpus proxy\nhttp_proxy:http://%s:3128/\nSTARTFILE:http://search.retronet/\n' "$RN_GW_CT" >>usr/lib/lynx/lynx.cfg
fi
cat >etc/lilo.conf <<'F'
boot = /dev/hda
delay = 5
vga = normal
image = /vmlinuz
  root = /dev/hda1
  label = linux
  read-only
F
# root with an empty password, in both files (shadow suite is installed)
sed -i 's|^root:[^:]*:|root::|' etc/passwd
[ -f etc/shadow ] && sed -i 's|^root:[^:]*:|root::|' etc/shadow
# X: XFree86 3.3.1 on QEMU's CL-GD5446 (cirrus), Microsoft serial mouse on ttyS0 (QEMU -chardev msmouse)
FP=""
for d in misc 75dpi Type1 Speedo 100dpi; do [ -d usr/X11R6/lib/fonts/$d ] && FP="$FP    FontPath \"/usr/X11R6/lib/X11/fonts/$d/\"\n"; done
cat >etc/XF86Config <<F
# Kernel Hive: XFree86 3.3.1 on QEMU cirrus (CL-GD5446, 4 MB), 1024x768, serial mouse.
Section "Files"
    RgbPath   "/usr/X11R6/lib/X11/rgb"
$(printf "%b" "$FP")EndSection
Section "ServerFlags"
    DontZap
EndSection
Section "Keyboard"
    Protocol    "Standard"
    AutoRepeat  500 30
    XkbRules    "xfree86"
    XkbModel    "pc101"
    XkbLayout   "us"
EndSection
Section "Pointer"
    Protocol    "Microsoft"
    Device      "/dev/ttyS0"
    BaudRate    1200
    SampleRate  150
EndSection
Section "Monitor"
    Identifier  "kh"
    VendorName  "Unknown"
    ModelName   "Unknown"
    HorizSync   30-70
    VertRefresh 50-100
    Modeline "1024x768"  65.00 1024 1048 1184 1344  768 771 777 806 -hsync -vsync
    Modeline "800x600"   40.00  800  840  968 1056  600 601 605 628 +hsync +vsync
    Modeline "640x480"   25.175 640  664  760  800  480 491 493 525
EndSection
Section "Device"
    Identifier  "cirrus"
    VendorName  "Cirrus Logic"
    BoardName   "CL-GD5446"
    Chipset     "clgd5446"
    VideoRam    4096
    Option      "sw_cursor"
$(for o in $XOPTS; do echo "    Option      \"$o\""; done)
EndSection
Section "Screen"
    Driver      "svga"
    Device      "cirrus"
    Monitor     "kh"
    DefaultColorDepth $XDEPTH
    Subsection "Display"
        Depth       16
        Modes       "1024x768"
        ViewPort    0 0
    EndSubsection
    Subsection "Display"
        Depth       8
        Modes       "1024x768"
        ViewPort    0 0
    EndSubsection
EndSection
Section "Screen"
    Driver      "vga16"
    Device      "cirrus"
    Monitor     "kh"
    Subsection "Display"
        Modes       "640x480"
        ViewPort    0 0
    EndSubsection
EndSection
F
# the session: fvwm95 desktop + one xterm; screensaver off
WM=fvwm95-2
[ -x usr/X11R6/bin/fvwm95-2 ] || WM=fvwm2
(cd var/X11R6/bin && rm -f X && ln -sf /usr/X11R6/bin/XF86_SVGA X)
cat >root/.xinitrc <<F
#!/bin/sh
xset s off 2>/dev/null
xset -dpms 2>/dev/null
xset m 1 1
# The daemon's x11warp absolute pointer dials this X server from labhost, whose source
# address on vmbr-rn is the bridge itself. Without this ACL every XWarpPointer is refused
# and the station silently falls back to relative motion.
xhost +$RN_LABHOST >/dev/null 2>&1
xsetroot -solid "#2f4f6f"
xterm -geometry 80x18+48+40 -sb -title "darkstar" &
xclock -geometry 120x120-40+40 &
# The retronet ICQ client. micq is a terminal client (no GUI ICQ client for libc5/1997
# exists — see docs/lab/retronet/STATION-slackware.md), so the exhibit's IM surface is
# an xterm that owns the client, exactly as solaris ran climm in a dtterm.
[ -x /usr/local/bin/micq ] && xterm -geometry 80x22+48+320 -sb -title "ICQ - retronet" \\
  -bg "#000040" -fg "#e0e0e0" -e /usr/local/bin/icq-session &
exec $WM > /var/log/wm.log 2>&1
F
chmod 755 root/.xinitrc
[ -f var/X11R6/lib/fvwm95-2/system.fvwm2rc95 ] && cp var/X11R6/lib/fvwm95-2/system.fvwm2rc95 root/.fvwm2rc95

# ---- the museum web browser, discoverable from the desktop ----------------------
# Arena (W3C's HTML3 testbed, xap1, June 1996) is the ONLY graphical browser on the
# Slackware 3.4 media; it is a single static binary in /usr/X11R6/bin. It predates the
# Host: header, so it uses the gateway's :3128 PROXY door, never the :80 origin
# (docs/lab/retronet/WEB-PLANE-PLAN.md). The wrapper pins the proxy and the home page so
# a browser launched from a menu — with no login shell, hence no /etc/profile — still
# reaches the corpus.
mkdir -p usr/local/bin
cat >usr/local/bin/webbrowser <<F
#!/bin/sh
# Kernel Hive: the retronet museum web. There is no other internet.
http_proxy=http://$RN_GW_CT:3128/; export http_proxy
ftp_proxy=http://$RN_GW_CT:3128/; export ftp_proxy
WWW_HOME=http://search.retronet/; export WWW_HOME
exec /usr/X11R6/bin/arena "\${1:-http://search.retronet/}"
F
chmod 755 usr/local/bin/webbrowser
# The ICQ session wrapper: micq has no auto-reconnect of its own, so the xterm re-runs it.
cat >usr/local/bin/icq-session <<'F'
#!/bin/sh
# Kernel Hive: keep the retronet ICQ client on the air. micq exits on a dropped
# session; the exhibit must not be left with a dead window (the beos/ICBM lesson,
# docs/lab/retronet/STATION-beos.md).
cd /root || exit 1
while : ; do
  /usr/local/bin/micq
  echo "--- micq exited; reconnecting in 5s (Ctrl-C to stay out) ---"
  sleep 5
done
F
chmod 755 usr/local/bin/icq-session
# ---- fvwm95: Start menu entries + dock buttons for the browser and the IM client ----
# The stock system.fvwm2rc95 even ships a commented-out Netscape button and a
# mini-nscape.xpm icon; the museum's browser takes that slot.
if [ -f root/.fvwm2rc95 ]; then
  # Start menu, at the top where a visitor looks first.
  sed -i 's|^\+ "New shell        %mini-sh1.xpm%".*|+ "Web browser      %mini-nscape.xpm%"      Exec    /usr/local/bin/webbrowser \&\n+ "ICQ (retronet)   %mini-mail.xpm%"        Exec    xterm -geometry 80x24 -title "ICQ - retronet" -bg "#000040" -fg "#e0e0e0" -e /usr/local/bin/icq-session \&\n+ ""                                        Nop\n\0|' root/.fvwm2rc95
  # Dock (FvwmButtons, bottom right): a labelled browser button in the Netscape slot.
  sed -i 's|^#\*FvwmButtons netscape nscape.xpm.*|*FvwmButtons web     nscape.xpm  Exec    "Web" /usr/local/bin/webbrowser \&|' root/.fvwm2rc95
  grep -c 'webbrowser' root/.fvwm2rc95 | sed 's|^|  fvwm95 browser hooks: |'
fi
# ---- the retronet ICQ client -----------------------------------------------------
# micq 0.4.x speaks the PRE-OSCAR ICQ v5 protocol over UDP 4000 — the gateway door beos
# already uses (docs/lab/retronet/GATEWAY.md §Ports). It is BUILT IN THE GUEST with the
# d-series gcc 2.7.2.3 (libc5 binaries will not run in a host chroot on this kernel:
# every one of them dies with "Out of virtual memory"), and the resulting binary plus the
# source tarball are staged so this builder is reproducible without a boot.
EXTRAS=${EXTRAS:-/data/assets-staging/slackware/extras}
if [ -x "$EXTRAS/micq" ]; then
  install -m 755 "$EXTRAS/micq" usr/local/bin/micq
  echo "  micq: installed from $EXTRAS/micq"
else
  echo "  micq: MISSING at $EXTRAS/micq — the ICQ half of the station will not start"
fi
# ~/.micqrc: UIN, password and the client-side contact list. ICQ v5 has NO server-side
# roster (SSI/feedbag is OSCAR-only), so the contact list is a GUEST-SIDE file and
# scripts/retronet/icq/roster.json is mirrored into it here, not seeded over the wire.
RN_UIN=${RN_UIN:-18400}
# The roster: read straight out of scripts/retronet/icq/roster.json (every onboarded
# station except this one, plus the bot), so the two can never drift. ICQ v5 has no
# server-side roster, so this file IS slackware's contact list — see
# docs/lab/retronet/CONTACT-SEEDER.md and STATION-slackware.md.
ROSTER_JSON=${ROSTER_JSON:-$SELF_DIR/../../../retronet/icq/roster.json}
if [ -z "${RN_ROSTER:-}" ] && [ -r "$ROSTER_JSON" ]; then
  RN_ROSTER=$(
    python3 - "$ROSTER_JSON" <<'PYEOF'
import json
import sys

d = json.load(open(sys.argv[1]))
rows = [(d["bot"]["uin"], d["bot"]["nick"])]
rows += [
    (s["uin"], s["nick"])
    for s in d["stations"]
    if s.get("onboarded") and s["station"] != "slackware"
]
print("\n".join(f"{u} {n}" for u, n in rows))
PYEOF
  )
fi
[ -n "${RN_ROSTER:-}" ] || RN_ROSTER="10000 HiveBot"
echo "  micqrc: $(printf '%s\n' "$RN_ROSTER" | grep -c .) contacts from $ROSTER_JSON"
# The password is box-local, never committed: registry/local.env holds it (the same
# split every other retronet station uses). A composed image without it still boots —
# the client simply fails to sign in, loudly, in its own xterm.
LOCAL_ENV=${LOCAL_ENV:-/data/kernel-hive/registry/local.env}
# shellcheck disable=SC1090 # box-local, gitignored, may be absent
[ -z "${RN_PASS:-}" ] && [ -r "$LOCAL_ENV" ] && RN_PASS=$(sed -n 's/^RETRONET_ICQ_SLACKWARE_PASS=//p' "$LOCAL_ENV" | head -1)
RN_PASS=${RN_PASS:-changeme}
[ "$RN_PASS" = changeme ] && echo "  micqrc: WARNING no RETRONET_ICQ_SLACKWARE_PASS in $LOCAL_ENV"
cat >root/.micqrc <<F
# Kernel Hive: retronet ICQ. Generated by compose.sh — edits here are lost on rebuild.
# Keys are micq 0.4.3's own (file_util.c Read_RC/Save_RC): they are case-insensitive
# words, and everything after the bare word "Contacts" is "<uin> <nickname>" rows.
UIN $RN_UIN
Password $RN_PASS
Server $RN_GW_CT
Port 4000
Status 0
Auto_away 0
# ICQ v5 has NO server-side roster — SSI/feedbag is an OSCAR service — so this list is
# the station's contact list, generated by compose.sh from scripts/retronet/icq/roster.json.
# It is the reason seed_contacts.py ssi does nothing for this station.
Contacts
$RN_ROSTER
F
chmod 600 root/.micqrc
# The source the guest's own gcc built /usr/local/bin/micq from, kept on the disk: this
# station SHIPS a C compiler, and a visitor who types `cd /usr/src/micq && make` gets the
# same binary back. It is also the reproducibility record for the staged one.
if [ -f "$EXTRAS/micq_0.4.3.orig.tar.gz" ]; then
  mkdir -p usr/src
  tar xzf "$EXTRAS/micq_0.4.3.orig.tar.gz" -C usr/src
  rm -rf usr/src/micq
  mv usr/src/micq-0.4.3.orig usr/src/micq
  PATCH=$SELF_DIR/../../patches/micq-0.4.3-quiet-retronet-chatter.patch
  if [ -f "$PATCH" ]; then
    (cd usr/src/micq && patch -p1 --batch --forward <"$PATCH" >/dev/null) && echo "  micq: retronet-chatter patch applied"
  else
    echo "  micq: WARNING patch not found at $PATCH — the ICQ window will scroll for ever"
  fi
  echo "  micq: source unpacked into /usr/src/micq"
fi
# autostart X on boot (rc.local runs last in rc.M); a cold boot lands on the desktop
cat >>etc/rc.d/rc.local <<'F'

# Kernel Hive: bring the desktop up on every boot (no login prompt to answer)
if [ -x /usr/X11R6/bin/startx ]; then
  ( sleep 2; cd /root; HOME=/root PATH=/usr/X11R6/bin:$PATH /usr/X11R6/bin/startx >/var/log/startx.log 2>&1 ) &
fi
F
chmod 755 etc/rc.d/rc.local
set +e
# shellcheck disable=SC2012 # diagnostic listings only
ls -la var/X11R6/bin/X usr/X11R6/bin/XF86_SVGA "usr/X11R6/bin/$WM" 2>&1 | sed 's|^|  |'
# shellcheck disable=SC2012
ls usr/X11R6/lib/fonts/ 2>&1 | sed 's|^|  fonts: |'
# shellcheck disable=SC2012
ls var/X11R6/lib/xinit/ 2>&1 | sed 's|^|  xinit: |'
grep -c FontPath etc/XF86Config
du -sh "$ROOT" | sed 's|^|  root: |'
set -e

# ---- disk: one bootable primary partition at sector 63, rev-0 ext2 (kernel 2.0 mounts nothing newer) ----
cd "$OUT"
rm -f disk.raw disk.qcow2
truncate -s "${DISK_MB}M" disk.raw
printf 'label: dos\nstart=63, type=83, bootable\n' | sfdisk -q disk.raw
BLOCKS=$(((DISK_MB * 1024) - 64))
mke2fs -q -F -b 1024 -m 1 -E revision=0,offset=32256 -d "$ROOT" disk.raw $BLOCKS
qemu-img convert -O qcow2 disk.raw disk.qcow2
ls -la disk.raw disk.qcow2
sha256sum disk.raw
echo COMPOSED
