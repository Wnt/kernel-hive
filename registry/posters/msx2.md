---
title: MSX2 — a computer standard instead of a computer company
subtitle: Late 1980s · MSX2 · BASIC in ROM, cartridge slots and MSX-DOS 2
hero: /posters/msx2/desktop.webp
images:
  - src: /posters/msx2/desktop.webp
    alt: An MSX2 computer screen showing MSX-BASIC or an MSX-DOS 2 command prompt with colorful 8-bit graphics available
    caption: MSX defined a compatible home-computer platform that many manufacturers could build, especially across Japan and Europe.
---

## Origins

**MSX** was conceived in the early 1980s as a standard for home computers rather than one manufacturer's proprietary machine. ASCII Corporation's Kazuhiko Nishi worked with Microsoft on a specification that could be implemented by companies including Sony, Panasonic, Philips, Yamaha and many others.

An MSX computer therefore had a recognizable software environment even when the badge on the case changed. BASIC lived in ROM, cartridge and disk interfaces were standardized, and software could target a platform rather than a single vendor's model.

**MSX2**, introduced in the mid-1980s, expanded the graphics and memory capabilities while preserving that compatibility.

## Significance

The interesting thing about MSX is geographical as much as technical.

The platform never became dominant in the United States, which makes it easy to omit from histories centered on the Apple II, Commodore 64 and IBM PC. In Japan, the Netherlands, Spain, Brazil and other markets, MSX was a major home-computing standard with its own games, productivity software, music hardware and development culture.

The standardization also points forward. MSX separated the idea of a software platform from a single hardware maker years before commodity PC compatibility made that arrangement ordinary.

**MSX-DOS 2**, released later in the decade, gives the platform a second personality. The machine can begin at a friendly BASIC prompt and then become a disk-oriented command-line computer with subdirectories and a more capable DOS environment.

## What you're looking at

The station is a **Philips NMS 8250** (1987), an ordinary European MSX2 model with one internal 3.5" floppy drive — not a later turbo machine. It runs host-native: MAME's own `nms8250` driver on the exhibit host, publishing its framebuffer directly, the same engine that runs the museum's SAM Coupé and Apple IIe stations.

The rest scene is MSX-BASIC's `Ok` prompt — the machine's own power-on screen. A genuine period MSX-DOS 2 (English) system disk sits in the internal floppy drive; reaching MSX-DOS 2 from BASIC is one command away.

## Legacy

MSX continued through MSX2+, turboR and enthusiast descendants, but its larger legacy is the idea that a home computer could be a multi-vendor standard.

It also fills a gap in the museum's map. The existing European and American 8-bit machines show fierce incompatibility; MSX shows an alternate world where dozens of manufacturers deliberately agreed on the software target.

## Sources

- MSX-DOS 2 history/features: https://www.msx.org/wiki/MSX-DOS_2
- MAME `nms8250` driver: `src/mame/msx/msx2.cpp`
