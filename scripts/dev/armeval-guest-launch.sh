#!/bin/bash
# Acorn ARM Evaluation System (1986) kiosk launcher — ARMEVAL-armbasic angle.
# A BBC Micro Model B host (MAME `bbcb`, MOS 1.20) with the ARM Evaluation
# System on the Tube (-tube arm, Executive v1.00 14th August 1986), the Acorn
# 1770 disc interface (ADFS discs are double density; the 8271 cannot read
# them) and Acorn ADFS 1.30 in sideways socket 3. Socket 1 is NOT usable: ADFS
# there stops the Tube from coming up at all. Drive 0 holds Disc 3 of the ARM
# Evaluation System set, 'Utilities 2 / BASIC', which carries ARM BASIC as $.AB
sleep 2
OUT=$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
[ -n "$OUT" ] && xrandr --output "$OUT" --mode 800x600 2>/dev/null || true
xset r off 2>/dev/null || true
exec nice -n 10 /opt/bbcmicro/mame/bbcb bbcb \
  -tube arm \
  -fdc acorn1770 \
  -rom3 /opt/armeval/Acorn-ADFS-1.30.rom \
  -flop1 /opt/armeval/armevaluationsystem-disc3.adl \
  -rompath /opt/bbcmicro/roms \
  -inipath /opt/bbcmicro \
  -skip_gameinfo \
  -artwork_crop \
  -video soft \
  -prescale 1 \
  -autoframeskip \
  -keepaspect \
  -nowindow \
  -nofilter
