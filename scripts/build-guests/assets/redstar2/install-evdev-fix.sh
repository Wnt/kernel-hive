#!/bin/sh
set -eu

CD=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
WORK=/tmp/redstar2-evdev-build
MODULE=/usr/lib/xorg/modules/input/evdev_drv.so

rm -rf "$WORK"
mkdir -p "$WORK"

# These preservation RPMs are build tools only.  --nodeps is intentional:
# Red Star adds an rs2.0 release suffix to otherwise matching Fedora-era
# glibc/Xorg packages, which RPM does not consider an exact release match.
rpm -ivh --replacepkgs --nodeps \
  "$CD"/binutils-2.17.50.0.3-6.i386.rpm \
  "$CD"/gcc-4.1.1-30.i386.rpm \
  "$CD"/glibc-headers-2.5-3.i386.rpm \
  "$CD"/glibc-devel-2.5-3.i386.rpm \
  "$CD"/pkgconfig-0.21-1.fc6.i386.rpm \
  "$CD"/xorg-x11-proto-devel-7.2-9.fc7.i386.rpm \
  "$CD"/xorg-x11-server-sdk-1.3.0.0-17.fc7.i386.rpm

tar -xjf "$CD"/xf86-input-evdev-1.1.5.tar.bz2 -C "$WORK"
cd "$WORK"/xf86-input-evdev-1.1.5
sed -i \
  's/state->abs->v\[0\], state->abs->v\[1\]/state->axes->v[0], state->axes->v[1]/' \
  src/evdev_axes.c
grep -q 'state->axes->v\[0\], state->axes->v\[1\]' src/evdev_axes.c
./configure --disable-static --with-xorg-module-dir=/usr/lib/xorg/modules
make

test -s src/.libs/evdev_drv.so
test -s "$MODULE"
cp -p "$MODULE" "$MODULE.redstar2-original"
install -m 0755 src/.libs/evdev_drv.so "$MODULE"
sync

echo 'REDSTAR2_EVDEV_FIX_INSTALLED'
