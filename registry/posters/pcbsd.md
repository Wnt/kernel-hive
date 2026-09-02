---
title: PC-BSD 1.5.1
subtitle: 2008 · FreeBSD made point-and-click — KDE 3, a graphical installer and one-click PBI packages
hero: /posters/pcbsd/desktop.webp
images:
  - src: /posters/pcbsd/desktop.webp
    alt: The PC-BSD 1.5.1 graphical installer at 1024x768 — a Qt window titled PC-BSD Install on a blue gradient background, its first page asking to Select Language and Keyboard, with a step list down the left and Back, Next and Cancel buttons at the bottom
    caption: The installer's first page, about thirty-five seconds after power-on from the install CD. This is the whole point of the project — in 2008 the FreeBSD it wraps still installed through the text-mode sysinstall.
  - src: /posters/pcbsd/installer-accounts.webp
    alt: The PC-BSD Install window on its User accounts page — a root password already entered, an Add user form with Username, Full name, Password and a Shell drop-down reading /bin/csh, a User Accounts list showing visitor (Visitor) - /bin/csh, and a ticked Auto-login User checkbox, with Quick Tips explaining the root password and the default shell below
    caption: The User accounts step, captured while this exhibit's disk was being installed. The tips box explains what a shell is, and leaves csh selected — a FreeBSD default this desktop distribution did not change.
---
## Origins

**PC-BSD** was started in 2005 by **Kris Moore**, with a single aim: a FreeBSD that a desktop user could install and run without ever meeting the command line. Under the hood it was unmodified FreeBSD — 1.5.1 is built on **FreeBSD 6.3-RELEASE** — but on top of it came a Qt graphical installer, **KDE 3.5.8** on **X.org 7.3** as the one supported desktop, and the project's own answer to package management: the **PBI**, a self-contained "Push Button Installer" bundle with every dependency inside it, installed with a double-click and a few Next buttons, the way Windows users already installed software.

In October 2006 the project was acquired by **iXsystems**, the FreeBSD hardware vendor, which kept Moore on and funded development. Version 1.5.1 "Edison", released in the spring of 2008, was the last of the 1.x line and the last built on FreeBSD 6; the next release, **7.0 "Fibonacci"** (September 2008), moved to FreeBSD 7 and KDE 4. The lineage carried on for a decade and was renamed **TrueOS** in 2016 before winding down.

## Significance

PC-BSD is a marker for a specific moment: the years when desktop Linux distributions had made "just works" the bar, and the BSD world tried to meet it without forking the base system. The graphical installer, the auto-login checkbox, the one-click PBI — none of these were new ideas in 2008, but they were new to FreeBSD, and PC-BSD proved they could sit on top of it without changing the kernel, the ports tree or the release engineering beneath.

The PBI format is the part worth a second look. Bundling every dependency into one installer solved the problem it set out to solve — no dependency conflicts, no ports build — at the cost of disk space and duplicated libraries, an argument that would be had again a decade later around Snap, Flatpak and AppImage. PC-BSD had it first, on a BSD.

## What you're looking at

A 2008-class PC with 1 GB of RAM, a standard VGA card driven by X.org's vesa driver at 1024 by 768, an AC'97 sound chip, an Intel network card and a USB tablet pointer, running an installed PC-BSD 1.5.1 from CD1 — the base system plus KDE; CD2 carried optional PBIs and is not needed.

The exhibit boots straight into a KDE 3.5 desktop as the `visitor` user. **Alt+F1** opens the K menu; **Alt+F2** the run dialog; **Ctrl+Esc** the process table. **Konqueror** is both file manager and web browser, **Konsole** the terminal — `uname -a` there reports the FreeBSD 6.3 kernel that all of this is standing on — and **KWrite** the editor. The PBI installer is in the K menu under System.

The disk is a single image, and the exhibit restores it when it resets, so a file you write belongs to your visit.

## Legacy

PC-BSD never reached the numbers of the Linux desktops it was measured against, but its ideas outlived the name: the graphical installer became pc-sysinstall and then the basis of TrueOS's, the Lumina desktop came out of the same team, and iXsystems' FreeNAS and TrueNAS inherited the "FreeBSD, but you never need the shell" attitude. The hall's `freebsd411` exhibit shows the base system from a few years earlier, in text mode; this one shows what a team spent three years building on top of it.
