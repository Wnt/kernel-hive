#!/bin/bash
# =============================================================================
# build-guests/tiles/debian22.sh — compose the Debian GNU/Linux 2.2 "potato"
# (i386) station disk ON THE HOST, then boot it once for the golden bake.
#
# WHY HOST-SIDE (measured 2026-09-03, three waves independently): a Linux 2.2
# kernel writes an emulated IDE disk in 16-bit PIO under KVM, one VM exit per
# outw, ~27 KB/s. dbootstrap's mke2fs alone did not finish in 13 minutes; the
# interactive CD install is not viable. So: mke2fs on the host (-I 128: 2.2
# rejects 256-byte inodes), base2_2.tgz + a Depends closure of the X/GNOME
# .debs from CD1 unpacked with dpkg-deb -x (dpkg status stanzas written so the
# guest's dpkg agrees), the eight X traps below fixed in the tree, then the
# guest is booted from the CD prompt with `linux root=/dev/hda1` (no boot
# loader on the disk; the golden vmstate carries the running kernel).
#
# Runs as root on labhost (scripts/dev/labrun). Inputs (pinned in
# check-assets.sh): /data/assets-staging/debian22/{debian-2.2-i386-cd1.iso,
# base2_2.tgz}. Output: $R/disk.qcow2 (2 GiB qcow2 with hda1 ext2 + hda2 swap,
# partition table made once with fdisk from the rescue shell: hda1 cyl 1-483,
# hda2 cyl 484-520, CHS 520/128/63) booted on the EXACT launcher device set
# (streamhost/stations/debian22/qemu-streamhost.sh) with -boot order=d.
#
# After it boots to the login prompt: log in root on tty1, run
#   su - gallery -c /usr/bin/X11/startx >/root/x.log 2>&1 &
# wait for Window Maker + the GNOME 1.0 panel (~1-2 min: fonts and libraries
# come through the PIO path), click the terminal, `xset m 1 1; clear`, then
# HMP `savevm golden`. init cannot start X here (no controlling tty; proven),
# and hdparm is not on CD1, so DMA (`hdparm -d1 /dev/hda`, proven 60+ MB/s by
# the redhat62 wave) is a follow-up — see docs/guests/debian22.md.
#
# Usage: R=/data/vms/sandbox/<session>/smoke  B=<dir with closure.py + XF86Config>  bash debian22.sh
# =============================================================================
set -e; umask 022
R="${R:-/data/vms/sandbox/debian22/smoke}"
B="${B:-$(cd "$(dirname "$0")" && pwd)/debian22}"
M="$B/mnt"; CD="$B/cd"
[ -f "$R/disk.qcow2" ] || qemu-img create -f qcow2 "$R/disk.qcow2" 2G
if [ -f "$R/qemu.pid" ]; then kill "$(cat "$R/qemu.pid")" 2>/dev/null || true; sleep 2; fi
set -e; umask 022
for N in 5 6 7 8 9 10 11; do [ "$(cat /sys/block/nbd$N/size)" = 0 ] && qemu-nbd -c /dev/nbd$N $R/disk.qcow2 && break; done
echo $N > $B/nbd.dev; sleep 1; partprobe /dev/nbd$N 2>/dev/null || true; sleep 1
mke2fs -q -t ext2 -O none -I 128 -L potato /dev/nbd${N}p1
mkswap /dev/nbd${N}p2 >/dev/null
mkdir -p $M $CD; mount /dev/nbd${N}p1 $M; mount -o loop,ro /data/assets-staging/debian22/debian-2.2-i386-cd1.iso $CD
tar -xzpf /data/assets-staging/debian22/base2_2.tgz -C $M
python3 $B/closure.py $CD/dists/potato/main/binary-i386/Packages.gz gnome-core gnome-panel gnome-terminal gmc gnome-session xserver-svga xbase-clients xfonts-base xfonts-75dpi xterm wmaker hdparm > $B/closure.txt 2>$B/closure.err
wc -l $B/closure.txt; cat $B/closure.err
mkdir -p $M/var/lib/dpkg/info
while read f; do
  [ -f $CD/$f ] || { echo "NOFILE $f"; continue; }
  dpkg-deb -x $CD/$f $M
  p=$(dpkg-deb -f $CD/$f Package); dpkg-deb -e $CD/$f $B/ctl; for c in $B/ctl/*; do [ "$(basename $c)" = control ] || cp "$c" "$M/var/lib/dpkg/info/$p.$(basename "$c")"; done
  { dpkg-deb -f $CD/$f | sed '1a Status: install ok unpacked'; echo; } >> $M/var/lib/dpkg/status; rm -rf $B/ctl
done < $B/closure.txt
# --- X traps (all framebuffer-proven 2026-09-03) ---
for d in $M/usr/X11R6/lib/X11/fonts/*/; do n=$(basename $d); cat $M/etc/X11/fonts/$n/*.alias > $d/fonts.alias 2>/dev/null || true; (cd $d && mkfontdir .); done   # fixed alias lives in /etc/X11/fonts; postinst never ran
chmod -R a+rX $M/usr/X11R6 $M/etc/X11                       # host umask left fonts.dir/XF86Config 0600
chmod 4755 $M/usr/bin/X11/XF86_SVGA                          # no Xwrapper on potato; server must be setuid
echo /usr/X11R6/lib >> $M/etc/ld.so.conf                     # libXmu.so.6 not found otherwise (ldconfig runs in rcS)
printf '127.0.0.1\tlocalhost potato\n' > $M/etc/hosts
cp $B/XF86Config $M/etc/X11/XF86Config; chmod 644 $M/etc/X11/XF86Config   # clgd5446 + no_bitblt + 1024x768x16
ln -sf /usr/bin/X11/XF86_SVGA $M/etc/X11/X
# --- system ---
printf '/dev/hda1 / ext2 defaults,errors=remount-ro 0 1\n/dev/hda2 none swap sw 0 0\nproc /proc proc defaults 0 0\n' > $M/etc/fstab
rm -f $M/etc/rc2.d/S11pcmcia $M/etc/rc2.d/S14ppp $M/etc/rcS.d/S15isapnp $M/etc/rcS.d/S45mountnfs.sh $M/etc/rc2.d/S20inetd $M/etc/rc2.d/S20logoutd $M/etc/rc2.d/S99gdm $M/etc/rc2.d/S99xdm
sed -i 's|^root:[^:]*:|root:$1$1AtcCd5Y$b6VhRV4dhtzRRxtApk4Qh1:|' $M/etc/passwd
echo 'gallery:$1$vEGce7Pd$tHczNC9lOCXCQ66lqbhAH0:1000:1000:Gallery:/home/gallery:/bin/bash' >> $M/etc/passwd
echo 'gallery:x:1000:' >> $M/etc/group
mkdir -p $M/home/gallery
printf '#!/bin/sh\nxset s off; xset -dpms\nwmaker &\nsleep 3\ngnome-terminal --geometry 80x24+240+300 &\nexec gnome-session\n' > $M/home/gallery/.xsession
cp $M/home/gallery/.xsession $M/home/gallery/.xinitrc; chmod +x $M/home/gallery/.xsession $M/home/gallery/.xinitrc
chown -R 1000:1000 $M/home/gallery
# no inittab autologin: X started by init has no controlling tty and never spawns (proven 2026-09-03); the golden vmstate carries the running session, X is started once from the root console at bake time
echo potato > $M/etc/hostname
dpkg-deb -x $CD/dists/potato/main/binary-i386/base/kernel-image-2.2.17_2.2.17pre6-1.deb $M
sed -i "2i /sbin/insmod /lib/modules/2.2.17/misc/unix.o >/dev/null 2>&1" $M/etc/init.d/rcS
echo "mkdir -p /tmp/.X11-unix; chown root:root /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix   # bootmisc cleans /tmp; X aborts on a gallery-owned socket dir" >> $M/etc/init.d/rcS
echo "/sbin/hdparm -d1 /dev/hda >/dev/null 2>&1   # PIIX bus-master DMA on the UP 2.2 kernel: 60+ MB/s instead of 27 KB/s PIO under KVM (redhat62 wave, proven)" >> $M/etc/init.d/rcS
echo "/sbin/ldconfig >/dev/null 2>&1   # after / is rw: at the top of rcS the cache write fails silently (libXmu.so.6 not found)" >> $M/etc/init.d/rcS
rm -f $M/sbin/unconfigured.sh $M/etc/rcS.d/S20modutils $M/etc/rc2.d/S12kerneld $M/etc/rc2.d/S20makedev
mkdir -p $M/lib/modules/2.2.17; du -sh $M; sync; umount $M; umount $CD; qemu-nbd -d /dev/nbd$N
rm -f $R/qmp.sock $R/hmp.sock $R/qemu.pid
cd $R; export SH_DBUS_UPDATE_MS=4
nohup qemu-system-x86_64 -name debian22-smoke -nodefaults -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 256 -smp 1 -rtc base=localtime -drive file=$R/disk.qcow2,format=qcow2,if=ide,index=0 -drive file=/data/assets-staging/debian22/debian-2.2-i386-cd1.iso,media=cdrom,if=ide,index=2 -boot order=d -vga cirrus -display dbus,p2p=on -qmp unix:$R/qmp.sock,server=on,wait=off -monitor unix:$R/hmp.sock,server,nowait -pidfile $R/qemu.pid >$R/qemu.log 2>&1 &
sleep 2; cat $R/qemu.pid; bash $R/run-daemon.sh >/dev/null 2>&1; chmod -R a+rwX $R; echo relaunched
