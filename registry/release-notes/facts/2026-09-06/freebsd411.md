# freebsd411 — facts from week ending 2026-09-06 ("The mouse finally lands")

Extracted mechanically from the in-progress/append-only week JSON; raw material
for the Sunday authoring pass, not publishable prose on its own.

## From the summary prose

- (New stations) [FreeBSD 4.11](station:freebsd411) joins as the last of the 4.x line, the January 2005 release of the BSD that quietly ran a large share of the early commercial web, here with the full **KDE 3.3.2** desktop from its own release CD: a K menu, a panel, Konqueror, Konsole and a calculator one click away on a 1024×768 screen.

## Bullets

- [FreeBSD 4.11](station:freebsd411) had to be *installed* under pure software emulation and only then run on the hardware virtualiser: its 2005 kernel reads a CD one 16-bit word at a time, and under KVM every word is a trip out of the guest — 70 KB/s, hours for one CD — where the slow emulator manages it twenty times faster
