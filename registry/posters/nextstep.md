---
title: NeXTSTEP 3.3 — the operating system that outlived its computer
subtitle: 1995 · NeXTSTEP 3.3 (NeXTcube)
hero: /posters/nextstep/desktop.webp
images:
  - src: /posters/nextstep/desktop.webp
    alt: The grey NeXTSTEP Workspace with the Workspace menu at the top left, a File Viewer window and the Dock down the right-hand edge
    caption: The Workspace as the machine brings it up for itself. The column of icons on the right is the Dock — this is where it was invented.
---
## Origins

**Steve Jobs was forced out of Apple in September 1985 and started NeXT within weeks.** The plan was a workstation for universities: better than a personal computer, cheaper than the Unix machines from Sun and Apollo, and built to a standard nobody in the education market had asked for. The result, unveiled in 1988, was a one-foot magnesium cube finished in matte black, with a 25 MHz Motorola 68030, a digital signal processor, an optical drive instead of a hard disk, and a 17-inch greyscale monitor whose 1120x832 display had square pixels at a time when very few did.

The hardware was late, expensive and strange. The optical drive was too slow to boot from comfortably; the machine arrived at $6,500 in a market that wanted $3,000; the education-only rule was quietly dropped. NeXT sold roughly fifty thousand computers in total and stopped making them in 1993, four and a half years after the launch.

The software was the part that worked. NeXTSTEP put a Mach microkernel and a 4.3BSD Unix userland underneath a windowing system built on Display PostScript — the same page-description language the printer used, so what appeared on the screen and what came out of the LaserWriter were generated from one description. On top of that sat an application framework written in Objective-C, a language NeXT licensed and then made its own, and Interface Builder, which let you assemble a program's windows by dragging objects onto them and wiring their connections with the mouse. In 1989 that was closer to science fiction than to normal practice.

## Significance

Two things happened on machines like this one that changed what computers are for.

The first is the web. Tim Berners-Lee wrote his proposal for a hypertext system at CERN in 1989 and was given a NeXTcube to develop it on. The first web browser, WorldWideWeb — which was also the first web *editor* — the first web server, and the first web pages were all built on NeXTSTEP, and Berners-Lee said afterwards that the framework was why one person could produce a working browser in a few months rather than a few years. The cube he used is in a museum with a hand-written label on it: *This machine is a server. DO NOT POWER IT DOWN!!*

The second is everything Apple sells today. When Apple's own attempts at a modern operating system collapsed, it bought NeXT in December 1996 for about $429 million, brought Jobs back with the purchase, and made NeXTSTEP the foundation of Mac OS X. That inheritance is not metaphorical. Cocoa is the NeXTSTEP application framework with a new name, which is why its classes are still called `NSString`, `NSWindow` and `NSObject` — NS for NeXTSTEP, in code written this morning, on iPhones, thirty years after the company that chose the prefix stopped making hardware.

Along the way the Dock, the column of application icons down the right-hand edge of this screen, moved to the bottom of every Mac; the app bundle — a program that is really a folder pretending to be a file — became how Mac software is installed; and Objective-C carried the whole message-passing style of NeXT's frameworks into two decades of Apple development.

## What you're looking at

A NeXTcube: 68040, 64 MB of memory, and the MegaPixel display's 1120x832 greyscale, resting on the Workspace exactly as an untouched login leaves it. Nothing here has been arranged for the exhibit.

Top left is the Workspace menu — NeXTSTEP menus are not a bar across the top of the screen, they are floating panels you can tear off and leave wherever you like. The window is the File Viewer, showing the home directory of the user the machine logs in as; the horizontal column browser inside it is another NeXT idea that survives in the Finder to this day. Down the right-hand edge is the Dock, with the recycler at the bottom.

The greyscale is not a limitation of the exhibit. The original cube's display was two bits deep — black, white and two greys — and the entire interface was designed around that constraint, which is a large part of why it still looks calm.

## Legacy

NeXT the hardware company is a footnote: fifty thousand machines, most of them in universities and financial-trading rooms, and a final year spent selling the operating system alone for ordinary Intel PCs. NeXTSTEP the software is the most consequential operating system almost nobody used. It is the direct ancestor of macOS, iOS, iPadOS, watchOS and tvOS, which between them run on well over a billion devices; its framework survives class-for-class; and the first thing anyone ever browsed the web with was written on it.

The machine here is emulated, but the software is not a reconstruction. It is NeXTSTEP 3.3, the release from 1995, running the same Workspace Manager that Berners-Lee had open while he invented the browser.
