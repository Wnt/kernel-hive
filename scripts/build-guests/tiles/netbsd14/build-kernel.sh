#!/bin/sh
# In-guest: sh /mnt/build-kernel.sh KHCONS|KHMIN   (extras CD mounted on /mnt)
set -e
C=${1:-KHCONS}
cd / && tar xzpf /mnt/syssrc.tgz
cp "/mnt/$C" "/usr/src/sys/arch/i386/conf/$C"
cd /usr/src/sys/arch/i386/conf && config "$C"
cd "../compile/$C" && make depend && make
cp /netbsd /netbsd.GENERIC
cp netbsd /netbsd
sync
echo "KERNEL-BUILT-$C"
