#!/bin/sh
# build-im.sh — mICQ 0.4.12 (OSCAR v8) for NetBSD 1.4.1/i386, gcc 2.7.2.2.
# Source: sourceforge.net/projects/climm/files/OldFiles/micq-0.4.12.tgz
# sha256 9fd47c90be48a7d9d41d2bb4c5c9c00496206afab3d0eb9ff7916d41b46641f7
set -e
SRC=${1:-/mnt/micq-0.4.12.tgz}
cd /usr/local/src || {
  mkdir -p /usr/local/src
  cd /usr/local/src
}
rm -rf micq-0.4.12
gunzip -c "$SRC" | tar xf -
cd micq-0.4.12
CFLAGS="-O" ./configure --prefix=/usr/local --disable-ssl --disable-tcl --disable-nls
make
make install
/usr/local/bin/micq --version || true
