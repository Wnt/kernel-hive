---
title: HP-UX 10.20 / HP VUE
subtitle: 1996 · Hewlett-Packard's own Motif desktop on PA-RISC
hero: /posters/hpuxvue/desktop.webp
images:
  - src: /posters/hpuxvue/desktop.webp
    alt: Placeholder card for the HP-UX 10.20 station while the operating system is being installed live — a dark slate frame with the station name
    caption: Install in progress. This card is replaced by the real HP VUE desktop once the installation completes and the golden fixture is baked.
---
## Origins

HP-UX is Hewlett-Packard's System V Unix for the HP 9000 line, and by the mid-1990s it ran on HP's own PA-RISC processors — the architecture HP designed when the 68000-based Series 300 workstations ran out of headroom. Release 10.20, from 1996, is the version that stayed in service longest: it was the last HP-UX many sites ever upgraded, and it was still receiving patches into the 2000s.

The desktop it shipped with tells a story of its own. **HP VUE — the Visual User Environment** — arrived with HP-UX 9.0 in 1992: a Motif front panel with a workspace switcher, a file manager, a help system and a style manager, all drawn in HP's characteristic bevelled grey-and-blue. When HP, IBM, Sun and Novell agreed on a Common Desktop Environment in 1993, VUE was the design they started from; CDE is, to a first approximation, VUE with the HP branding filed off. 10.20 was the release where CDE became the default — but VUE was still on the media and still selectable at the login screen, and that is the desktop this station shows.

## Significance

VUE matters because it is the missing link. Visitors who have seen the CDE stations in this hall — Solaris, Tru64, OpenVMS — will recognise the front panel, the drawers, the workspace buttons; here they can see the vendor original that those were standardised from, with its own window manager (`vuewm`) and its own front-panel controls, a year or two before it became everybody's desktop.

The hardware underneath is a **HP 9000 Model 778 (Visualize B160L)** — a 160 MHz PA-7300LC workstation from 1996 with HP's built-in **Artist** graphics. There is no separate firmware to source: PA-RISC boots through its own Processor Dependent Code, and the emulator provides that itself.

## What you're looking at

Right now: the HP-UX 10.20 installer, running live from the Install and Core OS CD, on an emulated B160L. The install is being done on camera; this station is not yet announced in the hall. When it is finished, this card will show the HP VUE desktop at 1280×1024 — the highest resolution the emulated Artist framebuffer can be trusted at.

## Legacy

HP-UX outlived VUE by decades: it moved to Itanium, and Hewlett Packard Enterprise still supports it. VUE itself vanished with HP-UX 11.00 in 1997. Its ideas did not — they are the shape of CDE, and CDE's front panel is the shape a whole generation of Unix workstations shared.
