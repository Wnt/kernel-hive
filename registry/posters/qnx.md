---
title: QNX Neutrino 6.5
subtitle: 2010 · Real-time microkernel
hero: /posters/qnx/desktop.webp
images:
  - src: /posters/qnx/desktop.webp
    alt: QNX Photon microGUI desktop and application shelf
    caption: Photon places a compact graphical workstation above QNX’s message-passing real-time microkernel.
---
## Origins

QNX began in 1980, when Gordon Bell and Dan Dodge — students in the same real-time operating systems course at the University of Waterloo, where they had built a small kernel as coursework — decided it had a market and moved to the high-tech belt outside Ottawa to found the company that became QNX Software Systems. The product was called QUNIX, until a letter from AT&T's lawyers, who owned the UNIX trademark, shortened it to QNX; the company followed. Its defining architecture placed a small kernel at the center of message passing among processes, drivers, filesystems, and network services, and the first release, in 1982, ran on the Intel 8088. That foundation became a commercial platform for industrial control, telecommunications, vehicles, medical equipment, and other systems where timing and failure boundaries matter.

Neutrino, introduced in the 1990s, extended the architecture across several processor families. QNX 6.5, released in 2010, combined the microkernel with POSIX-oriented development tools, networking, filesystems, and the Photon microGUI. Photon itself followed QNX’s modular instincts and could provide an embedded panel or a complete desktop from the same components.

## Significance

QNX demonstrates that an operating system may prioritize deterministic response and service isolation without abandoning a rich user environment. Drivers and services running outside the kernel can be restarted or constrained more readily than monolithic kernel components, while priority scheduling supports workloads with explicit deadlines. These qualities explain QNX’s presence in systems users rarely identify as computers.

Its graphical history also includes the famous QNX demo disk, which compressed a bootable OS, desktop, networking, and web browser onto a floppy. The demonstration was theatrical, but it accurately expressed an engineering culture centered on small, composable services.

## What you're looking at

Photon presents the application shelf, pterm, and the period Voyager browser.

## Legacy

BlackBerry acquired QNX in 2010, and the system became especially prominent in automotive software while continuing across industrial fields. Its microkernel design remains a practical deployed architecture, not merely an academic proposal — the same bet appears on the BeOS tile in this gallery, and on the Haiku tile that carries BeOS on, where drivers and the desktop alike live outside a small kernel as replaceable processes. The Photon desktop in this exhibit makes that otherwise hidden infrastructure visible: a real-time system capable of presenting itself as an ordinary workstation.
