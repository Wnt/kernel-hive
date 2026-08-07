# Cross-build the QNX 6.5 gallery-hid devi input module (galleryhid.so).
#
# Requires a QNX 6.5 SDP host toolchain (qcc / ntox86-gcc) + the Input DDK
# headers (<devi.h>, struct packet_abs).  The QNX 6.5 LiveCD tile ships NO
# in-guest compiler (only ntox86-ld), so this MUST be cross-compiled off-box and
# the resulting .so staged into the guest (see README.md).
#
#   source ~/qnx650/qnx650-env.sh      # sets QNX_HOST / QNX_TARGET / PATH
#   make                               # -> galleryhid.so
#
# qcc target selector -Vgcc_ntox86 = 32-bit x86 QNX (matches the tile's -cpu).

QCC     ?= qcc
TARGET  ?= gcc_ntox86
CFLAGS  ?= -V$(TARGET) -shared -fPIC -Wall -Wextra -O2
LDLIBS  ?=

all: galleryhid.so

galleryhid.so: galleryhid.c
	$(QCC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f galleryhid.so galleryhid.o

.PHONY: all clean
