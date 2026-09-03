#!/bin/bash
# compose.sh — build the Slackware 3.4 root filesystem HOST-SIDE (labhost, root) from the
# mirror .tgz packages: no interactive setup, no floppy dance. Slackware packages are plain
# tarballs relative to /; their install/doinst.sh scripts are written to run with cwd = the
# install root using relative paths, so we run them with the host sh and a no-op ldconfig.
set -euo pipefail
SRC=${SRC:-/data/assets-staging/slackware/slakware}
OUT=${OUT:-/data/vms/sandbox/slackware/build}
ROOT=$OUT/root
DISK_MB=${DISK_MB:-400}
XDEPTH=${XDEPTH:-16}
XOPTS=${XOPTS:-no_bitblt} # extra Option lines for the Device section, e.g. noaccel
PKGS_A="aaa_base bash devs etc shadow hdsetup ide lilo sysvinit bin ldso getty gzip bzip2 ps aoutlibs elflibs util minicom cpio e2fsbn find grep kbd pnp sh_utils sysklogd tar tcsh txtutils zoneinfo less bsdlpr modules"
PKGS_AP="manpgs sudo joe bc diff sc zsh ash jpeg mc vim"
PKGS_X="fvwm fvwmicns x331bin x331cfg x331doc x331fnts x331lib x331man x331svga x331vg16 x331fscl xlock xpm"
PKGS_XAP="fvwm95 libgr xv xfm xpaint xgames"
PKGS_Y="bsdgames"
PKGS_N="tcpip"   # n6: ifconfig/route/rc.inet1 — the x11warp absolute pointer needs guest TCP/IP
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
# ---- network: slirp user-net 10.0.2.0/24, NE2000 ISA at io 0x300 (QEMU ne2k_isa defaults) ----
# The only consumer is the x11warp pointer sink: host 127.0.0.1:6084 -> guest :6000 (X on TCP).
printf '127.0.0.1\tlocalhost\n10.0.2.15\tdarkstar.example.com darkstar\n10.0.2.2\tslirp-host\n' >etc/hosts
cat >etc/rc.d/rc.inet1 <<'F'
#!/bin/sh
# Kernel Hive: static slirp address; the NE2000 module is loaded by rc.modules.
/sbin/ifconfig lo 127.0.0.1
/sbin/route add -net 127.0.0.0 netmask 255.0.0.0 lo
/sbin/ifconfig eth0 10.0.2.15 broadcast 10.0.2.255 netmask 255.255.255.0
/sbin/route add -net 10.0.2.0 netmask 255.255.255.0 eth0
/sbin/route add default gw 10.0.2.2 metric 1
F
chmod 755 etc/rc.d/rc.inet1
printf '#!/bin/sh\n# Kernel Hive: no inetd/portmap -- nothing listens but X.\n' >etc/rc.d/rc.inet2
chmod 755 etc/rc.d/rc.inet2
cat >>etc/rc.d/rc.modules <<'F'

# Kernel Hive: QEMU ne2k_isa (io 0x300, irq 9) for the x11warp pointer forward
/sbin/modprobe ne io=0x300
F
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
xhost +10.0.2.2 >/dev/null 2>&1   # the host's x11warp sink (slirp gateway) may move the pointer
xsetroot -solid "#2f4f6f"
xterm -geometry 80x24+48+40 -sb -title "darkstar" &
xclock -geometry 120x120-40+40 &
exec $WM > /var/log/wm.log 2>&1
F
chmod 755 root/.xinitrc
[ -f var/X11R6/lib/fvwm95-2/system.fvwm2rc95 ] && cp var/X11R6/lib/fvwm95-2/system.fvwm2rc95 root/.fvwm2rc95
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
