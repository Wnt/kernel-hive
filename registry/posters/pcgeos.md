---
title: PC/GEOS Ensemble
subtitle: 1990 · a multitasking GUI in 640 KB, from Berkeley Softworks to open source
hero: /posters/pcgeos/desktop.webp
images:
  - src: /posters/pcgeos/desktop.webp
    alt: The PC/GEOS desktop at 800x600 — an orange sandstone-canyon wallpaper, Computer, Documents and World folder icons top left, a Wastebasket bottom right, a grey taskbar with a clock reading 12:41 AM, and the Express menu open on the left listing Calculator, Character Map, Clock, Perf, Scrapbook, Screen Dumper, Text File Editor, Calendar, Contacts, Email, GeoCalc, GeoDraw, GeoFile, GeoPoint, GeoWrite, Preferences and WebMagick, then Extras, Games, Printer Status, Go to GeoManager and Exit to DOS
    caption: The Express menu, opened with Ctrl+Esc, is the whole application list — the productivity suite in the middle, the desk accessories above it, and Exit to DOS at the bottom, because underneath all of this is still FreeDOS.
  - src: /posters/pcgeos/geowrite.webp
    alt: GeoWrite open over the desktop — a grey document window titled GeoWrite with File, Edit, View, Options, Layout, Graphic, Paragraph, Character and Window menus, two rows of toolbar icons, a vertical drawing-tool palette on the left and a blank page in the middle; the taskbar shows a GeoWrite button beside the GEOS logo
    caption: GeoWrite, the word processor. The page is drawn with the same scalable outline fonts the printer gets, which in 1990 was one of the product's main selling points.
  - src: /posters/pcgeos/bare.webp
    alt: The bare PC/GEOS desktop — canyon wallpaper, the three folder icons, the Wastebasket, the taskbar and clock, and an arrow pointer near the top left
    caption: The desktop as it appears about twenty-five seconds after power-on, once FreeDOS has handed over to loader.exe.
---
## Origins

In 1990 **Berkeley Softworks** — the company that had already squeezed a windowing desktop called GEOS onto the Commodore 64, which is the machine the hall's `c64` exhibit runs — renamed itself **GeoWorks** and shipped **GeoWorks Ensemble 1.0** for the IBM PC. It was a complete graphical environment: a kernel with preemptive multitasking, an object-oriented user-interface toolkit, scalable outline fonts, a file manager and a suite of applications, and it ran in the 640 KB of a 286-class machine, on top of DOS. Windows 3.0 shipped the same year, and was the product Ensemble was measured against.

The company's fortunes did not follow the engineering. GeoWorks licensed the platform to AOL, whose first DOS client was built on it, and later pointed it at handhelds and set-top boxes, but the desktop product changed hands: **NewDeal Office** carried it through the late 1990s, and **Breadbox Ensemble** through the 2000s. In 2018 the code base was released as open source under the Apache 2.0 licence, as **PC/GEOS**, and it is now maintained as the bluewaysw/pcgeos project on GitHub. What runs in this exhibit is a current build from that repository, installed over FreeDOS 1.3.

## Significance

Ensemble is the clearest surviving demonstration that a small, coherent operating system could have been the PC's graphical future. Everything on screen — windows, menus, the taskbar, the icons, the text in the document window — is drawn by GEOS's own graphics system rather than by DOS or the BIOS, and every application is built from the same object classes, so the environment is consistent in a way early Windows was not. The scalable fonts, rendered on screen exactly as they would print, were a selling point before TrueType reached Windows.

It is also a rare case of a 1990 commercial GUI whose full source became free software while the people who wrote it were still around to maintain it. The applications in the Express menu — GeoWrite, GeoDraw, GeoCalc, GeoFile, the desk accessories — are the shipping product, not a reconstruction.

## What you're looking at

A PC with 64 MB of RAM (GEOS will use a fraction of it), a standard VGA card driven through GEOS's VESA driver at 800 by 600 in 64 K colours, a Sound Blaster 16, and a PS/2 mouse. FreeDOS 1.3 boots, loads a mouse driver, and starts `loader.exe` from `C:\ENSEMBLE`; about twenty-five seconds after power-on the desktop is up.

The desktop is GeoManager's. **Computer**, **Documents** and **World** open folder windows; **Wastebasket** is where deletions go. Press **Ctrl+Esc** for the Express menu and pick an application with the arrow keys and Enter, or the mouse. **GeoWrite** is the word processor, **GeoDraw** the vector drawing program, **GeoCalc** the spreadsheet, **GeoFile** the database; **Games** is a submenu of its own. The desktop, the taskbar and the clock are all part of GEOS itself.

The disk is a single image, and the exhibit restores it when it resets, so a document you write belongs to your visit.

## Legacy

The GEOS lineage is present twice in this hall: on the `c64` exhibit, where the same company's earlier design runs on an 8-bit machine with 64 KB, and here, where the PC version shows what that idea grew into. Neither displaced the platforms it competed with — the 8-bit GEOS lost to the end of the 8-bit era, Ensemble lost to Windows — but the PC branch is the one that survived as a living code base, still built, still booting on a plain PC, and still fitting in memory that a 1990 machine could afford.
