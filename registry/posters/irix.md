---
title: SGI Indy — IRIX 6.5
subtitle: 1993 · MIPS workstation Unix
hero: /posters/irix/desktop.webp
images:
  - src: /posters/irix/desktop.webp
    alt: The IRIX 6.5 Indigo Magic Desktop with the Toolchest, a file manager, the Icon Catalog, and FSN, SGI's 3D file system navigator
    caption: The Indigo Magic Desktop under 4Dwm — the Toolchest at upper left, an open file manager and the Icon Catalog, gr_osview reporting CPU usage, and FSN, the 3D file system navigator SGI wrote for IRIX and the one the world met as the "Unix system" in Jurassic Park, flying over /usr/demos/Performer/bin.
---
## Origins

Silicon Graphics introduced the Indy in July 1993 as its entry-level workstation, and marketed it as a machine that could bring SGI's graphics tradition to a far wider audience than the expensive Indigo and Onyx systems above it. The industrial design was deliberately unmistakable: a low blue-violet pizza-box chassis that looked like nothing else on an engineering desk. Inside sat a MIPS processor — this exhibit runs the R4600 configuration — together with a 24-bit XL framebuffer, and, unusually for the period, a digital video camera and video capture hardware included as standard equipment rather than sold as an option.

The Indy's graphics were also the source of its most repeated joke, that it was "an Indigo without the go," because the base XL configuration provided a colour framebuffer without the hardware geometry engine that accelerated three-dimensional work on costlier SGI models. The quip was fair and also incomplete. What the Indy actually delivered was a genuine Unix workstation — networked, 64-bit capable, colour-correct, and equipped with real video I/O — at a price that put it into universities, broadcast facilities, and design studios in large numbers.

## Significance

IRIX was SGI's own Unix, built on System V with BSD extensions and steadily extended over more than a decade. Several of its ideas outlived the hardware. XFS, the journalling filesystem developed for IRIX in the early 1990s to handle large media files and high throughput, was later released as free software and remains in wide use on Linux today. OpenGL likewise began at SGI, generalized from the company's earlier proprietary IRIS GL, and became the graphics interface that the rest of the industry standardized on.

IRIX 6.5, first released in 1998, was the final major release line and received maintenance updates until 2006; the version in this exhibit is 6.5.22. Its desktop is the Indigo Magic Desktop, running under the 4Dwm window manager, which SGI derived from Motif's mwm and then styled heavily — the drop-shadowed icons, the engraved bevels, and the distinctive teal-and-grey palette are all SGI's own work rather than stock Motif. The Toolchest in the upper-left corner is the environment's signature control: a permanently docked strip of menus from which the whole system is reached.

## What you're looking at

The system shown here is an IRIX 6.5 install. The demos user is logged in to an Indigo Magic Desktop session under 4Dwm, with the Toolchest docked in the upper-left corner carrying the standard Desktop, Selected, Internet, Find, System, and Help menus. Down the right edge are desktop icons for the machine's own microphone, camera, and CD-ROM — the Indy shipped with audio and video capture as standard equipment rather than as options.

Behind the other windows, a winterm terminal has the machine describe itself: `uname -a` answers IRIX 6.5 on an IP22, and `hinv` names the MIPS R4600. A file manager is browsing `/usr`, and the Icon Catalog is open on its DesktopTools page — SoftwareManager, insight, xcalc, gr_osview and the rest of the stock tools. `gr_osview` is running too, at the lower right, drawing a live bar of processor usage.

The large window is FSN, the three-dimensional file system navigator SGI wrote for IRIX. Directories become pedestals and files become blocks, height standing for size and colour for age against the legend along the bottom; here the camera has flown down into `/usr/demos/Performer/bin`, with the small overview window mapping its position in the wider tree. FSN is the program a character in *Jurassic Park* recognises on sight, and this is the real thing rather than a prop — SGI gave it away from its own FTP site, and the binary running here was built in December 1996.

## Legacy

SGI's commercial decline through the 2000s was steep, and the workstation line did not survive it. The influence did. Graphics hardware everywhere descends from the pipeline SGI defined, OpenGL and its successors remain the vocabulary of real-time rendering, and XFS still stores files on Linux systems that have never heard of an Indy. The visual culture endured too: for a generation, IRIX was what serious computer graphics looked like — the machines behind the effects work of the early 1990s, and, in one famously accurate movie scene, the 3D file browser a character recognizes on sight as a Unix system.

What remains here is the everyday texture rather than the legend. A teal desktop, a docked menu strip, a browser reading a local page, and a Unix workstation quietly waiting for input.
