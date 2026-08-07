#!/bin/sh
set -eu

CC=${CC:-/usr/sfw/bin/gcc}
LD=${LD:-/usr/ccs/bin/ld}

"$CC" -D_KERNEL -m64 -mcmodel=kernel -mno-red-zone -ffreestanding \
  -nodefaultlibs -Wall -Wextra -c galleryhid.c -o galleryhid.o
"$LD" -r -o galleryhid galleryhid.o
file galleryhid.o galleryhid
