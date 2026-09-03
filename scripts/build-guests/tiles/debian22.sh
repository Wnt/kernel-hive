#!/bin/bash
# shellcheck disable=SC2016,SC2129  # literal $1$ MD5 hashes in single quotes; per-line >> appends are deliberate
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
# It boots straight into X (inittab `x1` respawns `su - gallery -c startx`,
# NO shell redirection on that line, /etc/X11/Xserver = Anybody), Window Maker
# + the GNOME 1.0 panel in ~75 s with hdparm -d1 DMA (66 MB/s). x11warp: the
# ne2k_pci NIC on SLIRP + /etc/X0.hosts = 10.0.2.2; the host forwards
# 127.0.0.1:6082 -> :6000 and warps the pointer through the guest X server.
# Bake: warp the pointer onto the terminal, one PS/2 click, `clear`, warp to
# 512,384, HMP `savevm golden`. Proof: tiles/debian22/xwarp.py HOST PORT X,Y…
#
# Usage: R=/data/vms/sandbox/<session>/smoke  B=<dir with closure.py + XF86Config>  bash debian22.sh
# =============================================================================
set -e
umask 022
for N in 5 6 7 8 9 10 11; do [ "$(cat /sys/block/nbd$N/size)" = 0 ] && qemu-nbd -c /dev/nbd$N "$R"/disk.qcow2 && break; done
echo "$N" >"$B"/nbd.dev
sleep 1
partprobe /dev/nbd"$N" 2>/dev/null || true
sleep 1
mke2fs -q -t ext2 -O none -I 128 -L potato /dev/nbd"${N}"p1
mkswap /dev/nbd"${N}"p2 >/dev/null
mkdir -p "$M" "$CD"
mount /dev/nbd"${N}"p1 "$M"
mount -o loop,ro /data/assets-staging/debian22/debian-2.2-i386-cd1.iso "$CD"
tar -xzpf /data/assets-staging/debian22/base2_2.tgz -C "$M"
python3 "$B"/closure.py "$CD"/dists/potato/main/binary-i386/Packages.gz gnome-core gnome-panel gnome-terminal gmc gnome-session xserver-svga xbase-clients xfonts-base xfonts-75dpi xterm wmaker >"$B"/closure.txt 2>"$B"/closure.err
wc -l "$B"/closure.txt
cat "$B"/closure.err
mkdir -p "$M"/var/lib/dpkg/info
while read -r f; do
  [ -f "$CD"/"$f" ] || {
    echo "NOFILE $f"
    continue
  }
  dpkg-deb -x "$CD"/"$f" "$M"
  p=$(dpkg-deb -f "$CD"/"$f" Package)
  dpkg-deb -e "$CD"/"$f" "$B"/ctl
  for c in "$B"/ctl/*; do [ "$(basename "$c")" = control ] || cp "$c" "$M/var/lib/dpkg/info/$p.$(basename "$c")"; done
  {
    dpkg-deb -f "$CD"/"$f" | sed '1a Status: install ok unpacked'
    echo
  } >>"$M"/var/lib/dpkg/status
  rm -rf "$B"/ctl
done <"$B"/closure.txt
# GnomeICU's contact list is client-local (a v5 client ignores the server-side
# SSI roster), so HiveBot is seeded into its gnome_config file. NOTE: seeding
# [Contacts] alone did NOT take on 0.90b (proven 2026-09-03) — kept here as the
# documented starting point, not as a working recipe. See STATION-debian22.md.
# --- retronet extras that are NOT on CD1: Netscape Navigator 4.77 (non-free),
# staged as .debs in /data/assets-staging/debian22/deb/ (check-assets.sh pins
# their hashes). Same unpack + dpkg-status shape as the CD loop above.
for f in /data/assets-staging/debian22/deb/*.deb; do
  dpkg-deb -x "$f" "$M"
  p=$(dpkg-deb -f "$f" Package)
  dpkg-deb -e "$f" "$B"/ctl
  for c in "$B"/ctl/*; do [ "$(basename "$c")" = control ] || cp "$c" "$M/var/lib/dpkg/info/$p.$(basename "$c")"; done
  {
    dpkg-deb -f "$f" | sed '1a Status: install ok unpacked'
    echo
  } >>"$M"/var/lib/dpkg/status
  rm -rf "$B"/ctl
done
# update-alternatives never ran (no postinst), so there is no /usr/bin/netscape
# and no /usr/bin/navigator-smotif-477 -> the wrapper. The real binary is
# .../navigator/navigator-smotif.real; .../477/netscape is a DIRECTORY, which is
# what an `Exit 126 … is a directory` in the guest terminal means.
mkdir -p "$M"/usr/bin
ln -sf /usr/lib/netscape/477/navigator/navigator-smotif "$M"/usr/bin/navigator-smotif-477
ln -sf /usr/bin/navigator-smotif-477 "$M"/usr/bin/netscape
# ...and navigator-smotif is itself a symlink to ../../base-4/wrapper, i.e.
# /usr/lib/netscape/base-4/wrapper, which lives in a THIRD package in a THIRD
# section: netscape-base-4 1:4.77-1 in potato **contrib** (netscape-base-477's
# `Depends: netscape-base-4` resolves nowhere inside main+non-free, which is
# exactly the `MISSING netscape-base-4` closure.py prints). Without it the
# wrapper symlink dangles and bash reports `No such file or directory` for a
# path that ls shows — the wrapper, not the target, is what is absent.
# --- X traps (all framebuffer-proven 2026-09-03) ---
for d in "$M"/usr/X11R6/lib/X11/fonts/*/; do
  n=$(basename "$d")
  cat "$M"/etc/X11/fonts/"$n"/*.alias >"$d"/fonts.alias 2>/dev/null || true
  (cd "$d" && mkfontdir .)
done                                      # fixed alias lives in /etc/X11/fonts; postinst never ran
chmod -R a+rX "$M"/usr/X11R6 "$M"/etc/X11 # host umask left fonts.dir/XF86Config 0600
chmod 4755 "$M"/usr/bin/X11/XF86_SVGA     # no Xwrapper on potato; server must be setuid
echo /usr/X11R6/lib >>"$M"/etc/ld.so.conf # libXmu.so.6 not found otherwise (ldconfig runs in rcS)
printf '127.0.0.1\tlocalhost potato\n10.0.2.2\tslirphost\n10.99.0.2\tgateway search.retronet\n' >"$M"/etc/hosts
printf 'nameserver 10.99.0.2\nsearch retronet.lab\n' >"$M"/etc/resolv.conf   # retronet wildcard DNS (docs/lab/retronet/WEB-PLANE-PLAN.md); reached over eth1, never a default route
echo 10.0.2.2 >"$M"/etc/X0.hosts # x11warp: the SLIRP peer may connect to the guest X server (never xhost +)
cp "$B"/XF86Config "$M"/etc/X11/XF86Config
chmod 644 "$M"/etc/X11/XF86Config # clgd5446 + no_bitblt + 1024x768x16
ln -sf /usr/bin/X11/XF86_SVGA "$M"/etc/X11/X
printf '/usr/bin/X11/XF86_SVGA\nAnybody\n' >"$M"/etc/X11/Xserver # Debian's xserver wrapper policy: 'Console' refuses an init-spawned (no utmp) session with 'user not authorized to run the X server'
# --- system ---
printf '/dev/hda1 / ext2 defaults,errors=remount-ro 0 1\n/dev/hda2 none swap sw 0 0\nproc /proc proc defaults 0 0\n' >"$M"/etc/fstab
rm -f "$M"/etc/rc2.d/S11pcmcia "$M"/etc/rc2.d/S14ppp "$M"/etc/rcS.d/S15isapnp "$M"/etc/rcS.d/S45mountnfs.sh "$M"/etc/rc2.d/S20inetd "$M"/etc/rc2.d/S20logoutd "$M"/etc/rc2.d/S99gdm "$M"/etc/rc2.d/S99xdm
sed -i 's|^root:[^:]*:|root:$1$1AtcCd5Y$b6VhRV4dhtzRRxtApk4Qh1:|' "$M"/etc/passwd
echo 'gallery:$1$vEGce7Pd$tHczNC9lOCXCQ66lqbhAH0:1000:1000:Gallery:/home/gallery:/bin/bash' >>"$M"/etc/passwd
echo 'gallery:x:1000:' >>"$M"/etc/group
mkdir -p "$M"/home/gallery
printf '#!/bin/sh\nxset s off; xset -dpms\nwmaker &\nsleep 3\ngnome-terminal --geometry 80x24+240+300 &\nexec gnome-session\n' >"$M"/home/gallery/.xsession
cp "$M"/home/gallery/.xsession "$M"/home/gallery/.xinitrc
chmod +x "$M"/home/gallery/.xsession "$M"/home/gallery/.xinitrc
mkdir -p "$M"/home/gallery/.netscape
# Netscape 4.77 first run: a pre-existing preferences.js skips the licence
# dialog; proxy type 0 = direct, because the retronet DNS resolves every name to
# the gateway and its :80 origin serves the corpus (the "seamless web").
cat >"$M"/home/gallery/.netscape/preferences.js <<'NSP'
// Netscape User Preferences
user_pref("browser.startup.homepage", "http://search.retronet/");
user_pref("browser.startup.page", 1);
user_pref("network.proxy.type", 0);
user_pref("browser.wfe.ignore_def_check", true);
user_pref("browser.startup.license_accepted", true);
NSP
chown -R 1000:1000 "$M"/home/gallery
sed -i 's|^2:23:respawn.*|x1:2345:respawn:/bin/su - gallery -c /usr/bin/X11/startx|' "$M"/etc/inittab # NO redirection: init passes the line verbatim to su, '>/dev/null 2>&1' became su arguments and startx never ran (proven 2026-09-03; redhat62 uses this exact shape)
echo potato >"$M"/etc/hostname
dpkg-deb -x "$CD"/dists/potato/main/binary-i386/base/kernel-image-2.2.17_2.2.17pre6-1.deb "$M"
echo "3e0551105e370f916354c6685f848988a664f01a2ba31ab842512ee33b1b20a9  /data/assets-staging/debian22/hdparm.deb" | sha256sum -c - >/dev/null && dpkg-deb -x /data/assets-staging/debian22/hdparm.deb "$M" # hdparm 3.6-1 is not on CD1: archive.debian.org potato/main/admin
sed -i "2i /sbin/insmod /lib/modules/2.2.17/misc/unix.o >/dev/null 2>&1" "$M"/etc/init.d/rcS
echo "mkdir -p /tmp/.X11-unix; chown root:root /tmp/.X11-unix; chmod 1777 /tmp/.X11-unix   # bootmisc cleans /tmp; X aborts on a gallery-owned socket dir" >>"$M"/etc/init.d/rcS
echo "/sbin/insmod /lib/modules/2.2.17/net/8390.o >/dev/null 2>&1; /sbin/insmod /lib/modules/2.2.17/net/ne2k-pci.o >/dev/null 2>&1; /sbin/ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up   # ne2k_pci on SLIRP: x11warp reaches X :0 via the hostfwd. NO default route here — with restrict=on there is nothing to route to, and the default route belongs to the retronet side" >>"$M"/etc/init.d/rcS
echo "/sbin/insmod /lib/modules/2.2.17/net/rtl8139.o >/dev/null 2>&1; /sbin/ifconfig eth1 10.99.0.36 netmask 255.255.255.0 up; /sbin/route add default gw 10.99.0.2   # retronet: the SECOND NIC is an rtl8139 on tap debian22rn0/vmbr-rn, deliberately a DIFFERENT driver from the slirp ne2k_pci so the interface numbering is deterministic (ne2k-pci.o=eth0, rtl8139.o=eth1). Static per WEB-PLANE-PLAN: potato's boot tree has no DHCP client. NO default route via it (containment Lock 1)" >>"$M"/etc/init.d/rcS
echo "/sbin/hdparm -d1 /dev/hda >/dev/null 2>&1   # PIIX bus-master DMA on the UP 2.2 kernel: 60+ MB/s instead of 27 KB/s PIO under KVM (redhat62 wave, proven)" >>"$M"/etc/init.d/rcS
echo "/sbin/ldconfig >/dev/null 2>&1   # after / is rw: at the top of rcS the cache write fails silently (libXmu.so.6 not found)" >>"$M"/etc/init.d/rcS
rm -f "$M"/sbin/unconfigured.sh "$M"/etc/rcS.d/S20modutils "$M"/etc/rc2.d/S12kerneld "$M"/etc/rc2.d/S20makedev
mkdir -p "$M"/lib/modules/2.2.17
du -sh "$M"
sync
umount "$M"
umount "$CD"
qemu-nbd -d /dev/nbd"$N"
rm -f "$R"/qmp.sock "$R"/hmp.sock "$R"/qemu.pid
cd "$R"
export SH_DBUS_UPDATE_MS=4
nohup qemu-system-x86_64 -name debian22-smoke -nodefaults -enable-kvm -machine pc-i440fx-11.0 -cpu host -m 256 -smp 1 -rtc base=localtime -drive file="$R"/disk.qcow2,format=qcow2,if=ide,index=0 -drive file=/data/assets-staging/debian22/debian-2.2-i386-cd1.iso,media=cdrom,if=ide,index=2 -boot order=d -vga cirrus -netdev user,id=n0,restrict=on,hostfwd=tcp:127.0.0.1:${X11WARP_PORT:-6082}-10.0.2.15:6000 -device ne2k_pci,netdev=n0 -netdev tap,id=n1,ifname=${RN_TAP_IF:-debian22rn0},script=no,downscript=no -device rtl8139,netdev=n1,mac=52:54:00:52:4e:24 -display dbus,p2p=on -qmp unix:"$R"/qmp.sock,server=on,wait=off -monitor unix:"$R"/hmp.sock,server,nowait -pidfile "$R"/qemu.pid >"$R"/qemu.log 2>&1 &
sleep 2
cat "$R"/qemu.pid
bash "$R"/run-daemon.sh >/dev/null 2>&1
chmod -R a+rwX "$R"
echo relaunched
