#!/bin/sh
# build-browser.sh — Lynx 2.8.2rel.1 (1999-06-03) for NetBSD 1.4.1/i386.
# Source: invisible-island.net/archives/lynx/tarballs/lynx2.8.2rel.1.tar.gz
# sha256 cb974227c268269f74072d0e9d26c7b42190cf77d9e1e082bbdd74390ba6a6ec
set -e
SRC=${1:-/mnt/lynx2.8.2rel.1.tar.gz}
cd /usr/local/src || {
  mkdir -p /usr/local/src
  cd /usr/local/src
}
rm -rf lynx2-8-2
gunzip -c "$SRC" | tar xf -
cd lynx2-8-2
CFLAGS="-O" ./configure --prefix=/usr/local --with-screen=curses --disable-nls
make
make install
/usr/local/bin/lynx -version || true
